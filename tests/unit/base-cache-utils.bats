#!/usr/bin/env bats

# Unit tests for helpers/base-cache-utils.sh
# Covers: resolve_cache_check_tag  — tag resolution for GHCR accessibility checks
#         emit_reachable_cache_args — --build-arg emission (sole validated emitter)
#         remote_cr_applicable      — REMOTE_CR applicability decision (pure function)
#         distro_uses_base_cache    — distro-level base-cache opt-out
#         collect_all_cache_images / _collect_entry_tags — image dest path for old and new styles

setup() {
    TEST_DIR=$(mktemp -d)
    ORIG_DIR="$PWD"
    cd "$TEST_DIR" || exit 1

    source "$ORIG_DIR/helpers/logging.sh"
    source "$ORIG_DIR/helpers/variant-utils.sh"
    source "$ORIG_DIR/helpers/base-cache-utils.sh"

    unset SYNC_MANIFEST_OUT
}

teardown() {
    unset SYNC_MANIFEST_OUT
    cd "$ORIG_DIR" || true
    rm -rf "$TEST_DIR"
}

# --- distro_uses_base_cache ---

@test "BCU-DISTRO-01: distro_uses_base_cache returns false for explicit opt-out" {
    cat > config.yaml <<'EOF'
distros:
  debian:
    use_base_cache: false
EOF

    run distro_uses_base_cache "config.yaml" "debian"
    [ "$status" -eq 1 ]
}

@test "BCU-DISTRO-02: distro_uses_base_cache returns true when key is absent" {
    cat > config.yaml <<'EOF'
distros:
  alpine:
    base_image: "alpine:3.21"
EOF

    run distro_uses_base_cache "config.yaml" "alpine"
    [ "$status" -eq 0 ]
}

@test "BCU-DISTRO-03: distro_uses_base_cache returns true without distros block" {
    cat > config.yaml <<'EOF'
base_image_cache:
  - source: library/alpine
    tags: ["3.21"]
EOF

    run distro_uses_base_cache "config.yaml" "alpine"
    [ "$status" -eq 0 ]
}

@test "BCU-DISTRO-04: distro_uses_base_cache returns true for empty distro arg" {
    cat > config.yaml <<'EOF'
distros:
  debian:
    use_base_cache: false
EOF

    run distro_uses_base_cache "config.yaml" ""
    [ "$status" -eq 0 ]
}

# --- resolve_cache_check_tag ---

# BCU-01: regression lock for the docker.io 429 bug
# tags_from_versions: true → must return build_version, NOT "latest"
@test "BCU-01: tags_from_versions=true returns build_version (regression lock: not 'latest')" {
    cat > config.yaml <<'EOF'
base_image_cache:
  - arg: BASE_IMAGE
    source: postgres
    ghcr_repo: postgres-base
    tags_from_versions: true
EOF

    run resolve_cache_check_tag "config.yaml" 0 "18-alpine"
    [ "$status" -eq 0 ]
    [ "$output" = "18-alpine" ]

    # Mutation guard: revert would return "latest" — verify it is NOT "latest"
    [ "$output" != "latest" ]
}

# BCU-02: tags_from_versions=true with a different build_version
@test "BCU-02: tags_from_versions=true returns whatever build_version is passed" {
    cat > config.yaml <<'EOF'
base_image_cache:
  - arg: BASE_IMAGE
    source: postgres
    ghcr_repo: postgres-base
    tags_from_versions: true
EOF

    run resolve_cache_check_tag "config.yaml" 0 "17-alpine"
    [ "$status" -eq 0 ]
    [ "$output" = "17-alpine" ]
}

# BCU-03: tags[] literal array → returns the literal tag (existing behaviour preserved)
@test "BCU-03: literal tags[0] entry returns the literal tag" {
    cat > config.yaml <<'EOF'
base_image_cache:
  - arg: BASE_IMAGE
    source: ubuntu
    ghcr_repo: ubuntu-base
    tags: ["latest"]
EOF

    run resolve_cache_check_tag "config.yaml" 0 "22.04"
    [ "$status" -eq 0 ]
    [ "$output" = "latest" ]
}

# BCU-04: tags[] with a template that uses ${VERSION}
@test "BCU-04: tags[0] template using \${VERSION} is resolved to build_version" {
    cat > config.yaml <<'EOF'
base_image_cache:
  - arg: TERRAFORM_BASE
    source: hashicorp/terraform
    ghcr_repo: terraform-base
    tags: ["${VERSION}"]
EOF

    run resolve_cache_check_tag "config.yaml" 0 "1.9.5"
    [ "$status" -eq 0 ]
    [ "$output" = "1.9.5" ]
}

# BCU-05: no tags key and tags_from_versions absent → falls back to "latest"
@test "BCU-05: absent tags and no tags_from_versions defaults to 'latest'" {
    cat > config.yaml <<'EOF'
base_image_cache:
  - arg: BASE_IMAGE
    source: alpine
    ghcr_repo: alpine-base
EOF

    run resolve_cache_check_tag "config.yaml" 0 "3.21"
    [ "$status" -eq 0 ]
    [ "$output" = "latest" ]
}

# BCU-06: second entry (index=1) is resolved correctly
@test "BCU-06: entry at index 1 is resolved independently" {
    cat > config.yaml <<'EOF'
base_image_cache:
  - arg: BASE_IMAGE
    source: hashicorp/terraform
    ghcr_repo: terraform-base
    tags: ["${VERSION}"]
  - arg: ALPINE_BASE
    source: alpine
    ghcr_repo: alpine-base
    tags: ["3.21"]
EOF

    run resolve_cache_check_tag "config.yaml" 1 "1.9.5"
    [ "$status" -eq 0 ]
    [ "$output" = "3.21" ]
}

# --- collect_all_cache_images / _collect_entry_tags: new-style dest path ---

# BCU-11: NEW-style entry → sync_image dest preserves source path (library/postgres)
# sync_image must be ghcr.io/<owner>/library/postgres:<tag> — NOT ghcr.io/<owner>/postgres:<tag>
@test "BCU-11: NEW-style collect_all_cache_images dest preserves full source path with slash" {
    mkdir -p pgcontainer
    cat > pgcontainer/variants.yaml <<'EOF'
versions:
  - tag: "18-alpine"
  - tag: "17-alpine"
EOF
    cat > pgcontainer/config.yaml <<'EOF'
base_image_cache:
  - source: library/postgres
    tags_from_versions: true
EOF

    local containers_json='["pgcontainer"]'
    local versions_json='{"pgcontainer":"18-alpine"}'

    run collect_all_cache_images "$containers_json" "$versions_json" "myowner"
    [ "$status" -eq 0 ]
    # sync_image must contain the two-segment path library/postgres (NOT just postgres)
    [[ "$output" == *"ghcr.io/myowner/library/postgres:"* ]]
    # Distinctness assertion: the path portion after owner must contain a '/'
    # i.e. library/postgres not just postgres
    [[ "$output" != *"ghcr.io/myowner/postgres:"* ]]
}

