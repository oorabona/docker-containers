---
layout: post
title: "The fix that worked by coincidence: a CI stall that was never in the code"
description: "We shipped a tidy root cause for a 67-minute CI stall. Six measurement rounds — including regenerating the real SBOM and instrumenting the original script — proved the code was never the cause and the celebrated fix was post hoc ergo propter hoc."
date: 2026-05-18 10:00:00 +0000
tags: [ci, debugging, post-mortem, measurement, github-actions, causality, code-review]
---

For several days the GitHub Pages deploy for this project's dashboard kept stalling. The "Generate dashboard data" step in `generate-dashboard.sh` ran for about 67 minutes, the deploy that depended on it was cancelled, and the dashboard went stale. A fix shipped with a clean root-cause story, the number dropped to about 10 minutes, and the incident was closed. This post is about what happened when that root cause was finally measured instead of believed — and why the fix's success turned out to be a coincidence.

## The stall, and the story we told about it

The first useful signal was the shape of the metric, not the code. Across consecutive runs the step did not sit at a stable duration: 39 minutes, then 49, then 57, then 67. Variable and rising over calendar time with no matching code change — the signature of an external or data-scaling cost, not a step-function regression.

The first durable change, PR #459 (commit `1930dbe`), persisted the per-arch GHCR manifest cache across runs (it had lived in a per-process temp dir, 0% cross-run hit). Mechanically correct; measured end to end it bought about 3%. Sound fix, wrong target.

Then came the root cause we believed. PR #464 (commit `2b83dfe`) was credited with finding it: `generate-dashboard.sh` ran `jq` over each container's SBOM with no size or time bound, and the `github-runner` `*-windows-ltsc2022-dev` variants — a 9.4 GB development image — produced a 37 MB SBOM that, the narrative said, took roughly 20 minutes per variant to process, ~61 of the 67. The fix added a 25 MiB SBOM size cutoff plus `timeout 60 jq`, applied the same guard to the `update-dashboard.yaml` hydration step, and added a `timeout 120` to the `skopeo list-tags` `docker run`. On the next real deploy (`update-dashboard` run `26041557511`), "Generate dashboard data" went from ~67 minutes to ~10. The guard fired 6 times, exactly on the oversized SBOMs. The story was tidy, the number moved, and it survived a senior-model review, a Copilot review, and a mandatory orthogonal review gate.

Everything in that paragraph is true except the part that mattered: that the `jq` was the cost.

## The first crack: the jq is fast

The doubt started with arithmetic. `jq` over a 37 MB JSON taking ~20 minutes is implausible — that is normally seconds. A synthetic SBOM scaled to 37 MB with the exact dashboard filter ran in about 0.8 s. Suggestive, but a synthetic proxy is not proof, so the real artifact was obtained the only way it could be: the original SBOM is an ephemeral CI artifact (1-day retention, long gone), but the image is public and durable, so the SBOM was regenerated in CI with the exact pipeline command — `syft registry:ghcr.io/oorabona/github-runner:2.334.0-windows-ltsc2022-dev-amd64 -o spdx-json` — and the two exact dashboard filters were timed on it, unbounded (run `26052427507`):

