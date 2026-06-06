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
  version_retention: 3

versions:
  - tag: "1.14.6-alpine"
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

@test "variant_image_tag: terraform base → 1.14.6-alpine (no base_suffix)" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_terraform_variants "tf"
    run variant_image_tag "1.14.6-alpine" "base" "tf"
    [ "$status" -eq 0 ]
    [ "$output" = "1.14.6-alpine" ]
}

@test "variant_image_tag: terraform aws → 1.14.6-alpine-aws" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_terraform_variants "tf"
    run variant_image_tag "1.14.6-alpine" "aws" "tf"
    [ "$status" -eq 0 ]
    [ "$output" = "1.14.6-alpine-aws" ]
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

@test "list_build_matrix: terraform uses version tag directly" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_terraform_variants "tf"
    run list_build_matrix "tf" "1.14.6-alpine"
    [ "$status" -eq 0 ]
    # All entries should have version=1.14.6-alpine (the tag from variants.yaml)
    local count
    count=$(echo "$output" | jq '[.[] | select(.version == "1.14.6-alpine")] | length')
    [ "$count" -gt 0 ]
}

@test "list_build_matrix: without real_version keeps yaml tag" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_terraform_variants "tf"
    run list_build_matrix "tf"
    [ "$status" -eq 0 ]
    local tag_count
    tag_count=$(echo "$output" | jq '[.[] | select(.version == "1.14.6-alpine")] | length')
    [ "$tag_count" -gt 0 ]
}

@test "list_build_matrix: postgres ignores real_version (tags are not latest)" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_postgres_variants "pg"
    run --separate-stderr list_build_matrix "pg" "18.4-alpine" "true"
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
    run list_build_matrix "tf" "1.14.6-alpine"
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

@test "list_build_matrix: terraform produces correct tags from version" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_terraform_variants "tf"
    run list_build_matrix "tf" "1.14.6-alpine"
    [ "$status" -eq 0 ]
    # base has suffix "" and base_suffix="" → tag = "1.14.6-alpine"
    local base_tag
    base_tag=$(echo "$output" | jq -r '[.[] | select(.variant == "base")] | .[0].tag')
    [ "$base_tag" = "1.14.6-alpine" ]
    # aws has suffix "-aws" → tag = "1.14.6-alpine-aws"
    local aws_tag
    aws_tag=$(echo "$output" | jq -r '[.[] | select(.variant == "aws")] | .[0].tag')
    [ "$aws_tag" = "1.14.6-alpine-aws" ]
    # full has suffix "-full" → tag = "1.14.6-alpine-full"
    local full_tag
    full_tag=$(echo "$output" | jq -r '[.[] | select(.variant == "full")] | .[0].tag')
    [ "$full_tag" = "1.14.6-alpine-full" ]
}

# --- list_container_builds ---

@test "list_container_builds: includes container name" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_terraform_variants "tf"
    run list_container_builds "tf" "1.14.6-alpine"
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
    run list_container_builds "tf" "1.14.6-alpine"
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
    run --separate-stderr list_build_matrix "pg"
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
    run list_build_matrix "tf" "1.14.6-alpine"
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

# --- version_retention ---

@test "version_retention: terraform returns 3" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_terraform_variants "tf"
    run version_retention "tf"
    [ "$status" -eq 0 ]
    [ "$output" = "3" ]
}

@test "version_retention: postgres returns 0 (no version_retention)" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_postgres_variants "pg"
    run version_retention "pg"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "version_retention: no variants.yaml returns 0" {
    mkdir -p "novar"
    run version_retention "novar"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

# --- versions-only build path (no variants) ---

create_simple_container_variants() {
    local dir="${1:-.}"
    mkdir -p "$dir"
    cat > "$dir/variants.yaml" <<'EOF'
build:
  version_retention: 3

versions:
  - tag: "2.0.0"
  - tag: "1.9.0"
EOF
}

@test "list_build_matrix: versions-only produces entries without variants" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_simple_container_variants "simple"
    run --separate-stderr list_build_matrix "simple" "2.0.0" "true"
    [ "$status" -eq 0 ]
    local count
    count=$(echo "$output" | jq 'length')
    [ "$count" -eq 2 ]
    # First entry (version 2.0.0) should be is_latest_version=true
    local first_version
    first_version=$(echo "$output" | jq -r '.[0].version')
    [ "$first_version" = "2.0.0" ]
    local first_latest
    first_latest=$(echo "$output" | jq '.[0].is_latest_version')
    [ "$first_latest" = "true" ]
    # Variant should be empty
    local first_variant
    first_variant=$(echo "$output" | jq -r '.[0].variant')
    [ "$first_variant" = "" ]
    # Second entry should be is_latest_version=false
    local second_latest
    second_latest=$(echo "$output" | jq '.[1].is_latest_version')
    [ "$second_latest" = "false" ]
}

