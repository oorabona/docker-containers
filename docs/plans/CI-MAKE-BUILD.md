# SPEC: CI-MAKE-BUILD — Refactor CI to use ./make build

**Story ID:** CI-MAKE-BUILD
**Status:** canonical
**Complexity:** COMPLEX
**Created:** 2026-01-29
**Hardened by:** /adversarial (5/5 perspectives, 4 challenges resolved)

---

## 1. Problem Statement

The GitHub Actions composite action (`.github/actions/build-container/action.yaml`) reimplements container build logic instead of calling `./make build`. This causes:

1. **openresty CI failure** — `build` script providing `CUSTOM_BUILD_ARGS` is never sourced, resulting in empty `RESTY_OPENSSL_VERSION` (404 on download)
2. **Divergent behavior** — local builds (via `./make`) source `build` files; CI doesn't
3. **Maintenance burden** — build logic duplicated in two places

## 2. Goal

**Single build path:** CI calls `./make build <container> <version>` directly, eliminating divergence.

## 3. Scope

### In-Scope (Phase 1)

- Add `--flavor` and `--dockerfile` CLI args to `./make`
- Support `FLAVOR` env var (CLI arg takes priority)
- Refactor action.yaml "Build container" step to call `./make build`
- Pass `GH_TOKEN` for authenticated GitHub API calls in `build` scripts
- Preserve postgres-specific GHCR base image cache logic
- Preserve `BUILD_PLATFORM`, `SKIP_EXISTING_BUILDS`, `FORCE_REBUILD` env vars
- Revert temporary openresty fixes (`config.json`, Dockerfile `UPSTREAM_VERSION`)

### Out-of-Scope (Phases 2-3)

- Standardize all containers with `build` scripts
- Pin base image SHA digests
- Lineage JSON output / dashboard integration
- Refactor push steps to use `skopeo copy` (evaluate only)

## 4. Design

### 4.1 Current Flow (Broken)

```
action.yaml                    ./make build
─────────────                  ────────────
source build-container.sh      source build file (if -x)
source variant-utils.sh        → sets CUSTOM_BUILD_ARGS
                               do_buildx()
postgres cache (CUSTOM_BUILD_ARGS)   ├─ has_variants? → build_container_variants()
build_container() directly           └─ else → build_container()
```

**Problem:** CI never sources `build` file → openresty's `CUSTOM_BUILD_ARGS` empty.

### 4.2 Target Flow

```
action.yaml
─────────────
[postgres cache setup → CUSTOM_BUILD_ARGS env var]
[export GH_TOKEN, BUILD_PLATFORM, SKIP_EXISTING_BUILDS, FORCE_REBUILD]

./make build <container> <version> [tag] [--flavor X] [--dockerfile Y]
  │
  ├─ cd <container>
  ├─ source build file (if -x) → sets CUSTOM_BUILD_ARGS
  ├─ do_buildx()
  │    ├─ FLAVOR set? → build_container() with flavor (single variant, CI mode)
  │    ├─ has_variants? → build_container_variants() (local full build)
  │    └─ else → build_container() (simple container)
  └─ return exit code
```

### 4.3 CLI Argument Design

```
./make build <container> [version] [tag] [--flavor VALUE] [--dockerfile VALUE]
./make push <container> [version] [tag]
```

**Argument precedence for flavor:**
1. `--flavor VALUE` (CLI arg, highest priority)
2. `FLAVOR` env var
3. Not set (default: expand all variants if `variants.yaml` exists)

**Argument precedence for dockerfile:**
1. `--dockerfile VALUE` (CLI arg)
2. `DOCKERFILE` env var
3. `Dockerfile` (default)

### 4.4 Env Vars Passed from CI

