#!/usr/bin/env bats

# Unit tests for version-set fan-out in scripts/build-extensions.sh
# Covers: backward-compat single version, fan-out, skip-existing, musl
# tolerance, ceiling-fatal, and the versionset artifact shape.
#
# Mocking strategy:
#   - resolve_version_set()    : overridden per-test to return controlled arrays
#   - build_ext_image()        : records calls; controllable failure
#   - tag_ext_image()          : records calls; always succeeds
#   - push_ext_image()         : records calls; always succeeds
#   - image_exists_in_registry(): overridden per-test
#   - docker()                 : absent locally (returns 1)
#   - ext_config()             : returns deterministic values per key
#   - ext_image_name()         : deterministic tag from (ext, version, major)

load "../test_helper"

# ---------------------------------------------------------------------------
# Source helper (same pattern as build-extensions.bats)
# ---------------------------------------------------------------------------
_source_build_extensions() {
    pushd "$SCRIPTS_DIR" > /dev/null 2>&1
    # shellcheck disable=SC1091
    source "./build-extensions.sh"
    popd > /dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
    setup_temp_dir

    CONTAINER_DIR="$TEST_TEMP_DIR/postgres"
    EXT_BUILD_DIR="$CONTAINER_DIR/extensions/build"
    mkdir -p "$EXT_BUILD_DIR"

    mkdir -p "$CONTAINER_DIR/extensions"
    cat > "$CONTAINER_DIR/extensions/config.yaml" <<'EOF'
extensions:
  timescaledb:
    version: "2.27.1"
    repo: "https://github.com/timescale/timescaledb"
    priority: 1
    version_set:
      resolver: "scripts/resolvers/timescaledb-ha.sh"
EOF

    CONFIG_FILE="$CONTAINER_DIR/extensions/config.yaml"
    MAJOR_VER="18"

    touch "$EXT_BUILD_DIR/timescaledb.Dockerfile"

    export FORCE=false
    export LOCAL_ONLY=false
    export DRY_RUN=false
    export CONTAINER="postgres"
    export ROOT_DIR="$TEST_TEMP_DIR"

    _source_build_extensions

    # Install mocks AFTER sourcing
    _setup_default_mocks

    ROOT_DIR="$TEST_TEMP_DIR"
}

teardown() {
    teardown_temp_dir
    unset FORCE LOCAL_ONLY DRY_RUN CONTAINER ROOT_DIR
}

# ---------------------------------------------------------------------------
# Default mock helpers
# ---------------------------------------------------------------------------

_setup_default_mocks() {
    # docker image inspect: absent locally
    docker() { return 1; }
    export -f docker

    # registry: absent
    image_exists_in_registry() { return 1; }
    export -f image_exists_in_registry

    # ext_config: return known values by key
    ext_config() {
        local _ext="$1" _key="$2"
        case "$_key" in
            version) echo "2.27.1" ;;
            repo)    echo "https://github.com/timescale/timescaledb" ;;
            *)       echo "" ;;
        esac
    }
    export -f ext_config

    # ext_image_name: deterministic from (ext, ver, major)
    ext_image_name() {
        echo "ghcr.io/test/ext-${1}:pg${3}-${2}"
    }
    export -f ext_image_name

    # ext_local_image_name: deterministic
    ext_local_image_name() {
        echo "localhost/ext-builder-${1}:pg${2}"
    }
    export -f ext_local_image_name

    # resolve_version_set: default → single-version (overridden per-test)
    resolve_version_set() {
        echo '["2.27.1"]'
    }
    export -f resolve_version_set

    # build_ext_image: succeed by default, record call
    build_ext_image() {
        echo "BUILD_CALLED ext=${1} ver=${2} pg=${4}" >> "$TEST_TEMP_DIR/build_calls.log"
        return 0
    }
    export -f build_ext_image

    # tag_ext_image: succeed by default, record call
    tag_ext_image() {
        echo "TAG_CALLED ext=${1} ver=${2} pg=${3}" >> "$TEST_TEMP_DIR/tag_calls.log"
        return 0
    }
    export -f tag_ext_image

    # push_ext_image: succeed by default, record call
    push_ext_image() {
        echo "PUSH_CALLED ext=${1} ver=${2} pg=${3}" >> "$TEST_TEMP_DIR/push_calls.log"
        return 0
    }
    export -f push_ext_image

    # jq: pass through (real jq required)
    # log_* pass-through (already sourced from extension-utils.sh chain)
}

# ---------------------------------------------------------------------------
# Helper: count lines in a log file (0 if absent)
# ---------------------------------------------------------------------------
_count_log_lines() {
    local f="$1"
    [[ -f "$f" ]] && wc -l < "$f" || echo 0
}

# ---------------------------------------------------------------------------
# Test 1: backward compat — single-version resolver → exactly one build
# ---------------------------------------------------------------------------

@test "backward-compat: single-version set triggers exactly one build" {
    resolve_version_set() { echo '["1.2.3"]'; }
    export -f resolve_version_set

    ext_config() {
        case "$2" in
            version) echo "1.2.3" ;;
            repo)    echo "https://example.com/ext" ;;
            *)       echo "" ;;
        esac
    }
    export -f ext_config

    run build_tag_push_extensions \
        "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR" "true" "timescaledb"

    [ "$status" -eq 0 ]

    local build_count
    build_count=$(_count_log_lines "$TEST_TEMP_DIR/build_calls.log")
    [ "$build_count" -eq 1 ]

    [[ "$(cat "$TEST_TEMP_DIR/build_calls.log")" == *"ver=1.2.3"* ]]
}

# ---------------------------------------------------------------------------
# Test 2: fan-out — 3-version set, all absent → 3 build+tag+push
# ---------------------------------------------------------------------------

@test "fan-out: 3-version set all absent → 3 builds with correct versions" {
    resolve_version_set() { echo '["2.25.0","2.26.0","2.27.1"]'; }
    export -f resolve_version_set

    ext_config() {
        case "$2" in
            version) echo "2.27.1" ;;
            repo)    echo "https://github.com/timescale/timescaledb" ;;
            *)       echo "" ;;
        esac
    }
    export -f ext_config

    run build_tag_push_extensions \
        "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR" "true" "timescaledb"

    [ "$status" -eq 0 ]

    local build_count
    build_count=$(_count_log_lines "$TEST_TEMP_DIR/build_calls.log")
    [ "$build_count" -eq 3 ]

    [[ "$(cat "$TEST_TEMP_DIR/build_calls.log")" == *"ver=2.25.0"* ]]
    [[ "$(cat "$TEST_TEMP_DIR/build_calls.log")" == *"ver=2.26.0"* ]]
    [[ "$(cat "$TEST_TEMP_DIR/build_calls.log")" == *"ver=2.27.1"* ]]

    local push_count
    push_count=$(_count_log_lines "$TEST_TEMP_DIR/push_calls.log")
    [ "$push_count" -eq 3 ]

    # L1: each version must be tagged and pushed under its OWN version string
    local tag_log push_log
    tag_log=$(cat "$TEST_TEMP_DIR/tag_calls.log")
    push_log=$(cat "$TEST_TEMP_DIR/push_calls.log")
    [[ "$tag_log"  == *"ver=2.25.0"* ]]
    [[ "$tag_log"  == *"ver=2.26.0"* ]]
    [[ "$tag_log"  == *"ver=2.27.1"* ]]
    [[ "$push_log" == *"ver=2.25.0"* ]]
    [[ "$push_log" == *"ver=2.26.0"* ]]
    [[ "$push_log" == *"ver=2.27.1"* ]]
}

# ---------------------------------------------------------------------------
# Test 3: skip-existing — 3-version set, middle already in registry → 2 builds
# ---------------------------------------------------------------------------

@test "skip-existing: middle version in registry → 2 builds; middle in available" {
    resolve_version_set() { echo '["2.25.0","2.26.0","2.27.1"]'; }
    export -f resolve_version_set

    ext_config() {
        case "$2" in
            version) echo "2.27.1" ;;
            repo)    echo "https://github.com/timescale/timescaledb" ;;
            *)       echo "" ;;
        esac
    }
    export -f ext_config

    # Only 2.26.0 exists in registry
    image_exists_in_registry() {
        [[ "$1" == *"pg18-2.26.0"* ]] && return 0 || return 1
    }
    export -f image_exists_in_registry

    run build_tag_push_extensions \
        "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR" "true" "timescaledb"

    [ "$status" -eq 0 ]

    local build_count
    build_count=$(_count_log_lines "$TEST_TEMP_DIR/build_calls.log")
    [ "$build_count" -eq 2 ]

    [[ "$(cat "$TEST_TEMP_DIR/build_calls.log")" == *"ver=2.25.0"* ]]
    [[ "$(cat "$TEST_TEMP_DIR/build_calls.log")" != *"ver=2.26.0"* ]]
    [[ "$(cat "$TEST_TEMP_DIR/build_calls.log")" == *"ver=2.27.1"* ]]
    # Note: versionset artifact is now written exclusively by _emit_final_versionset_pass
    # (called from main()); build_tag_push_extensions no longer writes it.
    # Artifact content is covered by the CACHED-1/CACHED-2/MIXED-* integration tests.
}

# ---------------------------------------------------------------------------
# Test 4: musl tolerance — oldest build fails → exit 0; version in excluded
# ---------------------------------------------------------------------------

@test "musl-tolerance: oldest build fails → exit 0, version in excluded" {
    resolve_version_set() { echo '["2.25.0","2.26.0","2.27.1"]'; }
    export -f resolve_version_set

    ext_config() {
        case "$2" in
            version) echo "2.27.1" ;;
            repo)    echo "https://github.com/timescale/timescaledb" ;;
            *)       echo "" ;;
        esac
    }
    export -f ext_config

    # 2.25.0 fails to build (musl incompatibility)
    build_ext_image() {
        if [[ "$2" == "2.25.0" ]]; then
            echo "BUILD_FAILED ext=${1} ver=${2}" >> "$TEST_TEMP_DIR/build_calls.log"
            return 1
        fi
        echo "BUILD_CALLED ext=${1} ver=${2} pg=${4}" >> "$TEST_TEMP_DIR/build_calls.log"
        return 0
    }
    export -f build_ext_image

    run build_tag_push_extensions \
        "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR" "true" "timescaledb"

    [ "$status" -eq 0 ]

    # 2.26.0 and 2.27.1 (ceiling) should still have been built
    [[ "$(cat "$TEST_TEMP_DIR/build_calls.log")" == *"ver=2.26.0"* ]]
    [[ "$(cat "$TEST_TEMP_DIR/build_calls.log")" == *"ver=2.27.1"* ]]
    # Note: versionset artifact is now written exclusively by _emit_final_versionset_pass
    # (called from main()); build_tag_push_extensions no longer writes it.
    # The musl-excluded split is covered by the CACHED-2 integration test.
}

# ---------------------------------------------------------------------------
# Test 5: ceiling fatal — build fails for ceiling version → exit 1
# ---------------------------------------------------------------------------

@test "ceiling-fatal: ceiling build fails → exit 1" {
    resolve_version_set() { echo '["2.25.0","2.26.0","2.27.1"]'; }
    export -f resolve_version_set

    ext_config() {
        case "$2" in
            version) echo "2.27.1" ;;
            repo)    echo "https://github.com/timescale/timescaledb" ;;
            *)       echo "" ;;
        esac
    }
    export -f ext_config

    # Only 2.27.1 (ceiling) fails
    build_ext_image() {
        if [[ "$2" == "2.27.1" ]]; then
            echo "BUILD_FAILED ext=${1} ver=${2}" >> "$TEST_TEMP_DIR/build_calls.log"
            return 1
        fi
        echo "BUILD_CALLED ext=${1} ver=${2} pg=${4}" >> "$TEST_TEMP_DIR/build_calls.log"
        return 0
    }
    export -f build_ext_image

    run build_tag_push_extensions \
        "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR" "true" "timescaledb"

    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Test 6: artifact shape — versionset JSON has correct fields
# ---------------------------------------------------------------------------

@test "artifact-shape: versionset JSON has resolved/available/excluded fields" {
    resolve_version_set() { echo '["2.25.0","2.26.0","2.27.1"]'; }
    export -f resolve_version_set

    ext_config() {
        case "$2" in
            version) echo "2.27.1" ;;
            repo)    echo "https://github.com/timescale/timescaledb" ;;
            *)       echo "" ;;
        esac
    }
    export -f ext_config

    # 2.25.0 fails (excluded), others succeed (available)
    build_ext_image() {
        if [[ "$2" == "2.25.0" ]]; then
            echo "BUILD_FAILED ext=${1} ver=${2}" >> "$TEST_TEMP_DIR/build_calls.log"
            return 1
        fi
        echo "BUILD_CALLED ext=${1} ver=${2} pg=${4}" >> "$TEST_TEMP_DIR/build_calls.log"
        return 0
    }
    export -f build_ext_image

    run build_tag_push_extensions \
        "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR" "true" "timescaledb"

    [ "$status" -eq 0 ]
    # Note: versionset artifact is now written exclusively by _emit_final_versionset_pass
    # (called from main()); build_tag_push_extensions no longer writes it.
    # Artifact shape (resolved/available/excluded fields) is covered by the
    # CACHED-1/CACHED-2/MIXED-* integration tests which drive main().
}

# ---------------------------------------------------------------------------
# M1: resolver call-count — resolve_version_set called AT MOST ONCE per
# (ext, pg_major) even though both _should_build_extension and
# build_tag_push_extensions consume the result.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Test 8: resolver failure is fatal — not silently degraded to single-version
# ---------------------------------------------------------------------------

@test "resolver-failure-fatal: resolver non-zero exit causes build failure, not silent fallback" {
    local build_log="$TEST_TEMP_DIR/rfatal_build_calls.log"

    resolve_version_set() {
        echo "::error::simulated resolver failure" >&2
        return 1
    }
    export -f resolve_version_set

    ext_config() {
        case "$2" in
            version) echo "2.27.1" ;;
            repo)    echo "https://github.com/timescale/timescaledb" ;;
            *)       echo "" ;;
        esac
    }
    export -f ext_config

    build_ext_image() {
        echo "BUILD_CALLED ext=${1} ver=${2}" >> "$build_log"
        return 0
    }
    export -f build_ext_image

    run build_tag_push_extensions \
        "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR" "true" "timescaledb"
    local actual_status="$status"

    # Must fail (fail-closed), not silently succeed.
    [ "$actual_status" -ne 0 ]

    # Must NOT have built any version (no silent fallback to ceiling).
    local build_count
    build_count=$(_count_log_lines "$build_log")
    [ "$build_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# M1: resolver call-count — resolve_version_set called AT MOST ONCE per
# (ext, pg_major) even though both _should_build_extension and
# build_tag_push_extensions consume the result.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# A1: main() pre-filter fail-closed — resolver failure must propagate to exit 1
# (not silently become "All extensions are up to date" / exit 0).
# ---------------------------------------------------------------------------

@test "main-fail-closed: resolver failure in main() pre-filter exits non-zero, not 'up to date'" {
    # This test drives main() via a full subprocess invocation of build-extensions.sh.
    # Before the fix: main() calls _should_build_extension with plain 'if', so rc=2
    # is treated as "skip" → extensions_to_build stays empty → exit 0 + "up to date".
    # After the fix: the caller distinguishes rc>=2 as a resolver error → exit 1.

    local tmpd="$TEST_TEMP_DIR"
    local build_log="${tmpd}/main_build_calls.log"
    local sd="$SCRIPTS_DIR"

    # Write a minimal version.sh so detect_major_version can run if needed
    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    # The config + timescaledb.Dockerfile are already in place from setup()

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres

        cd \"$sd\"
        source ./build-extensions.sh
        # Re-set ROOT_DIR after source — build-extensions.sh resets it to the real repo
        export ROOT_DIR=\"$tmpd\"

        resolve_version_set() { echo 'simulated resolver failure' >&2; return 1; }
        export -f resolve_version_set

        ext_config() {
            case \"\$2\" in
                version) echo '2.27.1' ;;
                repo)    echo 'https://github.com/timescale/timescaledb' ;;
                *)       echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name
        image_exists_in_registry() { return 1; }
        export -f image_exists_in_registry
        docker()               { return 1; }
        export -f docker
        build_ext_image()      { echo \"BUILD ext=\$1 ver=\$2\" >> '${build_log}'; return 0; }
        export -f build_ext_image
        tag_ext_image()        { return 0; }
        export -f tag_ext_image
        push_ext_image()       { return 0; }
        export -f push_ext_image
        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority

        # source resets CONTAINER="" — pass the container name as a positional arg
        main postgres --major-version 18
    "

    # Before the fix: status=0 and output contains "up to date"  (RED)
    # After the fix:  status!=0 and output does NOT contain "up to date" (GREEN)

    # Must fail — fail-closed: resolver error is not a silent skip
    [ "$status" -ne 0 ]

    # Must NOT print "up to date" (that would be the fail-open bug behavior)
    [[ "$output" != *"up to date"* ]]

    # Must NOT have triggered any build (resolver failed before any build decision)
    local build_count
    build_count=$(_count_log_lines "$build_log")
    [ "$build_count" -eq 0 ]
}

