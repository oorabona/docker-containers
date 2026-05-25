---
layout: post
title: "Six PRs to deliver one perf win (part 2 of 3)"
description: "The architectural shift in part 1 was the right answer. It still took six PRs and a trace-bisection round to make it land. The story of how each fix passed its unit tests, then masked the next bug — and the integration smoke test that finally broke the chain."
date: 2026-05-27 10:00:00 +0000
tags: [ci, dashboard, perf, debugging, integration-testing, post-mortem, series-dashboard-perf]
---

Part 1 of this series ended with an architectural shift that, on paper, should have moved a dashboard regen from 80 minutes to under 5. The lineage cache was being enriched at build time; the dashboard read it preferentially with a network fallback; the unit tests for the new helper were green. We pushed.

The next dashboard run took **83 minutes**. Three minutes *worse* than before the fix.

This post is about the six PRs we needed after that — and why the obvious explanations were all wrong.

## PR #517 — the artifact clobber

The first dashboard run after the merge showed the enrich-lineage step writing 78 files. The network profile, though, was unchanged: 167 ghcr-index calls, same as before. Whatever the dashboard was reading, it was not the enriched lineage.

Looking at the workflow that restores the lineage cache, we found a hydration step in `update-dashboard.yaml`. To bridge a race between auto-build's `cache-lineage` job and the dashboard's restore — both write the same cache key, and a fresh build might not have its lineage in the dashboard's restored cache yet — the dashboard re-downloads `build-lineage-*` artifacts from recent build runs and merges them into `.build-lineage/`.

The merge loop overwrites cached files with artifact contents whenever the source artifact has an `oci_subject_digest`. That guard was there for a different problem (digest-less fallbacks from older runs), but it had a side effect we hadn't accounted for:

**Per-arch build artifacts are uploaded *before* `enrich-lineage.sh` runs.** They contain `build_digest`, `oci_subject_digest`, the base fields — but not the eight enrichment fields, because those are added by the `cache-lineage` job *after* the per-arch artifacts have been merged. The dashboard's hydration then overwrites the enriched cached file with the raw per-arch artifact, silently undoing the enrichment.

The fix was a five-line guard inserted before the existing logic:

```bash
if [[ -f "$target" ]]; then
  tgt_enriched=$(jq -e '(.multi_arch_index_digest // null) != null' "$target" \
    >/dev/null 2>&1 && echo true || echo false)
  if [[ "$tgt_enriched" == "true" ]]; then
    echo "::notice::Preserving enriched cached lineage for $fname"
    lineage_locked[$fname]=1
    continue
  fi
  # ... existing tgt_has_digest logic ...
fi
```

If the cached file already has `multi_arch_index_digest`, it's enriched — let it through unchanged. We pushed.

The dashboard ran. It now took 70 minutes. Twelve percent better than the 79.7 baseline. A real improvement. Still far, far from <5 min.

## PR #518 — the cache race that defeats the guard

The next investigation question: if the guard preserves enrichment per-file, why is `ghcr-index` latency still 167?

It turned out the file-level preservation had a precondition that wasn't always true: **the cache the dashboard restores has to be enriched to begin with.** A timing trace told the story:

```
21:58:30  auto-build cache-lineage SAVED enriched cache build-lineage-26373621326
21:58:51  workflow_run dashboard (cancelled by concurrency 12 min in) SAVED 
          its own cache build-lineage-26373612236
21:59:15  verification dashboard restored "most recent" cache via prefix match
          → got the cancelled run's cache (saved 21 seconds later)
          → that cache was clobbered (no enrichment to preserve)
          → guard never fires
          → entire dashboard runs on the network fallback
```

GitHub Actions cache prefix-match returns the most-recently-saved cache. If a concurrent workflow_run dashboard saves its cache state *after* the enriching auto-build saves its, the dashboard's clobbered state wins the race. The next dashboard restores the clobbered cache, sees no enrichment, the guard from #517 does not fire, the merge proceeds, the clobbered state is re-saved as the latest. The cache is now in a clobbered fixed point.

The fix was to make the dashboard self-healing: re-run `enrich-lineage.sh` once per dashboard regen, immediately after the merge loop ends. The script is idempotent (it skips files where `multi_arch_index_digest` is already non-null), so on a healthy cache this is a 2-second no-op. On a clobbered cache, it's a 2-minute recovery. Either way, the cache the dashboard saves is always enriched.

```yaml
- name: Re-enrich lineage after merge (self-heal against cache races)
  if: hashFiles('.build-lineage/*.json') != ''
  env:
    GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    GITHUB_REPOSITORY: ${{ github.repository }}
  run: |
    chmod +x scripts/enrich-lineage.sh
    ./scripts/enrich-lineage.sh --owner "${{ github.repository_owner }}"
```

