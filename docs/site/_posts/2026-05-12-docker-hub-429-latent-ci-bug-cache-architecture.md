---
layout: post
title: "When Docker Hub Starts Rate-Limiting: Anatomy of a Two-Month-Old Latent CI Bug"
description: "A regression that slept for 56 days, surfaced by Docker Hub HTTP 429s. The story of why our base image cache was silently bypassed, what `|| true` cost us, and how we structured the cache to actually survive rate limits."
date: 2026-05-12 10:00:00 +0000
tags: [ci, docker, ghcr, debugging, base-images, rate-limiting]
---

On April 28th, the daily auto-build for the `terraform` container failed. So did the next dependency PR. And the next. The pattern was always the same: build of `terraform:full` collapsed pulling `python:3.12-alpine` from Docker Hub with HTTP 429 — Too Many Requests.

This is the post-mortem of a bug that had been latent for **56 days** before Docker Hub's rate limiter exposed it. It is also a story about why `|| true` is rarely the right answer, and why we redesigned the base image cache verification step so the next regression doesn't sleep for two months.

## The symptom

```
ERROR: failed to copy: httpReadSeeker: failed open: unexpected status from
GET request to https://registry-1.docker.io/v2/library/python/manifests/...
: 429 Too Many Requests
```

Two days in a row, three failing PRs, all on `terraform:full` (the variant that bundles AWS CLI, Azure CLI, and Google Cloud SDK on top of Alpine — three distinct multi-MB downloads at build time).

The first hypothesis was the obvious one: **transient Docker Hub rate-limiting**. Every CI engineer running anonymous pulls in 2026 has lived this. Wait an hour, re-run, move on.

Except this project has a base image cache. Every base image referenced by a `FROM` line is supposed to be mirrored to GHCR — `python:3.12-alpine` → `ghcr.io/oorabona/python-base:3.12-alpine`. The build step is supposed to pull from GHCR, not Docker Hub. So we shouldn't be hitting registry-1.docker.io at all for these images.

Yet the error came from `registry-1.docker.io`.

## First red flag: the cache job said it succeeded

The `cache-base-images` job runs before every build and copies upstream images into our GHCR namespace. Its log for the failing run was clear:

```
🔄 Caching python:3.12-alpine → ghcr.io/oorabona/python-base:3.12-alpine
  ✅ Cached successfully
```

The cache job reported success for `python:3.12-alpine`. Yet the build still hit Docker Hub. Something between "image is in GHCR" and "build uses it" was broken.

## Reading the build action carefully

The `build-container` composite action has a verification step that decides whether to inject GHCR-rewriting build-args:

```bash
cache_args=$(get_cache_build_args "./$container" "$owner" "$build_version")
if [[ -n "$cache_args" ]]; then
  first_image=$(echo "$cache_args" | grep -oE 'ghcr\.io/[^ ]+' | head -1)
  first_cache_tag=$(yq -r '.base_image_cache[0].tags[0]' "./$container/config.yaml")
  check_image="${first_image}:${first_cache_tag}"
  if docker manifest inspect "$check_image" &>/dev/null; then
    export CUSTOM_BUILD_ARGS="${CUSTOM_BUILD_ARGS:+$CUSTOM_BUILD_ARGS }$cache_args"
    echo "✅ Using GHCR base images: $cache_args"
  else
    echo "⚠️ GHCR cache image not accessible — using Docker Hub defaults"
  fi
fi
```

The intent is sensible: before we tell `docker build` to rewrite `${PYTHON_BASE}` to `ghcr.io/.../python-base`, verify at least one cached image is actually reachable in GHCR. If the cache pipeline failed silently, this fallback prevents a confusing `manifest unknown` mid-build.

Now look at line 4. For the `terraform` container, `config.yaml` declares:

```yaml
base_image_cache:
  - arg: TERRAFORM_BASE
    source: hashicorp/terraform
    ghcr_repo: terraform-base
    tags: ["${UPSTREAM_VERSION}"]   # <-- Templated tag
  - arg: ALPINE_BASE
    ghcr_repo: alpine-base
    tags: ["latest"]
  - arg: PYTHON_BASE
    ghcr_repo: python-base
    tags: ["3.12-alpine"]
```

