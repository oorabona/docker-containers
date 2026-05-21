# ADR-009: Transparent Docker Hub pull-through mirror on the runners (eliminate 429 without touching Dockerfiles)

**Status:** Accepted
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

**Implementation tracking:** issue #488. Reference for the buildkitd config-inline
and `registry:2` proxy wiring to be captured in the shared composite action.
