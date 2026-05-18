---
layout: post
title: "Five wrong guesses and one measurement: debugging a multi-day CI stall"
description: "Five hypotheses killed by measurement, one wrong first fix, and an unbounded jq over a 37 MB SBOM: how a GitHub Pages dashboard deploy went from 67 to 10 minutes."
date: 2026-05-18 10:00:00 +0000
tags: [ci, debugging, jq, sbom, github-actions, measurement, code-review]
---

For several days the GitHub Pages deploy for this project's dashboard kept stalling. The "Generate dashboard data" step in `generate-dashboard.sh` ran for about 67 minutes, and the deploy that depended on it was cancelled before it finished. The dashboard went stale. This is the account of how that hour was found and removed — including the first fix that was the wrong fix, and the five causes that turned out not to be causes.

## The shape of the metric

The first useful observation was not about the code. It was about the number. Across consecutive runs the step did not sit at a stable duration: it was 39 minutes, then 49, then 57, then 67. Variable, and trending up.

A stable regression looks like a step function — it was fast, a commit landed, now it is slow by a fixed amount. A cost that is variable and rising over calendar time, with no corresponding code change, has a different signature: it usually tracks an external input or a quantity that is growing. The shape of the metric is itself evidence, and here it argued against "a commit broke it" and in favour of "something the step consumes is getting bigger."

That reading was correct. It still took a wrong fix and five dead ends to act on it properly.

## The first durable fix was the wrong target

The earliest concrete change — PR #459, commit `1930dbe` — persisted the per-arch GHCR manifest cache across CI runs. The cache had been living in a per-process temporary directory, which meant a 0% cross-run hit rate: every run re-fetched every manifest from scratch. Persisting it across runs was a real defect fixed, and mechanically the change was correct.

Measured end to end, it bought roughly 3%. The manifest fetches were real work, but they were not 64 of the 67 minutes. The fix was sound and the target was wrong. It is worth stating plainly because it is the common failure mode: a defect you can see and reason about is not necessarily the defect that is costing you the time. Only measurement settles which one you are looking at.

## Five hypotheses, each killed by measurement

After #459, the discipline that mattered was refusing to write code against any hypothesis until a cheap measurement had survived. Five candidates were raised, each plausible, each disproved before implementation:

1. **Per-arch manifest fetch volume** — the count of manifest requests was large, so the time was assumed to be there. Persisting the cache (#459) tested this directly: ~3% — not it.
2. **Trivy and SBOM artifact-hydration steps** — these download and unpack scan artifacts and looked heavy. Timed in isolation, they were not the dominant cost.
3. **GHCR throttling the GitHub-runner egress** — the theory that the registry was rate-limiting the runner. A small latency probe run from a runner returned a median around 0.22 seconds per request. Throttling was dead on arrival; you do not get a 67-minute step out of sub-second requests at this volume.
4. **`gh` API secondary-rate-limit backoff** — the GitHub CLI backing off under secondary rate limits would have introduced long sleeps. The call volume and observed pacing did not support it.
5. **Windows foreign-layer fetches** — the `github-runner` Windows variants reference base layers via `urls:` pointing at `mcr.microsoft.com`; pulling those could have been slow. Measured, the foreign-layer fetches were not where the time went.

Each of these was the "obvious" answer at the moment it was raised. Each was killed by a targeted measurement that cost minutes, not by argument and not by a code change that then had to be reverted. The cumulative cost of being wrong five times was small precisely because none of the five turned into an implementation.

## The synthetic-probe trap

To time each operation faithfully, a dedicated `workflow_dispatch` probe was built — a throwaway workflow whose only job was to run the suspect operations and report per-operation timings.

That probe was not free, and the honest version of this story includes its cost. It needed several hardening passes before its numbers could be trusted: an early version measured an inert path and would have reported a misleadingly fast result; a tag-injection bug fed it the wrong input; a fallback branch silently substituted a value that did not represent the real operation; and the output materialization had to be made faithful so the reported number matched what actually ran.

After all that hardening, the probe failed structurally. The operation that mattered consumed the SBOM of a multi-gigabyte Windows development image, and that SBOM is an ephemeral CI artifact — produced inside the build, not obtainable standalone. The probe could be made correct, but it could not be made to see the input that caused the problem.

The hardening was not wasted, though, and the reason is the lesson. The final probe, confronted with an input it could not faithfully obtain, refused to emit a number rather than emit a number it could not stand behind. A diagnostic that declines to produce an untrustworthy measurement is doing its job. The deeper takeaway: a synthetic proxy of a non-reproducible input will either under-measure it or fail to measure it at all. The authoritative measurement had been available the whole time and was free — the real post-merge deploy.

## The actual cause: an unbounded jq over a 37 MB SBOM

The real deploy is what proved the cause. `generate-dashboard.sh` runs `jq` over each container's SBOM to summarise package data for the dashboard. For the `github-runner` `*-windows-ltsc2022-dev` variants — a 9.4 GB development image — the SBOM measured 37 MB, and the `jq` invocation over it was unbounded: no size ceiling, no timeout. There were six such oversized variant SBOMs; the same unbounded `jq` ran once per variant, and those six runs together were roughly 61 of the 67 minutes. Everything else — the other containers, all with normal-sized SBOMs — was the remaining ~6 minutes, and was never the problem.

This matches the shape of the metric from the start. The Windows-dev image grew over time; its SBOM grew with it; the unbounded `jq` got slower in proportion. Variable and rising, tracking a quantity that was getting bigger — exactly the signature the duration curve had shown before any of the five hypotheses were raised.

## The fix — and the sibling the first fix missed

The solution is one sentence: never let `jq` loose on an SBOM past a size ceiling — skip it above the ceiling, cap whatever still runs with a timeout, and apply that at every code path that runs it. PR #464 (commit `2b83dfe`) bounded the operation rather than special-casing the one input that triggered it today. The core of it, in `get_sbom_summary`:

```bash
size=$(stat -c%s "$sbom_file" 2>/dev/null || echo 0)
if (( size > SBOM_MAX_BYTES )); then            # SBOM_MAX_BYTES = 25 MiB
    echo "::warning::SBOM ${container}:${tag} is $((size/1048576))MB (> 25MB guard) — returning empty summary to avoid unbounded jq" >&2
    echo "{}"
    return
fi
if ! result=$(timeout 60 jq '…package-manager group summary…' "$sbom_file" 2>/dev/null); then
    echo "::warning::SBOM jq for ${container}:${tag} timed out/failed — empty" >&2
    result="{}"
fi
```

The same guard went on `get_sbom_packages`, and a `timeout 120` — with the `skopeo list-tags` output written to a file before being parsed rather than streamed inline through a pipe — went on the registry `docker run`, which had the same unbounded-call shape. 11 `bats` tests cover it, including a mutation-checked regression lock: a change that deletes the guard fails a test instead of silently re-opening the stall.

Be precise about what this preserves and what it costs. For every SBOM under the 25 MiB ceiling the dashboard output is byte-for-byte unchanged — the normal path is untouched, and the `timeout 60` is only a second-order net for an under-ceiling file that is somehow still pathological to parse. For an SBOM over the ceiling the package summary for that variant becomes `{}`: the dashboard loses the per-ecosystem package breakdown for the oversized Windows-dev image, and the build log says so. That is graceful degradation of one pathological variant's detail, traded for a step that finishes in minutes instead of stalling for over an hour — not behaviour preservation. The honest framing is the tradeoff, not a claim that nothing was given up.

Trace where the 57 minutes went. The guard returns `{}` for exactly the six oversized SBOMs that were the ~61 minutes; those six multi-minute `jq` parses simply no longer run. Nothing else in the step changed — the other containers were always ~6 minutes combined. An hour of work computing a package breakdown for a 9 GB image's dependency tree stopped happening, and the step that does everything else now finishes the whole job in about ten. The fix is not an optimisation of the slow operation; it is the slow operation no longer running.

The part worth the most to another team is what happened in review, because it nearly did not get caught. The diff for #464 was three files. Two reviews scoped to that diff came back clean. A third review — mandatory, with repository-wide scope, directed to trace the data across the codebase rather than read the changed lines — found a *sibling*: a second, separate code path carrying the identical defect. `.github/workflows/update-dashboard.yaml` ran the *same* unbounded `jq` over the *same* SBOM files in its hydration step, *before* `generate-dashboard.sh` ever ran. Guarding only `generate-dashboard.sh` would have left the 67-minute stall in place one step upstream, and all three diff-scoped files would still have looked correct.

This is one defect, not a statistic, and the honest lesson is about scope, not about which reviewer found it. A prompt scoped to a diff sees the diff; the upstream producer of the same data sat outside the diff and so outside every diff-scoped reviewer's field of view, however capable the reviewer. What the orthogonal gate bought was structural: it is the one review *required* to run with repository-wide scope and a different set of priors, so the broad question gets asked even when nobody remembers to ask it. The fix was extended to put the identical guard on the `update-dashboard.yaml` hydration `jq`, and the durable rule is the scope, not the model: any review that touches a data-processing step must trace that data's producers and consumers across files, not just inspect the changed lines.

## What it bought, on the real deploy

The validation was the real post-merge deploy — `update-dashboard` run `26041557511`, which completed successfully. "Generate dashboard data" went from about 67 minutes to about 10: roughly 85%, roughly 57 minutes removed. The 25 MiB guard fired 6 times, on the real `github-runner` Windows-dev SBOMs, exactly as designed — those six skips are the ~57 minutes. All 13 containers were processed, and the dashboard data for the normal containers was unchanged.

Two follow-ups closed the arc. The throwaway diagnostic workflows were removed (PR #465, commit `ec2cabe`). And the build `timeout-minutes` was deliberately left at 90 rather than tightened toward the new 10-minute reality: a legitimate cold run with every cache cold still needs headroom, and shrinking a safety margin to fit the happy path is how the next flaky-cancellation incident gets manufactured. The stall was the thing to remove, not the margin.

## Lessons

- **Let the shape of the metric pick the investigation.** A duration that is variable and rising over calendar time, with no matching code change, points at an external or data-scaling cost — not a code regression. That reading was available before any hypothesis and was correct.
- **Measure the actual operation in the actual environment.** A synthetic proxy of a non-reproducible input will under-measure it or fail outright. Here the authoritative measurement — the real post-merge deploy — was free and available the entire time the synthetic probe was being hardened.
- **An unbounded operation over an unbounded artifact is a defect class**, independent of which input triggers it today. The objection writes itself — isn't a size guard a band-aid on a symptom? It is not, and the distinction is the point: a 9.4 GB development image legitimately produces a large SBOM; that artifact is not a bug to be shrunk. The defect is running an operation over it with no ceiling and no timeout. Bounding the operation fixes the cause; chasing the SBOM's size would be chasing a symptom that is allowed to exist. The price of the bound — an empty package summary for that one variant — is paid in the open with a log line, not hidden.
- **Scope at least one review wider than the diff, and make that pass mandatory.** Two diff-scoped reviews missed a real cross-file sibling that would have shipped the stall; the review that caught it was the one structurally required to run repository-wide. The reusable rule is not "use another model" — it is that any data-processing change gets at least one review obligated to map that data's producers and consumers across the whole subsystem.
- **A diagnostic that refuses to emit an untrustworthy number is working correctly.** The probe's refusal to report a value it could not stand behind was the signal that the synthetic approach was the wrong approach — not a bug in the probe.

The headline number is 67 minutes to 10. The part worth keeping is the order it happened in: the metric's shape was read correctly first, then a sound fix aimed at the wrong target, then five measured dead ends, then a synthetic detour that failed honestly, and only then the cause — proven on the real deploy, not inferred, and bounded by construction rather than patched around.