The first entry's tag is `${UPSTREAM_VERSION}` — a literal string in the YAML, intended to be resolved at build time to `1.14.9` (the actual terraform version being built).

The verification step reads this tag with `yq` and never resolves the template. So `check_image` becomes the literal string `ghcr.io/oorabona/terraform-base:${UPSTREAM_VERSION}`. `docker manifest inspect` on that always fails — it is not a valid tag.

Result: the verification step always took the failure branch, dropped `cache_args`, and the build fell through to Docker Hub defaults. Every time. For every terraform build. For 56 days.

## Why didn't it explode in March?

The bug was introduced in commit `9e4f1a8` on **2026-03-06**, while adding the verification fallback itself ("safer to check before injecting"). The check failed the same way every day from March 6th onward. We just never noticed, because:

1. The project authenticates to Docker Hub with a paid PAT for pushes. Anonymous pulls were still well under the unauthenticated rate limit.
2. Most builds use the cache successfully via direct `docker buildx build` calls in our `make` script — the GHCR rewrite is one optimization layer among many.
3. The terraform image specifically is rebuilt rarely (deps PRs every week or two), so the failure window was narrow.

Then on April 28th something shifted at Docker Hub — possibly stricter throttling on the GitHub Actions IP range, possibly a quota policy change, definitely something we didn't control. The latent fallback path stopped silently working, and the build started failing loudly.

This is a Hyrum's Law moment: **every behavior, including failure modes, becomes a contract**. The verification step's quiet fallback to Docker Hub was an undocumented but very real dependency on Docker Hub being permissive. When the upstream environment changed, the dependency surfaced as an outage.

## The fix

Two lines, fundamentally:

```diff
- first_cache_tag=$(yq -r '.base_image_cache[0].tags[0]' "./$container/config.yaml")
- check_image="${first_image}:${first_cache_tag}"
+ raw_tag=$(yq -r ".base_image_cache[$i].tags[0]" "./$container/config.yaml")
+ resolved_tag=$(_resolve_tag_template "$raw_tag" "$build_version" "./$container/config.yaml" "./$container")
+ check_image="ghcr.io/${owner}/${ghcr_repo}:${resolved_tag}"
```

We were already exporting `_resolve_tag_template` from `helpers/base-cache-utils.sh` — it handles `${VERSION}`, `${UPSTREAM_VERSION}`, and arbitrary `${KEY}` lookups against `build_args`. We just weren't calling it. While we were there, we also iterated every `base_image_cache` entry instead of only the first — a single unavailable image (transient GHCR hiccup) shouldn't disable the cache entirely.

After the fix, the same terraform rebuild's log confirmed the cache was being used:

```
✅ GHCR cache verified via ghcr.io/***/terraform-base:1.14.9
✅ Using GHCR base images:  --build-arg TERRAFORM_BASE=ghcr.io/***/terraform-base
                            --build-arg ALPINE_BASE=ghcr.io/***/alpine-base
                            --build-arg PYTHON_BASE=ghcr.io/***/python-base

#10 [cloud-tools-gcp 1/2] FROM ghcr.io/***/python-base:3.12-alpine@sha256:...
#11 [terraform 1/1]       FROM ghcr.io/***/terraform-base:1.14.9@sha256:...
#12 [devops-tools 1/3]    FROM ghcr.io/***/alpine-base:latest@sha256:...
```

Twelve `FROM ghcr.io/...` resolutions in the build output. Zero pulls from `registry-1.docker.io`. 32 jobs success, 0 failures.

## The deeper lesson: `|| true` is a smell

After the cache fix, one residual `429` showed up in the post-build phase, in this snippet:

```bash
if [[ "${{ steps.push-dockerhub.outputs.success }}" == "true" ]]; then
  dh_src="docker.io/$image_name:$current_tag-$platform_suffix"
  dh_dst="docker.io/$image_name:$current_tag"
  docker buildx imagetools create -t "$dh_dst" "$dh_src" || true
fi
```

This step creates a `IMAGE:TAG` (without arch suffix) on Docker Hub, pointing to the per-arch image we just pushed. `imagetools create` does a manifest GET on the source, and that GET hit the rate limit. The `|| true` swallowed the error.