| Variable | Purpose | Source |
|----------|---------|--------|
| `BUILD_PLATFORM` | Single platform per runner | `inputs.platform` |
| `GH_TOKEN` | GitHub API auth (5000 req/h) | `inputs.github_token` |
| `SKIP_EXISTING_BUILDS` | Smart skip if image exists | Workflow env |
| `FORCE_REBUILD` | Override smart skip | Workflow input |
| `CUSTOM_BUILD_ARGS` | Postgres base image cache | Set before `./make` call |
| `GITHUB_ACTIONS` | Detect CI context | Automatic in GHA |
| `GITHUB_REPOSITORY_OWNER` | Registry namespace | Automatic in GHA |

### 4.5 Postgres Cache Handling

The postgres-specific GHCR base image cache logic **stays in action.yaml** (Phase 1).
It sets `CUSTOM_BUILD_ARGS` env var before calling `./make build`, which `build_container()` already reads.

```yaml
# In action.yaml (unchanged from current logic)
if [[ "$container" == "postgres" ]]; then
    base_sfx=$(base_suffix "./$container")
    base_tag="${build_version}${base_sfx}"
    cache_image="ghcr.io/$owner/postgres-base:${base_tag}"
    if docker pull --quiet "$cache_image" &>/dev/null; then
        # BASE_IMAGE without tag — Dockerfile uses FROM ${BASE_IMAGE}:${VERSION}
        export CUSTOM_BUILD_ARGS="--build-arg BASE_IMAGE=ghcr.io/$owner/postgres-base"
    fi
fi
# Then call ./make build
```

> **Note:** `BASE_IMAGE` must NOT include the tag — the Dockerfile uses
> `FROM ${BASE_IMAGE}:${VERSION}` (line 73 of `postgres/Dockerfile`).

### 4.6 What Changes Per File

| File | Change |
|------|--------|
| `make` | Fix dispatcher (line 512) to forward all args; add `--flavor`/`--dockerfile` arg parsing in `make()`; update `do_buildx()` |
| `.github/actions/build-container/action.yaml` | Replace Build step with `./make build` call; use `inputs.github_token` for `GH_TOKEN` |
| `openresty/config.json` | **Delete** (temporary fix no longer needed) |
| `openresty/Dockerfile` | **Revert** UPSTREAM_VERSION changes |

## 5. BDD Scenarios

### 5.1 CLI Argument Parsing

```gherkin
Scenario: Build with explicit --flavor
  Given the make script is invoked with "build terraform 1.10.5 1.10.5-base-alpine --flavor base"
  When the build starts
  Then FLAVOR is set to "base"
  And do_buildx() calls build_container() with flavor="base" (no variant expansion)
  And the tag is "1.10.5-base-alpine"

Scenario: Build with FLAVOR env var
  Given FLAVOR=base is set in the environment
  And the make script is invoked with "build terraform 1.10.5 1.10.5-base-alpine"
  When the build starts
  Then do_buildx() calls build_container() with flavor="base"

Scenario: CLI --flavor overrides FLAVOR env var
  Given FLAVOR=gcp is set in the environment
  And the make script is invoked with "build terraform 1.10.5 --flavor aws"
  When the build starts
  Then FLAVOR is "aws" (CLI wins)

Scenario: Build with --dockerfile
  Given the make script is invoked with "build terraform 1.10.5 --flavor base --dockerfile Dockerfile.minimal"
  When the build starts
  Then build_container() receives dockerfile="Dockerfile.minimal"

Scenario: Build without flavor (local, variants container)
  Given the make script is invoked with "build terraform 1.10.5"
  And terraform has variants.yaml
  And no FLAVOR is set
  When the build starts
  Then do_buildx() calls build_container_variants() (builds all variants)

Scenario: Build without flavor (simple container)
  Given the make script is invoked with "build openresty"
  And openresty has no variants.yaml
  And no FLAVOR is set
  When the build starts
  Then do_buildx() calls build_container() with no flavor
```

### 5.2 CI Integration