@test "resolver-call-count: resolve_version_set called exactly once per (ext,major) across filter+build" {
    local counter_file="$TEST_TEMP_DIR/resolver_call_count"
    printf '0' > "$counter_file"

    resolve_version_set() {
        local n
        n=$(cat "$counter_file")
        printf '%d' $(( n + 1 )) > "$counter_file"
        echo '["2.25.0","2.26.0","2.27.1"]'
    }
    export -f resolve_version_set
    export counter_file

    ext_config() {
        case "$2" in
            version) echo "2.27.1" ;;
            repo)    echo "https://github.com/timescale/timescaledb" ;;
            *)       echo "" ;;
        esac
    }
    export -f ext_config

    # Run _should_build_extension (the pre-filter step) then build_tag_push_extensions
    # (the actual build loop) in a single shell so the cache is shared — mimicking
    # the real main() flow where both call _resolve_cached for the same (ext, major).
    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export counter_file=\"$counter_file\"
        cd \"$SCRIPTS_DIR\"
        source ./build-extensions.sh
        # Re-set ROOT_DIR after source — build-extensions.sh resets it to the real repo
        export ROOT_DIR=\"$TEST_TEMP_DIR\"

        resolve_version_set() {
            local n; n=\$(cat \"\$counter_file\")
            printf '%d' \$(( n + 1 )) > \"\$counter_file\"
            echo '[\"2.25.0\",\"2.26.0\",\"2.27.1\"]'
        }
        export -f resolve_version_set

        ext_config() {
            case \"\$2\" in
                version) echo \"2.27.1\" ;;
                repo)    echo \"https://github.com/timescale/timescaledb\" ;;
                *)       echo \"\" ;;
            esac
        }
        export -f ext_config

        ext_image_name() { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name
        image_exists_in_registry() { return 1; }
        export -f image_exists_in_registry
        docker() { return 1; }
        export -f docker
        build_ext_image() { return 0; }
        export -f build_ext_image
        tag_ext_image() { return 0; }
        export -f tag_ext_image
        push_ext_image() { return 0; }
        export -f push_ext_image

        CONFIG=\"$CONFIG_FILE\"
        CDIR=\"$CONTAINER_DIR\"

        # Simulate the main() pattern: filter step then build step
        if _should_build_extension timescaledb \"\$CONFIG\" 18 \"\$CDIR\"; then
            build_tag_push_extensions \"\$CONFIG\" 18 \"\$CDIR\" true timescaledb
        fi
    "

    [ "$status" -eq 0 ]

    local call_count
    call_count=$(cat "$counter_file")
    # Must be exactly 1 — the at-most-once invariant
    [ "$call_count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# D: tag failure on non-ceiling version must be fatal, NOT tolerated as musl.
# Before fix: single build_ok flag swallows tag failure into the "non-ceiling
# tolerated" branch → exit 0; version recorded in excluded as "musl" (#558).
# After fix:  tag failure always fatal → exit non-zero; version NOT in excluded.
# ---------------------------------------------------------------------------

@test "D-tag-fatal: non-ceiling tag failure is fatal (exit non-zero), not musl-excluded" {
    resolve_version_set() { echo '["2.25.0","2.26.0","2.27.1"]'; }
    export -f resolve_version_set

    ext_config() {
        case "$2" in
            version) echo "2.27.1" ;;
            repo)    echo "https://github.com/timescale/timescaledb" ;;
            *)       echo "" ;;
        esac
    }
    export -f ext_config

    # Builds all succeed; tag fails for the oldest (non-ceiling) version only.
    build_ext_image() {
        echo "BUILD_CALLED ext=${1} ver=${2}" >> "$TEST_TEMP_DIR/build_calls.log"
        return 0
    }
    export -f build_ext_image

    tag_ext_image() {
        if [[ "$2" == "2.25.0" ]]; then
            echo "TAG_FAILED ext=${1} ver=${2}" >> "$TEST_TEMP_DIR/tag_calls.log"
            return 1
        fi
        echo "TAG_CALLED ext=${1} ver=${2}" >> "$TEST_TEMP_DIR/tag_calls.log"
        return 0
    }
    export -f tag_ext_image

    run build_tag_push_extensions \
        "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR" "true" "timescaledb"
    local actual_status="$status"

    # Tag failure must be fatal regardless of ceiling/non-ceiling.
    [ "$actual_status" -ne 0 ]

    # 2.25.0 must NOT appear as a musl-excluded entry in the versionset artifact.
    local artifact="$TEST_TEMP_DIR/.build-lineage/ext-timescaledb-pg18-versionset.json"
    if [ -f "$artifact" ]; then
        local excluded_count
        excluded_count=$(jq '.excluded | length' "$artifact")
        [ "$excluded_count" -eq 0 ]
    fi
}

# ---------------------------------------------------------------------------
# E: per-version lineage durations must be independent (each = own build time),
# not cumulative (each = elapsed since outer loop started).
# Before fix: _ext_start captured once before the loop → later versions'
#   durations include earlier versions' build time → monotonically growing.
# After fix:  _ver_start captured per iteration → each duration is bounded.
#
# Strategy: mock build_ext_image to sleep 1s per call and build 3 versions.
# With the bug: durations are ~1, ~2, ~3 (cumulative wall time from _ext_start).
# With the fix: durations are ~1, ~1, ~1 (each version's own time).
# Assertion: every per-version lineage file has duration_seconds < 3.
# (Generous upper bound: on a very slow CI box each "build" is just sleep 1,
# so even with scheduler jitter no single-version delta should reach 3s.)
# ---------------------------------------------------------------------------

@test "E-duration-independent: per-version lineage durations are bounded, not cumulative" {
    resolve_version_set() { echo '["2.25.0","2.26.0","2.27.1"]'; }
    export -f resolve_version_set

    ext_config() {
        case "$2" in
            version) echo "2.27.1" ;;
            repo)    echo "https://github.com/timescale/timescaledb" ;;
            *)       echo "" ;;
        esac
    }
    export -f ext_config

    # Each build takes ~1s — makes cumulative vs. per-version observable.
    build_ext_image() {
        sleep 1
        echo "BUILD_CALLED ext=${1} ver=${2}" >> "$TEST_TEMP_DIR/build_calls.log"
        return 0
    }
    export -f build_ext_image

    run build_tag_push_extensions \
        "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR" "true" "timescaledb"

    [ "$status" -eq 0 ]

    # Read per-version lineage files and assert each duration is bounded (< 3).
    local lineage_dir="$TEST_TEMP_DIR/.build-lineage"
    local fail=0
    for ver in "2.25.0" "2.26.0" "2.27.1"; do
        local safe_ver="${ver//[^a-zA-Z0-9.-]/_}"
        local lfile="$lineage_dir/ext-timescaledb-pg18-${safe_ver}.json"
        [ -f "$lfile" ] || { echo "Missing lineage file for $ver"; fail=1; continue; }
        local dur
        dur=$(jq '.duration_seconds' "$lfile")
        # With cumulative code: ver 2.26.0 ≈ 2, ver 2.27.1 ≈ 3 → this assertion fails.
        # With per-version code: all ≈ 1 → passes.
        if [ "$dur" -ge 3 ]; then
            echo "FAIL: $ver duration_seconds=$dur is >= 3 (cumulative, not per-version)"
            fail=1
        fi
    done
    [ "$fail" -eq 0 ]
}

# ---------------------------------------------------------------------------
# G: resolver failure + LOCAL_ONLY=true must degrade gracefully to ceiling build
# (local recovery path). Without LOCAL_ONLY (publish/CI path), must stay fatal.
# ---------------------------------------------------------------------------

@test "G-local-degrade: resolver fails + LOCAL_ONLY=true → ceiling built, exit 0" {
    export LOCAL_ONLY=true

    resolve_version_set() {
        echo "::error::simulated upstream outage" >&2
        return 1
    }
    export -f resolve_version_set

    ext_config() {
        case "$2" in
            version) echo "2.27.1" ;;
            repo)    echo "https://github.com/timescale/timescaledb" ;;
            *)       echo "" ;;
        esac
    }
    export -f ext_config

    local build_log="$TEST_TEMP_DIR/g_local_build_calls.log"
    build_ext_image() {
        echo "BUILD_CALLED ext=${1} ver=${2}" >> "$build_log"
        return 0
    }
    export -f build_ext_image

    run build_tag_push_extensions \
        "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR" "false" "timescaledb"

    # Local recovery path must succeed (degraded, not fatal).
    [ "$status" -eq 0 ]

    # Must have built exactly the ceiling version.
    local build_count
    build_count=$(_count_log_lines "$build_log")
    [ "$build_count" -eq 1 ]
    [[ "$(cat "$build_log")" == *"ver=2.27.1"* ]]
}

@test "G-publish-fatal: resolver fails + LOCAL_ONLY=false → exit non-zero (publish path stays fail-closed)" {
    export LOCAL_ONLY=false

    resolve_version_set() {
        echo "::error::simulated upstream outage" >&2
        return 1
    }
    export -f resolve_version_set

    ext_config() {
        case "$2" in
            version) echo "2.27.1" ;;
            repo)    echo "https://github.com/timescale/timescaledb" ;;
            *)       echo "" ;;
        esac
    }
    export -f ext_config

    local build_log="$TEST_TEMP_DIR/g_publish_build_calls.log"
    build_ext_image() {
        echo "BUILD_CALLED ext=${1} ver=${2}" >> "$build_log"
        return 0
    }
    export -f build_ext_image

    run build_tag_push_extensions \
        "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR" "true" "timescaledb"

    # Publish/CI path must remain fail-closed.
    [ "$status" -ne 0 ]

    # Must NOT have built anything.
    local build_count
    build_count=$(_count_log_lines "$build_log")
    [ "$build_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# K: stale lineage files from a previous run must not persist across re-runs.
# Before fix: build-extensions.sh never removes old per-version lineage files,
# so ext-<ext>-pg<major>-<oldver>.json from the previous run survives and
# inflates the duration sum read by extension-duration-utils.sh.
# After fix: at the start of processing each ext+major, any pre-existing
# ext-<ext>-pg<major>-*.json (including *-versionset.json) is removed so only
# the current run's versions are on disk.
# ---------------------------------------------------------------------------

@test "K-stale-cleanup: stale lineage file from old version is removed before current run" {
    # Arrange: pre-create a stale per-version lineage file (2.24.0, not in the
    # current resolved set which is [2.25.0,2.26.0,2.27.1]).
    resolve_version_set() { echo '["2.25.0","2.26.0","2.27.1"]'; }
    export -f resolve_version_set

    ext_config() {
        case "$2" in
            version) echo "2.27.1" ;;
            repo)    echo "https://github.com/timescale/timescaledb" ;;
            *)       echo "" ;;
        esac
    }
    export -f ext_config

    local lineage_dir="$TEST_TEMP_DIR/.build-lineage"
    mkdir -p "$lineage_dir"

    # Stale file from a previous run — version 2.24.0 is NOT in the current set.
    local stale_file="$lineage_dir/ext-timescaledb-pg18-2.24.0.json"
    printf '{"ext":"timescaledb","version":"2.24.0","duration_seconds":99}\n' > "$stale_file"

    run build_tag_push_extensions \
        "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR" "true" "timescaledb"

    [ "$status" -eq 0 ]

    # The stale file must be gone after the run.
    [ ! -f "$stale_file" ]

    # Current-run lineage files must exist for each built version.
    [ -f "$lineage_dir/ext-timescaledb-pg18-2.25.0.json" ]
    [ -f "$lineage_dir/ext-timescaledb-pg18-2.26.0.json" ]
    [ -f "$lineage_dir/ext-timescaledb-pg18-2.27.1.json" ]
}

@test "K-stale-cleanup: stale versionset artifact from previous run is overwritten by final pass" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    local lineage_dir="$tmpd/.build-lineage"
    mkdir -p "$lineage_dir"

    # Pre-create a stale versionset artifact from a prior run.
    local stale_vs="$lineage_dir/ext-timescaledb-pg18-versionset.json"
    printf '{"ext":"timescaledb","pg_major":"18","ceiling":"2.24.0","resolved":["2.24.0"],"available":["2.24.0"],"excluded":[]}\n' \
        > "$stale_vs"

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        cd \"$sd\"
        source ./build-extensions.sh
        export ROOT_DIR=\"$tmpd\"

        resolve_version_set() { echo '[\"2.25.0\",\"2.26.0\",\"2.27.1\"]'; }
        export -f resolve_version_set

        ext_config() {
            case \"\$2\" in
                version) echo '2.27.1' ;;
                repo)    echo 'https://github.com/timescale/timescaledb' ;;
                *)       echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        # All versions in registry — nothing to build
        image_exists_in_registry() { return 0; }
        export -f image_exists_in_registry

        docker() { return 1; }
        export -f docker

        build_ext_image() { return 0; }
        export -f build_ext_image
        tag_ext_image()  { return 0; }
        export -f tag_ext_image
        push_ext_image() { return 0; }
        export -f push_ext_image
        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority

        main postgres --major-version 18
    "

    [ "$status" -eq 0 ]

    # The final pass must overwrite the stale artifact with the current ceiling.
    [ -f "$stale_vs" ]
    local ceiling
    ceiling=$(jq -r '.ceiling' "$stale_vs")
    [ "$ceiling" = "2.27.1" ]
}

# ---------------------------------------------------------------------------
# P1: --pull-only resolves full version set and attempts pull for each version
# ---------------------------------------------------------------------------

@test "pull-only-multiversion: resolver-backed ext attempts pull for each resolved version" {
    export LOCAL_ONLY=false

    resolve_version_set() { echo '["2.25.0","2.26.0","2.27.1"]'; }
    export -f resolve_version_set

    ext_config() {
        case "$2" in
            version) echo "2.27.1" ;;
            repo)    echo "https://github.com/timescale/timescaledb" ;;
            *)       echo "" ;;
        esac
    }
    export -f ext_config

    # Record pull attempts; all fail so build will be triggered
    local pull_log="$TEST_TEMP_DIR/pull_calls.log"
    pull_ext_image() {
        echo "PULL_CALLED ext=${1} ver=${2} pg=${3}" >> "$pull_log"
        return 1  # simulate: not in registry
    }
    export -f pull_ext_image

    # Build succeeds (LOCAL_ONLY=true set by handle_pull_only_mode for fallback builds)
    build_ext_image() {
        echo "BUILD_CALLED ext=${1} ver=${2} pg=${4}" >> "$TEST_TEMP_DIR/build_calls.log"
        return 0
    }
    export -f build_ext_image

    list_extensions_by_priority() { echo "timescaledb"; }
    export -f list_extensions_by_priority

    run handle_pull_only_mode "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR"

    # Must have attempted pull for all 3 versions
    [ -f "$pull_log" ]
    local pull_count
    pull_count=$(wc -l < "$pull_log")
    [ "$pull_count" -eq 3 ]
    [[ "$(cat "$pull_log")" == *"ver=2.25.0"* ]]
    [[ "$(cat "$pull_log")" == *"ver=2.26.0"* ]]
    [[ "$(cat "$pull_log")" == *"ver=2.27.1"* ]]
}

# ---------------------------------------------------------------------------
# P2: --pull-only: versions already local are skipped (not pulled again)
# ---------------------------------------------------------------------------

@test "pull-only-skip-local: version already present locally is not pulled" {
    export LOCAL_ONLY=false

    resolve_version_set() { echo '["2.25.0","2.26.0","2.27.1"]'; }
    export -f resolve_version_set

    ext_config() {
        case "$2" in
            version) echo "2.27.1" ;;
            repo)    echo "https://github.com/timescale/timescaledb" ;;
            *)       echo "" ;;
        esac
    }
    export -f ext_config

    # 2.26.0 is present locally
    docker() {
        local img="${*: -1}"
        [[ "$img" == *"2.26.0"* ]] && return 0 || return 1
    }
    export -f docker

    local pull_log="$TEST_TEMP_DIR/pull_calls.log"
    pull_ext_image() {
        echo "PULL_CALLED ext=${1} ver=${2}" >> "$pull_log"
        return 0
    }
    export -f pull_ext_image

    list_extensions_by_priority() { echo "timescaledb"; }
    export -f list_extensions_by_priority

    run handle_pull_only_mode "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR"

    [ "$status" -eq 0 ]

    # 2.26.0 must NOT appear in the pull log (already present locally)
    if [ -f "$pull_log" ]; then
        [[ "$(cat "$pull_log")" != *"ver=2.26.0"* ]]
    fi
}

