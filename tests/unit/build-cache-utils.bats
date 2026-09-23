#!/usr/bin/env bats

# Unit tests for helpers/build-cache-utils.sh
# Tests per-flavor precise build digest computation

setup() {
    # Create temp dir for test isolation
    TEST_DIR=$(mktemp -d)
    ORIG_DIR="$PWD"
    cd "$TEST_DIR" || exit 1

    # Source dependencies from the project root
    source "$ORIG_DIR/helpers/logging.sh"
    source "$ORIG_DIR/helpers/build-cache-utils.sh"
}

# Additional setup for _resolve_base_image tests (sources build-container.sh)
_setup_resolve_base_image() {
    source "$ORIG_DIR/helpers/variant-utils.sh"
    source "$ORIG_DIR/helpers/build-args-utils.sh"
    source "$ORIG_DIR/helpers/template-utils.sh"
    source "$ORIG_DIR/helpers/extension-utils.sh"
    source "$ORIG_DIR/scripts/build-container.sh"
}

teardown() {
    cd "$ORIG_DIR" || true
    rm -rf "$TEST_DIR"
}

# --- Postgres Flavors ---

@test "pgvector bump changes vector digest, not timeseries" {
    mkdir -p flavors extensions

    cat > flavors/vector.yaml <<'EOF'
name: vector
extensions:
  - pgvector
EOF

    cat > flavors/timeseries.yaml <<'EOF'
name: timeseries
extensions:
  - timescaledb
EOF

    cat > extensions/config.yaml <<'EOF'
extensions:
  pgvector:
    version: "0.8.1"
  timescaledb:
    version: "2.1.0"
EOF
    echo "FROM postgres:17" > Dockerfile

    # Compute initial digests
    run compute_build_digest "Dockerfile" "vector"
    [ "$status" -eq 0 ]
    local digest_vector_1="$output"

    run compute_build_digest "Dockerfile" "timeseries"
    [ "$status" -eq 0 ]
    local digest_timeseries_1="$output"

    # Bump pgvector version
    cat > extensions/config.yaml <<'EOF'
extensions:
  pgvector:
    version: "0.9.0"
  timescaledb:
    version: "2.1.0"
EOF

    run compute_build_digest "Dockerfile" "vector"
    local digest_vector_2="$output"

    run compute_build_digest "Dockerfile" "timeseries"
    local digest_timeseries_2="$output"

    # Vector changed, timeseries unchanged
    [ "$digest_vector_1" != "$digest_vector_2" ]
    [ "$digest_timeseries_1" == "$digest_timeseries_2" ]
}

@test "full flavor includes all extension versions" {
    mkdir -p flavors extensions
    cat > flavors/full.yaml <<'EOF'
name: full
extensions:
  - pgvector
  - citus
EOF
    cat > extensions/config.yaml <<'EOF'
extensions:
  pgvector:
    version: "0.8.1"
  citus:
    version: "13.2.0"
EOF
    echo "FROM postgres:17" > Dockerfile

    run compute_build_digest "Dockerfile" "full"
    [ "$status" -eq 0 ]
    local d1="$output"

    # Change citus version
    cat > extensions/config.yaml <<'EOF'
extensions:
  pgvector:
    version: "0.8.1"
  citus:
    version: "14.0.0"
EOF

    run compute_build_digest "Dockerfile" "full"
    local d2="$output"

    [ "$d1" != "$d2" ]
}

@test "base flavor has no extensions — unaffected by extension bumps" {
    mkdir -p flavors extensions
    cat > flavors/base.yaml <<'EOF'
name: base
extensions: []
EOF
    cat > extensions/config.yaml <<'EOF'
extensions:
  pgvector:
    version: "0.8.1"
EOF
    echo "FROM postgres:17" > Dockerfile

    run compute_build_digest "Dockerfile" "base"
    [ "$status" -eq 0 ]
    local d1="$output"

    # Bump pgvector
    cat > extensions/config.yaml <<'EOF'
extensions:
  pgvector:
    version: "0.9.0"
EOF

    run compute_build_digest "Dockerfile" "base"
    local d2="$output"

    # Base digest unchanged (no extensions in its flavor)
    [ "$d1" == "$d2" ]
}

# --- Terraform Variants ---

