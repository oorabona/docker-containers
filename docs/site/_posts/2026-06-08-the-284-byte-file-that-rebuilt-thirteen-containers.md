---
layout: post
title: "The 284-byte file that rebuilt thirteen containers"
description: "A transient network reset on a tiny artifact upload made my CI rebuild the entire fleet. The safety mechanism that did it was working exactly as designed — which is the whole point. This is about calibrating a fail-closed gate so it stops over-firing on noise without dulling the alarm."
date: 2026-06-08 06:00:00 +0000
tags: [ci, github-actions, fail-closed, reliability, lessons-learned]
---

I don't rebuild every image on every push — most pushes touch one or two. So there's a checkpoint: a git tag that records which containers failed in the last run. The next run rebuilds the ones whose files changed, *plus* the ones still carried as failing, and drops a container from the carry list only once it's built green. It keeps the build cheap without ever silently abandoning a broken image.

One run carried all thirteen.

Thirteen is the whole fleet. And it wasn't because thirteen things broke — most of them had built green that run. The checkpoint had looked at a run where three containers failed and decided to rebuild everything. I went in expecting a bug in the carry logic. What I found was the carry logic being exactly right about a situation I'd given it.

## How the checkpoint decides

Every build job, pass or fail, emits a tiny result record as an artifact — `{container, tag, arch, result}`, a few hundred bytes. After the matrix finishes, the checkpoint job downloads those records and reconciles them against the jobs that actually ran:

- `failure_record_count` — how many records say `result: failure`
- `bad_build_job_count` — how many jobs ended in a non-success state

If those two agree, the checkpoint knows exactly which containers failed and carries precisely those. If `bad_build_job_count` is *greater* than `failure_record_count`, there's a failure it can't attribute — a job died without leaving a record saying which container it was. And at that point it does the only safe thing:

```
unmapped failure → carry everything (prior ∪ this run's matrix)
```

It refuses to claim it knows which containers are safe when there's a failure it can't account for. Fail-closed. Carry all thirteen, rebuild next run, sort it out when every cell has a record.

## The 284 bytes

So what was the unaccounted failure? The counts were 8 jobs bad, 7 records — a gap of one. The missing one was `php`, on amd64. And `php` had *built fine*. The image was pushed to both registries; the logs end with a clean success. Then this:

```
##[error]Failed to FinalizeArtifact: Unable to make request: ECONNRESET
```

That's the upload of the result record — a 284-byte JSON saying `php: success`. The Docker build worked, the push worked, the bytes of the record made it to blob storage, and then the *finalize* call that registers the artifact got its TCP connection reset. The upload step failed, which marked the whole job as failed. But no artifact was registered, so the checkpoint downloaded nothing for that cell.

Eight failed jobs, seven failure records. One of those eight "failures" was a fully successful build whose 284-byte receipt didn't get filed. The gate saw a failure it couldn't map, did the safe thing, and rebuilt the fleet. A network blip on a tiny file rebuilt thirteen containers.

## The tempting fix

The tempting fix is to relax the count gate — tolerate a small gap, assume a missing record means success. Don't. The gate's strictness is the feature. The entire reason it exists is to never look at an unaccountable failure and quietly decide everything's fine; that's the failure mode it's there to prevent. Loosen it and you've reintroduced exactly the silent-gap bug it was built to stop, in exchange for saving the occasional redundant rebuild. Bad trade.

The gate wasn't wrong. Its *input* was noisy. `php` looked like an unmapped failure only because a transient reset turned a successful build into a job with no record. Fix the noise, not the gate.

`actions/upload-artifact` retries the data upload but not the finalize call, so an `ECONNRESET` there is fatal to that one upload. The fix is a gated retry around it: let the first upload fail soft, and if it did, run it again — same artifact, `overwrite: true`. Two consecutive resets on a 284-byte payload is a real problem worth failing on; one is just Tuesday on the internet. With the receipt reliably filed, a successful build stops occasionally presenting as an unaccountable failure, and the gate stops firing on phantom smoke.

## What I'd tell past-me

- **A fail-closed mechanism is supposed to over-react. The question is what it over-reacts *to*.** Reacting to a real unaccountable failure is correct. Reacting to a network blip on a receipt is the bug — and it lives in the input, not the gate.
- **Don't dull the alarm to stop false alarms — remove the false smoke.** Relaxing the count gate would have "fixed" the symptom by reintroducing the exact silent failure the gate exists to catch. A fleet-wide rebuild over one dropped 284-byte file is the gate's false-positive cost showing up; make the trigger robust and that cost goes to near zero without touching the guarantee.
- **`upload-artifact` doesn't retry finalize.** If a missing artifact has consequences downstream, wrap the upload in your own retry. The action's internal retries don't cover the call that actually registers the thing.

The checkpoint did its job. It was handed a successful build wearing a failure's clothes and, not being able to tell, refused to guess.
