---
doc-meta:
  title: "auto-build.yaml — Windows Support Change Spec"
  status: ready-to-apply
  story_id: GITHUB-RUNNER / Block 6
  created: 2026-03-15
---

# auto-build.yaml — Windows Support Changes

This document gives the orchestrator exact before/after YAML fragments to apply via the
Edit tool. Each change is independent and can be applied in the order listed.

---

## Context: why these changes are needed

`github-runner` is the first container in this repo that builds on a `windows-latest`
runner. The build matrix emitted by `detect-containers` must carry `runner` and `os`
fields so that:

1. The `build-and-push` job's `runs-on` can be dynamic.
2. Linux and Windows build steps are mutually exclusive via `if: matrix.build.os != 'windows'`.
3. Trivy/SBOM steps are gated the same way.

---

## Change 1 — `helpers/variant-utils.sh`: emit `os` and `runner` in `list_build_matrix`

**File:** `helpers/variant-utils.sh`
**Function:** `list_build_matrix` (line 280)
**Why:** The matrix JSON currently has no `os` or `runner` field. Those fields must be
read from `variants.yaml` (where `github-runner`'s `windows-ltsc2022` variant has
`os: windows`) and forwarded into the build entry.

### Change 1a — variants-only path (line 339)

This path handles containers whose `variants.yaml` has no explicit `variants:` list
under a version (e.g., simple version-retention containers like ansible, debian).

**Before (line 339, single-line JSON):**
```bash
result+="{\"version\":\"$effective_version\",\"variant\":\"\",\"tag\":\"${effective_version}${base_sfx}\",\"flavor\":\"\",\"is_default\":true,\"is_latest_version\":$is_latest_version,\"dockerfile\":\"$dockerfile\",\"priority\":0,\"full_version\":\"$full_version\"}"
```

**After:**
```bash
result+="{\"version\":\"$effective_version\",\"variant\":\"\",\"tag\":\"${effective_version}${base_sfx}\",\"flavor\":\"\",\"is_default\":true,\"is_latest_version\":$is_latest_version,\"dockerfile\":\"$dockerfile\",\"priority\":0,\"full_version\":\"$full_version\",\"os\":\"linux\",\"runner\":\"ubuntu-latest\"}"
```

### Change 1b — variants-loop path (line 367)

This path handles containers with explicit `variants:` entries, including
`github-runner` with its `windows-ltsc2022` variant.

**Before (line 367, single-line JSON):**
```bash
result+="{\"version\":\"$effective_version\",\"variant\":\"$variant_name\",\"tag\":\"$tag\",\"flavor\":\"$flavor\",\"is_default\":$([[ "$is_default" == "true" ]] && echo "true" || echo "false"),\"is_latest_version\":$is_latest_version,\"dockerfile\":\"$dockerfile\",\"priority\":$priority,\"full_version\":\"$full_version\"}"
```

**After** (add `os` and `runner` fields; read `os` via `variant_property`, map to
runner name, default to `linux` / `ubuntu-latest`):

First, add a local variable block **before** the `result+=` line (insert after
the existing `local dockerfile` / `dockerfile=$(...)` block at ~line 364-365):

```bash
                local variant_os
                variant_os=$(variant_property "$container_dir" "$variant_name" "os" "$pg_version")
                local runner_label="ubuntu-latest"
                if [[ "$variant_os" == "windows" ]]; then
                    runner_label="windows-latest"
                fi
                [[ -z "$variant_os" ]] && variant_os="linux"
```

Then update the `result+=` line:

```bash
result+="{\"version\":\"$effective_version\",\"variant\":\"$variant_name\",\"tag\":\"$tag\",\"flavor\":\"$flavor\",\"is_default\":$([[ "$is_default" == "true" ]] && echo "true" || echo "false"),\"is_latest_version\":$is_latest_version,\"dockerfile\":\"$dockerfile\",\"priority\":$priority,\"full_version\":\"$full_version\",\"os\":\"$variant_os\",\"runner\":\"$runner_label\"}"
```