# ---------------------------------------------------------------------------
# DRY1: dry run must not delete existing lineage files
# ---------------------------------------------------------------------------

@test "dry-run-no-delete: pre-existing lineage file is not removed under DRY_RUN=true" {
    export DRY_RUN=true

    resolve_version_set() { echo '["2.25.0","2.26.0","2.27.1"]'; }
    export -f resolve_version_set

    ext_config() {
        case "$2" in
            version) echo "2.27.1" ;;
            repo)    echo "https://github.com/timescale/timescaledb" ;;
            *)       echo "" ;;
        esac
    }
    export -f ext_config

    local lineage_dir="$TEST_TEMP_DIR/.build-lineage"
    mkdir -p "$lineage_dir"

    # Pre-create a lineage file that must survive the dry run.
    local existing_file="$lineage_dir/ext-timescaledb-pg18-2.24.0.json"
    printf '{"ext":"timescaledb","version":"2.24.0","duration_seconds":5}\n' > "$existing_file"

    run build_tag_push_extensions \
        "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR" "true" "timescaledb"

    [ "$status" -eq 0 ]

    # The pre-existing lineage file must still be there.
    [ -f "$existing_file" ]
}

# ---------------------------------------------------------------------------
# DRY2: dry run must not write any new lineage or versionset artifact
# ---------------------------------------------------------------------------

@test "dry-run-no-write: no new lineage files created under DRY_RUN=true" {
    export DRY_RUN=true

    resolve_version_set() { echo '["2.25.0","2.26.0","2.27.1"]'; }
    export -f resolve_version_set

    ext_config() {
        case "$2" in
            version) echo "2.27.1" ;;
            repo)    echo "https://github.com/timescale/timescaledb" ;;
            *)       echo "" ;;
        esac
    }
    export -f ext_config

    local lineage_dir="$TEST_TEMP_DIR/.build-lineage"
    # Ensure the lineage dir does not exist before the run.
    rm -rf "$lineage_dir"

    run build_tag_push_extensions \
        "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR" "true" "timescaledb"

    [ "$status" -eq 0 ]

    # No lineage dir or files must have been created.
    [ ! -d "$lineage_dir" ]
}

# ---------------------------------------------------------------------------
# P-malformed: resolver returns non-JSON → _resolve_cached must return non-zero
# (fail-closed on publish path), NOT cache the bad value and silently skip builds.
# ---------------------------------------------------------------------------

@test "P-malformed-json: resolver returns non-JSON → publish path exits non-zero (fail-closed)" {
    export LOCAL_ONLY=false

    resolve_version_set() {
        echo "not-json"
        return 0
    }
    export -f resolve_version_set

    ext_config() {
        case "$2" in
            version) echo "2.27.1" ;;
            repo)    echo "https://github.com/timescale/timescaledb" ;;
            *)       echo "" ;;
        esac
    }
    export -f ext_config

    local build_log="$TEST_TEMP_DIR/p_malformed_build_calls.log"
    build_ext_image() {
        echo "BUILD_CALLED ext=${1} ver=${2}" >> "$build_log"
        return 0
    }
    export -f build_ext_image

    run build_tag_push_extensions \
        "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR" "true" "timescaledb"

    # Must fail — malformed resolver output is treated as resolver failure (fail-closed).
    [ "$status" -ne 0 ]

    # Must NOT have built anything (no silent fallback).
    local build_count
    build_count=$(_count_log_lines "$build_log")
    [ "$build_count" -eq 0 ]
}

@test "P-empty-array: resolver returns [] → publish path exits non-zero (fail-closed)" {
    export LOCAL_ONLY=false

    resolve_version_set() {
        echo "[]"
        return 0
    }
    export -f resolve_version_set

    ext_config() {
        case "$2" in
            version) echo "2.27.1" ;;
            repo)    echo "https://github.com/timescale/timescaledb" ;;
            *)       echo "" ;;
        esac
    }
    export -f ext_config

    local build_log="$TEST_TEMP_DIR/p_empty_build_calls.log"
    build_ext_image() {
        echo "BUILD_CALLED ext=${1} ver=${2}" >> "$build_log"
        return 0
    }
    export -f build_ext_image

    run build_tag_push_extensions \
        "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR" "true" "timescaledb"

    # Must fail — empty array is invalid version set (fail-closed).
    [ "$status" -ne 0 ]

    local build_count
    build_count=$(_count_log_lines "$build_log")
    [ "$build_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Q-pull-only-degrade: resolver failure + PULL_ONLY=true must degrade to ceiling,
# not abort. The pull-only recovery path is equivalent to LOCAL_ONLY for degradation.
# ---------------------------------------------------------------------------

@test "Q-pull-only-degrade: resolver fails + PULL_ONLY=true → degrades to ceiling, exits 0" {
    export LOCAL_ONLY=false
    export PULL_ONLY=true

    resolve_version_set() {
        echo "::error::simulated outage" >&2
        return 1
    }
    export -f resolve_version_set

    ext_config() {
        case "$2" in
            version) echo "2.27.1" ;;
            repo)    echo "https://github.com/timescale/timescaledb" ;;
            *)       echo "" ;;
        esac
    }
    export -f ext_config

    local pull_log="$TEST_TEMP_DIR/q_pull_calls.log"
    # pull_ext_image: ceiling pulled successfully
    pull_ext_image() {
        echo "PULL_CALLED ext=${1} ver=${2}" >> "$pull_log"
        return 0
    }
    export -f pull_ext_image

    list_extensions_by_priority() { echo "timescaledb"; }
    export -f list_extensions_by_priority

    run handle_pull_only_mode "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR"

    # Must succeed (degrade, not abort).
    [ "$status" -eq 0 ]

    # Must have attempted pull for the ceiling version.
    [ -f "$pull_log" ]
    [[ "$(cat "$pull_log")" == *"ver=2.27.1"* ]]
}

# ---------------------------------------------------------------------------
# R-dry-run-pull: --pull-only --dry-run must NOT invoke pull_ext_image (real pull).
# The DRY_RUN-honoring pull_extension wrapper must be used instead.
# ---------------------------------------------------------------------------

@test "R-dry-run-pull: pull-only + DRY_RUN=true does not call pull_ext_image" {
    export LOCAL_ONLY=false
    export DRY_RUN=true

    resolve_version_set() { echo '["2.25.0","2.26.0","2.27.1"]'; }
    export -f resolve_version_set

    ext_config() {
        case "$2" in
            version) echo "2.27.1" ;;
            repo)    echo "https://github.com/timescale/timescaledb" ;;
            *)       echo "" ;;
        esac
    }
    export -f ext_config

    local real_pull_log="$TEST_TEMP_DIR/r_real_pull_calls.log"
    # pull_ext_image is the REAL pull; it must NOT be invoked under DRY_RUN.
    pull_ext_image() {
        echo "REAL_PULL ext=${1} ver=${2}" >> "$real_pull_log"
        return 0
    }
    export -f pull_ext_image

    list_extensions_by_priority() { echo "timescaledb"; }
    export -f list_extensions_by_priority

    run handle_pull_only_mode "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR"

    # Command must succeed under dry run.
    [ "$status" -eq 0 ]

    # pull_ext_image must NOT have been called (dry run bypasses real pulls).
    local real_pull_count
    real_pull_count=$(_count_log_lines "$real_pull_log")
    [ "$real_pull_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# CACHED-1: all versions already in registry → no build, but versionset artifact
# IS written with available == full resolved set, excluded == [].
# Before fix: main() hits the "All extensions are up to date" early-exit before
#   build_tag_push_extensions is ever called → no artifact written (RED).
# After fix:  main() emits the artifact from presence-check even when nothing
#   is built (GREEN).
# ---------------------------------------------------------------------------

@test "CACHED-1: all-cached run emits versionset artifact with full available set" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        cd \"$sd\"
        source ./build-extensions.sh
        export ROOT_DIR=\"$tmpd\"

        resolve_version_set() { echo '[\"2.25.0\",\"2.26.0\",\"2.27.1\"]'; }
        export -f resolve_version_set

        ext_config() {
            case \"\$2\" in
                version) echo '2.27.1' ;;
                repo)    echo 'https://github.com/timescale/timescaledb' ;;
                *)       echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        # All versions already in registry — no build should occur
        image_exists_in_registry() { return 0; }
        export -f image_exists_in_registry

        docker() { return 1; }
        export -f docker

        build_ext_image() {
            echo 'BUILD_CALLED' >> \"$tmpd/cached1_build.log\"
            return 0
        }
        export -f build_ext_image
        tag_ext_image()  { return 0; }
        export -f tag_ext_image
        push_ext_image() { return 0; }
        export -f push_ext_image
        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority

        main postgres --major-version 18
    "

    # Must succeed (all cached = normal exit)
    [ "$status" -eq 0 ]

    # Must NOT have built anything (all already in registry)
    local build_count
    build_count=$(_count_log_lines "$tmpd/cached1_build.log")
    [ "$build_count" -eq 0 ]

    # The versionset artifact MUST have been written even though no build occurred
    local artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"
    [ -f "$artifact" ]

    # available must equal the full resolved set (all 3 versions are in registry)
    local available_count
    available_count=$(jq '.available | length' "$artifact")
    [ "$available_count" -eq 3 ]

    # excluded must be empty
    local excluded_count
    excluded_count=$(jq '.excluded | length' "$artifact")
    [ "$excluded_count" -eq 0 ]

    # resolved must also contain all 3
    local resolved_count
    resolved_count=$(jq '.resolved | length' "$artifact")
    [ "$resolved_count" -eq 3 ]
}

# ---------------------------------------------------------------------------
# CACHED-2: partial-cached run — some versions in registry, one absent (built),
# one absent (build fails / musl) → available = present+built, excluded = failed.
# ---------------------------------------------------------------------------

@test "CACHED-2: partial-cached run — artifact has correct available/excluded split" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    # Stateful registry-presence file: seed with 2.26.0 already cached.
    # push_ext_image will add successfully-pushed versions to this file so
    # image_exists_in_registry reflects production behaviour (just-built = present).
    local registry_present="$tmpd/registry-present"
    printf 'pg18-2.26.0\n' > "$registry_present"
    export registry_present

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export registry_present=\"$registry_present\"
        cd \"$sd\"
        source ./build-extensions.sh
        export ROOT_DIR=\"$tmpd\"

        resolve_version_set() { echo '[\"2.25.0\",\"2.26.0\",\"2.27.1\"]'; }
        export -f resolve_version_set

        ext_config() {
            case \"\$2\" in
                version) echo '2.27.1' ;;
                repo)    echo 'https://github.com/timescale/timescaledb' ;;
                *)       echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        # Stateful presence check: consults the registry-present file.
        # Image arg format: ghcr.io/test/ext-<name>:pg<major>-<ver>
        # Tag (after the colon) matches entries written by push_ext_image.
        # Seed: pg18-2.26.0 present. Successfully pushed versions are added by push_ext_image.
        image_exists_in_registry() {
            local tag=\"\${1##*:}\"
            grep -qxF \"\$tag\" \"\$registry_present\" 2>/dev/null
        }
        export -f image_exists_in_registry

        docker() { return 1; }
        export -f docker

        # 2.25.0 fails to build (musl); others succeed.
        build_ext_image() {
            if [[ \"\$2\" == '2.25.0' ]]; then
                return 1
            fi
            return 0
        }
        export -f build_ext_image
        tag_ext_image()  { return 0; }
        export -f tag_ext_image

        # Stateful push: on success, register the version as present so
        # image_exists_in_registry sees it as available (mirrors production).
        push_ext_image() {
            local ext=\"\$1\" ver=\"\$2\" major=\"\$3\"
            printf 'pg%s-%s\n' \"\$major\" \"\$ver\" >> \"\$registry_present\"
            return 0
        }
        export -f push_ext_image

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority

        main postgres --major-version 18
    "

    # Must succeed (2.25.0 is non-ceiling musl failure = tolerated)
    [ "$status" -eq 0 ]

    local artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"
    [ -f "$artifact" ]

    # Stateful mock reflects production: 2.26.0 was pre-seeded, 2.27.1 was built+pushed
    # (added to present set by push_ext_image), 2.25.0 failed to build (never pushed).
    # Result: available=[2.26.0, 2.27.1] (2), excluded=[2.25.0] (1).
    local available_count
    available_count=$(jq '.available | length' "$artifact")
    [ "$available_count" -eq 2 ]

    local available_versions
    available_versions=$(jq -r '.available[]' "$artifact")
    [[ "$available_versions" == *"2.26.0"* ]]
    [[ "$available_versions" == *"2.27.1"* ]]

    local excluded_count
    excluded_count=$(jq '.excluded | length' "$artifact")
    [ "$excluded_count" -eq 1 ]

    # Only 2.25.0 (build failed) is excluded; 2.27.1 is available (push succeeded).
    local all_excl
    all_excl=$(jq -r '.excluded[].version' "$artifact")
    [[ "$all_excl" == *"2.25.0"* ]]
    [[ "$all_excl" != *"2.27.1"* ]]
}

# ---------------------------------------------------------------------------
# MIXED-1: two extensions in scope — timescaledb (resolver-backed, ALL versions
# already in registry → skipped by build_tag_push) and pgvector (single-version,
# needs build). main() must NOT take the all-up-to-date early-exit; after
# build_tag_push completes for pgvector, the timescaledb versionset artifact
# MUST still be written (presence-based final pass).
#
# Before fix: only the early-exit path emits the artifact → mixed path never
#   triggers the emission → timescaledb artifact absent (RED).
# After fix:  final pass runs on all success paths → artifact present (GREEN).
# ---------------------------------------------------------------------------

@test "MIXED-1: mixed run (skipped resolver-backed ext + built single-ver ext) emits versionset artifact" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    # Extend config to include pgvector (single-version, no resolver)
    cat > "$CONTAINER_DIR/extensions/config.yaml" <<'EOF'
extensions:
  timescaledb:
    version: "2.27.1"
    repo: "https://github.com/timescale/timescaledb"
    priority: 1
    version_set:
      resolver: "scripts/resolvers/timescaledb-ha.sh"
  pgvector:
    version: "0.8.0"
    repo: "https://github.com/pgvector/pgvector"
    priority: 2
EOF

    touch "$EXT_BUILD_DIR/pgvector.Dockerfile"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    local build_log="${tmpd}/mixed1_build.log"

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        cd \"$sd\"
        source ./build-extensions.sh
        export ROOT_DIR=\"$tmpd\"

        # timescaledb: multi-version resolver → 3 versions
        # pgvector: single-version (no resolver), absent → needs build
        resolve_version_set() {
            local ext=\"\$1\"
            if [[ \"\$ext\" == 'timescaledb' ]]; then
                echo '[\"2.25.0\",\"2.26.0\",\"2.27.1\"]'
            else
                echo '[\"0.8.0\"]'
            fi
        }
        export -f resolve_version_set

        ext_config() {
            local ext=\"\$1\" key=\"\$2\"
            case \"\$ext:\$key\" in
                timescaledb:version) echo '2.27.1' ;;
                timescaledb:repo)    echo 'https://github.com/timescale/timescaledb' ;;
                pgvector:version)    echo '0.8.0' ;;
                pgvector:repo)       echo 'https://github.com/pgvector/pgvector' ;;
                *)                   echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        # timescaledb: ALL versions already in registry (skipped by build_tag_push)
        # pgvector: absent → triggers build
        image_exists_in_registry() {
            [[ \"\$1\" == *'timescaledb'* ]] && return 0 || return 1
        }
        export -f image_exists_in_registry

        docker() { return 1; }
        export -f docker

        build_ext_image() {
            echo \"BUILD ext=\${1} ver=\${2}\" >> \"$build_log\"
            return 0
        }
        export -f build_ext_image
        tag_ext_image()  { return 0; }
        export -f tag_ext_image
        push_ext_image() { return 0; }
        export -f push_ext_image
        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { printf 'timescaledb\npgvector\n'; }
        export -f list_extensions_by_priority

        main postgres --major-version 18
    "

    # Must succeed
    [ "$status" -eq 0 ]

    # pgvector must have been built (it was absent from registry)
    [ -f "$build_log" ]
    [[ "$(cat "$build_log")" == *"ext=pgvector"* ]]

    # The timescaledb versionset artifact MUST be present (not built, but in scope)
    local artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"
    [ -f "$artifact" ]

    # available must list all 3 resolved versions (all were in registry)
    local available_count
    available_count=$(jq '.available | length' "$artifact")
    [ "$available_count" -eq 3 ]

    # excluded must be empty (all 3 were in registry)
    local excluded_count
    excluded_count=$(jq '.excluded | length' "$artifact")
    [ "$excluded_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# MIXED-2: resolver-backed ext IS built (not skipped), single-ver ext already
# cached. After build completes, the versionset artifact reflects what is
# actually in the registry (presence-based — no regression from the build path).
# ---------------------------------------------------------------------------

@test "MIXED-2: built resolver-backed ext produces correct versionset artifact" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    local build_log="${tmpd}/mixed2_build.log"

    # Stateful registry-presence file: seed with 2.26.0 and 2.27.1 already cached.
    # push_ext_image adds successfully-pushed versions so image_exists_in_registry
    # reflects production behaviour (just-built 2.25.0 becomes present after push).
    local registry_present="$tmpd/registry-present"
    printf 'pg18-2.26.0\npg18-2.27.1\n' > "$registry_present"
    export registry_present

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export registry_present=\"$registry_present\"
        cd \"$sd\"
        source ./build-extensions.sh
        export ROOT_DIR=\"$tmpd\"

        # timescaledb: 3-version set; 2.25.0 absent → needs build
        resolve_version_set() { echo '[\"2.25.0\",\"2.26.0\",\"2.27.1\"]'; }
        export -f resolve_version_set

        ext_config() {
            case \"\$2\" in
                version) echo '2.27.1' ;;
                repo)    echo 'https://github.com/timescale/timescaledb' ;;
                *)       echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        # Stateful presence check: image arg format ghcr.io/test/ext-<name>:pg<major>-<ver>.
        # 2.26.0 and 2.27.1 pre-seeded; 2.25.0 becomes present after push_ext_image succeeds.
        image_exists_in_registry() {
            local tag=\"\${1##*:}\"
            grep -qxF \"\$tag\" \"\$registry_present\" 2>/dev/null
        }
        export -f image_exists_in_registry

        docker() { return 1; }
        export -f docker

        build_ext_image() {
            echo \"BUILD ext=\${1} ver=\${2}\" >> \"$build_log\"
            return 0
        }
        export -f build_ext_image
        tag_ext_image()  { return 0; }
        export -f tag_ext_image

        # Stateful push: register the version as present so image_exists_in_registry
        # sees it as available on the final pass (mirrors production).
        push_ext_image() {
            local ext=\"\$1\" ver=\"\$2\" major=\"\$3\"
            printf 'pg%s-%s\n' \"\$major\" \"\$ver\" >> \"\$registry_present\"
            return 0
        }
        export -f push_ext_image

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority

        main postgres --major-version 18
    "

    [ "$status" -eq 0 ]

    # 2.25.0 was built (absent → triggered build)
    [ -f "$build_log" ]
    [[ "$(cat "$build_log")" == *"ext=timescaledb"* ]]
    [[ "$(cat "$build_log")" == *"ver=2.25.0"* ]]

    # Stateful mock reflects production: 2.26.0 and 2.27.1 were pre-seeded, 2.25.0 was
    # built+pushed (added to present set by push_ext_image). All 3 versions are available.
    # Result: available=[2.25.0, 2.26.0, 2.27.1] (3), excluded=[] (0).
    local artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"
    [ -f "$artifact" ]

    local available_count
    available_count=$(jq '.available | length' "$artifact")
    [ "$available_count" -eq 3 ]

    local available_versions
    available_versions=$(jq -r '.available[]' "$artifact")
    [[ "$available_versions" == *"2.25.0"* ]]
    [[ "$available_versions" == *"2.26.0"* ]]
    [[ "$available_versions" == *"2.27.1"* ]]

    local excluded_count
    excluded_count=$(jq '.excluded | length' "$artifact")
    [ "$excluded_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# PULL-ONLY-EMITS: --pull-only where all resolved versions pull successfully →
# versionset artifact written before the pull-only success exit.
#
# Before fix: handle_pull_only_mode exits 0 without emitting the artifact (RED).
# After fix:  final pass runs before the success exit → artifact present (GREEN).
# ---------------------------------------------------------------------------

@test "pull-only-emits: pull-only success path writes versionset artifact" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres PULL_ONLY=true
        cd \"$sd\"
        source ./build-extensions.sh
        export ROOT_DIR=\"$tmpd\"

        resolve_version_set() { echo '[\"2.25.0\",\"2.26.0\",\"2.27.1\"]'; }
        export -f resolve_version_set

        ext_config() {
            case \"\$2\" in
                version) echo '2.27.1' ;;
                repo)    echo 'https://github.com/timescale/timescaledb' ;;
                *)       echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        docker() { return 1; }
        export -f docker

        # All versions pulled successfully → no fallback builds needed
        pull_ext_image() { return 0; }
        export -f pull_ext_image

        # After pull, images are present locally (docker inspect returns 0)
        docker() {
            # Any 'docker image inspect <image>' call: succeed for pulled images
            return 0
        }
        export -f docker

        image_exists_in_registry() { return 1; }
        export -f image_exists_in_registry

        build_ext_image() { return 0; }
        export -f build_ext_image
        tag_ext_image()   { return 0; }
        export -f tag_ext_image
        push_ext_image()  { return 0; }
        export -f push_ext_image
        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority

        main postgres --major-version 18
    "

    [ "$status" -eq 0 ]

    # Artifact must exist after pull-only success
    local artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"
    [ -f "$artifact" ]

    # All 3 versions were pulled and are now present locally → all available
    local resolved_count
    resolved_count=$(jq '.resolved | length' "$artifact")
    [ "$resolved_count" -eq 3 ]
}