@test "list_container_builds: versions-only produces sorted entries" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_simple_container_variants "simple"
    run --separate-stderr list_container_builds "simple" "2.0.0" "true"
    [ "$status" -eq 0 ]
    local count
    count=$(echo "$output" | jq 'length')
    [ "$count" -eq 2 ]
    local all_have_container
    all_have_container=$(echo "$output" | jq 'all(.container == "simple")')
    [ "$all_have_container" = "true" ]
}

# --- full_version direct match ---

@test "list_build_matrix: full_version exact match for real version tags" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_terraform_variants "tf"
    run list_build_matrix "tf" "1.14.6-alpine"
    [ "$status" -eq 0 ]
    # full_version should match the real_version since tag == real_version
    local full_version
    full_version=$(echo "$output" | jq -r '.[0].full_version')
    [ "$full_version" = "1.14.6-alpine" ]
}

# --- always_all_versions ---

# Helper: multi-version variants.yaml with 3 versions (for filter tests)
create_three_version_variants() {
    local dir="${1:-.}"
    mkdir -p "$dir"
    cat > "$dir/variants.yaml" <<'EOF'
build:
  base_suffix: ""
  version_retention: 3

versions:
  - tag: "3.0.0"
    variants:
      - name: base
        suffix: ""
        flavor: base
        default: true
  - tag: "2.9.0"
    variants:
      - name: base
        suffix: ""
        flavor: base
        default: true
  - tag: "2.8.0"
    variants:
      - name: base
        suffix: ""
        flavor: base
        default: true
EOF
}

@test "always_all_versions: returns false when build key missing" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    mkdir -p "nokey"
    cat > "nokey/variants.yaml" <<'EOF'
versions:
  - tag: "1.0.0"
EOF
    run always_all_versions "nokey"
    [ "$status" -eq 0 ]
    [ "$output" = "false" ]
}

@test "always_all_versions: returns false when always_all_versions key missing from build block" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    mkdir -p "nobuildkey"
    cat > "nobuildkey/variants.yaml" <<'EOF'
build:
  version_retention: 3

versions:
  - tag: "1.0.0"
EOF
    run always_all_versions "nobuildkey"
    [ "$status" -eq 0 ]
    [ "$output" = "false" ]
}

@test "always_all_versions: returns true when explicitly set to true" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    mkdir -p "allver"
    cat > "allver/variants.yaml" <<'EOF'
build:
  always_all_versions: true

versions:
  - tag: "1.0.0"
EOF
    run always_all_versions "allver"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "always_all_versions: returns false when variants.yaml missing" {
    mkdir -p "missingdir"
    run always_all_versions "missingdir"
    [ "$status" -eq 0 ]
    [ "$output" = "false" ]
}

# --- list_build_matrix filtering ---

@test "list_build_matrix: default (no 3rd arg) emits only is_latest_version=true entries" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_three_version_variants "threevers"
    # Use --separate-stderr so the ::notice:: stderr line doesn't pollute $output
    run --separate-stderr list_build_matrix "threevers"
    [ "$status" -eq 0 ]
    local count
    count=$(echo "$output" | jq 'length')
    [ "$count" -eq 1 ]
    local all_latest
    all_latest=$(echo "$output" | jq 'all(.is_latest_version == true)')
    [ "$all_latest" = "true" ]
}

