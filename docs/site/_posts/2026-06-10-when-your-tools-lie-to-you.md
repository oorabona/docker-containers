---
layout: post
title: "When your tools lie to you"
description: "In one CI cleanup, three tools told me things that weren't true: a run status that contradicted itself, a cancel that did nothing, and a review gate that refused code I hadn't written. None were broken. Each was answering a slightly different question than the one I thought I'd asked."
date: 2026-06-10 06:00:00 +0000
tags: [ci, github-actions, git, tooling, debugging, lessons-learned]
---

I had a stuck CI run to clear and a fix to ship behind it. Routine cleanup. Over the next hour, three different tools told me things that were false, and I believed each one a little too long. None of them was broken. Each was a faithful answer to a question I didn't realize I was asking.

## Lie #1: the run status that wouldn't hold still

A push run on `master` was sitting in the way, holding a concurrency lock so the next run couldn't start. I checked on it:

```bash
gh run view <id> --json status,jobs
```

It said `in_progress`, with jobs ticking along. A minute later, `completed`. A minute after that, `in_progress` again, jobs un-completing. The status was contradicting itself across reads that were seconds apart.

`gh run view` reads a derived, cached projection of the run. Under load it lags and flickers — it's eventually consistent, and "eventually" was visibly losing to my refresh key. The authoritative source is the REST endpoint:

```bash
gh api repos/<owner>/<repo>/actions/runs/<id> --jq '{status, conclusion, updated_at}'
```

That one didn't flicker. It said `queued`, `updated_at` frozen at a timestamp from an hour earlier. The run wasn't progressing at all — it had never been assigned a runner. The porcelain had been inventing job progress; the plumbing told me the truth. When two views of the same object disagree, the cached one isn't a second opinion. It's noise.

## Lie #2: the cancel that did nothing

Fine — kill it and move on:

```bash
gh run cancel <id>
```

Returned success. The run stayed `queued`. Stayed `queued`. Kept holding the lock for another hour while I waited for it to die.

`gh run cancel` signals the running jobs to stop. This run had no running jobs — it was `queued`, never scheduled, nothing to signal. The cancel succeeded at delivering a signal to zero recipients, which is to say it did nothing, and reported that nothing as success. A queued run that won't start also won't soft-cancel; there's no process to interrupt.

What actually lands is force-cancel, which tears the run down at the control-plane level regardless of whether anything's running:

```bash
gh api -X POST repos/<owner>/<repo>/actions/runs/<id>/force-cancel
```

That killed it in seconds. The lock released, the queued run behind it started. "Success" from the soft cancel had meant "the message was sent," not "the thing you wanted happened" — and those are only the same when there's someone listening.

## Lie #3: the review gate that refused code I hadn't written

With the queue clear, I pushed the actual fix — a four-line change to one workflow file — through an orthogonal review gate before merging. It refused. The findings were about base-image staleness and digest freshness in a registry-sync helper. I hadn't touched that helper. It had been merged days earlier, in a different change.

The gate wasn't hallucinating. It was reviewing exactly what it was handed — and it had been handed the wrong diff. The diff it reviews comes from:

```bash
git diff master...HEAD
```

Three dots. `A...B` doesn't diff `A` against `B`; it diffs the **merge base** of the two against `B` — everything on my branch since it last diverged from `master`. And my local `master` was stale: the things I'd merged in the last few days went in as squash commits on the remote, but my local `master` ref had never caught up. So the merge base was way back, and the three-dot range swept in every commit since — including the registry-sync change from days ago that was already live.

The gate reviewed all of it and refused on the part that wasn't mine. Fixing it wasn't arguing with the gate; it was fixing the diff. Update local `master` to the remote, rebase the branch onto it so the range is just my four lines, re-run. Clean. The tool had been honest about a diff that wasn't the diff I thought I was showing it.

## The thread

Every one was a tool faithfully answering a question subtly different from the one in my head.

`gh run view` answered "what does the cache say?" when I needed "what is true?" `gh run cancel` answered "did the signal send?" when I needed "did it stop?" `git diff A...B` answered "what's changed since the merge base?" when I thought I'd asked "what's in my change?" None lied in the sense of being wrong. They lied in the sense every map does — by being a representation, with a contract I'd half-remembered.

The failure that fails first in an incident isn't usually the system. It's your model of what your tools are telling you. The map is not the territory.

## What I'd tell past-me

- **When two views of the same thing disagree, find the authoritative one.** `gh api` over `gh run view`. The plumbing doesn't flicker; the porcelain does. A self-contradicting status isn't a second opinion to average — it's a cache to stop trusting.
- **"Success" from a command means the command succeeded, not that the world changed.** A soft cancel that signals zero jobs reports success and does nothing. Check the state you wanted, not the exit code you got. Know that force-cancel exists for the run that won't die.
- **Know `..` from `...`.** A review or CI step that diffs `A...B` shows everything since the merge base, not your change — and a stale local base silently widens that range. If a gate flags code you don't recognize, suspect the diff base before the finding.
- **In an incident, audit your tools first, the system second.** I lost two hours to three tools telling the truth about questions I hadn't meant to ask.

The run was stuck, the cancel was a no-op, the gate was reviewing someone else's week-old code — and all three tools were behaving exactly as documented. The bug was that I'd stopped reading the documentation a long time ago and was going on memory.
