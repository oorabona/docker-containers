---
layout: post
title: "Nine bytes of bash hid a 30-minute hang (part 3 of 3)"
description: "After five PRs, the dashboard's fast path was active, all unit tests were green, and the network profile had dropped 92%. The step still took 70 minutes. This is the story of how a bash parameter expansion you've probably used hundreds of times — ${var//pattern/replacement} — turned into an O(n) memory copy that ate 30 minutes per Windows-dev variant, and the nine-byte change that fixed it."
date: 2026-05-29 10:00:00 +0000
tags: [bash, perf, debugging, sbom, post-mortem, series-dashboard-perf]
---

Part 1 of this series moved 95% of the dashboard's per-regen work to build time. Part 2 took six PRs to actually make that shift land. After all of it, the dashboard step was still taking ~70 minutes — almost as slow as the 79.7-minute baseline before any of this work began. The architectural network calls were gone (167 ghcr-index → 13, 77 gh-attestation → 12) and yet the wall-clock time barely moved.

Something was eating 70 minutes that had nothing to do with the network.

This post is about how we found it, what it was, and why it's worth knowing about for any bash script that handles large JSON values.

## The trace

By PR #522 we had exhausted static analysis. Reading the script had told us where the bug *could* be, several times, and every place we had patched turned out to be a real bug that didn't move the bottom line. The remaining gap had to be measured.

We added four conditional trace markers inside `collect_variant_json`, each timestamped, each gated on a `DASHBOARD_TRACE=1` env var, each printing the variant name:

```bash
[[ -n "${DASHBOARD_TRACE:-}" ]] && printf '[trace] %s pre-trivy %s:%s\n' \
    "$(date -Iseconds)" "$container" "$variant_tag" >&2
trivy_summary=$(get_trivy_summary "$trivy_category")
[[ -n "${DASHBOARD_TRACE:-}" ]] && printf '[trace] %s post-trivy %s:%s\n' \
    "$(date -Iseconds)" "$container" "$variant_tag" >&2

# ... platforms + digests lineage-first lookup ...
[[ -n "${DASHBOARD_TRACE:-}" ]] && printf '[trace] %s post-platforms %s:%s\n' \
    "$(date -Iseconds)" "$container" "$variant_tag" >&2

# ... variant_deps assembly ...
[[ -n "${DASHBOARD_TRACE:-}" ]] && printf '[trace] %s pre-slurp %s:%s\n' \
    "$(date -Iseconds)" "$container" "$variant_tag" >&2

_slurp_guard lineage_json   '...'
_slurp_guard build_args_json '[]'
_slurp_guard sbom_summary    '{}'
_slurp_guard sbom_packages   '{}'
_slurp_guard changelog       '{}'
_slurp_guard build_history   '[]'
_slurp_guard trivy_summary   '{}'
_slurp_guard multi_arch_platforms_json '[]'
_slurp_guard multi_arch_digests_json   '{...}'
```

The workflow change to expose the gate was three lines (`DASHBOARD_TRACE: ${{ contains(...trigger_reason, 'TRACE') ... }}`), gated through both `github.event.inputs.trigger_reason` (for workflow_dispatch) and `inputs.trigger_reason` (for workflow_call) — the orthogonal review caught that the workflow_call path was missing before we pushed.

We triggered a dashboard run with `TRACE` in the trigger reason and let it run for the full 79 minutes. Then we pulled the trace markers for the variant we knew was slow:

```
11:56:12.266  pre-trivy       github-runner:2.334.0-windows-ltsc2022-dev
11:56:12.283  post-trivy      github-runner:2.334.0-windows-ltsc2022-dev
11:56:12.303  post-platforms  github-runner:2.334.0-windows-ltsc2022-dev
11:56:12.321  pre-slurp       github-runner:2.334.0-windows-ltsc2022-dev
12:26:03.435  WARN: slurp guard fired: empty changelog for github-runner:2.334.0-windows-ltsc2022-dev
```

Three sections covering `pre-trivy → post-trivy → post-platforms → pre-slurp`, each 17-20 milliseconds apart. Then **29 minutes and 51 seconds** before the next event — which was the WARN print from inside `_slurp_guard` itself.

Trivy was 17 ms. The platforms lookup was 20 ms. The variant_deps assembly was 18 ms. And then the slurp guards consumed half an hour.

## What the slurp guards do

The slurp guards exist because of a stream-shift bug in `jq -s`. The final variant record is assembled by piping nine JSON values into a single `jq -s` call:

```bash
printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s' \
    "$lineage_json" "$build_args_json" \
    "$sbom_summary" "$sbom_packages" \
    "$changelog" "$build_history" \
    "$trivy_summary" "$multi_arch_platforms_json" \
    "$multi_arch_digests_json" | \
jq -s '
    .[0] as $lineage |
    .[1] as $build_args |
    .[2] as $sbom_summary |
    .[3] as $sbom_packages |
    .[4] as $changelog |
    # ...
'
```