# BCU-12: OLD-style entry → sync_image dest uses ghcr_repo (regression lock)
@test "BCU-12: OLD-style collect_all_cache_images dest uses ghcr_repo (regression lock)" {
    mkdir -p ubuntucontainer
    cat > ubuntucontainer/config.yaml <<'EOF'
base_image_cache:
  - arg: BASE_IMAGE
    source: ubuntu
    ghcr_repo: ubuntu-base
    tags: ["latest"]
EOF

    local containers_json='["ubuntucontainer"]'
    local versions_json='{"ubuntucontainer":"22.04"}'

    run collect_all_cache_images "$containers_json" "$versions_json" "myowner"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ghcr.io/myowner/ubuntu-base:latest"* ]]
}

# BCU-13: MIXED collect_all_cache_images — both old and new sync_image dests correct
@test "BCU-13: MIXED collect_all_cache_images — old uses ghcr_repo, new uses source path" {
    mkdir -p mixcontainer
    cat > mixcontainer/variants.yaml <<'EOF'
versions:
  - tag: "18-alpine"
EOF
    cat > mixcontainer/config.yaml <<'EOF'
base_image_cache:
  - arg: BASE_IMAGE
    source: ubuntu
    ghcr_repo: ubuntu-base
    tags: ["latest"]
  - source: library/postgres
    tags_from_versions: true
EOF

    local containers_json='["mixcontainer"]'
    local versions_json='{"mixcontainer":"18-alpine"}'

    run collect_all_cache_images "$containers_json" "$versions_json" "myowner"
    [ "$status" -eq 0 ]
    # Old-style dest
    [[ "$output" == *"ghcr.io/myowner/ubuntu-base:latest"* ]]
    # New-style dest preserves full source path
    [[ "$output" == *"ghcr.io/myowner/library/postgres:"* ]]
}

# --- Leading-slash (chained-on-own-build) source path splitting ---

# BCU-14: leading-slash source → sync_image has library/ prefix, probe_image is leaf-only
@test "BCU-14: leading-slash source (/php) → sync_image uses library/php, probe_image uses php" {
    mkdir -p wpcontainer
    cat > wpcontainer/config.yaml <<'EOF'
base_image_cache:
  - source: /php
    tags: ["latest"]
EOF

    local containers_json='["wpcontainer"]'
    local versions_json='{"wpcontainer":"latest"}'

    run collect_all_cache_images "$containers_json" "$versions_json" "myowner"
    [ "$status" -eq 0 ]
    # sync_image must use library/ prefix (mirror dest)
    [[ "$output" == *'"sync_image":"ghcr.io/myowner/library/php:latest"'* ]]
    # probe_image must be leaf-only (project's published container)
    [[ "$output" == *'"probe_image":"ghcr.io/myowner/php:latest"'* ]]
    # Distinctness: sync_image must not equal the probe_image path
    [[ "$output" != *'"sync_image":"ghcr.io/myowner/php:latest"'* ]]
}

# BCU-15: normal NEW-style source → sync_image == probe_image
@test "BCU-15: normal NEW-style source (library/postgres) → sync_image equals probe_image" {
    mkdir -p pgcontainer2
    cat > pgcontainer2/variants.yaml <<'EOF'
versions:
  - tag: "18-alpine"
EOF
    cat > pgcontainer2/config.yaml <<'EOF'
base_image_cache:
  - source: library/postgres
    tags_from_versions: true
EOF

    local containers_json='["pgcontainer2"]'
    local versions_json='{"pgcontainer2":"18-alpine"}'

    run collect_all_cache_images "$containers_json" "$versions_json" "myowner"
    [ "$status" -eq 0 ]
    # Both fields must be identical for normal NEW-style entries
    [[ "$output" == *'"sync_image":"ghcr.io/myowner/library/postgres:18-alpine"'* ]]
    [[ "$output" == *'"probe_image":"ghcr.io/myowner/library/postgres:18-alpine"'* ]]
}

# BCU-15b: sync_base_images_to_ghcr with leading-slash source — source_ref has explicit library/ prefix
@test "BCU-15b: sync_base_images_to_ghcr leading-slash source — source_ref has explicit library/ prefix" {
    docker() {
        if [[ "$1" == "buildx" && "$2" == "imagetools" && "$3" == "create" ]]; then
            echo "MOCK_DOCKER_ARGS: $*"
            return 0
        fi
        return 0
    }
    export -f docker

    # Leading-slash source /php must produce docker.io/library/php:latest (not docker.io/php:latest).
    # The Docker daemon silently aliases docker.io/php → docker.io/library/php, but skopeo and
    # imagetools do not; the explicit prefix is required for idempotent mirroring.
    local input='[{"source":"/php","tag":"latest","sync_image":"ghcr.io/myowner/library/php:latest","probe_image":"ghcr.io/myowner/php:latest"}]'
    run sync_base_images_to_ghcr "$input"
    [ "$status" -eq 0 ]
    # Source ref must carry the explicit library/ segment
    [[ "$output" == *"docker.io/library/php:latest"* ]]
    [[ "$output" != *"docker.io//php:latest"* ]]
    [[ "$output" != *"docker.io/php:latest "* ]]
    # Dest must be the sync_image (library/php path)
    [[ "$output" == *"ghcr.io/myowner/library/php:latest"* ]]
}

# BCU-15d: mutation guard — single-segment chained source must never produce an alias-only ref
@test "BCU-15d: sync_base_images_to_ghcr single-segment chained source — no bare alias (library/ always explicit)" {
    docker() { return 0; }
    export -f docker

    # /debian is another single-segment chained marker.  The constructed source_ref
    # must be docker.io/library/debian:bullseye, not docker.io/debian:bullseye.
    # Revert the leading-slash strip in sync_base_images_to_ghcr and this test fails.
    local input='[{"source":"/debian","tag":"bullseye","sync_image":"ghcr.io/myowner/library/debian:bullseye","probe_image":"ghcr.io/myowner/debian:bullseye"}]'
    run sync_base_images_to_ghcr "$input"
    [ "$status" -eq 0 ]
    [[ "$output" == *"docker.io/library/debian:bullseye"* ]]
    # The bare alias form must be absent (no double-slash collapse residue either)
    [[ "$output" != *"docker.io/debian:bullseye"* ]]
    [[ "$output" != *"docker.io//debian:bullseye"* ]]
}

# BCU-15c: dedup by sync_image — entries with same sync_image path are deduplicated
@test "BCU-15c: collect_all_cache_images dedup uses sync_image field" {
    mkdir -p dedup1 dedup2
    cat > dedup1/config.yaml <<'EOF'
base_image_cache:
  - source: /php
    tags: ["latest"]
EOF
    cat > dedup2/config.yaml <<'EOF'
base_image_cache:
  - source: library/php
    tags: ["latest"]
EOF

    local containers_json='["dedup1","dedup2"]'
    local versions_json='{"dedup1":"latest","dedup2":"latest"}'

    run collect_all_cache_images "$containers_json" "$versions_json" "myowner"
    [ "$status" -eq 0 ]
    # dedup1 sync_image=ghcr.io/myowner/library/php:latest
    # dedup2 sync_image=ghcr.io/myowner/library/php:latest — same → deduped to 1 entry
    local count
    count=$(echo "$output" | jq 'length')
    [ "$count" -eq 1 ]
}

