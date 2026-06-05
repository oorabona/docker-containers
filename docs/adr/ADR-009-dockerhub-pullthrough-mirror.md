# ADR-009: Transparent Docker Hub pull-through mirror on the runners (eliminate 429 without touching Dockerfiles)

**Status:** Superseded by #498 (2026-05-23) — see "Why this was removed" below
**Date:** 2026-05-21

## Context

Full-matrix CI builds recurrently fail with `docker.io/library/<base>:<tag>`
HTTP 429 (Too Many Requests): anonymous Docker Hub pulls from shared
GitHub-hosted runner IPs exceed the per-IP rate limit, and the problem worsens
as the container count grows.

The repository already mirrors base images into GHCR (`alpine-base`,
`postgres-base`, …) via nightly skopeo copies, consumed best-effort through a
CI-time build-arg override (`helpers/base-cache-utils.sh get_cache_build_args`).
When the override does not apply (a generator that ignores it, a one-ARG
`FROM ${X_BASE}` resolving to an implicit `:latest` the cache lacks, any path
the override misses), the build falls back to the Dockerfile's Docker Hub
default → 429.

Two mechanisms can remove Docker Hub from the matrix build path:

1. **Authoritative GHCR in the FROM** — default every base ARG to the GHCR
   copy (`FROM ghcr.io/owner/<repo>:<tag>`), demote Docker Hub to a manual
   fallback. Requires per-Dockerfile changes across the fleet.
2. **Transparent pull-through mirror** — leave Dockerfiles as
   `FROM <upstream>:<tag>` and route `docker.io/*` through a pull-through cache
   configured at the runner / buildkitd layer.

GHCR is a plain registry: it serves only what was explicitly pushed and returns
404 on a miss (no auto-fetch, no `library/*` namespace mapping). It therefore
cannot itself be a transparent `registry-mirrors` target for `docker.io`; a real
pull-through cache (e.g. `registry:2` in proxy mode) is required for mechanism 2.

## Hard constraint: everything stays inside GitHub

Non-negotiable: Actions, caching (`actions/cache` + GHCR), the published image
registry (GHCR), and dashboard hosting (GitHub Pages) all remain exactly as
today. **No component may live outside GitHub.** The only external endpoint is
`docker.io` itself — the upstream origin of base images, touched solely on a
cold cache miss and authenticated. That is irreducible (it is the source of the
images) and is not infrastructure this project hosts.

The chosen hosting model below is the only one that satisfies this constraint:
the pull-through proxy is an ephemeral container that runs ON the GitHub runner
inside the job; its backing store is `actions/cache`; its backend credentials
are a GitHub secret. GHCR remains the published-image registry, Pages remains
the dashboard host, Actions remains the CI — all unchanged.

## Decision

Adopt **mechanism 2 — a transparent Docker Hub pull-through mirror configured on
the runners**. Dockerfiles keep their canonical upstream references
(`FROM postgres:18-alpine`); fetch routing is infrastructure configuration the
maintainer controls, not source.

Rejected mechanism 1 (authoritative GHCR in the FROM):
- It bakes a registry choice into source — a portability and vendor-lock
  regression. `FROM postgres:18-alpine` works for anyone who clones the repo;
  `FROM ghcr.io/oorabona/postgres-base` does not.
- It overrides a downstream consumer's own mirror configuration — if a consumer
  runs their own pull-through cache, hardcoding GHCR in the FROM defeats it.
- It forces ongoing compromises as upstream references evolve.

Hosting model: **per-job sidecar pull-through cache with an `actions/cache`
backing store** (no external always-on infrastructure):
- Each job that pulls `docker.io` starts a `registry:2` proxy
  (`REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io`) bound to a local
  port, with Docker Hub credentials on the proxy backend so even cold upstream
  fetches are authenticated (higher limit).
- buildkitd is pointed at it via `setup-buildx-action` config-inline
  (`[registry."docker.io"] mirrors = ["http://localhost:<port>"]`).
- The proxy's storage directory is persisted across runs with `actions/cache`
  (rotating key + restore-keys), so warm entries survive job-to-job and most
  pulls are served locally — Docker Hub is touched only on a genuine cold miss,
  authenticated.

Rejected hosting alternatives:
- Persistent external pull-through cache: requires a public-facing always-on
  service to host, secure, and pay for, and adds a runtime dependency on its
  uptime.
- Self-hosted-runner-co-located cache: couples the solution to where CI runs;
  the matrix is predominantly GitHub-hosted.

A 404 from the mirror on a genuinely-absent image is acceptable and expected —
the mirror does not mask absence.

The routing wiring (start sidecar + configure buildkitd) is implemented ONCE as
a shared composite action used uniformly by every job that pulls `docker.io`
(cache-population, extension builds, the build matrix, manifest creation) — no
per-job duplication, consistent treatment from the simplest container to the
most complex.

## Consequences

**Positive**
- Docker Hub leaves the matrix build path; 429 cannot fail a build. Scales to
  any number of containers with zero per-container work.
- Dockerfiles stay portable and canonical; downstream consumers keep their own
  mirror configuration.
- New containers are covered automatically — no Dockerfile change, no new cache
  entry.
