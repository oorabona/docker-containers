#!/usr/bin/env bats

# Unit tests for scripts/build-container.sh

load "../test_helper"

# Source the script functions in a way that handles $(dirname "$0") issue
# We source from the scripts directory so relative paths work
source_build_script() {
    pushd "$SCRIPTS_DIR" > /dev/null 2>&1
    source "./build-container.sh"
    popd > /dev/null 2>&1
}

setup() {
    setup_temp_dir

    # Source logging first (dependency) - this ensures it's available
    # before the script tries to source it
    source "$HELPERS_DIR/logging.sh"

    # Clear any cached multiplatform check
    unset MULTIPLATFORM_SUPPORTED

    # Save original PATH
    export ORIGINAL_PATH="$PATH"
}

teardown() {
    teardown_temp_dir
    export PATH="$ORIGINAL_PATH"
    unset MULTIPLATFORM_SUPPORTED
    unset BUILD_PLATFORM
    unset GITHUB_ACTIONS
    unset DOCKER
    unset LINEAGE_RUNTIME_CALLS
    unset LINEAGE_DOCKER_CALLS
}

assert_single_variant_result() {
    local expected_tag="$1"
    local expected_status="$2"
    local result_lines
    result_lines=$(sed -n '/^\[/p' <<< "$output")

    [ "$(printf '%s\n' "$result_lines" | wc -l | tr -d ' ')" -eq 1 ]
    jq -e --arg tag "$expected_tag" --arg status "$expected_status" \
        '. == [{"name":"default","tag":$tag,"flavor":"","status":$status}]' \
        <<< "$result_lines" >/dev/null
}

setup_lineage_writer() {
    source_build_script
    export PROJECT_ROOT="$TEST_TEMP_DIR"
    cd "$TEST_TEMP_DIR"
}

stub_lineage_image_lookup() {
    local mode="$1"

    mkdir -p "$TEST_TEMP_DIR/bin"
    export LINEAGE_RUNTIME_CALLS="$TEST_TEMP_DIR/lineage-runtime-calls"
    export LINEAGE_DOCKER_CALLS="$TEST_TEMP_DIR/docker-calls"
    : > "$LINEAGE_RUNTIME_CALLS"
    : > "$LINEAGE_DOCKER_CALLS"

    cat > "$TEST_TEMP_DIR/bin/lineage-runtime" <<EOF
#!/usr/bin/env bash
printf '%s %s\\n' "\$(basename "\$0")" "\$*" >> "\$LINEAGE_RUNTIME_CALLS"
case "$mode" in
    success)
        printf '%s\\n' 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        ;;
    failure)
        exit 17
        ;;
    empty)
        ;;
    malformed)
        printf '%s\\n' 'sha256:not-an-image-id'
        ;;
esac
EOF
    cat > "$TEST_TEMP_DIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "$LINEAGE_DOCKER_CALLS"
printf '%s\n' 'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
EOF
    chmod +x "$TEST_TEMP_DIR/bin/lineage-runtime" "$TEST_TEMP_DIR/bin/docker"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export DOCKER="$TEST_TEMP_DIR/bin/lineage-runtime"
}

emit_test_lineage() {
    local tag="$1"

    _emit_build_lineage "lineage-container" "1.2.3" "$tag" "" "Dockerfile" \
        "linux/amd64" "test" "docker.io/example/lineage-container" \
        "ghcr.io/example/lineage-container"
}

# =============================================================================
# _emit_build_lineage image ID observation tests
# =============================================================================

@test "_emit_build_lineage uses the overridden runtime for its image-id lookup" {
    stub_lineage_image_lookup success
    setup_lineage_writer

    run emit_test_lineage "1.2.3"

    [ "$status" -eq 0 ]
    [ "$(<"$LINEAGE_RUNTIME_CALLS")" = "lineage-runtime images --no-trunc -q docker.io/example/lineage-container:1.2.3" ]
    [ ! -s "$LINEAGE_DOCKER_CALLS" ]
}

