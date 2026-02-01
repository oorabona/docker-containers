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

# --- yq Fallback Behavior (F-004) ---

# Helper: run compute_build_digest with yq hidden from PATH
_run_without_yq() {
    # Create a temp bin dir with everything except yq
    local fake_bin="$TEST_DIR/fake_bin"
    mkdir -p "$fake_bin"
    # Link only essential commands (sha256sum, cat, wc, grep, sort, printf, head)
    for cmd in sha256sum cat wc grep sort printf head cut; do
        local cmd_path
        cmd_path=$(command -v "$cmd" 2>/dev/null) && ln -sf "$cmd_path" "$fake_bin/$cmd"
    done
    # Run with restricted PATH (no yq)
    PATH="$fake_bin" run compute_build_digest "$@"
}

@test "F-004a: yq fallback — postgres flavor uses raw file content instead of extension versions" {
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
    echo "FROM postgres:17" > Dockerfile

    # With yq: precise per-extension hash
    run compute_build_digest "Dockerfile" "vector"
    [ "$status" -eq 0 ]
    local digest_with_yq="$output"

    # Without yq: falls back to raw flavor file only (no extension extraction)
    _run_without_yq "Dockerfile" "vector"
    [ "$status" -eq 0 ]
    local digest_without_yq="$output"

    # Digests should differ (different inputs collected)
    [ "$digest_with_yq" != "$digest_without_yq" ]

    # Without yq: extension bump should NOT change digest (can't extract versions)
    local digest_before="$digest_without_yq"
    cat > extensions/config.yaml <<'EOF'
extensions:
  pgvector:
    version: "0.9.0"
EOF
    _run_without_yq "Dockerfile" "vector"
    local digest_after="$output"

    # Unchanged — fallback doesn't parse extensions
    [ "$digest_before" == "$digest_after" ]
}

@test "F-004b: yq fallback — terraform variant uses raw variants.yaml content" {
    cat > variants.yaml <<'EOF'
versions:
  - variants:
      - name: aws
        flavor: aws
        build_args_include:
          - AWS_CLI_VERSION
EOF
    cat > config.yaml <<'EOF'
build_args:
  AWS_CLI_VERSION: "1.44.29"
EOF
    echo "FROM alpine" > Dockerfile

    # With yq: per-arg hash
    run compute_build_digest "Dockerfile" "aws"
    [ "$status" -eq 0 ]
    local digest_with_yq="$output"

    # Without yq: raw variants.yaml fallback
    _run_without_yq "Dockerfile" "aws"
    [ "$status" -eq 0 ]
    local digest_without_yq="$output"

    # Different (different input collection method)
    [ "$digest_with_yq" != "$digest_without_yq" ]
}

@test "F-004c: yq fallback — simple container uses raw config.yaml content" {
    cat > config.yaml <<'EOF'
build_args:
  FOO: "1.0"
EOF
    echo "FROM alpine" > Dockerfile

    # With yq
    run compute_build_digest "Dockerfile" ""
    local digest_with_yq="$output"

    # Without yq
    _run_without_yq "Dockerfile" ""
    local digest_without_yq="$output"

    # Different (structured vs raw)
    [ "$digest_with_yq" != "$digest_without_yq" ]
}

@test "F-004d: yq fallback — still produces valid 12-char hex digest" {
    echo "FROM alpine" > Dockerfile

    _run_without_yq "Dockerfile" ""
    [ "$status" -eq 0 ]

    # Extract just the hash (last line, ignoring warnings)
    local digest
    digest=$(echo "$output" | tail -1)
    [ "${#digest}" -eq 12 ]
    [[ "$digest" =~ ^[0-9a-f]{12}$ ]]
}

# --- Integration Smoke Tests (F-005) ---

@test "F-005a: integration — postgres real flavors produce different digests" {
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

@test "F-005b: integration — terraform real flavors produce different digests" {
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

@test "F-005c: integration — simple container (ansible) produces valid digest" {
    cd "$ORIG_DIR/ansible" || skip "ansible directory not found"

    run compute_build_digest "Dockerfile" ""
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9a-f]{12}$ ]]
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