We pushed. The next dashboard ran. The re-enrich step succeeded, populating 78 files. Step duration: **72 minutes**.

## PR #521 — the synthesizer drops the data

By this point we had four pieces of evidence that the enrichment was being written correctly: the bats tests, the enrich step's own `Enriched 78 lineage files (0 errors)` log, the cache save step succeeding, and a manual inspection of the lineage cache contents during the run. The data was on disk. The dashboard was reading the disk. And yet the dashboard was still hitting the network for every variant.

So we read `collect_variant_json` more carefully, top to bottom. The lineage data comes from a helper called `resolve_variant_lineage_json`. Its job, as we had understood it, was to load the lineage file from disk and return its contents. What it actually did:

```bash
resolve_variant_lineage_json() {
    # ... lookup file, read three fields, do version-mismatch normalization ...
    BD="$build_digest" BI="$base_image" OCI="$oci_subject_digest" \
        yq -n -o json '.build_digest = strenv(BD) | .base_image = strenv(BI) | .oci_subject_digest = strenv(OCI)'
}
```

It read three fields from the file. Then it synthesized **a brand new JSON object containing only those three fields**, with `yq -n` (start from nothing). Every other field from the file — including the eight enrichment fields — was dropped.

The caller stored the synthesized object in `lineage_json`. The fast-path lookups added in PR #516 (`jq -r '.multi_arch_index_digest // empty'` etc.) always returned empty, because the synthesizer had quietly stripped that field on the way through. The fallback to the network always fired. Every variant. Every regen.

We had reviewed `resolve_variant_lineage_json` while writing #516. We had read those exact lines. We had not noticed that the function was rebuilding the JSON instead of passing it through, because at the time the function returned exactly what its three callers needed and the new callers were being added *around* it, not through it.

The fix preserves all source fields and overrides only the three normalized ones:

```bash
if [[ -n "$lineage_file" ]]; then
    BD="$build_digest" BI="$base_image" OCI="$oci_subject_digest" \
        jq '. + {build_digest: env.BD, base_image: env.BI, oci_subject_digest: env.OCI}' "$lineage_file"
else
    BD="$build_digest" BI="$base_image" OCI="$oci_subject_digest" \
        yq -n -o json '.build_digest = strenv(BD) | .base_image = strenv(BI) | .oci_subject_digest = strenv(OCI)'
fi
```

We pushed. The next dashboard run got cancelled at 22 minutes. The logs were full of:

```
./generate-dashboard.sh: line 522: lineage_json: unbound variable
./generate-dashboard.sh: line 523: lineage_json: unbound variable
```

## PR #522 — the read-before-init under `set -u`

In `collect_variant_json`, the new fast-path reads I had added in #516 read `$lineage_json` to look up `size_amd64_bytes`, `size_arm64_bytes`, etc. The `local lineage_json` declaration and `resolve_variant_lineage_json` call were further down in the function, after the sizes section, because the sizes section had been a self-contained operation in the original code.

`generate-dashboard.sh` runs under `set -euo pipefail`. Reading an unset variable kills the script. The script is wrapped in `2>/dev/null || true` at every variant call site (each variant runs in `$(collect_variant_json …)`), so the error was *silent* — the subshell crashed, the caller got an empty string, the dashboard happily fell back to the network for that variant. No log on stdout. No alert. Just the original perf bug, restored, behind a `set -u` violation.

The fix moves the lineage resolution to the top of the function:

```bash
[[ "$is_default" != "true" ]] && is_default="false"

# Lineage resolved EARLY so every lineage-first read below can consume it.
local flavor
if [[ "$is_versioned" == "true" ]]; then
    flavor=$(variant_property "$container_dir" "$variant_name" "flavor" "$version")
else
    flavor=$(variant_property "$container_dir" "$variant_name" "flavor")
fi
local lineage_json
lineage_json=$(resolve_variant_lineage_json "$container" "$variant_tag" "$version" "$fallback_base_image" "$flavor")

# Sizes — prefer lineage, fall back to network
# ... read $lineage_json safely ...
```

Before pushing, I wrote a real integration smoke test:

