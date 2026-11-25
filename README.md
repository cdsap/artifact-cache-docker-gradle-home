# Artifact Cache for a Docker image that carries the Gradle user home

Some CI setups don't warm the agent. Instead they bake the Gradle user home (dependencies,
wrapper distribution, transforms), the JDK and the Android SDK into a Docker image, and
every job runs `docker run <that image> ./gradlew …`. From
[Artifact Cache CLI 1.9](https://docs.develocity.ai/artifact-cache/current/concepts/docker-images/),
Develocity Artifact Cache caches the Docker images a job used, so the image can come
from the Edge instead of the registry.

This repository tests that on ephemeral runners on your machine, with an Android
project. By default it uses [android/nowinandroid](https://github.com/android/nowinandroid)
at a pinned commit.

```bash
export DV_SERVER=https://develocity.example.com
export DEVELOCITY_ACCESS_KEY='develocity.example.com=<key>'
./run.sh --control
```

Or on GitHub Actions: add the repository secrets `DEVELOCITY_URL` and
`DEVELOCITY_ACCESS_KEY` (the bare key, or `host=key`), then run the
*Docker image cache test* workflow by hand. It masks the server host and its domain in
the job log, which is public on a public repository. A GitHub-hosted runner is not
next to your Edge, so its timings show that the mechanism works, not what it saves.

| Runner | Docker daemon | How the GUH image arrives | Then |
|---|---|---|---|
| seed | its own, empty | `docker pull` from the registry | build, **store** |
| restore | its own, empty | **Artifact Cache restore** | build with `--pull=never` |
| control | its own, empty | `docker pull` from the registry | build |

`--pull=never` on the restore runner makes the test falsifiable: if the restore did
not load the image, the build fails instead of quietly pulling it.

## Requirements

- Docker with 8 GiB of memory at the very least; 10–12 GiB is safer. On Apple Silicon
  the GUH image is `linux/amd64`, because Linux Android build-tools are x86_64-only,
  so builds run under emulation.
- Develocity 2026.3+ with the Artifact Cache entitlement and an Edge 2.3+ reachable
  from the machine over HTTP/2.
- An access key with *Read and write Build Cache data*.

## Why it is built this way

- **Each runner runs its own `dockerd`**, Docker-in-Docker with `--privileged`. The
  cache only sees the agent's local daemon during the job. A daemon shared with the
  host, a remote `DOCKER_HOST`, GitHub Actions `container:`/`services:`, Kubernetes pod
  agents and Testcontainers Cloud are invisible to it.
- **Every layer of the GUH image is under 95 MiB.** Each Docker layer is one cache
  entry. An image with any layer above the Edge's maximum artifact size (100 MiB by
  default) is **never restored**, and nothing fails. A single `COPY` of an Android
  Gradle user home is a multi-GB layer. [`docker/split-into-layers.sh`](docker/split-into-layers.sh)
  spreads the JDK, SDK and Gradle user home over as many layers as needed, in path
  order, so a changed dependency only changes the layers it lands in.
  - The base layer counts too. That is why the image uses a jlinked, compressed JDK on
    `ubuntu:24.04`: the stock JDK's `lib/modules` is a single ~130 MiB file.
  - The ~140 MiB wrapper zip is deleted. The wrapper only needs the unpacked
    distribution and its `.ok` marker.
  - `caches/<version>/generated-gradle-jars` is left out. Its `gradle-api` jar is a
    single file of about 190 MiB, so no layering fits it. Gradle regenerates it
    locally on the first build, even offline, which costs some build time.
  - If your Edge allows larger artifacts, raise `--layer-limit-mib`.
- **The tag is never `latest`.** Images tagged `latest`, or untagged, are not cached.
- **Docker only.** The CLI runs with `--autodetect=DOCKER --disable-setup-cache`. The
  Gradle user home lives in the image, so nothing else should move.
- **The build is `--offline` by default**, so it has to succeed from what the image
  carries.
- **CLI 1.10.0**, checksum-verified.

## Options

| Option | |
|---|---|
| `--project DIR` | build another Android project instead of nowinandroid |
| `--task` | what runners build (default `:app:compileDemoDebugKotlin`) |
| `--warm-task` | what warms the GUH image (default: `--task`) |
| `--layer-limit-mib N` | largest layer (default 95) |
| `--image-name NAME --restore-only` | replay a cold runner against a seeded cache image |
| `--store-on-restore` | let the restore runner store too, as CI would |
| `--skip-guh-build` | reuse the GUH image already in the local registry |

Slow uplink to the Edge? Each layer is one upload. `CLI_OPERATION_TIMEOUT` (default `PT20M`),
`CLI_OPERATION_CONCURRENCY` and `CLI_TIMEOUT` (default `PT90M`) are passed to the CLI.

Logs, the CLI's `--reporting-directory` output and the generated final Dockerfile go
to `.docker-run/<cache-image-name>/`.

## Reading the result

- The restore log lists each Docker image it loaded or skipped, with the reason.
  The restore runner should report `GUH image present: yes`.
- The seed's store log shows the layer files uploaded. A second store
  (`--store-on-restore`) should upload almost nothing: an image that is exactly the
  one the restore loaded keeps its cache entry without being exported again.
- **The registry is local.** A pull from a registry on the same machine is the best
  case for the control runner. Before drawing conclusions about savings, compare the
  restore against a pull from your real registry, with the Edge next to the agents.
- Restoring includes `docker load` of the whole image, which counts against the
  restore's `--timeout` and grows with the image size.