@test "list_build_matrix: include_all_retained=true emits all versions" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_three_version_variants "threevers"
    run list_build_matrix "threevers" "" "true"
    [ "$status" -eq 0 ]
    local count
    count=$(echo "$output" | jq 'length')
    [ "$count" -eq 3 ]
}

@test "list_build_matrix: always_all_versions=true in yaml overrides include_all_retained=false" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    mkdir -p "alwaysall"
    cat > "alwaysall/variants.yaml" <<'EOF'
build:
  always_all_versions: true
  version_retention: 3

versions:
  - tag: "3.0.0"
    variants:
      - name: base
        suffix: ""
        flavor: base
        default: true
  - tag: "2.9.0"
    variants:
      - name: base
        suffix: ""
        flavor: base
        default: true
  - tag: "2.8.0"
    variants:
      - name: base
        suffix: ""
        flavor: base
        default: true
EOF
    # Call with include_all_retained=false — always_all_versions=true in yaml must win
    run list_build_matrix "alwaysall" "" "false"
    [ "$status" -eq 0 ]
    local count
    count=$(echo "$output" | jq 'length')
    [ "$count" -eq 3 ]
}

@test "list_build_matrix: include_all_retained string 'false' emits filtered output" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_three_version_variants "threevers"
    # Explicit string "false" must NOT be treated as truthy
    # Use --separate-stderr so the ::notice:: stderr line doesn't pollute $output
    run --separate-stderr list_build_matrix "threevers" "" "false"
    [ "$status" -eq 0 ]
    local count
    count=$(echo "$output" | jq 'length')
    [ "$count" -eq 1 ]
    local all_latest
    all_latest=$(echo "$output" | jq 'all(.is_latest_version == true)')
    [ "$all_latest" = "true" ]
}

@test "list_build_matrix: single-version container emits 1 entry with is_latest_version=true" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    mkdir -p "singlever"
    cat > "singlever/variants.yaml" <<'EOF'
build:
  base_suffix: ""

versions:
  - tag: "1.0.0"
    variants:
      - name: base
        suffix: ""
        flavor: base
        default: true
EOF
    run list_build_matrix "singlever"
    [ "$status" -eq 0 ]
    local count
    count=$(echo "$output" | jq 'length')
    [ "$count" -eq 1 ]
    local is_latest
    is_latest=$(echo "$output" | jq '.[0].is_latest_version')
    [ "$is_latest" = "true" ]
}

@test "list_build_matrix: emits ::notice:: to stderr when versions are skipped" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    create_three_version_variants "threevers"
    # bats `run` captures stdout in $output; stderr goes to fd 3 (bats captures it in $stderr with run --)
    # Use process substitution to capture stderr separately
    local stderr_out
    stderr_out=$(list_build_matrix "threevers" "" "false" 2>&1 >/dev/null)
    [[ "$stderr_out" == *"::notice::Container threevers: latest-only (skipped retained versions:"* ]]
}

# --- compute_expand_retained_map fallback_all (coverage checkpoint fail-safe, #595) ---

setup_fallback_test() {
    # Shared setup for fallback tests: temp changed_files with no content
    printf '' > "${TEST_DIR}/changed.txt"
}

@test "compute_expand_retained_map: fallback_all=true forces all containers to true" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    setup_fallback_test
    containers='["openresty","terraform","postgres"]'

    # fallback_all=true — every container must expand, regardless of event/diff
    run compute_expand_retained_map "push" "false" "${TEST_DIR}/changed.txt" "$containers" "true"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.openresty')" = "true" ]
    [ "$(echo "$output" | jq -r '.terraform')" = "true" ]
    [ "$(echo "$output" | jq -r '.postgres')" = "true" ]
}

@test "compute_expand_retained_map: fallback_all=true overrides per-container diff signal" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    # changed_files contains ONLY openresty — without fallback, terraform/postgres stay false
    printf 'openresty/Dockerfile\n' > "${TEST_DIR}/changed.txt"
    containers='["openresty","terraform","postgres"]'

    run compute_expand_retained_map "push" "false" "${TEST_DIR}/changed.txt" "$containers" "true"
    [ "$status" -eq 0 ]
    # fallback_all wins even for containers not in changed_files
    [ "$(echo "$output" | jq -r '.openresty')" = "true" ]
    [ "$(echo "$output" | jq -r '.terraform')" = "true" ]
    [ "$(echo "$output" | jq -r '.postgres')" = "true" ]
}

