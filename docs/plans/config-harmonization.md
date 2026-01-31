# Spec: Config Harmonization — Unified config.yaml

## Story

**As a** maintainer of docker-containers,
**I want** every container to have a `config.yaml` with base image and third-party dependency versions,
**So that** the build system and lineage have a single, uniform source of truth.

## Context

Current state is fragmented:
- **terraform**: `config.json` (JSON, read with `jq`)
- **openresty**: hardcoded versions in `build` script as `CUSTOM_BUILD_ARGS`
- **postgres**: `extensions/config.yaml` for extension versions (separate concern)
- **Other 7 containers**: no config file, base_image parsed from Dockerfile with fragile heuristics

## Scope

### In Scope
- Create `config.yaml` in every container directory (10 files)
- Migrate `terraform/config.json` → `terraform/config.yaml`
- Migrate openresty hardcoded versions from `build` script → `config.yaml`
- Update `build-container.sh` to read `config.yaml` (yq) instead of `config.json` (jq)
- Read `base_image` from config.yaml (template with variables, resolved at build time)
- Update lineage extraction to read `build_args` from `config.yaml`
- Add `command -v yq` check in build-container.sh
- Delete `terraform/config.json`

### Out of Scope
- `description` — already extracted from README.md by `get_container_description()`
- `variants.yaml` — orthogonal config, unchanged
- `postgres/extensions/config.yaml` — mature system, unchanged
- Validation script for config.yaml — deferred to backlog
- Backward compat with config.json — not needed (only terraform had one)

## Format

```yaml
# <container>/config.yaml
# Container configuration — base image and third-party dependency versions
# Do NOT put secrets or internal ARGs (NPROC, LOCALES, VERSION) here
# Values MUST be quoted strings to prevent YAML type coercion

base_image: "image:tag"

build_args:
  TOOL_NAME: "version"
```

`base_image` supports variable templates (e.g. `"postgres:${MAJOR_VERSION}-alpine"`).
Variables are resolved by build-container.sh at build time using known build context.

### Examples

**terraform/config.yaml** (replaces config.json):
```yaml
base_image: "hashicorp/terraform:${UPSTREAM_VERSION}"

build_args:
  TFLINT_VERSION: "0.60.0"
  TRIVY_VERSION: "0.68.2"
  TERRAGRUNT_VERSION: "0.99.0"
  TERRAFORM_DOCS_VERSION: "0.21.0"
  GITHUB_CLI_VERSION: "2.86.0"
  AWS_CLI_VERSION: "1.44.27"
  AZURE_CLI_VERSION: "2.82.0"
  GCP_CLI_VERSION: "554.0.0"
```

**openresty/config.yaml** (extracts from build script):
```yaml
base_image: "alpine:latest"

build_args:
  RESTY_OPENSSL_VERSION: "1.1.1w"
  RESTY_OPENSSL_PATCH_VERSION: "1.1.1f"
  RESTY_PCRE_VERSION: "8.45"
  LUAROCKS_VERSION: "3.11.1"
```

**debian/config.yaml** (no third-party deps):
```yaml
base_image: "debian:trixie"

build_args: {}
```

**postgres/config.yaml** (extension versions managed separately):
```yaml
base_image: "postgres:${MAJOR_VERSION}-alpine"

build_args: {}
```

**wordpress/config.yaml**:
```yaml
base_image: "${PHP_IMAGE}"

build_args: {}
```

## BDD Scenarios

```gherkin
Scenario: Build reads config.yaml for build args
  Given terraform/config.yaml exists with build_args
  When ./make build terraform runs
  Then Docker receives --build-arg TFLINT_VERSION=0.60.0

Scenario: Build resolves base_image template from config.yaml
  Given postgres/config.yaml has base_image: "postgres:${MAJOR_VERSION}-alpine"
  When ./make build postgres runs with MAJOR_VERSION=18
  Then lineage JSON has base_image_ref: "postgres:18-alpine"

Scenario: Build handles empty build_args
  Given debian/config.yaml has build_args: {}
  When ./make build debian runs
  Then no additional --build-arg flags are added
  And build succeeds

Scenario: Build checks yq availability
  Given yq is not installed
  When ./make build runs
  Then build fails with clear error message about missing yq

Scenario: Openresty build uses config.yaml
  Given openresty/config.yaml has RESTY_OPENSSL_VERSION: "1.1.1w"
  When openresty/build script runs
  Then CUSTOM_BUILD_ARGS includes --build-arg RESTY_OPENSSL_VERSION=1.1.1w
  And versions are NOT hardcoded in the build script

Scenario: Lineage captures build_args from config.yaml
  Given terraform/config.yaml has build_args
  When build completes and lineage JSON is generated
  Then .build-lineage/terraform.json contains build_args from config.yaml

Scenario: terraform/config.json is removed
  Given terraform/config.yaml exists
  When git status is checked
  Then terraform/config.json does not exist
```

## Implementation Plan

### Block 1: Create 10 config.yaml files (no behavior change yet)
**Files created:** 10 config.yaml files with base_image + build_args
- terraform/config.yaml (from config.json + Dockerfile FROM)
- openresty/config.yaml (from build script hardcoded values + Dockerfile FROM)
- ansible/config.yaml, debian/config.yaml, jekyll/config.yaml,
  openvpn/config.yaml, php/config.yaml, postgres/config.yaml,
  sslh/config.yaml, wordpress/config.yaml (base_image + empty build_args)

### Block 2: Update build-container.sh (config reading + base_image)
**File modified:** scripts/build-container.sh
- Add `command -v yq` check
- Replace config.json/jq with config.yaml/yq for build_args
- Read base_image from config.yaml instead of parsing Dockerfile FROM
- Resolve variable templates in base_image using known build context
- Remove old Dockerfile FROM parsing heuristics

### Block 3: Update openresty/build script
**File modified:** openresty/build
- Remove hardcoded version variables (lines 28-31)
- Read from config.yaml instead via yq
- Keep CUSTOM_BUILD_ARGS construction but source values from config.yaml

### Block 4: Update lineage extraction + cleanup
**File modified:** scripts/build-container.sh
- Read build_args from config.yaml for lineage JSON (instead of parsing flags)
- Delete terraform/config.json
- Local verification: build terraform, openresty, debian
- Verify lineage JSON and dashboard generation

## Deferred Items

| Item | Reason | Track In |
|------|--------|----------|
| config.yaml validation script | Not blocking for v1 | TODO.md |
| Shellcheck on modified scripts | Will run in CI | Automatic |
