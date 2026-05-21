#!/usr/bin/env bats

# Unit tests for helpers/base-cache-utils.sh
# Covers: resolve_cache_check_tag — tag resolution for GHCR accessibility checks

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
