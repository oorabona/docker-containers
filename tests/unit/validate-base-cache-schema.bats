#!/usr/bin/env bats

# Unit tests for helpers/validate-base-cache-schema.sh
#
# Guard: static config.yaml schema validation for base_image_cache dual-schema.
# Discriminator is BINARY on ghcr_repo: present+non-empty => old-style, else new-style.
# A slash in source is valid for both styles (Docker Hub namespace).
#
# Rules tested:
#   VBC-02: new-style source without slash → REJECT
#   VBC-03: new-style source with registry prefix (dot/colon before first slash) → REJECT
#   VBC-04: new-style source with tag (:) → REJECT
#   VBC-05: new-style source with digest (@) → REJECT
#   VBC-06: new-style source with uppercase letters → REJECT
#   VBC-07: new-style source with empty path component (//) → REJECT
#   VBC-08: REMOTE_CR in build_args → REJECT
#   VBC-09: old-style entry with empty/absent arg → REJECT
#   VBC-10: valid new-style (source: library/postgres, no ghcr_repo) → PASS
#   VBC-11: valid old-style (ghcr_repo + arg present) → PASS
#   VBC-11d: valid old-style with namespaced source (hashicorp/terraform) → PASS [regression lock]
#   VBC-11e: valid new-style with non-library namespace (hashicorp/terraform) → PASS
#   VBC-12: container dir name with slash → REJECT (defensive invariant)
#   VBC-13: new-style source with leading slash → REJECT (empty path component)
#   VBC-14: new-style source with trailing slash → REJECT (empty path component)

setup() {
    TEST_DIR=$(mktemp -d)
    ORIG_DIR="$PWD"
    cd "$TEST_DIR" || exit 1

    # Source the guard helper once available
    source "$ORIG_DIR/helpers/validate-base-cache-schema.sh"
}

teardown() {
    cd "$ORIG_DIR" || true
    rm -rf "$TEST_DIR"
}

# Helper: create a minimal container dir + config.yaml
# Usage: make_container <name> <yaml_content>
make_container() {
    local name="$1"
    local yaml="$2"
    mkdir -p "$name"
    printf '%s\n' "$yaml" > "$name/config.yaml"
}

# ─── REJECT cases ─────────────────────────────────────────────────────────────

@test "VBC-02: new-style source without slash → REJECT" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source: postgres
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

@test "VBC-03: new-style source with registry prefix (docker.io/) → REJECT" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source: docker.io/library/postgres
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

@test "VBC-03b: new-style source with ghcr.io registry prefix → REJECT" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source: ghcr.io/owner/image
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

@test "VBC-03c: new-style source with colon-port registry (localhost:5000/img) → REJECT" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source: localhost:5000/myimage
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

@test "VBC-04: new-style source with tag colon → REJECT" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source: library/postgres:16
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

@test "VBC-05: new-style source with digest @ → REJECT" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source: library/postgres@sha256:abc123
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

@test "VBC-06: new-style source with uppercase letters → REJECT" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source: Library/Postgres
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

@test "VBC-07: new-style source with empty path component (//) → REJECT" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source: library//postgres
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

@test "VBC-08: REMOTE_CR present in build_args → REJECT" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source: library/postgres
    tags: ["latest"]
build_args:
  REMOTE_CR: ghcr.io/owner
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
    [[ "$output" =~ "REMOTE_CR" ]]
}

@test "VBC-09: old-style with empty arg → REJECT" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - arg: ""
    source: ubuntu
    ghcr_repo: ubuntu-base
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

@test "VBC-09b: old-style with absent arg → REJECT" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source: ubuntu
    ghcr_repo: ubuntu-base
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

@test "VBC-13: new-style source with leading slash → REJECT" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source: /library/postgres
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

@test "VBC-14: new-style source with trailing slash → REJECT" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source: library/postgres/
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

# ─── PASS cases ───────────────────────────────────────────────────────────────

@test "VBC-10: valid new-style (source: library/postgres, no ghcr_repo) → PASS" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source: library/postgres
    tags_from_versions: true
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -eq 0 ]
}

@test "VBC-11: valid old-style (ghcr_repo + arg present) → PASS" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - arg: BASE_IMAGE
    source: ubuntu
    ghcr_repo: ubuntu-base
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -eq 0 ]
}

@test "VBC-11b: valid old-style multiple entries → PASS" {
    make_container "myapp" "$(cat <<'EOF'
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
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -eq 0 ]
}

@test "VBC-11c: no base_image_cache section → PASS (no entries to validate)" {
    make_container "myapp" "$(cat <<'EOF'
build_args:
  FOO: bar
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -eq 0 ]
}

@test "VBC-11d: valid old-style with namespaced source (regression lock — hashicorp/terraform pattern) → PASS" {
    # Regression lock: old-style entries (ghcr_repo set) may have a slash in source
    # because Docker Hub uses namespace/image paths (e.g. hashicorp/terraform).
    # The discriminator is BINARY — ghcr_repo present => old-style, full stop.
    # A slash in source is the upstream namespace separator, not a new-style indicator.
    # This test was RED before R1 deletion and proves the bug is locked out.
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - arg: TERRAFORM_BASE
    source: hashicorp/terraform
    ghcr_repo: terraform-base
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -eq 0 ]
}

@test "VBC-11e: valid new-style with non-library namespace (hashicorp/terraform, no ghcr_repo) → PASS" {
    # Guards against future R3 tightening that might mistakenly reject 2-segment
    # paths that are not under the 'library/' namespace.
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source: hashicorp/terraform
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -eq 0 ]
}

@test "VBC-12: defensive — container dir name with slash would be invalid (path check)" {
    # Container names are directory names on disk — they cannot contain /
    # This is a repo invariant. We verify the guard is consistent:
    # a container with a path traversal dir name cannot be created normally.
    # We test the guard rejects a hypothetical 'a/b' name by passing invalid path.
    run validate_container_base_cache_schema "nonexistent/slash"
    # Should fail cleanly (dir does not exist or name contains slash)
    [ "$status" -ne 0 ]
}

# ─── Multi-container scan ─────────────────────────────────────────────────────

@test "VBC-SCAN-01: validate_all_containers_base_cache_schema — all valid → exit 0" {
    make_container "c1" "$(cat <<'EOF'
base_image_cache:
  - arg: BASE_IMAGE
    source: ubuntu
    ghcr_repo: ubuntu-base
    tags: ["latest"]
EOF
)"
    make_container "c2" "$(cat <<'EOF'
base_image_cache:
  - source: library/postgres
    tags_from_versions: true
EOF
)"
    run validate_all_containers_base_cache_schema "."
    [ "$status" -eq 0 ]
}

@test "VBC-SCAN-02: validate_all_containers_base_cache_schema — one invalid → exit non-zero" {
    make_container "good" "$(cat <<'EOF'
base_image_cache:
  - arg: BASE_IMAGE
    source: ubuntu
    ghcr_repo: ubuntu-base
    tags: ["latest"]
EOF
)"
    make_container "bad" "$(cat <<'EOF'
base_image_cache:
  - source: postgres
    tags: ["latest"]
EOF
)"
    run validate_all_containers_base_cache_schema "."
    [ "$status" -ne 0 ]
    [[ "$output" =~ "bad" ]]
}
