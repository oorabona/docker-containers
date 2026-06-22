# ADR-015: Automated (content-addressed) postgres extension image identity

- **Status:** Accepted (design); implementation deferred
- **Date:** 2026-06-22
- **Tracking:** [#801](https://github.com/oorabona/docker-containers/issues/801)
- **Relates:** ADR-014 (dependency & supply-chain strategy), ADR-002 (smart rebuild detection)

## Context

The postgres extension build prefilter keys an extension image only on its upstream **version** (`ext-<name>:pg<major>-<version>`). So a same-version change to a build input — the Dockerfile, the Rust toolchain, a build dep — silently reuses the existing image: the change is never rebuilt or validated. The trigger was pinning the paradedb Rust toolchain (so a new stable Rust can't silently break the pgrx build); the pin is correct but inert under the version-keyed prefilter until something forces a rebuild.

The operator's hard requirement: the rebuild decision must be **fully automated and deterministic** — **no manual revision bump, no PR check**. The system must autonomously rebuild when (and only when) a build input changes.

## What we tried, and what was rejected

A first implementation added a manual `build_revision` field to the image identity (`…-r<rev>`) plus a PR check that failed a PR when a build input changed without a revision bump. The **identity mechanism** (threading the suffix through ~23 producer/consumer sites, cleanup completeness, multi-arch composition) is sound and reusable. What the operator rejected is the **human-process parts**: the *manual* bump and the *check* enforcing it — they defeat "fully automated." That PR check also proved to be a persistent source of robustness and security problems: it ran on every pull request, read branch-controlled content, and executed logic on it — yielding failure modes such as self-neutering, fail-open on malformed config, and workflow-command injection.

## The chosen direction: content-addressed identity

Replace the manual `-r<rev>` suffix with an **auto-derived content hash of the build inputs**: `ext-<name>:pg<major>-<version>-h<hash>`. Same tag shape, **same threading reused**; only the suffix *source* changes (manual → computed). Then the prefilter naturally rebuilds when the hash changes and reuses when it doesn't — self-correcting, no bump, no PR check. The PR check, the `build_revision` field, and the numeric-revision retention are deleted.

This was pressure-tested **before any code** via a written spec subjected to three independent design reviews (one adversarial, plus a two-engine consensus). All three converged on the same verdict: **the pure content-addressed design is not implementable as-is**, because the current extension builds are **not reproducible functions of the hashable inputs**.

### The core finding (unanimous across the three reviews)

The hash would cover *declared* inputs (package names, floating refs) while the builds resolve content at build time that the hash never captures:
- `apk add build-base clang-dev …` — package **names, not versions**; Alpine repos roll, so the compiled `.so` drifts while the hash is unchanged (silent stale reuse), and amd64/arm64 resolve **different** package versions under one shared hash.
- `curl https://sh.rustup.rs | sh` — unpinned installer/components.
- `git clone --branch v${VERSION}` — a **mutable tag**, not a commit SHA.
- `PGRX_VERSION=$(grep … Cargo.toml)` — discovered at build time, not in config.
- `FROM postgres:N-alpine` — floating base tag (per-arch digests differ).
- `build_date=$(date)` stamped **into the COPY'd artifact** → two builds, same hash, different content.
- A **circular hash**: if the generated Dockerfile carries `LABEL input_sha256=<hash>`, its bytes depend on the hash that depends on its bytes.

**The multi-arch contradiction** is structural: a *single shared* hash across arches is incompatible with hashing *per-arch* resolved content (apk versions, base digest). You can have one or the other, not both, silently.

### Two coherent ways to deliver the requirement

- **(A) Full reproducible builds + content-addressing.** Resolve and pin every input once before fan-out into a lock artifact (resolved apk closure **per arch**, source commit SHA, base **per-arch** digest, exact Rust toolchain + pgrx, all `FROM` digests, strip timestamps from the output layer), use **per-arch hashes** combined at the manifest level, hash the resolved/expanded Dockerfile (not the template, no label cycle), forbid unresolved network during build. This is true determinism — and a substantial project (industry-hard; bit-reproducible Docker builds are ~2.7% of images). Note: pinning apk to exact versions is itself infeasible/fragile (distro repos keep only the latest → exact pins 404; cf. ADR-014), so A's apk story must hash the *resolved closure per arch*, which forces per-arch hashes and a resolve-before-skip cost.
- **(B) Pragmatic automated rebuild.** Hash the **declared intent** (extension version, `rust_version`, resolved/expanded Dockerfile bytes, build-affecting config, source identity) — which catches the **common** build-input changes and triggers an automatic rebuild, no bump, no check. Lean on the **existing base-digest-drift** mechanism (which already rebuilds when the base image — and thus the apk world — changes) plus a **periodic time-bounded rebuild backstop** to sweep residual apk drift. Automated and deterministic *for declared inputs*; honestly not bit-reproducible. Much smaller; reuses the existing identity threading and the base-drift infrastructure (which already records base digests).

## Decision

**Adopt (B)** as the target design; **defer implementation** (capture it here, build it as a focused project).

Rationale: (B) delivers the autonomy the requirement actually needs — no manual bump, no check, automatic rebuild on input change — and its only gap (a pure Alpine-toolchain micro-drift not reflected in the hash) is low-impact (the extension still works; it's just not on the newest toolchain) and is largely covered by the existing base-digest-drift plus a periodic backstop. (A)'s full bit-reproducibility is a large, complex project (per-arch hashing, resolved-closure locks, resolve-before-skip cost) for a marginal gain over (B)+base-drift+periodic. If bit-level reproducibility ever becomes a hard requirement, (A) is documented here and is a strict superset of (B).

**Ship now:** only the Rust toolchain pin (the concrete, correct win). The `build_revision` work is **not merged** (it carries the rejected manual/check model) but is **retained as reference** for (B)'s threading — see Reuse.

## Reuse map (what (B) builds on)

Reuse: the identity-suffix **threading** through `ext_image_name` / `ext_ref_resolve` / the prefilter exact-ref check / `generate_dockerfile` FROM+COPY / manifest finalize / lineage; the cleanup **completeness** check (manifest + amd64 + arm64) and multi-arch composition; the fail-closed patterns. Replace only the suffix **source** (`build_revision` → computed hash). Delete: the PR-check job + `scripts/guard-extension-build-inputs.sh`, the `build_revision` config field + its validation, the numeric-revision retention ordering.

## Implementation plan for (B) (deferred)

1. Define the **declared-input record** (canonical JSON, schema-versioned): extension, pg_major, resolved version, source identity (resolve the upstream tag to a **commit SHA** — mandatory, fail-closed if unresolvable), build-affecting config (`rust_version` exact, normalized `build_deps`/`runtime_deps`, `shared_preload`), and the **resolved/expanded** Dockerfile bytes (not the template).
2. Resolve mutable inputs **once before fan-out**; the record is the single source of truth.
3. Hash → `…-h<hash>`; reuse the threading. Avoid the **label↔Dockerfile cycle** (compute the hash from a template with canonical placeholders, add provenance labels in a derived phase).
4. Cleanup: **mark-and-sweep**, two-phase — a flavor build records its ext-hash dependency **before** publish; cleanup serializes against publish (or a grace window ≥ max build time) and re-checks references immediately before delete; completeness fail-closed.
5. Move `PGRX_VERSION` into config (a hashed input); strip `build_date`/timestamps from the output layer.
6. The **periodic rebuild backstop** + the existing base-digest-drift cover residual apk drift.

## Consequences

- No manual bump, no PR check (its whole problem surface is removed).
- Automatic rebuild on any declared build-input change; reuse otherwise.
- Honest limitation: pure Alpine package micro-drift is swept periodically / via base-drift, not per-hash. Documented, not silently assumed.
- The pre-implementation design reviews are the design basis; revisiting (A) starts from this ADR.

## References

- The pre-implementation spec, the adversarial design review, and the two-engine consensus — retained in the project's memory notes for #801.
- ADR-014 (why distro-package exact-pinning is infeasible — informs A's apk story).
