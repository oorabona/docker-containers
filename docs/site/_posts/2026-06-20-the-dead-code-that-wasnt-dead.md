---
layout: post
title: "Narrowed is not dead"
description: "After migrating the fleet to a new build engine, I went to delete the old path's now-obsolete code. The problem: a partial migration doesn't kill the old code. It narrows its caller list — and from where the migration leaves you standing, narrowed looks exactly like dead."
date: 2026-06-20 06:00:00 +0000
tags: [ci, docker, refactoring, migration, architecture, lessons-learned]
---

Finishing a migration comes with a promise you make to yourself: once the new path is the default, you get to delete the old one and collect the cleanup dividend. After moving every Linux container onto `docker buildx bake`, I had two deletions queued. Both were wrong, and they were wrong in a way I keep seeing dressed up as carelessness when it's actually something more specific.

## "Default" is not "only"

Here's the trap, stated plainly so I stop walking into it: a responsible migration is *partial on purpose*. You move the cases the new engine handles and leave the old path running for the ones it doesn't. Bake took the Linux-latest containers. It did not take the Windows images — bake is Linux-native. It didn't take the extension build, or the retained older versions that still get rebuilt on the old rails. The flat matrix wasn't reduced to a legacy husk; it stayed the current answer for a real slice of the fleet.

So the day bake became the *default*, I quietly re-read "default" as "only" and mentally booked the entire old path as dead. It wasn't. Its caller list had narrowed. That is a completely different fact, and it looks identical from a distance.

## Narrowed looks exactly like dead

My second queued deletion was the base-image handoff: the old path builds a base, pushes it to a cache registry, and the consumer build pulls it back. A bake graph keeps the base in the build's own context and hands it over in memory — no round-trip. Obsolete, obviously.

Except the round-trip is still the path for everything bake didn't take. Windows, the extension pipeline, the retained versions — they all still do the handoff, still lean on the cache probe I was about to delete. The caller count wasn't zero. It was *small, and entirely in the long tail I never look at* — the containers that only rebuild when something upstream moves, the ones nobody watches until they're red.

That's the whole problem in one sentence: **from the new path, a narrowed caller set and an empty one are indistinguishable.** The migration moved my attention to bake, and from there the old handoff has no visible users — every build I actually watch goes through bake now. The callers that remain are real, but they're off-screen. "Looks dead" was a statement about my vantage point, not about the code.

## The other direction, which is worse

The first queued deletion was sneakier, and it's the failure mode that actually deletes load-bearing walls. I'd remembered the flat matrix carrying build-ordering logic — base before consumer — and bake's DAG derives that order itself, so the old ordering had to be dead.

I went to delete it and found it wasn't ordering logic at all. It was a *variant* precedence: within a single container, build the plain variant before the ones that extend it. Bake didn't make that redundant, because bake orders **containers** — base container before consumer container — and this ordering is one level down, *inside* a container, on an axis the container graph doesn't model. Different problem, still live, used by the bake path too.

I hadn't found dead code and mis-scoped it. I'd found live code and misremembered what it *was*. That's the dangerous direction: mistaking dead-for-live just leaves you some cruft; mistaking live-for-dead deletes the wall. And the only thing standing between me and that `rm` was going to look at the callers instead of trusting the picture in my head.

## What I'd tell past-me

- **A migration narrows caller lists; it doesn't empty them.** "We moved to X" never means "all the pre-X code is gone" — it means the old path now serves a smaller set. The dividend is only the code with *zero* remaining callers, and that set is almost always smaller than the migration's headline suggests.
- **Count callers across everything the old path still serves** — every platform, version, and variant, not just the ones in front of you. The migration put your attention on the new path; the surviving callers are, by construction, the ones you've stopped looking at.
- **Treat "looks dead" as unproven until you've counted callers on the old path.** Narrowed and dead are the same shape from where the migration leaves you standing; the grep is the only thing that tells them apart. Prove zero before the `rm`.
- **Deleting live code you misread is the expensive mistake; the cheap one is leaving cruft.** When you're not sure which you're holding, bias toward the cheap mistake — a refactor that removes nothing is recoverable, a deletion that removes a wall is an incident.
