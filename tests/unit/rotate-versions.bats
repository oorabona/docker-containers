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

create_retention_window_container() {
    local dir="${1:-tf}"
    mkdir -p "$dir"
    cat > "$dir/variants.yaml" <<'EOF'
build:
  version_retention: 3

versions:
  - tag: "1.15.4"
  - tag: "1.15.3"
  - tag: "1.15.2"
EOF
}

create_rotated_retention_window_container() {
    local dir="${1:-tf}"
    mkdir -p "$dir"
    cat > "$dir/variants.yaml" <<'EOF'
build:
  version_retention: 3

versions:
  - tag: "1.15.5"
  - tag: "1.15.4"
  - tag: "1.15.3"
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
    cat > myapp/config.yaml <<'EOF'
base_image_cache:
  - source: example/myapp
    tags: ["2.0.0", "1.9.0"]
EOF

    run scripts/rotate-versions.sh "myapp" "2.0.0"
    [ "$status" -eq 0 ]

    # Should still have exactly 2 entries
    local count
    count=$(yq -r '.versions | length' myapp/variants.yaml)
    [ "$count" -eq 2 ]

    local tags
    tags=$(yq -r '.base_image_cache[] | select(.source == "example/myapp") | .tags | join(",")' myapp/config.yaml)
    [ "$tags" = "2.0.0,1.9.0" ]
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

@test "rotate: base_image_cache version tags mirror retained variants" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi

    create_retention_window_container "tf"
    cat > tf/config.yaml <<'EOF'
base_image: "${REMOTE_CR}/hashicorp/terraform:${UPSTREAM_VERSION}"
base_image_cache:
  - source: hashicorp/terraform
    tags: ["1.15.4", "1.15.3", "1.15.2"]
EOF

    run scripts/rotate-versions.sh "tf" "1.15.5"
    [ "$status" -eq 0 ]

    local tags
    tags=$(yq -r '.base_image_cache[] | select(.source == "hashicorp/terraform") | .tags | join(",")' tf/config.yaml)
    [ "$tags" = "1.15.5,1.15.4,1.15.3" ]
}

@test "rotate: base_image_cache version tags preserve suffix format" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi

    create_retention_window_container "tf"
    cat > tf/config.yaml <<'EOF'
base_image_cache:
  - source: hashicorp/terraform
    tags: ["1.15.4-alpine", "1.15.3-alpine", "1.15.2-alpine"]
EOF

    run scripts/rotate-versions.sh "tf" "1.15.5"
    [ "$status" -eq 0 ]

    local tags
    tags=$(yq -r '.base_image_cache[] | select(.source == "hashicorp/terraform") | .tags | join(",")' tf/config.yaml)
    [ "$tags" = "1.15.5-alpine,1.15.4-alpine,1.15.3-alpine" ]
}

@test "rotate: idempotent variants path reconciles stale base_image_cache" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi

    create_rotated_retention_window_container "tf"
    cp tf/variants.yaml tf/variants.before.yaml
    cat > tf/config.yaml <<'EOF'
base_image_cache:
  - source: hashicorp/terraform
    tags: ["1.15.4", "1.15.3", "1.15.2"]
EOF

    run scripts/rotate-versions.sh "tf" "1.15.5"
    [ "$status" -eq 0 ]

    cmp -s tf/variants.before.yaml tf/variants.yaml

    local tags
    tags=$(yq -r '.base_image_cache[] | select(.source == "hashicorp/terraform") | .tags | join(",")' tf/config.yaml)
    [ "$tags" = "1.15.5,1.15.4,1.15.3" ]
}

@test "rotate: idempotent cache reconciliation leaves unrelated entries untouched" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi

    create_rotated_retention_window_container "tf"
    cat > tf/config.yaml <<'EOF'
base_image_cache:
  - source: hashicorp/terraform
    tags: ["1.15.4", "1.15.3", "1.15.2"]
  - source: library/alpine
    tags: ["latest"]
  - source: library/python
    tags: ["3.12-alpine"]
EOF

    run scripts/rotate-versions.sh "tf" "1.15.5"
    [ "$status" -eq 0 ]

    local terraform_tags
    local alpine_tags
    local python_tags
    terraform_tags=$(yq -r '.base_image_cache[] | select(.source == "hashicorp/terraform") | .tags | join(",")' tf/config.yaml)
    alpine_tags=$(yq -r '.base_image_cache[] | select(.source == "library/alpine") | .tags | join(",")' tf/config.yaml)
    python_tags=$(yq -r '.base_image_cache[] | select(.source == "library/python") | .tags | join(",")' tf/config.yaml)

    [ "$terraform_tags" = "1.15.5,1.15.4,1.15.3" ]
    [ "$alpine_tags" = "latest" ]
    [ "$python_tags" = "3.12-alpine" ]
}

@test "rotate: non-version base_image_cache entries are untouched" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi

    create_retention_window_container "tf"
    cat > tf/config.yaml <<'EOF'
base_image_cache:
  - source: library/alpine
    tags: ["latest"]
  - source: library/python
    tags: ["3.12-alpine"]
EOF

    run scripts/rotate-versions.sh "tf" "1.15.5"
    [ "$status" -eq 0 ]

    local alpine_tags
    local python_tags
    alpine_tags=$(yq -r '.base_image_cache[] | select(.source == "library/alpine") | .tags | join(",")' tf/config.yaml)
    python_tags=$(yq -r '.base_image_cache[] | select(.source == "library/python") | .tags | join(",")' tf/config.yaml)

    [ "$alpine_tags" = "latest" ]
    [ "$python_tags" = "3.12-alpine" ]
}

@test "rotate: config without base_image_cache is unchanged" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi

    create_retention_window_container "tf"
    cat > tf/config.yaml <<'EOF'
base_image: "${REMOTE_CR}/hashicorp/terraform:${UPSTREAM_VERSION}"
build_args:
  TFLINT_VERSION: "0.63.1"
EOF
    cp tf/config.yaml tf/config.before.yaml

    run scripts/rotate-versions.sh "tf" "1.15.5"
    [ "$status" -eq 0 ]
    cmp -s tf/config.before.yaml tf/config.yaml
}

@test "rotate: mixed base_image_cache rotates only version-keyed entry" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi

    create_retention_window_container "tf"
    cat > tf/config.yaml <<'EOF'
base_image_cache:
  - source: hashicorp/terraform
    tags: ["1.15.4", "1.15.3", "1.15.2"]
  - source: library/alpine
    tags: ["latest"]
EOF

    run scripts/rotate-versions.sh "tf" "1.15.5"
    [ "$status" -eq 0 ]

    local terraform_tags
    local alpine_tags
    terraform_tags=$(yq -r '.base_image_cache[] | select(.source == "hashicorp/terraform") | .tags | join(",")' tf/config.yaml)
    alpine_tags=$(yq -r '.base_image_cache[] | select(.source == "library/alpine") | .tags | join(",")' tf/config.yaml)

    [ "$terraform_tags" = "1.15.5,1.15.4,1.15.3" ]
    [ "$alpine_tags" = "latest" ]
}
