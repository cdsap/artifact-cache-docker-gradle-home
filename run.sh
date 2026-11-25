#!/usr/bin/env bash
#
# Test Artifact Cache Docker image caching with a Gradle user home baked into
# a Docker image, on ephemeral runners on your machine.
#
#   1. Build the GUH image (JDK + Android SDK + warmed Gradle user home), with
#      every layer under the Edge's maximum artifact size, and push it to a
#      local registry.
#   2. Runner #1 (seed): empty Docker daemon, pulls the image from the
#      registry, builds in it, and Artifact Cache stores the image.
#   3. Runner #2 (restore): empty Docker daemon, Artifact Cache restores the
#      image, and the build runs with --pull=never.
#   4. Optional runner #3 (control): pulls from the registry, no cache.
#
# Usage:
#   export DV_SERVER=https://develocity.example.com
#   export DEVELOCITY_ACCESS_KEY='develocity.example.com=<key>'
#   ./run.sh [options]
#
# If DEVELOCITY_ACCESS_KEY is unset, the key for DV_SERVER's host is read from
# ~/.gradle/develocity/keys.properties.
#
# Options:
#   --project DIR          Android project to build (default: android/nowinandroid
#                          at $NIA_COMMIT, cloned into .work/)
#   --task TASK            task the runners build (default: :app:compileDemoDebugKotlin)
#   --warm-task TASK       task that warms the GUH image (default: same as --task)
#   --layer-limit-mib N    largest layer of the GUH image (default: 95; Edge default limit is 100)
#   --image-name NAME      Artifact Cache image name shared by the runners (default: generated)
#   --control              also run a cache-free runner that pulls from the registry
#   --seed-only            run runner #1 and stop
#   --restore-only         skip seeding; requires --image-name
#   --store-on-restore     let runner #2 store as well
#   --online               build without --offline
#   --extra-args "…"       extra Gradle arguments
#   --quiet-cli            drop the CLI's --verbose
#   --skip-guh-build       reuse the GUH image already in the local registry
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

NIA_REPO=https://github.com/android/nowinandroid.git
NIA_COMMIT=a49ed253d75e61a2b6ab80a8da677b57437b08eb
RUNNER_IMAGE="${RUNNER_IMAGE:-ac-docker-runner:local}"
NETWORK=ac-docker
REGISTRY_CONTAINER=ac-docker-registry
REGISTRY_HOST_PORT=5055
GUH_PLATFORM=linux/amd64
PROJECT=""
TASK=":app:compileDemoDebugKotlin"
WARM_TASK=""
LAYER_LIMIT_MIB=95
CACHE_IMAGE_NAME=""
EXTRA_GRADLE_ARGS=""
RUN_CONTROL=0 DO_SEED=1 DO_RESTORE=1 STORE_AFTER_BUILD=0 ONLINE=0 CLI_VERBOSE=1 BUILD_GUH=1

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="${2:?}"; shift 2 ;;
    --task) TASK="${2:?}"; shift 2 ;;
    --warm-task) WARM_TASK="${2:?}"; shift 2 ;;
    --layer-limit-mib) LAYER_LIMIT_MIB="${2:?}"; shift 2 ;;
    --image-name) CACHE_IMAGE_NAME="${2:?}"; shift 2 ;;
    --extra-args) EXTRA_GRADLE_ARGS="${2:?}"; shift 2 ;;
    --control) RUN_CONTROL=1; shift ;;
    --seed-only) DO_RESTORE=0; shift ;;
    --restore-only) DO_SEED=0; shift ;;
    --store-on-restore) STORE_AFTER_BUILD=1; shift ;;
    --online) ONLINE=1; shift ;;
    --quiet-cli) CLI_VERBOSE=0; shift ;;
    --skip-guh-build) BUILD_GUH=0; shift ;;
    -h|--help) sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
WARM_TASK="${WARM_TASK:-$TASK}"

hr() { printf '\n\033[1m######## %s\033[0m\n' "$1"; }

hr "Preflight"
if ! docker info > /dev/null 2>&1; then
  echo "ERROR: the Docker daemon is not reachable." >&2
  exit 1
