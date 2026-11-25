# An ephemeral CI agent with its OWN Docker daemon.
#
# Artifact Cache only sees the agent's local daemon during the job; images
# pulled by another daemon (a remote DOCKER_HOST, a socket shared with the
# host) are invisible to it. So each runner starts dockerd inside itself, on a
# fresh /var/lib/docker volume: an empty image store, exactly like a new CI
# machine, and the only way the GUH image can be there before the build is a
# registry pull or an Artifact Cache restore.
#
# Native architecture on purpose: dockerd and the CLI run fast; only the GUH
# image (linux/amd64, because Linux Android build-tools are x86_64-only) is
# emulated, and only for the Gradle build itself.
FROM docker:27.5.1-dind

RUN apk add --no-cache bash coreutils curl rsync openjdk21-jre-headless

# 1.9.0 is the first CLI that caches Docker images; 1.10.0 is what
# gradle/develocity-artifact-cache-github-action v1.2.0 pins. The checksum is
# the one published next to the jar.
ARG ARTIFACT_CACHE_CLI_VERSION=1.10.0
ARG ARTIFACT_CACHE_CLI_SHA256=664bfb44046db0fccb2518fff2e38eaa4c3e1ec2265adc54de6f3f30ee869db3
ENV ARTIFACT_CACHE_CLI_JAR=/opt/develocity/develocity-artifact-cache-cli.jar
RUN set -eux; \
    mkdir -p /opt/develocity; \
    curl --location --fail --silent --show-error --retry 3 \
         "https://docs.develocity.ai/downloads/develocity-artifact-cache-cli/develocity-artifact-cache-cli-${ARTIFACT_CACHE_CLI_VERSION}.jar" \
         --output "$ARTIFACT_CACHE_CLI_JAR"; \
    echo "${ARTIFACT_CACHE_CLI_SHA256}  $ARTIFACT_CACHE_CLI_JAR" | sha256sum -c -; \
    java -jar "$ARTIFACT_CACHE_CLI_JAR" --version

COPY runner-entrypoint.sh /usr/local/bin/runner-entrypoint.sh
RUN chmod +x /usr/local/bin/runner-entrypoint.sh

ENV PROJECT_SOURCE=/mnt/project \
    PROJECT_DIR=/work/project \
    RUN_OUTPUT_DIR=/out
ENTRYPOINT ["/usr/local/bin/runner-entrypoint.sh"]
