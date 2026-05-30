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

    # Artifact should list 2.26.0 as available (not excluded)
    local artifact="$TEST_TEMP_DIR/.build-lineage/ext-timescaledb-pg18-versionset.json"
    [ -f "$artifact" ]
    local available_versions
    available_versions=$(jq -r '.available[]' "$artifact")
    [[ "$available_versions" == *"2.26.0"* ]]

    local excluded_count
    excluded_count=$(jq '.excluded | length' "$artifact")
    [ "$excluded_count" -eq 0 ]
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

    # Artifact: 2.25.0 in excluded; others in available
    local artifact="$TEST_TEMP_DIR/.build-lineage/ext-timescaledb-pg18-versionset.json"
    [ -f "$artifact" ]

    local excluded_count
    excluded_count=$(jq '.excluded | length' "$artifact")
    [ "$excluded_count" -eq 1 ]

    local excluded_ver
    excluded_ver=$(jq -r '.excluded[0].version' "$artifact")
    [ "$excluded_ver" = "2.25.0" ]

    local available
    available=$(jq -r '.available[]' "$artifact")
    [[ "$available" == *"2.26.0"* ]]
    [[ "$available" == *"2.27.1"* ]]
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

    local artifact="$TEST_TEMP_DIR/.build-lineage/ext-timescaledb-pg18-versionset.json"
    [ -f "$artifact" ]

    # Validate top-level fields
    local ext pg ceiling
    ext=$(jq -r '.ext' "$artifact")
    pg=$(jq -r '.pg_major' "$artifact")
    ceiling=$(jq -r '.ceiling' "$artifact")
    [ "$ext" = "timescaledb" ]
    [ "$pg" = "18" ]
    [ "$ceiling" = "2.27.1" ]

    # resolved array must contain all 3 versions
    local resolved_count
    resolved_count=$(jq '.resolved | length' "$artifact")
    [ "$resolved_count" -eq 3 ]

    # available must contain the 2 that built
    local available_count
    available_count=$(jq '.available | length' "$artifact")
    [ "$available_count" -eq 2 ]

    # excluded must contain the 1 that failed
    local excluded_count
    excluded_count=$(jq '.excluded | length' "$artifact")
    [ "$excluded_count" -eq 1 ]

    # excluded entry must have version + reason fields
    local excl_ver excl_reason
    excl_ver=$(jq -r '.excluded[0].version' "$artifact")
    excl_reason=$(jq -r '.excluded[0].reason' "$artifact")
    [ "$excl_ver" = "2.25.0" ]
    [[ -n "$excl_reason" ]]
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

@test "K-stale-cleanup: stale versionset artifact from previous run is removed" {
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

    # Pre-create a stale versionset artifact from a prior run.
    local stale_vs="$lineage_dir/ext-timescaledb-pg18-versionset.json"
    printf '{"ext":"timescaledb","pg_major":"18","ceiling":"2.24.0","resolved":["2.24.0"],"available":["2.24.0"],"excluded":[]}\n' \
        > "$stale_vs"

    run build_tag_push_extensions \
        "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR" "true" "timescaledb"

    [ "$status" -eq 0 ]

    # The new versionset artifact must reflect the current run (ceiling=2.27.1).
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