fi
: "${DV_SERVER:?DV_SERVER is required, e.g. export DV_SERVER=https://develocity.example.com}"
DV_HOST="$(echo "$DV_SERVER" | sed -E 's#^https?://##; s#/.*$##')"
if [ -z "${DEVELOCITY_ACCESS_KEY:-}" ] && [ -f "$HOME/.gradle/develocity/keys.properties" ]; then
  DEVELOCITY_ACCESS_KEY="$(grep -E "^${DV_HOST//./\\.}=" "$HOME/.gradle/develocity/keys.properties" | head -1 || true)"
fi
if [ -z "${DEVELOCITY_ACCESS_KEY:-}" ]; then
  echo "ERROR: no access key for $DV_HOST. export DEVELOCITY_ACCESS_KEY='$DV_HOST=<key>'" >&2
  exit 1
fi
export DEVELOCITY_ACCESS_KEY
MEM_GIB=$(( $(docker info --format '{{.MemTotal}}') / 1024 / 1024 / 1024 ))
echo "   docker memory    : ${MEM_GIB} GiB"
if [ "$MEM_GIB" -lt 10 ]; then
  echo "   WARNING: builds run with -Xmx3g, 2 workers and an in-process Kotlin" >&2
  echo "            compiler to fit, but 10-12 GiB is safer for Android tasks." >&2
fi
if [ "$DO_SEED" = 0 ] && [ -z "$CACHE_IMAGE_NAME" ]; then
  echo "ERROR: --restore-only needs --image-name." >&2
  exit 2
fi
CACHE_IMAGE_NAME="${CACHE_IMAGE_NAME:-ac-docker-$(date -u +%Y%m%d-%H%M%S)-$$}"

if [ -z "$PROJECT" ]; then
  PROJECT="$ROOT/.work/nowinandroid"
  if [ ! -d "$PROJECT/.git" ]; then
    hr "Clone android/nowinandroid at ${NIA_COMMIT:0:8}"
    git init -q "$PROJECT"
    git -C "$PROJECT" fetch -q --depth 1 "$NIA_REPO" "$NIA_COMMIT"
    git -C "$PROJECT" checkout -q FETCH_HEAD
  fi
fi
PROJECT="$(cd "$PROJECT" && pwd)"

# Never `latest`: Artifact Cache skips images tagged latest or untagged.
PROJECT_REV="$(git -C "$PROJECT" rev-parse --short HEAD 2>/dev/null || echo nogit)"
GUH_TAG="$PROJECT_REV-$(printf '%s|%s' "$WARM_TASK" "$LAYER_LIMIT_MIB" | shasum | cut -c1-8)"
GUH_IMAGE="$REGISTRY_CONTAINER:5000/guh:$GUH_TAG"
GUH_PUSH_REF="localhost:$REGISTRY_HOST_PORT/guh:$GUH_TAG"
echo "   DV server        : $DV_SERVER"
echo "   project          : $PROJECT"
echo "   cache image name : $CACHE_IMAGE_NAME"
echo "   GUH image        : $GUH_IMAGE"
echo "   warm task        : $WARM_TASK"
echo "   runner task      : $TASK $([ "$ONLINE" = 1 ] || echo --offline)"
echo "   layer limit      : $LAYER_LIMIT_MIB MiB"

OUT_ROOT="$ROOT/.docker-run/$CACHE_IMAGE_NAME"
mkdir -p "$OUT_ROOT"/{seed,restore,control}

hr "Local registry"
docker network inspect "$NETWORK" > /dev/null 2>&1 || docker network create "$NETWORK" > /dev/null
if ! docker container inspect "$REGISTRY_CONTAINER" > /dev/null 2>&1; then
  docker run -d --name "$REGISTRY_CONTAINER" --network "$NETWORK" \
    -p "127.0.0.1:$REGISTRY_HOST_PORT:5000" registry:2.8.3 > /dev/null
fi
docker start "$REGISTRY_CONTAINER" > /dev/null
echo "   $REGISTRY_CONTAINER on $NETWORK, pushed to as localhost:$REGISTRY_HOST_PORT"
echo "   NOTE: a registry on the same machine is the best case for a pull. Compare"
echo "         restore against a pull from your real registry before quoting savings."

if [ "$BUILD_GUH" = 1 ]; then
  hr "Build the GUH image"
  LAYER_LIMIT_BYTES=$(( LAYER_LIMIT_MIB * 1024 * 1024 ))
  # The project is the build context, so editing this harness never busts the
  # (long) warm stage; the harness reaches the build as a named context.
  COMMON_ARGS=(--platform "$GUH_PLATFORM"
    --build-context "harness=$ROOT/docker"
    --build-arg "WARM_TASK=$WARM_TASK"
    --build-arg "LAYER_LIMIT_BYTES=$LAYER_LIMIT_BYTES")
  COUNT_DIR="$(mktemp -d)"
  docker buildx build "${COMMON_ARGS[@]}" -f docker/guh.Dockerfile \
    --target layer-count --output "type=local,dest=$COUNT_DIR" "$PROJECT"
  LAYERS="$(tr -d ' \n' < "$COUNT_DIR/layer-count")"
  rm -rf "$COUNT_DIR"
  echo "   $LAYERS payload layers"

  GEN_DOCKERFILE="$OUT_ROOT/guh.generated.Dockerfile"
  {
    cat docker/guh.Dockerfile
    echo
    echo "FROM ubuntu:24.04"
    echo "RUN useradd --create-home --home-dir /home/runner --shell /bin/bash --uid 1001 runner"
    for i in $(seq 0 $(( LAYERS - 1 ))); do
      printf 'COPY --from=split --chown=1001:1001 /layers/%03d/ /\n' "$i"
    done
    echo "ENV JAVA_HOME=/opt/jdk ANDROID_HOME=/opt/android-sdk ANDROID_SDK_ROOT=/opt/android-sdk GRADLE_USER_HOME=/home/runner/.gradle"
    echo "ENV PATH=/opt/jdk/bin:\$PATH"
    echo "USER runner"
  } > "$GEN_DOCKERFILE"
  docker buildx build "${COMMON_ARGS[@]}" -f "$GEN_DOCKERFILE" -t "$GUH_PUSH_REF" --load "$PROJECT"
  docker push "$GUH_PUSH_REF" | tail -1

  # Per-layer sizes are in the split step's output above; `docker history`
  # reports 0B per layer with the containerd image store.
  hr "GUH image"
  docker image inspect --format '   total: {{.Size}} bytes, {{len .RootFS.Layers}} layers' "$GUH_PUSH_REF"
fi

hr "Build the runner image"
docker build -f docker/runner.Dockerfile -t "$RUNNER_IMAGE" docker

run_runner() {
  local role="$1"
  docker run --rm --privileged \
    --name "ac-docker-$role-$$" \
    --network "$NETWORK" \
    -e "ROLE=$role" \
    -e "DV_SERVER=$DV_SERVER" \
    -e DEVELOCITY_ACCESS_KEY \
    -e "CACHE_IMAGE_NAME=$CACHE_IMAGE_NAME" \
    -e "GUH_IMAGE=$GUH_IMAGE" \
    -e "GUH_PLATFORM=$GUH_PLATFORM" \
    -e "INSECURE_REGISTRY=$REGISTRY_CONTAINER:5000" \
    -e "TASK=$TASK" \
    -e "EXTRA_GRADLE_ARGS=$EXTRA_GRADLE_ARGS" \
    -e "ONLINE=$ONLINE" \
    -e "STORE_AFTER_BUILD=$STORE_AFTER_BUILD" \
    -e "CLI_VERBOSE=$CLI_VERBOSE" \
    -e CLI_TIMEOUT -e CLI_OPERATION_TIMEOUT -e CLI_OPERATION_CONCURRENCY \
    -v "$PROJECT:/mnt/project:ro" \
    -v "$OUT_ROOT/$role:/out" \
    "$RUNNER_IMAGE" "$role"
}

SEED_RC=0 RESTORE_RC=0 CONTROL_RC=0
if [ "$DO_SEED" = 1 ]; then
  hr "Runner #1 — seed (pull, build, store)"
  run_runner seed || SEED_RC=$?
fi
if [ "$DO_RESTORE" = 1 ]; then
  hr "Runner #2 — cold agent (restore, build with --pull=never)"
  run_runner restore || RESTORE_RC=$?
fi
if [ "$RUN_CONTROL" = 1 ]; then
  hr "Runner #3 — control (pull, build, no cache)"
  run_runner control || CONTROL_RC=$?
fi

hr "Summary"
for role in seed restore control; do
  [ -f "$OUT_ROOT/$role/$role-timings.txt" ] || continue
  echo "   $role (GUH image present before build: $(cat "$OUT_ROOT/$role/$role-guh-present.txt" 2>/dev/null || echo '?'))"
  sed 's/^/      /' "$OUT_ROOT/$role/$role-timings.txt"
done
echo "   exit codes : seed=$SEED_RC restore=$RESTORE_RC control=$CONTROL_RC"
echo "   logs       : $OUT_ROOT"
echo "   cache image: $CACHE_IMAGE_NAME (pass to --image-name with --restore-only to replay)"

if [ "$SEED_RC" -ne 0 ]; then exit "$SEED_RC"; fi
if [ "$RESTORE_RC" -ne 0 ]; then exit "$RESTORE_RC"; fi
exit "$CONTROL_RC"
