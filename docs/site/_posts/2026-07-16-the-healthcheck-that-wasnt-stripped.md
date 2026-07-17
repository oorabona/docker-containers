---
layout: post
title: "Docker sees your HEALTHCHECK. Podman might not."
description: "The same published image, inspected with real Docker Engine and with Podman, gives two different answers for whether it even has a HEALTHCHECK. Both tools are reading identical bytes. The divergence runs from the build tool all the way through the reader, and it's worth understanding before it costs you a debugging session."
date: 2026-07-16 06:00:00 +0000
tags: [docker, podman, oci, buildkit, buildah, supply-chain, lessons-learned]
---

`docker inspect --format '{% raw %}{{.State.Health.Status}}{% endraw %}'` came back empty on a `tor` container pulled straight from our own registry — not `unhealthy`, not `starting`, nothing, as if the image had never declared a `HEALTHCHECK` at all, despite the Dockerfile declaring one in plain sight. I went looking for what strips it. The honest answer turned out to be: nothing does, and also, it depends entirely on which tool you ask.

## Same bytes, two different answers

The image in question is built by `docker buildx bake --push` on the `docker-container` driver — this fleet's standard path for every `latest`-tagged Linux image. BuildKit adds a minimal provenance attestation to every push by default on that driver, no flag required, and that default reshapes the published artifact: the attestation is itself a small manifest that has to sit alongside the real image, so BuildKit packages both inside an OCI image index rather than a single Docker-format manifest. [Docker's own docs](https://docs.docker.com/build/metadata/attestations/) confirm attestations "attach to images as a manifest in the image index," and `oci-mediatypes=false` does nothing to opt back out once attestations are on.

Pull that image with **real Docker Engine** and inspect it, and `Healthcheck` is right there — full command, interval, retries, all of it. Run the container and its live health status genuinely reports `healthy` after the check executes. Pull the identical bytes with **Podman** and ask the same question, and `Healthcheck` doesn't exist as far as the tool is concerned: not an empty value, an outright type error — `can't evaluate field Healthcheck in type *v1.ImageConfig`. `skopeo inspect --config`, without `--raw`, does the same thing more quietly: no error, just no `Healthcheck` key in the output, on an image that — checked with `--raw` on the same command — has the field completely intact in the raw bytes.

Both tools are reading the exact same registry blob. One sees the field. One doesn't. That's not a bug in either of them — it's two ecosystems that made a different call about a field the OCI spec itself won't commit to.

## What the spec actually says

`Healthcheck` isn't absent from the OCI Image Specification — [config.md](https://github.com/opencontainers/image-spec/blob/v1.1.1/config.md) lists it as an optional property. But it's marked *reserved*, and the [compatibility matrix](https://github.com/opencontainers/image-spec/blob/v1.1.1/media-types.md) says plainly what that means: "`.config.Healthcheck`: only present in Docker, and reserved in OCI." The name is reserved in the schema; the behavior isn't defined. Nothing in the spec tells a conformant reader what to *do* with the field, which leaves every tool free to make its own choice — carry it through anyway, or type its own config parsing against the strict OCI shape and never see it.

Docker made the first choice. Its own [`docker-image-spec`](https://github.com/moby/docker-image-spec) defines `DockerOCIImageConfig` as the base OCI `ImageConfig` plus a `DockerOCIImageConfigExt` — `Healthcheck`, `OnBuild`, `Shell` — bolted on top. dockerd and the `docker` CLI are built around that extended type consistently, so it doesn't matter whether the manifest wrapping the config is Docker-format or OCI-format: the config itself still gets parsed with the type that knows about `Healthcheck`. That's confirmed, not inferred — a real Docker Engine 28.0.4 run against this fleet's actual published image shows the field intact and the healthcheck actually running.

Podman's `containers/image` library made the other choice: its Go type for image config is the plain OCI `ImageConfig`, with no `Healthcheck` field at all. It's not that Podman looks for the field and doesn't find it — its own data structure has no slot to put it in, which is why asking for it is a type error rather than an empty result.

## It's not only a reading problem

The divergence isn't confined to how images get *read* — it goes back to how they get *built*, on the Podman side. Buildah, the tool underneath `podman build`, supports building in either Docker or OCI format via `--format` (or `BUILDAH_FORMAT`). Building the identical `HEALTHCHECK`-bearing Dockerfile both ways:

```
$ podman build --format oci -t test-oci .
...
level=warning msg="HEALTHCHECK is not supported for OCI image format and will be ignored. Must use `docker` format"

$ podman build --format docker -t test-docker .
...
(no warning)
```

Inspecting the raw config of each confirms the warning means exactly what it says: the OCI-format build's config has no `Healthcheck` key anywhere — the instruction survives only as a cosmetic line in the build history, the same fate a stripped field would have. The docker-format build's config has the real thing. Buildah isn't failing to carry the field through by accident; in OCI mode it deliberately never writes it, and tells you so.

So there are two independent divergences stacked on top of each other, and BuildKit and Buildah land on opposite sides of both:

| | writes `Healthcheck` into OCI-format output | reads `Healthcheck` back out |
|---|---|---|
| **BuildKit** / **dockerd** | yes, unconditionally | yes, via the extended type |
| **Buildah** / **Podman** | no, `--format oci` explicitly drops it (warns) | no, the OCI-only type has no field for it |

This fleet's images are built with BuildKit, not Buildah, so the *build*-side gap doesn't touch them directly — but the *read*-side gap does, for anyone who inspects or runs those images with Podman instead of Docker.

## Where this actually bites

This fleet's own CI publishes and — more importantly — *consumes* these images with real Docker Engine, and that path is unaffected: verified directly against a live GitHub Actions run, `Healthcheck` is visible and the healthcheck genuinely executes. The gap only shows up wherever Podman gets involved somewhere in the chain — a rootless-Podman dev machine, a RHEL or Fedora host where `podman` is the default `docker`, a `buildah`-based custom build, a `skopeo`-based inspection script that forgets `--raw`, or `podman-compose` standing in for `docker compose`.

That last one is concrete enough to have caused a real, narrow bug in this repo: `examples/web-terminal`'s Compose stack gates `openresty` on `web-shell: condition: service_healthy`, with no Compose-level override, trusting the image's own `HEALTHCHECK`. On real Docker Engine + real Compose that resolves fine. On a Podman-backed Compose it wouldn't resolve at all, and the stack would refuse to start. The fix is a Compose-level `healthcheck:` override on `web-shell` that mirrors the Dockerfile's own check — cheap, harmless on Docker where it's redundant, and load-bearing on Podman where it isn't.

## Confirming there's no flag for this

The instinct is to go looking for the setting that fixes it. [docker/buildx#3047](https://github.com/docker/buildx/issues/3047) asks BuildKit's maintainers directly whether attestations could be left out of the image index, and gets a clear no, by design — attestations stay in the index so other tooling can find them, closed as working as intended. [moby/buildkit#6070](https://github.com/moby/buildkit/issues/6070) is a separate, still-open request asking BuildKit to document the mediatype coupling somewhere instead of leaving people to rediscover it. And [opencontainers/image-spec#749](https://github.com/opencontainers/image-spec/issues/749) is the spec project's own tracking issue asking for OCI-defined *semantics* for that reserved slot, rather than leaving each toolchain to decide for itself — open since 2018, still unresolved.

Until that lands, there's no setting that makes Podman parse `Healthcheck` the way Docker does, and no setting that makes Buildah's OCI-format writer include a field OCI itself won't define. The two ecosystems are each being internally consistent with a different, equally defensible reading of a spec that punted on the question.

## What I'd tell past-me

- **"Docker inspect" and "an OCI-mediatype image" are each doing more work in that sentence than they look like.** Which `docker` you're actually running, and which image format your build tool chose, are two separate variables — collapsing them into "the pipeline" is how a two-tool divergence gets misread as a one-cause bug.
- **A field a spec merely *reserves* is a coin flip, not a guarantee, and every tool in the chain gets to flip it independently.** OCI reserving `Healthcheck` without defining it means BuildKit, Buildah, dockerd, and `containers/image` were each free to make their own call — and they didn't all make the same one.
- **Verify against the reader that actually matters, not the one that's locally convenient.** A dev sandbox and a CI runner can silently be different tools wearing the same `docker` alias; checking a claim against production infrastructure once is worth more than checking it against a laptop three times.
- **A default that's actively running in production (real Docker, real CI) doesn't need defending against a tool that was never in that path.** The fix that matters is the one narrow surface where Podman genuinely touches this fleet's stacks, not a fleet-wide change nothing here required.
