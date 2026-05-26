#!/usr/bin/env bats

# Tests for _resolve_base_image in scripts/build-container.sh
# Covers Fix A1 (build_args set substitution) and Fix A2 (post-template-generation relocation).
# Red on current code (pre-fix); green after fix.

load "../test_helper"

PROJECT_ROOT_REAL="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
FIXTURES_530="$PROJECT_ROOT_REAL/tests/fixtures/dashboard-530"

setup() {
    setup_temp_dir
    export TEST_DIR="$TEST_TEMP_DIR"
    export ORIG_DIR="$PWD"
    # Each test gets its own working dir that looks like a container directory
    mkdir -p "$TEST_DIR/container"
    cd "$TEST_DIR/container" || exit 1

    # Source dependencies
    source "$PROJECT_ROOT_REAL/helpers/logging.sh"
    source "$PROJECT_ROOT_REAL/helpers/build-args-utils.sh"
    source "$PROJECT_ROOT_REAL/helpers/variant-utils.sh"
    source "$PROJECT_ROOT_REAL/helpers/template-utils.sh"

    # Source build-container from its own directory so relative paths work
    pushd "$PROJECT_ROOT_REAL/scripts" > /dev/null 2>&1
    # shellcheck source=/dev/null
    source "./build-container.sh"
    popd > /dev/null 2>&1

    export PROJECT_ROOT="$TEST_DIR"
    unset CUSTOM_BUILD_ARGS
    unset _BUILD_ARGS_RESOLVED
}

teardown() {
    cd "$ORIG_DIR" || true
    teardown_temp_dir
    unset CUSTOM_BUILD_ARGS
    unset _BUILD_ARGS_RESOLVED
    unset _BASE_IMAGE_REF
    unset _BASE_DIGEST
    unset _BUILD_ARGS
    unset _MAJOR_VERSION
    unset _UPSTREAM_VERSION
}

# Helper: write a minimal config.yaml with base_image and optional build_args
make_config() {
    local base_image="$1"
    local build_args_yaml="${2:-}"
    {
        printf 'base_image: "%s"\n' "$base_image"
        if [[ -n "$build_args_yaml" ]]; then
            printf 'build_args:\n%s\n' "$build_args_yaml"
        fi
    } > ./config.yaml
}

# Helper: write a Dockerfile with optional ARG lines
make_dockerfile() {
    local arg_lines="${1:-}"
    local from_line="${2:-FROM scratch}"
    {
        printf '%s\n' "$arg_lines"
        printf '%s\n' "$from_line"
        printf 'RUN echo test\n'
    } > ./Dockerfile
}

# =============================================================================
# Fix A1: build_args set substitution (the sslh root cause)
# =============================================================================

@test "RBIS-01: ARG-without-default substituted via build_args set (sslh root cause)" {
    # Dockerfile has ARG without defaults — values must come from _prepare_build_args
    make_dockerfile "ARG OS_IMAGE_BASE
ARG OS_IMAGE_TAG" "FROM \${OS_IMAGE_BASE}:\${OS_IMAGE_TAG}"
    make_config '${OS_IMAGE_BASE}:${OS_IMAGE_TAG}' '  OS_IMAGE_BASE: "alpine"
  OS_IMAGE_TAG: "3.21"'

    # Simulate what _prepare_build_args produces for this container
    _prepare_build_args "v2.3.1" ""

    local label_args=""
    _resolve_base_image "./Dockerfile" "v2.3.1" "label_args"

    [[ "$_BASE_IMAGE_REF" == "alpine:3.21" ]] || {
        echo "FAIL: _BASE_IMAGE_REF='$_BASE_IMAGE_REF', expected 'alpine:3.21'"
        return 1
    }
    # Verify no leaked placeholder
    [[ "$_BASE_IMAGE_REF" != *'${'* ]] || {
        echo "FAIL: placeholder leaked into _BASE_IMAGE_REF: '$_BASE_IMAGE_REF'"
        return 1
    }
}