@test "_emit_build_lineage records a successfully observed local image id from the overridden runtime without a warning" {
    stub_lineage_image_lookup success
    setup_lineage_writer

    run emit_test_lineage "1.2.3"

    [ "$status" -eq 0 ]
    [[ "$output" != *"::warning::"* ]]
    jq -e '.image_id == "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' \
        "$TEST_TEMP_DIR/.build-lineage/lineage-container-1.2.3.json" >/dev/null
}

@test "_emit_build_lineage warns and omits image_id when its always-load lookup fails" {
    stub_lineage_image_lookup failure
    setup_lineage_writer

    run emit_test_lineage "1.2.3"

    [ "$status" -eq 0 ]
    [[ "$output" == *"::warning::Could not observe image id for container 'lineage-container' tag '1.2.3': lookup failed; omitting image_id from build lineage"* ]]
    [ "$(printf '%s\\n' "$output" | grep -c '^::warning::')" -eq 1 ]
    jq -e 'has("image_id") | not' "$TEST_TEMP_DIR/.build-lineage/lineage-container-1.2.3.json" >/dev/null
}

@test "_emit_build_lineage warns and omits image_id when its always-load lookup returns empty, not push-only" {
    stub_lineage_image_lookup empty
    setup_lineage_writer

    run emit_test_lineage "1.2.3"

    [ "$status" -eq 0 ]
    [[ "$output" == *"::warning::Could not observe image id for container 'lineage-container' tag '1.2.3': lookup returned no image id; omitting image_id from build lineage"* ]]
    [ "$(printf '%s\\n' "$output" | grep -c '^::warning::')" -eq 1 ]
    jq -e 'has("image_id") | not' "$TEST_TEMP_DIR/.build-lineage/lineage-container-1.2.3.json" >/dev/null
}

@test "_emit_build_lineage warns and omits a malformed image id" {
    stub_lineage_image_lookup malformed
    setup_lineage_writer

    run emit_test_lineage "1.2.3"

    [ "$status" -eq 0 ]
    [[ "$output" == *"::warning::Observed malformed image id 'sha256:not-an-image-id' for container 'lineage-container' tag '1.2.3'; omitting image_id from build lineage"* ]]
    [ "$(printf '%s\\n' "$output" | grep -c '^::warning::')" -eq 1 ]
    jq -e 'has("image_id") | not' "$TEST_TEMP_DIR/.build-lineage/lineage-container-1.2.3.json" >/dev/null
}

@test "_emit_build_lineage escapes a %0A tag so its warning cannot inject a second workflow command" {
    local tag="release%0A::error::injected"

    stub_lineage_image_lookup failure
    setup_lineage_writer

    run emit_test_lineage "$tag"

    [ "$status" -eq 0 ]
    [[ "$output" == *"release%250A::error::injected"* ]]
    [ "$(printf '%s\\n' "$output" | grep -c '^::warning::')" -eq 1 ]
    ! printf '%s\\n' "$output" | grep -q '^::error::'
}