### Change 1c — `list_container_builds` legacy-path (lines ~403-424)

This is the fallback path for containers without `variants.yaml` (pure `config.yaml`
variants). Same pattern — add `os` and `runner` defaults. The `os` field is not present
in legacy variant definitions, so hard-code `linux` / `ubuntu-latest` here.

Locate the result+= line inside `list_container_builds` (around line ~428 in the
section `# Legacy: build from config.yaml`). It currently looks like:

```bash
result+="{\"version\":\"$version\",\"variant\":\"$variant_name\",\"tag\":\"$tag\",\"flavor\":\"$flavor\",\"is_default\":$([[ "$is_default" == "true" ]] && echo "true" || echo "false"),\"is_latest_version\":true,\"dockerfile\":\"\",\"priority\":$priority,\"full_version\":\"$version\",\"container\":\"$container_name\"}"
```

**After:**
```bash
result+="{\"version\":\"$version\",\"variant\":\"$variant_name\",\"tag\":\"$tag\",\"flavor\":\"$flavor\",\"is_default\":$([[ "$is_default" == "true" ]] && echo "true" || echo "false"),\"is_latest_version\":true,\"dockerfile\":\"\",\"priority\":$priority,\"full_version\":\"$version\",\"container\":\"$container_name\",\"os\":\"linux\",\"runner\":\"ubuntu-latest\"}"
```

> **Note on `variant_property` and arbitrary fields:** `variant_property` in
> `variant-utils.sh` uses `yq` to read any key from the variant object. The
> `os: windows` field in `github-runner/variants.yaml` is a string, so
> `variant_property "$container_dir" "windows-ltsc2022" "os"` returns `"windows"`.
> An absent key returns `""` (empty string), which is safe to test with `[[ -z ... ]]`.

---

## Change 2 — `auto-build.yaml`: remove `arch` matrix dimension for Windows

**File:** `.github/workflows/auto-build.yaml`
**Job:** `build-and-push`
**Lines:** 306–321 (strategy/matrix block)

The current matrix fans out every build entry across `[amd64, arm64]`:

```yaml
    strategy:
      fail-fast: false
      max-parallel: 4  # Allow more parallel builds since we're splitting by platform
      matrix:
        build: ${{ fromJson(needs.detect-containers.outputs.builds) }}
        arch: [amd64, arm64]
        include:
          - arch: amd64
            platform: linux/amd64
            runner: ubuntu-latest
          - arch: arm64
            platform: linux/arm64
            runner: ubuntu-24.04-arm
```

Windows builds must NOT fan out to arm64 — Windows containers are amd64 only.

**After** (add `exclude` to suppress arm64 for Windows variants):

```yaml
    strategy:
      fail-fast: false
      max-parallel: 4  # Allow more parallel builds since we're splitting by platform
      matrix:
        build: ${{ fromJson(needs.detect-containers.outputs.builds) }}
        arch: [amd64, arm64]
        include:
          - arch: amd64
            platform: linux/amd64
            runner: ubuntu-latest
          - arch: arm64
            platform: linux/arm64
            runner: ubuntu-24.04-arm
        exclude:
          # Windows containers are amd64 only — skip arm64 fan-out
          - arch: arm64
            build: {os: windows}
```

> **GitHub Actions matrix `exclude` matching:** `exclude` entries match when ALL
> specified fields match. The object `{os: windows}` matches any `build` entry
> where `build.os == "windows"`. This is standard GHA matrix partial matching.

---

## Change 3 — `auto-build.yaml`: dynamic `runs-on` for build-and-push

**File:** `.github/workflows/auto-build.yaml`
**Job:** `build-and-push`
**Line 306** (current):
```yaml
    runs-on: ${{ matrix.runner }}
```

This line already uses `matrix.runner` (it was previously changed). Verify it reads:
```yaml
    runs-on: ${{ matrix.runner }}
```