```gherkin
Scenario: CI builds openresty via ./make build
  Given the CI matrix job has container=openresty, version=1.29.2.1, platform=linux/amd64
  And BUILD_PLATFORM=linux/amd64 is exported
  And GH_TOKEN is exported
  When action.yaml runs the Build step
  Then ./make build openresty 1.29.2.1 is called
  And ./make sources openresty/build (setting CUSTOM_BUILD_ARGS)
  And build_container() receives the build args from CUSTOM_BUILD_ARGS
  And the image is built for linux/amd64 only

Scenario: CI builds terraform variant via ./make build with --flavor
  Given the CI matrix job has container=terraform, version=1.10.5, tag=1.10.5-base-alpine, flavor=base
  And BUILD_PLATFORM=linux/arm64 is exported
  When action.yaml runs the Build step
  Then ./make build terraform 1.10.5 1.10.5-base-alpine --flavor base is called
  And build_container() receives flavor="base"
  And variant expansion is NOT triggered (single variant only)

Scenario: CI builds postgres with GHCR base cache
  Given the CI matrix job has container=postgres, version=18
  And action.yaml pulls "ghcr.io/owner/postgres-base:18-alpine" successfully
  And action.yaml sets CUSTOM_BUILD_ARGS="--build-arg BASE_IMAGE=ghcr.io/owner/postgres-base"
  When ./make build postgres 18 18-alpine is called
  Then build_container() uses CUSTOM_BUILD_ARGS from the environment
  And Dockerfile resolves FROM ghcr.io/owner/postgres-base:18-alpine (BASE_IMAGE:VERSION)

Scenario: GH_TOKEN available for build scripts using GitHub API
  Given the CI has GH_TOKEN exported from inputs.github_token
  When ./make build runs and sources a container's build script
  Then any GitHub API calls in the build script use authenticated rate limit (5000/h)

Scenario: Build step exits non-zero on failure
  Given ./make build returns exit code 1
  When the CI Build step completes
  Then the step fails
  And subsequent push/scan steps are skipped
```

### 5.3 Backward Compatibility

```gherkin
Scenario: Local build without new flags still works
  Given a developer runs ./make build openresty
  When the build starts
  Then behavior is identical to before the change
  And openresty/build is sourced
  And the image is built successfully

Scenario: Local build of variant container expands all variants
  Given a developer runs ./make build terraform 1.10.5
  When the build starts
  Then all 5 flavors (base, aws, azure, gcp, full) are built
  And each flavor image is tagged correctly
```

### 5.4 Error Handling

```gherkin
Scenario: Build file not executable
  Given debian/ has no build file
  When ./make build debian runs
  Then no build file is sourced (no error)
  And build_container() proceeds without CUSTOM_BUILD_ARGS

Scenario: Build file fails
  Given a build file exits with error
  When ./make build <container> runs
  Then the build stops with non-zero exit code
  And the error is logged

Scenario: Invalid --flavor with no variants
  Given openresty has no variants.yaml
  And ./make build openresty --flavor test is called
  When the build starts
  Then build_container() is called with flavor="test"
  And FLAVOR build arg is passed to Docker
  And Docker ignores unknown build arg (warning only)

Scenario: Missing value for --flavor flag
  Given ./make build openresty --flavor is called (no value after flag)
  When arg parsing runs
  Then make() logs error "--flavor requires a value"
  And returns exit code 1
```

## 6. Implementation Blocks

### Block 1: Fix dispatcher + Add CLI arg parsing to `make` script

**Files:** `make`

**Changes:**
1. **Fix dispatcher** (line 512): Current `make "$1" "${2:-}" "${3:-}"` only forwards 3 args — tag and `--flavor`/`--dockerfile` are dropped. Change to forward all args with `"$@"`.
2. In `make()` function (line 349), parse `--flavor` and `--dockerfile` from args after positional params
3. Export `FLAVOR` and `DOCKERFILE` so `do_buildx()` can use them
4. CLI `--flavor` overrides `FLAVOR` env var
5. Validate that `--flavor`/`--dockerfile` have a value (prevent `shift 2` on missing arg)

**Concrete example — dispatcher fix (line 512):**
```bash
# Before:
  build ) make "$1" "${2:-}" "${3:-}" ;;
# After:
  build ) make "$@" ;;
```