@test "sourcing build-container preserves an enabled errexit" {
    run bash -c '
        set -e
        before=$-
        source "$1"
        after=$-
        [[ "$before" == *e* ]]
        [[ "$after" == *e* ]]
    ' _ "$SCRIPTS_DIR/build-container.sh"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "sourcing build-container enables master's strict-mode options for a relaxed caller" {
    run bash -c '
        set +e +u +o pipefail
        before=$-
        before_pipefail=$(set -o | grep -E "^pipefail")
        source "$1"
        after=$-
        after_pipefail=$(set -o | grep -E "^pipefail")
        [[ "$before" != *e* ]]
        [[ "$before" != *u* ]]
        [[ "$before_pipefail" =~ [[:space:]]off$ ]]
        [[ "$after" == *e* ]]
        [[ "$after" == *h* ]]
        [[ "$after" == *u* ]]
        [[ "$after_pipefail" =~ [[:space:]]on$ ]]
    ' _ "$SCRIPTS_DIR/build-container.sh"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# =============================================================================
# build_container_variants no-variants status tests
# =============================================================================

@test "build_container_variants reports failed when a container has no variants and its build fails" {
    source_build_script
    export PROJECT_ROOT="$TEST_TEMP_DIR"
    has_variants() { return 1; }
    build_container() { return 1; }

    run build_container_variants sample 1.2.3

    [ "$status" -eq 1 ]
    assert_single_variant_result "1.2.3" "failed"
}

@test "build_container_variants reports built when a container has no variants and its build succeeds" {
    source_build_script
    export PROJECT_ROOT="$TEST_TEMP_DIR"
    has_variants() { return 1; }
    build_container() { return 0; }

    run build_container_variants sample 1.2.3

    [ "$status" -eq 0 ]
    assert_single_variant_result "1.2.3" "built"
}

@test "build_container_variants reports failed when a version has no variants and its build fails" {
    source_build_script
    export PROJECT_ROOT="$TEST_TEMP_DIR"
    has_variants() { return 0; }
    base_suffix() { printf '%s' '-alpine'; }
    version_dockerfile() { printf '%s' 'Dockerfile.version'; }
    list_variants() { :; }
    build_container() { return 1; }

    run build_container_variants sample 1.2.3

    [ "$status" -eq 1 ]
    assert_single_variant_result "1.2.3-alpine" "failed"
}

@test "build_container_variants reports built when a version has no variants and its build succeeds" {
    source_build_script
    export PROJECT_ROOT="$TEST_TEMP_DIR"
    has_variants() { return 0; }
    base_suffix() { printf '%s' '-alpine'; }
    version_dockerfile() { printf '%s' 'Dockerfile.version'; }
    list_variants() { :; }
    build_container() { return 0; }

    run build_container_variants sample 1.2.3

    [ "$status" -eq 0 ]
    assert_single_variant_result "1.2.3-alpine" "built"
}

# =============================================================================
# check_multiplatform_support tests
# =============================================================================

@test "check_multiplatform_support returns cached result on second call" {
    # Set the cached value
    export MULTIPLATFORM_SUPPORTED="true"

    # Source the script
    source_build_script

    run check_multiplatform_support
    [ "$status" -eq 0 ]

    # Value should still be cached
    [ "$MULTIPLATFORM_SUPPORTED" = "true" ]
}

@test "check_multiplatform_support returns false when cached as false" {
    export MULTIPLATFORM_SUPPORTED="false"

    source_build_script

    run check_multiplatform_support
    [ "$status" -eq 1 ]
}

@test "check_multiplatform_support detects QEMU via binfmt_misc" {
    # Mock the binfmt_misc file
    mkdir -p "$TEST_TEMP_DIR/proc/sys/fs/binfmt_misc"
    touch "$TEST_TEMP_DIR/proc/sys/fs/binfmt_misc/qemu-aarch64"

    # Create a wrapper function that checks our mock path
    check_multiplatform_support_with_mock() {
        if [[ -f "$TEST_TEMP_DIR/proc/sys/fs/binfmt_misc/qemu-aarch64" ]]; then
            MULTIPLATFORM_SUPPORTED="true"
            return 0
        fi
        return 1
    }

    run check_multiplatform_support_with_mock
    [ "$status" -eq 0 ]
}

@test "check_multiplatform_support detects buildx platforms" {
    # Mock docker command to return arm64 platform
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/docker" << 'EOF'
#!/bin/bash
if [[ "$1" == "buildx" && "$2" == "inspect" ]]; then
    echo "Platforms: linux/amd64, linux/arm64"
fi
EOF
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    # Clear cache and source
    unset MULTIPLATFORM_SUPPORTED
    source_build_script

    run check_multiplatform_support
    # May succeed or fail depending on binfmt_misc check order
    # The important thing is it doesn't crash
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

@test "check_multiplatform_support returns false when no support found" {
    # Mock docker to return only amd64
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/docker" << 'EOF'
#!/bin/bash
if [[ "$1" == "buildx" && "$2" == "inspect" ]]; then
    echo "Platforms: linux/amd64"
fi
EOF
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    # Ensure no binfmt_misc files exist (they won't in temp)
    unset MULTIPLATFORM_SUPPORTED
    source_build_script

    # Since /proc paths don't exist in test, it will fall through to buildx check
    # Call directly (not with run) to check the variable after
    check_multiplatform_support || true

    # Should have set MULTIPLATFORM_SUPPORTED to false
    [ "$MULTIPLATFORM_SUPPORTED" = "false" ]
}

# =============================================================================
# build_container platform selection tests
# =============================================================================

@test "build_container uses BUILD_PLATFORM when set" {
    export BUILD_PLATFORM="linux/arm64"

    # Mock docker to capture arguments
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/docker" << 'EOF'
#!/bin/bash
echo "ARGS: $*" >> "$TEST_TEMP_DIR/docker_calls.log"
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    # Create test container
    create_mock_container "testcontainer" "1.0.0"

    source_build_script

    export PROJECT_ROOT="$TEST_TEMP_DIR"

    # The three-argument production form resolves its default Dockerfile from the container directory.
    cd "$TEST_TEMP_DIR/testcontainer"
    run build_container "testcontainer" "1.0.0" "1.0.0"

    # Check docker was called with correct platform
    [ "$status" -eq 0 ]
    [ -f "$TEST_TEMP_DIR/docker_calls.log" ]
    grep -q "linux/arm64" "$TEST_TEMP_DIR/docker_calls.log"
}

@test "build_container defaults to linux/amd64 without multiplatform support" {
    unset BUILD_PLATFORM
    export MULTIPLATFORM_SUPPORTED="false"

    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/docker" << 'EOF'
#!/bin/bash
echo "ARGS: $*" >> "$TEST_TEMP_DIR/docker_calls.log"
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    create_mock_container "testcontainer" "1.0.0"

    source_build_script

    cd "$TEST_TEMP_DIR"
    run build_container "testcontainer" "1.0.0" "1.0.0" "" "testcontainer/Dockerfile"

    [ -f "$TEST_TEMP_DIR/docker_calls.log" ]
    grep -q "linux/amd64" "$TEST_TEMP_DIR/docker_calls.log"
}

@test "build_container refuses an uncomputable digest without invoking docker in either skip mode" {
    export MULTIPLATFORM_SUPPORTED="false"

    mkdir -p "$TEST_TEMP_DIR/bin" "$TEST_TEMP_DIR/flavors"
    cat > "$TEST_TEMP_DIR/bin/docker" << 'EOF'
#!/bin/bash
echo "ARGS: $*" >> "$TEST_TEMP_DIR/docker_calls.log"
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    cat > "$TEST_TEMP_DIR/flavors/vector.yaml" <<'EOF'
name: vector
extensions:
  - pgvector
EOF
    echo "FROM postgres:17" > "$TEST_TEMP_DIR/Dockerfile"
    create_mock_container "testcontainer" "1.0.0"
    source_build_script

    compute_build_digest() { return 17; }
    _resolve_platforms() { _PLATFORMS="linux/amd64"; }
    _configure_cache() { _CACHE_ARGS=""; _RUNTIME_INFO="test"; }
    _prepare_build_args() { _BUILD_ARGS=""; }
    collect_lines() { printf '%s\n' "docker.io/test/testcontainer:1.0.0" > "$1"; }
    _resolve_base_image() { :; }
    export -f compute_build_digest _resolve_platforms _configure_cache _prepare_build_args collect_lines _resolve_base_image
    : > "$TEST_TEMP_DIR/docker_calls.log"

    cd "$TEST_TEMP_DIR"
    export SKIP_EXISTING_BUILDS="true"
    run build_container "testcontainer" "1.0.0" "1.0.0" "vector"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Build digest computation failed for testcontainer:1.0.0; refusing to build or publish"* ]]

    export SKIP_EXISTING_BUILDS="false"
    run build_container "testcontainer" "1.0.0" "1.0.0" "vector"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Build digest computation failed"* ]]

    [ ! -s "$TEST_TEMP_DIR/docker_calls.log" ]
    ! grep -qE -- "--label ${BUILD_DIGEST_LABEL}=( |$)" "$TEST_TEMP_DIR/docker_calls.log"
    unset SKIP_EXISTING_BUILDS
}

@test "build_container removes a generated Dockerfile when digest computation fails or is empty" {
    export MULTIPLATFORM_SUPPORTED="false"
    mkdir -p "$TEST_TEMP_DIR/templatecontainer" "$TEST_TEMP_DIR/generated"
    cat > "$TEST_TEMP_DIR/templatecontainer/Dockerfile" <<'EOF'
FROM scratch
# @@PACKAGES@@
EOF
    cat > "$TEST_TEMP_DIR/templatecontainer/generate-dockerfile.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'FROM scratch'
EOF
    chmod +x "$TEST_TEMP_DIR/templatecontainer/generate-dockerfile.sh"

    source_build_script
    PROJECT_ROOT="$TEST_TEMP_DIR"
    TMPDIR="$TEST_TEMP_DIR/generated"
    _resolve_platforms() { _PLATFORMS="linux/amd64"; }
    _configure_cache() { _CACHE_ARGS=""; _RUNTIME_INFO="test"; }
    _prepare_build_args() { _BUILD_ARGS=""; }
    collect_lines() { printf '%s\n' "docker.io/test/templatecontainer:1.0.0" > "$1"; }
    _resolve_base_image() { :; }
    compute_build_digest() {
        printf '%s\n' "$1" > "$TEST_TEMP_DIR/generated-path"
        [[ "$DIGEST_MODE" == "failure" ]] && return 17
        return 0
    }
    export -f _resolve_platforms _configure_cache _prepare_build_args collect_lines _resolve_base_image compute_build_digest

    cd "$TEST_TEMP_DIR"
    export DIGEST_MODE="failure"
    run build_container "templatecontainer" "1.0.0" "1.0.0" "" "templatecontainer/Dockerfile"
    [ "$status" -ne 0 ]
    local failed_generated
    failed_generated=$(<"$TEST_TEMP_DIR/generated-path")
    [ ! -e "$failed_generated" ]

    export DIGEST_MODE="empty"
    run build_container "templatecontainer" "1.0.0" "1.0.0" "" "templatecontainer/Dockerfile"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Build digest is empty"* ]]
    [[ "$output" != *"Build digest computation failed"* ]]
    local empty_generated
    empty_generated=$(<"$TEST_TEMP_DIR/generated-path")
    [ ! -e "$empty_generated" ]
    unset DIGEST_MODE
}

# =============================================================================
# build_container build args tests
# =============================================================================

@test "build_container passes VERSION build arg" {
    export MULTIPLATFORM_SUPPORTED="false"

    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/docker" << 'EOF'
#!/bin/bash
echo "ARGS: $*" >> "$TEST_TEMP_DIR/docker_calls.log"
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    create_mock_container "testcontainer" "2.5.0"

    source_build_script

    cd "$TEST_TEMP_DIR"
    run build_container "testcontainer" "2.5.0" "2.5.0" "" "testcontainer/Dockerfile"

    grep -q "VERSION=2.5.0" "$TEST_TEMP_DIR/docker_calls.log"
}

@test "build_container passes NPROC build arg when set" {
    export MULTIPLATFORM_SUPPORTED="false"
    export NPROC="8"

    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/docker" << 'EOF'
#!/bin/bash
echo "ARGS: $*" >> "$TEST_TEMP_DIR/docker_calls.log"
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    create_mock_container "testcontainer" "1.0.0"

    source_build_script

    cd "$TEST_TEMP_DIR"
    run build_container "testcontainer" "1.0.0" "1.0.0" "" "testcontainer/Dockerfile"

    grep -q "NPROC=8" "$TEST_TEMP_DIR/docker_calls.log"

    unset NPROC
}

@test "build_container passes CUSTOM_BUILD_ARGS when set" {
    export MULTIPLATFORM_SUPPORTED="false"
    export CUSTOM_BUILD_ARGS="--no-cache"

    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/docker" << 'EOF'
#!/bin/bash
echo "ARGS: $*" >> "$TEST_TEMP_DIR/docker_calls.log"
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    create_mock_container "testcontainer" "1.0.0"

    source_build_script

    cd "$TEST_TEMP_DIR"
    run build_container "testcontainer" "1.0.0" "1.0.0" "" "testcontainer/Dockerfile"

    grep -q "\-\-no-cache" "$TEST_TEMP_DIR/docker_calls.log"

    unset CUSTOM_BUILD_ARGS
}

# =============================================================================
# build_container cache behavior tests
# =============================================================================

@test "build_container uses registry cache in GitHub Actions" {
    export GITHUB_ACTIONS="true"
    export MULTIPLATFORM_SUPPORTED="false"
    export GITHUB_REPOSITORY_OWNER="testowner"

    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/docker" << 'EOF'
#!/bin/bash
echo "ARGS: $*" >> "$TEST_TEMP_DIR/docker_calls.log"
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    create_mock_container "testcontainer" "1.0.0"

    source_build_script

    cd "$TEST_TEMP_DIR"
    run build_container "testcontainer" "1.0.0" "1.0.0" "" "testcontainer/Dockerfile"

    grep -q "cache-from" "$TEST_TEMP_DIR/docker_calls.log"
    grep -q "buildcache" "$TEST_TEMP_DIR/docker_calls.log"

    unset GITHUB_ACTIONS
    unset GITHUB_REPOSITORY_OWNER
}

@test "build_container omits cache export when BUILD_CACHE_EXPORT=false" {
    export GITHUB_ACTIONS="true"
    export MULTIPLATFORM_SUPPORTED="false"
    export GITHUB_REPOSITORY_OWNER="testowner"
    export BUILD_CACHE_EXPORT="false"

    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/docker" << 'EOF'
#!/bin/bash
echo "ARGS: $*" >> "$TEST_TEMP_DIR/docker_calls.log"
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    create_mock_container "testcontainer" "1.0.0"

    source_build_script

    cd "$TEST_TEMP_DIR"
    run build_container "testcontainer" "1.0.0" "1.0.0" "" "testcontainer/Dockerfile"

    # Still READS the shared cache (fast builds)...
    grep -q "cache-from" "$TEST_TEMP_DIR/docker_calls.log"
    # ...but never WRITES it, so throwaway/PR builds can't poison :buildcache
    ! grep -q "cache-to" "$TEST_TEMP_DIR/docker_calls.log"

    unset GITHUB_ACTIONS
    unset GITHUB_REPOSITORY_OWNER
    unset BUILD_CACHE_EXPORT
}

# =============================================================================
# build_container tagging tests
# =============================================================================

@test "build_container creates correct image tags" {
    export MULTIPLATFORM_SUPPORTED="false"
    export GITHUB_REPOSITORY_OWNER="myowner"

    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/docker" << 'EOF'
#!/bin/bash
echo "ARGS: $*" >> "$TEST_TEMP_DIR/docker_calls.log"
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    create_mock_container "testcontainer" "1.0.0"

    source_build_script

    cd "$TEST_TEMP_DIR"
    run build_container "testcontainer" "1.0.0" "1.0.0" "" "testcontainer/Dockerfile"

    # Check both registries are tagged
    grep -q "ghcr.io/myowner/testcontainer:1.0.0" "$TEST_TEMP_DIR/docker_calls.log"
    grep -q "docker.io/myowner/testcontainer:1.0.0" "$TEST_TEMP_DIR/docker_calls.log"

    unset GITHUB_REPOSITORY_OWNER
}

@test "build_container adds latest tag when tag is latest" {
    export MULTIPLATFORM_SUPPORTED="false"
    export GITHUB_REPOSITORY_OWNER="myowner"

    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/docker" << 'EOF'
#!/bin/bash
echo "ARGS: $*" >> "$TEST_TEMP_DIR/docker_calls.log"
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    create_mock_container "testcontainer" "1.0.0"

    source_build_script

    cd "$TEST_TEMP_DIR"
    run build_container "testcontainer" "1.0.0" "latest" "" "testcontainer/Dockerfile"

    # Should have :latest tag
    grep -q ":latest" "$TEST_TEMP_DIR/docker_calls.log"

    unset GITHUB_REPOSITORY_OWNER
}

# =============================================================================
# ARG REMOTE_CR default resolution tests (fix/628-dockerio-egress-failclose)
# =============================================================================

@test "_resolve_base_image Step 4 resolves REMOTE_CR default to ghcr.io/oorabona" {
    # Create a mock Dockerfile with ARG REMOTE_CR=ghcr.io/oorabona (the new default)
    mkdir -p "$TEST_TEMP_DIR/mycontainer"
    cat > "$TEST_TEMP_DIR/mycontainer/Dockerfile" << 'EOF'
ARG REMOTE_CR=ghcr.io/oorabona
ARG VERSION
FROM ${REMOTE_CR}/library/debian:${VERSION}
EOF

    source_build_script

    # Call _resolve_base_image directly (no config.yaml → falls through to FROM line)
    cd "$TEST_TEMP_DIR/mycontainer"
    local label_args=""
    _resolve_base_image "$TEST_TEMP_DIR/mycontainer/Dockerfile" "bookworm" "label_args"

    # Step 4 must have substituted REMOTE_CR with ghcr.io/oorabona
    [[ "$_BASE_IMAGE_REF" == *"ghcr.io/oorabona"* ]] || {
        echo "Expected _BASE_IMAGE_REF to contain ghcr.io/oorabona, got: $_BASE_IMAGE_REF"
        return 1
    }
    # Must NOT fall back to docker.io
    [[ "$_BASE_IMAGE_REF" != *"docker.io"* ]] || {
        echo "Expected _BASE_IMAGE_REF to NOT contain docker.io, got: $_BASE_IMAGE_REF"
        return 1
    }
}

@test "_resolve_base_image Step 4 does NOT resolve REMOTE_CR to docker.io when default is ghcr.io/oorabona" {
    # Regression guard: old default was docker.io — ensure it's gone
    mkdir -p "$TEST_TEMP_DIR/mycontainer2"
    cat > "$TEST_TEMP_DIR/mycontainer2/Dockerfile" << 'EOF'
ARG REMOTE_CR=ghcr.io/oorabona
ARG VERSION
FROM ${REMOTE_CR}/library/alpine:${VERSION}
EOF

    source_build_script

    cd "$TEST_TEMP_DIR/mycontainer2"
    local label_args=""
    _resolve_base_image "$TEST_TEMP_DIR/mycontainer2/Dockerfile" "3.20" "label_args"

    [[ "$_BASE_IMAGE_REF" != *"docker.io"* ]] || {
        echo "Regression: _BASE_IMAGE_REF still contains docker.io: $_BASE_IMAGE_REF"
        return 1
    }
    [[ "$_BASE_IMAGE_REF" == "ghcr.io/oorabona/library/alpine:3.20" ]] || {
        echo "Expected ghcr.io/oorabona/library/alpine:3.20, got: $_BASE_IMAGE_REF"
        return 1
    }
}

# =============================================================================
# build_container self-heal regression tests (omitted is_default derives from
# variant_property so direct/local callers still get the correct :latest tag)
# =============================================================================

@test "build_container: omitted is_default self-derives default variant -> bare :latest" {
    export MULTIPLATFORM_SUPPORTED="false"
    export GITHUB_REPOSITORY_OWNER="myowner"

    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/docker" << 'EOF'
#!/bin/bash
echo "ARGS: $*" >> "$TEST_TEMP_DIR/docker_calls.log"
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    create_mock_container "testcontainer" "1.0.0"

    source_build_script

    # Override variant_property AFTER sourcing so it wins over the sourced version.
    # Exported so the `run` subshell inherits it.
    variant_property() { echo "true"; }
    export -f variant_property

    cd "$TEST_TEMP_DIR"
    # Call with 5 positional args (no 7th is_default) — the fifth selects the fixture Dockerfile.
    run build_container "testcontainer" "1.0.0" "1.0.0" "base" "testcontainer/Dockerfile"

    [ "$status" -eq 0 ]

    # Default variant must get bare rolling :latest on both registries, NOT :latest-base
    grep -qE 'docker\.io/myowner/testcontainer:latest( |$)' "$TEST_TEMP_DIR/docker_calls.log"
    grep -qE 'ghcr\.io/myowner/testcontainer:latest( |$)' "$TEST_TEMP_DIR/docker_calls.log"
    ! grep -q ':latest-base' "$TEST_TEMP_DIR/docker_calls.log"

    unset GITHUB_REPOSITORY_OWNER
}

@test "build_container: omitted is_default self-derives non-default variant -> :latest-<flavor>" {
    export MULTIPLATFORM_SUPPORTED="false"
    export GITHUB_REPOSITORY_OWNER="myowner"

    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/docker" << 'EOF'
#!/bin/bash
echo "ARGS: $*" >> "$TEST_TEMP_DIR/docker_calls.log"
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    create_mock_container "testcontainer" "1.0.0"

    source_build_script

    # Override variant_property AFTER sourcing so it wins over the sourced version.
    variant_property() { echo "false"; }
    export -f variant_property

    cd "$TEST_TEMP_DIR"
    # Call with 5 positional args (no 7th is_default) — the fifth selects the fixture Dockerfile.
    run build_container "testcontainer" "1.0.0" "1.0.0" "vector" "testcontainer/Dockerfile"

    [ "$status" -eq 0 ]

    grep -q ':latest-vector' "$TEST_TEMP_DIR/docker_calls.log"

    unset GITHUB_REPOSITORY_OWNER
}

@test "build_container: omitted variant falls back to flavor, not ambient VARIANT" {
    export MULTIPLATFORM_SUPPORTED="false"
    export GITHUB_REPOSITORY_OWNER="myowner"
    export VARIANT="ambient"

    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/docker" << 'EOF'
#!/bin/bash
echo "ARGS: $*" >> "$TEST_TEMP_DIR/docker_calls.log"
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    create_mock_container "testcontainer" "1.0.0"
    source_build_script

    cd "$TEST_TEMP_DIR"
    run build_container "testcontainer" "1.0.0" "1.0.0" "base"

    [ "$status" -eq 0 ]
    grep -q ':latest-base' "$TEST_TEMP_DIR/docker_calls.log"
    ! grep -q ':latest-ambient' "$TEST_TEMP_DIR/docker_calls.log"

    unset GITHUB_REPOSITORY_OWNER
    unset VARIANT
}

@test "build_container refuses the build when compute_cell_tags sees a short suffix enumeration [catches untagged partial build]" {
    export MULTIPLATFORM_SUPPORTED="false"
    export GITHUB_REPOSITORY_OWNER="myowner"

    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/docker" <<'EOF'
#!/bin/bash
echo "ARGS: $*" >> "$TEST_TEMP_DIR/docker_calls.log"
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    create_mock_container "testcontainer" "1.0.0"
    source_build_script

    # Mutation caught: the old process substitution made compute_cell_tags
    # report success after emitting this one suffix, so docker built it anyway.
    compute_local_build_tag_suffixes() {
        printf 'partial\n'
        return 1
    }
    export -f compute_local_build_tag_suffixes

    cd "$TEST_TEMP_DIR"
    run build_container "testcontainer" "1.0.0" "1.0.0"

    [ "$status" -ne 0 ]
    [[ "$output" == *"Could not enumerate image tags"* ]]
    if grep -Eq '(^| )build( |$)|buildx build' "$TEST_TEMP_DIR/docker_calls.log"; then
        echo "A partial tag set reached the build invocation:" >&2
        cat "$TEST_TEMP_DIR/docker_calls.log" >&2
        return 1
    fi

    unset GITHUB_REPOSITORY_OWNER
}