@test "compute_expand_retained_map: fallback_all=false preserves normal per-container logic" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    # Only openresty changed; push event; fallback_all=false (normal path)
    printf 'openresty/Dockerfile\n' > "${TEST_DIR}/changed.txt"
    containers='["openresty","terraform"]'

    run compute_expand_retained_map "push" "false" "${TEST_DIR}/changed.txt" "$containers" "false"
    [ "$status" -eq 0 ]
    # openresty: changed → true; terraform: not changed → false
    [ "$(echo "$output" | jq -r '.openresty')" = "true" ]
    [ "$(echo "$output" | jq -r '.terraform')" = "false" ]
}

@test "compute_expand_retained_map: fallback_all omitted (backward compat) — normal logic applies" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    printf 'openresty/Dockerfile\n' > "${TEST_DIR}/changed.txt"
    containers='["openresty","terraform"]'

    # 4-arg call (no fallback_all) — must behave as fallback_all=false
    run compute_expand_retained_map "push" "false" "${TEST_DIR}/changed.txt" "$containers"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.openresty')" = "true" ]
    [ "$(echo "$output" | jq -r '.terraform')" = "false" ]
}

@test "compute_expand_retained_map: fallback_all=true with single container" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    setup_fallback_test
    containers='["ansible"]'

    run compute_expand_retained_map "push" "false" "${TEST_DIR}/changed.txt" "$containers" "true"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.ansible')" = "true" ]
}

# --- Finding 1: make fan-out shares the full-rebuild signal with coverage-checkpoint fail-safe ---
# The make root-file fan-out sets coverage_fallback=true (same signal as the fail-safe),
# which is passed as fallback_all=true to compute_expand_retained_map.
# This test verifies that the shared signal forces all containers to expand retained versions,
# even when changed_files is empty (which is what the make fan-out does — it clears
# changed_files after queuing all containers).

@test "compute_expand_retained_map: make-fanout full-rebuild signal (fallback_all=true, empty diff) forces all containers to expand retained" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    # Simulate the make fan-out state: changed_files is empty (cleared after queuing all),
    # but coverage_fallback=true (new signal added to make fan-out).
    printf '' > "${TEST_DIR}/changed.txt"
    containers='["postgres","terraform","openresty","ansible"]'

    # fallback_all=true mirrors what the make fan-out now sets.
    run compute_expand_retained_map "push" "false" "${TEST_DIR}/changed.txt" "$containers" "true"
    [ "$status" -eq 0 ]
    # Every container must expand retained versions — NOT just latest.
    [ "$(echo "$output" | jq -r '.postgres')" = "true" ]
    [ "$(echo "$output" | jq -r '.terraform')" = "true" ]
    [ "$(echo "$output" | jq -r '.openresty')" = "true" ]
    [ "$(echo "$output" | jq -r '.ansible')" = "true" ]
}

@test "compute_expand_retained_map: WITHOUT full-rebuild signal, empty diff produces latest-only for push event" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    # Contrast test: same setup but fallback_all=false (old behaviour before fix).
    # With an empty diff and a push event, all containers should be latest-only.
    printf '' > "${TEST_DIR}/changed.txt"
    containers='["terraform","openresty"]'

    run compute_expand_retained_map "push" "false" "${TEST_DIR}/changed.txt" "$containers" "false"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.terraform')" = "false" ]
    [ "$(echo "$output" | jq -r '.openresty')" = "false" ]
}

# --- Finding 2: forged/unverified checkpoint tag → fail-safe build-all with retained expansion ---
# When the checkpoint tag cannot be verified against a successful push run (e.g. tag was
# manually advanced or the GH API query fails), the code sets coverage_fallback=true,
# which is the same full-rebuild signal. This test verifies the shared signal path.

