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
        export ROOT_DIR=\"$TEST_TEMP_DIR\"
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export counter_file=\"$counter_file\"
        cd \"$SCRIPTS_DIR\"
        source ./build-extensions.sh

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