- Real SBOM: 39,368,938 bytes (the original guard's "37MB"), 17,108 packages, 34,940 external references, 24,640 files.
- `get_sbom_summary` filter: **0.59 s** wall, 100% CPU.
- `get_sbom_packages` filter (the one with the unbounded `.externalRefs[]?` fan-out): **0.65 s** wall.

The real `jq`, on the real SBOM, both filters, is sub-second. The thing the headline fix was built around was never the cost. The 25 MiB cutoff was skipping that SBOM — and dropping the windows-dev variant's entire package breakdown from the dashboard — to save about six tenths of a second.

## Eliminating the rest

If not the `jq`, then which of #464's bundled changes bought the 57 minutes? The other one it touched was the `skopeo list-tags` `docker run`. A call-graph audit settled it without a stopwatch: that command is invoked once per container (via `get_current_published_version`), early, before the per-variant loop. The original stall was three separate ~20-minute silent gaps, one per windows-dev variant. A once-per-container operation cannot produce a three-times-per-variant pattern. Every other per-variant operation — GHCR size and digest fetches, the attestation API call — measured under three seconds in isolation.

At this point both named suspects were gone and the only honest move left was the one that should have been first: stop measuring proxies and instrument the real script.

## The reproduction that should have come first

The pre-#464 (unbounded) `generate-dashboard.sh` was checked out verbatim, scoped to `github-runner` (the slow container), and run in CI under a fork-free timestamped trace (`set -x` with `PS4='+ ${EPOCHREALTIME} ...'`), with a cold GHCR cache faithful to the non-persisted-cache condition of the slow era, and with the same API permissions and token the real dashboard job carries so nothing collapsed into a fast 403 fallback (run `26055369954`).

Total wall time for the entire pre-fix github-runner processing — all 18 variants, unbounded, the exact code that "took 67 minutes":

**72.8 seconds.**

The slowest single command in the whole trace was 0.95 s. The stall did not reproduce. The per-(file:line) cumulative breakdown put the dominant cost at the GitHub `gh api .../actions/runs/<id>/jobs` path — about 40 seconds across all 18 variants — followed by repeated `gh auth status`, the GHCR size fetches, Trivy, and version resolution, all single-digit seconds cumulatively.

## What actually happened on 2026-05-18

The code is fast. The dominant code path is a sequence of GitHub API calls. On 2026-05-18 between roughly 00:47 and 01:54 UTC (pre-fix run `26007641130`), those same `gh api` calls took about 20 minutes per variant. The original log corroborates it: each ~22-minute silent gap is bracketed by `gh api attestations failed` warnings — the API path was failing and stalling, not the parsing.

The explanation most consistent with the evidence is a transient GitHub-API degradation during that window — latency or secondary-rate-limit behaviour on the `gh api` calls the dashboard step makes per variant. That is the surviving best explanation, not a proven one: we did not instrument the failing run, we lack the GitHub-side request-count and 429 telemetry to confirm it after the fact, and the condition no longer exists to reproduce. What the evidence does establish is the negative — the code is fast — and a positive that fits every remaining marker without contradicting any measurement. There is no commit that introduced the slowdown and no commit that fixed it.

## Post hoc ergo propter hoc

PR #464 bounded the `jq` (measured irrelevant, 0.6 s) and the `skopeo` call (once per container, cannot explain the pattern). It did not touch the `gh api` path that the evidence points to. The deploy after #464 was fast because the transient API condition had lifted by then — not because of the guards. The fix and the recovery were concurrent, not causal. The tidy narrative was *post hoc ergo propter hoc*: the number moved right after the change, so the change was credited.

The one durable consequence of the wrong narrative was a regression. The 25 MiB SBOM cutoff, justified by a 20-minute cost that does not exist, silently replaced the `github-runner` windows-dev variant's package summary with `{}` on every dashboard build — real provenance, dropped to save 0.6 s. It has since been removed (keeping only the cheap `timeout 60 jq` as a genuine latent-defect backstop); the full reckoning is recorded in issue #470.

## Why every safeguard missed it

This is the part worth keeping, because the failure was not a lack of effort:

- The original 67-minute run was never instrumented. By the time anyone looked, the only evidence was a coarse log with 22-minute silent gaps.
- Synthetic probes built during the incident measured operations in isolation, and one of them structurally could not obtain the ephemeral input at all — so the team inferred the cause instead of measuring it.
- A local reproduction ran without the SBOM and lineage files present, so it skipped the very code path under suspicion and "completed fast" — falsely reassuring.
- Four review surfaces — a senior model, Copilot, an orthogonal gate, and human eyes — all reviewed the *fix's diff*. None reviewed the *premise*, because a premise is not in a diff.

A transient external degradation has no code signature. Reading the code or re-running it later cannot recover it; the surest catch is instrumenting the failing run *while it fails*, and the next best is service-side telemetry (request counts, 429s, retry storms) — neither of which we had, and the second of which we did not pursue. That instrumentation did not exist, so a plausible code-shaped story filled the vacuum and was rewarded by a coincidental recovery.

## Lessons

- **"The fix worked" is not "the fix fixed the cause."** An aggregate before/after improvement proves nothing about causation when the change is bundled and the variable was never isolated. Either isolate the variable or state plainly that you have a correlation, not a cause.
- **A transient external degradation cannot be debugged post-hoc.** Instrument the failing operation while it is failing — per-call timing on the real path, emitted live. Reconstructing it days later from a coarse log is archaeology, and archaeology invents narratives.
- **Every proxy lies in its own way.** A synthetic input understates structure; an isolated operation hides integration cost; a local run with missing inputs skips the path. The only measurement that does not lie is the real operation, on the real input, in the real environment — here, the regenerated 37 MB SBOM and the in-CI instrumented script.
- **A guard credited with a benefit it does not provide is worse than no guard.** The 25 MiB cutoff bought 0.6 s and silently cost real dashboard data for months of builds, defended the whole time by a number nobody had measured.
- **Reviews check diffs; they do not check premises.** The most consequential error here was upstream of every line anyone reviewed.

The headline number — 67 minutes to 10 — was real. The story attached to it was not. The most useful thing this project can publish is not the fix; it is the six rounds of measurement it took to disprove our own published root cause, and the admission that the thing that "fixed" the stall was GitHub having a bad hour, and us being there to take the credit.

## Postscript (2026-05-19): the lessons, acted on

A post-mortem that only writes lessons is itself a kind of archaeology. Two follow-ups closed the loop:

- **The data-dropping guard was removed** (PR #471). The 25 MiB SBOM cutoff — the regression this post criticised — is gone; only the cheap `timeout 60 jq` backstop remains, and the `github-runner` windows-dev package breakdown is back on the dashboard.
- **The "instrument the failing operation while it fails" lesson was shipped** (PR #475, commit `7fd8428`). The dashboard generator now emits a per-call latency line to the run log for every `gh api`, GHCR, skopeo, and attestation call — plus a `::warning::` annotation when a single call exceeds its threshold. If GitHub has another bad hour, it will show up *as it happens*, as a labelled slow call, not as a silent 22-minute gap reconstructed days later. The exact instrumentation this incident lacked is now always on.

The number we could not explain post-hoc is now one we will be able to see live.
