#!/usr/bin/env bash
#
# The GUH image tag: a hash of everything that decides what the Gradle user
# home holds (build scripts, version catalog, wrapper, build logic) and of the
# image tooling itself. It changes only when the dependencies can, and it is
# never `latest`, which Artifact Cache does not cache.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

hash="$(git ls-files -s -- \
          gradle build-logic gradle.properties settings.gradle.kts \
          '*.gradle.kts' docker/guh.Dockerfile docker/split-into-layers.sh docker/build-guh-image.sh \
        | git hash-object --stdin)"
echo "deps-${hash:0:12}"