If any of the nine values is an empty string, `printf '%s\n' ""` produces a single newline. `jq -s` reads multiple JSON documents from a stream and bundles them into one array. An empty stream element gets *silently dropped*, the array collapses from 9 elements to 8, and every positional `.[N]` index shifts by one. We had hit this once already (terraform's provenance digest rows landed in the multi-arch-platforms slot), and the slurp guards were the defensive fix:

```bash
_slurp_guard() {
    local _name="$1" _fallback="$2"
    local _val="${!_name}"
    if [[ -z "${_val//[[:space:]]/}" ]]; then
        printf 'WARN: collect_variant_json slurp guard fired: empty %s for %s:%s — substituted fallback\n' \
            "$_name" "$container" "$variant_tag" >&2
        printf -v "$_name" '%s' "$_fallback"
    fi
}
_slurp_guard lineage_json   '...'
_slurp_guard build_args_json '[]'
_slurp_guard sbom_summary    '{}'
_slurp_guard sbom_packages   '{}'
_slurp_guard changelog       '{}'
# (and four more)
```

The check `[[ -z "${_val//[[:space:]]/}" ]]` is meant to catch empty or whitespace-only values: take the value, strip every whitespace character, see if anything remains. If not, the value was effectively empty, replace it with a safe JSON literal (`'[]'`, `'{}'`, etc.) so `jq -s` keeps nine elements.

It's a defensive guard. It's the right idea. It is also where 30 minutes per Windows-dev variant were going.

## What `${var//pattern/replacement}` actually does

Bash's parameter expansion `${var//pattern/replacement}` performs a *global* substring substitution: it replaces every match of `pattern` in `var` with `replacement`. It does this by **allocating a new string** containing the result, and the original variable is left untouched. The expansion's value is the allocated copy.

For `${val//[[:space:]]/}` — the pattern is "any whitespace character", the replacement is empty — bash walks the value character by character, builds a new string containing only the non-whitespace characters, and returns that. For a 10-character value the cost is negligible. For a 100-megabyte value, the cost is: allocate 100 MB, copy 100 MB byte by byte (skipping whitespace), and then immediately throw away the result because the only thing we want to know is whether it's empty.

The `sbom_packages` value for Windows-dev variants of `github-runner` is exactly this case. The image includes a full Windows base layer plus a dev tooling stack. The SPDX SBOM enumerates every package: the syft scan produces a JSON file in the tens of megabytes. The dashboard's `get_sbom_packages` function reads that file with `jq` (a 60-second timeout, no warning was firing, the jq was completing), restructures it into a nested object grouped by package type, and the resulting value held in `sbom_packages` is *still* large — comfortably in the 50-100 MB range.

When `_slurp_guard sbom_packages '{}'` runs, bash sees a multi-tens-of-MB string in `_val` and asks for a copy with all whitespace removed. On the runner this takes ~5-10 minutes. Multiply by nine `_slurp_guard` invocations per variant (each operating on its own value, but `sbom_packages` is the dominant one), times three Windows-dev variants per regen (we retain three versions of `github-runner`), and you have roughly 30 minutes per regen burned on a defensive whitespace strip.

The architectural fast path from part 1 made the *network* part of the work negligible. It did nothing about this. The `sbom_packages` value was just as large after the fix as before — it had always been read from the SBOM file, which itself had always been written by the build job. The dashboard had always paid for the slurp-guard whitespace check; we just hadn't noticed because the network calls had been even more expensive.

Once the network calls were gone, the slurp guard was suddenly the dominant cost.

## A benchmark

A 12.8 MB synthetic JSON-like string, OLD vs NEW check:

```
String size: 12800005 bytes

OLD check (global substitution):
  real    0m0.542s
  user    0m0.471s
  sys     0m0.072s

NEW check (regex with short-circuit):
  real    0m0.258s
  user    0m0.163s
  sys     0m0.095s
```

A 51 MB version:

```
String size: 51200005 bytes

OLD check:
  real    0m2.386s
  user    0m1.986s
  sys     0m0.400s

NEW check:
  real    0m1.245s
  user    0m0.748s
  sys     0m0.395s
```

Per call the old check is roughly twice as slow on these sizes. The gap on real `sbom_packages` payloads is larger — the runner is doing other work, allocating that much memory triggers paging and GC behavior these microbenchmarks don't capture, and bash's pattern-substitution implementation has non-linear performance on some pathological inputs depending on the alphabet size and the value's structure.

What the benchmark *does* prove is that the new check, on the same input, never costs more than the old one and is meaningfully cheaper at large sizes. Whatever the constant factor in CI is, the new check pays less of it.

## The fix

Nine bytes, near enough:

```diff
 _slurp_guard() {
     local _name="$1" _fallback="$2"
     local _val="${!_name}"
-    if [[ -z "${_val//[[:space:]]/}" ]]; then
+    if [[ -z "$_val" || "$_val" =~ ^[[:space:]]+$ ]]; then
         printf 'WARN: collect_variant_json slurp guard fired: empty %s for %s:%s — substituted fallback\n' \
             "$_name" "$container" "$variant_tag" >&2
         printf -v "$_name" '%s' "$_fallback"
     fi
 }
```

The two checks are equivalent in semantics:

- `[[ -z "$_val" ]]` — the value is truly empty (zero bytes).
- `[[ "$_val" =~ ^[[:space:]]+$ ]]` — the value contains one or more characters and they are all whitespace.

The disjunction covers the same set of inputs as `[[ -z "${_val//[[:space:]]/}" ]]`.

The reason it is fast is that bash's regex engine, on a non-empty string starting with a non-whitespace character, **fails the anchor immediately**. The `^` requires the regex to match the entire string, the regex begins with `[[:space:]]+`, and the first character of a typical JSON value is `{` or `[`. The regex engine sees `{`, sees that `[[:space:]]+` cannot match `{`, fails the overall match, and returns. For a 100 MB string the time spent is the time to read one byte.

The OLD check does no such short-circuit. It iterates the entire value, character by character, building the stripped copy as it goes, *even when the very first character has already told us the value is non-empty*. That's the design trade-off of `${var//pattern/replacement}`: it always produces a copy, because the caller might want the copy. We didn't. We wanted a boolean.

The first commit message for this fix had a self-description that turned out to be the entire post-mortem in one line: *"the regex short-circuits on the first non-whitespace character"*. Bash had been giving us a tool that didn't short-circuit, and we had been calling it on values where the first character was almost always conclusive.

## What the dashboard does now

The next dashboard run after the merge:

```
Re-download SBOM artifacts:                                  41s
Re-enrich lineage after merge (self-heal):                    2s
Restore GHCR per-arch manifest cache:                         1s
Generate dashboard data:                                    136s   ← 2 min 16 s
```

**79.7 min → 2.3 min, a 97% reduction.**

Of the 136 seconds, roughly 60 seconds are the trivy-alerts fetch (one paginated `gh api code-scanning/alerts` call at the start of the run, cached across variants), 20-30 seconds are the per-variant orchestration overhead (shell loops, jq invocations, lineage reads), and the rest is the per-container container-level work that hasn't been moved to build time yet.

We could optimize further. There's a remaining container-level `ghcr_get_manifest_sizes` at the top of each iteration that fires once per container regardless of variants. It contributes ~13 seconds total. We left it for follow-up — it's now the largest remaining piece, but it's no longer the bottleneck.

## What this post is also about

**Bash parameter expansions are not always free.** `${var//pattern/replacement}` is O(n) in the value's size, and the constant factor on large strings is high enough to matter. The substring forms (`${var#prefix}`, `${var%suffix}`) are usually fine because the comparison happens at the value's edges; the global form is the dangerous one because it touches every byte.

**A "defensive" check is a hot path if it runs on every variant.** The slurp guard ran on nine variables per variant, dozens of times per regen. Its cost was directly proportional to the size of the value being guarded. Defensive code does not get an exemption from perf analysis just because it's defensive — if it's on the hot path, it's a hot path.

**Static analysis ran out at a certain point.** Reading the script, we could see the slurp guard, we could see the check, we could see the values. We did not see that the check itself was the slow operation, because the check looked cheap. The trace markers told us the truth in five minutes.

**Trace markers are worth their cost.** The markers added in the diagnostic commit were left in production. They are gated on `DASHBOARD_TRACE=1` via the trigger reason, produce no output in normal runs, and cost the workflow nothing. Adding them after a perf bug has surfaced is too late if there's no convenient harness; *keeping* them after the bug is found means the next bisection takes a `workflow_dispatch` instead of another PR cycle.

The full chain — architectural shift in [part 1]({% post_url 2026-05-25-dashboard-perf-architecture-build-time-lineage %}), six PRs of fighting the layered handshakes in [part 2]({% post_url 2026-05-27-six-prs-to-deliver-one-perf-win %}), and this 9-byte fix — got the dashboard from 79.7 min to 2.3 min. The architecture did the real work; the bash builtin was hiding the result. The shape that surprised us is that the bash builtin's cost had always been there. Only when the architectural work removed everything else did it become visible.

The lesson worth pulling out is uncomfortable but useful: an optimization that doesn't deliver might not be wrong. It might be right and *insufficient*. The next layer down can have a problem of its own. Keep going.

---

*Refs: [#515](https://github.com/oorabona/docker-containers/issues/515), [#523](https://github.com/oorabona/docker-containers/pull/523). Bash manual: [Shell Parameter Expansion §3.5.3](https://www.gnu.org/software/bash/manual/html_node/Shell-Parameter-Expansion.html). Previous: [part 1]({% post_url 2026-05-25-dashboard-perf-architecture-build-time-lineage %}), [part 2]({% post_url 2026-05-27-six-prs-to-deliver-one-perf-win %}).*
