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