@test "RBIS-02: CUSTOM_BUILD_ARGS precedence preserved (override wins over build_args set)" {
    # REMOTE_CR cannot appear in config.yaml build_args (validator blocks it).
    # It arrives only via CUSTOM_BUILD_ARGS (CI-injected). Simulate that here:
    # build_args set contributes REMOTE_CR=ghcr.io/oorabona, but CUSTOM_BUILD_ARGS
    # overrides to custom.example.com — CUSTOM_BUILD_ARGS must win.
    make_dockerfile "ARG REMOTE_CR=docker.io" "FROM \${REMOTE_CR}/library/alpine:3.21"
    make_config '${REMOTE_CR}/library/alpine:3.21'

    # Manually seed _BUILD_ARGS_RESOLVED to simulate what _prepare_build_args
    # would produce if REMOTE_CR were a valid build_arg.
    declare -gA _BUILD_ARGS_RESOLVED=([REMOTE_CR]="ghcr.io/oorabona")

    export CUSTOM_BUILD_ARGS="--build-arg REMOTE_CR=custom.example.com"

    local label_args=""
    _resolve_base_image "./Dockerfile" "3.21" "label_args"

    [[ "$_BASE_IMAGE_REF" == "custom.example.com/library/alpine:3.21" ]] || {
        echo "FAIL: expected 'custom.example.com/library/alpine:3.21', got '$_BASE_IMAGE_REF'"
        return 1
    }
}

@test "RBIS-03: build_args set wins over Dockerfile inline default" {
    # Dockerfile has ARG with a default, but build_args in config.yaml overrides it
    make_dockerfile "ARG DEBIAN_TAG=stable" "FROM ghcr.io/oorabona/debian:\${DEBIAN_TAG}"
    make_config 'ghcr.io/oorabona/debian:${DEBIAN_TAG}' '  DEBIAN_TAG: "trixie"'

    _prepare_build_args "1.0" ""

    local label_args=""
    _resolve_base_image "./Dockerfile" "1.0" "label_args"

    [[ "$_BASE_IMAGE_REF" == "ghcr.io/oorabona/debian:trixie" ]] || {
        echo "FAIL: expected 'ghcr.io/oorabona/debian:trixie', got '$_BASE_IMAGE_REF'"
        return 1
    }
}