# --- discriminator robustness: empty-string and explicit-nil ghcr_repo ---
# These cases are fully covered via emit_reachable_cache_args + remote_cr_applicable tests below.

# --- remote_cr_applicable: pure decision helper ---

# BCU-16: all new-style entries reachable → "apply"
@test "BCU-16: remote_cr_applicable — all new-style reachable → apply" {
    mkdir -p pgcontainer
    cat > pgcontainer/config.yaml <<'EOF'
base_image_cache:
  - source: library/postgres
    tags_from_versions: true
EOF
    run remote_cr_applicable "pgcontainer/config.yaml" "true"
    [ "$status" -eq 0 ]
    [ "$output" = "apply" ]
}

# BCU-17: mixed old+new config, new-style entry unreachable → "drop"
# Locks the always-apply mutation: a single unreachable new-style entry in a mixed
# config must produce "drop", not "apply". BCU-20 covers the partial-reachability
# boundary (multiple new-style entries, only some reachable).
@test "BCU-17: remote_cr_applicable — mixed old+new, new-style unreachable → drop (always-apply mutation lock)" {
    mkdir -p mixcontainer
    cat > mixcontainer/config.yaml <<'EOF'
base_image_cache:
  - arg: BASE_IMAGE
    source: ubuntu
    ghcr_repo: ubuntu-base
    tags: ["latest"]
  - source: library/postgres
    tags_from_versions: true
EOF
    # Flag 0 = old-style (reachable, passed as "true"), flag 1 = new-style (missing, "false")
    run remote_cr_applicable "mixcontainer/config.yaml" "true" "false"
    [ "$status" -eq 0 ]
    [ "$output" = "drop" ]
    # Mutation guard: must NOT be "apply" — that is the bug FIX-1 corrects
    [ "$output" != "apply" ]
}

# BCU-18: no new-style entries → "n/a"
@test "BCU-18: remote_cr_applicable — pure old-style config → n/a" {
    mkdir -p oldcontainer
    cat > oldcontainer/config.yaml <<'EOF'
base_image_cache:
  - arg: BASE_IMAGE
    source: ubuntu
    ghcr_repo: ubuntu-base
    tags: ["latest"]
EOF
    run remote_cr_applicable "oldcontainer/config.yaml" "true"
    [ "$status" -eq 0 ]
    [ "$output" = "n/a" ]
}

# BCU-19: multiple new-style entries all reachable → "apply"
@test "BCU-19: remote_cr_applicable — multiple new-style all reachable → apply" {
    mkdir -p multinew
    cat > multinew/config.yaml <<'EOF'
base_image_cache:
  - source: library/postgres
    tags_from_versions: true
  - source: library/alpine
    tags: ["3.21"]
EOF
    run remote_cr_applicable "multinew/config.yaml" "true" "true"
    [ "$status" -eq 0 ]
    [ "$output" = "apply" ]
}

# BCU-20: multiple new-style entries with one unreachable → "drop"
@test "BCU-20: remote_cr_applicable — multiple new-style one unreachable → drop" {
    mkdir -p multinew2
    cat > multinew2/config.yaml <<'EOF'
base_image_cache:
  - source: library/postgres
    tags_from_versions: true
  - source: library/alpine
    tags: ["3.21"]
EOF
    run remote_cr_applicable "multinew2/config.yaml" "true" "false"
    [ "$status" -eq 0 ]
    [ "$output" = "drop" ]
}

# BCU-21: mixed old+new, new reachable → "apply" (old flags are ignored)
@test "BCU-21: remote_cr_applicable — mixed old+new, new reachable → apply" {
    mkdir -p mixok
    cat > mixok/config.yaml <<'EOF'
base_image_cache:
  - arg: BASE_IMAGE
    source: ubuntu
    ghcr_repo: ubuntu-base
    tags: ["latest"]
  - source: library/postgres
    tags_from_versions: true
EOF
    # Flag 0 = old-style ("old" semantically, but we pass "true" — old flags are not counted)
    # Flag 1 = new-style, reachable
    run remote_cr_applicable "mixok/config.yaml" "true" "true"
    [ "$status" -eq 0 ]
    [ "$output" = "apply" ]
}

# --- emit_reachable_cache_args: per-entry filtered arg emitter ---

# BCU-22: all old-style entries reachable → all --build-arg flags emitted (regression lock)
@test "BCU-22: emit_reachable_cache_args — all old-style reachable → all args emitted" {
    mkdir -p oldall
    cat > oldall/config.yaml <<'EOF'
base_image_cache:
  - arg: BASE_IMAGE
    source: ubuntu
    ghcr_repo: ubuntu-base
    tags: ["latest"]
  - arg: ALPINE_BASE
    source: alpine
    ghcr_repo: alpine-base
    tags: ["3.21"]
EOF
    run emit_reachable_cache_args "oldall/config.yaml" "myowner" "22.04" "true" "true"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--build-arg BASE_IMAGE=ghcr.io/myowner/ubuntu-base"* ]]
    [[ "$output" == *"--build-arg ALPINE_BASE=ghcr.io/myowner/alpine-base"* ]]
    # No REMOTE_CR — pure old-style config
    [[ "$output" != *"REMOTE_CR"* ]]
}

# BCU-23 (RED→GREEN for FINDING A): one old-style entry unreachable → that arg omitted
# This is the class bug: old-style args were previously bulk-applied on any-reachable.
# Now each arg is gated on its own probe flag.
@test "BCU-23: emit_reachable_cache_args — one old-style unreachable → only reachable arg emitted (FINDING-A lock)" {
    mkdir -p oldpartial
    cat > oldpartial/config.yaml <<'EOF'
base_image_cache:
  - arg: BASE_IMAGE
    source: ubuntu
    ghcr_repo: ubuntu-base
    tags: ["latest"]
  - arg: ALPINE_BASE
    source: alpine
    ghcr_repo: alpine-base
    tags: ["3.21"]
EOF
    # Entry 0 reachable, entry 1 NOT reachable
    run emit_reachable_cache_args "oldpartial/config.yaml" "myowner" "22.04" "true" "false"
    [ "$status" -eq 0 ]
    # Reachable entry present
    [[ "$output" == *"--build-arg BASE_IMAGE=ghcr.io/myowner/ubuntu-base"* ]]
    # Unreachable entry ABSENT — mutation guard: the bulk-apply bug would include it
    [[ "$output" != *"--build-arg ALPINE_BASE="* ]]
    # No REMOTE_CR
    [[ "$output" != *"REMOTE_CR"* ]]
}

# BCU-24: mixed old+new, all reachable → old args + REMOTE_CR present
@test "BCU-24: emit_reachable_cache_args — mixed old+new all reachable → old args + REMOTE_CR" {
    mkdir -p mixall
    cat > mixall/config.yaml <<'EOF'
base_image_cache:
  - arg: BASE_IMAGE
    source: ubuntu
    ghcr_repo: ubuntu-base
    tags: ["latest"]
  - source: library/postgres
    tags_from_versions: true
EOF
    run emit_reachable_cache_args "mixall/config.yaml" "myowner" "18-alpine" "true" "true"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--build-arg BASE_IMAGE=ghcr.io/myowner/ubuntu-base"* ]]
    [[ "$output" == *"--build-arg REMOTE_CR=ghcr.io/myowner"* ]]
}