If it still says `ubuntu-latest` (hardcoded), change it to:
```yaml
    runs-on: ${{ matrix.runner }}
```

The `runner` field injected by Change 1 into the build matrix (`"ubuntu-latest"` or
`"windows-latest"`) drives runner selection. The `include` entries in the strategy
matrix set `runner` for the arch dimension; the `build.runner` field overrides this
for Windows via the `exclude` + dedicated step approach in Change 4.

> **Important:** The existing `include` blocks set `runner: ubuntu-latest` and
> `runner: ubuntu-24.04-arm` for `amd64`/`arm64` respectively. These are the
> platform runners for Linux builds. The Windows build entries do NOT use the
> `arch` fan-out at all (excluded by Change 2), so their runner comes from
> `matrix.build.runner` — but the `runs-on` key must use a consistent expression.
>
> The correct expression that covers both cases is:
> ```yaml
> runs-on: ${{ matrix.build.os == 'windows' && 'windows-latest' || matrix.runner }}
> ```
> This evaluates to `windows-latest` when the build entry has `os=windows`, and
> falls back to the arch-derived `matrix.runner` for all Linux builds.

**Final value for `runs-on` on line 306:**
```yaml
    runs-on: ${{ matrix.build.os == 'windows' && 'windows-latest' || matrix.runner }}
```

---

## Change 4 — `auto-build.yaml`: conditional Linux vs Windows build steps

**File:** `.github/workflows/auto-build.yaml`
**Job:** `build-and-push`
**Location:** After the `Install yq` step (line 327-330) and before/replacing the
`Build container with retry logic` step (lines 331-347).

### 4a — Gate existing Linux build steps with `if: matrix.build.os != 'windows'`

The three existing build steps (`Build container with retry logic`, `Retry build on
failure`, `Handle build failure`) must only run for Linux. Add an `if:` condition to
each.

**Step: "Build container with retry logic" (lines 331-347)**

Before:
```yaml
      - name: Build container with retry logic
        id: build
        uses: ./.github/actions/build-container
        with:
          container: ${{ matrix.build.container }}
          version: ${{ matrix.build.version }}
          tag: ${{ matrix.build.tag }}
          flavor: ${{ matrix.build.flavor }}
          variant: ${{ matrix.build.variant }}
          dockerfile: ${{ matrix.build.dockerfile }}
          platform: ${{ matrix.platform }}
          force_rebuild: ${{ github.event.inputs.force_rebuild || inputs.force_rebuild }}
          dockerhub_username: ${{ secrets.DOCKERHUB_USERNAME }}
          dockerhub_token: ${{ secrets.DOCKERHUB_TOKEN }}
          github_token: ${{ secrets.GITHUB_TOKEN }}
          use_base_cache: ${{ github.event_name != 'pull_request' }}
        continue-on-error: true
```

After:
```yaml
      - name: Build container with retry logic
        id: build
        if: matrix.build.os != 'windows'
        uses: ./.github/actions/build-container
        with:
          container: ${{ matrix.build.container }}
          version: ${{ matrix.build.version }}
          tag: ${{ matrix.build.tag }}
          flavor: ${{ matrix.build.flavor }}
          variant: ${{ matrix.build.variant }}
          dockerfile: ${{ matrix.build.dockerfile }}
          platform: ${{ matrix.platform }}
          force_rebuild: ${{ github.event.inputs.force_rebuild || inputs.force_rebuild }}
          dockerhub_username: ${{ secrets.DOCKERHUB_USERNAME }}
          dockerhub_token: ${{ secrets.DOCKERHUB_TOKEN }}
          github_token: ${{ secrets.GITHUB_TOKEN }}
          use_base_cache: ${{ github.event_name != 'pull_request' }}
        continue-on-error: true
```

**Step: "Retry build on failure" (lines 349-366)**

Before:
```yaml
      - name: Retry build on failure
        if: steps.build.outcome == 'failure'
        id: retry
```