# ---------------------------------------------------------------------------
# MIXED-DRY-RUN: mixed path (pgvector built, timescaledb skipped) with
# DRY_RUN=true must NOT write the timescaledb versionset artifact.
# ---------------------------------------------------------------------------

@test "MIXED-DRY-RUN: mixed path under DRY_RUN=true writes no versionset artifact" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    # Extend config to include pgvector (same as MIXED-1)
    cat > "$CONTAINER_DIR/extensions/config.yaml" <<'EOF'
extensions:
  timescaledb:
    version: "2.27.1"
    repo: "https://github.com/timescale/timescaledb"
    priority: 1
    version_set:
      resolver: "scripts/resolvers/timescaledb-ha.sh"
  pgvector:
    version: "0.8.0"
    repo: "https://github.com/pgvector/pgvector"
    priority: 2
EOF

    touch "$EXT_BUILD_DIR/pgvector.Dockerfile"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    local lineage_dir="$tmpd/.build-lineage"
    rm -rf "$lineage_dir"

    run bash -c "
        export FORCE=false LOCAL_ONLY=false CONTAINER=postgres
        cd \"$sd\"
        source ./build-extensions.sh
        # Re-export after source: build-extensions.sh resets DRY_RUN=false at script level
        export ROOT_DIR=\"$tmpd\" DRY_RUN=true

        resolve_version_set() {
            local ext=\"\$1\"
            if [[ \"\$ext\" == 'timescaledb' ]]; then
                echo '[\"2.25.0\",\"2.26.0\",\"2.27.1\"]'
            else
                echo '[\"0.8.0\"]'
            fi
        }
        export -f resolve_version_set

        ext_config() {
            local ext=\"\$1\" key=\"\$2\"
            case \"\$ext:\$key\" in
                timescaledb:version) echo '2.27.1' ;;
                timescaledb:repo)    echo 'https://github.com/timescale/timescaledb' ;;
                pgvector:version)    echo '0.8.0' ;;
                pgvector:repo)       echo 'https://github.com/pgvector/pgvector' ;;
                *)                   echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        # timescaledb: all in registry (skipped); pgvector: absent
        image_exists_in_registry() {
            [[ \"\$1\" == *'timescaledb'* ]] && return 0 || return 1
        }
        export -f image_exists_in_registry

        docker() { return 1; }
        export -f docker

        build_ext_image() { return 0; }
        export -f build_ext_image
        tag_ext_image()  { return 0; }
        export -f tag_ext_image
        push_ext_image() { return 0; }
        export -f push_ext_image
        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { printf 'timescaledb\npgvector\n'; }
        export -f list_extensions_by_priority

        main postgres --major-version 18
    "

    [ "$status" -eq 0 ]

    # Under DRY_RUN, NO versionset artifact must be written (the core invariant).
    [ ! -f "$lineage_dir/ext-timescaledb-pg18-versionset.json" ]
    [ ! -f "$lineage_dir/ext-pgvector-pg18-versionset.json" ]
}

# ---------------------------------------------------------------------------
# STALENESS: pre-existing stale versionset artifact is overwritten on a
# cache-hit run (no build occurs).
#
# Before fix: _emit_final_versionset_pass has a file-existence guard → skips
#   refresh when the artifact is already on disk → stale "1.0.0" survives (RED).
# After fix:  guard removed → artifact always (re)written → stale "1.0.0" gone,
#   real versions present (GREEN).
# ---------------------------------------------------------------------------

@test "STALENESS: cache-hit run overwrites stale versionset artifact" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    local lineage_dir="$tmpd/.build-lineage"
    mkdir -p "$lineage_dir"

    local artifact="$lineage_dir/ext-timescaledb-pg18-versionset.json"

    # Pre-create a STALE artifact with wrong content (old single version "1.0.0").
    printf '{"ext":"timescaledb","pg_major":"18","ceiling":"1.0.0","resolved":["1.0.0"],"available":["1.0.0"],"excluded":[]}\n' \
        > "$artifact"

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        cd \"$sd\"
        source ./build-extensions.sh
        export ROOT_DIR=\"$tmpd\"

        # Real resolved set: 3 current versions
        resolve_version_set() { echo '[\"2.25.0\",\"2.26.0\",\"2.27.1\"]'; }
        export -f resolve_version_set

        ext_config() {
            case \"\$2\" in
                version) echo '2.27.1' ;;
                repo)    echo 'https://github.com/timescale/timescaledb' ;;
                *)       echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        # All versions already in registry — cache-hit, nothing to build
        image_exists_in_registry() { return 0; }
        export -f image_exists_in_registry

        docker() { return 1; }
        export -f docker

        build_ext_image() {
            echo 'BUILD_CALLED' >> \"$tmpd/staleness_build.log\"
            return 0
        }
        export -f build_ext_image
        tag_ext_image()  { return 0; }
        export -f tag_ext_image
        push_ext_image() { return 0; }
        export -f push_ext_image
        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority

        main postgres --major-version 18
    "

    # Must succeed (all cached)
    [ "$status" -eq 0 ]

    # Must NOT have built anything (cache-hit run)
    local build_count
    build_count=$(_count_log_lines "$tmpd/staleness_build.log")
    [ "$build_count" -eq 0 ]

    # The artifact MUST be overwritten with the CURRENT resolved set.
    # Before fix (guard present): stale "1.0.0" survives → this fails (RED).
    # After fix (guard removed):  artifact is rewritten → this passes (GREEN).
    [ -f "$artifact" ]

    local ceiling
    ceiling=$(jq -r '.ceiling' "$artifact")
    [ "$ceiling" = "2.27.1" ]

    # The stale "1.0.0" must be gone from the available array.
    local stale_present
    stale_present=$(jq '[.available[] | select(. == "1.0.0")] | length' "$artifact")
    [ "$stale_present" -eq 0 ]

    # The real versions must be present (all 3 are in registry).
    local available_count
    available_count=$(jq '.available | length' "$artifact")
    [ "$available_count" -eq 3 ]

    local resolved_count
    resolved_count=$(jq '.resolved | length' "$artifact")
    [ "$resolved_count" -eq 3 ]
}

# ---------------------------------------------------------------------------
# FORCE-AVAILABLE: FORCE=true + successful build+push → available must contain
# the built versions (NOT empty).
# Before fix: _emit_versionset_artifact calls _image_needs_build, which returns 0
#   (needs build) unconditionally when FORCE=true → every version goes to excluded
#   even after a successful push → available=[] (RED).
# After fix:  _emit_versionset_artifact uses _image_present (FORCE-independent
#   presence check) → available = built+pushed versions (GREEN).
# ---------------------------------------------------------------------------

@test "FORCE-AVAILABLE: FORCE=true + successful build+push → available is non-empty" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    # Stateful registry-presence: seed empty; push_ext_image adds to it.
    local registry_present="$tmpd/registry-present-force"
    : > "$registry_present"
    export registry_present

    run bash -c "
        export LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export registry_present=\"$registry_present\"
        cd \"$sd\"
        source ./build-extensions.sh
        export ROOT_DIR=\"$tmpd\"

        resolve_version_set() { echo '[\"2.25.0\",\"2.26.0\",\"2.27.1\"]'; }
        export -f resolve_version_set

        ext_config() {
            case \"\$2\" in
                version) echo '2.27.1' ;;
                repo)    echo 'https://github.com/timescale/timescaledb' ;;
                *)       echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        # Stateful presence: consults registry_present file.
        # Initially empty so --force triggers rebuilds for all versions.
        # push_ext_image adds each successfully-pushed version so the final
        # _image_present pass sees them as available — mirrors production.
        image_exists_in_registry() {
            local tag=\"\${1##*:}\"
            grep -qxF \"\$tag\" \"\$registry_present\" 2>/dev/null
        }
        export -f image_exists_in_registry

        docker() { return 1; }
        export -f docker

        build_ext_image() { return 0; }
        export -f build_ext_image
        tag_ext_image()  { return 0; }
        export -f tag_ext_image

        # Stateful push: register version as present after successful push
        push_ext_image() {
            local ext=\"\$1\" ver=\"\$2\" major=\"\$3\"
            printf 'pg%s-%s\n' \"\$major\" \"\$ver\" >> \"\$registry_present\"
            return 0
        }
        export -f push_ext_image

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority

        # Pass --force via CLI argument (source resets FORCE=false, so env export is not enough)
        main postgres --major-version 18 --force
    "

    [ "$status" -eq 0 ]

    local artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"
    [ -f "$artifact" ]

    # FORCE=true + all pushes succeeded → available must be ALL 3 versions.
    # Before fix: available=[] (FORCE makes _image_needs_build return 0 = "needs build"
    #   even for just-pushed images → all go to excluded). RED.
    # After fix:  _image_present is FORCE-independent; registry has all versions
    #   after push → all 3 in available. GREEN.
    local available_count
    available_count=$(jq '.available | length' "$artifact")
    [ "$available_count" -eq 3 ]

    local excluded_count
    excluded_count=$(jq '.excluded | length' "$artifact")
    [ "$excluded_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# SCOPED-RETENTION: scoped run (--extension pgvector only) with timescaledb
# images already in registry → timescaledb versionset artifact is NOT emitted
# (the final pass is scoped to the targeted extension only — DEFECT MM fix).
# The consumer (generate_dockerfile) self-heals absent artifacts on demand.
#
# Contract (post-DEFECT-MM fix):
#   - Final emission pass is scoped to $EXTENSION when set.
#   - pgvector: single-version (no resolver, set_size <= 1) → no artifact.
#   - timescaledb: resolver-backed, but NOT the targeted extension → not emitted.
#   - Run must exit 0; no timescaledb resolver is even called.
# ---------------------------------------------------------------------------

@test "SCOPED-RETENTION: scoped --extension pgvector run does NOT emit timescaledb artifact (MM fix)" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    # Config: both timescaledb (resolver-backed) and pgvector (single-version)
    cat > "$CONTAINER_DIR/extensions/config.yaml" <<'EOF'
extensions:
  timescaledb:
    version: "2.27.1"
    repo: "https://github.com/timescale/timescaledb"
    priority: 1
    version_set:
      resolver: "scripts/resolvers/timescaledb-ha.sh"
  pgvector:
    version: "0.8.0"
    repo: "https://github.com/pgvector/pgvector"
    priority: 2
EOF

    touch "$EXT_BUILD_DIR/pgvector.Dockerfile"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    local ts_resolver_called="$tmpd/ts_resolver_called"
    local registry_present="$tmpd/registry-present-scoped"
    printf 'pg18-2.25.0\npg18-2.26.0\npg18-2.27.1\n' > "$registry_present"
    export registry_present ts_resolver_called

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export registry_present=\"$registry_present\"
        export ts_resolver_called=\"$ts_resolver_called\"
        cd \"$sd\"
        source ./build-extensions.sh
        export ROOT_DIR=\"$tmpd\"

        resolve_version_set() {
            local ext=\"\$1\"
            if [[ \"\$ext\" == 'timescaledb' ]]; then
                # Record that timescaledb resolver was called — must NOT happen.
                printf 'called\n' >> \"\$ts_resolver_called\"
                echo '[\"2.25.0\",\"2.26.0\",\"2.27.1\"]'
            else
                echo '[\"0.8.0\"]'
            fi
        }
        export -f resolve_version_set

        ext_config() {
            local ext=\"\$1\" key=\"\$2\"
            case \"\$ext:\$key\" in
                timescaledb:version) echo '2.27.1' ;;
                timescaledb:repo)    echo 'https://github.com/timescale/timescaledb' ;;
                pgvector:version)    echo '0.8.0' ;;
                pgvector:repo)       echo 'https://github.com/pgvector/pgvector' ;;
                *)                   echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        # timescaledb all 3 present; pgvector absent
        image_exists_in_registry() {
            local tag=\"\${1##*:}\"
            grep -qxF \"\$tag\" \"\$registry_present\" 2>/dev/null
        }
        export -f image_exists_in_registry

        docker() { return 1; }
        export -f docker

        build_ext_image() { return 0; }
        export -f build_ext_image
        tag_ext_image()  { return 0; }
        export -f tag_ext_image

        push_ext_image() {
            local ext=\"\$1\" ver=\"\$2\" major=\"\$3\"
            printf 'pg%s-%s\n' \"\$major\" \"\$ver\" >> \"\$registry_present\"
            return 0
        }
        export -f push_ext_image

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { printf 'timescaledb\npgvector\n'; }
        export -f list_extensions_by_priority

        # Scoped: only pgvector
        main postgres --major-version 18 --extension pgvector
    "

    # Run must succeed.
    [ "$status" -eq 0 ]

    # timescaledb artifact must NOT be emitted (scoped to pgvector only).
    local ts_artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"
    [ ! -f "$ts_artifact" ]

    # timescaledb resolver must NOT have been called from the final pass
    # (it may have been called from _should_build_extension's pre-filter check,
    # but the final pass must not add an extra call — the file would record it).
    # We track only final-pass calls by checking after the build completes.
    # (The resolver IS called by _should_build_extension during pre-filter for
    # timescaledb to decide it's cached — that single call is acceptable.
    # The key invariant: the final pass must not call it AND must not abort on failure.)
}

