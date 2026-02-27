#!/usr/bin/env bats

# Unit tests for scripts/rotate-versions.sh

setup() {
    TEST_DIR=$(mktemp -d)
    ORIG_DIR="$PWD"
    cd "$TEST_DIR" || exit 1

    # Ensure yq and helpers are accessible
    export PATH="${ORIG_DIR}/bin:$PATH"

    # Create helpers directory structure so rotate-versions.sh can source variant-utils.sh
    mkdir -p helpers scripts
    cp "$ORIG_DIR/helpers/variant-utils.sh" helpers/
    cp "$ORIG_DIR/scripts/rotate-versions.sh" scripts/
    chmod +x scripts/rotate-versions.sh
}

teardown() {
    cd "$ORIG_DIR" || true
    rm -rf "$TEST_DIR"
}

# --- Helper to create test fixtures ---

create_versioned_container() {
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

create_versioned_with_variants() {
    local dir="${1:-.}"
    mkdir -p "$dir"
    cat > "$dir/variants.yaml" <<'EOF'
build:
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
EOF
}

create_no_retention() {
    local dir="${1:-.}"
    mkdir -p "$dir"
    cat > "$dir/variants.yaml" <<'EOF'
build:
  requires_extensions: true

versions:
  - tag: "18"
    variants:
      - name: base
        suffix: ""
        flavor: base
EOF
}

# --- Tests ---

@test "rotate: basic prepend + trim" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi

    create_versioned_container "myapp"
    run scripts/rotate-versions.sh "myapp" "2.1.0"
    [ "$status" -eq 0 ]

    # New version should be first
    local first_tag
    first_tag=$(yq -r '.versions[0].tag' myapp/variants.yaml)
    [ "$first_tag" = "2.1.0" ]

    # Should have 3 entries (retention=3)
    local count
    count=$(yq -r '.versions | length' myapp/variants.yaml)
    [ "$count" -eq 3 ]

    # Third entry is 1.9.0 (original second)
    local third_tag
    third_tag=$(yq -r '.versions[2].tag' myapp/variants.yaml)
    [ "$third_tag" = "1.9.0" ]
}

@test "rotate: trim removes oldest when exceeding retention" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi

    create_versioned_container "myapp"

    # Add two more to go from 2 → 4, but retention=3 so it should stay at 3
    scripts/rotate-versions.sh "myapp" "2.1.0"
    scripts/rotate-versions.sh "myapp" "2.2.0"

    local count
    count=$(yq -r '.versions | length' myapp/variants.yaml)
    [ "$count" -eq 3 ]

    # Newest first
    local first_tag
    first_tag=$(yq -r '.versions[0].tag' myapp/variants.yaml)
    [ "$first_tag" = "2.2.0" ]

    # Oldest (1.9.0) should have been trimmed
    local has_old
    has_old=$(yq -r '.versions[].tag' myapp/variants.yaml | grep -c "1.9.0" || true)
    [ "$has_old" -eq 0 ]
}

@test "rotate: idempotence — existing version exits 0 without changes" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi

    create_versioned_container "myapp"
    run scripts/rotate-versions.sh "myapp" "2.0.0"
    [ "$status" -eq 0 ]

    # Should still have exactly 2 entries
    local count
    count=$(yq -r '.versions | length' myapp/variants.yaml)
    [ "$count" -eq 2 ]
}

@test "rotate: container with variants copies variants from first entry" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi

    create_versioned_with_variants "tf"
    run scripts/rotate-versions.sh "tf" "1.15.0-alpine"
    [ "$status" -eq 0 ]

    # New entry should have variants copied from first
    local first_tag
    first_tag=$(yq -r '.versions[0].tag' tf/variants.yaml)
    [ "$first_tag" = "1.15.0-alpine" ]

    local variant_count
    variant_count=$(yq -r '.versions[0].variants | length' tf/variants.yaml)
    [ "$variant_count" -eq 2 ]

    local base_name
    base_name=$(yq -r '.versions[0].variants[0].name' tf/variants.yaml)
    [ "$base_name" = "base" ]
}

@test "rotate: exit code 2 when no version_retention" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi

    create_no_retention "pg"
    run scripts/rotate-versions.sh "pg" "19"
    [ "$status" -eq 2 ]
}

@test "rotate: exit code 1 when no variants.yaml" {
    mkdir -p "nonexistent"
    run scripts/rotate-versions.sh "nonexistent" "1.0.0"
    [ "$status" -eq 1 ]
}
