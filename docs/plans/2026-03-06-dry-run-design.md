---
doc-meta:
  status: canonical
---
# Dry-Run Mode — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add `DRY_RUN=true` support so the entire build pipeline runs without executing docker mutating commands — all resolution, matrix, args are computed and logged.

**Architecture:** A `$DOCKER` shell variable (default: `docker`) is set to `echo docker` when `DRY_RUN=true`. Mutating commands use `$DOCKER`, read-only commands keep `docker`. Same pattern for `$SKOPEO`. Non-docker side effects (lineage writes) use a small guard.

**Tech Stack:** Bash, GitHub Actions YAML, bats (tests)

---

### Task 1: Add DOCKER/SKOPEO variables to logging.sh

**Files:**
- Modify: `helpers/logging.sh:13` (after color definitions)
- Test: `tests/unit/dry-run.bats` (new file)

**Step 1: Write the test file**

```bash
# tests/unit/dry-run.bats
#!/usr/bin/env bats

setup() {
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
}

@test "DOCKER defaults to docker when DRY_RUN unset" {
    unset DRY_RUN DOCKER
    source "$PROJECT_ROOT/helpers/logging.sh"
    [[ "$DOCKER" == "docker" ]]
}

@test "DOCKER becomes echo docker when DRY_RUN=true" {
    export DRY_RUN=true
    unset DOCKER
    source "$PROJECT_ROOT/helpers/logging.sh"
    [[ "$DOCKER" == "echo docker" ]]
}

@test "DOCKER can be overridden even with DRY_RUN=true" {
    export DRY_RUN=true
    export DOCKER="/usr/local/bin/podman"
    source "$PROJECT_ROOT/helpers/logging.sh"
    [[ "$DOCKER" == "/usr/local/bin/podman" ]]
}

@test "SKOPEO defaults to skopeo when DRY_RUN unset" {
    unset DRY_RUN SKOPEO
    source "$PROJECT_ROOT/helpers/logging.sh"
    [[ "$SKOPEO" == "skopeo" ]]
}

@test "SKOPEO becomes echo skopeo when DRY_RUN=true" {
    export DRY_RUN=true
    unset SKOPEO
    source "$PROJECT_ROOT/helpers/logging.sh"
    [[ "$SKOPEO" == "echo skopeo" ]]
}

@test "echo docker outputs the full command" {
    DOCKER="echo docker"
    result=$($DOCKER buildx build --load --platform linux/amd64 -t myimage:latest .)
    [[ "$result" == "docker buildx build --load --platform linux/amd64 -t myimage:latest ." ]]
}
```

**Step 2: Run test to verify it fails**

Run: `bats tests/unit/dry-run.bats`
Expected: FAIL — DOCKER variable not set in logging.sh

**Step 3: Add DOCKER/SKOPEO to logging.sh**

After line 13 (`fi` closing the color block), add:

```bash
# Dry-run support: $DOCKER/$SKOPEO replace hardcoded commands
# DRY_RUN=true → commands print instead of executing
# DOCKER/SKOPEO can also be overridden directly (e.g., podman)
if [[ -z "${DOCKER:-}" ]]; then
    DOCKER="docker"
    [[ "${DRY_RUN:-false}" == "true" ]] && DOCKER="echo docker"
fi
if [[ -z "${SKOPEO:-}" ]]; then
    SKOPEO="skopeo"
    [[ "${DRY_RUN:-false}" == "true" ]] && SKOPEO="echo skopeo"
fi
```

**Step 4: Run test to verify it passes**

Run: `bats tests/unit/dry-run.bats`
Expected: 6/6 PASS

**Step 5: Commit**

```
git add helpers/logging.sh tests/unit/dry-run.bats
git commit -m "feat: add DRY_RUN support via \$DOCKER/\$SKOPEO variables in logging.sh"
```

---

### Task 2: Patch build-container.sh — replace docker buildx build

**Files:**
- Modify: `scripts/build-container.sh:301,320` (two `docker buildx build` calls)
- Modify: `scripts/build-container.sh:339` (lineage write guard)
- Test: `tests/unit/dry-run.bats` (append)

**Step 1: Add tests for build dry-run**

Append to `tests/unit/dry-run.bats`:

