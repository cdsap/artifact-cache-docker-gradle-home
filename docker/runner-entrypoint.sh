#!/usr/bin/env bash
#
# One ephemeral agent, one role. The build always runs inside GUH_IMAGE, the
# image that carries the Gradle user home; what differs is how that image
# reaches this agent's empty Docker daemon.
#
#   seed     restore (expected miss) -> pull from registry -> build -> store
#   restore  restore (expected hit)  -> build with --pull=never [-> store]
#   control  no CLI                  -> pull from registry -> build
#
# `--pull=never` on the restore runner makes the test falsifiable: if the
# restore did not load the image, the build fails instead of quietly pulling.
set -euo pipefail

ROLE="${1:-${ROLE:-}}"
case "$ROLE" in
  seed|restore|control) ;;
  *) echo "usage: runner-entrypoint.sh <seed|restore|control>" >&2; exit 2 ;;
esac

: "${GUH_IMAGE:?GUH_IMAGE is required (registry reference with a version tag, never latest)}"
: "${PROJECT_SOURCE:?}"
: "${PROJECT_DIR:?}"
OUT="${RUN_OUTPUT_DIR:-/out}"
TASK="${TASK:-:app:compileDemoDebugKotlin}"
EXTRA_GRADLE_ARGS="${EXTRA_GRADLE_ARGS:-}"
GUH_PLATFORM="${GUH_PLATFORM:-linux/amd64}"
INSECURE_REGISTRY="${INSECURE_REGISTRY:-}"
OFFLINE_ARGS="--offline"
if [ "${ONLINE:-0}" = "1" ]; then OFFLINE_ARGS=""; fi

hr()  { printf '\n\033[1m== [%s] %s ==\033[0m\n' "$ROLE" "$1"; }
log() { printf '   %s\n' "$*"; }
now() { date +%s.%N; }
secs() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", b - a }'; }

mkdir -p "$OUT"
: > "$OUT/$ROLE-timings.txt"
timing() { printf '%-16s %8ss\n' "$1" "$2" | tee -a "$OUT/$ROLE-timings.txt" | sed 's/^/   /'; }

