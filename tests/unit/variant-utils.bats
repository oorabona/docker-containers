#!/usr/bin/env bats

# Unit tests for helpers/variant-utils.sh
# Tests variant resolution, tag construction, and version mapping

setup() {
    TEST_DIR=$(mktemp -d)
    ORIG_DIR="$PWD"
    cd "$TEST_DIR" || exit 1

    # Mock yq — tests provide specific overrides as needed
    mkdir -p bin
    cat > bin/yq <<'MOCK'
#!/bin/bash
echo ""
MOCK
    chmod +x bin/yq
    export PATH="$TEST_DIR/bin:$PATH"

    source "$ORIG_DIR/helpers/variant-utils.sh"
}

teardown() {
    cd "$ORIG_DIR" || true
    rm -rf "$TEST_DIR"
}

# --- Helper to create a postgres-like variants.yaml ---

create_postgres_variants() {
    local dir="${1:-.}"
    mkdir -p "$dir"
    cat > "$dir/variants.yaml" <<'EOF'
build:
  base_suffix: "-alpine"
  flavor_arg: "FLAVOR"
  requires_extensions: true

versions:
  - tag: "18"
    variants:
      - name: base
        suffix: ""
        flavor: base
        default: true
      - name: vector
        suffix: "-vector"
        flavor: vector
      - name: analytics
        suffix: "-analytics"
        flavor: analytics
  - tag: "17"
    variants:
      - name: base
        suffix: ""
        flavor: base
        default: true
      - name: vector
        suffix: "-vector"
        flavor: vector
      - name: distributed
        suffix: "-distributed"
        flavor: distributed
EOF
}

create_terraform_variants() {
    local dir="${1:-.}"
    mkdir -p "$dir"
    cat > "$dir/variants.yaml" <<'EOF'
build:
  base_suffix: ""
  flavor_arg: "FLAVOR"

versions:
  - tag: "latest"
    variants:
      - name: base
        suffix: ""
        flavor: base
        default: true
      - name: aws
        suffix: "-aws"
        flavor: aws
      - name: full
        suffix: "-full"
        flavor: full
EOF
}

# --- has_variants ---

@test "has_variants: true when variants.yaml exists" {
    mkdir -p mycontainer
    touch mycontainer/variants.yaml
    run has_variants "mycontainer"
    [ "$status" -eq 0 ]
}

@test "has_variants: false when no variants.yaml" {
    mkdir -p mycontainer
    run has_variants "mycontainer"
    [ "$status" -eq 1 ]
}

# --- list_versions (requires real yq) ---

@test "list_versions: returns version tags from variants.yaml" {
    # Skip if real yq is not available
    if ! command -v yq &>/dev/null && [[ ! -f "$ORIG_DIR/bin/yq" ]]; then
        skip "yq not available"
    fi
    # Use real yq
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_postgres_variants "pg"
    run list_versions "pg"
    [ "$status" -eq 0 ]
    [[ "$output" == *"18"* ]]
    [[ "$output" == *"17"* ]]
}

# --- resolve_major_version (requires real yq) ---

@test "resolve_major_version: exact match 18 → 18" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_postgres_variants "pg"
    run resolve_major_version "pg" "18"
    [ "$status" -eq 0 ]
    [ "$output" = "18" ]
}

@test "resolve_major_version: prefix match 18.1-alpine → 18" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_postgres_variants "pg"
    run resolve_major_version "pg" "18.1-alpine"
    [ "$status" -eq 0 ]
    [ "$output" = "18" ]
}

@test "resolve_major_version: prefix match 17.2-alpine → 17" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_postgres_variants "pg"
    run resolve_major_version "pg" "17.2-alpine"
    [ "$status" -eq 0 ]
    [ "$output" = "17" ]
}

@test "resolve_major_version: no match returns original" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_postgres_variants "pg"
    run resolve_major_version "pg" "99.0-alpine"
    [ "$status" -eq 0 ]
    [ "$output" = "99.0-alpine" ]
}

# --- variant_image_tag (requires real yq) ---

@test "variant_image_tag: base variant → 18-alpine (no suffix)" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_postgres_variants "pg"
    run variant_image_tag "18" "base" "pg"
    [ "$status" -eq 0 ]
    [ "$output" = "18-alpine" ]
}

@test "variant_image_tag: vector variant → 18-alpine-vector" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_postgres_variants "pg"
    run variant_image_tag "18" "vector" "pg"
    [ "$status" -eq 0 ]
    [ "$output" = "18-alpine-vector" ]
}