@test "compute_expand_retained_map: unverified-tag fail-safe (fallback_all=true) forces retained expansion on all containers" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    # Simulate: tag present + ancestor check passed, but GH API verification failed
    # (or returned 'no'). Code falls through to coverage_fallback=true → same signal.
    printf '' > "${TEST_DIR}/changed.txt"
    containers='["postgres","openresty","terraform"]'

    run compute_expand_retained_map "push" "false" "${TEST_DIR}/changed.txt" "$containers" "true"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.postgres')" = "true" ]
    [ "$(echo "$output" | jq -r '.openresty')" = "true" ]
    [ "$(echo "$output" | jq -r '.terraform')" = "true" ]
}

@test "compute_expand_retained_map: verified checkpoint tag with partial diff expands only changed containers" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    # Simulate: tag verified (fallback_all=false), only openresty changed.
    # Only openresty should expand retained; terraform stays latest-only.
    printf 'openresty/Dockerfile\n' > "${TEST_DIR}/changed.txt"
    containers='["openresty","terraform","postgres"]'

    run compute_expand_retained_map "push" "false" "${TEST_DIR}/changed.txt" "$containers" "false"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.openresty')" = "true" ]
    [ "$(echo "$output" | jq -r '.terraform')" = "false" ]
    [ "$(echo "$output" | jq -r '.postgres')" = "false" ]
}

# --- Finding 1 checkpoint-job binding traces ---
# Trace (a): resolve-coverage-baseline finds a run at B whose
#   publish-coverage-checkpoint job succeeded → baseline_valid=true →
#   find-containers uses the partial diff → compute_expand_retained_map
#   receives fallback_all=false and the partial diff → only changed containers expand.
#
# Trace (b): resolve-coverage-baseline finds a run at B (successful push run)
#   but NO publish-coverage-checkpoint job success → baseline_valid=false →
#   find-containers sets coverage_fallback=true → compute_expand_retained_map
#   receives fallback_all=true → ALL containers expand (fail-safe).
#
# The compute_expand_retained_map function is the downstream consumer of
# baseline_valid; it receives fallback_all from the action step.  The two
# bats tests below exercise the contract of the downstream consumer for each
# upstream trace, ensuring that changing fallback_all between the two traces
# produces the correct per-container result.

@test "compute_expand_retained_map: trace-a (checkpoint job verified, baseline_valid=true) — partial diff, only changed container expands" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    # Trace (a): baseline_valid=true passed as fallback_all=false.
    # changed_files contains only postgres; other containers must stay latest-only.
    printf 'postgres/variants.yaml\n' > "${TEST_DIR}/changed.txt"
    containers='["postgres","ansible","terraform"]'

    run compute_expand_retained_map "push" "false" "${TEST_DIR}/changed.txt" "$containers" "false"
    [ "$status" -eq 0 ]
    # The changed container expands all retained versions.
    [ "$(echo "$output" | jq -r '.postgres')" = "true" ]
    # Unchanged containers stay at latest-only.
    [ "$(echo "$output" | jq -r '.ansible')" = "false" ]
    [ "$(echo "$output" | jq -r '.terraform')" = "false" ]
}

@test "compute_expand_retained_map: trace-b (push run succeeded but checkpoint job not present/skipped) — fail-safe: all containers expand" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    # Trace (b): a successful push run existed at B, but the
    # publish-coverage-checkpoint job was skipped or not present (e.g. a run
    # predating the mechanism, or a partial success where only checkpoint was
    # skipped).  resolve-coverage-baseline leaves baseline_valid=false →
    # find-containers sets coverage_fallback=true → fallback_all=true here.
    # Even though only postgres changed, ALL containers must expand.
    printf 'postgres/variants.yaml\n' > "${TEST_DIR}/changed.txt"
    containers='["postgres","ansible","terraform"]'

    run compute_expand_retained_map "push" "false" "${TEST_DIR}/changed.txt" "$containers" "true"
    [ "$status" -eq 0 ]
    # Fail-safe: every container expands retained versions regardless of diff.
    [ "$(echo "$output" | jq -r '.postgres')" = "true" ]
    [ "$(echo "$output" | jq -r '.ansible')" = "true" ]
    [ "$(echo "$output" | jq -r '.terraform')" = "true" ]
}