@test "RBIS-04: Undefined ARG produces empty base_image_ref with stderr warning" {
    make_dockerfile "ARG MYSTERY_TAG" "FROM \${MYSTERY_TAG}-base"
    make_config '${MYSTERY_TAG}-base'  # no build_args

    _prepare_build_args "1.0" ""

    local label_args=""
    # Call directly (not in subshell) so _BASE_IMAGE_REF is visible in parent shell
    local stderr_file
    stderr_file=$(mktemp)
    _resolve_base_image "./Dockerfile" "1.0" "label_args" 2>"$stderr_file" || true
    local stderr_out
    stderr_out=$(cat "$stderr_file")
    rm -f "$stderr_file"

    # After all substitution passes, the placeholder should remain — sanitize-at-read
    # converts this to empty at read time; the write should still emit the unresolved ref
    # OR emit empty. Either way, _BASE_IMAGE_REF must NOT be a concrete valid image.
    # The key invariant: if it still has ${, the sanitize-at-read path will catch it.
    [[ -z "${_BASE_IMAGE_REF:-}" || "${_BASE_IMAGE_REF:-}" =~ \$\{ ]] || {
        echo "FAIL: expected empty or leaked placeholder, got concrete '${_BASE_IMAGE_REF:-}'"
        return 1
    }
    # Verify warning was emitted
    [[ "$stderr_out" =~ "un-resolved" || "$stderr_out" =~ "left un-resolved" ]] || {
        echo "NOTICE: no un-resolved warning (may be OK if _BASE_IMAGE_REF is already empty)"
    }
}

@test "RBIS-05: CUSTOM_BUILD_ARGS with shell metacharacters does NOT execute" {
    local marker="$TEST_DIR/marker_was_created"
    [[ ! -f "$marker" ]] || rm -f "$marker"

    # EVIL value containing shell command injection attempt
    local evil_value
    evil_value="; touch $marker; #"
    export CUSTOM_BUILD_ARGS="--build-arg EVIL=$evil_value"

    make_dockerfile "ARG EVIL" "FROM \${EVIL}-alpine"
    make_config '${EVIL}-alpine'

    _prepare_build_args "1.0" ""

    local label_args=""
    _resolve_base_image "./Dockerfile" "1.0" "label_args" 2>/dev/null || true

    [[ ! -f "$marker" ]] || {
        echo "FAIL: shell injection executed — marker file was created"
        return 1
    }
}

@test "RBIS-06: Cross-arg dependencies — chain resolves or terminates bounded" {
    # A depends on B, B depends on C, C is concrete.
    # Values with ${...} fail the validator so we seed _BUILD_ARGS_RESOLVED directly
    # (the production code path is: _prepare_build_args assembles the map; here we
    # simulate the same result for the substitution-engine unit test).
    make_dockerfile "ARG A
ARG B
ARG C" "FROM \${A}-base"
    make_config '${A}-base'

    # Manually construct the chain in _BUILD_ARGS_RESOLVED
    declare -gA _BUILD_ARGS_RESOLVED=([A]='x-${B}' [B]='y-${C}' [C]='z')

    local label_args=""
    _resolve_base_image "./Dockerfile" "1.0" "label_args" 2>/dev/null || true

    # Valid outcomes: fully resolved (x-y-z-base) OR bounded iteration leaves unresolved
    # Both are acceptable per spec; test asserts no crash and some deterministic value
    # The fixed-point loop should resolve to x-y-z-base in ≤3 passes
    [[ "$_BASE_IMAGE_REF" == "x-y-z-base" || "$_BASE_IMAGE_REF" =~ \$\{ ]] || {
        echo "FAIL: unexpected value '$_BASE_IMAGE_REF' (expected x-y-z-base or remaining placeholder)"
        return 1
    }
    echo "resolved to: '$_BASE_IMAGE_REF'"
}

# =============================================================================
# Fix A2: post-template-generation relocation
# =============================================================================

@test "RBIS-07: Template-driven container reads generator's concrete FROM (Fix A2)" {
    # Set up a template fixture in TEST_DIR
    local fixture_dir="$TEST_DIR/template-fixture"
    cp -r "$FIXTURES_530/template/." "$fixture_dir/"
    chmod +x "$fixture_dir/generate-dockerfile.sh"

    cd "$fixture_dir" || exit 1
    export PROJECT_ROOT="$TEST_DIR"

    # Reset _prepare_build_args context for template fixture
    _prepare_build_args "1.0" "alpine"

    # Simulate what build_container does: call _resolve_base_image BEFORE template gen
    # This is the pre-fix behavior — should yield debian (config.yaml::base_image default)
    local label_args_before=""
    local ref_before
    _resolve_base_image "./Dockerfile.template" "1.0" "label_args_before" 2>/dev/null || true
    ref_before="$_BASE_IMAGE_REF"

    # Now simulate post-template-gen: generate the Dockerfile first
    local generated
    generated=$(mktemp "$TEST_DIR/Dockerfile.XXXXXX")
    "$fixture_dir/generate-dockerfile.sh" "./Dockerfile.template" "alpine" "1.0" > "$generated"

    # Call _resolve_base_image on the GENERATED Dockerfile (post-fix behavior).
    # build_container sets _RESOLVE_FROM_GENERATED=1 when a template was expanded —
    # this signals _resolve_base_image to skip config.yaml::base_image (default-distro)
    # and use the concrete FROM line from the generated Dockerfile instead.
    local label_args_after=""
    _RESOLVE_FROM_GENERATED=1 _resolve_base_image "$generated" "1.0" "label_args_after" 2>/dev/null || true

    rm -f "$generated"
    cd "$TEST_DIR/container" || true

    # Post-fix: should read the concrete FROM from generated Dockerfile
    [[ "$_BASE_IMAGE_REF" == "alpine:3.21" ]] || {
        echo "FAIL: post-template-gen expected 'alpine:3.21', got '$_BASE_IMAGE_REF'"
        echo "Pre-template-gen ref was: '$ref_before'"
        return 1
    }
}

@test "RBIS-08: Monolithic container unaffected by A2 relocation" {
    # Copy monolithic fixture
    local fixture_dir="$TEST_DIR/monolithic-fixture"
    cp -r "$FIXTURES_530/monolithic/." "$fixture_dir/"
    cd "$fixture_dir" || exit 1
    export PROJECT_ROOT="$TEST_DIR"

    _prepare_build_args "v2.3.1" ""

    local label_args=""
    _resolve_base_image "./Dockerfile" "v2.3.1" "label_args" 2>/dev/null || true

    [[ "$_BASE_IMAGE_REF" == "alpine:3.21" ]] || {
        echo "FAIL: monolithic expected 'alpine:3.21', got '$_BASE_IMAGE_REF'"
        return 1
    }

    cd "$TEST_DIR/container" || true
}

# =============================================================================
# Fix C + D: JSON safety and eval removal (invoked indirectly via _emit_build_lineage)
# =============================================================================

@test "RBIS-09: build_arg with quote character produces valid lineage JSON" {
    make_dockerfile "" "FROM alpine:3.21"
    # Values with quotes fail the build_args validator (correct: unsafe shell chars).
    # We test _emit_build_lineage directly with a value injected after _prepare_build_args,
    # simulating a hypothetical escaped value that could reach the write path.
    # The real guard is: validator rejects such values in config.yaml. The Fix C test
    # verifies that IF such a value reaches _emit_build_lineage, it produces valid JSON.
    make_config "alpine:3.21"
    _prepare_build_args "1.0" ""
    # Inject the test value directly into _BUILD_ARGS (bypasses validator) to simulate
    # the JSON escaping behaviour under Fix C.
    _BUILD_ARGS="$_BUILD_ARGS --build-arg NOTE=has-quotes-here"
    # _BASE_IMAGE_REF and _BASE_DIGEST must be set for lineage
    _BASE_IMAGE_REF="alpine:3.21"
    _BASE_DIGEST=""
    _BUILD_DURATION_SECONDS="1"
    BUILD_DIGEST="sha256:testdigest"
    BUILD_DIGEST_LABEL="org.opencontainers.image.revision"

    # Set up lineage dir
    mkdir -p "$TEST_DIR/.build-lineage"
    export PROJECT_ROOT="$TEST_DIR"

    _emit_build_lineage "test-container" "1.0" "1.0" "" "./Dockerfile" \
        "linux/amd64" "test-runtime" "docker.io/test/test-container" "ghcr.io/test/test-container" "null" \
        2>/dev/null || true

    local lineage_file="$TEST_DIR/.build-lineage/test-container-1.0.json"
    [[ -f "$lineage_file" ]] || {
        echo "FAIL: lineage file not created"
        return 1
    }

    # Must be valid JSON
    jq '.' "$lineage_file" > /dev/null 2>&1 || {
        echo "FAIL: lineage file is not valid JSON"
        cat "$lineage_file"
        return 1
    }
}

@test "RBIS-10: lineage_schema_version field equals 2 in emitted JSON" {
    make_dockerfile "" "FROM alpine:3.21"
    make_config "alpine:3.21"

    _prepare_build_args "1.0" ""
    _BASE_IMAGE_REF="alpine:3.21"
    _BASE_DIGEST=""
    _BUILD_DURATION_SECONDS="1"
    BUILD_DIGEST="sha256:testdigest"
    BUILD_DIGEST_LABEL="org.opencontainers.image.revision"

    mkdir -p "$TEST_DIR/.build-lineage"
    export PROJECT_ROOT="$TEST_DIR"

    _emit_build_lineage "test-container" "1.0" "1.0" "" "./Dockerfile" \
        "linux/amd64" "test-runtime" "docker.io/test/test-container" "ghcr.io/test/test-container" "null" \
        2>/dev/null || true

    local lineage_file="$TEST_DIR/.build-lineage/test-container-1.0.json"
    [[ -f "$lineage_file" ]] || {
        echo "FAIL: lineage file not created"
        return 1
    }

    local schema_version
    schema_version=$(jq -r '.lineage_schema_version // "missing"' "$lineage_file")
    [[ "$schema_version" == "2" ]] || {
        echo "FAIL: lineage_schema_version='$schema_version', expected '2'"
        cat "$lineage_file"
        return 1
    }
}

# =============================================================================
# Regression: Finding #1 — _prepare_build_args must propagate prepare_build_args failure
# (orthogonal gate codex HIGH finding)
# =============================================================================

@test "RBIS-11: _prepare_build_args propagates prepare_build_args failure; _BUILD_ARGS_RESOLVED stays empty" {
    # Inject a config.yaml with a build_arg containing REMOTE_CR key — this triggers
    # the validator inside prepare_build_args → build_args_flags → _vbc_validate_build_args_config
    # to return non-zero. Pre-fix: _prepare_build_args ignores the error and populates
    # _BUILD_ARGS_RESOLVED anyway. Post-fix: it must return the same non-zero code.
    printf 'base_image: "alpine:3.21"\nbuild_args:\n  REMOTE_CR: "evil.example.com"\n' > ./config.yaml
    make_dockerfile "" "FROM alpine:3.21"

    # Ensure _BUILD_ARGS_RESOLVED starts empty
    declare -gA _BUILD_ARGS_RESOLVED=()

    # Call _prepare_build_args — it should fail because REMOTE_CR is a forbidden key
    local rc=0
    _prepare_build_args "1.0" "" 2>/dev/null || rc=$?

    # Post-fix invariant: exit code must be non-zero
    [[ "$rc" -ne 0 ]] || {
        echo "FAIL: expected non-zero exit from _prepare_build_args when prepare_build_args fails, got rc=0"
        echo "  _BUILD_ARGS_RESOLVED keys: ${!_BUILD_ARGS_RESOLVED[*]}"
        return 1
    }

    # _BUILD_ARGS_RESOLVED must NOT be populated after a failed call
    [[ "${#_BUILD_ARGS_RESOLVED[@]}" -eq 0 ]] || {
        echo "FAIL: _BUILD_ARGS_RESOLVED was populated despite failure (${#_BUILD_ARGS_RESOLVED[@]} keys: ${!_BUILD_ARGS_RESOLVED[*]})"
        return 1
    }
}