- Subsumes the best-effort build-arg override: with a transparent mirror, no
  Dockerfile needs a GHCR override, so the per-Dockerfile ARG-pattern
  convergence (the A1 work in #488) stops being load-bearing for the 429 and
  becomes optional consistency cleanup rather than a prerequisite.

**Negative / mitigations**
- The first pull of an uncached base on a cold `actions/cache` still reaches
  Docker Hub — but authenticated (proxy backend creds), so under the higher
  limit, and warmed for subsequent jobs.
- The existing GHCR base-image cache repos + skopeo-copy job + the
  `get_cache_build_args` override become redundant for 429-avoidance once the
  mirror is proven; deprecate them in a follow-up rather than removing eagerly.
- The sidecar registry must be reachable from buildkitd (host networking /
  `docker` driver); verify per build driver during implementation.

**Implementation tracking:** issue #488.

## Implementation (issue #488)

Shipped as the shared composite action `.github/actions/dockerhub-mirror`
plus the buildkitd config `.github/buildkitd-mirror.toml` (both since removed — see
"Why this was removed" below).
The action restored a `registry:2` pull-through store from `actions/cache`, started
the proxy on `127.0.0.1:5000` (`REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io`
plus Docker Hub backend credentials), fail-closed on an unhealthy proxy, and let
`actions/cache` persist the store on a per-job key.

Wiring (per job that pulled `docker.io` through `docker buildx build`):
`docker.io login → dockerhub-mirror → setup-buildx-action` with
`driver-opts: network=host` and **`buildkitd-config: .github/buildkitd-mirror.toml`**
(the `network=host` driver-opt is how the `docker-container` buildkitd reached the
host-published proxy; `buildkitd-config` — not `config` — is the setup-buildx-action
input that loads the mirror, the latter being silently ignored).

Scope verified at implementation time (the "verify per build driver" step above):
only the buildx-build pull path is mirrored — the **build matrix** (via the
`build-container` action) and **build-extensions**. `cache-base-images` and
`create-manifest` pull `docker.io` through `docker buildx imagetools create`, which
resolves source manifests directly against the upstream registry and does not honor
the buildkitd mirror; they remain on authenticated direct pull. `cache-base-images`
is made non-blocking (`continue-on-error: true`) so its un-mirrorable rate-limit
cannot fail the workflow — `build-and-push` carries the mirror as the safety net, and
also seeds a digest-pinned `registry:2` into GHCR so the proxy image itself is pulled
intra-GitHub.

Once the mirror was observed eliminating the rate-limit on full-matrix runs, the GHCR
base-image-copy repos, the skopeo-copy job, and the `get_cache_build_args` build-arg
override became redundant for rate-limit avoidance and were removed in subsequent PRs.
Design + hardening: `docs/plans/488-dockerhub-mirror.md`.

## Why this was removed (#498, 2026-05-23)

The pull-through sidecar was introduced to protect the build path from 429s
when Dockerfiles referenced `FROM docker.io/...`. Two subsequent changes made
this protection redundant:

- **#492** fixed the root cause that was forcing builds into the docker.io
  fallback (the GHCR cache check used `:latest` instead of the version tag,
  so the override was silently dropped and builds went straight to docker.io
  even when GHCR was warm).
- **#493 / #497** migrated containers to `FROM ${REMOTE_CR}/<upstream-path>`,
  where `REMOTE_CR` resolves to `ghcr.io/<owner>` when the GHCR cache is
  reachable for that tag. Builds with a warm cache no longer touch docker.io
  at all.

After these two changes, the only remaining docker.io consumers were the
seed jobs (`cache-base-images` and `refresh-base-image-cache`). These two
jobs did near-identical work on different triggers (push vs daily cron),
each with its own ~70-line inline shell loop. #498 consolidated them into
a single `sync-base-images` job in each workflow, both calling a shared
`sync_base_images_to_ghcr` helper in `helpers/base-cache-utils.sh`.

The helper performs a blind copy: each base image is unconditionally
mirrored from `docker.io/<path>:<tag>` to `ghcr.io/<owner>/<path>:<tag>`
via `docker buildx imagetools create`. No presence-check, no digest-compare,
no sidecar cache layer. The math justifies this simplicity:

- N ≈ 15 unique base images per run today (sum of deduped `base_image_cache`
  entries across detected containers, or all containers for the daily run).
  Headroom for growth: even at N = 30 the budget still holds.
- Auth'd Docker Hub rate limit: 200 pulls per 6h per user.
- Steady-state load (N = 15): ~15 pulls × ~5 runs / 6h = ~75 pulls per 6h
  window, ~38% of the 200 budget.
- Burst (release flurry): the helper retries each rate-limited call with
  exponential backoff (5s, 10s, 20s; max 3 retries) before giving up. Non-
  429 failures (auth, network) fail fast. Persistent failures after backoff
  are bounded by `continue-on-error: true` on the job and per-image error
  handling, so any spike that exceeds the per-IP budget just degrades to
  a missing/stale GHCR tag — which the next push or the daily sync recovers.
  Dependent jobs are never blocked.

The `dockerhub-mirror` composite action and `.github/buildkitd-mirror.toml`
were removed (2026-06-05, PR #647) once the new design had run in production.
No workflow invokes them.
