# Terraform

Enterprise-grade Terraform container with comprehensive DevOps tooling for multi-cloud infrastructure as code. Available in multiple flavors optimized for AWS, Azure, GCP, or all clouds.

[![Docker Hub](https://img.shields.io/docker/v/oorabona/terraform?sort=semver&label=Docker%20Hub)](https://hub.docker.com/r/oorabona/terraform)
[![GHCR](https://img.shields.io/badge/GHCR-oorabona%2Fterraform-blue)](https://ghcr.io/oorabona/terraform)
[![Build](https://github.com/oorabona/docker-containers/actions/workflows/auto-build.yaml/badge.svg)](https://github.com/oorabona/docker-containers/actions/workflows/auto-build.yaml)

## Quick Start

```bash
# Full flavor with all cloud CLIs (recommended for development)
docker pull ghcr.io/oorabona/terraform:latest

# Base flavor (smallest image, no cloud CLIs)
docker pull ghcr.io/oorabona/terraform:latest-base

# AWS-specific flavor
docker pull ghcr.io/oorabona/terraform:latest-aws

# Azure-specific flavor
docker pull ghcr.io/oorabona/terraform:latest-azure

# GCP-specific flavor
docker pull ghcr.io/oorabona/terraform:latest-gcp
```

## Available Flavors

All flavors include the core security and DevOps toolkit. The difference is which cloud CLIs are included:

| Flavor | Description | Cloud CLIs | Use Case |
|--------|-------------|------------|----------|
| **base** | Core tools only | None | Smallest image, cloud-agnostic |
| **aws** | AWS optimized | AWS CLI | AWS-only infrastructure |
| **azure** | Azure optimized | Azure CLI | Azure-only infrastructure |
| **gcp** | GCP optimized | Google Cloud SDK | GCP-only infrastructure |
| **full** | All clouds | AWS CLI + Azure CLI + Google Cloud SDK + j2cli | Multi-cloud or development |

### Flavor Details

#### Base (`*-base`)
Includes Terraform, security scanning, linting, and documentation tools. No cloud provider CLIs installed. Smallest image size.

**Tools:**
- Terraform
- TFLint (linting)
- Trivy (security scanning)
- Terragrunt (orchestration)
- terraform-docs (documentation generation)
- Infracost (cost estimation)
- GitHub CLI
- Git, Jq, Yq

#### AWS (`*-aws`)
Includes base + AWS CLI for Amazon Web Services infrastructure.

**Additional tools:**
- AWS CLI (pinned version for reproducibility)

#### Azure (`*-azure`)
Includes base + Azure CLI for Microsoft Azure infrastructure.

**Additional tools:**
- Azure CLI (pinned version for reproducibility)

#### GCP (`*-gcp`)
Includes base + Google Cloud SDK for Google Cloud Platform infrastructure.

**Additional tools:**
- Google Cloud SDK (always latest - GCP installer doesn't support version pinning)
- gcloud, gsutil, bq commands

#### Full (`*-full`)
Includes all cloud CLIs plus Jinja2 templating engine. Recommended for:
- Multi-cloud environments
- Development and testing
- CI/CD pipelines
- Template-based infrastructure

**Additional tools:**
- AWS CLI
- Azure CLI
- Google Cloud SDK
- j2cli (Jinja2 templating)

### Image Tags

```
ghcr.io/oorabona/terraform:{version}-{flavor}
```

Examples:
- `latest` or `latest-full` - Latest Terraform, all clouds
- `latest-base` - Latest Terraform, no cloud CLIs
- `latest-aws` - Latest Terraform with AWS CLI
- `1.10.3-azure` - Terraform 1.10.3 with Azure CLI

## Tools Reference

All versions are pinned and automatically monitored for updates:

| Tool | Version | Description | Flavors |
|------|---------|-------------|---------|
| Terraform | (upstream) | Infrastructure as code | All |
| TFLint | 0.60.0 | Terraform linter | All |
| Trivy | 0.69.1 | Security scanner | All |
| Terragrunt | 0.99.1 | Terraform orchestration | All |
| terraform-docs | 0.21.0 | Documentation generator | All |
| Infracost | 0.10.43 | Cloud cost estimation | All |
| GitHub CLI | 2.86.0 | GitHub automation | All |
| AWS CLI | 1.44.33 | Amazon Web Services CLI | aws, full |
| Azure CLI | 2.83.0 | Microsoft Azure CLI | azure, full |
| Google Cloud SDK | latest | Google Cloud Platform CLI | gcp, full |
| j2cli | (latest) | Jinja2 templating CLI | full |

### Built-in Utilities

All flavors include:
- Git - Version control
- Jq - JSON processor
- Yq - YAML processor
- Bash - Shell scripting
- Curl - HTTP client
- Python 3 - Scripting runtime

## Usage

### Docker Compose (Recommended)

```yaml
services:
  terraform:
    image: ghcr.io/oorabona/terraform:latest
    user: "1000:1000"
    volumes:
      - .:/data
      - ~/.aws:/home/terraform/.aws:ro  # AWS credentials (read-only)
      - ~/.azure:/home/terraform/.azure:ro  # Azure credentials (read-only)
      - ~/.config/gcloud:/home/terraform/.config/gcloud:ro  # GCP credentials (read-only)
    environment:
      # Pass credentials from environment, never hardcode
      - AWS_ACCESS_KEY_ID
      - AWS_SECRET_ACCESS_KEY
      - AWS_DEFAULT_REGION
      - AZURE_SUBSCRIPTION_ID
      - AZURE_TENANT_ID
      - AZURE_CLIENT_ID
      - AZURE_CLIENT_SECRET
      - GOOGLE_APPLICATION_CREDENTIALS
      - TF_VAR_project_id
```

### Docker Run

```bash
# Initialize and plan
docker run --rm \
  -v $(pwd):/data \
  -v ~/.aws:/home/terraform/.aws:ro \
  ghcr.io/oorabona/terraform:latest-aws \
  init

docker run --rm \
  -v $(pwd):/data \
  -v ~/.aws:/home/terraform/.aws:ro \
  -e AWS_DEFAULT_REGION \
  ghcr.io/oorabona/terraform:latest-aws \
  plan

# Apply with environment credentials
docker run --rm -it \
  -v $(pwd):/data \
  -e AWS_ACCESS_KEY_ID \
  -e AWS_SECRET_ACCESS_KEY \
  -e AWS_DEFAULT_REGION \
  ghcr.io/oorabona/terraform:latest-aws \
  apply
```

### Jinja2 Templating (full flavor only)

The full flavor includes j2cli for template-based infrastructure:

```bash
# Create templated Terraform files with .j2 extension
# Example: main.tf.j2
resource "aws_instance" "{{ instance_name }}" {
  instance_type = "{{ instance_type }}"
  ami           = "{{ ami_id }}"
}

# Create config.json with template variables
{
  "instance_name": "web-server",
  "instance_type": "t3.micro",
  "ami_id": "ami-12345678"
}

# Process templates
docker run --rm \
  -v $(pwd):/data \
  ghcr.io/oorabona/terraform:latest \
  bash -c "for f in *.tf.j2; do j2 \$f config.json > \${f%.j2}; done && terraform plan"
```

### Security Scanning

```bash
# Scan Terraform configurations for misconfigurations
docker run --rm -v $(pwd):/data ghcr.io/oorabona/terraform:latest \
  trivy config .

# Scan with detailed output
docker run --rm -v $(pwd):/data ghcr.io/oorabona/terraform:latest \
  trivy config --format table --severity HIGH,CRITICAL .

# Scan for sensitive data
docker run --rm -v $(pwd):/data ghcr.io/oorabona/terraform:latest \
  trivy fs --scanners secret .
```

### Linting

```bash
# Initialize TFLint plugins
docker run --rm -v $(pwd):/data ghcr.io/oorabona/terraform:latest \
  tflint --init

# Lint Terraform files
docker run --rm -v $(pwd):/data ghcr.io/oorabona/terraform:latest \
  tflint

# Lint with AWS plugin
docker run --rm -v $(pwd):/data ghcr.io/oorabona/terraform:latest-aws \
  tflint --config=.tflint.hcl
```

### Documentation Generation

```bash
# Generate README.md from Terraform modules
docker run --rm -v $(pwd):/data ghcr.io/oorabona/terraform:latest \
  terraform-docs markdown table . > README.md

# Generate JSON output
docker run --rm -v $(pwd):/data ghcr.io/oorabona/terraform:latest \
  terraform-docs json . > module.json
```

### Cost Estimation

```bash
# Generate cost breakdown
docker run --rm -v $(pwd):/data ghcr.io/oorabona/terraform:latest \
  infracost breakdown --path .

# Compare costs between branches
docker run --rm -v $(pwd):/data ghcr.io/oorabona/terraform:latest \
  infracost diff --path .
```

### Building Locally

```bash
# Build specific flavor
docker build --build-arg VERSION=latest --build-arg FLAVOR=aws -t terraform:aws .

# Build full flavor (default)
docker build --build-arg VERSION=latest -t terraform:full .

# Build base flavor
docker build --build-arg VERSION=latest --build-arg FLAVOR=base -t terraform:base .
```

## Build Arguments

| Argument | Description | Default |
|----------|-------------|---------|
| `VERSION` | Terraform version | latest |
| `UPSTREAM_VERSION` | Raw Terraform version (without suffix) | (derived from VERSION) |
| `FLAVOR` | Flavor to build | full |
| `TFLINT_VERSION` | TFLint version | 0.60.0 |
| `TRIVY_VERSION` | Trivy version | 0.69.1 |
| `TERRAGRUNT_VERSION` | Terragrunt version | 0.99.1 |
| `TERRAFORM_DOCS_VERSION` | terraform-docs version | 0.21.0 |
| `INFRACOST_VERSION` | Infracost version | 0.10.43 |
| `GITHUB_CLI_VERSION` | GitHub CLI version | 2.86.0 |
| `AWS_CLI_VERSION` | AWS CLI version | 1.44.33 |
| `AZURE_CLI_VERSION` | Azure CLI version | 2.83.0 |
| `GCP_CLI_VERSION` | GCP SDK version | latest |

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `CONFIGFILE` | Jinja2 configuration file (full flavor) | config.json |
| `TERRAFORM_FLAVOR` | Flavor identifier | (set during build) |
| `AWS_ACCESS_KEY_ID` | AWS credentials | (pass from environment) |
| `AWS_SECRET_ACCESS_KEY` | AWS credentials | (pass from environment) |
| `AWS_DEFAULT_REGION` | AWS region | (pass from environment) |
| `AZURE_SUBSCRIPTION_ID` | Azure subscription | (pass from environment) |
| `AZURE_TENANT_ID` | Azure tenant | (pass from environment) |
| `AZURE_CLIENT_ID` | Azure service principal | (pass from environment) |
| `AZURE_CLIENT_SECRET` | Azure service principal | (pass from environment) |
| `GOOGLE_APPLICATION_CREDENTIALS` | GCP credentials file path | (pass from environment) |
| `TF_VAR_*` | Terraform variables | (user-defined) |

## Volumes

| Path | Purpose | Notes |
|------|---------|-------|
| `/data` | Terraform working directory | WORKDIR + VOLUME |
| `/home/terraform/.aws` | AWS credentials | Mount read-only |
| `/home/terraform/.azure` | Azure credentials | Mount read-only |
| `/home/terraform/.config/gcloud` | GCP credentials | Mount read-only |
| `/.terraform.d` | Terraform plugins/cache | Use tmpfs for security |
| `/.config` | Tool configuration | Use tmpfs for security |
| `/tmp` | Temporary files | Use tmpfs for security |

## Security

### Base Security
- Multi-stage build minimizes attack surface
- Alpine-based final image for minimal footprint
- Regular security updates through automated rebuilds
- Includes Trivy for security scanning
- Non-root execution by default
- No shell access for terraform user (`/sbin/nologin`)

### Credential Security (CRITICAL)

**NEVER** hardcode credentials in docker-compose.yml or Dockerfiles:

```yaml
# BAD - Never do this:
environment:
  AWS_ACCESS_KEY_ID: AKIAIOSFODNN7EXAMPLE

# GOOD - Use environment variables:
environment:
  AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID}
  AWS_SECRET_ACCESS_KEY: ${AWS_SECRET_ACCESS_KEY}

# BETTER - Use credential files mounted read-only:
volumes:
  - ~/.aws:/home/terraform/.aws:ro
```

### Runtime Hardening (Recommended)

```yaml
services:
  terraform:
    image: ghcr.io/oorabona/terraform:latest
    user: "1000:1000"  # terraform:terraform
    read_only: true
    tmpfs:
      - /.terraform.d
      - /.config
      - /tmp
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    volumes:
      - .:/data:ro  # Read-only if only planning
      - ~/.aws:/home/terraform/.aws:ro
    environment:
      # Pass credentials from environment, never hardcode
      - AWS_ACCESS_KEY_ID
      - AWS_SECRET_ACCESS_KEY
      - AWS_DEFAULT_REGION
```

### Scanning Your Infrastructure

```bash
# Scan for security issues before applying
docker run --rm -v $(pwd):/data ghcr.io/oorabona/terraform:latest \
  trivy config --severity HIGH,CRITICAL .

# Scan for common Terraform mistakes
docker run --rm -v $(pwd):/data ghcr.io/oorabona/terraform:latest \
  tflint --enable-rule=terraform_deprecated_interpolation

# Check for secrets in code
docker run --rm -v $(pwd):/data ghcr.io/oorabona/terraform:latest \
  trivy fs --scanners secret .
```

## Dependencies

All tool versions are pinned and automatically monitored for updates:

| Dependency | Version | Source | Monitoring | License |
|------------|---------|--------|------------|---------|
| Terraform | upstream | hashicorp/terraform | Docker Hub | MPL-2.0 |
| TFLint | 0.60.0 | terraform-linters/tflint | GitHub Releases | MPL-2.0 |
| Trivy | 0.69.1 | aquasecurity/trivy | GitHub Releases | Apache-2.0 |
| Terragrunt | 0.99.1 | gruntwork-io/terragrunt | GitHub Releases | MIT |
| terraform-docs | 0.21.0 | terraform-docs/terraform-docs | GitHub Releases | MIT |
| Infracost | 0.10.43 | infracost/infracost | GitHub Releases | Apache-2.0 |
| GitHub CLI | 2.86.0 | cli/cli | GitHub Releases | MIT |
| AWS CLI | 1.44.33 | awscli | PyPI | Apache-2.0 |
| Azure CLI | 2.83.0 | azure-cli | PyPI | MIT |
| Google Cloud SDK | latest | N/A | Not tracked* | Apache-2.0 |

*Google Cloud SDK installer always fetches the latest version - version pinning is not supported by the GCP installer. The `GCP_CLI_VERSION` in config.yaml is for reference only.

## Architecture

```
terraform/
├── Dockerfile                 # Multi-stage, multi-flavor build
├── docker-entrypoint.sh       # Entrypoint script
├── docker-compose.yml         # Example composition
├── config.yaml               # Tool version configuration
├── version.sh                # Upstream version discovery
└── build                     # Build script with auto-version detection
```

### Multi-stage Build

The Dockerfile uses a multi-stage build process:

1. **terraform stage** - Extracts Terraform binary from HashiCorp image
2. **security-tools stage** - Downloads TFLint and Trivy
3. **devops-tools stage** - Downloads Terragrunt, terraform-docs, Infracost, GitHub CLI
4. **cloud-tools-gcp stage** - Conditionally installs Google Cloud SDK (only for gcp/full flavors)
5. **Final stage** - Assembles tools based on FLAVOR argument and installs cloud CLIs via pip

This approach:
- Minimizes final image size
- Enables parallel builds of independent stages
- Allows conditional inclusion of cloud-specific tools
- Maintains clean separation of concerns

### Flavor Selection

Build-time `FLAVOR` argument determines:
- Which cloud CLIs are installed via pip (AWS, Azure)
- Whether Google Cloud SDK is copied from cloud-tools-gcp stage
- Whether j2cli is installed (full flavor only)
- Contents of environment variable `TERRAFORM_FLAVOR`

## CI/CD Integration

### GitHub Actions

```yaml
- name: Terraform Plan
  uses: docker://ghcr.io/oorabona/terraform:latest-aws
  with:
    args: plan -out=tfplan
  env:
    AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
    AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
    AWS_DEFAULT_REGION: us-east-1

- name: Security Scan
  uses: docker://ghcr.io/oorabona/terraform:latest
  with:
    args: trivy config --exit-code 1 --severity HIGH,CRITICAL .

- name: Cost Estimation
  uses: docker://ghcr.io/oorabona/terraform:latest
  with:
    args: infracost breakdown --path .
  env:
    INFRACOST_API_KEY: ${{ secrets.INFRACOST_API_KEY }}
```

### GitLab CI

```yaml
terraform:
  image: ghcr.io/oorabona/terraform:latest-aws
  script:
    - terraform init
    - terraform plan
    - trivy config .
  variables:
    AWS_ACCESS_KEY_ID: $AWS_ACCESS_KEY_ID
    AWS_SECRET_ACCESS_KEY: $AWS_SECRET_ACCESS_KEY
```

## Troubleshooting

### Permission Denied

```bash
# Ensure proper user ownership
docker run --rm -it --user 1000:1000 \
  -v $(pwd):/data \
  ghcr.io/oorabona/terraform:latest init

# Or fix permissions on host
sudo chown -R 1000:1000 .terraform/
```

### Plugin Installation Issues

```bash
# Clear plugin cache
rm -rf .terraform/
docker run --rm -v $(pwd):/data \
  ghcr.io/oorabona/terraform:latest init -upgrade
```

### Cloud Provider Authentication

```bash
# AWS - Verify credentials
docker run --rm \
  -e AWS_ACCESS_KEY_ID \
  -e AWS_SECRET_ACCESS_KEY \
  ghcr.io/oorabona/terraform:latest-aws \
  aws sts get-caller-identity

# Azure - Verify login
docker run --rm \
  -v ~/.azure:/home/terraform/.azure:ro \
  ghcr.io/oorabona/terraform:latest-azure \
  az account show

# GCP - Verify authentication
docker run --rm \
  -v ~/.config/gcloud:/home/terraform/.config/gcloud:ro \
  ghcr.io/oorabona/terraform:latest-gcp \
  gcloud auth list
```

## Links

- [Terraform Documentation](https://www.terraform.io/docs)
- [TFLint Rules](https://github.com/terraform-linters/tflint-ruleset-terraform)
- [Trivy Documentation](https://aquasecurity.github.io/trivy/)
- [Terragrunt Documentation](https://terragrunt.gruntwork.io/)
- [terraform-docs Documentation](https://terraform-docs.io/)
- [Infracost Documentation](https://www.infracost.io/docs/)
- [GitHub CLI Manual](https://cli.github.com/manual/)
- [AWS CLI Documentation](https://docs.aws.amazon.com/cli/)
- [Azure CLI Documentation](https://docs.microsoft.com/en-us/cli/azure/)
- [Google Cloud SDK Documentation](https://cloud.google.com/sdk/docs)
- [Docker Hub Repository](https://hub.docker.com/r/oorabona/terraform)
- [GitHub Container Registry](https://ghcr.io/oorabona/terraform)
- [Source Repository](https://github.com/oorabona/docker-containers)