@test "AWS CLI bump changes aws digest, not base" {
    cat > variants.yaml <<'EOF'
versions:
  - variants:
      - name: aws
        flavor: aws
        build_args_include:
          - TFLINT_VERSION
          - AWS_CLI_VERSION
      - name: base
        flavor: base
        build_args_include:
          - TFLINT_VERSION
EOF
    cat > config.yaml <<'EOF'
build_args:
  TFLINT_VERSION: "0.60.0"
  AWS_CLI_VERSION: "1.44.29"
EOF
    echo "FROM alpine" > Dockerfile

    run compute_build_digest "Dockerfile" "aws"
    [ "$status" -eq 0 ]
    local d_aws_1="$output"

    run compute_build_digest "Dockerfile" "base"
    [ "$status" -eq 0 ]
    local d_base_1="$output"

    # Bump AWS CLI
    cat > config.yaml <<'EOF'
build_args:
  TFLINT_VERSION: "0.60.0"
  AWS_CLI_VERSION: "1.45.0"
EOF

    run compute_build_digest "Dockerfile" "aws"
    local d_aws_2="$output"

    run compute_build_digest "Dockerfile" "base"
    local d_base_2="$output"

    # AWS changed, base unchanged
    [ "$d_aws_1" != "$d_aws_2" ]
    [ "$d_base_1" == "$d_base_2" ]
}

@test "TFLINT bump changes all terraform flavors" {
    cat > variants.yaml <<'EOF'
versions:
  - variants:
      - name: aws
        flavor: aws
        build_args_include:
          - TFLINT_VERSION
          - AWS_CLI_VERSION
      - name: base
        flavor: base
        build_args_include:
          - TFLINT_VERSION
EOF
    cat > config.yaml <<'EOF'
build_args:
  TFLINT_VERSION: "0.60.0"
  AWS_CLI_VERSION: "1.44.29"
EOF
    echo "FROM alpine" > Dockerfile

    run compute_build_digest "Dockerfile" "aws"
    local d_aws_1="$output"

    run compute_build_digest "Dockerfile" "base"
    local d_base_1="$output"

    # Bump TFLINT
    cat > config.yaml <<'EOF'
build_args:
  TFLINT_VERSION: "0.61.0"
  AWS_CLI_VERSION: "1.44.29"
EOF

    run compute_build_digest "Dockerfile" "aws"
    local d_aws_2="$output"

    run compute_build_digest "Dockerfile" "base"
    local d_base_2="$output"

    # Both changed
    [ "$d_aws_1" != "$d_aws_2" ]
    [ "$d_base_1" != "$d_base_2" ]
}

# --- Simple Containers ---

@test "container with config.yaml build_args" {
    cat > config.yaml <<'EOF'
build_args:
  FOO: "1.0"
EOF
    echo "FROM alpine" > Dockerfile

    run compute_build_digest "Dockerfile" ""
    [ "$status" -eq 0 ]
    local d1="$output"

    cat > config.yaml <<'EOF'
build_args:
  FOO: "2.0"
EOF

    run compute_build_digest "Dockerfile" ""
    local d2="$output"

    [ "$d1" != "$d2" ]
}

@test "container with no config.yaml returns valid 12-char hex digest" {
    echo "FROM alpine" > Dockerfile

    run compute_build_digest "Dockerfile" ""
    [ "$status" -eq 0 ]
    local d1="$output"

    # Valid 12-char hex
    [ "${#d1}" -eq 12 ]
    [[ "$d1" =~ ^[0-9a-f]{12}$ ]]

    # Dockerfile change produces different digest
    echo "FROM alpine:3.18" > Dockerfile
    run compute_build_digest "Dockerfile" ""
    local d2="$output"

    [ "$d1" != "$d2" ]
}

# --- Edge Cases ---

@test "CUSTOM_BUILD_ARGS included in digest" {
    echo "FROM alpine" > Dockerfile

    run compute_build_digest "Dockerfile" ""
    local d1="$output"

    CUSTOM_BUILD_ARGS="--build-arg BASE=foo"
    export CUSTOM_BUILD_ARGS
    run compute_build_digest "Dockerfile" ""
    local d2="$output"
    unset CUSTOM_BUILD_ARGS

    [ "$d1" != "$d2" ]
}

@test "deterministic output — identical inputs produce identical digest" {
    cat > config.yaml <<'EOF'
build_args:
  A: "1"
  B: "2"
EOF
    echo "FROM alpine" > Dockerfile

    run compute_build_digest "Dockerfile" ""
    [ "$status" -eq 0 ]
    local d1="$output"

    run compute_build_digest "Dockerfile" ""
    local d2="$output"

    [ "$d1" == "$d2" ]
}

# --- yq requirement ---

@test "compute_build_digest refuses a missing yq with a named diagnostic" {
    echo "FROM alpine" > Dockerfile
    local fake_bin="$TEST_DIR/fake_bin"
    mkdir -p "$fake_bin"

    PATH="$fake_bin" run compute_build_digest "Dockerfile" ""

    [ "$status" -ne 0 ]
    [[ "$output" == *"yq is required for build digest inputs but was not found in PATH"* ]]
    [[ "$output" != *"cat:"* ]]
}