# --- Finding A: carried-forward containers must force retained-version expansion ---
# Mutation locked: if the new Rule 5 (carried-forward check) is removed, the first
# test goes RED — a carried-forward container with no changed-file entry would fall
# through to Priority 7 (default: false), rebuilding latest-only and producing a
# false recovery signal.

@test "compute_expand_retained_map: carried-forward container with NO changed-file prefix expands to true" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    # No files changed for github-runner — it has no entry in changed_files.
    # It is carried forward from a prior failed run.
    # Without Rule 5, it would fall through to default=false → latest-only →
    # extract_failed_recovered would see latest green → false recovery.
    printf 'postgres/variants.yaml\n' > "${TEST_DIR}/changed.txt"
    containers='["github-runner","postgres"]'
    carried='["github-runner"]'

    run compute_expand_retained_map "push" "false" "${TEST_DIR}/changed.txt" "$containers" "false" "$carried"
    [ "$status" -eq 0 ]
    # Carried-forward container must expand all retained versions.
    [ "$(echo "$output" | jq -r '."github-runner"')" = "true" ]
    # postgres changed via diff — also true (unrelated to carry-forward).
    [ "$(echo "$output" | jq -r '.postgres')" = "true" ]
}

@test "compute_expand_retained_map: container NOT carried and NOT changed stays false (6-arg call)" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    # ansible is neither in carried_forward nor in changed_files.
    # Behavior must match the pre-Finding-A default (false).
    printf 'postgres/variants.yaml\n' > "${TEST_DIR}/changed.txt"
    containers='["ansible","postgres"]'
    carried='["github-runner"]'   # github-runner not in containers — irrelevant

    run compute_expand_retained_map "push" "false" "${TEST_DIR}/changed.txt" "$containers" "false" "$carried"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.ansible')" = "false" ]
    [ "$(echo "$output" | jq -r '.postgres')" = "true" ]
}

@test "compute_expand_retained_map: 5-arg call (no carried_forward) behaves as carried=[] — backward compat" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    export PATH="${ORIG_DIR}/bin:${PATH#"$TEST_DIR"/bin:}"
    hash -r

    # Three existing callers (make:524, recreate-manifests.yaml, validate-version-scripts.yaml)
    # pass only 5 args.  This call must produce identical results to passing carried_forward=[].
    printf 'openresty/Dockerfile\n' > "${TEST_DIR}/changed.txt"
    containers='["openresty","terraform"]'

    # 5-arg call — carried_forward defaults to []
    run compute_expand_retained_map "push" "false" "${TEST_DIR}/changed.txt" "$containers" "false"
    [ "$status" -eq 0 ]
    local result_5arg
    result_5arg="$output"

    # 6-arg call with explicit []
    run compute_expand_retained_map "push" "false" "${TEST_DIR}/changed.txt" "$containers" "false" "[]"
    [ "$status" -eq 0 ]
    local result_6arg
    result_6arg="$output"

    # Both must produce the same map (openresty=true, terraform=false).
    [ "$(echo "$result_5arg" | jq -r '.openresty')" = "true" ]
    [ "$(echo "$result_5arg" | jq -r '.terraform')" = "false" ]
    [ "$(echo "$result_6arg" | jq -r '.openresty')" = "true" ]
    [ "$(echo "$result_6arg" | jq -r '.terraform')" = "false" ]
    # Maps must be equal.
    [ "$(echo "$result_5arg" | jq -c 'to_entries | sort_by(.key)')" = "$(echo "$result_6arg" | jq -c 'to_entries | sort_by(.key)')" ]
}

# --- compute_cell_tags ---
#
# New signature: compute_cell_tags <tag> <flavor> <is_default> <dockerhub_image> <ghcr_image>
# is_default is now a caller-supplied boolean ("true"/"false"), computed from the
# VARIANT NAME via variant_property — not looked up internally.
#
# Four cases per the spec:
#   (a) no-flavor container (flavor="", is_default="false") → versioned + :latest (both registries)
#   (b) flavor non-empty + is_default="true"  → versioned + :latest (both registries)
#   (c) flavor non-empty + is_default="false" → versioned + :latest-<flavor> (both registries)
#   (d) tag == "latest"                       → only versioned refs, no rolling latest

