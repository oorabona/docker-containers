---
layout: post
title: "Zero-Touch Docker Image Maintenance: SBOMs, Sigstore, and Automated Upstream Tracking for 13 Containers"
description: "How we keep 13 container images in sync with upstream releases, signed with Sigstore, and shipped with SPDX SBOMs — without anyone manually running docker build."
date: 2026-05-02 10:00:00 +0000
tags: [docker, supply-chain-security, sbom, sigstore, github-actions, ci-cd]
---

Every container image you publish is a debt: CVEs accumulate, upstream releases pile up, base images drift, and eventually someone asks "why is this still on PHP 7.4?". If you maintain more than 2 or 3 images, the debt compounds faster than you service it.

This post is about how we keep **13 Docker images** fresh without anyone running `docker build` by hand — and why every artifact ships with an SBOM and a Sigstore attestation.

## The fleet

Pulls on Docker Hub (last check):

| Container | Pulls | Role |
|---|---|---|
| [sslh](/docker-containers/container/sslh/) | 79 606 | SSH/HTTPS/OpenVPN port multiplexer (2 MB scratch image) |
| [postgres](/docker-containers/container/postgres/) | 29 429 | PostgreSQL 16/17/18 with pgvector, paradedb, timescale, postgis, citus |
| [terraform](/docker-containers/container/terraform/) | 20 398 | Terraform CLI + tflint + terragrunt + trivy + per-cloud flavors |
| [github-runner](/docker-containers/container/github-runner/) | 15 509 | Self-hosted runners: Ubuntu, Debian, Windows Server 2022 |
| [wordpress](/docker-containers/container/wordpress/) | 2 459 | Immutable WordPress with SQLite plugin |
| [ansible](/docker-containers/container/ansible/) | 2 452 | Ansible controller with pinned cryptography stack |
| [php](/docker-containers/container/php/) | 2 160 | PHP-FPM with Composer + APCu baked in |
| [openresty](/docker-containers/container/openresty/) | 1 758 | OpenResty built from source with 30 compile flags |
| [openvpn](/docker-containers/container/openvpn/) | 1 709 | 15 MB OpenVPN server, PKCS11-capable |
| [web-shell](/docker-containers/container/web-shell/) | 1 119 | ttyd-based browser terminal, multi-distro |
| [debian](/docker-containers/container/debian/) | 973 | Debian base with a host-to-container migration tool |
| [jekyll](/docker-containers/container/jekyll/) | 814 | Jekyll with pre-pinned gems for reproducible builds |
| [vector](/docker-containers/container/vector/) | 597 | 52 MB vendor-free observability pipeline |

Built daily, delivered to GHCR and Docker Hub, multi-arch (amd64 + arm64 for Linux, ltsc2022 for Windows), each one signed.

## The problem we set out to solve

Three years ago, our release process looked like this:

1. See upstream release somewhere (GitHub, mailing list, RSS if lucky)
2. Pull the repo, bump the version, commit, `docker build`, `docker push`
3. Forget to rebuild the downstream images that depend on it
4. Realize 3 months later that pg_cron is two versions behind pgvector

Multiply by 13 containers, 3 PostgreSQL major versions, 5 Terraform cloud flavors, 6 github-runner OS×flavor variants, and you have a full-time maintenance job.

The fix is automation. Not "manual with a reminder" — actual automation where humans only intervene on majors.

## The pipeline

```
   ┌──────────────────────┐
   │ upstream-monitor     │  daily @ 06:00 UTC
   │ GitHub releases API  │
   │ PyPI / RubyGems / DH │
   └───────────┬──────────┘
               │ bumps variants.yaml / config.yaml
               ▼
   ┌──────────────────────┐
   │ peter-evans/create-  │  opens PR per container
   │ pull-request         │
   └───────────┬──────────┘
               │ auto-merge if minor/patch
               │ human review if major
               ▼
   ┌──────────────────────┐
   │ auto-build.yaml      │  triggered by push to master
   │ detect-containers    │
   │ build matrix         │
   │ multi-arch buildx    │
   └───────────┬──────────┘
               │
               ▼
   ┌──────────────────────┐
   │ syft → SPDX SBOM     │
   │ cosign/Sigstore attestation
   │ trivy scan (advisory)│
   └───────────┬──────────┘
               │
               ▼
   ┌──────────────────────┐
   │ push to GHCR & DH    │
   │ multi-arch manifest  │
   │ update dashboard     │
   └──────────────────────┘
```

Each stage is a few dozen lines of YAML plus shell. The clever parts are in **what counts as a version**, **when to auto-merge**, and **how to tell dashboard reality from what's deployed**.

## What counts as a version

A helper function (`helpers/latest-github-release`) resolves the latest **stable** version for any GitHub repo. Three strategies in cascade:

1. **`/releases/latest`** — the repo-declared "latest." Fast, but some projects (like Vector) publish their CLI sub-project here.
2. **Releases list** with `prerelease == false` filter — catches per-commit prereleases.
3. **Tags endpoint** fallback — for projects like git-for-windows that tag but don't release formally.