@test "variant_image_tag: analytics variant → 18-alpine-analytics" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_postgres_variants "pg"
    run variant_image_tag "18" "analytics" "pg"
    [ "$status" -eq 0 ]
    [ "$output" = "18-alpine-analytics" ]
}

@test "variant_image_tag: terraform base → latest (no base_suffix)" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_terraform_variants "tf"
    run variant_image_tag "latest" "base" "tf"
    [ "$status" -eq 0 ]
    [ "$output" = "latest" ]
}

@test "variant_image_tag: terraform aws → latest-aws" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_terraform_variants "tf"
    run variant_image_tag "latest" "aws" "tf"
    [ "$status" -eq 0 ]
    [ "$output" = "latest-aws" ]
}

# --- default_variant (requires real yq) ---

@test "default_variant: returns base for postgres 18" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_postgres_variants "pg"
    run default_variant "pg" "18"
    [ "$status" -eq 0 ]
    [ "$output" = "base" ]
}

# --- list_variants (requires real yq) ---

@test "list_variants: postgres 18 has base, vector, analytics" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_postgres_variants "pg"
    run list_variants "pg" "18"
    [ "$status" -eq 0 ]
    [[ "$output" == *"base"* ]]
    [[ "$output" == *"vector"* ]]
    [[ "$output" == *"analytics"* ]]
}

@test "list_variants: postgres 17 has distributed but not analytics" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_postgres_variants "pg"
    run list_variants "pg" "17"
    [ "$status" -eq 0 ]
    [[ "$output" == *"distributed"* ]]
    [[ "$output" != *"analytics"* ]]
}

# --- base_suffix (requires real yq) ---

@test "base_suffix: postgres returns -alpine" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_postgres_variants "pg"
    run base_suffix "pg"
    [ "$status" -eq 0 ]
    [ "$output" = "-alpine" ]
}

@test "base_suffix: terraform returns empty" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_terraform_variants "tf"
    run base_suffix "tf"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

# --- version_count (requires real yq) ---

@test "version_count: postgres has 2 versions" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_postgres_variants "pg"
    run version_count "pg"
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]
}

@test "version_count: container without variants.yaml returns 0" {
    mkdir -p novar
    run version_count "novar"
    [ "$output" = "0" ]
}

# --- list_build_matrix with real_version ---

@test "list_build_matrix: with real_version substitutes latest" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_terraform_variants "tf"
    run list_build_matrix "tf" "1.14.5"
    [ "$status" -eq 0 ]
    # All entries should have version=1.14.5, not "latest"
    local count
    count=$(echo "$output" | jq '[.[] | select(.version == "1.14.5")] | length')
    [ "$count" -gt 0 ]
    local latest_count
    latest_count=$(echo "$output" | jq '[.[] | select(.version == "latest")] | length')
    [ "$latest_count" -eq 0 ]
}

@test "list_build_matrix: without real_version keeps latest" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_terraform_variants "tf"
    run list_build_matrix "tf"
    [ "$status" -eq 0 ]
    local latest_count
    latest_count=$(echo "$output" | jq '[.[] | select(.version == "latest")] | length')
    [ "$latest_count" -gt 0 ]
}

@test "list_build_matrix: postgres ignores real_version (tags are not latest)" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_postgres_variants "pg"
    run list_build_matrix "pg" "18.4-alpine"
    [ "$status" -eq 0 ]
    # Postgres tags are "18" and "17", not "latest" — real_version should NOT change them
    local v18_count
    v18_count=$(echo "$output" | jq '[.[] | select(.version == "18")] | length')
    [ "$v18_count" -gt 0 ]
    local v17_count
    v17_count=$(echo "$output" | jq '[.[] | select(.version == "17")] | length')
    [ "$v17_count" -gt 0 ]
}

@test "list_build_matrix: includes priority and is_default fields" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_terraform_variants "tf"
    run list_build_matrix "tf" "1.14.5"
    [ "$status" -eq 0 ]
    # base variant: is_default=true, priority=0
    local base_default
    base_default=$(echo "$output" | jq '[.[] | select(.variant == "base")] | .[0].is_default')
    [ "$base_default" = "true" ]
    local base_priority
    base_priority=$(echo "$output" | jq '[.[] | select(.variant == "base")] | .[0].priority')
    [ "$base_priority" = "0" ]
    # full variant: priority=2
    local full_priority
    full_priority=$(echo "$output" | jq '[.[] | select(.variant == "full")] | .[0].priority')
    [ "$full_priority" = "2" ]
    # aws variant: priority=1
    local aws_priority
    aws_priority=$(echo "$output" | jq '[.[] | select(.variant == "aws")] | .[0].priority')
    [ "$aws_priority" = "1" ]
}

