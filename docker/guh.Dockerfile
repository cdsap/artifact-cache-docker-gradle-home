# The "Gradle user home" Docker image: everything an Android project needs to build,
# baked into an image, so a CI job only has to pull it and `docker run` the
# build. This is the image Artifact Cache (CLI 1.9+) is expected to cache.
#
# Built in two stages, then finished by a Dockerfile that
# run.sh generates, because the number of layers
# is only known after the split:
#
#   warm    JDK + Android SDK + a Gradle user home warmed by WARM_TASK
#   split   the three trees spread over /layers/NNN, each under LAYER_LIMIT_BYTES
#
# Every layer of the final image must fit under the Edge's maximum artifact
# size, base image included — hence a jlinked JDK (the stock lib/modules is a
# single ~130 MiB file) on plain ubuntu rather than the eclipse-temurin image.

# ---------------------------------------------------------------------------
FROM eclipse-temurin:21-jdk-noble AS warm

ARG ANDROID_CMDLINE_TOOLS_ZIP=commandlinetools-linux-13114758_latest.zip
ARG ANDROID_CMDLINE_TOOLS_SHA1=5fdcc763663eefb86a5b8879697aa6088b041e70
ARG ANDROID_COMPILE_SDK=36
ARG WARM_TASK=:app:compileDemoDebugKotlin

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl unzip \
 && rm -rf /var/lib/apt/lists/*

# Compressed, so lib/modules fits under the layer limit. Gradle, AGP and the
# Kotlin compiler only need a runtime with every module, not jmods.
RUN jlink --add-modules ALL-MODULE-PATH --compress=zip-6 --strip-debug \
          --no-header-files --no-man-pages --output /opt/jdk \
 && ls -l /opt/jdk/lib/modules
ENV JAVA_HOME=/opt/jdk
ENV PATH=/opt/jdk/bin:$PATH

# Same SDK pinning as docker/Dockerfile: 19.0 is the last cmdline-tools with a
# self-contained sdkmanager.
ENV ANDROID_HOME=/opt/android-sdk
ENV ANDROID_SDK_ROOT=$ANDROID_HOME
RUN set -eux; \
    mkdir -p "$ANDROID_HOME/cmdline-tools"; \
    curl --location --fail --silent --show-error --retry 3 \
         "https://dl.google.com/android/repository/${ANDROID_CMDLINE_TOOLS_ZIP}" \
         --output /tmp/cmdline-tools.zip; \
    echo "${ANDROID_CMDLINE_TOOLS_SHA1}  /tmp/cmdline-tools.zip" | sha1sum --check; \
    unzip -q /tmp/cmdline-tools.zip -d /tmp/cmdline-tools-extracted; \
    mv /tmp/cmdline-tools-extracted/cmdline-tools "$ANDROID_HOME/cmdline-tools/latest"; \
    rm -rf /tmp/cmdline-tools.zip /tmp/cmdline-tools-extracted; \
    yes | "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --licenses > /dev/null; \
    "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --install "platform-tools" "platforms;android-${ANDROID_COMPILE_SDK}" > /dev/null

# Warm the Gradle user home with a real build. AGP also installs the
# build-tools it needs into the (writable) SDK here. No scan: this is image
# preparation, not a measurement.
#
# The wrapper only checks the unpacked distribution and its .ok marker; the
# ~140 MiB zip next to them would be a single file above the layer limit.
ENV GRADLE_USER_HOME=/opt/guh
COPY . /src
WORKDIR /src
RUN ./gradlew ${WARM_TASK} --no-daemon --no-watch-fs --no-scan --max-workers=2 \
        -Dorg.gradle.jvmargs="-Xmx3g -XX:MaxMetaspaceSize=1g -Dfile.encoding=UTF-8" \
        -Pkotlin.compiler.execution.strategy=in-process \
 && rm -rf "$GRADLE_USER_HOME"/daemon "$GRADLE_USER_HOME"/workers "$GRADLE_USER_HOME"/.tmp \
           "$GRADLE_USER_HOME"/build-scan-data "$GRADLE_USER_HOME"/.develocity \
 && find "$GRADLE_USER_HOME"/wrapper/dists -name '*.zip' -delete \
 && du -sh "$GRADLE_USER_HOME" "$ANDROID_HOME" /opt/jdk

# ---------------------------------------------------------------------------
# File moves only, so run it on the build platform rather than under emulation.
FROM --platform=$BUILDPLATFORM ubuntu:24.04 AS split
ARG LAYER_LIMIT_BYTES=99614720
COPY --from=warm /opt/jdk /payload/opt/jdk
COPY --from=warm /opt/android-sdk /payload/opt/android-sdk
COPY --from=warm /opt/guh /payload/home/runner/.gradle
COPY --from=harness split-into-layers.sh /usr/local/bin/split-into-layers.sh
# generated-gradle-jars holds gradle-api-<version>.jar (~190 MiB, one file, so
# no layering fits it). Gradle regenerates it locally on first use, offline too.
RUN rm -rf /payload/home/runner/.gradle/caches/*/generated-gradle-jars \
 && bash /usr/local/bin/split-into-layers.sh /payload /layers "$LAYER_LIMIT_BYTES" \
 && ls /layers | wc -l > /layer-count

# Only the layer count, so the orchestrator can generate the final stage
# without exporting the layers themselves.
FROM scratch AS layer-count
COPY --from=split /layer-count /layer-count

# ---------------------------------------------------------------------------
# The final stage is appended by run.sh:
#
#   FROM ubuntu:24.04
#   COPY --from=split --chown=1001:1001 /layers/000/ /
#   COPY --from=split --chown=1001:1001 /layers/001/ /
#   …