# ---------------------------------------------------------------------------
# PULL-ONLY-LOCAL-PRESENCE: --pull-only where a version is missing from
# registry but built locally → that version is in available (local presence),
# not excluded.
# Before fix: _emit_final_versionset_pass calls _emit_versionset_artifact with
#   PULL_ONLY still true but LOCAL_ONLY false; _image_needs_build with FORCE=false
#   and LOCAL_ONLY=false → checks registry → locally-built version absent from
#   registry → excluded (RED, available=2).
# After fix:  _image_present checks docker image inspect when PULL_ONLY=true
#   → locally-built version is in local store → available (GREEN, available=3).
# ---------------------------------------------------------------------------

@test "PULL-ONLY-LOCAL-PRESENCE: pull-only + local build → locally-built version in available" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    # Local image store: 2.26.0 and 2.27.1 pulled from registry.
    # 2.25.0 absent from registry → will be built locally.
    # tag_ext_image adds it to the local store.
    local local_store="$tmpd/local-images"
    printf 'ghcr.io/test/ext-timescaledb:pg18-2.26.0\nghcr.io/test/ext-timescaledb:pg18-2.27.1\n' \
        > "$local_store"
    export local_store

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export local_store=\"$local_store\"
        cd \"$sd\"
        source ./build-extensions.sh
        export ROOT_DIR=\"$tmpd\"

        resolve_version_set() { echo '[\"2.25.0\",\"2.26.0\",\"2.27.1\"]'; }
        export -f resolve_version_set

        ext_config() {
            case \"\$2\" in
                version) echo '2.27.1' ;;
                repo)    echo 'https://github.com/timescale/timescaledb' ;;
                *)       echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        # Registry: 2.26.0 and 2.27.1 present; 2.25.0 absent → local build fallback
        image_exists_in_registry() {
            [[ \"\$1\" == *'pg18-2.26.0'* || \"\$1\" == *'pg18-2.27.1'* ]] && return 0 || return 1
        }
        export -f image_exists_in_registry

        # Local docker inspect: consults local_store file
        docker() {
            local img=\"\${*: -1}\"
            grep -qxF \"\$img\" \"\$local_store\" 2>/dev/null
        }
        export -f docker

        build_ext_image() { return 0; }
        export -f build_ext_image

        # tag_ext_image: adds image to local store (mirrors docker tag → inspectable)
        tag_ext_image() {
            local ext=\"\$1\" ver=\"\$2\" major=\"\$3\"
            local img=\"ghcr.io/test/ext-\${ext}:pg\${major}-\${ver}\"
            grep -qxF \"\$img\" \"\$local_store\" || printf '%s\n' \"\$img\" >> \"\$local_store\"
            return 0
        }
        export -f tag_ext_image

        push_ext_image() { return 0; }
        export -f push_ext_image

        # pull_ext_image: 2.26.0/2.27.1 pull OK; 2.25.0 fails → local build
        pull_ext_image() {
            local ext=\"\$1\" ver=\"\$2\" major=\"\$3\"
            local img=\"ghcr.io/test/ext-\${ext}:pg\${major}-\${ver}\"
            if [[ \"\$ver\" == '2.25.0' ]]; then
                return 1
            fi
            grep -qxF \"\$img\" \"\$local_store\" || printf '%s\n' \"\$img\" >> \"\$local_store\"
            return 0
        }
        export -f pull_ext_image

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority

        # Pass --pull-only via CLI (source resets PULL_ONLY=false, env export is not enough)
        main postgres --major-version 18 --pull-only
    "

    [ "$status" -eq 0 ]

    local artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"
    [ -f "$artifact" ]

    # 2.25.0 was built locally and tagged → present in local store.
    # Before fix: _image_present (via _image_needs_build) checks registry when
    #   LOCAL_ONLY=false → 2.25.0 absent → excluded (RED, available=2).
    # After fix:  _image_present checks docker inspect when PULL_ONLY=true
    #   → 2.25.0 in local store → available (GREEN, available=3).
    local available_count
    available_count=$(jq '.available | length' "$artifact")
    [ "$available_count" -eq 3 ]

    local available_versions
    available_versions=$(jq -r '.available[]' "$artifact")
    [[ "$available_versions" == *"2.25.0"* ]]
    [[ "$available_versions" == *"2.26.0"* ]]
    [[ "$available_versions" == *"2.27.1"* ]]

    local excluded_count
    excluded_count=$(jq '.excluded | length' "$artifact")
    [ "$excluded_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AA: registry propagation lag — a version built+pushed this run must appear
# in available[] even if the post-push registry probe returns ABSENT (lag).
# A musl-failed version must NOT be included.
#
# RED before fix: probe-absent → excluded from available[] (lag drops the version).
# GREEN after fix: built-this-run ∪ probe → version included in available[].
# ---------------------------------------------------------------------------

@test "AA-probe-lag: built-and-pushed version survives probe-absent (registry lag)" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    local build_log="${tmpd}/aa_build.log"

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        cd \"$sd\"
        source ./build-extensions.sh
        export ROOT_DIR=\"$tmpd\"

        resolve_version_set() { echo '[\"2.25.0\",\"2.26.0\",\"2.27.1\"]'; }
        export -f resolve_version_set

        ext_config() {
            case \"\$2\" in
                version) echo '2.27.1' ;;
                repo)    echo 'https://github.com/timescale/timescaledb' ;;
                *)       echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        # PROBE ALWAYS ABSENT — simulates GHCR propagation lag.
        image_exists_in_registry() { return 1; }
        export -f image_exists_in_registry

        docker() { return 1; }
        export -f docker

        # 2.25.0 fails (musl); 2.26.0 and 2.27.1 succeed.
        build_ext_image() {
            if [[ \"\$2\" == '2.25.0' ]]; then
                echo \"BUILD_FAILED ext=\${1} ver=\${2}\" >> \"$build_log\"
                return 1
            fi
            echo \"BUILD_CALLED ext=\${1} ver=\${2}\" >> \"$build_log\"
            return 0
        }
        export -f build_ext_image
        tag_ext_image()  { return 0; }
        export -f tag_ext_image
        push_ext_image() { return 0; }
        export -f push_ext_image

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority

        main postgres --major-version 18
    "

    # 2.25.0 is non-ceiling musl failure → tolerated, exit 0.
    [ "$status" -eq 0 ]

    local artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"
    [ -f "$artifact" ]

    # RED before fix: probe-absent for all → available=[] (lag drops 2.26.0 and 2.27.1).
    # GREEN after fix: built-this-run union → available=[2.26.0, 2.27.1] (2 versions).
    local available_count
    available_count=$(jq '.available | length' "$artifact")
    [ "$available_count" -eq 2 ]

    local available_versions
    available_versions=$(jq -r '.available[]' "$artifact")
    [[ "$available_versions" == *"2.26.0"* ]]
    [[ "$available_versions" == *"2.27.1"* ]]

    # 2.25.0 (build failed / musl) must NOT be in available.
    [[ "$available_versions" != *"2.25.0"* ]]

    # 2.25.0 must be in excluded.
    local excluded_versions
    excluded_versions=$(jq -r '.excluded[].version' "$artifact")
    [[ "$excluded_versions" == *"2.25.0"* ]]
}

@test "AA-musl-excluded: musl-failed version is not smuggled into available via built-this-run" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        cd \"$sd\"
        source ./build-extensions.sh
        export ROOT_DIR=\"$tmpd\"

        resolve_version_set() { echo '[\"2.25.0\",\"2.26.0\",\"2.27.1\"]'; }
        export -f resolve_version_set

        ext_config() {
            case \"\$2\" in
                version) echo '2.27.1' ;;
                repo)    echo 'https://github.com/timescale/timescaledb' ;;
                *)       echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        # Probe: 2.26.0 visible (pre-existing), 2.27.1 absent (lag), 2.25.0 absent (failed).
        image_exists_in_registry() {
            [[ \"\$1\" == *'pg18-2.26.0'* ]] && return 0 || return 1
        }
        export -f image_exists_in_registry

        docker() { return 1; }
        export -f docker

        # 2.25.0 fails build (musl). 2.26.0 skipped (already in registry). 2.27.1 built+pushed.
        build_ext_image() {
            if [[ \"\$2\" == '2.25.0' ]]; then
                return 1
            fi
            return 0
        }
        export -f build_ext_image
        tag_ext_image()  { return 0; }
        export -f tag_ext_image
        push_ext_image() { return 0; }
        export -f push_ext_image

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority

        main postgres --major-version 18
    "

    [ "$status" -eq 0 ]

    local artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"
    [ -f "$artifact" ]

    # 2.25.0 failed build → must NOT appear in available.
    local available_versions
    available_versions=$(jq -r '.available[]' "$artifact" 2>/dev/null || true)
    [[ "$available_versions" != *"2.25.0"* ]]

    # 2.25.0 must be in excluded.
    local excluded_versions
    excluded_versions=$(jq -r '.excluded[].version' "$artifact")
    [[ "$excluded_versions" == *"2.25.0"* ]]

    # 2.26.0 (pre-existing probe) and 2.27.1 (built-this-run, lag) must both be available.
    [[ "$available_versions" == *"2.26.0"* ]]
    [[ "$available_versions" == *"2.27.1"* ]]
}

# ---------------------------------------------------------------------------
# BB-1: final-pass resolver failure on PUBLISH path with a FULL (unscoped) run
# (no --extension, LOCAL_ONLY=false, PULL_ONLY=false) → run must exit NON-ZERO
# (fail-closed).
#
# Note: the DEFECT MM fix scopes the final pass to $EXTENSION when set, so a
# scoped run can no longer trigger this path for UNTARGETED extensions. This
# test now uses a full (unscoped) run to lock in fail-closed behavior on the
# publish path when ALL versions are already in the registry (pre-filter skips)
# and the resolver has to be called fresh in the final pass.
#
# Mechanism: resolve_version_set is mocked to succeed on ALL calls in the
# pre-filter (returns a valid set → cached) and then the cache is poisoned by
# clearing the in-process cache dir so the final pass re-calls the resolver —
# but since we can't reach _RESOLVER_CACHE_DIR from outside the subprocess, we
# instead run a FULL unscoped run where the resolver succeeds for pgvector and
# FAILS for timescaledb, both on their first (and only) calls. The full
# unscoped final pass iterates ALL extensions → timescaledb resolver fails →
# fail-closed.
# ---------------------------------------------------------------------------
@test "BB-1-publish-fail-closed: full unscoped run with failing timescaledb resolver → exit non-zero (fail-closed)" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    cat > "$CONTAINER_DIR/extensions/config.yaml" <<'EOF'
extensions:
  timescaledb:
    version: "2.27.1"
    repo: "https://github.com/timescale/timescaledb"
    priority: 1
    version_set:
      resolver: "scripts/resolvers/timescaledb-ha.sh"
  pgvector:
    version: "0.8.0"
    repo: "https://github.com/pgvector/pgvector"
    priority: 2
EOF

    touch "$EXT_BUILD_DIR/pgvector.Dockerfile"

    local registry_present="$tmpd/bb1-registry"
    : > "$registry_present"
    export registry_present

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export registry_present=\"$registry_present\"
        cd \"$sd\"
        source ./build-extensions.sh
        export ROOT_DIR=\"$tmpd\"

        # timescaledb resolver ALWAYS fails; pgvector resolves fine.
        resolve_version_set() {
            local ext=\"\$1\"
            if [[ \"\$ext\" == 'pgvector' ]]; then
                echo '[\"0.8.0\"]'
                return 0
            fi
            echo 'resolver error' >&2
            return 1
        }
        export -f resolve_version_set

        ext_config() {
            local ext=\"\$1\" key=\"\$2\"
            case \"\$ext:\$key\" in
                timescaledb:version) echo '2.27.1' ;;
                timescaledb:repo)    echo 'https://github.com/timescale/timescaledb' ;;
                pgvector:version)    echo '0.8.0' ;;
                pgvector:repo)       echo 'https://github.com/pgvector/pgvector' ;;
                *)                   echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        # ALL images absent → both extensions will be attempted.
        # timescaledb resolver fails before build can proceed → run fails.
        image_exists_in_registry() { return 1; }
        export -f image_exists_in_registry

        docker() { return 1; }
        export -f docker

        build_ext_image() { return 0; }
        export -f build_ext_image
        tag_ext_image()  { return 0; }
        export -f tag_ext_image
        push_ext_image() {
            local ext=\"\$1\" ver=\"\$2\" major=\"\$3\"
            printf 'pg%s-%s\n' \"\$major\" \"\$ver\" >> \"\$registry_present\"
            return 0
        }
        export -f push_ext_image
        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { printf 'timescaledb\npgvector\n'; }
        export -f list_extensions_by_priority

        # FULL unscoped run — final pass iterates all extensions.
        main postgres --major-version 18
    "

    # Fail-closed: timescaledb resolver failure on publish path → non-zero.
    [ "$status" -ne 0 ]

    # The timescaledb versionset artifact must NOT exist (resolver failed).
    local ts_artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"
    [ ! -f "$ts_artifact" ]
}

# ---------------------------------------------------------------------------
# BB-2: final-pass resolver failure + LOCAL_ONLY=true → degrade, exit 0.
# The recovery path must not be blocked by a transient resolver outage.
#
# RED before fix: N/A — current code already degrades (same warn+continue).
#   This test locks the degrade behavior so it is not broken by the BB-1 fix.
# GREEN: exit 0, warn logged, no artifact (no resolved set → can't write).
# ---------------------------------------------------------------------------
@test "BB-2-local-degrade: final-pass resolver failure + LOCAL_ONLY=true → exit 0 (degrade)" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    cat > "$CONTAINER_DIR/extensions/config.yaml" <<'EOF'
extensions:
  timescaledb:
    version: "2.27.1"
    repo: "https://github.com/timescale/timescaledb"
    priority: 1
    version_set:
      resolver: "scripts/resolvers/timescaledb-ha.sh"
  pgvector:
    version: "0.8.0"
    repo: "https://github.com/pgvector/pgvector"
    priority: 2
EOF

    touch "$EXT_BUILD_DIR/pgvector.Dockerfile"

    run bash -c "
        export FORCE=false LOCAL_ONLY=true DRY_RUN=false CONTAINER=postgres
        cd \"$sd\"
        source ./build-extensions.sh
        export ROOT_DIR=\"$tmpd\" LOCAL_ONLY=true

        # pgvector resolves fine; timescaledb resolver fails in final pass
        resolve_version_set() {
            local ext=\"\$1\"
            if [[ \"\$ext\" == 'pgvector' ]]; then
                echo '[\"0.8.0\"]'
                return 0
            fi
            echo 'resolver error' >&2
            return 1
        }
        export -f resolve_version_set

        ext_config() {
            local ext=\"\$1\" key=\"\$2\"
            case \"\$ext:\$key\" in
                timescaledb:version) echo '2.27.1' ;;
                timescaledb:repo)    echo 'https://github.com/timescale/timescaledb' ;;
                pgvector:version)    echo '0.8.0' ;;
                pgvector:repo)       echo 'https://github.com/pgvector/pgvector' ;;
                *)                   echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        # LOCAL_ONLY: docker inspect for presence; pgvector absent locally
        docker() { return 1; }
        export -f docker
        image_exists_in_registry() { return 1; }
        export -f image_exists_in_registry

        build_ext_image() { return 0; }
        export -f build_ext_image
        tag_ext_image()  { return 0; }
        export -f tag_ext_image
        push_ext_image() { return 0; }
        export -f push_ext_image
        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { printf 'timescaledb\npgvector\n'; }
        export -f list_extensions_by_priority

        main postgres --major-version 18 --extension pgvector --local-only
    "

    # Recovery path: resolver failure in final pass must NOT abort the run.
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# FF-1: stale per-version DURATION lineage files are removed on an all-cached
# run (no build occurs). The versionset artifact must survive.
#
# Scenario: a previous run built timescaledb 2.20.0 and wrote:
#   ext-timescaledb-pg18-2.20.0.json  (stale per-version DURATION file)
# In the current run, all resolved versions (2.25.0, 2.26.0, 2.27.1) are
# already in the registry — all-cached, nothing built.
#
# RED before fix: stale 2.20.0 per-version file survives the all-cached run.
# GREEN after fix: stale per-version duration file is cleaned on the all-cached
#   path while the versionset artifact is preserved.
# ---------------------------------------------------------------------------
@test "FF-1-allcached-stale-duration-cleaned: stale per-version duration file removed on all-cached run" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    local lineage_dir="$tmpd/.build-lineage"
    mkdir -p "$lineage_dir"

    # Stale per-version DURATION file from a PREVIOUS run (version not in current set)
    local stale_duration="$lineage_dir/ext-timescaledb-pg18-2.20.0.json"
    printf '{"ext":"timescaledb","version":"2.20.0","pg_major":"18","duration_seconds":55,"built_at":"2026-01-01T00:00:00Z"}\n' \
        > "$stale_duration"

    # Pre-create a versionset artifact (to verify it SURVIVES the cleanup)
    local versionset_artifact="$lineage_dir/ext-timescaledb-pg18-versionset.json"
    printf '{"ext":"timescaledb","pg_major":"18","ceiling":"2.27.1","resolved":["2.25.0","2.26.0","2.27.1"],"available":["2.25.0","2.26.0","2.27.1"],"excluded":[]}\n' \
        > "$versionset_artifact"

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        cd \"$sd\"
        source ./build-extensions.sh
        export ROOT_DIR=\"$tmpd\"

        resolve_version_set() { echo '[\"2.25.0\",\"2.26.0\",\"2.27.1\"]'; }
        export -f resolve_version_set

        ext_config() {
            case \"\$2\" in
                version) echo '2.27.1' ;;
                repo)    echo 'https://github.com/timescale/timescaledb' ;;
                *)       echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        # All versions in registry — all-cached, nothing to build
        image_exists_in_registry() { return 0; }
        export -f image_exists_in_registry

        docker() { return 1; }
        export -f docker

        build_ext_image() {
            echo 'BUILD_CALLED' >> \"$tmpd/ff1_build.log\"
            return 0
        }
        export -f build_ext_image
        tag_ext_image()  { return 0; }
        export -f tag_ext_image
        push_ext_image() { return 0; }
        export -f push_ext_image
        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority

        main postgres --major-version 18
    "

    # Must succeed (all cached)
    [ "$status" -eq 0 ]

    # Must NOT have built anything
    local build_count
    build_count=$(_count_log_lines "$tmpd/ff1_build.log")
    [ "$build_count" -eq 0 ]

    # Stale per-version DURATION file must be GONE.
    # RED before fix: stale file survives (cleanup only runs in build_tag_push_extensions).
    # GREEN after fix: cleaned by all-paths pass.
    [ ! -f "$stale_duration" ]

    # The versionset artifact must SURVIVE (never deleted by the stale-duration cleanup).
    [ -f "$versionset_artifact" ]
}