# ---------------------------------------------------------------------------
# A Docker daemon of our own, on an empty image store.
# ---------------------------------------------------------------------------
hr "Start this agent's Docker daemon"
DOCKERD_ARGS=(--host=unix:///var/run/docker.sock)
if [ -n "$INSECURE_REGISTRY" ]; then DOCKERD_ARGS+=("--insecure-registry=$INSECURE_REGISTRY"); fi
# `dind` is the docker:dind helper that prepares cgroups and mounts.
dind dockerd "${DOCKERD_ARGS[@]}" > "$OUT/$ROLE-dockerd.log" 2>&1 &
for _ in $(seq 1 60); do docker info > /dev/null 2>&1 && break; sleep 1; done
if ! docker info > /dev/null 2>&1; then
  echo "ERROR: dockerd did not start; see $OUT/$ROLE-dockerd.log" >&2
  tail -20 "$OUT/$ROLE-dockerd.log" >&2
  exit 1
fi
log "docker engine    : $(docker version --format '{{.Server.Version}}') (Artifact Cache needs 25+)"
log "images present   : $(docker images -q | wc -l) (expected 0 on a new agent)"
log "GUH image        : $GUH_IMAGE ($GUH_PLATFORM)"
log "task             : $TASK ${OFFLINE_ARGS}"

# ---------------------------------------------------------------------------
# A pristine project tree; the build container mounts it.
# ---------------------------------------------------------------------------
rm -rf "$PROJECT_DIR"
mkdir -p "$PROJECT_DIR"
rsync -a --exclude '.gradle/' --exclude 'build/' --exclude '*/build/' \
      --exclude '.docker-run/' --exclude 'local.properties' \
      "$PROJECT_SOURCE"/ "$PROJECT_DIR"/
# The GUH image runs as uid 1001.
chown -R 1001:1001 "$PROJECT_DIR"

# ---------------------------------------------------------------------------
# Artifact Cache: Docker images only. No Gradle on this agent (the Gradle user
# home lives in the image) and no Setup Cache, so whatever moves is Docker.
# Restore and store run in the same working directory, as the docs require.
# ---------------------------------------------------------------------------
CLI_OPTS=(
  "--dv-server=${DV_SERVER:-}"
  "--image-name=${CACHE_IMAGE_NAME:-}"
  "--autodetect=DOCKER"
  "--disable-setup-cache"
  "--timeout=${CLI_TIMEOUT:-PT30M}"
  "--reporting-directory=$OUT/ac-logs"
)
if [ "${CLI_VERBOSE:-1}" = "1" ]; then CLI_OPTS+=("--verbose"); fi
cli() { (cd /work && java -jar "$ARTIFACT_CACHE_CLI_JAR" "$@"); }

check_cli_log() {
  if grep -qiE "Connection error|failed to sign in to Edge|UnprocessedRequestException" "$1"; then
    echo "ERROR: the CLI could not reach the Edge; see $1" >&2
    return 1
  fi
  if grep -qiE "entitlement|not entitled" "$1"; then
    echo "WARNING: the CLI mentioned entitlements; see $1" >&2
  fi
}

if [ "$ROLE" != "control" ]; then
  : "${DV_SERVER:?DV_SERVER is required}"
  : "${CACHE_IMAGE_NAME:?CACHE_IMAGE_NAME is required and must be identical on every runner}"
  hr "Artifact Cache restore"
  log "cache image name : $CACHE_IMAGE_NAME"
  t0=$(now)
  set +e
  cli restore "${CLI_OPTS[@]}" 2>&1 | tee "$OUT/$ROLE-restore.log"
  rc=${PIPESTATUS[0]}
  set -e
  timing "restore" "$(secs "$t0" "$(now)")"
  log "restore exit code: $rc"
  check_cli_log "$OUT/$ROLE-restore.log"
fi

hr "Image store before the build"
docker images --format '   {{.Repository}}:{{.Tag}}  {{.Size}}'
if docker image inspect "$GUH_IMAGE" > /dev/null 2>&1; then
  GUH_PRESENT=yes
else
  GUH_PRESENT=no
fi
log "GUH image present: $GUH_PRESENT"
echo "$GUH_PRESENT" > "$OUT/$ROLE-guh-present.txt"

if [ "$ROLE" = "restore" ]; then
  PULL_POLICY=never
  if [ "$GUH_PRESENT" = no ]; then
    echo "ERROR: the restore did not load $GUH_IMAGE; nothing to build with." >&2
    echo "       Check $OUT/$ROLE-restore.log for skipped images (layer above the" >&2
    echo "       Edge maximum artifact size, missing entries, Docker < 25)." >&2
    exit 1
  fi
else
  PULL_POLICY=missing
  hr "Pull the GUH image from the registry"
  t0=$(now)
  docker pull --platform "$GUH_PLATFORM" "$GUH_IMAGE" | tail -3 | sed 's/^/   /'
  timing "registry pull" "$(secs "$t0" "$(now)")"
fi

# ---------------------------------------------------------------------------
# Build inside the GUH image. --offline by default: the build has to succeed
# from what the image carries, which is the claim being tested.
# ---------------------------------------------------------------------------
hr "Build inside the GUH image"
t0=$(now)
set +e
# shellcheck disable=SC2086
docker run --rm --pull="$PULL_POLICY" --platform "$GUH_PLATFORM" \
  -v "$PROJECT_DIR:/home/runner/work/project" \
  -w /home/runner/work/project \
  -e DEVELOCITY_ACCESS_KEY \
  "$GUH_IMAGE" \
  ./gradlew $TASK $OFFLINE_ARGS --no-watch-fs --max-workers=2 \
    -Dorg.gradle.jvmargs="-Xmx3g -XX:MaxMetaspaceSize=1g -Dfile.encoding=UTF-8" \
    -Pkotlin.compiler.execution.strategy=in-process \
    -Dscan.tag.ac_docker -Dscan.tag.ac_docker_$ROLE \
    ${CACHE_IMAGE_NAME:+"-Dscan.value.cacheImage=$CACHE_IMAGE_NAME"} \
    $EXTRA_GRADLE_ARGS \
  2>&1 | tee "$OUT/$ROLE-build.log"
BUILD_RC=${PIPESTATUS[0]}
set -e
timing "build" "$(secs "$t0" "$(now)")"
log "build exit code: $BUILD_RC"

# ---------------------------------------------------------------------------
# Store. Exports the image under ~/.develocity/artifact-cache/docker/ and
# uploads only the layer files the Edge does not hold yet.
# ---------------------------------------------------------------------------
if [ "$ROLE" = "seed" ] || { [ "$ROLE" = "restore" ] && [ "${STORE_AFTER_BUILD:-0}" = "1" ]; }; then
  if [ "$BUILD_RC" -ne 0 ]; then
    hr "Skipping store: the build failed"
  else
    hr "Artifact Cache store"
    t0=$(now)
    set +e
    cli store "${CLI_OPTS[@]}" 2>&1 | tee "$OUT/$ROLE-store.log"
    rc=${PIPESTATUS[0]}
    set -e
    timing "store" "$(secs "$t0" "$(now)")"
    log "store exit code: $rc"
    check_cli_log "$OUT/$ROLE-store.log"
  fi
fi

hr "Outcome"
cat "$OUT/$ROLE-timings.txt" | sed 's/^/   /'
for f in "$OUT/$ROLE-restore.log" "$OUT/$ROLE-store.log"; do
  [ -f "$f" ] || continue
  grep -iE "docker|image" "$f" | grep -viE "^\s*at " | tail -15 | sed "s/^/   $(basename "$f"): /" || true
done
exit "$BUILD_RC"
