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

@test "container with no config.yaml returns valid 64-char hex digest" {
    echo "FROM alpine" > Dockerfile

    run compute_build_digest "Dockerfile" ""
    [ "$status" -eq 0 ]
    local d1="$output"

    # Valid full SHA-256 hex digest
    [ "${#d1}" -eq 64 ]
    [[ "$d1" =~ ^[0-9a-f]{64}$ ]]

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

@test "distinct Dockerfile and build-arg boundaries produce different digests" {
    cat > Dockerfile <<'EOF'
FROM alpine
EOF
    cat > config.yaml <<'EOF'
build_args:
  PG_MAJOR: "18"
EOF
    run compute_build_digest "Dockerfile" ""
    [ "$status" -eq 0 ]
    local split_input_digest="$output"

    cat > Dockerfile <<'EOF'
FROM alpine
PG_MAJOR=18
EOF
    cat > config.yaml <<'EOF'
build_args: {}
EOF
    run compute_build_digest "Dockerfile" ""
    [ "$status" -eq 0 ]

    [ "$split_input_digest" != "$output" ]
}

@test "NUL record framing cannot be spelled by Dockerfile content" {
    cat > Dockerfile <<'EOF'
FROM alpine
EOF
    cat > config.yaml <<'EOF'
build_args:
  PG_MAJOR: "18"
EOF
    run compute_build_digest "Dockerfile" ""
    [ "$status" -eq 0 ]
    local separate_record_digest="$output"

    cat > Dockerfile <<'EOF'
FROM alpine
BUILD_ARG
PG_MAJOR
18
EOF
    cat > config.yaml <<'EOF'
build_args: {}
EOF
    run compute_build_digest "Dockerfile" ""
    [ "$status" -eq 0 ]

    [ "$separate_record_digest" != "$output" ]
}

@test "build-arg pair boundaries are distinct from newlines in a value" {
    echo "FROM alpine" > Dockerfile
    cat > config.yaml <<'EOF'
build_args:
  A: |-
    1
    B=2
EOF
    run compute_build_digest "Dockerfile" ""
    [ "$status" -eq 0 ]
    local one_pair_digest="$output"

    cat > config.yaml <<'EOF'
build_args:
  A: "1"
  B: "2"
EOF
    run compute_build_digest "Dockerfile" ""
    [ "$status" -eq 0 ]

    [ "$one_pair_digest" != "$output" ]
}

@test "template render config and arguments are digest inputs" {
    cat > Dockerfile <<'EOF'
FROM alpine
# @@PACKAGES@@
EOF
    cat > config.yaml <<'EOF'
flavors:
  base:
    packages:
      apt: [curl]
  dev:
    packages:
      apt: [curl, git]
distros:
  ubuntu-2404:
    packages:
      core: [ca-certificates]
EOF
    echo '# renderer v1' > generate-dockerfile.sh

    run compute_build_digest "Dockerfile" "" "config.yaml" "ubuntu-2404" "base" "1.0.0" "generate-dockerfile.sh"
    [ "$status" -eq 0 ]
    local initial="$output"

    sed -i 's/\[curl\]/[curl, jq]/' config.yaml
    run compute_build_digest "Dockerfile" "" "config.yaml" "ubuntu-2404" "base" "1.0.0" "generate-dockerfile.sh"
    [ "$status" -eq 0 ]
    [ "$initial" != "$output" ]
    initial="$output"

    sed -i 's/ca-certificates/ca-certificates, tzdata/' config.yaml
    run compute_build_digest "Dockerfile" "" "config.yaml" "ubuntu-2404" "base" "1.0.0" "generate-dockerfile.sh"
    [ "$status" -eq 0 ]
    [ "$initial" != "$output" ]
    initial="$output"

    run compute_build_digest "Dockerfile" "" "config.yaml" "debian-12" "base" "1.0.0" "generate-dockerfile.sh"
    [ "$status" -eq 0 ]
    [ "$initial" != "$output" ]
    initial="$output"

    run compute_build_digest "Dockerfile" "" "config.yaml" "debian-12" "dev" "1.0.0" "generate-dockerfile.sh"
    [ "$status" -eq 0 ]
    [ "$initial" != "$output" ]
}

@test "generic renderer version changes the digest even when the tag is unchanged" {
    echo 'FROM scratch' > Dockerfile
    echo '# renderer' > generate-dockerfile.sh
    cat > config.yaml <<'EOF'
distros:
  base: {}
EOF

    run compute_build_digest "Dockerfile" "base" "config.yaml" "base" "base" "1.0.0" "generate-dockerfile.sh"
    [ "$status" -eq 0 ]
    local first="$output"

    # The caller's tag is intentionally absent from this API: only version changes.
    run compute_build_digest "Dockerfile" "base" "config.yaml" "base" "base" "2.0.0" "generate-dockerfile.sh"
    [ "$status" -eq 0 ]
    [ "$first" != "$output" ]
}

@test "render digest serialization pins the surviving renderer arguments" {
    echo 'FROM scratch' > Dockerfile
    echo '# renderer' > generate-dockerfile.sh
    cat > config.yaml <<'EOF'
distros:
  base: {}
EOF

    run compute_build_digest "Dockerfile" "base" "config.yaml" "base" "base" "1.0.0" "generate-dockerfile.sh"
    [ "$status" -eq 0 ]
    # Regenerated after removing the orphaned pg_major render-argument record.
    [ "$output" = "bb1d18b414823277ea5439be690e17cb831e77456cd1c86462127ba8d69c9efe" ]
}

@test "github-runner and web-shell generator-consumed package edits change digests" {
    mkdir github-runner web-shell
    cp "$ORIG_DIR/github-runner/Dockerfile.linux" "$ORIG_DIR/github-runner/config.yaml" github-runner/
    cp "$ORIG_DIR/web-shell/Dockerfile" "$ORIG_DIR/web-shell/config.yaml" web-shell/

    cd github-runner
    run compute_build_digest \
        "Dockerfile.linux" "ubuntu-2404" "config.yaml" "ubuntu-2404" "base" "1.0.0" \
        "$ORIG_DIR/github-runner/generate-dockerfile.sh" \
        "$ORIG_DIR/helpers/logging.sh" "$ORIG_DIR/helpers/template-utils.sh" \
        "$ORIG_DIR/helpers/generate-utils.sh" "$ORIG_DIR/helpers/collect-lines.sh"
    [ "$status" -eq 0 ]
    local github_runner_before="$output"
    yq -i '.flavors.base.packages.apt += ["digest-test"]' config.yaml
    run compute_build_digest \
        "Dockerfile.linux" "ubuntu-2404" "config.yaml" "ubuntu-2404" "base" "1.0.0" \
        "$ORIG_DIR/github-runner/generate-dockerfile.sh" \
        "$ORIG_DIR/helpers/logging.sh" "$ORIG_DIR/helpers/template-utils.sh" \
        "$ORIG_DIR/helpers/generate-utils.sh" "$ORIG_DIR/helpers/collect-lines.sh"
    [ "$status" -eq 0 ]
    [ "$github_runner_before" != "$output" ]

    cd "$TEST_DIR/web-shell"
    run compute_build_digest \
        "Dockerfile" "ubuntu" "config.yaml" "ubuntu" "" "1.0.0" \
        "$ORIG_DIR/web-shell/generate-dockerfile.sh" \
        "$ORIG_DIR/helpers/logging.sh" "$ORIG_DIR/helpers/template-utils.sh" \
        "$ORIG_DIR/helpers/generate-utils.sh"
    [ "$status" -eq 0 ]
    local web_shell_before="$output"
    yq -i '.distros.ubuntu.packages.core += ["digest-test"]' config.yaml
    run compute_build_digest \
        "Dockerfile" "ubuntu" "config.yaml" "ubuntu" "" "1.0.0" \
        "$ORIG_DIR/web-shell/generate-dockerfile.sh" \
        "$ORIG_DIR/helpers/logging.sh" "$ORIG_DIR/helpers/template-utils.sh" \
        "$ORIG_DIR/helpers/generate-utils.sh"
    [ "$status" -eq 0 ]
    [ "$web_shell_before" != "$output" ]
}

@test "marker-free containers ignore unrelated config metadata" {
    echo "FROM alpine" > Dockerfile
    cat > config.yaml <<'EOF'
build_args:
  FOO: "1"
metadata:
  owner: one
EOF
    run compute_build_digest "Dockerfile" ""
    [ "$status" -eq 0 ]
    local initial="$output"

    sed -i 's/owner: one/owner: two/' config.yaml
    run compute_build_digest "Dockerfile" ""
    [ "$status" -eq 0 ]
    [ "$initial" = "$output" ]
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

@test "should_skip_build returns 2 and unsets BUILD_DIGEST when digest computation fails" {
    compute_build_digest() { return 17; }

    local force_rebuild
    for force_rebuild in false true; do
        BUILD_DIGEST="stale"
        if should_skip_build "example.invalid/image:tag" "Dockerfile" "" "$force_rebuild"; then
            local status=0
        else
            local status=$?
        fi

        [ "$status" -eq 2 ]
        [ -z "${BUILD_DIGEST+x}" ]
    done
}

@test "digest serialization pins postgres and terraform v2 framing digests" {
    # Regenerated for the digest-v2 NUL framing.  These fixtures deliberately
    # make future unintended source-input or serialization churn visible.
    local -a cases=(
        "postgres analytics f2888b5fcc8855fdbbcf43234129d7d79106950583f395c0fc9b6805164efa8d"
        "postgres base 3ff1636477694c9b56a25c804e1344539608ade4f7f5b35921120e8c4bb49c8b"
        "postgres distributed 3c114c2da79825836a3ecf7f11840a7d98a74ddc2c6ab7eea70f2e6158c75dd7"
        "postgres full 5d89e824004b98a03398fc697911dd4e00624c3ac4a7c049d46f1a2841f378f2"
        "postgres spatial 9ad4cf857bbf8d133e192b5621a83c1058ce19c39225698b50d9b5361d36311e"
        "postgres timeseries 3218f2f26e28ae3e9a2f29b8fe19b9166e976f79f660276445b78a1853e39ca3"
        "postgres vector 3126729d1d1ea68d77cc88983d77174e8dd9c412207d55ec5780c12db9002687"
        "terraform aws 5411c51096e76b86e6a4777f510cd46ccddc0ab596a6a6cbf75bcf23c8f042b8"
        "terraform azure f6a6f94428c46da0c51447fe94dae9aed858f5c3895a2594cc7452ff71445daf"
        "terraform base efba7431da23fb1b4265b4cf8635d6066a4c15f23c54bf6a9cbebb82aebd821d"
        "terraform full 5dd621e3c4663b9501dcc021049d58d64cb1562d77492578cb0c336531748db0"
        "terraform gcp 1baf4b01fdfca4d4b3b4c896a2d81efe7f9cf6337db990cac8a983b31093f937"
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
        [[ "$output" =~ ^[0-9a-f]{64}$ ]]
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
        [[ "$output" =~ ^[0-9a-f]{64}$ ]]
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
    [[ "$output" =~ ^[0-9a-f]{64}$ ]]
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
# Regression guard: modifying LAST_REBUILD.md must change the digest, so that
# should_skip_build returns false after a drift PR modifies the file.
# Without this fix, smart-skip would match the pre-PR digest and skip the
# rebuild, leaving base digest unchanged → infinite drift-PR loop.
# ---------------------------------------------------------------------------

@test "LAST_REBUILD.md absent — digest is stable (baseline)" {
    echo "FROM alpine:3.21" > Dockerfile

    run compute_build_digest "Dockerfile" ""
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9a-f]{64}$ ]]
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