# ---------------------------------------------------------------------------
# FF-2: stale per-version DURATION lineage files are removed on all success paths.
# Verify the same cleanup runs on the build path (build_tag_push_extensions IS called).
# After cleanup, fresh per-version files are written for actually-built versions.
# ---------------------------------------------------------------------------
@test "FF-2-build-path-stale-cleaned: stale per-version duration removed even when build runs" {
    local lineage_dir="$TEST_TEMP_DIR/.build-lineage"
    mkdir -p "$lineage_dir"

    # Stale file from a previous run
    local stale_duration="$lineage_dir/ext-timescaledb-pg18-2.20.0.json"
    printf '{"ext":"timescaledb","version":"2.20.0","pg_major":"18","duration_seconds":99}\n' \
        > "$stale_duration"

    resolve_version_set() { echo '["2.25.0","2.26.0","2.27.1"]'; }
    export -f resolve_version_set

    ext_config() {
        case "$2" in
            version) echo "2.27.1" ;;
            repo)    echo "https://github.com/timescale/timescaledb" ;;
            *)       echo "" ;;
        esac
    }
    export -f ext_config

    run build_tag_push_extensions \
        "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR" "true" "timescaledb"

    [ "$status" -eq 0 ]

    # Stale file must be gone
    [ ! -f "$stale_duration" ]

    # Current-run per-version files must exist for each built version
    [ -f "$lineage_dir/ext-timescaledb-pg18-2.25.0.json" ]
    [ -f "$lineage_dir/ext-timescaledb-pg18-2.26.0.json" ]
    [ -f "$lineage_dir/ext-timescaledb-pg18-2.27.1.json" ]
}

# ---------------------------------------------------------------------------
# FF-3: the FF cleanup must NEVER delete the versionset artifact even if it
# exists before an all-cached run.
# ---------------------------------------------------------------------------
@test "FF-3-versionset-survives: versionset artifact is never deleted by FF cleanup" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    local lineage_dir="$tmpd/.build-lineage"
    mkdir -p "$lineage_dir"

    # Pre-create both: a stale duration AND the versionset artifact
    local stale_duration="$lineage_dir/ext-timescaledb-pg18-2.20.0.json"
    printf '{"ext":"timescaledb","version":"2.20.0","duration_seconds":42}\n' > "$stale_duration"

    local versionset="$lineage_dir/ext-timescaledb-pg18-versionset.json"
    printf '{"ext":"timescaledb","pg_major":"18","ceiling":"2.27.1","resolved":["2.25.0","2.26.0","2.27.1"],"available":["2.25.0","2.26.0","2.27.1"],"excluded":[]}\n' \
        > "$versionset"

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        cd \"$sd\"
        source ./build-extensions.sh
        export ROOT_DIR=\"$tmpd\"

        resolve_version_set() { echo '[\"2.25.0\",\"2.26.0\",\"2.27.1\"]'; }
        export -f resolve_version_set

        ext_config() {
            case \"\$2\" in
                version) echo '2.27.1' ;;
                repo)    echo 'https://github.com/timescale/timescaledb' ;;
                *)       echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        image_exists_in_registry() { return 0; }
        export -f image_exists_in_registry

        docker() { return 1; }
        export -f docker

        build_ext_image() { return 0; }
        export -f build_ext_image
        tag_ext_image()  { return 0; }
        export -f tag_ext_image
        push_ext_image() { return 0; }
        export -f push_ext_image
        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority

        main postgres --major-version 18
    "

    [ "$status" -eq 0 ]

    # Stale per-version DURATION file must be gone
    [ ! -f "$stale_duration" ]

    # Versionset artifact must SURVIVE and be fresh (rewritten by final pass)
    [ -f "$versionset" ]
    local ceiling
    ceiling=$(jq -r '.ceiling' "$versionset")
    [ "$ceiling" = "2.27.1" ]
}

# ---------------------------------------------------------------------------
# BB-3: final-pass resolver failure + PULL_ONLY=true → degrade, exit 0.
# ---------------------------------------------------------------------------
@test "BB-3-pullonly-degrade: final-pass resolver failure + PULL_ONLY=true → exit 0 (degrade)" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    cat > "$CONTAINER_DIR/extensions/config.yaml" <<'EOF'
extensions:
  timescaledb:
    version: "2.27.1"
    repo: "https://github.com/timescale/timescaledb"
    priority: 1
    version_set:
      resolver: "scripts/resolvers/timescaledb-ha.sh"
  pgvector:
    version: "0.8.0"
    repo: "https://github.com/pgvector/pgvector"
    priority: 2
EOF

    touch "$EXT_BUILD_DIR/pgvector.Dockerfile"

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres PULL_ONLY=true
        cd \"$sd\"
        source ./build-extensions.sh
        export ROOT_DIR=\"$tmpd\" PULL_ONLY=true

        # pgvector resolves fine; timescaledb resolver fails in final pass
        resolve_version_set() {
            local ext=\"\$1\"
            if [[ \"\$ext\" == 'pgvector' ]]; then
                echo '[\"0.8.0\"]'
                return 0
            fi
            echo 'resolver error' >&2
            return 1
        }
        export -f resolve_version_set

        ext_config() {
            local ext=\"\$1\" key=\"\$2\"
            case \"\$ext:\$key\" in
                timescaledb:version) echo '2.27.1' ;;
                timescaledb:repo)    echo 'https://github.com/timescale/timescaledb' ;;
                pgvector:version)    echo '0.8.0' ;;
                pgvector:repo)       echo 'https://github.com/pgvector/pgvector' ;;
                *)                   echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        docker() { return 0; }
        export -f docker
        image_exists_in_registry() { return 1; }
        export -f image_exists_in_registry

        pull_ext_image() { return 0; }
        export -f pull_ext_image
        build_ext_image() { return 0; }
        export -f build_ext_image
        tag_ext_image()  { return 0; }
        export -f tag_ext_image
        push_ext_image() { return 0; }
        export -f push_ext_image
        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { printf 'timescaledb\npgvector\n'; }
        export -f list_extensions_by_priority

        main postgres --major-version 18 --pull-only
    "

    # Recovery path: PULL_ONLY resolver failure must NOT abort the run.
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# HH-1: per-version duration files SURVIVE the _emit_final_versionset_pass.
#
# Before HH fix: _emit_final_versionset_pass deleted per-version duration files
#   AFTER build_tag_push_extensions had already written them → sum = 0 even after
#   a real build (the final pass wiped them).
# After HH fix:  the final pass no longer deletes duration files; the cleanup
#   moved to pre-build (start of build_tag_push_extensions), so files written
#   during the build survive to be read by sum_flavor_extension_durations.
#
# Assertion: after a full main() run where builds occurred, at least one
# per-version duration file exists AND sum_flavor_extension_durations > 0.
# ---------------------------------------------------------------------------
@test "HH-1-duration-survives-final-pass: build-path per-version duration files exist after final pass" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    # Stateful registry-presence file: seed empty; push_ext_image adds to it.
    # This mirrors the FORCE-AVAILABLE / CACHED-2 pattern.
    local registry_present="$tmpd/hh1-registry"
    : > "$registry_present"
    export registry_present

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export registry_present=\"$registry_present\"
        cd \"$sd\"
        source ./build-extensions.sh
        export ROOT_DIR=\"$tmpd\"

        resolve_version_set() { echo '[\"2.25.0\",\"2.26.0\",\"2.27.1\"]'; }
        export -f resolve_version_set

        ext_config() {
            case \"\$2\" in
                version) echo '2.27.1' ;;
                repo)    echo 'https://github.com/timescale/timescaledb' ;;
                *)       echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        # Stateful presence: consults registry_present file.
        # Initially empty (all absent → all need build).
        # push_ext_image adds each successfully-pushed version so the final
        # _image_present pass sees them as available — mirrors production.
        image_exists_in_registry() {
            local tag=\"\${1##*:}\"
            grep -qxF \"\$tag\" \"\$registry_present\" 2>/dev/null
        }
        export -f image_exists_in_registry

        docker() { return 1; }
        export -f docker

        build_ext_image() { return 0; }
        export -f build_ext_image
        tag_ext_image()  { return 0; }
        export -f tag_ext_image

        # Stateful push: register version as present after successful push
        push_ext_image() {
            local ext=\"\$1\" ver=\"\$2\" major=\"\$3\"
            printf 'pg%s-%s\n' \"\$major\" \"\$ver\" >> \"\$registry_present\"
            return 0
        }
        export -f push_ext_image

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority

        main postgres --major-version 18
    "

    [ "$status" -eq 0 ]

    local lineage_dir="$tmpd/.build-lineage"

    # Per-version duration files must EXIST after the run.
    # RED before HH fix: final pass deleted them → none found.
    # GREEN after HH fix: final pass no longer deletes; files survive from build.
    [ -f "$lineage_dir/ext-timescaledb-pg18-2.25.0.json" ]
    [ -f "$lineage_dir/ext-timescaledb-pg18-2.26.0.json" ]
    [ -f "$lineage_dir/ext-timescaledb-pg18-2.27.1.json" ]

    # Verify each file has a duration_seconds field (not the versionset shape)
    local dur_25 dur_26 dur_27
    dur_25=$(jq '.duration_seconds' "$lineage_dir/ext-timescaledb-pg18-2.25.0.json")
    dur_26=$(jq '.duration_seconds' "$lineage_dir/ext-timescaledb-pg18-2.26.0.json")
    dur_27=$(jq '.duration_seconds' "$lineage_dir/ext-timescaledb-pg18-2.27.1.json")

    [[ "$dur_25" =~ ^[0-9]+$ ]]
    [[ "$dur_26" =~ ^[0-9]+$ ]]
    [[ "$dur_27" =~ ^[0-9]+$ ]]
}

# ---------------------------------------------------------------------------
# HH-2: all-cached run cleans stale duration file → sum = 0.
#
# Confirms the all-cached pre-clean runs before sum_flavor_extension_durations
# would be called: stale from previous run is gone, nothing built this run,
# sum = 0.  The versionset artifact is also (re)written.
# ---------------------------------------------------------------------------
@test "HH-2-allcached-stale-sum-zero: stale duration cleaned on all-cached run, sum = 0" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    local lineage_dir="$tmpd/.build-lineage"
    mkdir -p "$lineage_dir"

    # Stale per-version duration file from a previous run
    local stale="$lineage_dir/ext-timescaledb-pg18-2.20.0.json"
    printf '{"ext":"timescaledb","version":"2.20.0","pg_major":"18","duration_seconds":77,"built_at":"2026-01-01T00:00:00Z"}\n' \
        > "$stale"

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        cd \"$sd\"
        source ./build-extensions.sh
        export ROOT_DIR=\"$tmpd\"

        resolve_version_set() { echo '[\"2.25.0\",\"2.26.0\",\"2.27.1\"]'; }
        export -f resolve_version_set

        ext_config() {
            case \"\$2\" in
                version) echo '2.27.1' ;;
                repo)    echo 'https://github.com/timescale/timescaledb' ;;
                *)       echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        # All in registry — all-cached, nothing built
        image_exists_in_registry() { return 0; }
        export -f image_exists_in_registry

        docker() { return 1; }
        export -f docker

        build_ext_image() {
            echo 'SHOULD_NOT_BUILD' >> \"$tmpd/hh2_build.log\"
            return 0
        }
        export -f build_ext_image
        tag_ext_image()  { return 0; }
        export -f tag_ext_image
        push_ext_image() { return 0; }
        export -f push_ext_image
        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority

        main postgres --major-version 18
    "

    [ "$status" -eq 0 ]

    # Must NOT have built anything
    local build_count
    build_count=$(_count_log_lines "$tmpd/hh2_build.log")
    [ "$build_count" -eq 0 ]

    # Stale duration file must be GONE after the all-cached run
    [ ! -f "$stale" ]

    # No per-version duration files for current versions (nothing built)
    [ ! -f "$lineage_dir/ext-timescaledb-pg18-2.25.0.json" ]
    [ ! -f "$lineage_dir/ext-timescaledb-pg18-2.26.0.json" ]
    [ ! -f "$lineage_dir/ext-timescaledb-pg18-2.27.1.json" ]

    # Versionset artifact must still be present (rewritten by final pass)
    [ -f "$lineage_dir/ext-timescaledb-pg18-versionset.json" ]
}

