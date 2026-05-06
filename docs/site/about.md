---
layout: page
title: About
permalink: /about/
nav_active: about
description: docker-containers is maintained by Olivier Orabona — context, project goals, and how to reach the maintainer.
---

`docker-containers` is a personal infrastructure project that publishes a fleet of 13 custom Docker container images to GitHub Container Registry (GHCR) and Docker Hub. Each image is built with automated upstream version monitoring, signed SBOM attestation via Sigstore, an advisory Trivy CVE scan, and — uncommon for a personal catalog — **published as a multi-architecture manifest (amd64 + arm64) wherever the upstream supports it**.

## Maintainer

The project is maintained by [Olivier Orabona](https://github.com/oorabona), an independent infrastructure engineer based in France. Public profile: [github.com/oorabona](https://github.com/oorabona).

## Why this project exists

Docker Official Images cover the upstream-published software, but they do not always combine the extensions, hardening, or multi-distro variants that production deployments need. `docker-containers` fills that gap for a specific set of workloads: PostgreSQL with 10 extensions in 7 flavors, hardened OpenVPN, multi-distro web-shell, GitHub Actions self-hosted runners (Linux + Windows), and a small set of supporting images (Vector, Jekyll, PHP-FPM, WordPress, Terraform, Ansible, Debian, sslh, OpenResty).

Each image is treated as a verifiable artifact. The detail page for any container surfaces:

- The exact build commit and manifest digest
- A Sigstore attestation for the SPDX-format SBOM (when available)
- An advisory Trivy CVE scan summary
- A multi-architecture manifest list (amd64 + arm64) — see the variant page for per-arch digests

The verification guide at [/verify-images/]({{ '/verify-images/' | relative_url }}) walks through reproducing those checks with `cosign`, `gh`, and `Trivy`.

## How this differs from Docker Official Images

| Concern | Docker Official Images | docker-containers |
|---|---|---|
| Upstream tracking | Manual, irregular | Automated daily upstream-monitor workflow with auto-PRs |
| SBOM attestation | Not standard | SPDX JSON, Sigstore-signed, attached to each push |
| Trivy advisory | Not standard | Surfaced on every container detail page (advisory, not blocking) |
| Multi-arch coverage | amd64-only on most personal forks | amd64 + arm64 on every image where the upstream and dependencies support it |
| Multi-distro | Limited | Linux base + Alpine + Ubuntu + Rocky / Trixie variants where supported |
| Extension matrices | Per-image upstream choice | Flavor-based (e.g. PostgreSQL: vector / analytics / timeseries / spatial / distributed / full) |

This project does not aim to replace Docker Official Images for general use — it ships a curated set where the maintenance load and the verification surface justify the additional engineering.

## License

All container images and the build system are released under the [MIT License](https://github.com/oorabona/docker-containers/blob/{{ site.github.default_branch | default: 'master' }}/LICENSE). SBOM attestations and the published Sigstore signatures are not licensed material — they are evidence of the build provenance.

## Contact

- Issue tracker: [github.com/oorabona/docker-containers/issues](https://github.com/oorabona/docker-containers/issues)
- For non-public matters, profile contact details are on the maintainer's GitHub page.
- This site does not collect telemetry or store visitor data.