**Also fix push dispatcher (lines 514-521):**
```bash
# Before:
  push )
    if [[ "${2:-}" == "ghcr" || "${2:-}" == "dockerhub" ]]; then
      make "$1" "${2:-}" "${3:-}" "${4:-}"
    else
      make "$1" "${2:-}" "${3:-}"
    fi
    ;;
# After:
  push ) make "$@" ;;
```

> **Note:** `make()` already handles registry detection (`ghcr`/`dockerhub` as first arg after op),
> so the dispatcher doesn't need to special-case push. Forwarding `"$@"` is sufficient.

**Concrete example — `make()` arg parsing:**
```bash
make() {
  local op=$1 ; shift
  local registry=""

  # Check if first arg is a registry name
  if [[ "$1" == "ghcr" || "$1" == "dockerhub" ]]; then
    registry=$1
    shift
  fi

  # Parse named args (--flavor, --dockerfile) from remaining args
  local positional_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --flavor)
        [[ -z "${2:-}" || "$2" == --* ]] && { log_error "--flavor requires a value"; return 1; }
        export FLAVOR="$2"
        shift 2
        ;;
      --dockerfile)
        [[ -z "${2:-}" || "$2" == --* ]] && { log_error "--dockerfile requires a value"; return 1; }
        export DOCKERFILE="$2"
        shift 2
        ;;
      *)
        positional_args+=("$1")
        shift
        ;;
    esac
  done
  set -- "${positional_args[@]}"

  # Existing positional arg handling continues...
}
```

**Test:** `./make build openresty --flavor test` → FLAVOR=test in env
**Test:** `./make build openresty --flavor` → error "requires a value"

---

### Block 2: Update `do_buildx()` for single-flavor builds

**Files:** `make`

**Changes:**
1. In `do_buildx()` (line 315), check `FLAVOR` before variant expansion
2. When `FLAVOR` is set, call `build_container()` directly with flavor and dockerfile
3. Preserve existing behavior when `FLAVOR` is not set

**Concrete example — `do_buildx()` update:**
```bash
do_buildx() {
  local op=$1
  local registry=${2:-""}
  local container=$(basename "$PWD")

  if [[ "$op" == "build" ]]; then
    if [[ -n "${FLAVOR:-}" ]]; then
      # Single-flavor build (CI mode or explicit --flavor)
      log_info "Building $container with flavor: $FLAVOR"
      build_container "$container" "$VERSION" "$TAG" "$FLAVOR" "${DOCKERFILE:-Dockerfile}"
    elif container_has_variants "$container"; then
      log_info "Container $container has variants - building all variants..."
      build_container_variants "$container" "$VERSION"
    else
      build_container "$container" "$VERSION" "$TAG"
    fi
  elif [[ "$op" == "push" ]]; then
    # push logic unchanged...
  fi
}
```

**Test:** `FLAVOR=base ./make build terraform 1.10.5 1.10.5-base-alpine` → builds only base flavor

---

### Block 3: Refactor action.yaml Build step

**Files:** `.github/actions/build-container/action.yaml`

**Changes:**
1. Replace the Build step body (lines 205-283) with `./make build` call
2. Keep postgres cache setup (sets `CUSTOM_BUILD_ARGS` env var)
3. Export `GH_TOKEN`, `BUILD_PLATFORM`, `SKIP_EXISTING_BUILDS`, `FORCE_REBUILD`
4. Pass `--flavor` and `--dockerfile` if action inputs provide them
5. Keep existing step conditions and outputs

