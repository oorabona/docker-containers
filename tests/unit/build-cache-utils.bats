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

teardown() {
    cd "$ORIG_DIR" || true
    rm -rf "$TEST_DIR"
}

# --- Postgres Flavors ---

@test "SC-01: pgvector bump changes vector digest, not timeseries" {
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

@test "SC-02: full flavor includes all extension versions" {
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

@test "SC-03: base flavor has no extensions — unaffected by extension bumps" {
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

@test "SC-04: AWS CLI bump changes aws digest, not base" {
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

@test "SC-05: TFLINT bump changes all terraform flavors" {
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

@test "SC-06: container with config.yaml build_args" {
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

@test "SC-07: container with no config.yaml returns valid 12-char hex digest" {
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

@test "SC-08: CUSTOM_BUILD_ARGS included in digest" {
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

@test "SC-09: deterministic output — identical inputs produce identical digest" {
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

# --- Observability ---

@test "SC-10: digest inputs are logged when DIGEST_DEBUG=1" {
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