@test "digest serialization preserves established postgres and terraform digests" {
    local -a cases=(
        "postgres analytics 08a1a6eed3a1"
        "postgres base 0ecd9b539d01"
        "postgres distributed bf11af001fa2"
        "postgres full 3e4292355445"
        "postgres spatial e78ff2927cf3"
        "postgres timeseries 2a4e0b2efb67"
        "postgres vector eb885e90733d"
        "terraform aws d2fd46498ae9"
        "terraform azure 272ef51e54ef"
        "terraform base d56522613b5c"
        "terraform full b8fe5baa6290"
        "terraform gcp 938f9817b6e1"
    )
    local case container flavor expected

    for case in "${cases[@]}"; do
        read -r container flavor expected <<< "$case"
        cd "$ORIG_DIR/$container"
        run compute_build_digest "Dockerfile" "$flavor"
        [ "$status" -eq 0 ]
        [ "$output" = "$expected" ]
    done
}

# --- Integration Smoke Tests ---

@test "integration — postgres real flavors produce different digests" {
    cd "$ORIG_DIR/postgres" || skip "postgres directory not found"

    local -A digests
    local flavor
    for flavor in base vector analytics timeseries distributed full; do
        [ -f "flavors/${flavor}.yaml" ] || continue
        run compute_build_digest "Dockerfile" "$flavor"
        [ "$status" -eq 0 ]
        digests[$flavor]="$output"
        # Valid 12-char hex
        [[ "$output" =~ ^[0-9a-f]{12}$ ]]
    done

    # All flavors must produce different digests
    local -a values=("${digests[@]}")
    local unique
    unique=$(printf '%s\n' "${values[@]}" | sort -u | wc -l)
    [ "$unique" -eq "${#values[@]}" ]
}

@test "integration — terraform real flavors produce different digests" {
    cd "$ORIG_DIR/terraform" || skip "terraform directory not found"
    # Note: config.yaml already has build_args on disk — no need to source ./build

    local -A digests
    local flavor
    for flavor in base aws azure gcp full; do
        run compute_build_digest "Dockerfile" "$flavor"
        [ "$status" -eq 0 ]
        digests[$flavor]="$output"
        [[ "$output" =~ ^[0-9a-f]{12}$ ]]
    done

    # All 5 flavors must produce different digests
    local -a values=("${digests[@]}")
    local unique
    unique=$(printf '%s\n' "${values[@]}" | sort -u | wc -l)
    [ "$unique" -eq "${#values[@]}" ]
}

@test "integration — simple container (ansible) produces valid digest" {
    cd "$ORIG_DIR/ansible" || skip "ansible directory not found"

    run compute_build_digest "Dockerfile" ""
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9a-f]{12}$ ]]
}

# --- Observability ---

@test "digest inputs are logged when DIGEST_DEBUG=1" {
    echo "FROM alpine" > Dockerfile
    mkdir -p flavors
    cat > flavors/test.yaml <<'EOF'
name: test
extensions:
  - pgvector
EOF
    mkdir -p extensions
    cat > extensions/config.yaml <<'EOF'
extensions:
  pgvector:
    version: "0.8.1"
EOF

    DIGEST_DEBUG=1
    export DIGEST_DEBUG

    run compute_build_digest "Dockerfile" "test"
    [ "$status" -eq 0 ]

    # Debug output should mention digest inputs
    [[ "$output" == *"digest input: Dockerfile"* ]]
    [[ "$output" == *"digest type: postgres-style"* ]]
    [[ "$output" == *"pgvector=0.8.1"* ]]
}

# --- _resolve_base_image: REMOTE_CR override (FIX-2) ---
# Verifies that CUSTOM_BUILD_ARGS="--build-arg REMOTE_CR=..." wins over the
# Dockerfile ARG default (ARG REMOTE_CR=docker.io) when resolving the base
# image reference for lineage labels and manifest-inspect.

@test "CUSTOM_BUILD_ARGS REMOTE_CR override wins over Dockerfile ARG default" {
    _setup_resolve_base_image

    # Dockerfile that mirrors the postgres pattern: ARG REMOTE_CR with docker.io default
    cat > Dockerfile <<'EOF'
ARG REMOTE_CR=docker.io
FROM ${REMOTE_CR}/library/postgres:${VERSION}
EOF
    # No config.yaml base_image — falls through to Dockerfile FROM parsing
    local label_args=""
    CUSTOM_BUILD_ARGS="--build-arg REMOTE_CR=ghcr.io/owner"
    export CUSTOM_BUILD_ARGS

    _resolve_base_image "Dockerfile" "17-alpine" "label_args"

    unset CUSTOM_BUILD_ARGS

    # Must resolve to the GHCR mirror, not docker.io
    [[ "$_BASE_IMAGE_REF" == "ghcr.io/owner/library/postgres:17-alpine" ]]
}

