---
layout: post
title: "Anatomy of a Docker Image Catalog: SBOM, Sigstore, Multi-Arch, Hub-429-Proof CI"
description: "How ten Docker images are built, signed, scanned, multi-arch'd, and monitored daily — with shell scripts, GitHub Actions, and a Jekyll dashboard. Every trust signal verifiable from your terminal."
date: 2026-05-14 10:00:00 +0000
tags: [supply-chain, sbom, sigstore, trivy, ghcr, docker, ci, web-components, csp]
---

Two weeks ago, I shipped a row of badges across every container card on this dashboard: a green tick for the SBOM attestation, a Trivy "scanned" indicator, an `amd64 + arm64` chip, and a "7/7 deps tracked daily" link. Each badge points to a real artifact you can verify yourself — no vanity images, no `<img src="https://shields.io/...">` placeholders.

This is the post about what's underneath those badges. Specifically: how a Docker image catalog ends up with SBOM-attested, Sigstore-signed, Trivy-scanned, multi-arch, daily-upstream-monitored images for ten different open-source projects, on a Jekyll dashboard generated from build lineage, with a strict CSP and zero JavaScript framework runtime.

It's also the post about what I deliberately did not do, and why. The supply-chain side of a container collection isn't a solo-maintainer problem — Docker Hub 429s, SBOM wiring, dependency drift, and CI hygiene hit small teams and large ones alike. The bones of this approach scale in either direction; the parts I cut might be the ones you don't need either.

## A tour, in five clicks

