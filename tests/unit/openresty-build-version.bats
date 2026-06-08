#!/usr/bin/env bats

# Unit tests for openresty/build — version-resolution logic.
#
# Strategy: copy the build script into a temp dir alongside a stubbed version.sh,
# then stub yq via PATH injection. The build script sets SCRIPT_DIR=$(dirname "$0"),
# so running it from a temp dir with a version.sh stub makes the conditional branch
# testable without touching the real openresty/version.sh or making network calls.
#
# The script emits: "Building OpenResty ${VERSION} (source: ${UPSTREAM_VERSION})"
# We extract UPSTREAM_VERSION from that line for assertions.
#
# Mutation each test catches:
#   TC1: removing the VERSION branch → version.sh called, returns 9.8.7 ≠ "1.29.2.4"
#   TC2: removing suffix strip → UPSTREAM_VERSION would equal "1.29.2.5-alpine" ≠ "1.29.2.5"
#   TC3: removing the else branch → version.sh never called, UPSTREAM_VERSION empty or wrong
#   TC4: removing the -z guard → script exits 0 and emits "(source: )" instead of error exit 1
#   TC5: suffix strip using sed/grep instead of %-alpine → "1.29.2.4" (no suffix) would break
#   TC6-TC8: removing dotted-numeric validation → invalid upstream versions pass

bats_require_minimum_version 1.5.0

load "../test_helper"

# ---------------------------------------------------------------------------
# Setup: per-test temp dir with stubbed version.sh and yq
# ---------------------------------------------------------------------------

setup() {
    setup_temp_dir

    # PROJECT_ROOT is exported by test_helper; derive build script path from it.
    local build_script="$PROJECT_ROOT/openresty/build"

    # Copy the real build script into the temp dir so SCRIPT_DIR resolves to temp dir.
    cp "$build_script" "$TEST_TEMP_DIR/build"
    chmod +x "$TEST_TEMP_DIR/build"

    # Default stub: version.sh echoes a valid dotted numeric version when called with --upstream.
    _write_version_stub "9.8.7"

    # Stub yq: the build script checks for yq but does not use it; stub satisfies
    # the `command -v yq` guard without installing the real binary.
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/yq" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/yq"

    export ORIGINAL_PATH="$PATH"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
}

teardown() {
    teardown_temp_dir
    export PATH="$ORIGINAL_PATH"
    unset VERSION CUSTOM_BUILD_ARGS
}

# Write version.sh stub into temp dir with a given --upstream return value.
_write_version_stub() {
    local upstream_val="$1"
    cat > "$TEST_TEMP_DIR/version.sh" <<EOF
#!/bin/bash
if [[ "\$1" == "--upstream" ]]; then
    echo "$upstream_val"
else
    echo "UNEXPECTED_CALL: \$*" >&2
    exit 1
fi
EOF
    chmod +x "$TEST_TEMP_DIR/version.sh"
}

# Run the build script and capture output + stderr separately.
# Sets: $status, $output, $stderr (via bats --separate-stderr).
_run_build() {
    run --separate-stderr bash "$TEST_TEMP_DIR/build"
}

# Extract the UPSTREAM_VERSION resolved by the build script from its stdout line:
# "Building OpenResty <VERSION> (source: <UPSTREAM_VERSION>)"
# Prints the captured UPSTREAM_VERSION or fails if the line is absent.
_extract_resty_version() {
    local line
    line=$(echo "$output" | grep "^Building OpenResty") || {
        echo "MISSING_BUILD_LINE" >&2
        return 1
    }
    # Extract content inside "(source: ...)"
    local resty
    resty=$(echo "$line" | sed 's/.*source: \([^)]*\)).*/\1/')
    echo "$resty"
}

# =============================================================================
# TC1: VERSION="1.29.2.4-alpine" → RESTY_VERSION="1.29.2.4"
# =============================================================================

@test "TC1: VERSION=1.29.2.4-alpine sets RESTY_VERSION to 1.29.2.4" {
    export VERSION="1.29.2.4-alpine"
    _run_build

    [ "$status" -eq 0 ]
    local resty
    resty=$(_extract_resty_version)
    [ "$resty" = "1.29.2.4" ]
}

# =============================================================================
# TC2: VERSION="1.29.2.5-alpine" → RESTY_VERSION="1.29.2.5" (latest retained)
# =============================================================================

@test "TC2: VERSION=1.29.2.5-alpine sets RESTY_VERSION to 1.29.2.5" {
    export VERSION="1.29.2.5-alpine"
    _run_build

    [ "$status" -eq 0 ]
    local resty
    resty=$(_extract_resty_version)
    [ "$resty" = "1.29.2.5" ]
}

# =============================================================================
# TC3: VERSION unset → RESTY_VERSION comes from version.sh --upstream stub
# =============================================================================

@test "TC3: VERSION unset falls back to version.sh --upstream" {
    unset VERSION
    _run_build

    [ "$status" -eq 0 ]
    local resty
    resty=$(_extract_resty_version)
    [ "$resty" = "9.8.7" ]
}

# =============================================================================
# TC4: VERSION="-alpine" (empty after strip) → exit 1 + "resolves to empty" in stderr
# =============================================================================

@test "TC4: VERSION=-alpine (empty after strip) exits 1 with error in stderr" {
    export VERSION="-alpine"
    _run_build

    [ "$status" -ne 0 ]
    [[ "$stderr" == *"resolves to empty"* ]]
}

# =============================================================================
# TC5: VERSION="1.29.2.4" (no -alpine suffix) → RESTY_VERSION="1.29.2.4" (no-op strip)
# =============================================================================

@test "TC5: VERSION=1.29.2.4 (no -alpine suffix) sets RESTY_VERSION to 1.29.2.4" {
    export VERSION="1.29.2.4"
    _run_build

    [ "$status" -eq 0 ]
    local resty
    resty=$(_extract_resty_version)
    [ "$resty" = "1.29.2.4" ]
}

# =============================================================================
# TC6: VERSION="alpine-alpine" -> RESTY_VERSION="alpine" -> invalid
# =============================================================================

@test "TC6: VERSION=alpine-alpine rejects non-numeric stripped version" {
    export VERSION="alpine-alpine"
    _run_build

    [ "$status" -ne 0 ]
    [[ "$stderr" == *"UPSTREAM_VERSION='alpine' is not a valid dotted numeric version"* ]]
}

# =============================================================================
# TC7: VERSION="1.29.2.5-alpine-beta" -> invalid
# =============================================================================

@test "TC7: VERSION=1.29.2.5-alpine-beta rejects prerelease suffix" {
    export VERSION="1.29.2.5-alpine-beta"
    _run_build

    [ "$status" -ne 0 ]
    [[ "$stderr" == *"is not a valid dotted numeric version"* ]]
}

# =============================================================================
# TC8: VERSION unset and version.sh --upstream returns garbage -> invalid
# =============================================================================

@test "TC8: VERSION unset rejects invalid version.sh --upstream output" {
    unset VERSION
    _write_version_stub "alpine"
    _run_build

    [ "$status" -ne 0 ]
    [[ "$stderr" == *"UPSTREAM_VERSION='alpine' is not a valid dotted numeric version"* ]]
}