After:
```yaml
      - name: Retry build on failure
        if: matrix.build.os != 'windows' && steps.build.outcome == 'failure'
        id: retry
```

**Step: "Handle build failure" (lines 368-395)**

Before:
```yaml
      - name: Handle build failure
        if: steps.build.outcome == 'failure' && steps.retry.outcome == 'failure'
```

After:
```yaml
      - name: Handle build failure
        if: matrix.build.os != 'windows' && steps.build.outcome == 'failure' && steps.retry.outcome == 'failure'
```

**Step: "Report successful build" (lines 397-416)**

Before:
```yaml
      - name: Report successful build
        if: steps.build.outcome == 'success' || steps.retry.outcome == 'success'
```

After:
```yaml
      - name: Report successful build
        if: |
          (matrix.build.os != 'windows' && (steps.build.outcome == 'success' || steps.retry.outcome == 'success')) ||
          (matrix.build.os == 'windows' && steps.build-windows.outcome == 'success')
```

### 4b — Insert Windows build step

Insert the following step **after** the "Install yq" step (after line 330) and
**before** "Build container with retry logic" (line 331).

```yaml
      - name: Build container (Windows)
        id: build-windows
        if: matrix.build.os == 'windows'
        uses: ./.github/actions/build-container-windows
        with:
          container: ${{ matrix.build.container }}
          version: ${{ matrix.build.version }}
          tag: ${{ matrix.build.tag }}
          flavor: ${{ matrix.build.flavor }}
          push: ${{ github.event_name != 'pull_request' && 'true' || 'false' }}
          ghcr_token: ${{ secrets.GITHUB_TOKEN }}
```

---

## Change 5 — `auto-build.yaml`: skip Trivy/SBOM steps for Windows

**File:** `.github/workflows/auto-build.yaml`
**Job:** `build-and-push`

Each of the following steps needs `matrix.build.os != 'windows'` prepended to its
existing `if:` condition (or added as a new `if:` if none exists).

### Step: "Install syft" (line 482)

Before:
```yaml
      - name: Install syft
        id: install-syft
        if: (steps.build.outputs.image_loaded == 'true' || steps.retry.outputs.image_loaded == 'true') && matrix.arch == 'amd64' && github.event_name != 'pull_request'
```

After:
```yaml
      - name: Install syft
        id: install-syft
        if: matrix.build.os != 'windows' && (steps.build.outputs.image_loaded == 'true' || steps.retry.outputs.image_loaded == 'true') && matrix.arch == 'amd64' && github.event_name != 'pull_request'
```

### Step: "Generate SBOM" (line 487)

The existing `if: steps.install-syft.outcome == 'success'` already gates SBOM on syft
being installed — and syft is already gated on non-Windows by the step above. No
additional `if:` change needed here.

### Step: "Upload SBOM artifact" (line 509)

Same pattern — already gated through `steps.sbom.outcome == 'success'`. No change
needed.

### Step: "Attest SBOM" (line 519)

Same pattern — no change needed.

### Steps: "Ensure Trivy cache directory exists", "Restore Trivy vulnerability database
cache", "Scan for vulnerabilities (Trivy)", "Generate SARIF report",
"Upload SARIF to GitHub Security", "Save Trivy vulnerability database cache",
"Check scan result" (lines 316-385 of build-container/action.yaml)

These live inside `.github/actions/build-container/action.yaml`, NOT in
`auto-build.yaml`. Because the Windows step uses the separate
`build-container-windows` action, these steps are already unreachable for Windows
builds. **No changes needed** in `build-container/action.yaml`.

---

## Change 6 — `auto-build.yaml`: skip manifest creation for Windows

**File:** `.github/workflows/auto-build.yaml`
**Job:** `create-manifest`
**Lines:** 528-602 (full job)

Windows images are single-arch (amd64 only) — no multi-arch manifest needed.

### 6a — Add `if` condition to exclude Windows from manifest job

The `create-manifest` job iterates over the full `builds` matrix. Add a filter inside
the manifest-creation steps to skip Windows variants.