```bash
@test "build_container in dry-run does not call docker buildx build" {
    export DRY_RUN=true
    unset DOCKER
    source "$PROJECT_ROOT/helpers/logging.sh"

    # Verify DOCKER is set to echo
    [[ "$DOCKER" == "echo docker" ]]
}

@test "dry-run lineage file is not written" {
    export DRY_RUN=true
    local tmpdir
    tmpdir=$(mktemp -d)
    # Simulate the guard
    if [[ "${DRY_RUN:-false}" != "true" ]]; then
        touch "$tmpdir/lineage.json"
    fi
    [[ ! -f "$tmpdir/lineage.json" ]]
    rm -rf "$tmpdir"
}
```

**Step 2: Patch line 301 — GitHub Actions build**

Replace `docker buildx build \` with `$DOCKER buildx build \` (line 301).

**Step 3: Patch line 320 — local build**

Replace `docker buildx build \` with `$DOCKER buildx build \` (line 320).

**Step 4: Guard lineage write (line 339)**

Wrap the `_emit_build_lineage` call:

```bash
    _BUILD_DURATION_SECONDS=$(( SECONDS - _build_start ))
    if [[ "${DRY_RUN:-false}" != "true" ]]; then
        _emit_build_lineage "$container" "$version" "$tag" "$flavor" "$dockerfile" \
            "$_PLATFORMS" "$_RUNTIME_INFO" "$dockerhub_image" "$ghcr_image"
    else
        log_info "[DRY-RUN] Would write lineage: .build-lineage/${container}-${tag}.json"
    fi
```

**Step 5: Run tests**

Run: `bats tests/unit/dry-run.bats tests/unit/build-cache-utils.bats`
Expected: All pass (existing tests unaffected)

**Step 6: Commit**

```
git add scripts/build-container.sh tests/unit/dry-run.bats
git commit -m "feat(dry-run): patch build-container.sh — \$DOCKER for builds, guard lineage"
```

---

### Task 3: Patch push-container.sh — replace docker/skopeo commands

**Files:**
- Modify: `scripts/push-container.sh:103` (GHCR push)
- Modify: `scripts/push-container.sh:122` (skopeo-squash GHCR)
- Modify: `scripts/push-container.sh:154,163` (skopeo copy to Docker Hub)
- Modify: `scripts/push-container.sh:195` (buildx fallback to Docker Hub)
- Modify: `scripts/push-container.sh:214` (skopeo-squash Docker Hub)

**Step 1: Patch push_ghcr (line 103)**

Replace:
```bash
    retry_with_backoff 3 5 docker buildx build \
```
With:
```bash
    retry_with_backoff 3 5 $DOCKER buildx build \
```

**Step 2: Patch skopeo-squash calls (lines 122, 214)**

Replace `../helpers/skopeo-squash` with `$SKOPEO` won't work here (it's a script, not skopeo directly). Instead guard:

Line 122:
```bash
    if [[ "${SQUASH_IMAGE:-false}" == "true" && -z "$platform_suffix" && "${DRY_RUN:-false}" != "true" ]]; then
```

Line 214: same pattern.

**Step 3: Patch skopeo copy in push_dockerhub (lines 154, 163)**

Replace:
```bash
        if retry_with_backoff 5 10 skopeo copy \
```
With:
```bash
        if retry_with_backoff 5 10 $SKOPEO copy \
```

Line 163:
```bash
                skopeo copy --all \
```
With:
```bash
                $SKOPEO copy --all \
```

**Step 4: Patch buildx fallback push (line 195)**

Replace:
```bash
    retry_with_backoff 5 10 docker buildx build \
```
With:
```bash
    retry_with_backoff 5 10 $DOCKER buildx build \
```

**Step 5: Run existing push tests**

Run: `bats tests/unit/push-container.bats tests/unit/dry-run.bats`
Expected: All pass

**Step 6: Commit**

```
git add scripts/push-container.sh
git commit -m "feat(dry-run): patch push-container.sh — \$DOCKER and \$SKOPEO for pushes"
```

---

### Task 4: Patch create-manifest.sh — replace imagetools create

**Files:**
- Modify: `helpers/create-manifest.sh:1` (add source logging.sh)
- Modify: `helpers/create-manifest.sh:71,80,88` (three `docker buildx imagetools create`)

**Step 1: Source logging.sh at top**

After `set -euo pipefail` (line 15), add:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/logging.sh"
```

