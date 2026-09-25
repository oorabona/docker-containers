# OpenTofu

OpenTofu CLI with the same security, DevOps, and cloud-provider toolset as the
repository's Terraform image. It is published to GHCR in focused AWS, Azure,
GCP, base, and full flavors.

OpenTofu is licensed under [MPL-2.0](https://github.com/opentofu/opentofu/blob/main/LICENSE).
During the build, the `tofu` binary is checksum-checked against the release's
SHA256SUMS before it is extracted. This is an integrity check of the release
manifest; signature verification is not part of this image build.

[![GHCR](https://img.shields.io/badge/GHCR-oorabona%2Fopentofu-blue)](https://ghcr.io/oorabona/opentofu)
[![Build](https://github.com/oorabona/docker-containers/actions/workflows/auto-build.yaml/badge.svg)](https://github.com/oorabona/docker-containers/actions/workflows/auto-build.yaml)

## Quick start

```bash
# Full flavor with all cloud CLIs
docker pull ghcr.io/oorabona/opentofu:1.12.6-alpine

# Smallest flavor; no cloud CLI
docker pull ghcr.io/oorabona/opentofu:1.12.6-alpine-base

docker run --rm -v "$(pwd)":/data \
  ghcr.io/oorabona/opentofu:1.12.6-alpine init
```

## Tags and flavors

| Tag | Cloud CLIs |
|-----|------------|
| `<version>-alpine-base` | None |
| `<version>-alpine-aws` | AWS CLI |
| `<version>-alpine-azure` | Azure CLI |
| `<version>-alpine-gcp` | Google Cloud SDK |
| `<version>-alpine` | AWS CLI, Azure CLI, Google Cloud SDK |

All flavors contain OpenTofu, TFLint, Trivy, Terragrunt, terraform-docs,
Infracost, GitHub CLI, jinja2-cli, Git, Jq, Yq, Bash, Curl, and Python 3.
Terragrunt is configured to invoke OpenTofu through `TG_TF_PATH=tofu`.

## Usage

```bash
# Plan an OpenTofu configuration
docker run --rm -v "$(pwd)":/data \
  ghcr.io/oorabona/opentofu:1.12.6-alpine plan

# Generate module documentation
docker run --rm -v "$(pwd)":/data \
  ghcr.io/oorabona/opentofu:1.12.6-alpine terraform-docs markdown table .

# Scan the current configuration
docker run --rm -v "$(pwd)":/data \
  ghcr.io/oorabona/opentofu:1.12.6-alpine trivy config .
```

The entrypoint renders `*.tf.j2` templates using `CONFIGFILE` (default:
`config.json`) before passing its arguments to `tofu`.

## Build arguments

`config.yaml` pins the shared tool versions. `VERSION` is the public tag such
as `1.12.6-alpine`; the build hook derives and passes `UPSTREAM_VERSION` so the
Dockerfile downloads the matching OpenTofu release tarball for `TARGETARCH`.