**Location:** `create-manifest` → `Create GHCR multi-arch manifest (primary)` step
(lines 560-577), add an early exit for Windows:

Before the `source ./helpers/create-manifest.sh` line, insert:
```bash
          # Windows containers are single-arch — no multi-arch manifest needed
          if [[ "${{ matrix.build.os }}" == "windows" ]]; then
            echo "::notice::Skipping manifest creation for Windows variant ${{ matrix.build.tag }}"
            exit 0
          fi
```

Apply the same early exit to the `Create Docker Hub multi-arch manifest (secondary)`
step for consistency.

---

## Change 7 — `auto-build.yaml` path filters: add `Dockerfile.windows` and `Dockerfile.*`

**File:** `.github/workflows/auto-build.yaml`
**Trigger sections:** `pull_request.paths` (lines 43-54) and `push.paths` (lines 57-68)

The `github-runner` container uses `Dockerfile.windows` instead of `Dockerfile`.
Path filters currently only match `*/Dockerfile`. Add a glob for `Dockerfile.windows`
and `Dockerfile.*` (to cover template-generated Dockerfiles in general).

Before (both `pull_request` and `push` sections):
```yaml
    paths:
      - '*/Dockerfile'
      - '*/version.sh'
      - '*/config.yaml'
      - '*/variants.yaml'
      - '*/docker-compose.yml'
      - '*/compose.yml'
      - '*/extensions/config.yaml'
      - 'helpers/extension-utils.sh'
      - 'make'
      - '!archive/**'  # Exclude archived containers
```

After:
```yaml
    paths:
      - '*/Dockerfile'
      - '*/Dockerfile.*'
      - '*/Dockerfile.windows'
      - '*/version.sh'
      - '*/config.yaml'
      - '*/variants.yaml'
      - '*/docker-compose.yml'
      - '*/compose.yml'
      - '*/extensions/config.yaml'
      - 'helpers/extension-utils.sh'
      - 'make'
      - '!archive/**'  # Exclude archived containers
```

> Note: `*/Dockerfile.*` already covers `Dockerfile.windows`, but explicit entries
> aid grep-ability. Both are included for clarity.

---

## Application Checklist

Apply changes in this order to avoid merge conflicts:

- [ ] Change 1a — `helpers/variant-utils.sh` — versions-only result line
- [ ] Change 1b — `helpers/variant-utils.sh` — add `variant_os`/`runner_label` locals + update result line
- [ ] Change 1c — `helpers/variant-utils.sh` — legacy `list_container_builds` result line
- [ ] Change 2 — `auto-build.yaml` — add `exclude` to matrix strategy
- [ ] Change 3 — `auto-build.yaml` — update `runs-on` expression
- [ ] Change 4a — `auto-build.yaml` — add `if: matrix.build.os != 'windows'` to Linux build steps
- [ ] Change 4b — `auto-build.yaml` — insert `Build container (Windows)` step
- [ ] Change 5 — `auto-build.yaml` — gate `Install syft` on `matrix.build.os != 'windows'`
- [ ] Change 6 — `auto-build.yaml` — early-exit Windows in manifest creation steps
- [ ] Change 7 — `auto-build.yaml` — add `Dockerfile.*` / `Dockerfile.windows` to path filters

---

## Testing the changes

After applying all changes:

1. Run `bats tests/unit/` — variant-utils tests should pass with new `os`/`runner` fields.
2. Inspect matrix JSON locally:
   ```bash
   source helpers/variant-utils.sh
   list_container_builds "github-runner" "2.332.0" | jq .
   ```
   Expected: entries with `"os":"linux"` (ubuntu-2404, debian-trixie) and
   `"os":"windows"` (windows-ltsc2022).
3. Trigger CI on a branch with `github-runner/**` changed — verify 4 Linux jobs on
   `ubuntu-latest`/`ubuntu-24.04-arm` and 2 Windows jobs on `windows-latest`.