# BCU-25: mixed old+new, new-style unreachable → old reachable arg present, REMOTE_CR ABSENT
@test "BCU-25: emit_reachable_cache_args — mixed old+new, new unreachable → old arg kept, REMOTE_CR absent" {
    mkdir -p mixnewmissing
    cat > mixnewmissing/config.yaml <<'EOF'
base_image_cache:
  - arg: BASE_IMAGE
    source: ubuntu
    ghcr_repo: ubuntu-base
    tags: ["latest"]
  - source: library/postgres
    tags_from_versions: true
EOF
    # Entry 0 (old) reachable, entry 1 (new) NOT reachable
    run emit_reachable_cache_args "mixnewmissing/config.yaml" "myowner" "18-alpine" "true" "false"
    [ "$status" -eq 0 ]
    # Old-style arg still present (independent of new-style reachability)
    [[ "$output" == *"--build-arg BASE_IMAGE=ghcr.io/myowner/ubuntu-base"* ]]
    # REMOTE_CR absent — new-style mirror missing → must NOT be applied
    [[ "$output" != *"REMOTE_CR"* ]]
}

# BCU-26: pure new-style, all reachable → REMOTE_CR emitted, no old-style args
@test "BCU-26: emit_reachable_cache_args — pure new-style all reachable → REMOTE_CR only" {
    mkdir -p newonly
    cat > newonly/config.yaml <<'EOF'
base_image_cache:
  - source: library/postgres
    tags_from_versions: true
EOF
    run emit_reachable_cache_args "newonly/config.yaml" "myowner" "18-alpine" "true"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--build-arg REMOTE_CR=ghcr.io/myowner"* ]]
    # No old-style arg
    [[ "$output" != *"BASE_IMAGE"* ]]
}

