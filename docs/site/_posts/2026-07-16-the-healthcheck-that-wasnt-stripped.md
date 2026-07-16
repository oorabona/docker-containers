---
layout: post
title: "The healthcheck that wasn't stripped"
description: "Every bake-built image's HEALTHCHECK was invisible to docker inspect, despite every Dockerfile declaring one correctly. The obvious explanation — BuildKit strips it — turned out to be wrong. What's actually happening is more interesting, and it's not a bug."
date: 2026-07-16 06:00:00 +0000
tags: [docker, oci, supply-chain, debugging, lessons-learned]
---

`docker inspect --format '{% raw %}{{.State.Health.Status}}{% endraw %}'` came back empty. Not `unhealthy`, not `starting` — nothing, as if the container had never had a `HEALTHCHECK` in the first place. I was looking at a `tor` container whose Dockerfile declares one in plain sight, running an image pulled straight from our own registry a few minutes earlier. The obvious hypothesis formed immediately: something in our push pipeline is stripping the field. I was wrong about that, and the actual answer turned out to matter more than the bug I thought I'd found.

## The hypothesis, and why it looked right

Every Linux image in this fleet gets pushed the same way: `docker buildx bake --push`, on the `docker-container` driver. (Windows builds are the one exception — buildx bake doesn't support them, so they go through a separate `--load` + plain `docker push` path that, as I'd later confirm, doesn't pick up default attestations at all.) Nothing in the bake command asks for attestations — but that's not the same as attestations being off. BuildKit adds a minimal provenance attestation to every push by default on this driver, no flag required. That default is the kind of thing that changes how an image gets packaged under the hood — new manifests, new mediatypes, new layers of indirection. "One of those side effects is eating the Healthcheck field" was a completely reasonable first guess, and it fit the evidence: `sslh`, built through the identical pipeline, showed the exact same symptom. Fleet-wide across every Linux image, one shared cause, a shape I'd seen before in this codebase.

## The test that said otherwise

Before writing that up as a bug report, I built the same `HEALTHCHECK`-bearing Dockerfile twice on the same driver — once with the default provenance attestation left on, once with `--provenance=false` — and diffed the resulting image configs at the byte level.

They were identical. Same digest. `Healthcheck` present in both, word for word.

That single result killed the "BuildKit strips it" theory outright. Nothing in the build was throwing the field away. Which meant the actual question wasn't "why is this missing" — it was "why does it look missing when it isn't."

## What's actually happening

`skopeo inspect --config` on the pushed image showed no `Healthcheck` key. The raw config blob, fetched separately, had it. The gap was entirely in how something *read* the config, not in what got written.

A provenance attestation is itself a small manifest, and it has to live somewhere alongside the image it's describing. The place BuildKit puts it is an OCI image index: a container of manifests, where the real image and its attestation sit as siblings — [Docker's own docs](https://docs.docker.com/build/metadata/attestations/) confirm attestations "attach to images as a manifest in the image index." That structural requirement pulls the image's own manifest into OCI mediatype along with everything else in the index — confirmed by testing `oci-mediatypes=false`, which does nothing to stop it; once attestations are on, OCI mediatypes aren't optional.

`Healthcheck` isn't entirely absent from the OCI spec, either — [config.md](https://github.com/opencontainers/image-spec/blob/v1.1.1/config.md) lists it as an optional property, but marks it *reserved*, and the [compatibility matrix](https://github.com/opencontainers/image-spec/blob/v1.1.1/media-types.md) is blunter about what that means in practice: "`.config.Healthcheck`: only present in Docker, and reserved in OCI." The name is in the schema; the semantics aren't — nothing in the spec tells a reader what to *do* with that field, so a spec-conformant reader is free to carry it through without ever acting on it. Any tool that treats OCI as the format of record and Docker's `Healthcheck` as an out-of-scope Docker-ism — skopeo's normalized inspect, containerd, and by the same mechanism other spec-conformant runtimes — has no obligation to wire it up. Silently. The bytes are still sitting in the JSON; nothing downstream is required to look for them. The instruction survives only as a cosmetic string in the image's build history, which nothing reads at runtime.

That's also the answer to the question the opening symptom actually asked: the container wasn't showing `starting` or `unhealthy`, it was showing nothing, because the Docker daemon itself instantiates a container's healthcheck from the same OCI-schema-shaped config it just pulled — it doesn't reach into `history[].created_by` to recover behavior for a field its own schema never gave semantics to. So this isn't only an inspection-tooling blind spot. The container genuinely never gets a healthcheck wired up at all.

Nothing was stripped. A schema-conformant reader was doing exactly what a schema-conformant reader should do with a field the schema reserves but never defines: ignore it.

## Confirming there's no third option

The instinct here is to go looking for the flag that fixes it. I did — and the upstream trail is illuminating, if not quite as tidy as I first assumed. [docker/buildx#3047](https://github.com/docker/buildx/issues/3047) asks BuildKit's maintainers directly whether attestations could be left out of the image index, and gets a clear answer: no, by design — attestations stay in the index so other tooling can find them, and "BuildKit does not support any other distribution method for attestations that is outside of the build result." No opt-out, closed as working as intended. [moby/buildkit#6070](https://github.com/moby/buildkit/issues/6070) is a separate, still-open request asking BuildKit to actually document this mediatype coupling somewhere instead of leaving people to rediscover it — evidence this trips up more than just me. And [opencontainers/image-spec#749](https://github.com/opencontainers/image-spec/issues/749) is the spec project's own tracking issue asking for OCI-defined *semantics* for that reserved slot — not a new field, since the schema already reserves the name, but an actual behavior spec-conformant tools would be obligated to honor. Open since 2018, still unresolved.

The choice is genuinely binary: drop the default provenance attestation and get Docker mediatype back, or keep it and accept that `Healthcheck` is invisible to anything that reads the config strictly. There's no flag combination that gets both, and there isn't going to be one until that reserved field gets real OCI semantics. What makes this an easy call is that it isn't really a deliberate trade this fleet made — nobody opted into BuildKit's default provenance attestation, it's just what the `docker-container` driver does unless you explicitly turn it off with `--provenance=false` or `BUILDX_NO_DEFAULT_ATTESTATIONS=1`. Fighting a free default to restore a field almost nothing in our own tooling checks isn't worth the churn — especially next to what that default is quietly buying us: real, if currently unsigned, provenance metadata on every image, ahead of the signed `actions/attest-build-provenance` step already on the roadmap to formalize it. SBOM attestation is a separate, already-signed mechanism (`actions/attest-sbom`, out-of-band via the GitHub Attestations API) — it doesn't touch the image's own manifest index and isn't part of this trade-off at all.

## Checking the actual damage

A fleet-wide root cause doesn't automatically mean fleet-wide breakage, and it's worth checking rather than assuming. Our own end-to-end tests already tolerate a missing health status — they were written defensively before this was ever diagnosed, which is a coincidence I'll take. Of the stacks in this repo that gate a service on `depends_on: condition: service_healthy`, most already define their own Compose-level `healthcheck:`, which overrides whatever the image itself declares — unaffected by any of this. One stack didn't have that override and would have genuinely failed to start. That's a real, narrow bug, and it got its own fix rather than riding along as a footnote on an issue that turned out to be a documented, unfixable trade-off rather than a defect.

## What I'd tell past-me

- **A shared symptom across two containers is evidence of a shared cause — it's not evidence of *which* cause.** Both `tor` and `sslh` going through the same broken-looking pipeline pointed at the pipeline; it took an actual byte-level diff to find out the pipeline wasn't the part that was broken.
- **When a field looks stripped, check whether it's actually missing before assuming who removed it.** The write side and the read side are different code, maintained by different projects, and "invisible to this one tool" is a much weaker claim than "absent from the bytes."
- **A root cause confirmed doesn't mean the blast radius is what you assumed.** The honest next question after "found it" is "so what actually breaks," not "how do I fix it everywhere" — the second one wastes effort on inputs the first one would have ruled out.
- **Some findings are correctly closed as "won't fix."** Not every root cause has a repair; some are the visible edge of a default that isn't worth fighting. Writing that down clearly is a more useful outcome than leaving an issue open waiting for a fix that isn't coming.
