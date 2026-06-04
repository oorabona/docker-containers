---
layout: post
title: "Multi-arch is a distributed-systems problem"
description: "A single-arch build from my laptop quietly overwrote a multi-arch manifest in my registry. Nothing broke for months — until an arm64 build went looking for a base that no longer had an arm64 in it. This is about what a tag actually is, why a registry is shared mutable state, and who should be allowed to write to one."
date: 2026-06-04 06:00:00 +0000
tags: [docker, multi-arch, oci, registry, ci, lessons-learned]
---

I run a small fleet of container images, and the thing about a fleet is that it isn't flat — the images build on each other. My `github-runner` and `web-shell` images don't start `FROM` Debian on Docker Hub; they start `FROM` *my* Debian, `ghcr.io/oorabona/debian:trixie`, built once so everything on top inherits a known base. A short chain. It works right up until one link changes shape under the others.

It broke on a single line:

```
#6 [internal] load metadata for ghcr.io/oorabona/debian:trixie
ERROR: failed to solve: no match for platform in manifest: not found
```

Only on arm64. The amd64 build of the same image, from the same `FROM`, was green. A base that existed, that I could pull, that half my builds were using *right now* — had no arm64 inside it. And it had been that way, quietly, for two months.

## A tag is not an image

The mental model that gets you here is that `debian:trixie` *is* an image. It isn't. On a modern registry a tag can point at a **manifest list** (Docker's name) or an **image index** (the OCI name): a small JSON document that says nothing about layers and everything about routing —

```
debian:trixie  (index)
 ├─ linux/amd64 → sha256:aaaa…
 └─ linux/arm64 → sha256:bbbb…
```

When buildx pulls `debian:trixie` on an arm64 runner, it reads that index, finds the `linux/arm64` entry, and pulls *that* digest. The tag is a pointer to a fan-out, and the fan-out is what makes one name work on two architectures.

My CI builds it the honest way: the amd64 leg and the arm64 leg build independently, each pushes its own single-arch image, and a final step assembles the index over them —

```bash
docker buildx imagetools create -t ghcr.io/oorabona/debian:trixie \
  ghcr.io/oorabona/debian:trixie-amd64 \
  ghcr.io/oorabona/debian:trixie-arm64
```

After that, `:trixie` is an index with two entries, and `:trixie-amd64` / `:trixie-arm64` sit alongside it as the leaves it points at. Three tags, one of them a router.

## How one arch went missing

Here's the shape of what happened. The index was correct — CI had built it. Then, at some point, someone ran a plain build on a laptop and pushed it straight to the canonical tag:

```bash
podman build -t ghcr.io/oorabona/debian:trixie .
podman push   ghcr.io/oorabona/debian:trixie
```

That laptop is amd64. `podman build` produces a single-platform image, and pushing it to `:trixie` doesn't *merge* anything — it overwrites the tag. The pointer that used to reference a two-entry index now references one amd64 image manifest. The arm64 leaf, `:trixie-arm64`, is still sitting there untouched. It's just that nothing points at it anymore.

The registry won't warn you about this. An index and a single image are both perfectly valid things to put at a tag; swapping one for the other is a normal push, not a conflict. Nothing is corrupt. The object at `:trixie` simply got *smaller*.

I only know it was a laptop because every build I publish writes a lineage record, and the one for that tag said:

```json
{ "github_actions": false, "runtime": "Podman" }
```

CI never sets those. That single line is the entire forensic trail — without it I'd have been left guessing at *how* a tag I thought CI owned had quietly gone single-arch.

## Why nobody noticed for months

Two properties combined to make this invisible, and they're the two that always make registry bugs invisible.

It's a **partial** failure. The downgraded tag still serves amd64 flawlessly. Every amd64 consumer kept building and shipping. The system was *mostly up* — which is the exact state that hides a bug, because nothing alarms and nothing pages.

And it's a **delayed** failure. The missing arm64 entry isn't an error until something reads it, and nothing reads it until something builds `FROM` it on arm64. I hadn't built these consumers on arm64 in a while. The write that broke it and the build that revealed it were separated by two months. By the time the lights came on, the cause was long out of the recent history and looked, briefly, like an arm64 problem. It wasn't. arm64 just happened to be the reader that finally dereferenced the gap.

## The registry is shared mutable state

This is a distributed-systems failure wearing Docker clothes.

A tag is a **mutable pointer**. The registry that holds it has **multiple writers** — my CI runners and my laptop both have push rights — and **no coordination** between them. Mutable shared state, concurrent writers, no locking: last write wins. That it took months between the two writes instead of milliseconds doesn't change the category; it just makes the race quieter and the debugging worse.

What makes the multi-arch version nastier than a normal last-write-wins clobber is that the writes aren't symmetric. CI writes an *index* — a fan-out. The laptop writes a *leaf* — a single image. When the leaf wins, the object doesn't just change value, it **loses structure**: a router becomes a destination. And because both are legal at a tag, nothing in the system treats the downgrade as wrong.

Distributed systems have one answer to concurrent writers corrupting shared state: **ownership**. One writer owns the authoritative object; everyone else writes to their own namespace.

## The fix, and the real fix

The immediate fix is boring, which is the point: re-run the CI build of `debian`. Both legs build, `imagetools create` reassembles the index over the two arch leaves, `:trixie` is a router again, and the consumers resolve their arm64 base on the next try. No surgery — the arm64 leaf had been there the whole time; it just needed something pointing at it.

The real fix is the ownership rule. CI owns the canonical tags. Local builds — which are legitimate; you need to build on your laptop — push to a namespace that can't collide with the authoritative one: an arch suffix, or a `:trixie-dev`, never the bare `:trixie`. A push guard that refuses a single-arch image onto a tag that currently resolves to an index turns the silent downgrade into a loud, immediate "no." The registry won't enforce that for you, so it has to live in the thing that does the pushing.

## What I'd tell past-me

- **A tag is a mutable pointer in shared state.** Treat a write to a canonical tag like a write to a shared database row — it needs an owner, not just push rights.
- **Multi-arch makes the write asymmetric.** An index and a single image are both valid at a tag. Last-write-wins will silently swap a router for a leaf, and the registry won't call it an error.
- **Partial-plus-delayed is the dangerous pair.** amd64 kept working, so nothing alarmed; the arm64 gap waited months for a reader. A periodic multi-arch consumer build is a cheap canary that makes the reader show up on *your* schedule, not chance.
- **Keep local tooling out of canonical tags.** CI writes `:trixie`; laptops write `:trixie-dev` or an arch suffix, enforced by a push guard — not by remembering.
- **Put an audit trail on your tags.** The only reason I could say "a laptop did this" instead of "somehow this happened" was one `runtime: Podman` line in a lineage record.

None of this was an arm64 bug, the same way [the last one wasn't either](/docker-containers/2026/06/01/arm64-three-bugs-none-about-arm64.html). arm64 just reads the entry nobody else was reading.