**Concrete example — new Build step:**
```yaml
- name: Build container
  if: ${{ steps.check-build.outputs.needs_build == 'true' }}
  id: build
  shell: bash
  env:
    BUILD_PLATFORM: ${{ inputs.platform }}
    GH_TOKEN: ${{ inputs.github_token }}
    FORCE_REBUILD: ${{ inputs.force_rebuild }}
  run: |
    set -euo pipefail
    source ./helpers/logging.sh
    source ./helpers/variant-utils.sh

    container="${{ inputs.container }}"
    build_version="${{ steps.check-build.outputs.version }}"
    current_tag="${{ steps.check-build.outputs.tag }}"
    flavor="${{ steps.check-build.outputs.flavor }}"
    dockerfile="${{ steps.check-build.outputs.dockerfile }}"

    # Compute SKIP_EXISTING_BUILDS in-step (not via GitHub expression in env block)
    if [[ "${{ github.event_name }}" != "pull_request" && "${FORCE_REBUILD}" != "true" ]]; then
      export SKIP_EXISTING_BUILDS="true"
    else
      export SKIP_EXISTING_BUILDS="false"
    fi

    # PostgreSQL-specific: GHCR base image cache
    if [[ "$container" == "postgres" ]]; then
      owner="${{ github.repository_owner }}"
      base_sfx=$(base_suffix "./$container")
      [[ -z "$base_sfx" ]] && base_sfx="-alpine"
      base_tag="${build_version}${base_sfx}"
      cache_image="ghcr.io/$owner/postgres-base:${base_tag}"
      log_info "Checking GHCR cache for postgres base: $cache_image"
      if docker pull --quiet "$cache_image" &>/dev/null; then
        log_success "Using cached postgres base image"
        # BASE_IMAGE without tag — Dockerfile uses FROM ${BASE_IMAGE}:${VERSION}
        export CUSTOM_BUILD_ARGS="--build-arg BASE_IMAGE=ghcr.io/$owner/postgres-base"
      fi
    fi

    # Build via ./make
    make_args=("build" "$container" "$build_version")
    [[ -n "$current_tag" ]] && make_args+=("$current_tag")
    [[ -n "$flavor" ]] && make_args+=("--flavor" "$flavor")
    [[ -n "$dockerfile" && "$dockerfile" != "Dockerfile" ]] && make_args+=("--dockerfile" "$dockerfile")

    log_info "Calling: ./make ${make_args[*]}"
    ./make "${make_args[@]}"
```

**Test:** CI run builds openresty successfully (build file sourced, CUSTOM_BUILD_ARGS set)

---

### Block 4: Revert openresty temporary fixes

**Files:** `openresty/Dockerfile`, `openresty/config.json`

**Changes:**
1. Delete `openresty/config.json` (temporary fix, no longer needed)
2. Revert `openresty/Dockerfile` — remove `UPSTREAM_VERSION` ARG additions, restore `RESTY_VERSION=${VERSION}`

**Revert details for Dockerfile:**
```diff
-ARG UPSTREAM_VERSION=""
 ARG RESTY_IMAGE_BASE="alpine"

-ARG UPSTREAM_VERSION
-ARG RESTY_VERSION=${UPSTREAM_VERSION:-${VERSION}}
+ARG RESTY_VERSION=${VERSION}
```

**Test:** `./make build openresty` succeeds (build file provides versions via CUSTOM_BUILD_ARGS)

---

### Block 5: Local integration test

**Validation:**
1. `./make build openresty` — sources `build` file, resolves versions, builds successfully
2. `./make build debian` — simple container, no build file, builds successfully
3. `FLAVOR=base ./make build terraform 1.10.5` — single flavor only, no variant expansion
4. `./make build terraform 1.10.5 --flavor base` — same via CLI arg
5. Verify `--flavor` overrides `FLAVOR` env var

## 7. Test Requirements

### Unit Tests (manual verification)

| Test | Command | Expected |
|------|---------|----------|
| Flag parsing | `./make build openresty --flavor test 2>&1 \| head -5` | FLAVOR=test visible in log |
| Env var | `FLAVOR=test ./make build openresty 2>&1 \| head -5` | FLAVOR=test visible in log |
| Override | `FLAVOR=old ./make build openresty --flavor new 2>&1 \| head -5` | FLAVOR=new wins |
| No flag | `./make build openresty 2>&1 \| head -5` | No FLAVOR mentioned |
| Dockerfile flag | `./make build openresty --dockerfile Dockerfile 2>&1 \| head -5` | Uses Dockerfile |