Each stage validates the tag against a **whitelist regex**:

```regex
^([a-zA-Z]+-|v)?[0-9]+(\.([0-9]+|windows|linux|darwin|macos|alpine))*$
```

Accepts `1.7.1`, `v7.5.1`, `jq-1.8.1`, `2.49.0.windows.2`. Rejects `1.6rc2`, `vdev-v0.3.1`, `2.0-beta`. (The `vdev-v` case shipped a release candidate to production once. Hence the whitelist.)

## When to auto-merge

The bot classifies every bump as `patch` / `minor` / `major`:

- **Patch** (1.2.3 → 1.2.4): auto-merge, no questions.
- **Minor** (1.2 → 1.3): auto-merge after CI passes.
- **Major** (1.x → 2.x): PR opens with `major-update` label. Human reads the changelog, merges if boring.

The bot doesn't merge anything until auto-build.yaml passes — no "green because there are no tests" shortcut. Build, scan, manifest, all green.

## Supply-chain assurance

Every image push generates:

- **SPDX 2.3 SBOM** via [syft](https://github.com/anchore/syft) — every package, every binary, every license.
- **Sigstore attestation** via `actions/attest-sbom` — cryptographic binding of SBOM to image digest, verifiable without our keys.
- **Trivy scan** — CVE scan runs in advisory mode (doesn't block) with 15-minute timeout (the full Terraform flavor with 4 cloud SDKs takes a while).

Verify anything we publish:

```bash
gh attestation verify \
  oci://ghcr.io/oorabona/postgres:18-alpine-vector \
  --repo oorabona/docker-containers
```

The response tells you: who built it, when, with which source commit, and that the SBOM matches the image bytes byte-for-byte.

## Why all these images exist

Not every image in the fleet is a "competing" Docker Hub image. Some are specialised, some are foundations.

- **sslh, openvpn, vector, jekyll, ansible** — we use them. They exist because the "official" Docker Hub versions weren't minimal enough, multi-arch enough, or pinned enough.
- **postgres** — the official `postgres` image is great, but doesn't bundle pgvector, paradedb, timescale, and pgcron. We rebuild Alpine PostgreSQL and ship a flavor for each common workload.
- **terraform, github-runner** — the upstream images exist but are single-cloud / single-OS. We bundle.
- **debian** — a wrapper with an `export.sh` tool that migrates a host Linux system into a container image. Niche but we needed it.
- **wordpress** — an *immutable* WordPress with SQLite pre-installed. Designed for deployments that don't want the plugin-editor attack surface.
- **web-shell** — a ttyd-based browser terminal across four distros (Debian/Alpine/Ubuntu/Rocky) with SSH optional. For orchestration without CLI access.
- **openresty** — built from source with custom compile flags. 30 options you can't change on the official image.
- **php** — a PHP-FPM base with Composer and APCu baked in, saving two Dockerfile layers in downstream images.

Each has a distinct reason. No image exists "because we could."

## The dashboard

All of this lives at [oorabona.github.io/docker-containers](/docker-containers/). It's a Jekyll site generated by the same pipeline that builds the images. Every container has a page with:

- Current version (from Docker Hub)
- Pull count and image sizes per arch
- Build lineage (last successful digest, base image used)
- Dependency health (which upstream tools are behind)
- Recent change log
- Direct links to SBOM and attestation

Built daily. If a container's variants show warning, something broke and we know about it.

## Lessons we learned the hard way

- **Apt mirrors 5xx randomly.** Build retries cost ~30 min per Windows run. Worth it; false negatives cost more.
- **Chocolatey's Community API returns 503 frequently.** Direct downloads from vendor release pages are reliable. All Windows tools install from the vendor, not via choco.
- **Jekyll's `future: false`** is how we stagger blog posts — write them all today, dated in the future, Jekyll ignores them until their date arrives, daily rebuild picks them up.
- **GitHub Pages caches aggressively.** After a deploy, expect 2–5 minutes before the CDN updates.
- **Matrix job concurrency cancellation** cancels your own in-flight builds. We learned that the hard way. The fix is "no job-level concurrency, workflow-level removal is enough."
- **Multi-arch builds on GitHub's ARM runners** are natively fast. No QEMU emulation.

## If you're building your own fleet

Start with: `actions/create-pull-request`, `syft`, `cosign`, and one Dockerfile. Every other piece — the version helper, the whitelist regex, the dashboard — evolves from running the thing in production.

Our full `.github/workflows/` is MIT-licensed. [Read, copy, adapt](https://github.com/oorabona/docker-containers/tree/master/.github).

## TL;DR

13 containers, ~160 000 pulls/month, zero manual release step. Every image signed, every version tracked, every CVE scanned. Not because we're disciplined — because we automated the discipline away.

[⭐ Star on GitHub](https://github.com/oorabona/docker-containers) if this is the kind of pipeline you'd steal.
