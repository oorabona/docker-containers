#!/usr/bin/env bats

# Unit tests for helpers/base-cache-utils.sh
# Covers: resolve_cache_check_tag — tag resolution for GHCR accessibility checks
#         get_cache_build_args    — --build-arg emission for old and new entry styles
#         collect_all_cache_images / _collect_entry_tags — image dest path for old and new styles

setup() {
    TEST_DIR=$(mktemp -d)
    ORIG_DIR="$PWD"
    cd "$TEST_DIR" || exit 1

    source "$ORIG_DIR/helpers/logging.sh"
    source "$ORIG_DIR/helpers/variant-utils.sh"
    source "$ORIG_DIR/helpers/base-cache-utils.sh"
}

teardown() {
    cd "$ORIG_DIR" || true
    rm -rf "$TEST_DIR"
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

# --- get_cache_build_args: old-style (regression lock) ---

# BCU-07: OLD-style entry (has ghcr_repo) emits --build-arg ARG=ghcr.io/<owner>/<ghcr_repo>
# Byte-identical to pre-dual-schema behaviour — mutation guard
@test "BCU-07: OLD-style entry emits --build-arg with ghcr_repo path (regression lock)" {
    mkdir -p mycontainer
    cat > mycontainer/config.yaml <<'EOF'
base_image_cache:
  - arg: BASE_IMAGE
    source: ubuntu
    ghcr_repo: ubuntu-base
    tags: ["latest"]
EOF

    run get_cache_build_args "mycontainer" "myowner" "22.04"
    [ "$status" -eq 0 ]
    [ "$output" = " --build-arg BASE_IMAGE=ghcr.io/myowner/ubuntu-base" ]
}

# --- get_cache_build_args: new-style ---

# BCU-08: NEW-style entry (no ghcr_repo) emits REMOTE_CR=ghcr.io/<owner>
@test "BCU-08: NEW-style entry (no ghcr_repo) emits --build-arg REMOTE_CR=ghcr.io/<owner>" {
    mkdir -p pgcontainer
    cat > pgcontainer/config.yaml <<'EOF'
base_image_cache:
  - source: library/postgres
    tags_from_versions: true
EOF

    run get_cache_build_args "pgcontainer" "myowner" "18-alpine"
    [ "$status" -eq 0 ]
    # Must contain REMOTE_CR pointing to registry root (no ghcr_repo segment)
    [[ "$output" == *"--build-arg REMOTE_CR=ghcr.io/myowner"* ]]
    # Must NOT contain a per-arg flag from arg: field (new-style has no arg:)
    [[ "$output" != *"--build-arg BASE_IMAGE"* ]]
}

# BCU-09: NEW-style with multiple entries — REMOTE_CR emitted exactly ONCE (de-duplicated)
@test "BCU-09: multiple NEW-style entries emit REMOTE_CR exactly once" {
    mkdir -p multicontainer
    cat > multicontainer/config.yaml <<'EOF'
base_image_cache:
  - source: library/postgres
    tags_from_versions: true
  - source: library/alpine
    tags: ["3.21"]
EOF

    run get_cache_build_args "multicontainer" "myowner" "18-alpine"
    [ "$status" -eq 0 ]
    # Count occurrences of REMOTE_CR in output
    count=$(echo "$output" | grep -o "REMOTE_CR" | wc -l)
    [ "$count" -eq 1 ]
}

# BCU-10: MIXED config — one old-style + one new-style
# Old emits its per-arg flag; new emits REMOTE_CR; both present in output
@test "BCU-10: MIXED old+new entries — old emits per-arg flag, new emits REMOTE_CR" {
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

    run get_cache_build_args "mixcontainer" "myowner" "22.04"
    [ "$status" -eq 0 ]
    # Old-style flag present
    [[ "$output" == *"--build-arg BASE_IMAGE=ghcr.io/myowner/ubuntu-base"* ]]
    # New-style REMOTE_CR present
    [[ "$output" == *"--build-arg REMOTE_CR=ghcr.io/myowner"* ]]
    # REMOTE_CR emitted exactly once
    count=$(echo "$output" | grep -o "REMOTE_CR" | wc -l)
    [ "$count" -eq 1 ]
}

# --- collect_all_cache_images / _collect_entry_tags: new-style dest path ---

# BCU-11: NEW-style entry → ghcr_image dest preserves source path (library/postgres)
# ghcr_image must be ghcr.io/<owner>/library/postgres:<tag> — NOT ghcr.io/<owner>/postgres:<tag>
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
    # ghcr_image must contain the two-segment path library/postgres (NOT just postgres)
    [[ "$output" == *"ghcr.io/myowner/library/postgres:"* ]]
    # Distinctness assertion: the path portion after owner must contain a '/'
    # i.e. library/postgres not just postgres
    [[ "$output" != *"ghcr.io/myowner/postgres:"* ]]
}

# BCU-12: OLD-style entry → ghcr_image dest uses ghcr_repo (regression lock)
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

# BCU-13: MIXED collect_all_cache_images — both old and new dests correct
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

# --- F-001 discriminator robustness: empty-string and explicit-nil ghcr_repo ---

# BCU-14: entry with ghcr_repo: "" (empty string) → routed as NEW style
# Must emit REMOTE_CR, NOT --build-arg null=... or --build-arg =...
@test "BCU-14: ghcr_repo empty string is routed to NEW style (emits REMOTE_CR, not 'null')" {
    mkdir -p emptyrepo
    cat > emptyrepo/config.yaml <<'EOF'
base_image_cache:
  - source: library/postgres
    ghcr_repo: ""
    tags_from_versions: true
EOF

    run get_cache_build_args "emptyrepo" "myowner" "18-alpine"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--build-arg REMOTE_CR=ghcr.io/myowner"* ]]
    [[ "$output" != *"--build-arg null="* ]]
    [[ "$output" != *"--build-arg ="* ]]
}

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
# Verifies full-reachable old-style behaviour is identical to get_cache_build_args output.
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

# BCU-15: entry with explicit ghcr_repo: (nil in YAML) → routed as NEW style
@test "BCU-15: explicit ghcr_repo nil is routed to NEW style (emits REMOTE_CR, not 'null')" {
    mkdir -p nilrepo
    cat > nilrepo/config.yaml <<'EOF'
base_image_cache:
  - source: library/postgres
    ghcr_repo:
    tags_from_versions: true
EOF

    run get_cache_build_args "nilrepo" "myowner" "18-alpine"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--build-arg REMOTE_CR=ghcr.io/myowner"* ]]
    [[ "$output" != *"--build-arg null="* ]]
    [[ "$output" != *"--build-arg ="* ]]
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