@test "without CUSTOM_BUILD_ARGS override, ARG default (docker.io) applies" {
    _setup_resolve_base_image

    cat > Dockerfile <<'EOF'
ARG REMOTE_CR=docker.io
FROM ${REMOTE_CR}/library/postgres:${VERSION}
EOF
    local label_args=""
    unset CUSTOM_BUILD_ARGS

    _resolve_base_image "Dockerfile" "17-alpine" "label_args"

    # Must resolve to docker.io (the ARG default)
    [[ "$_BASE_IMAGE_REF" == "docker.io/library/postgres:17-alpine" ]]
}

@test "last --build-arg REMOTE_CR occurrence wins (docker semantics)" {
    _setup_resolve_base_image

    cat > Dockerfile <<'EOF'
ARG REMOTE_CR=docker.io
FROM ${REMOTE_CR}/library/postgres:${VERSION}
EOF
    local label_args=""
    # Two occurrences — last one (ghcr.io/second) must win
    CUSTOM_BUILD_ARGS="--build-arg REMOTE_CR=ghcr.io/first --build-arg REMOTE_CR=ghcr.io/second"
    export CUSTOM_BUILD_ARGS

    _resolve_base_image "Dockerfile" "17-alpine" "label_args"

    unset CUSTOM_BUILD_ARGS

    [[ "$_BASE_IMAGE_REF" == "ghcr.io/second/library/postgres:17-alpine" ]]
}

# ---------------------------------------------------------------------------
# Fix r10-1: LAST_REBUILD.md included in compute_build_digest
#
# Regression guard: modifying LAST_REBUILD.md must change the descriptive
# build-digest label recorded after a drift PR modifies the file.
# ---------------------------------------------------------------------------

@test "LAST_REBUILD.md absent — digest is stable (baseline)" {
    echo "FROM alpine:3.21" > Dockerfile

    run compute_build_digest "Dockerfile" ""
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9a-f]{12}$ ]]
    local digest_without="$output"

    # Running a second time without LAST_REBUILD.md must return same digest
    run compute_build_digest "Dockerfile" ""
    [ "$status" -eq 0 ]
    [ "$output" = "$digest_without" ]
}

@test "LAST_REBUILD.md present changes digest vs absent" {
    echo "FROM alpine:3.21" > Dockerfile

    run compute_build_digest "Dockerfile" ""
    [ "$status" -eq 0 ]
    local digest_without="$output"

    # Create LAST_REBUILD.md — digest must change
    cat > LAST_REBUILD.md <<'EOF'
## base-digest-drift

Drift detected for alpine:3.21 on 2026-05-27.
EOF

    run compute_build_digest "Dockerfile" ""
    [ "$status" -eq 0 ]
    local digest_with="$output"

    # Must differ from the no-file digest
    [ "$digest_with" != "$digest_without" ]
}

@test "modifying LAST_REBUILD.md changes digest (invalidates cache)" {
    echo "FROM alpine:3.21" > Dockerfile

    echo "## base-digest-drift v1" > LAST_REBUILD.md
    run compute_build_digest "Dockerfile" ""
    [ "$status" -eq 0 ]
    local digest_v1="$output"

    # Append new content to LAST_REBUILD.md (simulates second drift PR)
    echo "## base-digest-drift v2" >> LAST_REBUILD.md
    run compute_build_digest "Dockerfile" ""
    [ "$status" -eq 0 ]
    local digest_v2="$output"

    # Digest must change after modification
    [ "$digest_v2" != "$digest_v1" ]
}

@test "LAST_REBUILD.md included in digest with postgres-style flavor" {
    mkdir -p flavors extensions
    cat > flavors/vector.yaml <<'EOF'
name: vector
extensions:
  - pgvector
EOF
    cat > extensions/config.yaml <<'EOF'
extensions:
  pgvector:
    version: "0.8.1"
EOF
    echo "FROM postgres:17-alpine" > Dockerfile

    run compute_build_digest "Dockerfile" "vector"
    [ "$status" -eq 0 ]
    local digest_without="$output"

    echo "## base-digest-drift" > LAST_REBUILD.md

    run compute_build_digest "Dockerfile" "vector"
    [ "$status" -eq 0 ]
    local digest_with="$output"

    # Digest must change even for postgres-style flavor
    [ "$digest_with" != "$digest_without" ]
}