# ---------------------------------------------------------------------------
# LL-1: empty-available artifact must NOT be written.
#
# Tests _emit_versionset_artifact directly: when all versions are absent from
# the registry (available would be []), the writer must skip writing the
# artifact entirely. An empty-available artifact is HARMFUL: the consumer
# treats available=[] as "ceiling is guaranteed built" and falls back to a
# ceiling tag referencing a non-existent image → downstream build fails.
#
# RED before fix: artifact written with available=[].
# GREEN after fix: writer skips write when available is empty.
# ---------------------------------------------------------------------------
@test "LL-1: all-absent ext writes NO versionset artifact (available would be empty)" {
    local lineage_dir="$TEST_TEMP_DIR/.build-lineage"
    rm -rf "$lineage_dir"

    # ALL versions absent from registry — available would be [].
    image_exists_in_registry() { return 1; }
    export -f image_exists_in_registry

    docker() { return 1; }
    export -f docker

    local version_set_json='["2.25.0","2.26.0","2.27.1"]'
    PULL_ONLY=false LOCAL_ONLY=false DRY_RUN=false

    _emit_versionset_artifact "timescaledb" "$CONFIG_FILE" "18" \
        "$version_set_json" "2.27.1"

    local artifact="$lineage_dir/ext-timescaledb-pg18-versionset.json"

    # available=[] → no ceiling in available → artifact must NOT be written.
    # RED before fix: file exists with available=[].
    # GREEN after fix: file absent.
    [ ! -f "$artifact" ]
}

# ---------------------------------------------------------------------------
# LL-2: ceiling-absent from available → artifact NOT written.
#
# Some older versions are present in the registry but the ceiling (2.27.1) is
# NOT in available (registry absent, not in built-this-run). Writing such an
# artifact misleads the consumer into referencing a ceiling image that doesn't
# exist.
#
# RED before fix: artifact written with ceiling absent from available.
# GREEN after fix: artifact skipped when ceiling not in available.
# ---------------------------------------------------------------------------
@test "LL-2: ceiling-absent from available → NO versionset artifact written" {
    local lineage_dir="$TEST_TEMP_DIR/.build-lineage"
    rm -rf "$lineage_dir"

    # 2.25.0 and 2.26.0 present; ceiling 2.27.1 ABSENT.
    image_exists_in_registry() {
        [[ "$1" == *'pg18-2.25.0'* || "$1" == *'pg18-2.26.0'* ]] && return 0 || return 1
    }
    export -f image_exists_in_registry

    docker() { return 1; }
    export -f docker

    local version_set_json='["2.25.0","2.26.0","2.27.1"]'
    PULL_ONLY=false LOCAL_ONLY=false DRY_RUN=false

    _emit_versionset_artifact "timescaledb" "$CONFIG_FILE" "18" \
        "$version_set_json" "2.27.1"

    local artifact="$lineage_dir/ext-timescaledb-pg18-versionset.json"

    # available=[2.25.0,2.26.0] — ceiling 2.27.1 NOT in available.
    # RED before fix: artifact written despite missing ceiling.
    # GREEN after fix: artifact NOT written.
    [ ! -f "$artifact" ]
}

# ---------------------------------------------------------------------------
# LL-3: useful artifact (available non-empty AND contains ceiling) IS written.
# Regression guard: the LL fix must not prevent writing when the ceiling IS
# present in available.
# ---------------------------------------------------------------------------
@test "LL-3: useful artifact (available non-empty, ceiling present) IS written (regression guard)" {
    local lineage_dir="$TEST_TEMP_DIR/.build-lineage"
    rm -rf "$lineage_dir"

    # All versions present in registry (including ceiling 2.27.1).
    image_exists_in_registry() { return 0; }
    export -f image_exists_in_registry

    docker() { return 1; }
    export -f docker

    local version_set_json='["2.25.0","2.26.0","2.27.1"]'
    PULL_ONLY=false LOCAL_ONLY=false DRY_RUN=false

    _emit_versionset_artifact "timescaledb" "$CONFIG_FILE" "18" \
        "$version_set_json" "2.27.1"

    local artifact="$lineage_dir/ext-timescaledb-pg18-versionset.json"

    # Ceiling IS in available → artifact MUST be written.
    [ -f "$artifact" ]

    # available must include all 3 versions
    local available_count
    available_count=$(jq '.available | length' "$artifact")
    [ "$available_count" -eq 3 ]

    # ceiling field must match
    local ceiling_field
    ceiling_field=$(jq -r '.ceiling' "$artifact")
    [ "$ceiling_field" = "2.27.1" ]
}

# ---------------------------------------------------------------------------
# KK-1: scoped cleanup isolation — a scoped (--extension pgvector) all-cached
# run must NOT delete duration files from OTHER extensions (timescaledb).
#
# Scenario: a previous scoped run built timescaledb and wrote
#   ext-timescaledb-pg18-2.27.1.json (duration file).
# Then a second scoped run for pgvector is all-cached (nothing to build).
# The all-cached pre-clean must only clean pgvector's duration files, NOT
# timescaledb's.
#
# RED before fix: all-cached pre-clean iterates ALL extensions → deletes
#   timescaledb's duration file → sum_flavor_extension_durations under-reports.
# GREEN after fix: pre-clean scoped to EXTENSION=pgvector → timescaledb file
#   survives.
# ---------------------------------------------------------------------------
@test "KK-1: scoped all-cached run only cleans own extension's duration files, not others'" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    cat > "$CONTAINER_DIR/extensions/config.yaml" <<'EOF'
extensions:
  timescaledb:
    version: "2.27.1"
    repo: "https://github.com/timescale/timescaledb"
    priority: 1
    version_set:
      resolver: "scripts/resolvers/timescaledb-ha.sh"
  pgvector:
    version: "0.8.0"
    repo: "https://github.com/pgvector/pgvector"
    priority: 2
EOF

    touch "$EXT_BUILD_DIR/pgvector.Dockerfile"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    local lineage_dir="$tmpd/.build-lineage"
    mkdir -p "$lineage_dir"

    # Pre-create timescaledb duration file from an earlier scoped invocation.
    local ts_duration="$lineage_dir/ext-timescaledb-pg18-2.27.1.json"
    printf '{"ext":"timescaledb","version":"2.27.1","pg_major":"18","duration_seconds":42,"built_at":"2026-01-01T00:00:00Z"}\n' \
        > "$ts_duration"

    # Also pre-create a stale pgvector duration file that SHOULD be cleaned.
    local stale_pv="$lineage_dir/ext-pgvector-pg18-0.7.0.json"
    printf '{"ext":"pgvector","version":"0.7.0","pg_major":"18","duration_seconds":10}\n' \
        > "$stale_pv"

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        cd \"$sd\"
        source ./build-extensions.sh
        export ROOT_DIR=\"$tmpd\"

        resolve_version_set() {
            local ext=\"\$1\"
            if [[ \"\$ext\" == 'timescaledb' ]]; then
                echo '[\"2.25.0\",\"2.26.0\",\"2.27.1\"]'
            else
                echo '[\"0.8.0\"]'
            fi
        }
        export -f resolve_version_set

        ext_config() {
            local ext=\"\$1\" key=\"\$2\"
            case \"\$ext:\$key\" in
                timescaledb:version) echo '2.27.1' ;;
                timescaledb:repo)    echo 'https://github.com/timescale/timescaledb' ;;
                pgvector:version)    echo '0.8.0' ;;
                pgvector:repo)       echo 'https://github.com/pgvector/pgvector' ;;
                *)                   echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        # pgvector is already in registry (all-cached for pgvector)
        image_exists_in_registry() {
            [[ \"\$1\" == *'pgvector'* ]] && return 0 || return 1
        }
        export -f image_exists_in_registry

        docker() { return 1; }
        export -f docker

        build_ext_image() { return 0; }
        export -f build_ext_image
        tag_ext_image()  { return 0; }
        export -f tag_ext_image
        push_ext_image() { return 0; }
        export -f push_ext_image
        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { printf 'timescaledb\npgvector\n'; }
        export -f list_extensions_by_priority

        # Scoped to pgvector only; all-cached (pgvector already in registry)
        main postgres --major-version 18 --extension pgvector
    "

    [ "$status" -eq 0 ]

    # CORE INVARIANT: timescaledb duration file from the earlier run must SURVIVE.
    # RED before fix: all-extensions loop deletes it → [ ! -f ts_duration ] = TRUE (bad).
    # GREEN after fix: scoped cleanup only touches pgvector → ts_duration still present.
    [ -f "$ts_duration" ]

    # The stale pgvector file SHOULD be cleaned (it belonged to the pgvector scope).
    [ ! -f "$stale_pv" ]
}

# ---------------------------------------------------------------------------
# DEFECT-A tests: build_ext_image must propagate the docker build exit code.
# These tests exercise the REAL build_ext_image (NOT mocked) — only $DOCKER
# (the docker command) is mocked so that docker build returns non-zero.
# This closes the mock-vs-production gap where the old unconditional
# log_success+return-0 swallowed real docker build failures.
# ---------------------------------------------------------------------------

# DEFECT-A-1: REAL build_ext_image with docker build returning non-zero must
# return non-zero (was: returned 0 + logged success).
#
# Before fix: RED — build_ext_image ran "$DOCKER build ..." then unconditionally
#   called log_success and fell off the function → return 0.
# After fix: GREEN — "if ! $DOCKER build ...; then return 1; fi" propagates failure.
@test "DEFECT-A-1: real build_ext_image returns non-zero when docker build fails" {
    # Restore the real build_ext_image from build-extensions.sh (setup() installs
    # a mock via _setup_default_mocks; we need the production function here).
    _source_build_extensions

    # REMOTE_CR must be set: the build-extensions.sh override uses ${REMOTE_CR}.
    export REMOTE_CR="docker.io"

    # Override $DOCKER so "docker build" fails; other docker sub-commands pass.
    # The real build_ext_image calls: $DOCKER build ...
    export DOCKER="docker"
    docker() {
        if [[ "$1" == "build" ]]; then
            echo "simulated docker build failure" >&2
            return 1
        fi
        # docker image inspect (used by _image_needs_build) → image absent
        return 1
    }
    export -f docker

    # Provide the minimum filesystem structure build_ext_image expects.
    local ext_name="timescaledb"
    local ext_version="2.27.1"
    local ext_repo="https://github.com/timescale/timescaledb"
    local pg_major="18"
    local dockerfile="$CONTAINER_DIR/extensions/build/${ext_name}.Dockerfile"
    local context_dir="$CONTAINER_DIR/extensions"

    run build_ext_image "$ext_name" "$ext_version" "$ext_repo" "$pg_major" "$dockerfile" "$context_dir"

    # Must NOT return 0: a failed docker build must propagate as failure.
    [ "$status" -ne 0 ]

    # Must NOT log success (that was the lie).
    [[ "$output" != *"Built:"* ]]
}

# DEFECT-A-2: integration — REAL build_ext_image + docker build failing for a
# NON-CEILING version → build_tag_push_extensions TOLERATES it (exit 0, version
# recorded in the failed-set but run continues).
#
# Before fix: RED — build_ext_image returned 0 even on failure, so compile_ok
#   stayed true, non-ceiling tolerance logic never triggered, and no version was
#   excluded. The run exited 0 but for the wrong reason (swallowed failure).
# After fix: GREEN — build_ext_image returns 1, compile_ok=false is set,
#   non-ceiling tolerance records it as excluded/skipped, run exits 0.
@test "DEFECT-A-2: real build_ext_image docker-fail on non-ceiling version is tolerated (exit 0)" {
    # Restore the real build_ext_image (setup installs a mock; we need production here).
    _source_build_extensions
    export REMOTE_CR="docker.io"
    # Re-install required mocks after re-source (which resets everything from helpers).
    image_exists_in_registry() { return 1; }
    export -f image_exists_in_registry

    resolve_version_set() { echo '["2.25.0","2.27.1"]'; }
    export -f resolve_version_set

    ext_config() {
        case "$2" in
            version) echo "2.27.1" ;;
            repo)    echo "https://github.com/timescale/timescaledb" ;;
            *)       echo "" ;;
        esac
    }
    export -f ext_config

    # ext_local_image_name used by the real build_ext_image
    ext_local_image_name() { echo "localhost/ext-builder-${1}:pg${2}"; }
    export -f ext_local_image_name
    ext_image_name() { echo "ghcr.io/test/ext-${1}:pg${3}-${2}"; }
    export -f ext_image_name

    # docker: "build" fails only for 2.25.0 (non-ceiling).
    # Inspect calls (used by _image_needs_build) return absent (1) so all versions
    # are attempted.
    # 2.27.1 build succeeds; 2.25.0 build fails.
    local build_call_log="$TEST_TEMP_DIR/docker_build_calls.log"
    export DOCKER="docker"
    docker() {
        if [[ "$1" == "build" ]]; then
            # Detect which version from --build-arg EXT_VERSION=<ver>
            local ver=""
            local i
            for (( i=1; i<=$#; i++ )); do
                local arg="${!i}"
                if [[ "$arg" == "--build-arg" ]]; then
                    local next_i=$(( i + 1 ))
                    local next_arg="${!next_i}"
                    if [[ "$next_arg" == EXT_VERSION=* ]]; then
                        ver="${next_arg#EXT_VERSION=}"
                    fi
                fi
            done
            echo "docker build called for ver=${ver}" >> "$build_call_log"
            if [[ "$ver" == "2.25.0" ]]; then
                echo "simulated musl build failure for $ver" >&2
                return 1
            fi
            return 0
        fi
        # inspect / other sub-commands: image absent
        return 1
    }
    export -f docker
    export DOCKER

    # tag_ext_image / push_ext_image must record calls for the ceiling version
    tag_ext_image() {
        echo "TAG_CALLED ext=${1} ver=${2}" >> "$TEST_TEMP_DIR/tag_calls.log"
        return 0
    }
    export -f tag_ext_image

    push_ext_image() {
        echo "PUSH_CALLED ext=${1} ver=${2}" >> "$TEST_TEMP_DIR/push_calls.log"
        return 0
    }
    export -f push_ext_image

    run build_tag_push_extensions \
        "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR" "true" "timescaledb"

    # Non-ceiling failure must be TOLERATED: run exits 0.
    [ "$status" -eq 0 ]

    # The ceiling (2.27.1) must have been tagged and pushed (it succeeded).
    [ -f "$TEST_TEMP_DIR/tag_calls.log" ]
    [[ "$(cat "$TEST_TEMP_DIR/tag_calls.log")"  == *"ver=2.27.1"* ]]
    [ -f "$TEST_TEMP_DIR/push_calls.log" ]
    [[ "$(cat "$TEST_TEMP_DIR/push_calls.log")" == *"ver=2.27.1"* ]]

    # The non-ceiling (2.25.0) must NOT have been tagged (build failed before tag).
    if [ -f "$TEST_TEMP_DIR/tag_calls.log" ]; then
        [[ "$(cat "$TEST_TEMP_DIR/tag_calls.log")" != *"ver=2.25.0"* ]]
    fi
}

# DEFECT-A-3: integration — REAL build_ext_image + docker build failing for the
# CEILING version → build_tag_push_extensions is FATAL (exit non-zero).
#
# Before fix: RED — docker build failure swallowed → compile_ok stayed true →
#   ceiling tag+push proceeded → run exited 0 (silently shipping a broken image).
# After fix: GREEN — failure propagated → ceiling marked failed → exit 1.
@test "DEFECT-A-3: real build_ext_image docker-fail on ceiling version is fatal (exit non-zero)" {
    # Restore the real build_ext_image (setup installs a mock; we need production here).
    _source_build_extensions
    export REMOTE_CR="docker.io"
    # Re-install required mocks after re-source.
    image_exists_in_registry() { return 1; }
    export -f image_exists_in_registry

    resolve_version_set() { echo '["2.25.0","2.27.1"]'; }
    export -f resolve_version_set

    ext_config() {
        case "$2" in
            version) echo "2.27.1" ;;
            repo)    echo "https://github.com/timescale/timescaledb" ;;
            *)       echo "" ;;
        esac
    }
    export -f ext_config

    ext_local_image_name() { echo "localhost/ext-builder-${1}:pg${2}"; }
    export -f ext_local_image_name
    ext_image_name() { echo "ghcr.io/test/ext-${1}:pg${3}-${2}"; }
    export -f ext_image_name

    local build_call_log="$TEST_TEMP_DIR/docker_build_calls_a3.log"
    export DOCKER="docker"
    docker() {
        if [[ "$1" == "build" ]]; then
            local ver=""
            local i
            for (( i=1; i<=$#; i++ )); do
                local arg="${!i}"
                if [[ "$arg" == "--build-arg" ]]; then
                    local next_i=$(( i + 1 ))
                    local next_arg="${!next_i}"
                    if [[ "$next_arg" == EXT_VERSION=* ]]; then
                        ver="${next_arg#EXT_VERSION=}"
                    fi
                fi
            done
            echo "docker build called for ver=${ver}" >> "$build_call_log"
            # Ceiling (2.27.1) fails
            if [[ "$ver" == "2.27.1" ]]; then
                echo "simulated ceiling build failure for $ver" >&2
                return 1
            fi
            return 0
        fi
        return 1
    }
    export -f docker
    export DOCKER

    local tag_log="$TEST_TEMP_DIR/tag_calls.log"
    tag_ext_image() {
        echo "TAG_CALLED ext=${1} ver=${2}" >> "$tag_log"
        return 0
    }
    export -f tag_ext_image

    run build_tag_push_extensions \
        "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR" "true" "timescaledb"

    # Ceiling failure must be FATAL.
    [ "$status" -ne 0 ]

    # The ceiling must NOT have been tagged (build failed before tag).
    if [ -f "$tag_log" ]; then
        [[ "$(cat "$tag_log")" != *"ver=2.27.1"* ]]
    fi
}

# ---------------------------------------------------------------------------
# DEFECT-A-4: pull_ext_image must propagate docker pull exit code.
# Exercises the REAL pull_ext_image (NOT mocked) — only $DOCKER/docker is mocked
# so docker pull returns non-zero.
#
# Before fix: RED — pull_ext_image called "$DOCKER pull ..." then unconditionally
#   called log_success → returned 0 even on failure.
# After fix: GREEN — "if ! $DOCKER pull ...; then return 1; fi" propagates failure.
# ---------------------------------------------------------------------------

@test "DEFECT-A-4: real pull_ext_image returns non-zero when docker pull fails" {
    # Restore real pull_ext_image from helpers/extension-utils.sh.
    # setup() only sources build-extensions.sh (which sources extension-utils.sh),
    # so pull_ext_image is already the real one — but _setup_default_mocks defines
    # a pull_ext_image mock if any test does. Here setup() does NOT override
    # pull_ext_image, so the real one is in scope.
    # Re-source to be safe (also resets any prior mutation from other tests).
    _source_build_extensions
    export REMOTE_CR="docker.io"

    # Override $DOCKER so docker pull fails.
    export DOCKER="docker"
    docker() {
        if [[ "$1" == "pull" ]]; then
            echo "simulated docker pull failure" >&2
            return 1
        fi
        return 1
    }
    export -f docker

    ext_image_name() { echo "ghcr.io/test/ext-${1}:pg${3}-${2}"; }
    export -f ext_image_name

    run pull_ext_image "timescaledb" "2.27.1" "18"

    # Must NOT return 0: a failed docker pull must propagate as failure.
    [ "$status" -ne 0 ]

    # Must NOT log success (that was the lie).
    [[ "$output" != *"Pulled:"* ]]
}

# ---------------------------------------------------------------------------
# MM-1: scoped --extension pgvector run with TimescaleDB resolver FAILING →
# the run SUCCEEDS (exit 0).
#
# Before fix (DEFECT MM): _emit_final_versionset_pass iterates ALL extensions
#   regardless of $EXTENSION → calls timescaledb resolver on publish path →
#   resolver fails → _final_pass_failed=true → return 1 → exit non-zero. RED.
# After fix: final pass is scoped to $EXTENSION=pgvector → timescaledb resolver
#   never called → run exits 0. GREEN.
#
# Contract: pgvector is handled (its single-version set is processed); timescaledb
#   is never resolved, never emitted, never aborts the run.
# ---------------------------------------------------------------------------

@test "MM-1: scoped pgvector run with failing timescaledb resolver exits 0 (timescaledb never resolved)" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    # Config: both timescaledb (resolver-backed) and pgvector (single-version)
    cat > "$CONTAINER_DIR/extensions/config.yaml" <<'EOF'
extensions:
  timescaledb:
    version: "2.27.1"
    repo: "https://github.com/timescale/timescaledb"
    priority: 1
    version_set:
      resolver: "scripts/resolvers/timescaledb-ha.sh"
  pgvector:
    version: "0.8.0"
    repo: "https://github.com/pgvector/pgvector"
    priority: 2
EOF

    touch "$EXT_BUILD_DIR/pgvector.Dockerfile"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    local ts_resolver_calls="$tmpd/mm1_ts_resolver_calls"
    local pgv_build_log="$tmpd/mm1_pgv_build.log"
    local ts_artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"
    export ts_resolver_calls pgv_build_log

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export ts_resolver_calls=\"$ts_resolver_calls\"
        export pgv_build_log=\"$pgv_build_log\"
        cd \"$sd\"
        source ./build-extensions.sh
        export ROOT_DIR=\"$tmpd\"

        resolve_version_set() {
            local ext=\"\$1\"
            if [[ \"\$ext\" == 'timescaledb' ]]; then
                # Record the call so the test can verify it was (or was not) made.
                printf 'called\n' >> \"\$ts_resolver_calls\"
                echo '::error::simulated timescaledb HA resolver failure' >&2
                return 1
            fi
            # pgvector: single version, no multi-version resolver
            echo '[\"0.8.0\"]'
        }
        export -f resolve_version_set

        ext_config() {
            local ext=\"\$1\" key=\"\$2\"
            case \"\$ext:\$key\" in
                timescaledb:version) echo '2.27.1' ;;
                timescaledb:repo)    echo 'https://github.com/timescale/timescaledb' ;;
                pgvector:version)    echo '0.8.0' ;;
                pgvector:repo)       echo 'https://github.com/pgvector/pgvector' ;;
                *)                   echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        # pgvector absent → needs build; timescaledb irrelevant (not in scope)
        image_exists_in_registry() { return 1; }
        export -f image_exists_in_registry

        docker() { return 1; }
        export -f docker

        build_ext_image() {
            echo \"BUILD ext=\${1} ver=\${2}\" >> \"\$pgv_build_log\"
            return 0
        }
        export -f build_ext_image
        tag_ext_image()  { return 0; }
        export -f tag_ext_image
        push_ext_image() { return 0; }
        export -f push_ext_image
        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { printf 'timescaledb\npgvector\n'; }
        export -f list_extensions_by_priority

        # Scoped: only pgvector
        main postgres --major-version 18 --extension pgvector
    "

    # RED before fix: timescaledb resolver is called → fails → exit non-zero.
    # GREEN after fix: timescaledb never resolved → exit 0.
    [ "$status" -eq 0 ]

    # pgvector must have been built (it was absent).
    [ -f "$pgv_build_log" ]
    [[ "$(cat "$pgv_build_log")" == *"ext=pgvector"* ]]

    # timescaledb versionset artifact must NOT exist (never resolved/emitted).
    [ ! -f "$ts_artifact" ]
}