```bash
# Synthetic enriched lineage on disk
mkdir -p /tmp/test/.build-lineage
echo '{"container":"foo", "tag":"1.0", "build_digest":"abc",
       "multi_arch_index_digest":"sha256:idx", "size_amd64_bytes":12345 ...}' \
       > /tmp/test/.build-lineage/foo-1.0.json

# Mock the network functions to record every call
get_ghcr_sizes() { echo "NETWORK_CALL" >> "$NETCALLS"; }
ghcr_get_manifest_sizes() { echo "NETWORK_CALL" >> "$NETCALLS"; }
get_attestation_id() { echo "NETWORK_CALL" >> "$NETCALLS"; }

# Run the full collect_variant_json end-to-end
output=$(collect_variant_json "foo" "$TESTROOT/foo" "base" "1.0" "1.0" "alpine:3" "true")

# Assertions: enrichment in output, zero network calls
[[ $(jq -r '.multi_arch_index_digest' <<<"$output") == "sha256:idx" ]] || die FAIL
[[ ! -s "$NETCALLS" ]] || die "Network calls leaked"
```

The test failed locally before the move. After the move it passed: zero network calls, enrichment reaches the output. We pushed.

The next dashboard run ran the full step in **69 minutes**, but the network profile had finally dropped: 167 → 13 `ghcr-index` calls, 77 → 12 `gh-attestation`. The architectural fast path was active. And the dashboard was *still* taking 69 minutes.

## What was left

At this point we had a dashboard whose per-variant work was almost free (the 13 remaining ghcr-index calls were the genuine refreshes), and yet the step was still taking ~70 minutes. The trace markers we added next told the rest of the story — that's part 3 of the series.

But first the lesson worth pulling out of these four PRs.

## The integration smoke that wasn't there

Look at how each PR shipped:

- #516: 12 bats unit tests for `enrich-lineage.sh`. All green. Orthogonal gate clean. **Did not deliver the perf gain.**
- #517: workflow yaml change, 10 lines. Orthogonal gate clean. **Marginal perf gain.**
- #518: another 9-line workflow change. Orthogonal gate clean. **No perf gain.**
- #521: 13-line shell change. Orthogonal gate clean. **Crashed the dashboard with unbound variable errors.**
- #522: actual structural fix + integration smoke test. **Made the fast path activate.**

The first four PRs all *should* have been the fix. Every one of them was a real bug. Every one passed every test we ran on it. The integration smoke from #522 — synthetic enriched lineage on disk, mock network functions, call the full `collect_variant_json`, assert no network call fires — would have caught the bug in #521 (synthesizer drops the data), would have caught the bug in #522 itself (read-before-init), and would have surfaced the bug in #516 by failing at the next layer.

It would not have caught the bugs in #517 and #518 (those were workflow-level cache interactions that bats can't reach without simulating GitHub Actions cache semantics), but it would have caught the *script-level* issues much earlier in the chain.

The shape that applies to other optimizations:

**Unit tests for each side of a layer transition are insufficient.** If you have a producer (writes to a cache) and a consumer (reads from a cache), you need a test that synthesizes producer output, feeds it to the consumer, and asserts the fast path activates. Without that, the producer and consumer can be individually correct while their *handshake* is wrong — and there is no caller in production that does both in the test environment.

**A passing test can mask a missing test.** The 12 bats tests for `enrich-lineage.sh` proved it wrote the fields. They did not prove the dashboard read them. Each PR in the chain passed its tests because each PR was tested at the level it touched. The architectural transition — write here, read there — was tested nowhere until #522.

**`set -euo pipefail` plus per-call `2>/dev/null || true` is a silent-failure factory.** Strict mode catches bugs at the cost of crashing the subshell. The outer `|| true` then swallows the crash. The net effect is that bugs introduced under strict mode are *louder in logs* but *silent in behavior* than they would be in lax mode. Strict mode is still worth it; you just need linting or a smoke test to catch the silent-fallback class, because the script itself will not.

**Six PRs, four genuine bugs, all individually correct.** Layered optimizations have many handshakes. Each handshake is a place where one side can be right and the other side can be right and the combination can still be wrong. The cure is not "more PRs". The cure is one PR that exercises the full chain.

The dashboard was running at 69 minutes after #522. The architectural shift had landed, the cache was enriched, the dashboard was reading the cache, and the per-variant network work was gone. Yet the step was somehow nearly as slow as before. The next post — **2026-05-29** — is about what the trace markers found.

---

*Refs: [#515](https://github.com/oorabona/docker-containers/issues/515), [#517](https://github.com/oorabona/docker-containers/pull/517), [#518](https://github.com/oorabona/docker-containers/pull/518), [#521](https://github.com/oorabona/docker-containers/pull/521), [#522](https://github.com/oorabona/docker-containers/pull/522). Previous: [part 1]({% post_url 2026-05-25-dashboard-perf-architecture-build-time-lineage %}). Next: part 3 (2026-05-29).*
