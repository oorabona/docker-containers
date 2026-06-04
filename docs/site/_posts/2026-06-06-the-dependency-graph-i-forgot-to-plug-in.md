---
layout: post
title: "The dependency graph I forgot to plug in"
description: "My images build on each other, but changing a base only rebuilds the base — never the things on top of it. The fix turned out to be a dependency graph I'd already written, tested, and wired into exactly one of the two places that needed it."
date: 2026-06-06 06:00:00 +0000
tags: [ci, docker, monorepo, dependency-graph, github-actions, lessons-learned]
---

Several of my container images don't build from scratch — they build `FROM` one of the others. `github-runner` and `web-shell` sit on top of my own `debian`; `wordpress` sits on top of my own `php`. A little graph: a couple of bases, a few consumers hanging off them.

The build system doesn't know that graph exists.

I found that out the way you find out most things about a build system — by it not doing something I assumed it did. I'd changed `debian`, pushed, watched CI rebuild `debian`, and moved on. `github-runner` and `web-shell` — both of which start `FROM` that exact image — didn't rebuild. Not that run, not the next one. They just kept serving whatever they'd last been built against, on top of a base that had since moved.

## What "detect what changed" actually does

The job that decides what to build maps changed files to containers, and the mapping is as literal as it gets:

```bash
container="${file%%/*}"   # top-level dir of the changed path
```

Touch `debian/Dockerfile`, you get `debian`. Touch `web-shell/config.yaml`, you get `web-shell`. One file, one container, no second thought. It's a correct answer to the question "which container's *own files* changed" — and a completely wrong answer to the question I actually had, which was "what needs rebuilding now that `debian` did."

A monorepo of images that build on each other only stays correct if you ask the second question. The first one treats every container as a leaf. Mine aren't leaves — some are routers with things hanging off them.

Two ways to get hurt here. A base can change shape — drop a transitive package, lose an architecture — and the consumer that builds on it fails; but because it wasn't in the build matrix, the failure doesn't show up when the base changes. It waits, deferred, until something rebuilds the consumer for an unrelated reason, then detonates looking like a bug in the consumer. Or a base gets a CVE patch, rebuilds cleanly, and the consumers — which would happily pick up the fix — just don't, because nothing told them to. No error, no signal, indefinitely.

## The part that stung

So I went to add the obvious thing: expand a changed container to its consumers, so a `debian` change pulls `github-runner` and `web-shell` into the build along with it. A reverse-dependency walk. I started sketching how to parse every `FROM` and `base_image` across the fleet to build the edge list.

Then I found `helpers/dependency-graph.sh`. In my own repo. With a function called `_depgraph_get_consumers`. With tests. Already merged.

I'd written it months earlier — for the *other* place that needs this graph. Once a day a job walks every image and asks the registry whether the base it was built on has drifted; when it has, it opens a rebase PR. That detector classifies containers into bases and consumers, and it does it by calling `_depgraph_get_consumers`. The graph was real, it was correct, it was covered by tests, and it was answering "what depends on `debian`?" every single day.

It just answered that question for *drift detection* and nowhere else. The build-change detector — the thing that decides what a push rebuilds — never asked. The same question had a working implementation sitting twenty files away, and the path that most needed it walked right past.

## Wiring it where it was missing

The fix isn't writing a dependency graph. It's calling the one that exists from the second place that needs it. After the change detector resolves the directly-changed containers, expand each through `_depgraph_get_consumers` and fold the results into the build set. A `debian/` change becomes `{debian, web-shell, github-runner}`; a `php/` change becomes `{php, wordpress}`.

The important property is that the edges come from the actual `FROM` lines and `base_image` config, not a hand-maintained list. A declared `consumers:` field would have been faster to write and would have rotted the first time someone added a consumer without updating the base — a dependency list that lies is worse than none, because you trust it.

That closes the loud failure mode — a base change now rebuilds its consumers in the same run, so a base that breaks them breaks loudly, immediately, attributed correctly. The quiet one — staleness between rebuilds — is already half-covered by the daily drift job; closing it fully means having the base's *successful publish* re-queue its consumers, which is the same graph again, called from a third place.

## What I'd tell past-me

- **In a monorepo of images that build on each other, the build graph is a graph.** Change detection that maps files to containers one-to-one is correct for leaves and wrong for everything with something on top of it. It has to walk the edges.
- **Derive the edges, don't declare them.** A `FROM`-derived graph can't drift from reality. A hand-maintained `depends_on:` list can, and you won't notice until it silently skips a rebuild.
- **Before you build infrastructure, grep for it.** I was about to write a reverse-dependency walker that already existed in my own repo, tested, used daily — for one of the two callers that needed it. The expensive part wasn't the graph. It was noticing I'd only plugged it in once.
- **A base change that doesn't rebuild its consumers is a staleness bug on a delay fuse** — exactly the kind that surfaced when [a base quietly lost an architecture](/docker-containers/2026/06/04/multi-arch-is-a-distributed-systems-problem.html) and the consumers on top of it found out months later.

The graph was the easy part. I'd done it. I'd just done it for the job that runs at 6 AM and not for the one that runs on every push.
