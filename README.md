# Artifact Cache for a Docker image that carries the Gradle user home

Some CI setups don't warm the agent. Instead they bake the Gradle user home (dependencies,
wrapper distribution, transforms), the JDK and the Android SDK into a Docker image, and
every job runs `docker run <that image> ./gradlew …`. From
[Artifact Cache CLI 1.9](https://docs.develocity.ai/artifact-cache/current/concepts/docker-images/),
Develocity Artifact Cache caches the Docker images a job used, so that image can come
from the Edge instead of the registry.

This repository does exactly that on GitHub Actions, for a synthetic Android project:
30 modules in 5 layers, Hilt and unit tests. It was generated with
[ProjectGenerator](https://github.com/cdsap/ProjectGenerator) v0.7.1:

```
projectGenerator generate-project --type android --language kts --shape rectangle --modules 30 --layers 5 \
  --di hilt --classes-module 20 --generate-unit-test --develocity --project-name artifact-cache-docker-gradle-home
```

The project uses AGP 9.5.2, Kotlin 2.4.21, Gradle 9.9.2 and a Java 23 toolchain.

## Setup

| Repository secret | Value |
|---|---|
| `DEVELOCITY_URL` | Develocity server URL, e.g. `https://develocity.example.com` |
| `DEVELOCITY_ACCESS_KEY` | `host=key` form, e.g. `develocity.example.com=<key>`, with *Read and write Build Cache data* |

You also need Develocity 2026.3+ with the Artifact Cache entitlement, and an Edge 2.3+.
Until `DEVELOCITY_URL` is set, the build runs without the cache. Pull requests from forks
get no secrets.

## The workflow ([`build.yml`](.github/workflows/build.yml))

| Job | What it does |
|---|---|
| `guh-image` | Computes the image tag from the build scripts, version catalog, wrapper and build logic ([`docker/guh-tag.sh`](docker/guh-tag.sh)). If `ghcr.io/<repo>/guh:<tag>` doesn't exist yet, it builds and pushes it. |
| `build` | The Artifact Cache action restores Docker images. The job then reports whether the GUH image is already on the runner. It runs the build inside the image with `docker run`, `--offline` by default. The action's post step stores the image. |

The first build for a new tag pulls the image from GHCR and stores it. Later builds should
report **GUH image on the runner before `docker run`: yes** in the job summary, which
means it was loaded by Artifact Cache with no registry pull.

## Why it is built this way

- **A plain `docker run` step, not a job-level `container:`.** The cache only sees
  images pulled by the runner's own Docker daemon during the job. `container:`
  and `services:` pull before the restore and are invisible to it.
- **Every layer of the GUH image is under 95 MiB.** Each Docker layer is one cache
  entry. An image with any layer above the Edge's maximum artifact size (100 MiB by
  default) is **never restored**, and nothing fails. A single `COPY` of a Gradle user
  home is a multi-GB layer. [`docker/split-into-layers.sh`](docker/split-into-layers.sh)
  spreads the JDK, SDK and Gradle user home over as many layers as needed, in path
  order, so a changed dependency only changes the layers it lands in.
  - The base layer counts too. That is why the image uses a jlinked, compressed JDK on
    `ubuntu:24.04`: the stock JDK's `lib/modules` is a single ~130 MiB file.
  - The ~140 MiB wrapper zip is deleted. The wrapper only needs the unpacked
    distribution and its `.ok` marker.
  - `caches/<version>/generated-gradle-jars` is left out. Its `gradle-api` jar is a
    single file of about 190 MiB, so no layering fits it. Gradle regenerates it
    locally, even offline.
  - If your Edge allows larger artifacts, set `LAYER_LIMIT_MIB` for
    [`docker/build-guh-image.sh`](docker/build-guh-image.sh).
- **No local build cache in the image.** `caches/build-cache-*` from the warm build is
  left out, so the job compiles for real instead of reusing the warm build's outputs.
- **The tag is a dependency hash, never `latest`.** Images tagged `latest`, or untagged,
  are not cached.
- **Docker only.** The CLI runs with `--autodetect=DOCKER --disable-setup-cache`. The
  Gradle user home lives in the image, so nothing else should move.
- **A longer per-operation timeout.** Each layer is one upload. The CLI's 60s default
  can time out on a slow link to the Edge, and an image missing a layer is never
  restored.
- **Masked logs.** The job masks the Develocity host and its domain, which covers the
  Edge host the CLI prints. It uploads no CLI logs.

## Caveats

- **A single file above the Edge limit makes the image uncacheable**, because no
  layering can split one file. Robolectric's `nativeruntime-dist-compat` jar, which
  the unit tests pull in, is 157 MiB. Its transformed copy is 146 MiB. So the image
  is warmed with `assembleDebug` only, and the build runs `assembleDebug` by default.
  To include unit tests, raise the Edge's maximum artifact size above ~160 MiB. Then
  build the image with `WARM_TASK="assembleDebug testDebugUnitTest" LAYER_LIMIT_MIB=160`.
  A Gradle-user-home Artifact Cache hits the same limit for that jar.

- GitHub-hosted runners are not next to your Edge. Restore time therefore includes
  wide-area transfer and `docker load` of the whole image. Treat the timings as proof
  that the mechanism works, not as a savings figure.
