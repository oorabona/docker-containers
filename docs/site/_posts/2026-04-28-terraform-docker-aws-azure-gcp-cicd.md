---
layout: post
title: "One Terraform Image for AWS, Azure, and GCP CI/CD: Flavors, SBOMs, and Reproducible Pipelines"
description: "Curated Terraform CLI image with flavors per cloud — 205 MB base, 593 MB full. Bundles tflint, terragrunt, trivy, infracost, and the cloud SDKs you actually use."
date: 2026-04-28 10:00:00 +0000
tags: [terraform, docker, cicd, aws, azure, gcp, infrastructure-as-code]
---

Terraform CI pipelines tend to collect tools. You start with `terraform` and `tflint`, add `terragrunt` for environment layering, then `trivy` for scanning generated plans, `infracost` for cost diffs on PRs, maybe `aws-cli` to seed secrets, `az` to rotate a client secret, `gcloud` for an IAM change. A year in, your Dockerfile is a 300-line artifact nobody wants to touch.

The `oorabona/terraform` image packs these into curated flavors, each with a pinned version set and a signed SBOM. You pick the flavor that matches your cloud — no more `if aws then apk add awscli` conditionals.

## The flavors

| Flavor | Compressed size (amd64) | Includes |
|---|---|---|
| `base` | **205 MB** | terraform, tflint, terragrunt, trivy, terraform-docs, infracost, github-cli |
| `aws` | **226 MB** | base + `aws-cli` v2 |
| `azure` | — | base + `az-cli` |
| `gcp` | **471 MB** | base + Google Cloud SDK (the SDK is heavy) |
| `full` | **593 MB** | base + AWS + Azure + GCP |

Base already has the tools any pipeline needs. Flavors just add the cloud-specific CLI.

## Why not `hashicorp/terraform`

The official image is `terraform` alone. It's ~90 MB, pristine, versioned. Great as a starting point — not a pipeline. Every tool you add on top via `RUN apk add...` or `curl | install` is a thing you maintain, scan, and update.

This image does that for you:

- **Pinned versions in `variants.yaml`** — known-good combinations, not "latest of everything on tuesday"
- **Daily upstream checks** — GitHub releases for each tool; minor/patch auto-merges, majors reviewed
- **SBOM per build** — SPDX format, Sigstore-attested, covers every bundled binary
- **CVE scanning in the pipeline** — Trivy runs on the image itself before publishing (advisory mode, 15-min timeout for the full flavor since GCP SDK is huge)

## Typical CI usage

**GitLab CI, base flavor:**

```yaml
validate:
  image: ghcr.io/oorabona/terraform:base
  script:
    - terraform fmt -check -recursive
    - tflint --recursive
    - terraform init -backend=false
    - terraform validate
    - trivy config --format sarif --output trivy.sarif .
  artifacts:
    reports:
      sast: trivy.sarif
```

**GitHub Actions, AWS flavor with OIDC (no access keys):**

```yaml
jobs:
  plan:
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read
    container:
      image: ghcr.io/oorabona/terraform:aws
    steps:
      - uses: actions/checkout@v6

      - uses: aws-actions/configure-aws-credentials@v5
        with:
          role-to-assume: arn:aws:iam::123456789012:role/terraform-ci
          aws-region: eu-west-3

      - run: terragrunt run-all plan
        env:
          TF_IN_AUTOMATION: "true"

      - run: infracost diff --path=.
        env:
          INFRACOST_API_KEY: ${{ secrets.INFRACOST_API_KEY }}
```

**Full flavor for a meta-orchestration pipeline** (managing deployments across all three clouds):

```yaml
deploy:
  image: ghcr.io/oorabona/terraform:full
  script:
    - ./scripts/login-aws.sh
    - ./scripts/login-azure.sh
    - ./scripts/login-gcp.sh
    - terragrunt run-all apply --terragrunt-non-interactive
```

The `full` flavor is 593 MB — not small. But pulling once per pipeline and caching via buildkit is cheaper than maintaining three separate images.

## What's actually in there

```bash
docker run --rm ghcr.io/oorabona/terraform:base sh -c '
  for t in terraform tflint terragrunt trivy terraform-docs infracost gh; do
    echo "$t: $($t --version 2>&1 | head -1)"
  done
'
```

Output example (versions depend on your pull date):

```
terraform: Terraform v1.14.9
tflint: TFLint version 0.60.3
terragrunt: terragrunt version 0.99.5
trivy: Version: 0.77.0
terraform-docs: terraform-docs version v0.21.1
infracost: Infracost v0.10.44
gh: gh version 2.84.1
```

All reproducible — the versions live in `terraform/config.yaml`, the upstream monitor bumps them, each build is tagged with the full matrix.

## Reproducibility & provenance

Every push to GHCR and Docker Hub is signed with a Sigstore attestation referencing the SBOM. To verify:

```bash
gh attestation verify \
  oci://ghcr.io/oorabona/terraform:1.14.9-aws \
  --repo oorabona/docker-containers
```

The SBOM (SPDX JSON) lists every APK package, Go module, and bundled binary with its version and license. Works with `syft`, `grype`, and your preferred CVE scanner.

## Gotchas

- **GCP SDK pulls a lot** — the `gcp` and `full` flavors take longer to pull on cold CI runners. Cache the pull layer if your pipeline runs often; it's dominated by the SDK (~270 MB of the 471 MB).
- **`TF_IN_AUTOMATION=true`** — set this in CI. Terraform suppresses interactive prompts and some help text, which is what you want.
- **`TF_DATA_DIR`** — if you run `terragrunt run-all`, point `TF_DATA_DIR` at a shared path so downstream jobs can reuse plugins.
- **OIDC beats static credentials** — every major CI platform supports OIDC with the three clouds. Don't bake `AWS_ACCESS_KEY_ID` into CI variables.
- **Version pin in your `versions.tf`** matters more than the image tag — the image just provides the CLI. Your plan files are the source of truth.

## TL;DR

```bash
docker pull ghcr.io/oorabona/terraform:base        # 205 MB — no cloud CLI
docker pull ghcr.io/oorabona/terraform:aws         # 226 MB — base + awscli v2
docker pull ghcr.io/oorabona/terraform:azure       # base + az
docker pull ghcr.io/oorabona/terraform:gcp         # 471 MB — base + gcloud
docker pull ghcr.io/oorabona/terraform:full        # 593 MB — all three
```

All flavors: [container dashboard](/docker-containers/container/terraform/).

If you use this in a pipeline, [⭐ the repo](https://github.com/oorabona/docker-containers). It helps us prioritise what to add next.