@test "compute_cell_tags: (a) no-flavor → versioned + :latest on both registries" {
    # No variants.yaml needed — function is now pure (no yq lookup)
    run compute_cell_tags "2.3.1" "" "false" "docker.io/owner/plain" "ghcr.io/owner/plain"
    [ "$status" -eq 0 ]
    # Must contain exactly 4 lines: versioned×2 + latest×2
    [ "$(echo "$output" | wc -l)" -eq 4 ]
    [[ "$output" == *"docker.io/owner/plain:2.3.1"* ]]
    [[ "$output" == *"ghcr.io/owner/plain:2.3.1"* ]]
    [[ "$output" == *"docker.io/owner/plain:latest"* ]]
    [[ "$output" == *"ghcr.io/owner/plain:latest"* ]]
    # Must NOT contain any "latest-" rolling-flavor tag
    [[ "$output" != *"latest-"* ]]
}

@test "compute_cell_tags: (b) flavor + is_default=true → versioned + :latest on both registries" {
    run compute_cell_tags "1.0.0-base" "base" "true" "docker.io/owner/myapp" "ghcr.io/owner/myapp"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | wc -l)" -eq 4 ]
    [[ "$output" == *"docker.io/owner/myapp:1.0.0-base"* ]]
    [[ "$output" == *"ghcr.io/owner/myapp:1.0.0-base"* ]]
    [[ "$output" == *"docker.io/owner/myapp:latest"* ]]
    [[ "$output" == *"ghcr.io/owner/myapp:latest"* ]]
    # Must NOT emit :latest-base (that's the non-default flavor path)
    [[ "$output" != *"latest-base"* ]]
}

@test "compute_cell_tags: (c) flavor + is_default=false → versioned + :latest-<flavor> on both registries" {
    run compute_cell_tags "18-alpine-vector" "vector" "false" "docker.io/owner/postgres" "ghcr.io/owner/postgres"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | wc -l)" -eq 4 ]
    [[ "$output" == *"docker.io/owner/postgres:18-alpine-vector"* ]]
    [[ "$output" == *"ghcr.io/owner/postgres:18-alpine-vector"* ]]
    [[ "$output" == *"docker.io/owner/postgres:latest-vector"* ]]
    [[ "$output" == *"ghcr.io/owner/postgres:latest-vector"* ]]
    # Must NOT emit bare :latest (that's the default-flavor path)
    local bare_latest_count
    bare_latest_count=$(echo "$output" | grep -cxF "docker.io/owner/postgres:latest" || true)
    [ "$bare_latest_count" -eq 0 ]
}

@test "compute_cell_tags: (d) tag==latest → only versioned refs, no rolling latest added" {
    run compute_cell_tags "latest" "" "false" "docker.io/owner/plain2" "ghcr.io/owner/plain2"
    [ "$status" -eq 0 ]
    # Must contain exactly 2 lines: only the versioned (:latest) refs — no additional rolling tags
    [ "$(echo "$output" | wc -l)" -eq 2 ]
    [[ "$output" == *"docker.io/owner/plain2:latest"* ]]
    [[ "$output" == *"ghcr.io/owner/plain2:latest"* ]]
}

@test "compute_cell_tags: github-runner default variant (name!=flavor) → bare :latest via is_default=true" {
    # Regression: github-runner variant ubuntu-2404-base has flavor=ubuntu-2404.
    # Old code called variant_property(dir, "ubuntu-2404", "default") — wrong (flavor, not name).
    # New code: caller passes is_default computed from variant NAME ubuntu-2404-base → "true".
    run compute_cell_tags "2.334.0" "ubuntu-2404" "true" "docker.io/owner/github-runner" "ghcr.io/owner/github-runner"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | wc -l)" -eq 4 ]
    [[ "$output" == *"docker.io/owner/github-runner:2.334.0"* ]]
    [[ "$output" == *"ghcr.io/owner/github-runner:2.334.0"* ]]
    # Default variant must get bare :latest, NOT :latest-ubuntu-2404
    [[ "$output" == *"docker.io/owner/github-runner:latest"* ]]
    [[ "$output" == *"ghcr.io/owner/github-runner:latest"* ]]
    local flavor_latest_count
    flavor_latest_count=$(echo "$output" | grep -c "latest-ubuntu-2404" || true)
    [ "$flavor_latest_count" -eq 0 ]
}