### Integration Tests (CI validation)

1. Push branch → trigger CI
2. Verify openresty builds successfully (was failing before)
3. Verify terraform variant builds with --flavor
4. Verify postgres cache still works
5. Verify all 9 containers build (full matrix)

## 8. Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| `./make` exit code not propagated | `set -euo pipefail` in action step |
| `build` file network failure | Already handled by `build` scripts (`set -ex`) |
| Missing `GH_TOKEN` in local builds | `build` scripts already handle unauthenticated (60 req/h) |
| Variant expansion triggered in CI | `--flavor` flag prevents expansion (tested) |
| Postgres cache breaks | Cache logic stays in action.yaml (minimal change) |

## 9. Acceptance Criteria

- [ ] `./make build openresty` builds successfully (local)
- [ ] `./make build terraform 1.10.5 --flavor base` builds only base flavor
- [ ] `FLAVOR=base ./make build terraform 1.10.5` same behavior as `--flavor`
- [ ] `--flavor` CLI arg overrides `FLAVOR` env var
- [ ] CI builds all 9 containers successfully via `./make build`
- [ ] openresty CI build passes (was failing)
- [ ] postgres GHCR cache still works in CI
- [ ] No `openresty/config.json` in final commit
- [ ] `openresty/Dockerfile` reverted to original `RESTY_VERSION=${VERSION}`

## 10. Deferred Items

| Item | Phase | Track |
|------|-------|-------|
| Standardize all containers with `build` scripts | Phase 2 | TODO.md |
| Pin base image SHA digests | Phase 2 | TODO.md |
| Lineage JSON output | Phase 3 | TODO.md |
| Dashboard integration for lineage | Phase 3 | TODO.md |
| `skopeo copy` for Docker Hub push | Phase 2 | TODO.md (evaluate) |

## 11. Multi-LLM Review Amendments

**Reviewed by:** Codex, Gemini (via /llm --spec)
**Agreement:** HIGH on critical issues

### Issues Found & Resolutions

| # | Source | Severity | Issue | Resolution |
|---|--------|----------|-------|------------|
| 1 | Codex | **CRITICAL** | CLI dispatcher (line 512) drops args beyond $3 — `--flavor`, tag lost | Fixed: Block 1 now includes dispatcher fix (`make "$@"`) |
| 2 | Codex | **CRITICAL** | Postgres `BASE_IMAGE` included tag → `FROM img:tag:tag` double-tag | Fixed: Section 4.5 + Block 3 use `BASE_IMAGE` without tag |
| 3 | Both | **HIGH** | `shift 2` unsafe — `--flavor` with no value crashes | Fixed: Block 1 adds validation before shift |
| 4 | Codex | **MEDIUM** | `SKIP_EXISTING_BUILDS` via `${{ env.X }}` may be unset | Fixed: Block 3 computes it in-step |
| 5 | Codex | **MEDIUM** | `GH_TOKEN` source: `github.token` vs `inputs.github_token` | Fixed: Block 3 uses `inputs.github_token` (already required input) |
| 6 | Gemini | **MEDIUM** | `CUSTOM_BUILD_ARGS` collision if build file overwrites | No collision in Phase 1: postgres has no `build` file, openresty has no CI-set `CUSTOM_BUILD_ARGS` |
| 7 | Gemini | **LOW** | Output variables — downstream steps might depend on build outputs | Verified: action outputs come from `check-build` and `push-*` steps, not from the build step |
| 8 | Codex | **LOW** | `GH_TOKEN` not used by openresty/build (no GitHub API calls) | Corrected: BDD scenario updated. GH_TOKEN exported for any build script that may need it |
| 9 | Gemini | **LOW** | `export FLAVOR` leaks to child processes | Acceptable: `FLAVOR` is only meaningful to `build_container()` |
| 10 | Codex | **LOW** | `--dockerfile` not applied for non-flavor simple builds | Out of scope: simple containers always use `Dockerfile` |