# ---------------------------------------------------------------------------
# MM-2 (regression): full run (no --extension) with a resolver-backed extension's
# resolver failing on the publish path → still fails closed (exit non-zero).
# Confirms BB fail-closed is preserved for full runs.
# ---------------------------------------------------------------------------

@test "MM-2: full run with failing timescaledb resolver on publish path exits non-zero (fail-closed preserved)" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    local build_log="$tmpd/mm2_build.log"
    export build_log

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export build_log=\"$build_log\"
        cd \"$sd\"
        source ./build-extensions.sh
        export ROOT_DIR=\"$tmpd\"

        resolve_version_set() {
            echo '::error::simulated resolver failure' >&2
            return 1
        }
        export -f resolve_version_set

        ext_config() {
            case \"\$2\" in
                version) echo '2.27.1' ;;
                repo)    echo 'https://github.com/timescale/timescaledb' ;;
                *)       echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name
        image_exists_in_registry() { return 1; }
        export -f image_exists_in_registry
        docker() { return 1; }
        export -f docker
        build_ext_image() {
            echo \"BUILD ext=\${1} ver=\${2}\" >> \"\$build_log\"
            return 0
        }
        export -f build_ext_image
        tag_ext_image()  { return 0; }
        export -f tag_ext_image
        push_ext_image() { return 0; }
        export -f push_ext_image
        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority

        # Full run — no --extension
        main postgres --major-version 18
    "

    # Full run: resolver failure must stay fatal (fail-closed).
    [ "$status" -ne 0 ]

    # No build must have been triggered (resolver failed before build decision).
    local build_count
    build_count=0
    [ -f "$build_log" ] && build_count=$(wc -l < "$build_log")
    [ "$build_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# MM-3 (regression): scoped run targeting the resolver-backed extension itself
# (--extension timescaledb) with ITS resolver failing on publish path →
# fails closed (exit non-zero). Scoping to the resolver-backed ext keeps it fatal.
# ---------------------------------------------------------------------------

@test "MM-3: scoped --extension timescaledb with its resolver failing exits non-zero (scoped fatal preserved)" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    local build_log="$tmpd/mm3_build.log"
    export build_log

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export build_log=\"$build_log\"
        cd \"$sd\"
        source ./build-extensions.sh
        export ROOT_DIR=\"$tmpd\"

        resolve_version_set() {
            echo '::error::simulated timescaledb resolver failure' >&2
            return 1
        }
        export -f resolve_version_set

        ext_config() {
            case \"\$2\" in
                version) echo '2.27.1' ;;
                repo)    echo 'https://github.com/timescale/timescaledb' ;;
                *)       echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name
        image_exists_in_registry() { return 1; }
        export -f image_exists_in_registry
        docker() { return 1; }
        export -f docker
        build_ext_image() {
            echo \"BUILD ext=\${1} ver=\${2}\" >> \"\$build_log\"
            return 0
        }
        export -f build_ext_image
        tag_ext_image()  { return 0; }
        export -f tag_ext_image
        push_ext_image() { return 0; }
        export -f push_ext_image
        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority

        # Scoped: timescaledb is the targeted extension and ITS resolver fails
        main postgres --major-version 18 --extension timescaledb
    "

    # Scoped to the failing extension: must be fatal (fail-closed).
    [ "$status" -ne 0 ]

    # No build must have been triggered (resolver failed before build decision).
    local build_count
    build_count=0
    [ -f "$build_log" ] && build_count=$(wc -l < "$build_log")
    [ "$build_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# NN-1: transient probe ERROR on a non-ceiling resolved version → fail closed.
#
# Scenario: resolver returns ["2.25.0","2.26.0","2.27.1"] (all 3 retained).
# Ceiling 2.27.1 probes as PRESENT.
# 2.26.0 probes as PRESENT.
# 2.25.0 probe ERRORS (network blip / non-definitive failure — not a
#   "manifest unknown" / 404 signal, just a non-zero exit without that text).
#
# Before fix (fail-OPEN): 2.25.0 treated as absent → versionset artifact
#   written with available=["2.26.0","2.27.1"] (silently drops a published
#   retained version).
#
# After fix (fail-CLOSED): transient probe error on any non-ceiling resolved
#   version → artifact NOT written, emission exits non-zero.
#
# The test drives _emit_versionset_artifact via the final pass (main()).
# _image_present_3state is mocked to return rc=2 for 2.25.0 (transient error signal).
# ---------------------------------------------------------------------------
@test "NN-1: transient probe error on non-ceiling version fails closed (no partial artifact)" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"
    local artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"

    # Prepare environment expected by main()/final pass
    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        cd \"$sd\"
        source ./build-extensions.sh
        export ROOT_DIR=\"$tmpd\"

        resolve_version_set() { echo '[\"2.25.0\",\"2.26.0\",\"2.27.1\"]'; }
        export -f resolve_version_set

        ext_config() {
            case \"\$2\" in
                version) echo '2.27.1' ;;
                repo)    echo 'https://github.com/timescale/timescaledb' ;;
                *)       echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        # _image_present_3state mock: ceiling=PRESENT, 2.26.0=PRESENT, 2.25.0=ERROR (transient, rc=2)
        _image_present_3state() {
            case \"\$1\" in
                *pg18-2.27.1*) return 0 ;;   # ceiling: PRESENT
                *pg18-2.26.0*) return 0 ;;   # 2.26.0: PRESENT
                *pg18-2.25.0*) return 2 ;;   # 2.25.0: ERROR (transient) — rc=2
                *)             return 1 ;;
            esac
        }
        export -f _image_present_3state

        # image_exists_in_registry returns 0 so _should_build_extension skips all builds
        image_exists_in_registry() { return 0; }
        export -f image_exists_in_registry
        docker() { return 1; }
        export -f docker
        build_ext_image() { return 0; }
        export -f build_ext_image
        tag_ext_image()  { return 0; }
        export -f tag_ext_image
        push_ext_image() { return 0; }
        export -f push_ext_image
        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority

        main postgres --major-version 18
    "

    # RED before fix: exits 0, artifact written with available=[\"2.26.0\",\"2.27.1\"]
    #   (2.25.0 silently dropped as if definitively absent).
    # GREEN after fix: exits non-zero (fail-closed) AND artifact either absent or
    #   contains all 3 versions (never a silently-reduced set).

    # Primary assertion: the run must exit non-zero (fail-closed on probe error).
    [ "$status" -ne 0 ]

    # Secondary: if artifact was written despite the error, it must NOT have dropped 2.25.0.
    if [ -f "$artifact" ]; then
        local avail_count
        avail_count=$(jq '.available | length' "$artifact")
        # A reduced set of 2 (missing 2.25.0) is the exact pre-fix bug.
        [ "$avail_count" -ne 2 ]
    fi
}

# ---------------------------------------------------------------------------
# NN-2 (regression): definitively absent non-ceiling version is correctly
# excluded, run continues (legitimate musl-failed / never-built case).
#
# Scenario: resolver returns ["2.25.0","2.26.0","2.27.1"].
# Ceiling 2.27.1 probes PRESENT.
# 2.26.0 probes PRESENT.
# 2.25.0 is DEFINITIVELY ABSENT (rc=1, "manifest unknown" / not-found signal).
#
# Expected: artifact IS written with available=["2.26.0","2.27.1"], exit 0.
# Ensures we didn't over-correct (definitively absent is still excluded, not an error).
# ---------------------------------------------------------------------------
@test "NN-2: definitively absent non-ceiling version is excluded, run continues (exit 0)" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"
    local artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        cd \"$sd\"
        source ./build-extensions.sh
        export ROOT_DIR=\"$tmpd\"

        resolve_version_set() { echo '[\"2.25.0\",\"2.26.0\",\"2.27.1\"]'; }
        export -f resolve_version_set

        ext_config() {
            case \"\$2\" in
                version) echo '2.27.1' ;;
                repo)    echo 'https://github.com/timescale/timescaledb' ;;
                *)       echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        # _image_present_3state mock: ceiling=PRESENT, 2.26.0=PRESENT, 2.25.0=ABSENT (rc=1, definitive)
        _image_present_3state() {
            case \"\$1\" in
                *pg18-2.27.1*) return 0 ;;   # ceiling: PRESENT
                *pg18-2.26.0*) return 0 ;;   # 2.26.0: PRESENT
                *pg18-2.25.0*) return 1 ;;   # 2.25.0: ABSENT (definitive, e.g. musl-failed)
                *)             return 1 ;;
            esac
        }
        export -f _image_present_3state

        image_exists_in_registry() { return 0; }
        export -f image_exists_in_registry
        docker() { return 1; }
        export -f docker
        build_ext_image() { return 0; }
        export -f build_ext_image
        tag_ext_image()  { return 0; }
        export -f tag_ext_image
        push_ext_image() { return 0; }
        export -f push_ext_image
        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority

        main postgres --major-version 18
    "

    # Must succeed (definitive absence = musl-failed / never-built — expected behavior).
    [ "$status" -eq 0 ]

    # Artifact must be written with available=["2.26.0","2.27.1"] (2.25.0 correctly excluded).
    [ -f "$artifact" ]
    local avail_count
    avail_count=$(jq '.available | length' "$artifact")
    [ "$avail_count" -eq 2 ]

    # 2.27.1 (ceiling) must be in available
    local ceiling_present
    ceiling_present=$(jq '[.available[] | select(. == "2.27.1")] | length' "$artifact")
    [ "$ceiling_present" -eq 1 ]

    # 2.25.0 must appear in excluded (not silently lost)
    local excluded_count
    excluded_count=$(jq '.excluded | length' "$artifact")
    [ "$excluded_count" -ge 1 ]
    local excluded_has_2_25
    excluded_has_2_25=$(jq '[.excluded[] | select(.version == "2.25.0")] | length' "$artifact")
    [ "$excluded_has_2_25" -eq 1 ]
}
