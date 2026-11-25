# The "Gradle user home" Docker image: the JDK, the Android SDK and a Gradle
# user home warmed for this project, so a CI job only has to `docker run` the
# build in it. This is the image Artifact Cache (CLI 1.9+) is expected to cache.
#
# Built in two stages, then finished by a stage that build-guh-image.sh
# appends, because the number of layers is only known after the split:
#
#   warm    JDK + Android SDK + a Gradle user home warmed by WARM_TASK
#   split   the three trees spread over /layers/NNN, each under LAYER_LIMIT_BYTES
#
# Every layer of the final image must fit under the Edge's maximum artifact
# size, base image included — hence a jlinked JDK (the stock lib/modules is a
# single ~130 MiB file) on plain ubuntu rather than the eclipse-temurin image.

# ---------------------------------------------------------------------------
# JDK 23: the generated convention plugins use a Java 23 toolchain, and Gradle
# picks up the JDK it runs on as that toolchain.
FROM eclipse-temurin:23-jdk-noble AS warm

ARG ANDROID_CMDLINE_TOOLS_ZIP=commandlinetools-linux-13114758_latest.zip
ARG ANDROID_CMDLINE_TOOLS_SHA1=5fdcc763663eefb86a5b8879697aa6088b041e70
ARG ANDROID_COMPILE_SDK=36
ARG WARM_TASK="assembleDebug testDebugUnitTest"

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl unzip \
 && rm -rf /var/lib/apt/lists/*

# Compressed, so lib/modules fits under the layer limit. Every module is kept,
# so javac and the other launchers are there for the toolchain.
RUN jlink --add-modules ALL-MODULE-PATH --compress=zip-6 --strip-debug \
          --no-header-files --no-man-pages --output /opt/jdk \
 && ls -l /opt/jdk/lib/modules
ENV JAVA_HOME=/opt/jdk
ENV PATH=/opt/jdk/bin:$PATH

# 19.0 is the last cmdline-tools with a self-contained sdkmanager; later
# releases download a second CLI on first use.
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
ENV GRADLE_USER_HOME=/opt/guh
COPY . /src
WORKDIR /src
RUN ./gradlew ${WARM_TASK} --no-daemon --no-watch-fs --no-scan \
 && rm -rf "$GRADLE_USER_HOME"/daemon "$GRADLE_USER_HOME"/workers "$GRADLE_USER_HOME"/.tmp \
           "$GRADLE_USER_HOME"/build-scan-data "$GRADLE_USER_HOME"/.develocity \
 && du -sh "$GRADLE_USER_HOME" "$ANDROID_HOME" /opt/jdk

# ---------------------------------------------------------------------------
# File moves only, so run it on the build platform rather than under emulation.
FROM --platform=$BUILDPLATFORM ubuntu:24.04 AS split
ARG LAYER_LIMIT_BYTES=99614720
COPY --from=warm /opt/jdk /payload/opt/jdk
COPY --from=warm /opt/android-sdk /payload/opt/android-sdk
COPY --from=warm /opt/guh /payload/home/runner/.gradle
COPY --from=harness split-into-layers.sh /usr/local/bin/split-into-layers.sh
# Left out of the image:
#   generated-gradle-jars  gradle-api-<version>.jar is ~190 MiB in one file, so
#                          no layering fits it; Gradle regenerates it locally,
#                          offline too
#   build-cache-*          the warm build's task outputs; without them the job
#                          compiles for real instead of reusing them
#   wrapper zip            ~140 MiB in one file; the wrapper only needs the
#                          unpacked distribution and its .ok marker
RUN rm -rf /payload/home/runner/.gradle/caches/*/generated-gradle-jars \
           /payload/home/runner/.gradle/caches/build-cache-* \
 && find /payload/home/runner/.gradle/wrapper/dists -name '*.zip' -delete \
 && bash /usr/local/bin/split-into-layers.sh /payload /layers "$LAYER_LIMIT_BYTES" \
 && ls /layers | wc -l > /layer-count

# Only the layer count, so build-guh-image.sh can generate the final stage
# without exporting the layers themselves.
FROM scratch AS layer-count
COPY --from=split /layer-count /layer-count

# ---------------------------------------------------------------------------
# The final stage is appended by build-guh-image.sh:
#
#   FROM ubuntu:24.04
#   COPY --from=split --chown=1001:1001 /layers/000/ /
#   COPY --from=split --chown=1001:1001 /layers/001/ /
#   …