The dashboard at [oorabona.github.io/docker-containers](https://oorabona.github.io/docker-containers/) lists ten container collections. Each card shows:

- The current upstream version + how many days since last rebuild
- Image sizes (amd64 + arm64) for the default variant
- A **trust strip** of badges, every one clickable, every one resolving to a verifiable artifact:
  - **📋 SBOM attested** → GitHub's [attestation viewer](https://github.com/oorabona/docker-containers/attestations) showing the Sigstore-signed SPDX bundle
  - **🛡 Trivy: 0 CRITICAL · scanned 2026-05-12** → an in-page anchor that scrolls to the Security Scan section with severity counts and top advisories
  - **🏗 amd64 + arm64** → the GHCR package page where you can read the manifest list yourself
  - **🔗 7/7 deps tracked daily** → the upstream-monitor workflow that opens auto-PRs when new versions ship
  - **🔍 How to verify** → a one-page guide with the exact `gh attestation verify`, `gh api code-scanning/alerts`, and `docker manifest inspect` commands

Click around. There is no React, no Vue, no Alpine.js, no framework runtime. The trust strip is two vanilla custom elements (`<trust-strip>` and `<security-scan>`) totaling roughly 150 lines of JavaScript. The CSP is `script-src 'self'`. No `unsafe-eval`, no `unsafe-inline`. This matters more than it sounds — see "Layer 3" later.

## The architecture, in five layers

```
┌─────────────────────────────────────────────────────────────┐
│  Source of truth: <container>/config.yaml + variants.yaml   │
│  (build args, base image cache, dependency sources, tags)   │
└──────────────────┬──────────────────────────────────────────┘
                   │
         ┌─────────▼──────────┐
         │  detect-containers │  (which containers need rebuild)
         └─────────┬──────────┘
                   │
         ┌─────────▼─────────────┐
         │  cache-base-images    │  (mirror Docker Hub → GHCR)
         └─────────┬─────────────┘
                   │
         ┌─────────▼──────────────────────────────────────────┐
         │  matrix builds: docker buildx (amd64 + arm64)      │
         │   ├── pull base from ghcr.io/<org>/<base>          │
         │   ├── syft → SPDX SBOM                             │
         │   ├── actions/attest-sbom@v4 → Sigstore attestation│
         │   ├── trivy scan → SARIF → Code Scanning           │
         │   └── push manifest list (multi-arch) → GHCR + Hub │
         └─────────┬──────────────────────────────────────────┘
                   │
         ┌─────────▼──────────────────────────────────────────┐
         │  generate-dashboard.sh                             │
         │   reads .build-lineage/*.json + queries gh api for │
         │   attestation IDs + Trivy summaries                │
         │   writes docs/site/_data/containers.yml            │
         └─────────┬──────────────────────────────────────────┘
                   │
         ┌─────────▼──────────────────────────────────────────┐
         │  Jekyll: post.html, container-detail.html,         │
         │  vanilla custom elements for the reactive bits     │
         └────────────────────────────────────────────────────┘
```

Each layer is a separate concern. Each layer is shell + YAML + a small amount of JS where necessary, with one Bash helper file per crosscutting responsibility (`registry-utils.sh`, `extension-utils.sh`, `attestation-utils.sh`, `trivy-utils.sh`, `base-cache-utils.sh`, `logging.sh`). No vendored framework. No Python helper. No Go binary except `yq`. The toolchain is portable enough that a single person can hold all of it in their head, and divisible enough that any one helper can be extracted, tested, and replaced independently.

I'll walk through the four most interesting layers.

## Layer 1 — Declaration: every container is a `config.yaml` away

The contract a new container has to fulfill is a small `config.yaml`:

```yaml
# openresty/config.yaml (excerpt)
base_image: "alpine:latest"
base_image_cache:
  - arg: RESTY_IMAGE_BASE
    source: alpine
    ghcr_repo: alpine-base
    tags: ["latest"]

build_args:
  RESTY_IMAGE_BASE: "alpine"
  RESTY_IMAGE_TAG: "latest"
  RESTY_OPENSSL_VERSION: "1.1.1w"
  # ... project-specific pinned versions

dependency_sources:
  RESTY_OPENSSL_VERSION:
    monitor: false
    reason: "OpenSSL 1.1.1 is EOL, frozen"
  LUAROCKS_VERSION:
    type: github-release
    repo: luarocks/luarocks
    strip_v: true

value_proposition: |
  OpenResty with common modules pre-compiled. Multi-arch,
  SBOM-attested, daily upstream monitoring.
```

Three contracts in one file:
- **`base_image_cache`** declares what gets mirrored from Docker Hub to GHCR (the anti-429 hedge — see Layer 4)
- **`build_args`** is the pinned version surface that goes into the `docker build --build-arg` flags
- **`dependency_sources`** tells the daily monitor where to look for upstream version changes (GitHub releases, plain version files, Docker Hub tags). Every entry must either declare a source OR explicitly set `monitor: false` with a reason — there is no "this version just gets updated by hand someday".

Containers with version variants (postgres, terraform, github-runner) layer a `variants.yaml` on top:

```yaml
# postgres/variants.yaml (excerpt)
versions:
  - tag: "18"
    variants:
      - name: base
        flavor: base
        when_to_use: "Standard PostgreSQL with built-in extensions only"
      - name: vector
        flavor: vector
        when_to_use: "PG with pgvector and paradedb — for AI/ML embeddings or full-text search"
```

This drives the build matrix: 3 PostgreSQL versions × 7 variants = 21 build jobs. The `when_to_use` strings populate the comparison table you see on the postgres detail page; they are also displayed in the dashboard's Variant Comparison section. There is no second source of truth for what each variant contains; the `flavor:` field references `postgres/flavors/<name>.yaml` which lists the actual extensions, and the dashboard generator follows that reference. Two readers, one source.

## Layer 2 — The build pipeline as a sequence of small jobs

The `auto-build.yaml` workflow has roughly the following job graph:

```
detect-containers ─┬─→ cache-base-images ─┬─→ build-extensions (postgres only) ─┬─→ matrix builds ─→ create-manifest ─→ cache-lineage ─→ update-dashboard
                   └─────────────────────┴────────────────────────────────────┘
```

Each job is small enough to read in one screen. `detect-containers` decides what changed since the last run (file diff against the previous build's lineage data). `cache-base-images` mirrors every upstream image declared by every config to GHCR using `skopeo copy --all` — multi-arch in one shot, no Buildkit needed. The matrix builds use `docker buildx` with the `--build-arg` rewrite trick: every `FROM ${X_IMAGE_BASE}:${X_IMAGE_TAG}` in a Dockerfile gets `--build-arg X_IMAGE_BASE=ghcr.io/<org>/<base>` injected at build time, so the actual `FROM` resolves to GHCR, not Docker Hub.

This is the "Two-ARG pattern" that documentation calls out repeatedly. It only works if the verification step before the build correctly resolves tag templates. (Two months of latent silence in this verification step is what surfaced as a Hub 429 in the [post-mortem two days ago](/2026/05/12/docker-hub-429-latent-ci-bug-cache-architecture/). Read that one for the bug story; this post is about the steady state.)

Once the build succeeds, **two attestations** are produced inline:

- `actions/attest-sbom@v4.1.0` takes a `syft`-generated SPDX JSON and signs it with the workflow identity using Sigstore's keyless flow. The attestation lives at a stable URL: `https://github.com/oorabona/docker-containers/attestations/<id>`. This is the link the SBOM badge on the dashboard points to. It is publicly viewable. It includes the subject digest — the immutable image SHA — which means the attestation only covers the exact bits we pushed.
- `github/codeql-action/upload-sarif@v4` takes a `trivy` SARIF report and uploads it to Code Scanning. (Caveat: the current Trivy step is configured for `severity: CRITICAL` only, which means non-CRITICAL findings don't reach the dashboard's severity grid. This is open as [issue #332](https://github.com/oorabona/docker-containers/issues/332) — the dashboard's data layer is ready to surface all severities the day the SARIF filter widens.)

A third trust signal is more boring but more important: the **daily upstream-monitor.yaml workflow** parses every container's `dependency_sources` block and queries the corresponding upstream (GitHub releases, Docker Hub tags, plain tarball indices). When a new version is detected, it opens a PR through a GitHub App (`oorabona-upstream-monitor`) — not as a personal token. The app identity makes the PR auditable: every dependency bump is signed off by an automation account, not silently merged by a human pretending to have read the diff. The deps badge on the dashboard ("7/7 deps tracked daily") is the count of `monitor: true` entries vs declared dependencies. If you add a new build-arg without declaring its source, the audit script catches it the next morning.

## Layer 3 — Surfacing the signals: web components without a framework

The dashboard cards and detail pages render trust strip badges and a Security Scan section that update reactively when you click a different variant tag. The state machine is small: a `phase-b-variant-changed` CustomEvent is dispatched by the existing variant-selector handler, and two custom elements (`<trust-strip>` for the badges, `<security-scan>` for the severity grid) listen for it.

I went through three iterations on this:

**Iteration 1 — Vanilla `createElement` + `textContent` everywhere.** ~234 lines of XSS-safe DOM construction across two JS files (one for the dashboard, one for the detail page). Worked. CSP-clean. Verbose enough that the right answer was clearly "use a framework" — except.

**Iteration 2 — Alpine.js 3.** Vendored locally (no CDN, supply-chain rigor matters here too), 46 KB minified. The component bindings collapsed to ~40 lines of declarative `x-text` / `x-show` / `x-for` directives. Significant readability win. **Until the security_reminder_hook fired**: Alpine's standard build evaluates expressions via the `Function` constructor at runtime, which requires `script-src 'unsafe-eval'` in CSP. The whole point of the trust badges is supply-chain transparency. Relaxing the website's CSP for the framework that *renders* the trust badges is incoherent. Alpine has a CSP-friendly build (`@alpinejs/csp`) that requires registering all expressions ahead of time via `Alpine.data()` — which, for our five reactive bindings, restored most of the boilerplate vanilla had. Wash.

**Iteration 3 — Vanilla web components.** `customElements.define()` is browser-native, has shipped in every modern browser since 2020, requires no `unsafe-eval`, ships zero KB of framework. The component itself is ~70 lines of vanilla code that uses `textContent` and `setAttribute` (never `innerHTML` — the Trivy advisory data is upstream-controlled). The Liquid templates render the initial state server-side; the component only mutates the DOM when the `phase-b-variant-changed` event fires. No hydration flicker, no rebuild from scratch on each event. The full implementation:

```javascript
class TrustStrip extends HTMLElement {
  connectedCallback() {
    // Scope listener to parent card on dashboard, fall back to document on detail page
    this._listenerRoot = this.closest('.container-card') || document;
    this._handler = (e) => this._update(e.detail);
    this._listenerRoot.addEventListener('phase-b-variant-changed', this._handler);
  }
  disconnectedCallback() {
    this._listenerRoot?.removeEventListener('phase-b-variant-changed', this._handler);
  }
  _update(variant) {
    const sbom = this.querySelector('[data-trust="sbom"]');
    if (sbom) {
      if (variant.attestation_url) {
        sbom.setAttribute('href', variant.attestation_url);
        sbom.style.display = '';
      } else {
        sbom.style.display = 'none';
      }
    }
    // ... similar for trivy, multi-arch
  }
}
customElements.define('trust-strip', TrustStrip);
```

The lesson cost a week. Architectural decisions made under one set of conditions deserve to be re-challenged when the conditions change. Vanilla wasn't verbose; the abstraction was wrong. The hidden insight was the bridge pattern: existing handlers dispatch events, components listen — once that decoupling exists, the component itself can be tiny.

For anyone tracking the framework decision more broadly: petite-vue is unmaintained since September 2022; Lit is excellent if you ship more than three reactive components (we ship two); Astro with Svelte islands is the right call if you go all-in on a Vite-based build pipeline (we're a static Jekyll site, that's a 5-day migration for a 2-hour problem).

## Layer 4 — Anti-429 architecture: declaration, population, verification, audit

Every container declares its base image dependencies in `config.yaml`'s `base_image_cache`. A daily `cache-base-images` job mirrors each declared upstream image to GHCR. Before each matrix build, a verification step checks that the GHCR cache is reachable and injects `--build-arg` flags rewriting `FROM ${VAR}:tag` to `ghcr.io/<org>/<base>`. A non-blocking audit script runs daily, parses every `FROM` directive across every Dockerfile (template-aware: it expands `Dockerfile.template` into all distro variants for `web-shell`/`github-runner` before scanning), and reports any base image not declared in the cache config.

Today's audit looks like:

| Metric | Count |
|--------|-------|
| Base images cached on GHCR | 19/21 |
| Uncached (legal: Microsoft Windows redistribution restriction + GHCR self-references) | 2 |
| Unexpected gaps | **0** |

The audit script writes a markdown table to `$GITHUB_STEP_SUMMARY` on every dashboard run. New container, new `FROM`, no `base_image_cache` entry? The next morning it surfaces in the summary. Fix it before Docker Hub's rate limiter does.

There is **one open issue in this layer** — [#331](https://github.com/oorabona/docker-containers/issues/331), the matrix builds on PRs fall through to Docker Hub because the verification step's silent fallback (`docker manifest inspect ... &>/dev/null`) hides whatever real error prevents it from finding the cache. The cache *exists* and is *publicly pullable* — this is verifiable from your own terminal — but something in the action's auth or tag resolution disagrees. Drop the `&>/dev/null`, see the real error, fix it. That's the next half-hour of CI hygiene work.

## What I deliberately left out

This is the list a year ago I would have called "missing features"; today I call it "scope I picked".

- **Per-image cosign signing.** Sigstore *attestations* on the SBOM exist (`actions/attest-sbom@v4.1.0`), so the contents are signed and verifiable. The image *manifest* itself is not separately signed. Adding `cosign sign` is a 1-2 hour CI change plus a verification-doc page update. It will land when there's a concrete adopter who needs the cosign envelope specifically. Until then the Sigstore-attested SBOM covers the practical "did our pipeline produce this exact image" question.
- **OpenSSF Scorecard.** Tempting because it produces a number that goes on a badge. Resisted because the number is mostly a measure of CI hygiene I either have (signed commits, branch protection, dependency monitoring) or don't (CodeQL on more languages, fuzzing on shell scripts). Adding it before there's a target audience that asks for it would be vanity metrics.
- **SLSA L3 provenance.** The Sigstore attestation already provides build provenance (`subject-digest`, builder identity, repository ref, commit SHA). SLSA L3 would formalize this into a structured envelope. Same answer as cosign: when there's a downstream that ingests SLSA-formatted provenance specifically. Today nobody is asking.
- **Trust-strip on every blog post.** The trust strip is on container cards and detail pages. Blog posts are blog posts; they don't need a Sigstore attestation.
- **Container-platform-template extracted as a reusable repo.** The architecture *is* portable — it's all shell scripts, YAML configs, GitHub Actions YAML, and Jekyll/Liquid. Pulling it into a separate template repo is the obvious move for letting other people adopt the same pattern. I haven't done it yet because I'm not sure how big the audience is — running a curated Docker image collection with this much CI rigor is still a niche, whether you're a single maintainer or a small platform team. If you're in that niche, file an issue or drop a comment, and I'll know it's worth the extraction work.

## Closing

The supply-chain side of a Docker image collection doesn't get easier as the project grows. Every new container is a new `FROM` to mirror, a new dependency to monitor, a new SBOM to attest, a new variant matrix to multiply. What makes this approach sustainable at any scale is that *the framework is the contract*: every container declares its dependencies, its cache requirements, and its build args in one YAML file; everything else — mirroring, signing, scanning, dashboard generation — is shared infrastructure that scales linearly with the number of containers, not their complexity.

If you maintain a similar collection and your supply-chain side keeps slipping, the four moving parts above are the ones I would copy first: base-image-cache declarations, matrix-build verification of those caches, daily upstream-monitor PRs through a bot identity, and a small audit script that catches new `FROM`s before the rate limiter does. Everything else — the badges, the dashboard, the verify-images page — is presentation layer. Without the four pillars underneath, the badges are decorative.

Source: [github.com/oorabona/docker-containers](https://github.com/oorabona/docker-containers). Verify any image yourself: [/verify-images/](/verify-images/). Discussions, questions, "would you find this packaged as a template" comments: [issues](https://github.com/oorabona/docker-containers/issues) are open and read.