@test "list_build_matrix: terraform real_version produces correct tags" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_terraform_variants "tf"
    run list_build_matrix "tf" "1.14.5"
    [ "$status" -eq 0 ]
    # base has suffix "" and base_suffix="" → tag = "1.14.5"
    local base_tag
    base_tag=$(echo "$output" | jq -r '[.[] | select(.variant == "base")] | .[0].tag')
    [ "$base_tag" = "1.14.5" ]
    # aws has suffix "-aws" → tag = "1.14.5-aws"
    local aws_tag
    aws_tag=$(echo "$output" | jq -r '[.[] | select(.variant == "aws")] | .[0].tag')
    [ "$aws_tag" = "1.14.5-aws" ]
    # full has suffix "-full" → tag = "1.14.5-full"
    local full_tag
    full_tag=$(echo "$output" | jq -r '[.[] | select(.variant == "full")] | .[0].tag')
    [ "$full_tag" = "1.14.5-full" ]
}

# --- list_container_builds ---

@test "list_container_builds: includes container name" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_terraform_variants "tf"
    run list_container_builds "tf" "1.14.5"
    [ "$status" -eq 0 ]
    local all_have_container
    all_have_container=$(echo "$output" | jq 'all(.container == "tf")')
    [ "$all_have_container" = "true" ]
}

@test "list_container_builds: non-variant returns single entry" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    # Create a container with no variants.yaml
    mkdir -p "novar"
    run list_container_builds "novar" "2.0.0"
    [ "$status" -eq 0 ]
    local count
    count=$(echo "$output" | jq 'length')
    [ "$count" -eq 1 ]
    local entry
    entry=$(echo "$output" | jq '.[0]')
    [ "$(echo "$entry" | jq -r '.container')" = "novar" ]
    [ "$(echo "$entry" | jq -r '.version')" = "2.0.0" ]
    [ "$(echo "$entry" | jq -r '.variant')" = "" ]
    [ "$(echo "$entry" | jq -r '.tag')" = "2.0.0" ]
    [ "$(echo "$entry" | jq '.is_default')" = "true" ]
}

@test "list_container_builds: sorted by priority (base first, full last)" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_terraform_variants "tf"
    run list_container_builds "tf" "1.14.5"
    [ "$status" -eq 0 ]
    # First entry should have priority 0 (base)
    local first_priority
    first_priority=$(echo "$output" | jq '.[0].priority')
    [ "$first_priority" = "0" ]
    # Last entry should have priority 2 (full)
    local last_priority
    last_priority=$(echo "$output" | jq '.[-1].priority')
    [ "$last_priority" = "2" ]
}

# --- is_latest_version ---

@test "list_build_matrix: postgres is_latest_version only for first version (18)" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_postgres_variants "pg"
    run list_build_matrix "pg"
    [ "$status" -eq 0 ]
    # PG 18 (first in YAML) should have is_latest_version=true
    local v18_latest
    v18_latest=$(echo "$output" | jq '[.[] | select(.version == "18") | .is_latest_version] | all')
    [ "$v18_latest" = "true" ]
    # PG 17 should have is_latest_version=false
    local v17_latest
    v17_latest=$(echo "$output" | jq '[.[] | select(.version == "17") | .is_latest_version] | any')
    [ "$v17_latest" = "false" ]
}

@test "list_build_matrix: terraform is_latest_version always true (single version)" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_terraform_variants "tf"
    run list_build_matrix "tf" "1.14.5"
    [ "$status" -eq 0 ]
    local all_latest
    all_latest=$(echo "$output" | jq 'all(.is_latest_version == true)')
    [ "$all_latest" = "true" ]
}

@test "list_container_builds: non-variant has is_latest_version true" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    mkdir -p "novar2"
    run list_container_builds "novar2" "3.0.0"
    [ "$status" -eq 0 ]
    local is_latest
    is_latest=$(echo "$output" | jq '.[0].is_latest_version')
    [ "$is_latest" = "true" ]
}