@test "compute_cell_tags: github-runner non-default variant → :latest-<flavor>" {
    # ubuntu-2404-dev has flavor=ubuntu-2404 but is NOT default → latest-ubuntu-2404
    run compute_cell_tags "2.334.0-dev" "ubuntu-2404" "false" "docker.io/owner/github-runner" "ghcr.io/owner/github-runner"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | wc -l)" -eq 4 ]
    [[ "$output" == *"docker.io/owner/github-runner:2.334.0-dev"* ]]
    [[ "$output" == *"ghcr.io/owner/github-runner:2.334.0-dev"* ]]
    [[ "$output" == *"docker.io/owner/github-runner:latest-ubuntu-2404"* ]]
    [[ "$output" == *"ghcr.io/owner/github-runner:latest-ubuntu-2404"* ]]
    # Must NOT emit bare :latest
    local bare_latest_count
    bare_latest_count=$(echo "$output" | grep -cxF "docker.io/owner/github-runner:latest" || true)
    [ "$bare_latest_count" -eq 0 ]
}

# --- compute_cell_tag_suffixes ---
#
# Unit tests for the registry-independent suffix helper. Four cases:
#   (a) no-flavor non-default           → versioned + "latest"
#   (b) flavor set + is_default=true    → versioned + "latest"  (flavor ignored for default)
#   (c) flavor set + is_default=false   → versioned + "latest-<flavor>"
#   (d) tag already == "latest"         → only versioned suffix, no alias

@test "compute_cell_tag_suffixes: (a) no-flavor non-default → versioned + bare latest" {
    run compute_cell_tag_suffixes "2.3.1" "" "false"
    [ "$status" -eq 0 ]
    # Exactly 2 lines
    [ "$(echo "$output" | wc -l)" -eq 2 ]
    # Line 1: versioned suffix
    [ "$(echo "$output" | sed -n '1p')" = "2.3.1" ]
    # Line 2: bare latest
    [ "$(echo "$output" | sed -n '2p')" = "latest" ]
    # Must NOT contain any "latest-" flavor alias
    [[ "$output" != *"latest-"* ]]
}

@test "compute_cell_tag_suffixes: (b) flavor + is_default=true → versioned + bare latest (flavor ignored)" {
    run compute_cell_tag_suffixes "1.0.0-base" "base" "true"
    [ "$status" -eq 0 ]
    # Exactly 2 lines
    [ "$(echo "$output" | wc -l)" -eq 2 ]
    # Line 1: versioned suffix
    [ "$(echo "$output" | sed -n '1p')" = "1.0.0-base" ]
    # Line 2: bare latest (NOT latest-base)
    [ "$(echo "$output" | sed -n '2p')" = "latest" ]
    [[ "$output" != *"latest-base"* ]]
}

@test "compute_cell_tag_suffixes: (c) flavor + is_default=false → versioned + latest-<flavor>" {
    run compute_cell_tag_suffixes "18-alpine-vector" "vector" "false"
    [ "$status" -eq 0 ]
    # Exactly 2 lines
    [ "$(echo "$output" | wc -l)" -eq 2 ]
    # Line 1: versioned suffix
    [ "$(echo "$output" | sed -n '1p')" = "18-alpine-vector" ]
    # Line 2: flavor rolling alias
    [ "$(echo "$output" | sed -n '2p')" = "latest-vector" ]
    # Must NOT contain bare :latest line
    local bare_latest_count
    bare_latest_count=$(echo "$output" | grep -cxF "latest" || true)
    [ "$bare_latest_count" -eq 0 ]
}

@test "compute_cell_tag_suffixes: (d) tag==latest → single line, no alias added" {
    run compute_cell_tag_suffixes "latest" "" "false"
    [ "$status" -eq 0 ]
    # Exactly 1 line — the versioned "latest" suffix with no additional rolling alias
    [ "$(echo "$output" | wc -l)" -eq 1 ]
    [ "$(echo "$output" | sed -n '1p')" = "latest" ]
}
