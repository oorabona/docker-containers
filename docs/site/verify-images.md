---
layout: page
title: How we verify images
description: Reproduce every trust signal yourself — SBOM, Trivy, multi-arch, dependency monitoring.
permalink: /verify-images/
---

## Why this page exists

The trust badges on each container card link here so anyone can replicate every check independently. We surface SBOM attestations, Trivy scan results, multi-arch manifests, and upstream dependency tracking — not to ask you to trust a badge, but to give you the exact commands to verify them yourself.

## Verifying the SBOM attestation

Each container's SBOM is signed via Sigstore using `actions/attest-sbom`. The attestation is anchored to the image digest and recorded in the GitHub attestations API, which is publicly accessible without authentication. To verify locally using the GitHub CLI:

```bash
gh attestation verify oci://ghcr.io/oorabona/<container>:<tag> --owner oorabona
```

The SBOM badge in each container card opens the public attestation viewer directly in your browser — no login required. For example, a direct URL looks like `https://github.com/oorabona/docker-containers/attestations/<id>`. The viewer shows the SBOM payload, the Sigstore bundle, and the signing certificate chain.

<a id="trivy"></a>

## Reading Trivy scan results

Trivy scans run on every build in advisory mode: findings do not block the build, but they are surfaced. Results are uploaded to GitHub via `github/codeql-action/upload-sarif`, which populates the Code Scanning API. Note that the Security tab UI in GitHub requires authentication even for public repos — that is why each container's detail page embeds the scan summary directly. To query findings programmatically with any authenticated GitHub session (`gh auth login` is enough; no special scope is required):

```bash
gh api repos/oorabona/docker-containers/code-scanning/alerts \
  --paginate \
  -q '.[] | {rule_id: .rule.id, severity: .rule.severity, category: .most_recent_instance.category, package: .most_recent_instance.location.path}'
```

To filter findings to a single container variant, match on the `category` field, which encodes the container name and platform:

```bash
# Replace the category value with the variant you want to inspect
gh api repos/oorabona/docker-containers/code-scanning/alerts --paginate \
  -q '.[] | select(.most_recent_instance.category == "container-postgres-18-alpine-linux/amd64")'
```

## Inspecting multi-arch manifests

Multi-arch images publish a manifest list that references per-platform image manifests. To see which CPU architectures are present for any tag:

```bash
docker manifest inspect ghcr.io/oorabona/<container>:<tag>
```

Look at the `manifests` array in the output — each entry's `platform.architecture` field reveals the published architectures. Multi-arch images list both `amd64` and `arm64`; single-arch images list one. The architecture badge on each card reflects this inspection at build time.

## Auditing dependency monitoring

Daily upstream monitoring runs via `.github/workflows/upstream-monitor.yaml`. Each container's `config.yaml` declares `dependency_sources`, which lists the upstream packages to watch. When a new upstream version is available, the workflow opens an automatic pull request with the version bump. To audit the monitoring history and open PRs:

- Workflow run history: <https://github.com/oorabona/docker-containers/actions/workflows/upstream-monitor.yaml>
- The dependency badge on each card shows how many sources are tracked daily and links to that same workflow page.

Nothing in this pipeline is opaque: the `version.sh` script in each container directory implements the upstream query logic, and the workflow YAML is the complete source of truth for scheduling and automation.

## Reproducing builds locally

Every container build is driven by shell scripts with no opaque CI steps. To reproduce a build on your own machine:

```bash
git clone https://github.com/oorabona/docker-containers.git
cd docker-containers
./make build <container> [version]
```

BuildKit must be enabled (`DOCKER_BUILDKIT=1` or Docker 23+). The `./make` entry point accepts the same arguments as the CI pipeline. See each container's `README.md` and the top-level `docs/` directory for full build documentation, including multi-variant matrix builds, extension layers, and SBOM generation.
