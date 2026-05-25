---
layout: post
title: "The dashboard that did 540 network calls per regen (part 1 of 3)"
description: "Our containers dashboard step was taking 70+ minutes per refresh, almost entirely on per-variant GHCR fetches. This is the first of three posts on the fix: the architectural shift from per-regen network calls to build-time lineage enrichment — and why getting that shift right is harder than it looks."
date: 2026-05-25 10:00:00 +0000
tags: [ci, dashboard, perf, github-actions, jekyll, architecture, post-mortem, series-dashboard-perf]
---

The dashboard for [oorabona/docker-containers](https://github.com/oorabona/docker-containers) is a static Jekyll site that surfaces, for every container in the repo, its trust strip (digests, attestation links, SBOM packages, Trivy summary) and per-variant metadata. It is regenerated on every push to `master` and on every daily upstream-monitor cron. For about two weeks, that regen step had been quietly taking **between 70 and 80 minutes**.

This is the first of three posts on what we found and what we did about it.

- **Part 1 (this post)** — the diagnostic and the architectural shift: most of the work the dashboard did at regen time was wasted on data that does not change between regens.
- **Part 2 — coming 2026-05-27** — six PRs and the integration smoke test that wasn't there: each fix passed its unit tests, then masked the next bug.
- **Part 3 — coming 2026-05-29** — the bash builtin that hid a 30-minute hang.

The full result is at the end of part 3. The work was real and the architectural shift is the right answer, but it took us a chain of PRs to actually deliver the perf gain it promised. The story of why that took six PRs is part 2; this post is about what the right architecture even looked like.

## The symptom

The `Generate dashboard data` step in `update-dashboard.yaml` is the heart of the regen. It walks every container directory, for each container its versions, for each version its variants, and for each variant it emits a JSON record consumed by Jekyll templates. The job timeout had been bumped 15 → 40 → 90 minutes over two months as the step kept growing. The most recent runs were landing in the 70-79 min range — well past every previous bump.

A typical baseline run (`Generate dashboard data` step only):

```
Re-download SBOM artifacts:                            62s
Restore GHCR per-arch manifest cache:                   1s
Generate dashboard data:                             4780s   ← 79 min, the entire step
```

The first thing we did was look at the per-container time. The script logs `ℹ️  Processing <container>...` for every container as it enters its loop iteration, so the gap between two consecutive `Processing` lines is the cost of the previous container. Here it is in production:

| Container | Wall time |
|-----------|----------|
| ansible | 25 s |
| debian | 4 s |
| **github-runner** | **74 min** |
| jekyll | 5 s |
| openresty | 6 s |
| openvpn | 6 s |
| php | 9 s |
| postgres | 35 s |
| sslh | 4 s |
| terraform | 2 min |
| vector | 7 s |
| web-shell | 15 s |
| wordpress | 9 s |

One container, 93% of the step. We had a target, not a distributed problem.

Going one level deeper — every variant of `github-runner`:

```
ghcr-index oorabona/github-runner:2.334.0                          0.080s
ghcr-index oorabona/github-runner:2.334.0-dev                      0.080s
ghcr-index oorabona/github-runner:2.334.0-debian-trixie            0.080s
ghcr-index oorabona/github-runner:2.334.0-debian-trixie-dev        0.081s
ghcr-index oorabona/github-runner:2.334.0-windows-ltsc2022         0.063s
slurp guard fired for github-runner:2.334.0-windows-ltsc2022 … 38s after the line above
ghcr-index oorabona/github-runner:2.334.0-windows-ltsc2022-dev     0.059s
slurp guard fired for github-runner:2.334.0-windows-ltsc2022-dev … 22 minutes 50 seconds after the line above
```

Six Linux variants in ~3 seconds combined. Then a 38-second pause on the Windows base variant. Then **22 minutes** of total silence on Windows-dev. Three versions of `github-runner` were being retained (we keep the last three), so this was repeated three times.

A second baseline run, the next day, came in slightly worse. The gap on the slowest Windows-dev variant was 29 min, not 22. The pattern was real but its duration was non-deterministic.

## The audit

The instinct on a slow loop is to make the loop faster. Before doing that, we audited what `collect_variant_json` does per variant. Each call produces a JSON record with these fields:

| Field | Source | Mutable between regens? |
|-------|--------|--|
| `name`, `tag`, `description`, `is_default` | `variants.yaml` | No (config) |
| `variant_deps`, `when_to_use`, `extensions` | `config.yaml` | No (config) |
| `build_args` | `config.yaml` | No (config) |
| `build_digest`, `oci_subject_digest`, `base_image` | `.build-lineage/<tag>.json` | No (build artifact) |
| `size_amd64`, `size_arm64` | `ghcr_get_manifest_sizes` (network) | **No — set at push time** |
| `multi_arch_platforms` | `ghcr_get_manifest_sizes` (network) | **No — set at push time** |
| `multi_arch_index_digest`, `manifest_digest_{amd64,arm64}` | `ghcr_get_multi_arch_digests` (network) | **No — set at push time** |
| `attestation_id`, `attestation_url` | `gh api repos/.../attestations/<digest>` (network) | **No — set at attestation time** |
| `sbom_summary`, `sbom_packages` | `.build-lineage/<tag>.sbom.json` | No (SBOM artifact) |
| `changelog`, `build_history` | `.build-lineage/<tag>.changelog.json` | No (build artifact) |
| `trivy_summary.last_scan`, `counts` | code-scanning API (network) | Yes (scans run on schedule) |

Of the fields requiring network calls, **only `trivy_summary` is genuinely dynamic between regens**. Everything else is locked the moment the image is pushed (sizes, platforms, manifest digests) or the attestation is registered (attestation IDs). Those values do not change until the image is rebuilt and re-pushed.

Yet for every dashboard regen we were issuing, per variant:

- One call to `ghcr_get_manifest_sizes` (for sizes + platforms list)
- One call to `ghcr_get_multi_arch_digests` (for the index + per-arch digests)
- One call to `gh api .../attestations/<digest>` (for the attestation ID)

For 78 variant entries across the catalog, that is roughly 234 network calls per dashboard regen, **fetching data that has not changed since the last container build**. The dashboard regen runs many times per day (push events, cron, manual triggers). Most of those calls were producing the same answer as the previous regen.

The Windows-dev variants happened to be the worst case for unrelated reasons we'll get to in part 3, but the architectural problem applies to every variant: we were paying GHCR-pull latency for data that should have been computed once at build time.

The owner of the repo put it concisely:

> *If `github-runner` is rebuilt once per month, its stats should move once per month — not once per dashboard regen.*

## The contract

The fix is structural, not algorithmic. We already write a lineage JSON file at build time: `scripts/build-container.sh::_emit_build_lineage` is called by the per-arch build job after the push, and it writes `.build-lineage/<container>-<tag>.json` with `build_digest`, `oci_subject_digest`, `base_image_ref`, `build_args`, and a few other fields. That file is then bundled into a GitHub Actions cache by the `cache-lineage` job and restored by the dashboard regen.

The new contract: **add the 8 missing immutable fields to that same file, at the same time**. The dashboard reads them with a fallback to the network if the field is absent (for pre-migration lineage files, so the migration ships without invalidating any existing cache).

```text
                                         ┌──── enrich-lineage.sh ────┐
                  build job              │                           │
    push image  ──────────►  GHCR push   │  multi_arch_index_digest  │
                                ▼        │  manifest_digest_amd64    │
                   _emit_build_lineage:  │  manifest_digest_arm64    │
                     build_digest        │  multi_arch_platforms     │
                     oci_subject_digest  │  size_amd64_bytes         │
                     base_image_ref      │  size_arm64_bytes         │
                     build_args          │  attestation_id           │
                                ▼        │  attestation_url          │
                   cache-lineage job:    │                           │
                     merge per-arch      │  read fields once,        │
                     artifacts           │  write back to lineage    │
                                ▼        │                           │
                   .build-lineage/       └─────────── ▲ ─────────────┘
                   <container>-<tag>.json    ────────►│
                                ▼
                   GH Actions cache
                                ▼
                   dashboard regen reads cache, calls collect_variant_json,
                   variant_json reads lineage_first; network fallback only
                   when fields are absent
```

The choice that made the implementation tractable: do the enrichment **once per build run**, inside the `cache-lineage` job, after the per-arch artifacts have been merged. That job already had GHCR auth via `GITHUB_TOKEN` and runs on `ubuntu-latest`. It also runs every time something gets built, so the lineage cache it saves is always at least as fresh as the most recent build.

Two things make this safe to ship as a single PR:

**Reuse the existing helpers.** `helpers/registry-utils.sh::ghcr_get_manifest_sizes` and `ghcr_get_multi_arch_digests` already implement the GHCR queries the dashboard was making. Same code path, called at a different time. No new query logic to validate.

**Graceful fallback on the read side.** `generate-dashboard.sh::collect_variant_json` now checks each enrichment field in lineage_json; if any are absent, it falls through to the original network call. Pre-migration lineage files (which won't have the new fields until they're rebuilt) keep working unchanged.

## The implementation

`scripts/enrich-lineage.sh` is the new helper. It walks `.build-lineage/*.json`, skips auxiliary files (`*.sbom.json`, `*.changelog.json`, `*.history.json`, `ext-*.json`), and for each container lineage file:

1. Reads `container`, `tag`, `oci_subject_digest` via `jq`.
2. Checks idempotency: if `multi_arch_index_digest` is already non-null, the file is enriched — skip it. This makes the script safe to re-run.
3. Calls `ghcr_get_multi_arch_digests "$image_path" "$tag"` for the index + per-arch digests.
4. Calls `ghcr_get_manifest_sizes "$image_path" "$tag"` for the per-arch byte sizes and the platform list.
5. Calls `get_attestation_id "$oci_subject_digest"` (and `get_attestation_url`) for the attestation pair.
6. Merges all 8 fields into the lineage file in a single `jq` call, atomic `mktemp` + `mv`.

A per-file failure (GHCR transient error, missing attestation) logs a soft notice and continues. The whole batch is fault-tolerant: one bad container's lineage cannot stop the others.

The workflow change is two lines, one new step in the `cache-lineage` job:

```yaml
- name: Enrich lineage with multi-arch manifest data
  if: steps.merge.outputs.has_files == 'true'
  env:
    GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    GITHUB_REPOSITORY: ${{ github.repository }}
  run: |
    chmod +x scripts/enrich-lineage.sh
    ./scripts/enrich-lineage.sh --owner "${{ github.repository_owner }}"
```

The `cache-lineage` job's `sparse-checkout` was extended to include `scripts/` (it only had `helpers/`). The enriched lineage is then saved back to the same Actions cache the dashboard restores.

On the dashboard side, `collect_variant_json` reads lineage-first in three regions:

```bash
# Sizes — prefer lineage, fall back to network
lineage_size_amd64=$(echo "$lineage_json" | jq -r '.size_amd64_bytes // empty')
if [[ -n "$lineage_size_amd64" && "$lineage_size_amd64" =~ ^[0-9]+$ ]]; then
    size_amd64=$(awk -v b="$lineage_size_amd64" 'BEGIN{printf "%.1fMB", b/1048576}')
fi
# (similar for arm64)

if [[ -z "$size_amd64" && -z "$size_arm64" ]]; then
    sizes_raw=$(get_ghcr_sizes "oorabona/$container" "$variant_tag" 2>/dev/null) || true
    # ... existing network-derivation logic ...
fi
```

Same idiom for the multi-arch digest fast path and the attestation lookup. The fallback is intentionally conservative: only when *every* expected field is absent do we fall through to the network call, so a partially-enriched lineage still uses the values it has.

## What changed empirically

After the PR landed and the next auto-build enriched the lineage cache, the per-variant network profile dropped sharply:

| Metric | Before | After |
|--|--|--|
| `ghcr-index` latency entries per dashboard regen | 167 | 13 |
| `gh-attestation` latency entries per dashboard regen | 77 | 12 |

The remaining 13 + 12 are containers whose lineage hasn't been rebuilt yet (so the fallback fires) plus a handful of legitimate refreshes (a non-variant code path we left for follow-up). For every container with an enriched lineage, the per-variant work became a sequence of local file reads and one short `jq` invocation.

This is the win. The architecture moved 95% of the per-variant work from "I do this on every dashboard regen" to "I do this once when the image gets built", which is where it belonged.

## What didn't change

The dashboard step duration. From 79.7 min to 83 min, to 70, to 72, depending on the run. There was a problem we had not yet found — and it was not visible from the network profile.

The architectural shift turned out to be necessary but not sufficient. The next post in this series — **2026-05-27** — walks through six PRs of getting an architectural fix to actually pay off, and the integration smoke test we wished we had written.

## What this post is also about

If you read this and the only thing you take away is `enrich-lineage.sh`, you've taken the wrong lesson. The shape that applies to other systems:

**Audit the loop, not the iteration.** Speeding up `collect_variant_json` by 2× would not have moved the needle. Asking "what is this loop doing that shouldn't run at all" did. Field-by-field mutability classification is a cheap exercise that finds wasted work.

**Build-time computation is the cheapest cache.** If a value is locked at build time, it should be persisted by the build, not re-derived on every reader. The reader gets file I/O instead of network I/O, which is two to four orders of magnitude faster and survives the producer being offline.

**Ship the fallback, not just the optimization.** A reader that prefers the cached value but can degrade to the network call when the cache is incomplete is shippable in a single PR. A reader that hard-requires the cache must wait for every producer in the catalog to be rebuilt first — a much slower migration story.

The architectural answer was the right answer. Part 2 of this series is about the six PRs it took to make that answer actually arrive.

---

*Refs: [#515](https://github.com/oorabona/docker-containers/issues/515), [#516](https://github.com/oorabona/docker-containers/pull/516). Code: [`scripts/enrich-lineage.sh`](https://github.com/oorabona/docker-containers/blob/master/scripts/enrich-lineage.sh), [`generate-dashboard.sh::collect_variant_json`](https://github.com/oorabona/docker-containers/blob/master/generate-dashboard.sh).*
