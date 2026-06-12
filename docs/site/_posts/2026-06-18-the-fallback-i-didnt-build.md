---
layout: post
title: "The fallback I didn't build"
description: "A build died because a base image wasn't mirrored into our registry — and it refused, by design, to go fetch it from Docker Hub. The fallback would have worked. That's exactly why it isn't there."
date: 2026-06-18 06:00:00 +0000
tags: [ci, docker, github-actions, supply-chain, reliability, lessons-learned]
---

A build failed with an error that, the first time I saw it, felt like the pipeline being precious:

```
::error::GHCR base cache is configured for this container but no cache image is
accessible — Docker Hub fallback is disabled (egress containment). The GHCR base
cache is seeded by the daily upstream-monitor sync; trigger that workflow to seed it.
```

Nothing was wrong with the code. The image just couldn't find its base layer in our own registry, and instead of doing the obvious thing — pulling it from Docker Hub, where it has always existed — it stopped and told me to go seed a mirror first. My instinct was to delete the check. The base image is *right there* on Docker Hub. Why make me jump through a hoop?

I'm glad I read the rest of the message before I did.

## "Just pull it from Docker Hub"

Every base image we build on is mirrored into our own registry (GHCR) by a daily job. Builds pull the base from that mirror, never from Docker Hub directly. When the mirror is missing an image — first build of a new base, or a sync that hasn't run yet — the build doesn't fall back. It fails closed.

The obvious objection is the one I had: the fallback is free. Docker Hub has the image. One line of "if the mirror misses, pull upstream" and the build is green again. So why is the line deliberately *not* there?

## What the fallback would have given me

Two things, both quiet, both bad.

The first is a number. Docker Hub meters anonymous pulls — at the time of writing, on the order of a hundred per six hours per IP; check their current limits, because this is exactly the kind of figure they revise. A CI fleet shares a small pool of egress IPs, and a busy afternoon of builds burns through that allowance fast. The first time it bit us, it bit in the middle of a release — half the matrix green, half of it `429 Too Many Requests`, and no pattern to it because the pattern was "whoever pulled last." A Docker Hub fallback doesn't remove that failure mode; it *arms* it. It waits until you're under load — which is exactly when you reach for a fallback — and then rate-limits you anyway. Pinning the pull by digest doesn't save you here: the rate limit counts requests, not tags.

The second is subtler, and it's the one a digest *does* fix. The mirror stores a base by digest — a specific, immutable image. Docker Hub also gives you a *tag*, and a tag is a moving target: `:3.20` today is not byte-for-byte `:3.20` next week. A fallback that pulls the tag builds you against whatever that tag resolved to at that minute. It would succeed. It would also, silently, build a different image than the one you mirrored and tested — and you'd never know, because the only signal is "the build went green."

So to be fair to the fallback: a *digest-pinned* one would close the drift hole. What it can't close is the rate limit, and what it always adds is a second resolution path — Hub-shaped, exercised only under failure, tested least of all. That's the shape of the fallback I didn't build: a code path that triggers exactly when things are already going wrong, and whose best case is a green build on a throttled or drifted base. At its worst it doesn't fail. It lies.

## The cost, paid where I can see it

Fail-closed isn't free. The bill is real: a build can stop because a precondition — the seeded mirror — isn't there yet, and someone has to seed it before the build runs. That's friction. The first build of a new base needs a sync first. A human occasionally has to trigger a job and wait.

But look at where the cost lands. It lands **up front**, **loudly**, and with **the fix written into the error message** — "seeded by the daily upstream-monitor sync; trigger that workflow." The failure is its own runbook. You pay once, visibly, before anything ships.

There's a sharper version of the bill, and it's only fair to name it: fail-closed makes the seed job a hard dependency. If that job is healthy, missing a base costs you one `workflow_dispatch` and a short wait. If the seed job itself is broken — flaky upstream, registry outage — then "go seed the mirror" is advice you can't take, and the build stays red until someone fixes the seeder. Fail-closed only pays off if you watch the thing you're now depending on: the mirror sync gets its own alerting, and a human can run it by hand. Without that, you haven't removed the failure mode, you've just moved it one box upstream.

The fallback, by contrast, would have moved the cost *downstream* and turned the lights off on it: no error to read, no runbook, just a release built on a base that was rate-limited into something stale or drifted out from under you, discovered weeks later when you try to reproduce a build and can't. Same cost. Paid in the dark, with interest.

## What I'd tell past-me

Fail-closed was the right call for *this* pipeline — a slow release cadence that can absorb a seeding wait, and a threat model where a base image quietly drifting matters more than a build arriving late. Flip those constraints and the arithmetic flips: a team shipping every few minutes, or one that would rather serve something slightly stale than nothing at all, may land elsewhere. The choice is contextual. The reasoning is what travels.

- **A fallback is a second code path you take when the first one failed** — which is to say, the least-tested path in your system, exercised at the worst possible moment. Treat adding one as adding risk, not removing it.
- **"Graceful degradation" that returns a wrong answer isn't graceful.** If the degraded path can succeed while being wrong — a throttled pull, a drifted tag — it's not a safety net, it's a trapdoor with a rug over it.
- **Fail closed, and make the failure its own runbook.** A precondition that isn't met should stop the build, name what's missing, and say how to fix it. The cost of fail-closed is friction you can see; the cost of fail-open is a silence you'll pay for later.
- **Pin by digest, mirror what you pin.** The reason the fallback could lie is that the tag moves. Bind to the immutable thing, and the question "did I build on what I think I built on?" stops being a question.