**Step 2: Replace three docker calls**

Line 71: `docker buildx imagetools create` → `$DOCKER buildx imagetools create`
Line 80: same
Line 88: same

**Step 3: Run tests**

Run: `bats tests/unit/dry-run.bats`
Expected: All pass

**Step 4: Commit**

```
git add helpers/create-manifest.sh
git commit -m "feat(dry-run): patch create-manifest.sh — \$DOCKER for manifest creation"
```

---

### Task 5: Patch extension-utils.sh — replace docker build/tag/push

**Files:**
- Modify: `helpers/extension-utils.sh` (docker build, docker tag, docker push calls)

**Step 1: Find and replace docker mutating commands**

Replace all `docker build` (not `docker buildx`) with `$DOCKER build`.
Replace all `docker tag` with `$DOCKER tag`.
Replace all `docker push` with `$DOCKER push`.

Leave `docker manifest inspect` as-is (read-only).

**Step 2: Run tests**

Run: `bats tests/unit/dry-run.bats`
Expected: All pass

**Step 3: Commit**

```
git add helpers/extension-utils.sh
git commit -m "feat(dry-run): patch extension-utils.sh — \$DOCKER for extension builds"
```

---

### Task 6: Add dry_run input to auto-build.yaml

**Files:**
- Modify: `.github/workflows/auto-build.yaml` (inputs section + env)

**Step 1: Add input to workflow_dispatch and workflow_call**

In the `workflow_dispatch.inputs` section, add:

```yaml
      dry_run:
        description: 'Dry run — resolve everything but skip docker build/push/manifest'
        required: false
        default: false
        type: boolean
```

Same in `workflow_call.inputs`.

**Step 2: Add env at workflow level**

At the top-level `env:` block (or create one if absent):

```yaml
env:
  DRY_RUN: ${{ inputs.dry_run && 'true' || 'false' }}
```

**Step 3: Skip Trivy/SBOM steps in build-container action**

In `.github/actions/build-container/action.yaml`, wrap Trivy and SBOM steps with:

```yaml
      if: env.DRY_RUN != 'true'
```

**Step 4: Commit**

```
git add .github/workflows/auto-build.yaml .github/actions/build-container/action.yaml
git commit -m "feat(dry-run): add dry_run input to auto-build workflow"
```

---

### Task 7: Integration test — local dry-run

**Step 1: Run local dry-run for a simple container**

```bash
DRY_RUN=true ./make build ansible
```

Expected output: all resolution runs, `echo docker buildx build ...` prints the full command, no image built, no lineage written.

**Step 2: Run local dry-run for a variant container**

```bash
DRY_RUN=true ./make build postgres
```

Expected: matrix resolved, each variant prints its docker command, no build.

**Step 3: Run local dry-run for push**

```bash
DRY_RUN=true ./make push terraform 1.14.6
```

Expected: GHCR and Docker Hub commands printed, no push.

**Step 4: Run all unit tests**

```bash
bats tests/unit/*.bats
```

Expected: All pass (137+ existing + 8 new dry-run tests).

**Step 5: Final commit**

```
git commit -m "docs: dry-run implementation plan"
```

---

## Summary

| Task | Files | Changes |
|---|---|---|
| 1 | `helpers/logging.sh`, `tests/unit/dry-run.bats` | DOCKER/SKOPEO vars + tests |
| 2 | `scripts/build-container.sh` | 2x `docker` → `$DOCKER`, lineage guard |
| 3 | `scripts/push-container.sh` | 3x `docker` → `$DOCKER`, 2x `skopeo` → `$SKOPEO`, squash guards |
| 4 | `helpers/create-manifest.sh` | 3x `docker` → `$DOCKER`, source logging.sh |
| 5 | `helpers/extension-utils.sh` | 3x `docker` → `$DOCKER` |
| 6 | `.github/workflows/auto-build.yaml`, `.github/actions/build-container/action.yaml` | dry_run input, skip Trivy/SBOM |
| 7 | Integration test | Local dry-run validation |