Two problems:

1. **The step was redundant on Linux.** The dedicated `create-manifest` job runs after every build and creates the multi-arch manifest list at the same address (`IMAGE:TAG`), which immediately overwrites whatever single-arch alias this step produced. Linux didn't need the alias. We were paying a Docker Hub round-trip and a 429 risk for nothing.
2. **The `|| true` masked the failure.** When the alias creation broke, no warning, no telemetry. We only noticed because the error message got captured in the surrounding log capture.

We dropped the alias on Linux entirely (the manifest job handles it), kept it on Windows (where there is no manifest job — Windows containers are amd64-only by ecosystem convention), and replaced `|| true` with `retry_with_backoff 5 30` from `helpers/retry.sh`. If the operation truly fails after five 30-second-backoff attempts, the build fails. No more silent skips.

## Here's how we structured the cache to survive 429s

The architecture before the fix was already mostly right. The pipeline has four pieces, each with one job:

**1. Declaration.** Every container's `config.yaml` declares its base image cache requirements:

```yaml
base_image_cache:
  - arg: PYTHON_BASE          # build-arg name in the Dockerfile
    source: python            # upstream Docker Hub image
    ghcr_repo: python-base    # destination GHCR repo
    tags: ["3.12-alpine"]     # explicit tags or templates
```

**2. Population.** A daily `cache-base-images` job iterates every container's declarations, dedup by GHCR target, and copies each unique upstream image to GHCR. This runs *before* every build job. If Docker Hub rate-limits the cache job, the existing GHCR entry remains usable from yesterday's run — graceful degradation built in.

**3. Verification (the fixed piece).** Before each build, `get_cache_build_args` constructs the `--build-arg` flags that rewrite Dockerfile `FROM ${VAR}:tag` references to point at GHCR. We then iterate the declared cache entries, resolve each tag template via `_resolve_tag_template`, and call `docker manifest inspect` on each. If at least one is reachable, we trust the pipeline ran and inject the rewrites. Iterating *all* entries (not just the first) means a single transient GHCR error doesn't disable the whole cache.

**4. Audit.** A non-blocking script — `scripts/audit-base-image-cache.sh` — runs daily, parses every `FROM` directive in every Dockerfile (template-aware), resolves `${VAR}` substitutions against `build_args`, and reports each as `cached`, `uncached-expected` (legal/DRY exceptions), or `GAP` (unexpected). It writes a markdown table to `$GITHUB_STEP_SUMMARY` on every dashboard run. Today's coverage:

| Metric | Count |
|--------|-------|
| Cached | 16/21 |
| Uncached (expected: Microsoft Windows redistribution restriction + GHCR self-references) | 5 |
| Unexpected gaps | **0** |

If a future container introduces a `FROM` not declared in any `base_image_cache`, the audit will flag it the next morning — long before the inevitable Docker Hub 429 surfaces it as an outage.

## Lessons learned

- **`|| true` should be reserved for genuinely optional operations.** If the failure mode matters — and "we silently fall back to Docker Hub" matters — surface it. Either retry properly or fail loudly. A defensive `|| true` is a debt that comes due when the environment changes.

- **Verification logic is itself a contract.** When you add a "before we use X, check X exists" guard, the *exact* check must match how X is constructed downstream. Mismatched tag templates between verification and consumption will cause silent fallback for as long as the fallback path is permissive.

- **Latency between regression and detection is the real metric.** The bug was 56 days old when it surfaced. The fix took an afternoon. The **investment that paid off** was tooling — log parsing, audit scripts, observability — that compressed those 56 days into 4 hours of debugging. The fix is not the deliverable; the next-time-it-happens MTTD is.

- **Hyrum's Law applies to environment too.** Docker Hub being permissive was an undocumented dependency of our CI. We don't control Docker Hub. We do control whether we have a real cache or just a hopeful fallback. Now we have the former, with audit visibility on the boundary.

The full diff lives in commits `04ab78f` (verification fix), and the audit script is in `scripts/audit-base-image-cache.sh`. The build pipeline is `.github/workflows/auto-build.yaml` — the cache flow is documented inline.

The next time Docker Hub changes its rate limit policy, we want to find out from a dashboard, not from a build outage three days later.