# BCU-27: pure new-style, unreachable → empty output (no REMOTE_CR)
@test "BCU-27: emit_reachable_cache_args — pure new-style unreachable → empty output" {
    mkdir -p newmiss
    cat > newmiss/config.yaml <<'EOF'
base_image_cache:
  - source: library/postgres
    tags_from_versions: true
EOF
    run emit_reachable_cache_args "newmiss/config.yaml" "myowner" "18-alpine" "false"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ─── FIX 2 (RED→GREEN): emit_reachable_cache_args arg validation ─────────────

# BCU-FIX2-01: OLD-style entry with injected shell tokens in arg → non-zero, no flag emitted
# This is the FINDING: "BASE_IMAGE --network host" would inject extra docker flags.
# RED before fix (returns 0, emits the bad flag), GREEN after (returns non-zero, emits nothing).
@test "BCU-FIX2-01: emit_reachable_cache_args — malformed arg with shell token → non-zero + no flag (injection prevention)" {
    mkdir -p badarg
    cat > badarg/config.yaml <<'EOF'
base_image_cache:
  - arg: "BASE_IMAGE --network host"
    source: ubuntu
    ghcr_repo: ubuntu-base
    tags: ["latest"]
EOF
    run emit_reachable_cache_args "badarg/config.yaml" "myowner" "22.04" "true"
    # Must fail closed (non-zero exit)
    [ "$status" -ne 0 ]
    # Must not emit any --build-arg flag (no partial emission)
    [[ "$output" != *"--build-arg"* ]]
}

# BCU-FIX2-02: OLD-style entry with multi-word arg (spaces) → non-zero
@test "BCU-FIX2-02: emit_reachable_cache_args — arg with embedded spaces → non-zero" {
    mkdir -p badarg2
    cat > badarg2/config.yaml <<'EOF'
base_image_cache:
  - arg: "FOO BAR"
    source: ubuntu
    ghcr_repo: ubuntu-base
    tags: ["latest"]
EOF
    run emit_reachable_cache_args "badarg2/config.yaml" "myowner" "22.04" "true"
    [ "$status" -ne 0 ]
    [[ "$output" != *"--build-arg"* ]]
}

# BCU-FIX2-03: OLD-style entry with hyphen in arg (invalid Docker ARG name) → non-zero
@test "BCU-FIX2-03: emit_reachable_cache_args — arg with hyphen → non-zero" {
    mkdir -p badarg3
    cat > badarg3/config.yaml <<'EOF'
base_image_cache:
  - arg: "BASE-IMAGE"
    source: ubuntu
    ghcr_repo: ubuntu-base
    tags: ["latest"]
EOF
    run emit_reachable_cache_args "badarg3/config.yaml" "myowner" "22.04" "true"
    [ "$status" -ne 0 ]
    [[ "$output" != *"--build-arg"* ]]
}

# BCU-FIX2-PASS: valid arg identifier → clean output (regression lock)
# This must pass before AND after the fix (it was already working; guard against over-rejection).
@test "BCU-FIX2-PASS: emit_reachable_cache_args — valid identifier arg → emits flag correctly" {
    mkdir -p validarg
    cat > validarg/config.yaml <<'EOF'
base_image_cache:
  - arg: BASE_IMAGE
    source: ubuntu
    ghcr_repo: ubuntu-base
    tags: ["latest"]
EOF
    run emit_reachable_cache_args "validarg/config.yaml" "myowner" "22.04" "true"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--build-arg BASE_IMAGE=ghcr.io/myowner/ubuntu-base"* ]]
}

# BCU-FIX2-05: unreachable old-style entry with bad arg → still non-zero
# The validation must run regardless of the reachability flag — bad config is a config error,
# not a "suppress it" signal. (Guards against: skip validation if flag==false.)
@test "BCU-FIX2-05: emit_reachable_cache_args — bad arg in unreachable entry → non-zero (no silent skip)" {
    mkdir -p badarg5
    cat > badarg5/config.yaml <<'EOF'
base_image_cache:
  - arg: "BASE_IMAGE --network host"
    source: ubuntu
    ghcr_repo: ubuntu-base
    tags: ["latest"]
EOF
    # Flag is "false" (entry unreachable) — but arg is still validated
    run emit_reachable_cache_args "badarg5/config.yaml" "myowner" "22.04" "false"
    [ "$status" -ne 0 ]
}

# ─── FIX A: ghcr_repo injection prevention in emit_reachable_cache_args ──────

# BCU-GHCR-01 (RED→GREEN): old-style entry with malicious ghcr_repo → non-zero, no flag emitted
# The attack: "ubuntu-base --network host" expands in the flag string to:
#   --build-arg BASE_IMAGE=ghcr.io/owner/ubuntu-base --network host
# which would inject extra docker flags silently.
# After the fix, emit_reachable_cache_args must return non-zero and emit nothing.
@test "BCU-GHCR-01: emit_reachable_cache_args — ghcr_repo with space+flag → non-zero + no flag (injection prevention)" {
    mkdir -p badrepo
    cat > badrepo/config.yaml <<'EOF'
base_image_cache:
  - arg: BASE_IMAGE
    source: ubuntu
    ghcr_repo: "ubuntu-base --network host"
    tags: ["latest"]
EOF
    run emit_reachable_cache_args "badrepo/config.yaml" "myowner" "22.04" "true"
    # Must fail closed (non-zero exit)
    [ "$status" -ne 0 ]
    # Must not emit any --build-arg flag (no partial emission)
    [[ "$output" != *"--build-arg"* ]]
}

# BCU-GHCR-02: ghcr_repo with semicolon → non-zero
@test "BCU-GHCR-02: emit_reachable_cache_args — ghcr_repo with semicolon → non-zero" {
    mkdir -p badrepo2
    cat > badrepo2/config.yaml <<'EOF'
base_image_cache:
  - arg: BASE_IMAGE
    source: ubuntu
    ghcr_repo: "ubuntu-base;id"
    tags: ["latest"]
EOF
    run emit_reachable_cache_args "badrepo2/config.yaml" "myowner" "22.04" "true"
    [ "$status" -ne 0 ]
    [[ "$output" != *"--build-arg"* ]]
}

# BCU-GHCR-03: malicious ghcr_repo in unreachable entry → still non-zero (no silent skip)
# Mirrors BCU-FIX2-05: validation runs regardless of the probe flag.
@test "BCU-GHCR-03: emit_reachable_cache_args — bad ghcr_repo in unreachable entry → non-zero (no silent skip)" {
    mkdir -p badrepo3
    cat > badrepo3/config.yaml <<'EOF'
base_image_cache:
  - arg: BASE_IMAGE
    source: ubuntu
    ghcr_repo: "ubuntu-base --network host"
    tags: ["latest"]
EOF
    # Flag is "false" (entry unreachable) — ghcr_repo is still validated
    run emit_reachable_cache_args "badrepo3/config.yaml" "myowner" "22.04" "false"
    [ "$status" -ne 0 ]
}

# ─── FIX 1 (RED→GREEN): standalone source guard — log_error must be defined ────
#
# BCU-STANDALONE-01: source base-cache-utils.sh in a FRESH subshell (no pre-sourcing
# of logging.sh) and trigger emit_reachable_cache_args with a malformed arg.
# RED before FIX 1: "log_error: command not found" appears on stderr.
# GREEN after FIX 1: the intended validation message appears; "command not found" absent.
@test "BCU-STANDALONE-01: standalone source — log_error defined, malformed arg emits validation message not 'command not found'" {
    # Build a config with a shell-unsafe arg identifier to trigger the log_error path
    mkdir -p standalone_test
    cat > standalone_test/config.yaml <<'EOF'
base_image_cache:
  - arg: "BAD ARG"
    source: ubuntu
    ghcr_repo: ubuntu-base
    tags: ["latest"]
EOF

    # Run in a fresh subshell that does NOT pre-source logging.sh.
    # The source guard in base-cache-utils.sh must pull in logging.sh on its own.
    local stderr_out
    stderr_out=$(bash --norc --noprofile -c "
        source \"$ORIG_DIR/helpers/variant-utils.sh\"   # needed by base-cache-utils
        source \"$ORIG_DIR/helpers/base-cache-utils.sh\"  # standalone — no logging pre-sourced
        emit_reachable_cache_args 'standalone_test/config.yaml' 'myowner' '22.04' 'true'
    " 2>&1 1>/dev/null || true)

    # Must NOT contain "command not found" — that is the bug indicator
    [[ "$stderr_out" != *"command not found"* ]]
    # Must contain the intended validation error message keywords
    [[ "$stderr_out" == *"is not a valid Docker ARG identifier"* ]]
}

# BCU-GHCR-PASS: valid ghcr_repo values (all current containers) → exit 0 + correct flag
@test "BCU-GHCR-PASS: emit_reachable_cache_args — all valid old-style ghcr_repo names → PASS" {
    local repos="ubuntu-base ruby-base php-base composer-base alpine-base rocky-base debian-base terraform-base postgres-base python-base"
    for repo in $repos; do
        mkdir -p "valrepo-${repo}"
        cat > "valrepo-${repo}/config.yaml" <<EOF
base_image_cache:
  - arg: BASE_IMAGE
    source: test
    ghcr_repo: ${repo}
    tags: ["latest"]
EOF
        run emit_reachable_cache_args "valrepo-${repo}/config.yaml" "myowner" "1.0" "true"
        [ "$status" -eq 0 ] || {
            echo "FAILED for ghcr_repo=${repo}, output: $output"
            return 1
        }
        [[ "$output" == *"--build-arg BASE_IMAGE=ghcr.io/myowner/${repo}"* ]] || {
            echo "MISSING flag for ghcr_repo=${repo}, output: $output"
            return 1
        }
    done
}

# --- sync_base_images_to_ghcr ---

@test "sync_base_images_to_ghcr: empty input returns 0 and no-op message" {
    run sync_base_images_to_ghcr '[]'
    [ "$status" -eq 0 ]
    [[ "$output" == *"No base images to sync"* ]]
}

@test "sync_base_images_to_ghcr: non-array images_json returns error" {
    run sync_base_images_to_ghcr '{"source":"library/alpine","tag":"3.18"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"sync_base_images_to_ghcr: images_json is not a JSON array"* ]]
}

@test "sync_base_images_to_ghcr: single library/X image uses explicit library/ prefix" {
    # Mock docker to capture the source_ref argument
    docker() {
        if [[ "$1" == "buildx" && "$2" == "imagetools" && "$3" == "create" ]]; then
            echo "MOCK_DOCKER_ARGS: $*"
            return 0
        fi
        return 0
    }
    export -f docker

    local input='[{"source":"library/alpine","tag":"3.18","sync_image":"ghcr.io/oorabona/library/alpine:3.18"}]'
    run sync_base_images_to_ghcr "$input"
    [ "$status" -eq 0 ]
    [[ "$output" == *"docker.io/library/alpine:3.18"* ]]
    [[ "$output" == *"ghcr.io/oorabona/library/alpine:3.18"* ]]
    [[ "$output" == *"Synced"* ]]
}

@test "sync_base_images_to_ghcr: single-segment source normalized to library/X" {
    docker() {
        if [[ "$1" == "buildx" && "$2" == "imagetools" && "$3" == "create" ]]; then
            echo "MOCK_DOCKER_ARGS: $*"
            return 0
        fi
        return 0
    }
    export -f docker

    # Source has no slash — should be auto-prefixed with library/
    local input='[{"source":"alpine","tag":"3.18","sync_image":"ghcr.io/oorabona/library/alpine:3.18"}]'
    run sync_base_images_to_ghcr "$input"
    [ "$status" -eq 0 ]
    [[ "$output" == *"docker.io/library/alpine:3.18"* ]]
}

@test "sync_base_images_to_ghcr: per-image failures exit non-zero with workflow warning" {
    # Mock docker to fail
    docker() {
        if [[ "$1" == "buildx" && "$2" == "imagetools" && "$3" == "create" ]]; then
            echo "simulated registry error" >&2
            return 1
        fi
        return 0
    }
    export -f docker

    local input='[{"source":"library/alpine","tag":"3.18","sync_image":"ghcr.io/x/library/alpine:3.18"},{"source":"library/postgres","tag":"18-alpine","sync_image":"ghcr.io/x/library/postgres:18-alpine"}]'
    run sync_base_images_to_ghcr "$input"
    # Non-zero so the GitHub Actions UI surfaces the failure; the caller's
    # job-level `continue-on-error: true` keeps dependent jobs unblocked.
    [ "$status" -eq 1 ]
    [[ "$output" == *"⚠️ Failed"* ]]
    [[ "$output" == *"0 synced"* ]]
    [[ "$output" == *"2 failed"* ]]
    # Workflow warning surfaced for each image AND for the summary
    [[ "$output" == *"::warning::sync_base_images_to_ghcr: failed to sync"* ]]
    [[ "$output" == *"::warning::sync_base_images_to_ghcr: 2 image(s) failed to sync"* ]]
}

@test "sync_base_images_to_ghcr: writes manifest records for synced and failed bases" {
    local manifest_file="$TEST_DIR/base-sync-manifest.jsonl"
    export SYNC_MANIFEST_OUT="$manifest_file"
    export SLEEP_CMD=:

    docker() {
        if [[ "$1" == "buildx" && "$2" == "imagetools" && "$3" == "create" ]]; then
            local source_ref="${6:-}"
            if [[ "$source_ref" == "docker.io/library/alpine:3.18" ]]; then
                return 0
            fi
            echo "simulated registry error" >&2
            return 1
        fi
        if [[ "$1" == "buildx" && "$2" == "imagetools" && "$3" == "inspect" ]]; then
            printf '{"digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111"}'
            return 0
        fi
        return 0
    }
    export -f docker

    local input='[{"source":"alpine","tag":"3.18","sync_image":"ghcr.io/x/library/alpine:3.18"},{"source":"postgres","tag":"18-alpine","sync_image":"ghcr.io/x/library/postgres:18-alpine"}]'
    run sync_base_images_to_ghcr "$input"
    [ "$status" -eq 1 ]
    [[ "$output" == *"1 synced"* ]]
    [[ "$output" == *"1 failed"* ]]

    [ -f "$manifest_file" ]
    [ "$(jq -s 'length' "$manifest_file")" -eq 2 ]

    local synced_digest failed_status failed_digest synced_source failed_source
    synced_source=$(jq -sr 'map(select(.source_ref == "docker.io/library/alpine:3.18"))[0].source_ref' "$manifest_file")
    synced_digest=$(jq -sr 'map(select(.source_ref == "docker.io/library/alpine:3.18"))[0].digest' "$manifest_file")
    failed_source=$(jq -sr 'map(select(.source_ref == "docker.io/library/postgres:18-alpine"))[0].source_ref' "$manifest_file")
    failed_status=$(jq -sr 'map(select(.source_ref == "docker.io/library/postgres:18-alpine"))[0].status' "$manifest_file")
    failed_digest=$(jq -sr 'map(select(.source_ref == "docker.io/library/postgres:18-alpine"))[0].digest' "$manifest_file")

    [ "$synced_source" = "docker.io/library/alpine:3.18" ]
    [ "$synced_digest" = "sha256:1111111111111111111111111111111111111111111111111111111111111111" ]
    [ "$failed_source" = "docker.io/library/postgres:18-alpine" ]
    [ "$failed_status" = "failed" ]
    [ "$failed_digest" = "" ]
    jq -se 'map(select(.status == "synced" and .sync_image == "ghcr.io/x/library/alpine:3.18" and (.synced_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")))) | length == 1' "$manifest_file" >/dev/null
}

@test "sync_base_images_to_ghcr: multiline docker stderr cannot inject workflow commands" {
    # Mock docker to return multiline stderr containing a fake workflow command
    docker() {
        if [[ "$1" == "buildx" && "$2" == "imagetools" && "$3" == "create" ]]; then
            printf 'fake error line1\n::stop-commands::xx\nline3\n' >&2
            return 1
        fi
        return 0
    }
    export -f docker

    local input='[{"source":"library/alpine","tag":"3.18","sync_image":"ghcr.io/x/library/alpine:3.18"}]'
    run sync_base_images_to_ghcr "$input"
    [ "$status" -eq 1 ]
    # The injected line must never appear at column 0 — every stderr line is
    # prefixed with "  Error: " so it's quoted text, not a workflow command.
    [[ "$output" != *$'\n::stop-commands::'* ]]
    [[ "$output" == *"  Error: ::stop-commands::xx"* ]]
}

@test "sync_base_images_to_ghcr: carriage return in docker stderr cannot inject workflow commands" {
    # CR (\\r) is also a line terminator for the GHA workflow-command parser.
    # Mock docker to embed a CR-prefixed injection attempt.
    docker() {
        if [[ "$1" == "buildx" && "$2" == "imagetools" && "$3" == "create" ]]; then
            printf 'first line\r::stop-commands::xx\r\nlast line\n' >&2
            return 1
        fi
        return 0
    }
    export -f docker

    local input='[{"source":"library/alpine","tag":"3.18","sync_image":"ghcr.io/x/library/alpine:3.18"}]'
    run sync_base_images_to_ghcr "$input"
    [ "$status" -eq 1 ]
    # The CR-injected `::stop-commands::` must not appear preceded by raw CR.
    [[ "$output" != *$'\r::stop-commands::'* ]]
    # And it must appear in prefixed form.
    [[ "$output" == *"  Error: ::stop-commands::xx"* ]]
}

@test "sync_base_images_to_ghcr: newline in image ref is refused (injection prevention)" {
    # Mock docker — should NOT be called for the malicious entry
    local docker_call_count=0
    docker() {
        if [[ "$1" == "buildx" && "$2" == "imagetools" && "$3" == "create" ]]; then
            docker_call_count=$((docker_call_count + 1))
        fi
        return 0
    }
    export -f docker

    # Embed a newline + a fake workflow command in the source field
    local malicious_source="library/alpine"$'\n'"::stop-commands::xx"
    local input
    input=$(jq -nc --arg s "$malicious_source" \
        '[{"source":$s,"tag":"3.18","sync_image":"ghcr.io/x/lib/a:3.18"}]')
    run sync_base_images_to_ghcr "$input"
    [ "$status" -eq 1 ]
    # The injected `::stop-commands::xx` line must NOT appear as a standalone
    # line at column 0 (which would be interpreted as a workflow command).
    [[ "$output" != *$'\n::stop-commands::'* ]]
    # The validation guard fires and the entry is counted as failed
    [[ "$output" == *"refusing image entry with control characters"* ]]
    [[ "$output" == *"0 synced"* ]]
    [[ "$output" == *"1 failed"* ]]
}

@test "_sync_one_with_backoff: succeeds on first attempt without retry" {
    local call_count=0
    docker() {
        if [[ "$1" == "buildx" && "$2" == "imagetools" && "$3" == "create" ]]; then
            call_count=$((call_count + 1))
            return 0
        fi
        return 0
    }
    export -f docker
    export SLEEP_CMD=:  # no-op sleep

    run _sync_one_with_backoff "docker.io/library/alpine:3.18" "ghcr.io/x/lib/a:3.18"
    [ "$status" -eq 0 ]
    # Should NOT have retried (no backoff message)
    [[ "$output" != *"backing off"* ]]
}

@test "_sync_one_with_backoff: retries on 429 then succeeds" {
    # Use a real file as a counter so the mock survives subshells (docker is
    # called inside command substitution which forks).
    local counter_file
    counter_file=$(mktemp)
    echo 0 > "$counter_file"
    export COUNTER_FILE="$counter_file"

    docker() {
        if [[ "$1" == "buildx" && "$2" == "imagetools" && "$3" == "create" ]]; then
            local n
            n=$(<"$COUNTER_FILE")
            n=$((n + 1))
            echo "$n" > "$COUNTER_FILE"
            if (( n < 3 )); then
                echo "toomanyrequests: You have reached your pull rate limit" >&2
                return 1
            fi
            return 0
        fi
        return 0
    }
    export -f docker
    export SLEEP_CMD=:

    run _sync_one_with_backoff "docker.io/library/alpine:3.18" "ghcr.io/x/lib/a:3.18"
    [ "$status" -eq 0 ]
    # Should have emitted at least one backoff message (retries 1 and 2 hit the limit)
    [[ "$output" == *"backing off 5s (retry 1/3)"* ]]
    [[ "$output" == *"backing off 10s (retry 2/3)"* ]]

    rm -f "$counter_file"
}

@test "_sync_one_with_backoff: gives up after max retries on persistent 429" {
    docker() {
        if [[ "$1" == "buildx" && "$2" == "imagetools" && "$3" == "create" ]]; then
            echo "toomanyrequests: persistent rate limit" >&2
            return 1
        fi
        return 0
    }
    export -f docker
    export SLEEP_CMD=:

    run _sync_one_with_backoff "docker.io/library/alpine:3.18" "ghcr.io/x/lib/a:3.18"
    [ "$status" -eq 1 ]
    # All three backoff messages emitted before giving up
    [[ "$output" == *"backing off 5s"* ]]
    [[ "$output" == *"backing off 10s"* ]]
    [[ "$output" == *"backing off 20s"* ]]
    # Final stderr from docker is returned on stdout (by the function's contract)
    [[ "$output" == *"toomanyrequests"* ]]
}

@test "_sync_one_with_backoff: non-429 errors fail fast without retry" {
    local call_count=0
    docker() {
        if [[ "$1" == "buildx" && "$2" == "imagetools" && "$3" == "create" ]]; then
            call_count=$((call_count + 1))
            echo "unauthorized: authentication required" >&2
            return 1
        fi
        return 0
    }
    export -f docker
    export SLEEP_CMD=:

    run _sync_one_with_backoff "docker.io/library/alpine:3.18" "ghcr.io/x/lib/a:3.18"
    [ "$status" -eq 1 ]
    # No backoff for non-429
    [[ "$output" != *"backing off"* ]]
}

@test "sync_base_images_to_ghcr: control character in source_registry param is refused" {
    docker() { return 0; }
    export -f docker
    export SLEEP_CMD=:

    local input='[{"source":"library/alpine","tag":"3.18","sync_image":"ghcr.io/x/lib/a:3.18"}]'
    local malicious_registry=$'docker.io\n::stop-commands::xx'
    run sync_base_images_to_ghcr "$input" "$malicious_registry"
    [ "$status" -eq 1 ]
    [[ "$output" == *"refusing source_registry with control characters"* ]]
    # The injected line must not appear at column 0
    [[ "$output" != *$'\n::stop-commands::'* ]]
}

@test "sync_base_images_to_ghcr: source_registry override changes the source URL" {
    docker() {
        if [[ "$1" == "buildx" && "$2" == "imagetools" && "$3" == "create" ]]; then
            echo "MOCK_DOCKER_ARGS: $*"
            return 0
        fi
        return 0
    }
    export -f docker

    local input='[{"source":"library/alpine","tag":"3.18","sync_image":"ghcr.io/x/library/alpine:3.18"}]'
    run sync_base_images_to_ghcr "$input" "127.0.0.1:5000"
    [ "$status" -eq 0 ]
    [[ "$output" == *"127.0.0.1:5000/library/alpine:3.18"* ]]
}

# --- check_image construction guard (gate r3 fix — action.yaml ${source_path#/} strip) ---

# BCU-ACTIONSTRIP-01: leading-slash source → probe_image has no double slash
# Mirrors the action.yaml inline check_image construction: check_image="ghcr.io/${owner}/${source_path#/}:${tag}"
# Without the #/ strip, source: /php would yield ghcr.io/owner//php:tag.
@test "BCU-ACTIONSTRIP-01: leading-slash source (/php) → probe_image contains no double slash" {
    mkdir -p wpstrip
    cat > wpstrip/config.yaml <<'EOF'
base_image_cache:
  - source: /php
    tags: ["8.2-fpm-alpine"]
EOF

    local containers_json='["wpstrip"]'
    local versions_json='{"wpstrip":"latest"}'

    run collect_all_cache_images "$containers_json" "$versions_json" "myowner"
    [ "$status" -eq 0 ]
    # probe_image must not contain double slash
    [[ "$output" != *'"//'* ]]
    # probe_image must be leaf-only (no leading slash, no library/ prefix)
    [[ "$output" == *'"probe_image":"ghcr.io/myowner/php:8.2-fpm-alpine"'* ]]
}

# BCU-ACTIONSTRIP-02: bash strip pattern sanity — ${source_path#/} is idempotent for non-slash sources
@test "BCU-ACTIONSTRIP-02: strip pattern \${source_path#/} is idempotent for normal (non-leading-slash) source" {
    # Direct bash expansion check: verifies the fix applied in action.yaml does not
    # mangle normal sources like "library/postgres".
    local source_path="library/postgres"
    local stripped="${source_path#/}"
    [ "$stripped" = "library/postgres" ]

    local check_image="ghcr.io/myowner/${source_path#/}:18-alpine"
    [ "$check_image" = "ghcr.io/myowner/library/postgres:18-alpine" ]
    [[ "$check_image" != *'//'* ]]
}

# BCU-ACTIONSTRIP-03: bash strip pattern — ${source_path#/} strips exactly the leading slash for /php
@test "BCU-ACTIONSTRIP-03: strip pattern \${source_path#/} produces clean path for leading-slash source /php" {
    local source_path="/php"
    local check_image="ghcr.io/myowner/${source_path#/}:8.2-fpm-alpine"
    [ "$check_image" = "ghcr.io/myowner/php:8.2-fpm-alpine" ]
    [[ "$check_image" != *'//'* ]]
}

# --- gate r4 Bug 2 regression: multi-segment leading-slash source must not double library/ ---

# BCU-MULTISEG-01: source="/library/postgres" → sync_dest_path must be "library/postgres"
# Regression lock for gate r4 Bug 2: the unconditional "library/${leaf}" prepend produced
# "library/library/postgres" when source="/library/postgres" (leaf="library/postgres").
# Fix: prepend library/ only when leaf has no slash (single-segment, like "php").
@test "BCU-MULTISEG-01: source=/library/postgres → sync_image is library/postgres NOT library/library/postgres" {
    mkdir -p pgchained
    cat > pgchained/config.yaml <<'EOF'
base_image_cache:
  - source: /library/postgres
    tags: ["18-alpine"]
EOF

    local containers_json='["pgchained"]'
    local versions_json='{"pgchained":"18-alpine"}'

    run collect_all_cache_images "$containers_json" "$versions_json" "myowner"
    [ "$status" -eq 0 ]
    # sync_image must use library/postgres (multi-segment leaf used as-is)
    [[ "$output" == *'"sync_image":"ghcr.io/myowner/library/postgres:18-alpine"'* ]]
    # Must NOT contain the doubled path
    [[ "$output" != *'"sync_image":"ghcr.io/myowner/library/library/postgres:18-alpine"'* ]]
    # probe_image must also be correct (leaf without leading slash)
    [[ "$output" == *'"probe_image":"ghcr.io/myowner/library/postgres:18-alpine"'* ]]
}

# BCU-MULTISEG-02: source="/php" (single-segment) still gets library/ prepend
# Regression guard: the multi-segment fix must NOT break the original /php → library/php behaviour.
@test "BCU-MULTISEG-02: source=/php (single-segment) still uses library/php for sync_image" {
    mkdir -p phpchained
    cat > phpchained/config.yaml <<'EOF'
base_image_cache:
  - source: /php
    tags: ["8.2-fpm-alpine"]
EOF

    local containers_json='["phpchained"]'
    local versions_json='{"phpchained":"latest"}'

    run collect_all_cache_images "$containers_json" "$versions_json" "myowner"
    [ "$status" -eq 0 ]
    # Single-segment leaf: sync_image must retain library/ prefix
    [[ "$output" == *'"sync_image":"ghcr.io/myowner/library/php:8.2-fpm-alpine"'* ]]
    # probe_image is leaf-only
    [[ "$output" == *'"probe_image":"ghcr.io/myowner/php:8.2-fpm-alpine"'* ]]
}

# --- presence gate (skip_present=true) ---

# BCU-PRESGATE-01: skip_present=true + GHCR already present → copy NOT invoked, rc 0
# Locks the fast path: when `docker manifest inspect` succeeds (image in GHCR),
# `buildx imagetools create` must never be called (no docker.io request).
@test "BCU-PRESGATE-01: skip_present=true + GHCR present → copy skipped, rc 0" {
    # Use a marker file to detect whether buildx imagetools create was ever called.
    # A shell variable cannot survive the command-substitution subshell used by
    # _sync_one_with_backoff, so we use a real tempfile (same pattern as the
    # _sync_one_with_backoff backoff tests above).
    local copy_marker
    copy_marker=$(mktemp)
    rm -f "$copy_marker"   # absent = not called; present = called
    export COPY_MARKER="$copy_marker"

    docker() {
        if [[ "$1" == "manifest" && "$2" == "inspect" ]]; then
            # Image is present in GHCR → presence probe succeeds
            return 0
        fi
        if [[ "$1" == "buildx" && "$2" == "imagetools" && "$3" == "create" ]]; then
            # Record that copy was attempted (must NOT happen when image is present)
            touch "$COPY_MARKER"
            return 0
        fi
        return 0
    }
    export -f docker
    export SLEEP_CMD=:

    local input='[{"source":"library/alpine","tag":"3.18","sync_image":"ghcr.io/x/library/alpine:3.18"}]'
    run sync_base_images_to_ghcr "$input" "docker.io" "true"
    [ "$status" -eq 0 ]
    # Output must mention the skip
    [[ "$output" == *"Already in GHCR"* ]] || [[ "$output" == *"skipping"* ]]
    # buildx imagetools create must NOT have been invoked
    [ ! -f "$COPY_MARKER" ]
    # Summary: 0 synced, 1 skipped, 0 failed
    [[ "$output" == *"0 synced"* ]]
    [[ "$output" == *"1 skipped"* ]]

    rm -f "$copy_marker"
}

# BCU-PRESGATE-02: skip_present=true + GHCR absent → copy IS invoked, rc 0
# When `docker manifest inspect` fails (image not yet in GHCR), the normal copy
# path must run — ensures the gate doesn't block the initial population.
@test "BCU-PRESGATE-02: skip_present=true + GHCR absent → copy invoked, rc 0" {
    local copy_marker
    copy_marker=$(mktemp)
    rm -f "$copy_marker"
    export COPY_MARKER="$copy_marker"

    docker() {
        if [[ "$1" == "manifest" && "$2" == "inspect" ]]; then
            # Image not yet in GHCR → presence probe fails
            return 1
        fi
        if [[ "$1" == "buildx" && "$2" == "imagetools" && "$3" == "create" ]]; then
            touch "$COPY_MARKER"
            return 0
        fi
        return 0
    }
    export -f docker
    export SLEEP_CMD=:

    local input='[{"source":"library/alpine","tag":"3.18","sync_image":"ghcr.io/x/library/alpine:3.18"}]'
    run sync_base_images_to_ghcr "$input" "docker.io" "true"
    [ "$status" -eq 0 ]
    # Copy must have been invoked
    [ -f "$COPY_MARKER" ]
    # Summary: 1 synced, 0 skipped
    [[ "$output" == *"1 synced"* ]]
    [[ "$output" == *"0 skipped"* ]]

    rm -f "$copy_marker"
}

# BCU-PRESGATE-03: skip_present=false (default, daily sync) → copy invoked even when GHCR present
# Regression lock: blind-copy behavior must not be broken by the presence gate.
# The daily upstream-monitor sync calls sync_base_images_to_ghcr without skip_present
# (defaults to "false"), so it must always copy regardless of GHCR state.
@test "BCU-PRESGATE-03: skip_present=false (default) → copy invoked even when GHCR present (blind refresh)" {
    local copy_marker
    copy_marker=$(mktemp)
    rm -f "$copy_marker"
    export COPY_MARKER="$copy_marker"

    docker() {
        if [[ "$1" == "manifest" && "$2" == "inspect" ]]; then
            # Image IS present in GHCR — with skip_present=false this must be ignored
            return 0
        fi
        if [[ "$1" == "buildx" && "$2" == "imagetools" && "$3" == "create" ]]; then
            touch "$COPY_MARKER"
            return 0
        fi
        return 0
    }
    export -f docker
    export SLEEP_CMD=:

    local input='[{"source":"library/alpine","tag":"3.18","sync_image":"ghcr.io/x/library/alpine:3.18"}]'
    # Call without 3rd arg — mirrors the daily upstream-monitor invocation
    run sync_base_images_to_ghcr "$input"
    [ "$status" -eq 0 ]
    # Copy must have been invoked (blind refresh ignores presence)
    [ -f "$COPY_MARKER" ]
    # Summary: 1 synced, 0 skipped
    [[ "$output" == *"1 synced"* ]]
    [[ "$output" == *"0 skipped"* ]]

    rm -f "$copy_marker"
}
