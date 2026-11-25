#!/usr/bin/env bash
#
# Build the GUH image as <image-ref>, with every layer under the Edge's
# maximum artifact size, and push it.
#
#   docker/build-guh-image.sh <image-ref>
#
# Environment:
#   WARM_TASK          tasks that warm the Gradle user home (default: assembleDebug testDebugUnitTest)
#   LAYER_LIMIT_MIB    largest layer (default: 95; the Edge default limit is 100 MiB)
#   PUSH               0 to only load the image locally (default: 1)
set -euo pipefail

IMAGE_REF="${1:?usage: build-guh-image.sh <image-ref>}"
WARM_TASK="${WARM_TASK:-assembleDebug testDebugUnitTest}"
LAYER_LIMIT_MIB="${LAYER_LIMIT_MIB:-95}"
PUSH="${PUSH:-1}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# The project is the build context (see .dockerignore); the tooling reaches
# the build as a named context, so editing it never busts the warm stage.
COMMON_ARGS=(--platform linux/amd64
  --build-context "harness=$ROOT/docker"
  --build-arg "WARM_TASK=$WARM_TASK"
  --build-arg "LAYER_LIMIT_BYTES=$(( LAYER_LIMIT_MIB * 1024 * 1024 ))")

OUT="$ROOT/.docker-build"
rm -rf "$OUT"
mkdir -p "$OUT"
docker buildx build "${COMMON_ARGS[@]}" -f docker/guh.Dockerfile \
  --target layer-count --output "type=local,dest=$OUT/count" .
LAYERS="$(tr -d ' \n' < "$OUT/count/layer-count")"
echo "$LAYERS payload layers, each under $LAYER_LIMIT_MIB MiB"

{
  cat docker/guh.Dockerfile
  echo
  echo "FROM ubuntu:24.04"
  echo "LABEL org.opencontainers.image.source=https://github.com/${GITHUB_REPOSITORY:-cdsap/artifact-cache-docker-gradle-home}"
  echo "RUN useradd --create-home --home-dir /home/runner --shell /bin/bash --uid 1001 runner"
  for i in $(seq 0 $(( LAYERS - 1 ))); do
    printf 'COPY --from=split --chown=1001:1001 /layers/%03d/ /\n' "$i"
  done
  echo "ENV JAVA_HOME=/opt/jdk ANDROID_HOME=/opt/android-sdk ANDROID_SDK_ROOT=/opt/android-sdk GRADLE_USER_HOME=/home/runner/.gradle"
  echo "ENV PATH=/opt/jdk/bin:\$PATH"
  echo "USER runner"
} > "$OUT/guh.generated.Dockerfile"

docker buildx build "${COMMON_ARGS[@]}" -f "$OUT/guh.generated.Dockerfile" -t "$IMAGE_REF" --load .
docker image inspect --format '{{.Size}} bytes in {{len .RootFS.Layers}} layers' "$IMAGE_REF"
if [ "$PUSH" = 1 ]; then docker push "$IMAGE_REF"; fi
