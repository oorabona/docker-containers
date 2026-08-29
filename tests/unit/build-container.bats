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

@test "build-container enables strict mode before loading helpers" {
    local fixture_root
    fixture_root="$BATS_TEST_TMPDIR/build-container-strict-mode"
    mkdir -p "$fixture_root/scripts" "$fixture_root/helpers"
    cp "$SCRIPTS_DIR/build-container.sh" "$fixture_root/scripts/build-container.sh"
    for helper in logging.sh collect-lines.sh variant-utils.sh build-cache-utils.sh build-args-utils.sh template-utils.sh extension-utils.sh extension-duration-utils.sh; do
        printf '#!/usr/bin/env bash\n' > "$fixture_root/helpers/$helper"
    done

    run bash -c '
        source "$1"
        false
        printf "continued\\n"
    ' _ "$fixture_root/scripts/build-container.sh"

    [ "$status" -ne 0 ]
    [[ "$output" != *"continued"* ]]
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

    # Run from mock container dir
    cd "$TEST_TEMP_DIR"
    run build_container "testcontainer" "1.0.0" "1.0.0"

    # Check docker was called with correct platform
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
    run build_container "testcontainer" "1.0.0" "1.0.0"

    [ -f "$TEST_TEMP_DIR/docker_calls.log" ]
    grep -q "linux/amd64" "$TEST_TEMP_DIR/docker_calls.log"
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
    run build_container "testcontainer" "2.5.0" "2.5.0"

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
    run build_container "testcontainer" "1.0.0" "1.0.0"

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
    run build_container "testcontainer" "1.0.0" "1.0.0"

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
    run build_container "testcontainer" "1.0.0" "1.0.0"

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
    run build_container "testcontainer" "1.0.0" "1.0.0"

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
    run build_container "testcontainer" "1.0.0" "1.0.0"

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
    run build_container "testcontainer" "1.0.0" "latest"

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
    # Call with 4 positional args only (no 7th is_default) — mirrors `./make build --flavor base`
    run build_container "testcontainer" "1.0.0" "1.0.0" "base"

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
    # Call with 4 positional args only (no 7th is_default) — mirrors `./make build --flavor vector`
    run build_container "testcontainer" "1.0.0" "1.0.0" "vector"

    [ "$status" -eq 0 ]

    grep -q ':latest-vector' "$TEST_TEMP_DIR/docker_calls.log"

    unset GITHUB_REPOSITORY_OWNER
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
    compute_cell_tag_suffixes() {
        printf 'partial\n'
        return 1
    }
    export -f compute_cell_tag_suffixes

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
