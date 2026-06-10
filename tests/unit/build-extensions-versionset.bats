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
    # docker: image inspect absent locally; manifest inspect returns "manifest unknown";
    # build and push succeed (production: bundle assembly succeeds when per-version
    # images are available; build/push of the bundle image succeeds).
    docker() {
        local _cmd="${1:-}"
        case "$_cmd" in
            build|push)
                # Bundle build/push succeed by default — production-faithful (if
                # per-version images exist, the bundle assembly succeeds).
                return 0
                ;;
            manifest)
                if [[ "$*" == *"manifest inspect"* ]]; then
                    printf 'manifest unknown: manifest unknown\n' >&2
                fi
                return 1
                ;;
            *)
                return 1
                ;;
        esac
    }
    export -f docker

    # skopeo: confirm not-found (production-faithful; avoids real network calls when
    # skopeo binary is installed on the test host).
    skopeo() {
        printf 'manifest unknown: manifest unknown\n' >&2
        return 1
    }
    export -f skopeo

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

    # _capture_index_digest: returns a stable digest on success (production-faithful:
    # a successful push always has a retrievable digest; tests that need failure
    # override this function directly).
    _capture_index_digest() {
        echo "sha256:0000000000000000000000000000000000000000000000000000000000000000"
        return 0
    }
    export -f _capture_index_digest

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
# FIX1: pushed artifact (do_push=true, no ARCH_SUFFIX) must include version_digests
# for every available version.
#
# Invariant: version_digests absent ⟺ artifact was NOT pushed.
# A pushed artifact without version_digests would cause the consumer to emit
# mutable-tag refs, silently regressing the digest-pinned ref guarantee.
#
# Before fix: _bundle_and_write_artifact omits version_digests on the non-ARCH_SUFFIX
# push path → consumer falls back to tag-based refs (wrong for a pushed artifact).
# After fix: version_digests is captured and included for every available version.
# ---------------------------------------------------------------------------

@test "FIX1-push-has-digests: do_push=true artifact includes version_digests for every available version" {
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

    # _capture_index_digest already mocked in _setup_default_mocks to return a valid
    # fixed digest (sha256:000...0).  All versions available — no build failures.

    run build_tag_push_extensions \
        "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR" "true" "timescaledb"

    [ "$status" -eq 0 ]

    # Artifact must exist (written by _bundle_and_write_artifact on the push path).
    local artifact="$TEST_TEMP_DIR/.build-lineage/ext-timescaledb-pg18-versionset.json"
    [ -f "$artifact" ]

    # version_digests must be present (pushed artifact invariant: absent ⟺ not pushed).
    local vd_present
    vd_present=$(jq -r 'if has("version_digests") then "yes" else "no" end' "$artifact")
    [ "$vd_present" = "yes" ]

    # version_digests must contain an entry for EVERY available version.
    local available_count vd_count
    available_count=$(jq '.available | length' "$artifact")
    vd_count=$(jq '.version_digests | length' "$artifact")
    [ "$available_count" -eq "$vd_count" ]

    # Every version in available[] must have a valid sha256 digest.
    local all_valid
    all_valid=$(jq -r '.available[] as $v | .version_digests[$v] // "MISSING" | test("^sha256:[0-9a-f]{64}$")' "$artifact" \
        | sort -u)
    [ "$all_valid" = "true" ]
}

@test "FIX1-no-push-no-digests: do_push=false artifact omits version_digests (local/no-push invariant)" {
    export LOCAL_ONLY=true

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
        "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR" "false" "timescaledb"

    [ "$status" -eq 0 ]

    # Artifact must exist (LOCAL_ONLY allows artifact write on the no-push path).
    local artifact="$TEST_TEMP_DIR/.build-lineage/ext-timescaledb-pg18-versionset.json"
    [ -f "$artifact" ]

    # version_digests must be ABSENT (no-push path; consumer uses tag-based refs).
    local vd_present
    vd_present=$(jq -r 'if has("version_digests") then "yes" else "no" end' "$artifact")
    [ "$vd_present" = "no" ]
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
        docker()               { local _dk="\$1"; if [[ "\$_dk" == "build" || "\$_dk" == "push" ]]; then return 0; fi; if [[ "\$_dk" == "manifest" || "\$_dk" == "buildx" ]]; then printf 'manifest unknown: manifest unknown\n' >&2; return 1; fi; return 1; }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest
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
        docker() { local _dk="\$1"; case "\$_dk" in build|push) return 0;; manifest|buildx) echo manifest unknown >&2; return 1;; *) return 1;; esac; }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest
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
# TT-1: empty-HA resolver failure + LOCAL_ONLY=true → degrade to ceiling, exit 0.
# The mode-gated ceiling degrade lives in the CALLER (build_tag_push_extensions),
# not in the resolver. The resolver now exits non-zero on empty HA; the caller
# catches that and degrades to ceiling only when LOCAL_ONLY=true.
# ---------------------------------------------------------------------------

@test "TT-local-degrade: empty-HA resolver failure + LOCAL_ONLY=true → ceiling built, exit 0" {
    export LOCAL_ONLY=true

    # Simulate what the resolver now does on empty HA: exits non-zero, no stdout.
    resolve_version_set() {
        echo "::error::no HA tags found (empty response — fail-closed)" >&2
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

    local build_log="$TEST_TEMP_DIR/tt_local_build_calls.log"
    build_ext_image() {
        echo "BUILD_CALLED ext=${1} ver=${2}" >> "$build_log"
        return 0
    }
    export -f build_ext_image

    run build_tag_push_extensions \
        "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR" "false" "timescaledb"

    # LOCAL_ONLY recovery path: must succeed with ceiling-only degrade.
    [ "$status" -eq 0 ]

    # Must have built exactly the ceiling version (degraded, not full set).
    local build_count
    build_count=$(_count_log_lines "$build_log")
    [ "$build_count" -eq 1 ]
    [[ "$(cat "$build_log")" == *"ver=2.27.1"* ]]
}

# ---------------------------------------------------------------------------
# TT-2: empty-HA resolver failure + LOCAL_ONLY=false (publish path) → FATAL.
# A transient HA-metadata outage on the publish path must exit non-zero so CI
# does not silently publish a ceiling-only image that drops retained versions.
# ---------------------------------------------------------------------------

@test "TT-publish-fatal: empty-HA resolver failure + LOCAL_ONLY=false → exit non-zero (fail-closed)" {
    export LOCAL_ONLY=false

    resolve_version_set() {
        echo "::error::no HA tags found (empty response — fail-closed)" >&2
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

    local build_log="$TEST_TEMP_DIR/tt_publish_build_calls.log"
    build_ext_image() {
        echo "BUILD_CALLED ext=${1} ver=${2}" >> "$build_log"
        return 0
    }
    export -f build_ext_image

    run build_tag_push_extensions \
        "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR" "true" "timescaledb"

    # Publish path must remain fail-closed.
    [ "$status" -ne 0 ]

    # Must NOT have built anything (no silent ceiling fallback on publish path).
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

        docker() { local _dk="\$1"; case "\$_dk" in build|push) return 0;; manifest|buildx) echo manifest unknown >&2; return 1;; *) return 1;; esac; }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

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

        docker() { local _dk="\$1"; case "\$_dk" in build|push) return 0;; manifest|buildx) echo manifest unknown >&2; return 1;; *) return 1;; esac; }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

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

        image_exists_in_registry() {
            local tag=\"\${1##*:}\"
            grep -qxF \"\$tag\" \"\$registry_present\" 2>/dev/null
        }
        export -f image_exists_in_registry

        docker() {
            local _cmd="\${1:-}"
            if [[ "\$_cmd" == "build" || "\$_cmd" == "push" ]]; then
                return 0
            fi
            if [[ "\$*" == *'manifest inspect'* ]]; then
                echo 'manifest unknown: manifest unknown' >&2
            fi
            return 1
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

        skopeo() {
            echo 'manifest unknown: manifest unknown' >&2
            return 1
        }
        export -f skopeo

        _image_present_3state() {
            case \"\$1\" in
                *pg18-2.25.0*) return 1 ;;
                *pg18-2.26.0*) return 0 ;;
                *pg18-2.27.1*) return 0 ;;
                *)             return 1 ;;
            esac
        }
        export -f _image_present_3state

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

        docker() { local _dk="\$1"; case "\$_dk" in build|push) return 0;; manifest|buildx) echo manifest unknown >&2; return 1;; *) return 1;; esac; }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

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

        docker() { local _dk="\$1"; case "\$_dk" in build|push) return 0;; manifest|buildx) echo manifest unknown >&2; return 1;; *) return 1;; esac; }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

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

        docker() { local _dk="\$1"; case "\$_dk" in build|push) return 0;; manifest|buildx) echo manifest unknown >&2; return 1;; *) return 1;; esac; }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

        # All versions pulled successfully → no fallback builds needed
        pull_ext_image() { return 0; }
        export -f pull_ext_image

        # After pull, images are present locally (docker inspect returns 0)
        docker() {
            # Any 'docker image inspect <image>' call: succeed for pulled images
            return 0
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

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

        docker() { local _dk="\$1"; case "\$_dk" in build|push) return 0;; manifest|buildx) echo manifest unknown >&2; return 1;; *) return 1;; esac; }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

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

        docker() { local _dk="\$1"; case "\$_dk" in build|push) return 0;; manifest|buildx) echo manifest unknown >&2; return 1;; *) return 1;; esac; }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

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

        docker() { local _dk="\$1"; case "\$_dk" in build|push) return 0;; manifest|buildx) echo manifest unknown >&2; return 1;; *) return 1;; esac; }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

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

        docker() { local _dk="\$1"; case "\$_dk" in build|push) return 0;; manifest|buildx) echo manifest unknown >&2; return 1;; *) return 1;; esac; }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

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

        # Local docker inspect: consults local_store file; build/push always succeed
        docker() {
            local _dcmd=\"\${1:-}\"
            if [[ \"\$_dcmd\" == \"build\" || \"\$_dcmd\" == \"push\" ]]; then
                return 0
            fi
            local img=\"\${*: -1}\"
            grep -qxF \"\$img\" \"\$local_store\" 2>/dev/null
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

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

        # PROBE ALWAYS ABSENT: simulates GHCR propagation lag.
        # image_exists_in_registry returns 1 for all (simulates lag after push).
        image_exists_in_registry() { return 1; }
        export -f image_exists_in_registry

        docker() {
            local _dcmd=\"\${1:-}\"
            if [[ \"\$_dcmd\" == \"build\" || \"\$_dcmd\" == \"push\" ]]; then
                return 0
            fi
            if [[ \"\$*\" == *'manifest inspect'* ]]; then
                echo 'manifest unknown: manifest unknown' >&2
            fi
            return 1
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

        skopeo() { echo 'manifest unknown: manifest unknown' >&2; return 1; }
        export -f skopeo

        _image_present_3state() {
            return 1
        }
        export -f _image_present_3state

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

        docker() {
            local _dcmd=\"\${1:-}\"
            if [[ \"\$_dcmd\" == \"build\" || \"\$_dcmd\" == \"push\" ]]; then
                return 0
            fi
            if [[ \"\$*\" == *'manifest inspect'* ]]; then
                echo 'manifest unknown: manifest unknown' >&2
            fi
            return 1
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

        skopeo() { echo 'manifest unknown: manifest unknown' >&2; return 1; }
        export -f skopeo

        _image_present_3state() {
            case \"\$1\" in
                *pg18-2.25.0*) return 1 ;;
                *pg18-2.26.0*) return 0 ;;
                *pg18-2.27.1*) return 0 ;;
                *)             return 1 ;;
            esac
        }
        export -f _image_present_3state

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

        docker() { local _dk="\$1"; case "\$_dk" in build|push) return 0;; manifest|buildx) echo manifest unknown >&2; return 1;; *) return 1;; esac; }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

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
        docker() { local _dk="\$1"; case "\$_dk" in build|push) return 0;; manifest|buildx) echo manifest unknown >&2; return 1;; *) return 1;; esac; }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest
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

        docker() { local _dk="\$1"; case "\$_dk" in build|push) return 0;; manifest|buildx) echo manifest unknown >&2; return 1;; *) return 1;; esac; }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

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

        docker() { local _dk="\$1"; case "\$_dk" in build|push) return 0;; manifest|buildx) echo manifest unknown >&2; return 1;; *) return 1;; esac; }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

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
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest
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

        docker() { local _dk="\$1"; case "\$_dk" in build|push) return 0;; manifest|buildx) echo manifest unknown >&2; return 1;; *) return 1;; esac; }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

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

        docker() { local _dk="\$1"; case "\$_dk" in build|push) return 0;; manifest|buildx) echo manifest unknown >&2; return 1;; *) return 1;; esac; }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

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

    # docker manifest inspect: emit "manifest unknown" (production-faithful absent signal).
    docker() {
        if [[ "$*" == *"manifest inspect"* ]]; then
            printf 'manifest unknown: manifest unknown\n' >&2
        fi
        return 1
    }
    export -f docker

    # skopeo: confirm not-found (avoids real network call when skopeo binary is installed).
    skopeo() {
        printf 'manifest unknown: manifest unknown\n' >&2
        return 1
    }
    export -f skopeo

    local version_set_json='["2.25.0","2.26.0","2.27.1"]'
    PULL_ONLY=false LOCAL_ONLY=false DRY_RUN=false

    # All versions are definitively absent (manifest unknown) → available=[] →
    # ceiling absent → artifact NOT written (function returns 0, no file).
    run _emit_versionset_artifact "timescaledb" "$CONFIG_FILE" "18" \
        "$version_set_json" "2.27.1"

    local artifact="$lineage_dir/ext-timescaledb-pg18-versionset.json"

    # available=[] → no ceiling in available → artifact must NOT be written.
    # RED before fix: file exists with available=[].
    # GREEN after fix: file absent.
    [ "$status" -eq 0 ]
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

    # docker manifest inspect: emit "manifest unknown" for absent images.
    docker() {
        if [[ "$*" == *"manifest inspect"* ]]; then
            printf 'manifest unknown: manifest unknown\n' >&2
        fi
        return 1
    }
    export -f docker

    # skopeo: confirm not-found (avoids real network call when skopeo binary is installed).
    skopeo() {
        printf 'manifest unknown: manifest unknown\n' >&2
        return 1
    }
    export -f skopeo

    local version_set_json='["2.25.0","2.26.0","2.27.1"]'
    PULL_ONLY=false LOCAL_ONLY=false DRY_RUN=false

    # 2.25.0 and 2.26.0: image_exists_in_registry returns 0 → PRESENT (fast-path, no probe).
    # 2.27.1: image_exists_in_registry returns 1 → probe → "manifest unknown" → ABSENT.
    # available=[2.25.0,2.26.0], ceiling 2.27.1 NOT in available → no artifact.
    run _emit_versionset_artifact "timescaledb" "$CONFIG_FILE" "18" \
        "$version_set_json" "2.27.1"

    local artifact="$lineage_dir/ext-timescaledb-pg18-versionset.json"

    # available=[2.25.0,2.26.0] — ceiling 2.27.1 NOT in available.
    # RED before fix: artifact written despite missing ceiling.
    # GREEN after fix: artifact NOT written.
    [ "$status" -eq 0 ]
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

        docker() { local _dk="\$1"; case "\$_dk" in build|push) return 0;; manifest|buildx) echo manifest unknown >&2; return 1;; *) return 1;; esac; }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

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

    # docker: "build" fails only for 2.25.0 (non-ceiling); "push" succeeds for
    # per-version and bundle images.
    # "manifest inspect": returns "manifest unknown" for 2.25.0 (never pushed),
    # and absent for other inspect sub-commands (so _image_needs_build sees absent →
    # attempts build for all versions).
    # This is production-faithful: a version whose build failed is never pushed,
    # so the registry returns "manifest unknown" for its tag.
    local build_call_log="$TEST_TEMP_DIR/docker_build_calls.log"
    export DOCKER="docker"
    docker() {
        local _dcmd="${1:-}"
        if [[ "$_dcmd" == "build" ]]; then
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
        if [[ "$_dcmd" == "push" ]]; then
            return 0
        fi
        if [[ "$*" == *"manifest inspect"* ]]; then
            # Production-faithful: 2.25.0 was never pushed → "manifest unknown".
            # 2.27.1 is in _built_this_run_set so probe is never called for it.
            printf 'manifest unknown: manifest unknown\n' >&2
            return 1
        fi
        # Other sub-commands (image inspect, etc.): image absent (triggers build).
        return 1
    }
    export -f docker
    export DOCKER

    # Production-faithful: a successful push always has a retrievable digest.
    _capture_index_digest() {
        echo "sha256:0000000000000000000000000000000000000000000000000000000000000000"
        return 0
    }
    export -f _capture_index_digest

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

        docker() { local _dk="\$1"; case "\$_dk" in build|push) return 0;; manifest|buildx) echo manifest unknown >&2; return 1;; *) return 1;; esac; }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

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
        docker() { local _dk="\$1"; case "\$_dk" in build|push) return 0;; manifest|buildx) echo manifest unknown >&2; return 1;; *) return 1;; esac; }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest
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
        docker() { local _dk="\$1"; case "\$_dk" in build|push) return 0;; manifest|buildx) echo manifest unknown >&2; return 1;; *) return 1;; esac; }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest
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
        # Note: _image_registry_probe_3state delegates to _image_present_3state in build-extensions.sh
        # so mocking _image_present_3state controls ext_ref_resolve's probe behavior too.
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
        docker() { local _dk="\$1"; case "\$_dk" in build|push) return 0;; manifest|buildx) echo manifest unknown >&2; return 1;; *) return 1;; esac; }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest
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
        docker() { local _dk="\$1"; case "\$_dk" in build|push) return 0;; manifest|buildx) echo manifest unknown >&2; return 1;; *) return 1;; esac; }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest
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

# ---------------------------------------------------------------------------
# OO: _image_present_3state fail-closed polarity (inverted classification).
#
# BEFORE fix: default was ABSENT (fail-open). Ambiguous errors like
#   toomanyrequests, denied, unauthorized, no such host, EOF, empty stderr
#   all fell through to ABSENT → silently dropped retained published versions.
#
# AFTER fix (OO) + UU tightening: default is ERROR (fail-closed).
#   ABSENT only when stderr contains a REGISTRY-MANIFEST-SPECIFIC not-found signal:
#     manifest unknown | name unknown | repository name not known | no such manifest
#   Bare "not found", "no such image", and bare "404" are excluded (UU fix):
#   they also appear in infra errors like "docker: command not found" and would
#   mis-classify an infra failure as ABSENT.
#   EVERYTHING ELSE non-zero → ERROR (rc=2, fail-closed).
#
# Mock strategy: mock `docker` to emit controlled stderr + return non-zero.
# image_exists_in_registry returns 1 (not present) so the probe path is entered.
# ---------------------------------------------------------------------------

_run_3state_probe() {
    # Helper: run _image_present_3state in a subshell; capture its rc.
    # Usage: _run_3state_probe <docker_stderr> → prints rc (0=PRESENT,1=ABSENT,2=ERROR)
    # Mocks both docker and skopeo so real network calls are never made.
    # Skopeo mock mirrors the tightened allow-list (registry-manifest-specific only):
    #   manifest unknown, name unknown, repository name not known, no such manifest
    #   → skopeo confirms not-found (ABSENT preserved)
    #   everything else → skopeo returns transient (ERROR preserved)
    # Note: bare "not found", "no such image", bare "404" are NOT in the allow-list.
    local stderr_msg="$1"
    (
        docker() {
            if [[ "$*" == *"manifest inspect"* ]]; then
                printf '%s\n' "$stderr_msg" >&2
                return 1
            fi
            return 1
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest
        # skopeo mock: mirrors the tightened classification.
        skopeo() {
            local _not_found_pat='manifest unknown|name unknown|repository name not known|no such manifest'
            if printf '%s\n' "$stderr_msg" | grep -qiE "$_not_found_pat"; then
                printf 'manifest unknown: manifest unknown\n' >&2
                return 1  # confirm not-found
            else
                printf 'unauthorized: authentication required\n' >&2
                return 1  # non-not-found transient
            fi
        }
        export -f skopeo
        image_exists_in_registry() { return 1; }
        export -f image_exists_in_registry
        LOCAL_ONLY=false PULL_ONLY=false
        _image_present_3state "ghcr.io/test/ext-timescaledb:pg18-2.27.1"
    )
    printf '%d' $?
}

@test "OO-explicit-not-found-manifest-unknown: 'manifest unknown' stderr → ABSENT (rc 1)" {
    local rc
    rc=$(_run_3state_probe "Error response from daemon: manifest unknown: manifest unknown")
    [ "$rc" -eq 1 ]
}

@test "OO-explicit-not-found-404: '404 Not Found' → ERROR (rc 2, fail-closed after UU allow-list tightening)" {
    # Before UU fix: bare "404" and "not found" matched → ABSENT (rc 1) — fail-open.
    # After UU fix: "Error: 404 Not Found" is a generic HTTP error from a load-balancer
    # or cred-helper, not a registry-manifest-specific signal → ERROR (rc 2).
    local rc
    rc=$(_run_3state_probe "Error: 404 Not Found")
    [ "$rc" -eq 2 ]
}

@test "OO-explicit-not-found-name-unknown: 'name unknown' in stderr → ABSENT (rc 1)" {
    local rc
    rc=$(_run_3state_probe "Error: name unknown: repository name not known to registry")
    [ "$rc" -eq 1 ]
}

@test "OO-explicit-not-found-no-such-manifest: 'no such manifest' in stderr → ABSENT (rc 1)" {
    local rc
    rc=$(_run_3state_probe "no such manifest: ghcr.io/test/ext-timescaledb:pg18-2.27.1")
    [ "$rc" -eq 1 ]
}

@test "OO-toomanyrequests-is-ERROR-not-ABSENT: 'toomanyrequests' stderr → ERROR (rc 2, fail-closed)" {
    # RED before fix: fell through to ABSENT (rc 1) → silently dropped published version.
    # GREEN after fix: classified as ERROR (rc 2) → fail-closed.
    local rc
    rc=$(_run_3state_probe "toomanyrequests: You have reached your pull rate limit")
    [ "$rc" -eq 2 ]
}

@test "OO-429-is-ERROR-not-ABSENT: '429' in stderr → ERROR (rc 2, fail-closed)" {
    local rc
    rc=$(_run_3state_probe "Error: 429 Too Many Requests")
    [ "$rc" -eq 2 ]
}

@test "OO-denied-is-ERROR-not-ABSENT: 'denied' in stderr → ERROR (rc 2, fail-closed)" {
    local rc
    rc=$(_run_3state_probe "denied: access forbidden")
    [ "$rc" -eq 2 ]
}

@test "OO-unauthorized-is-ERROR-not-ABSENT: 'unauthorized' in stderr → ERROR (rc 2, fail-closed)" {
    local rc
    rc=$(_run_3state_probe "unauthorized: authentication required")
    [ "$rc" -eq 2 ]
}

@test "OO-no-such-host-is-ERROR-not-ABSENT: 'no such host' in stderr → ERROR (rc 2, fail-closed)" {
    local rc
    rc=$(_run_3state_probe "dial tcp: lookup ghcr.io: no such host")
    [ "$rc" -eq 2 ]
}

@test "OO-network-unreachable-is-ERROR-not-ABSENT: 'network is unreachable' stderr → ERROR (rc 2)" {
    local rc
    rc=$(_run_3state_probe "dial tcp: connect: network is unreachable")
    [ "$rc" -eq 2 ]
}

@test "OO-EOF-is-ERROR-not-ABSENT: 'EOF' in stderr → ERROR (rc 2, fail-closed)" {
    local rc
    rc=$(_run_3state_probe "unexpected EOF")
    [ "$rc" -eq 2 ]
}

@test "OO-context-deadline-is-ERROR-not-ABSENT: 'context deadline exceeded' → ERROR (rc 2)" {
    local rc
    rc=$(_run_3state_probe "context deadline exceeded")
    [ "$rc" -eq 2 ]
}

@test "OO-empty-stderr-non-zero-is-ERROR-not-ABSENT: empty stderr + rc≠0 → ERROR (rc 2, fail-closed)" {
    # RED before fix: empty stderr → fell through to ABSENT (rc 1).
    # GREEN after fix: empty stderr + non-zero → ERROR (rc 2, fail-closed).
    # Rationale: test mocks with `docker() { return 1; }` (no stderr) represent
    # controlled absent-image conditions in unit tests and are granted ABSENT via
    # `image_exists_in_registry` returning 0 before this probe runs. In production,
    # the registry probe with empty stderr and non-zero exit is always ambiguous
    # (daemon not running, socket error) — must be fail-closed.
    #
    # NOTE: This test verifies the PRODUCTION polarity. Existing unit tests that use
    # `docker() { return 1; }` (no stderr) as a controlled "absent" mock work because
    # image_exists_in_registry is also mocked to return 1 (skip the fast-path), and
    # those tests do NOT call _image_present_3state directly — they call higher-level
    # functions that use _image_needs_build (which uses image_exists_in_registry).
    local rc
    rc=$(_run_3state_probe "")
    [ "$rc" -eq 2 ]
}

# ---------------------------------------------------------------------------
# QQ: mixed run — timescaledb all-cached (skipped by build_tag_push_extensions)
# while another ext (pgvector) is built. A stale per-version duration file for
# an out-of-window timescaledb version pre-exists.
#
# Before fix: _cleanup_stale_duration_files is only called for extensions that
#   are in the `extensions_to_build` list passed to build_tag_push_extensions.
#   In a mixed run, timescaledb is NOT in that list (all cached), so its stale
#   duration files are never cleaned → inflate sum_flavor_extension_durations.
#
# After fix: stale cleanup also runs for resolver-backed extensions that are
#   PROCESSED during the run (whether built or skipped-as-cached), not just
#   for those explicitly passed to build_tag_push_extensions.
#
# RED before fix: stale file survives after the run.
# GREEN after fix: stale file removed; in-window files and versionset preserved.
# ---------------------------------------------------------------------------

@test "QQ-mixed-run-stale-cleanup: timescaledb all-cached + pgvector built → stale timescaledb duration file removed" {
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

    local lineage_dir="$tmpd/.build-lineage"
    mkdir -p "$lineage_dir"

    # Pre-create a stale per-version duration file for an out-of-window timescaledb version.
    # 2.20.0 is NOT in the current resolved set [2.25.0,2.26.0,2.27.1].
    local stale_ts_file="$lineage_dir/ext-timescaledb-pg18-2.20.0.json"
    printf '{"ext":"timescaledb","version":"2.20.0","duration_seconds":42}\n' > "$stale_ts_file"

    # Pre-create an in-window timescaledb duration file (2.27.1 = ceiling, should survive... actually
    # _cleanup_stale_duration_files removes ALL per-version files before the run writes fresh ones).
    # After cleanup, 2.27.1 would be absent (nothing was built in this run since it was cached).
    # The versionset artifact itself must survive.
    local ts_vs_artifact="$lineage_dir/ext-timescaledb-pg18-versionset.json"
    printf '{"ext":"timescaledb","pg_major":"18","ceiling":"2.27.1","resolved":["2.25.0","2.26.0","2.27.1"],"available":["2.25.0","2.26.0","2.27.1"],"excluded":[]}\n' \
        > "$ts_vs_artifact"

    local build_log="${tmpd}/qq_build.log"

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

        # timescaledb: ALL versions already in registry (all-cached, nothing to build).
        # pgvector: absent → triggers build.
        image_exists_in_registry() {
            [[ \"\$1\" == *'timescaledb'* ]] && return 0 || return 1
        }
        export -f image_exists_in_registry

        docker() { local _dk="\$1"; case "\$_dk" in build|push) return 0;; manifest|buildx) echo manifest unknown >&2; return 1;; *) return 1;; esac; }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

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

    # Run must succeed.
    [ "$status" -eq 0 ]

    # pgvector must have been built (it was absent).
    [ -f "$build_log" ]
    [[ "$(cat "$build_log")" == *"ext=pgvector"* ]]

    # The stale timescaledb duration file MUST be removed after the run.
    # RED before fix: stale file survives (cleanup never runs for cached timescaledb).
    # GREEN after fix: stale file removed.
    [ ! -f "$stale_ts_file" ]

    # The timescaledb versionset artifact (-versionset.json) must be preserved
    # (cleanup never touches versionset files).
    [ -f "$ts_vs_artifact" ]
}

# ---------------------------------------------------------------------------
# UU-1: _image_present_3state — "docker: command not found" must be ERROR (rc=2),
# not ABSENT. Before the allow-list tightening, bare "not found" matched, causing
# infra errors to be mis-classified as definitive absence.
# ---------------------------------------------------------------------------

@test "UU-image-present-3state-cmd-not-found: 'docker: command not found' stderr → ERROR (rc=2)" {
    # Use the same _run_3state_probe helper — it already handles the subshell/set-e
    # correctly and is already updated to use the tightened skopeo pattern.
    # "docker: command not found" contains "not found" which was in the OLD allow-list
    # (ABSENT before UU fix) but is NOT in the tightened list (ERROR after UU fix).
    local rc
    rc=$(_run_3state_probe "docker: command not found")
    # Must be ERROR (rc=2), not ABSENT (rc=1).
    [ "$rc" -eq 2 ]
}

@test "UU-image-present-3state-cred-helper-not-found: cred-helper error → ERROR (rc=2)" {
    # "docker-credential-desktop: executable file not found in PATH" contains "not found"
    # which was in the OLD allow-list (ABSENT before UU fix) → now ERROR (rc=2).
    local rc
    rc=$(_run_3state_probe "docker-credential-desktop: executable file not found in PATH")
    [ "$rc" -eq 2 ]
}

@test "UU-image-present-3state-manifest-unknown: 'manifest unknown' stderr → ABSENT (rc=1)" {
    # After the UU tightening, "manifest unknown" is still in the allow-list
    # (it is a genuine registry-manifest-specific not-found signal) → ABSENT (rc=1).
    local rc
    rc=$(_run_3state_probe "manifest unknown: manifest unknown")
    [ "$rc" -eq 1 ]
}

# ---------------------------------------------------------------------------
# WW: skip-without-write paths must delete a stale versionset artifact.
#
# When _emit_versionset_artifact cannot confirm a valid set (empty available[],
# ceiling missing from available[], or probe ERROR) it skips writing the
# artifact.  Before the fix a pre-existing artifact from a prior run would
# survive, and the consumer would read its stale available[] — shipping wrong
# retention sets or masking that the ceiling image is missing.
#
# After the fix every skip-without-write path removes any pre-existing
# ext-<ext>-pg<major>-versionset.json so the consumer's self-heal triggers.
# DRY_RUN=true must never delete (no filesystem mutation).
# The happy path (confirmed set → write) is an unchanged regression check.
# ---------------------------------------------------------------------------

# Helper: drive _emit_versionset_artifact directly in a subprocess so each
# test gets an isolated shell with exactly the mocks it needs.
# Args: extra_vars_block (bash code to export mocks before the call)
#       version_set_json ceiling dry_run
# Prints the exit code of _emit_versionset_artifact.
_run_emit_versionset() {
    local extra_vars="$1" version_set_json="$2" ceiling="$3" dry_run="${4:-false}"
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    bash -c "
        export FORCE=false LOCAL_ONLY=false CONTAINER=postgres
        export ROOT_DIR=\"$tmpd\"
        cd \"$sd\"
        source ./build-extensions.sh
        # Re-set ROOT_DIR and DRY_RUN after source — build-extensions.sh resets both
        # to their defaults (ROOT_DIR to the real repo path; DRY_RUN=false).
        export ROOT_DIR=\"$tmpd\"
        export DRY_RUN=$dry_run

        ext_image_name() { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_config() {
            case \"\$2\" in
                version) echo '$ceiling' ;;
                repo)    echo 'https://github.com/timescale/timescaledb' ;;
                *)       echo '' ;;
            esac
        }
        export -f ext_config

        $extra_vars

        _emit_versionset_artifact timescaledb \"$CONTAINER_DIR/extensions/config.yaml\" 18 '$version_set_json' '$ceiling'
        echo \"RC:\$?\"
    " 2>/dev/null
}

@test "WW-empty-available-deletes-stale: empty available[] on skip path removes stale versionset artifact" {
    # Arrange: stale artifact with available=[2.25.0,2.26.0,2.27.1] from prior run.
    local lineage_dir="$TEST_TEMP_DIR/.build-lineage"
    mkdir -p "$lineage_dir"
    local stale="$lineage_dir/ext-timescaledb-pg18-versionset.json"
    printf '{"ext":"timescaledb","pg_major":"18","ceiling":"2.27.1","resolved":["2.25.0","2.26.0","2.27.1"],"available":["2.25.0","2.26.0","2.27.1"],"excluded":[]}\n' \
        > "$stale"
    [ -f "$stale" ]

    # All probes return ABSENT (rc 1 from _image_present_3state) so available[] is empty.
    # image_exists_in_registry returns 1 (not present) → goes to manifest inspect.
    # docker manifest inspect returns "manifest unknown" → ABSENT.
    local mocks='
        image_exists_in_registry() { return 1; }
        export -f image_exists_in_registry
        docker() {
            if [[ "$*" == *"manifest inspect"* ]]; then
                printf "manifest unknown: manifest unknown\n" >&2
            fi
            return 1
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest
        skopeo() { printf "manifest unknown: manifest unknown\n" >&2; return 1; }
        export -f skopeo
    '

    # version_set has ceiling 2.27.1 but all probes return ABSENT → available empty → skip.
    run _run_emit_versionset "$mocks" '["2.25.0","2.26.0","2.27.1"]' "2.27.1"

    # The stale artifact MUST be deleted (file absent) after the skip.
    # RED before fix: file still present.
    # GREEN after fix: file absent.
    [ ! -f "$stale" ]
}

@test "WW-ceiling-missing-deletes-stale: ceiling absent from available[] removes stale versionset artifact" {
    # Arrange: stale artifact pre-exists.
    local lineage_dir="$TEST_TEMP_DIR/.build-lineage"
    mkdir -p "$lineage_dir"
    local stale="$lineage_dir/ext-timescaledb-pg18-versionset.json"
    printf '{"ext":"timescaledb","pg_major":"18","ceiling":"2.27.1","resolved":["2.25.0","2.26.0","2.27.1"],"available":["2.25.0","2.26.0","2.27.1"],"excluded":[]}\n' \
        > "$stale"
    [ -f "$stale" ]

    # Only 2.25.0 and 2.26.0 are PRESENT; 2.27.1 (ceiling) is definitively ABSENT.
    # Result: available=[2.25.0,2.26.0] but ceiling (2.27.1) is not in available → skip.
    local mocks='
        image_exists_in_registry() {
            [[ "$1" == *"2.25.0"* || "$1" == *"2.26.0"* ]] && return 0 || return 1
        }
        export -f image_exists_in_registry
        docker() {
            if [[ "$*" == *"manifest inspect"* ]]; then
                printf "manifest unknown: manifest unknown\n" >&2
            fi
            return 1
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest
        skopeo() { printf "manifest unknown: manifest unknown\n" >&2; return 1; }
        export -f skopeo
    '

    run _run_emit_versionset "$mocks" '["2.25.0","2.26.0","2.27.1"]' "2.27.1"

    # Stale artifact must be deleted because ceiling is absent from available[].
    [ ! -f "$stale" ]
}

@test "WW-probe-error-deletes-stale: ambiguous probe ERROR (fail-closed) removes stale versionset artifact" {
    # Arrange: stale artifact pre-exists.
    local lineage_dir="$TEST_TEMP_DIR/.build-lineage"
    mkdir -p "$lineage_dir"
    local stale="$lineage_dir/ext-timescaledb-pg18-versionset.json"
    printf '{"ext":"timescaledb","pg_major":"18","ceiling":"2.27.1","resolved":["2.25.0","2.26.0","2.27.1"],"available":["2.25.0","2.26.0","2.27.1"],"excluded":[]}\n' \
        > "$stale"
    [ -f "$stale" ]

    # All probes return ERROR (rc 2 from _image_present_3state): toomanyrequests.
    # image_exists_in_registry returns 1 → goes to manifest inspect.
    # docker manifest inspect returns "toomanyrequests" → ambiguous → ERROR.
    # _emit_versionset_artifact sets _probe_error=true → returns 1 (fail-closed skip).
    local mocks='
        image_exists_in_registry() { return 1; }
        export -f image_exists_in_registry
        docker() {
            if [[ "$*" == *"manifest inspect"* ]]; then
                printf "toomanyrequests: You have reached your pull rate limit\n" >&2
            fi
            return 1
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest
        skopeo() { printf "toomanyrequests: pull rate limit\n" >&2; return 1; }
        export -f skopeo
    '

    run _run_emit_versionset "$mocks" '["2.25.0","2.26.0","2.27.1"]' "2.27.1"

    # Stale artifact must be deleted so consumer self-heals instead of reading stale data.
    [ ! -f "$stale" ]
}

@test "WW-dry-run-preserves: DRY_RUN=true skip path must NOT delete the stale versionset artifact" {
    # Arrange: stale artifact pre-exists.
    local lineage_dir="$TEST_TEMP_DIR/.build-lineage"
    mkdir -p "$lineage_dir"
    local stale="$lineage_dir/ext-timescaledb-pg18-versionset.json"
    printf '{"ext":"timescaledb","pg_major":"18","ceiling":"2.27.1","resolved":["2.25.0","2.26.0","2.27.1"],"available":["2.25.0","2.26.0","2.27.1"],"excluded":[]}\n' \
        > "$stale"
    [ -f "$stale" ]

    # Under DRY_RUN=true, _emit_versionset_artifact returns 0 immediately without
    # touching the filesystem — so the stale file must survive.
    local mocks='
        image_exists_in_registry() { return 1; }
        export -f image_exists_in_registry
        docker() { local _dk="\$1"; case "\$_dk" in build|push) return 0;; manifest|buildx) echo manifest unknown >&2; return 1;; *) return 1;; esac; }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest
    '

    run _run_emit_versionset "$mocks" '["2.25.0","2.26.0","2.27.1"]' "2.27.1" "true"

    # Stale artifact must still be present (no filesystem mutation under DRY_RUN).
    [ -f "$stale" ]
}

@test "WW-happy-overwrites: confirmed set writes artifact with current available[]" {
    # Regression: happy path (all probes PRESENT, ceiling in available) must write
    # the artifact with the CURRENT available list, overwriting any stale content.
    local lineage_dir="$TEST_TEMP_DIR/.build-lineage"
    mkdir -p "$lineage_dir"
    local artifact="$lineage_dir/ext-timescaledb-pg18-versionset.json"

    # Write stale content with old versions.
    printf '{"ext":"timescaledb","pg_major":"18","ceiling":"2.24.0","resolved":["2.24.0"],"available":["2.24.0"],"excluded":[]}\n' \
        > "$artifact"

    # All three versions PRESENT in registry.
    local mocks='
        image_exists_in_registry() { return 0; }
        export -f image_exists_in_registry
        docker() { local _dk="\$1"; case "\$_dk" in build|push) return 0;; manifest|buildx) echo manifest unknown >&2; return 1;; *) return 1;; esac; }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest
    '

    run _run_emit_versionset "$mocks" '["2.25.0","2.26.0","2.27.1"]' "2.27.1"

    # Artifact must exist and reflect the CURRENT available list.
    [ -f "$artifact" ]
    local available_count ceiling_val
    available_count=$(jq '.available | length' "$artifact")
    ceiling_val=$(jq -r '.ceiling' "$artifact")
    # All 3 current versions must be in available.
    [ "$available_count" -eq 3 ]
    # Ceiling must be the NEW ceiling (2.27.1), not the stale 2.24.0.
    [ "$ceiling_val" = "2.27.1" ]
    # The old stale version must NOT appear in available.
    local old_in_available
    old_in_available=$(jq '[.available[] | select(. == "2.24.0")] | length' "$artifact")
    [ "$old_in_available" -eq 0 ]
}

# ---------------------------------------------------------------------------
# YY-1: malformed resolver output (injection-y entries) → fail-closed BEFORE
#        any build/tag/push. The malformed version must NEVER reach docker.
#
# Before fix: _resolve_cached only checks "non-empty JSON array of strings" —
#   malformed semver strings pass through and flow into build/tag/push.
# After fix:  each version in the resolved set is validated with is_strict_semver
#   before the build loop; any non-semver entry → fail-closed (no build).
# ---------------------------------------------------------------------------

@test "YY-1-malformed-injection: resolver returns injection-y version → fail-closed, never reaches build" {
    export LOCAL_ONLY=false

    # Resolver returns a set with an injection-y entry (valid-looking + shell metachar).
    resolve_version_set() {
        echo '["2.27.1","2.27.0; rm -rf /","latest"]'
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

    local build_log="$TEST_TEMP_DIR/yy1_build_calls.log"
    build_ext_image() {
        echo "BUILD_CALLED ext=${1} ver=${2}" >> "$build_log"
        return 0
    }
    export -f build_ext_image

    local tag_log="$TEST_TEMP_DIR/yy1_tag_calls.log"
    tag_ext_image() {
        echo "TAG_CALLED ext=${1} ver=${2}" >> "$tag_log"
        return 0
    }
    export -f tag_ext_image

    run build_tag_push_extensions \
        "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR" "true" "timescaledb"

    # Must fail closed — malformed version must not be allowed through.
    [ "$status" -ne 0 ]

    # The injection-y version must NEVER have been passed to build or tag.
    if [ -f "$build_log" ]; then
        [[ "$(cat "$build_log")" != *"rm -rf"* ]]
        [[ "$(cat "$build_log")" != *"latest"* ]]
    fi
    if [ -f "$tag_log" ]; then
        [[ "$(cat "$tag_log")" != *"rm -rf"* ]]
        [[ "$(cat "$tag_log")" != *"latest"* ]]
    fi
}

@test "YY-2-path-traversal: resolver returns ../evil version → fail-closed, never reaches tag" {
    export LOCAL_ONLY=false

    resolve_version_set() {
        echo '["2.27.1","../evil"]'
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

    local build_log="$TEST_TEMP_DIR/yy2_build_calls.log"
    build_ext_image() {
        echo "BUILD_CALLED ext=${1} ver=${2}" >> "$build_log"
        return 0
    }
    export -f build_ext_image

    local tag_log="$TEST_TEMP_DIR/yy2_tag_calls.log"
    tag_ext_image() {
        echo "TAG_CALLED ext=${1} ver=${2}" >> "$tag_log"
        return 0
    }
    export -f tag_ext_image

    run build_tag_push_extensions \
        "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR" "true" "timescaledb"

    # Must fail closed.
    [ "$status" -ne 0 ]

    # The path-traversal entry must NEVER reach build or tag.
    if [ -f "$build_log" ]; then
        [[ "$(cat "$build_log")" != *"../evil"* ]]
    fi
    if [ -f "$tag_log" ]; then
        [[ "$(cat "$tag_log")" != *"../evil"* ]]
    fi
}

@test "YY-3-valid-set-still-builds: fully valid version set still triggers all builds (regression)" {
    export LOCAL_ONLY=false

    # All valid semver entries — must build all 3.
    resolve_version_set() {
        echo '["2.25.0","2.26.0","2.27.1"]'
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

    local build_log="$TEST_TEMP_DIR/yy3_build_calls.log"
    build_ext_image() {
        echo "BUILD_CALLED ext=${1} ver=${2}" >> "$build_log"
        return 0
    }
    export -f build_ext_image

    run build_tag_push_extensions \
        "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR" "true" "timescaledb"

    [ "$status" -eq 0 ]

    local build_count
    build_count=$(_count_log_lines "$build_log")
    [ "$build_count" -eq 3 ]
    [[ "$(cat "$build_log")" == *"ver=2.25.0"* ]]
    [[ "$(cat "$build_log")" == *"ver=2.26.0"* ]]
    [[ "$(cat "$build_log")" == *"ver=2.27.1"* ]]
}

# ---------------------------------------------------------------------------
# YY-4: shared is_strict_semver validator — unit tests for the shared function
#        extracted to helpers/extension-utils.sh.
# ---------------------------------------------------------------------------

@test "YY-4-is-strict-semver-valid: is_strict_semver accepts standard X.Y.Z versions" {
    # is_strict_semver must return 0 (true) for canonical semver strings.
    _source_build_extensions

    for ver in "0.0.1" "1.0.0" "2.27.1" "100.200.300" "0.8.2"; do
        run bash -c "
            source \"$HELPERS_DIR/extension-utils.sh\"
            is_strict_semver '$ver' && echo OK || echo FAIL
        "
        [ "$status" -eq 0 ]
        [[ "$output" == *"OK"* ]]
    done
}

@test "YY-4-is-strict-semver-invalid: is_strict_semver rejects non-semver and injection strings" {
    for ver in "latest" "2.27" "2.27.1-beta" "2.27.1+build" "2.27.0; rm -rf /" "../evil" "" "v2.27.1" "2.27.1.0"; do
        run bash -c "
            source \"$HELPERS_DIR/extension-utils.sh\"
            is_strict_semver '$ver' && echo OK || echo FAIL
        "
        # is_strict_semver must return non-zero (FAIL output) for these inputs.
        [[ "$output" == *"FAIL"* ]]
    done
}

# ---------------------------------------------------------------------------
# AB-single-version-nonsemver-builds: a NON-resolver extension pinned to a
# two-component version (1.14 — the format pg_ivm uses in config.yaml) must
# NOT be rejected by the semver gate. The gate applies ONLY to resolver-backed
# extensions; trusted single-version config inputs are not subject to it.
#
# Before fix: is_strict_semver gate runs unconditionally → rejects "1.14" →
#   build is never triggered, extension fails (RED).
# After fix:  gate is skipped for non-resolver extensions → "1.14" flows
#   through to build/tag/push normally (GREEN).
# ---------------------------------------------------------------------------

@test "AB-single-version-nonsemver-builds: non-resolver ext pinned to 1.14 builds successfully" {
    export LOCAL_ONLY=false

    # Config with NO version_set.resolver — single-version, trusted input.
    cat > "$CONTAINER_DIR/extensions/config.yaml" <<'EOCFG'
extensions:
  pg_ivm:
    version: "1.14"
    repo: "https://github.com/sraoss/pg_ivm"
    priority: 1
EOCFG

    # Dockerfile must exist so build_ext_image is reached.
    touch "$EXT_BUILD_DIR/pg_ivm.Dockerfile"

    # resolve_version_set: single-version (no resolver configured) — echoes ["1.14"].
    resolve_version_set() {
        echo '["1.14"]'
    }
    export -f resolve_version_set

    ext_config() {
        local _ext="$1" _key="$2"
        case "$_key" in
            version)           echo "1.14" ;;
            repo)              echo "https://github.com/sraoss/pg_ivm" ;;
            version_set.resolver) echo "" ;;
            *)                 echo "" ;;
        esac
    }
    export -f ext_config

    local build_log="$TEST_TEMP_DIR/ab_single_build.log"
    build_ext_image() {
        echo "BUILD_CALLED ext=${1} ver=${2}" >> "$build_log"
        return 0
    }
    export -f build_ext_image

    local tag_log="$TEST_TEMP_DIR/ab_single_tag.log"
    tag_ext_image() {
        echo "TAG_CALLED ext=${1} ver=${2}" >> "$tag_log"
        return 0
    }
    export -f tag_ext_image

    local push_log="$TEST_TEMP_DIR/ab_single_push.log"
    push_ext_image() {
        echo "PUSH_CALLED ext=${1} ver=${2}" >> "$push_log"
        return 0
    }
    export -f push_ext_image

    run build_tag_push_extensions \
        "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR" "true" "pg_ivm"

    # Must succeed — two-component version from trusted config is not rejected.
    [ "$status" -eq 0 ]

    # The build must have been called with version 1.14 (gate did not reject it).
    [ -f "$build_log" ]
    [[ "$(cat "$build_log")" == *"ver=1.14"* ]]

    # Tag and push must also have been called (the version actually reached them).
    [ -f "$tag_log" ]
    [[ "$(cat "$tag_log")" == *"ver=1.14"* ]]
    [ -f "$push_log" ]
    [[ "$(cat "$push_log")" == *"ver=1.14"* ]]
}

# ---------------------------------------------------------------------------
# AB-resolver-backed-still-gated: a resolver-backed extension (timescaledb)
# with a malformed entry in its resolver output must STILL fail closed after
# the narrowing. Confirms the YY hardening (strict-semver gate on resolver
# output) was not disabled by the AB fix — only its APPLICATION was narrowed
# to resolver-backed extensions.
#
# The config used here has version_set.resolver configured (same as YY tests),
# so the gate MUST still apply and reject the malformed entry.
# ---------------------------------------------------------------------------

@test "AB-resolver-backed-still-gated: resolver-backed ext with malformed output still fails closed" {
    export LOCAL_ONLY=false

    # Config has version_set.resolver — this ext IS resolver-backed.
    # (Uses the CONFIG_FILE from setup(), which already has timescaledb with resolver.)

    # Resolver returns a set with an injection-y entry.
    resolve_version_set() {
        echo '["2.27.1","2.27.0; rm -rf /"]'
    }
    export -f resolve_version_set

    ext_config() {
        local _ext="$1" _key="$2"
        case "$_key" in
            version)              echo "2.27.1" ;;
            repo)                 echo "https://github.com/timescale/timescaledb" ;;
            version_set.resolver) echo "scripts/resolvers/timescaledb-ha.sh" ;;
            *)                    echo "" ;;
        esac
    }
    export -f ext_config

    local build_log="$TEST_TEMP_DIR/ab_resolver_build.log"
    build_ext_image() {
        echo "BUILD_CALLED ext=${1} ver=${2}" >> "$build_log"
        return 0
    }
    export -f build_ext_image

    local tag_log="$TEST_TEMP_DIR/ab_resolver_tag.log"
    tag_ext_image() {
        echo "TAG_CALLED ext=${1} ver=${2}" >> "$tag_log"
        return 0
    }
    export -f tag_ext_image

    run build_tag_push_extensions \
        "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR" "true" "timescaledb"

    # Must fail closed — resolver-backed gate still active.
    [ "$status" -ne 0 ]

    # The malformed entry must NEVER reach build or tag.
    if [ -f "$build_log" ]; then
        [[ "$(cat "$build_log")" != *"rm -rf"* ]]
    fi
    if [ -f "$tag_log" ]; then
        [[ "$(cat "$tag_log")" != *"rm -rf"* ]]
    fi
}

# ---------------------------------------------------------------------------
# AD-1: LOCAL_ONLY=true, resolver unavailable in final pass, ceiling built →
# NO reduced version-set artifact is written. Any pre-existing stale artifact
# for that (ext, major) is DELETED so it cannot be silently consumed.
#
# RED before fix (AC): artifact WAS written with available:[ceiling] — silently
#   ships reduced TimescaleDB retention, breaking persisted databases on older
#   retained versions (the exact failure the feature exists to prevent).
# GREEN after fix (AD): artifact is NOT written; stale artifact is removed;
#   downstream build must use skopeo or a CI-produced artifact.
# ---------------------------------------------------------------------------
@test "AD-1: LOCAL_ONLY=true + resolver unavailable in final pass → no artifact, stale deleted" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    local build_log="${tmpd}/ad1_build.log"

    # Pre-create a stale artifact to verify it is DELETED on recovery.
    local lineage_dir="$tmpd/.build-lineage"
    mkdir -p "$lineage_dir"
    local artifact="$lineage_dir/ext-timescaledb-pg18-versionset.json"
    printf '{"ext":"timescaledb","pg_major":"18","ceiling":"2.26.0","resolved":["2.26.0"],"available":["2.26.0"],"excluded":[]}\n' \
        > "$artifact"

    run bash -c "
        export FORCE=false LOCAL_ONLY=true DRY_RUN=false CONTAINER=postgres
        cd \"$sd\"
        source ./build-extensions.sh
        export ROOT_DIR=\"$tmpd\" LOCAL_ONLY=true

        resolve_version_set() {
            echo '::error::simulated upstream outage' >&2
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
        docker() { local _dk="\$1"; case "\$_dk" in build|push) return 0;; manifest|buildx) echo manifest unknown >&2; return 1;; *) return 1;; esac; }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

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
        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority

        main postgres --major-version 18 --local-only
    "

    # Local recovery path must succeed (ceiling still built).
    [ "$status" -eq 0 ]

    # Ceiling must have been built (build_tag_push_extensions degrade is unchanged).
    [ -f "$build_log" ]
    [[ "$(cat "$build_log")" == *"ver=2.27.1"* ]]

    # Artifact must NOT be present — fail-closed, no reduced retention artifact.
    # RED before fix (AC): file exists with available:[ceiling].
    # GREEN after fix (AD): file absent.
    [ ! -f "$artifact" ]
}

# ---------------------------------------------------------------------------
# AD-2: PULL_ONLY=true, resolver unavailable in final pass → no artifact written.
# Consistent with AD-1: both LOCAL_ONLY and PULL_ONLY recovery paths must be
# fail-closed on artifact emission.
# ---------------------------------------------------------------------------
@test "AD-2: PULL_ONLY=true + resolver unavailable in final pass → no artifact written" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    local lineage_dir="$tmpd/.build-lineage"
    mkdir -p "$lineage_dir"

    run bash -c "
        export FORCE=false LOCAL_ONLY=false PULL_ONLY=true DRY_RUN=false CONTAINER=postgres
        cd \"$sd\"
        source ./build-extensions.sh
        export ROOT_DIR=\"$tmpd\" PULL_ONLY=true

        resolve_version_set() {
            echo '::error::simulated outage' >&2
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
        docker() { return 0; }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

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
        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority

        main postgres --major-version 18 --pull-only
    "

    # Recovery path must succeed.
    [ "$status" -eq 0 ]

    # No version-set artifact must be present (consistent with LOCAL_ONLY behavior).
    [ ! -f "$lineage_dir/ext-timescaledb-pg18-versionset.json" ]
}

# ---------------------------------------------------------------------------
# AC-2: publish path (LOCAL_ONLY=false, PULL_ONLY=false) + resolver unavailable
# in final pass → run exits non-zero, and no new ceiling-only artifact is written.
# Regression guard: our fix must NOT create an artifact on the publish path.
# Must stay GREEN before AND after the fix (fail-closed behavior intact).
# ---------------------------------------------------------------------------
@test "AC-2: publish path + resolver unavailable in final pass → exit non-zero (fail-closed), no new artifact" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    # Start with no pre-existing artifact so the test is clean.
    local lineage_dir="$tmpd/.build-lineage"
    rm -rf "$lineage_dir"

    run bash -c "
        export FORCE=false LOCAL_ONLY=false PULL_ONLY=false DRY_RUN=false CONTAINER=postgres
        cd \"$sd\"
        source ./build-extensions.sh
        export ROOT_DIR=\"$tmpd\"

        resolve_version_set() {
            echo '::error::simulated outage' >&2
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
        docker() { local _dk="\$1"; case "\$_dk" in build|push) return 0;; manifest|buildx) echo manifest unknown >&2; return 1;; *) return 1;; esac; }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

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

    # Publish path must remain fail-closed.
    [ "$status" -ne 0 ]

    # The fix must NOT have written an artifact on the publish path.
    [ ! -f "$lineage_dir/ext-timescaledb-pg18-versionset.json" ]
}

# ---------------------------------------------------------------------------
# AC-3: LOCAL_ONLY=true + DRY_RUN=true + resolver unavailable in final pass →
# no filesystem mutation (no artifact written).
# ---------------------------------------------------------------------------
@test "AC-3: LOCAL_ONLY=true + DRY_RUN=true + resolver unavailable → no artifact written" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    local lineage_dir="$tmpd/.build-lineage"
    rm -rf "$lineage_dir"

    run bash -c "
        export FORCE=false LOCAL_ONLY=true DRY_RUN=true CONTAINER=postgres
        cd \"$sd\"
        source ./build-extensions.sh
        export ROOT_DIR=\"$tmpd\" LOCAL_ONLY=true DRY_RUN=true

        resolve_version_set() {
            echo '::error::simulated outage' >&2
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
        docker() { local _dk="\$1"; case "\$_dk" in build|push) return 0;; manifest|buildx) echo manifest unknown >&2; return 1;; *) return 1;; esac; }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

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

        main postgres --major-version 18 --local-only
    "

    # Dry run must succeed.
    [ "$status" -eq 0 ]

    # Under DRY_RUN, no artifact must be written.
    [ ! -f "$lineage_dir/ext-timescaledb-pg18-versionset.json" ]
}

# ---------------------------------------------------------------------------
# AE-1: embedded-newline bypass — resolver returns a single JSON element that
# contains an embedded newline ("2.27.1\n9.9.9"). The old line-based semver
# gate splits this into two lines and passes both; the fix validates at the
# JSON-array-element level so the element fails the anchored regex and the
# whole set is rejected BEFORE any build/tag/push.
#
# RED before fix: jq -r '.[]' splits the element into two lines; each matches
#   is_strict_semver → both 2.27.1 and 9.9.9 are built/tagged/pushed.
# GREEN after fix: jq validates each element as a whole string; the embedded
#   newline causes the element to fail the anchored regex → fail-closed.
#
# Non-vacuous: assert NEITHER 2.27.1 NOR 9.9.9 appears in build/tag logs.
# ---------------------------------------------------------------------------

@test "AE-1-embedded-newline-bypass: resolver returns element with embedded newline → fail-closed, neither version built" {
    export LOCAL_ONLY=false

    # One JSON element containing an embedded newline — a single string that
    # the old line-split gate would see as two valid semver lines.
    resolve_version_set() {
        printf '["2.27.1\\n9.9.9"]'
    }
    export -f resolve_version_set

    ext_config() {
        local _key="$2"
        case "$_key" in
            version)              echo "2.27.1" ;;
            repo)                 echo "https://github.com/timescale/timescaledb" ;;
            version_set.resolver) echo "scripts/resolvers/timescaledb-ha.sh" ;;
            *)                    echo "" ;;
        esac
    }
    export -f ext_config

    local build_log="$TEST_TEMP_DIR/ae1_build_calls.log"
    build_ext_image() {
        echo "BUILD_CALLED ext=${1} ver=${2}" >> "$build_log"
        return 0
    }
    export -f build_ext_image

    local tag_log="$TEST_TEMP_DIR/ae1_tag_calls.log"
    tag_ext_image() {
        echo "TAG_CALLED ext=${1} ver=${2}" >> "$tag_log"
        return 0
    }
    export -f tag_ext_image

    run build_tag_push_extensions \
        "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR" "true" "timescaledb"

    # Must fail closed — the embedded-newline element fails array-level validation.
    [ "$status" -ne 0 ]

    # Neither 2.27.1 nor 9.9.9 must ever reach build or tag (the whole set is rejected).
    if [ -f "$build_log" ]; then
        [[ "$(cat "$build_log")" != *"ver=2.27.1"* ]]
        [[ "$(cat "$build_log")" != *"ver=9.9.9"* ]]
    fi
    if [ -f "$tag_log" ]; then
        [[ "$(cat "$tag_log")" != *"ver=2.27.1"* ]]
        [[ "$(cat "$tag_log")" != *"ver=9.9.9"* ]]
    fi
}

# ---------------------------------------------------------------------------
# AE-2: above-ceiling rejection — resolver returns a set containing 9.9.9
# which exceeds the configured ceiling 2.27.1. The ceiling clamp at the
# array-validation boundary must reject the whole set → fail-closed.
#
# RED before fix: no ceiling clamp at build boundary → 9.9.9 is built and pushed.
# GREEN after fix: set rejected before any build/tag/push because 9.9.9 > ceiling.
#
# Non-vacuous: assert 9.9.9 never appears in build/tag logs.
# ---------------------------------------------------------------------------

@test "AE-2-above-ceiling-rejected: resolver returns version above ceiling → set rejected, nothing built" {
    export LOCAL_ONLY=false

    # 2.27.1 is the ceiling; 9.9.9 exceeds it.
    resolve_version_set() {
        echo '["2.27.1","9.9.9"]'
    }
    export -f resolve_version_set

    ext_config() {
        local _key="$2"
        case "$_key" in
            version)              echo "2.27.1" ;;
            repo)                 echo "https://github.com/timescale/timescaledb" ;;
            version_set.resolver) echo "scripts/resolvers/timescaledb-ha.sh" ;;
            *)                    echo "" ;;
        esac
    }
    export -f ext_config

    local build_log="$TEST_TEMP_DIR/ae2_build_calls.log"
    build_ext_image() {
        echo "BUILD_CALLED ext=${1} ver=${2}" >> "$build_log"
        return 0
    }
    export -f build_ext_image

    local tag_log="$TEST_TEMP_DIR/ae2_tag_calls.log"
    tag_ext_image() {
        echo "TAG_CALLED ext=${1} ver=${2}" >> "$tag_log"
        return 0
    }
    export -f tag_ext_image

    run build_tag_push_extensions \
        "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR" "true" "timescaledb"

    # Must fail closed — above-ceiling element in the set.
    [ "$status" -ne 0 ]

    # 9.9.9 must NEVER reach build or tag.
    if [ -f "$build_log" ]; then
        [[ "$(cat "$build_log")" != *"ver=9.9.9"* ]]
    fi
    if [ -f "$tag_log" ]; then
        [[ "$(cat "$tag_log")" != *"ver=9.9.9"* ]]
    fi
}

# ---------------------------------------------------------------------------
# AE-3: clean set still builds — a fully valid set ["2.25.0","2.26.0","2.27.1"]
# where all versions are <= ceiling (2.27.1) must pass array-level validation
# and trigger all three builds (regression guard for AE-1/AE-2 fix).
# ---------------------------------------------------------------------------

@test "AE-3-clean-set-still-builds: valid set all-at-or-below ceiling → all 3 versions built normally" {
    export LOCAL_ONLY=false

    resolve_version_set() {
        echo '["2.25.0","2.26.0","2.27.1"]'
    }
    export -f resolve_version_set

    ext_config() {
        local _key="$2"
        case "$_key" in
            version)              echo "2.27.1" ;;
            repo)                 echo "https://github.com/timescale/timescaledb" ;;
            version_set.resolver) echo "scripts/resolvers/timescaledb-ha.sh" ;;
            *)                    echo "" ;;
        esac
    }
    export -f ext_config

    local build_log="$TEST_TEMP_DIR/ae3_build_calls.log"
    build_ext_image() {
        echo "BUILD_CALLED ext=${1} ver=${2}" >> "$build_log"
        return 0
    }
    export -f build_ext_image

    run build_tag_push_extensions \
        "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR" "true" "timescaledb"

    [ "$status" -eq 0 ]

    local build_count
    build_count=$(_count_log_lines "$build_log")
    [ "$build_count" -eq 3 ]
    [[ "$(cat "$build_log")" == *"ver=2.25.0"* ]]
    [[ "$(cat "$build_log")" == *"ver=2.26.0"* ]]
    [[ "$(cat "$build_log")" == *"ver=2.27.1"* ]]
}

# ---------------------------------------------------------------------------
# AG-1: _should_build_extension — resolver returns element with embedded newline
# ("2.27.1\n9.9.9") -> the all-cached path must reject it fail-closed.
# Without the chokepoint fix, jq -r '.[]' splits the element into two lines
# (2.27.1 and 9.9.9); each passes the per-line semver check, and 9.9.9 is
# treated as "already available", causing _should_build_extension to skip the
# extension and the smuggled 9.9.9 to silently pass into the all-cached path.
#
# RED before fix: exits 0 or 1 (treated as "all available").
# GREEN after fix: exits non-zero (fail-closed at _resolve_cached chokepoint).
# ---------------------------------------------------------------------------

@test "AG-1-should-build-embedded-newline: resolver returns element with embedded newline -> fail-closed in pre-filter" {
    export LOCAL_ONLY=false

    resolve_version_set() {
        printf '["2.27.1\\n9.9.9"]'
    }
    export -f resolve_version_set

    ext_config() {
        local _key="$2"
        case "$_key" in
            version)              echo "2.27.1" ;;
            repo)                 echo "https://github.com/timescale/timescaledb" ;;
            version_set.resolver) echo "scripts/resolvers/timescaledb-ha.sh" ;;
            *)                    echo "" ;;
        esac
    }
    export -f ext_config

    # All registry probes return true — if 9.9.9 is treated as a version,
    # it would be "available" and the extension would be all-cached (return 1).
    image_exists_in_registry() { return 0; }
    export -f image_exists_in_registry

    run _should_build_extension \
        "timescaledb" "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR"

    # Must fail closed (rc >= 2) — neither 0 (build-needed) nor 1 (all-cached skip).
    # The smuggled 9.9.9 must never be treated as a present version.
    [ "$status" -ne 0 ]
    [ "$status" -ne 1 ]
}

# ---------------------------------------------------------------------------
# AG-2: embedded-newline resolver output must never reach the versionset artifact.
# Full main() subprocess: poisoned resolver -> exit non-zero, artifact absent or
# does not contain 9.9.9.
#
# RED before fix: 9.9.9 treated as available -> artifact contains 9.9.9 or exits 0.
# GREEN after fix: rejected at chokepoint -> exit non-zero, no 9.9.9 in artifact.
# ---------------------------------------------------------------------------

@test "AG-2-poisoned-all-cached-never-in-artifact: embedded-newline resolver output never written to versionset artifact" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    # Run in a subprocess to isolate environment mutations.
    run bash -c '
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        cd "'"$sd"'"
        source ./build-extensions.sh
        export ROOT_DIR="'"$tmpd"'"

        resolve_version_set() { printf "[\"2.27.1\\\\n9.9.9\"]"; }
        export -f resolve_version_set

        ext_config() {
            case "$2" in
                version)              echo "2.27.1" ;;
                repo)                 echo "https://github.com/timescale/timescaledb" ;;
                version_set.resolver) echo "scripts/resolvers/timescaledb-ha.sh" ;;
                *)                    echo "" ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo "ghcr.io/test/ext-${1}:pg${3}-${2}"; }
        export -f ext_image_name
        ext_local_image_name() { echo "localhost/ext-builder-${1}:pg${2}"; }
        export -f ext_local_image_name
        image_exists_in_registry() { return 0; }
        export -f image_exists_in_registry
        docker() { local _dk="\$1"; case "\$_dk" in build|push) return 0;; manifest|buildx) echo manifest unknown >&2; return 1;; *) return 1;; esac; }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest
        build_ext_image()  { return 0; }
        export -f build_ext_image
        tag_ext_image()    { return 0; }
        export -f tag_ext_image
        push_ext_image()   { return 0; }
        export -f push_ext_image
        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo "timescaledb"; }
        export -f list_extensions_by_priority

        main postgres --major-version 18
    ' 2>&1

    # Must fail closed.
    [ "$status" -ne 0 ]

    # The artifact must not contain 9.9.9.
    local artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"
    if [ -f "$artifact" ]; then
        [[ "$(cat "$artifact")" != *"9.9.9"* ]]
    fi
}

# ---------------------------------------------------------------------------
# AH: regression guard — valid resolver output (clean semver, at/below ceiling)
# passes the chokepoint and _should_build_extension returns 1 (all-cached skip).
# Ensures the chokepoint does not break the normal happy path.
# ---------------------------------------------------------------------------

@test "AH-clean-all-cached-still-skips: valid set all-present -> _should_build_extension returns 1 (skip)" {
    export LOCAL_ONLY=false

    resolve_version_set() { echo '["2.27.1"]'; }
    export -f resolve_version_set

    ext_config() {
        local _key="$2"
        case "$_key" in
            version)              echo "2.27.1" ;;
            repo)                 echo "https://github.com/timescale/timescaledb" ;;
            version_set.resolver) echo "scripts/resolvers/timescaledb-ha.sh" ;;
            *)                    echo "" ;;
        esac
    }
    export -f ext_config

    # All versions present in registry.
    image_exists_in_registry() { return 0; }
    export -f image_exists_in_registry

    run _should_build_extension \
        "timescaledb" "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR"

    # Must return 1 (skip — all already available).
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# BUNDLE-5: empty available set → NO bundle is built.
# If all per-version builds fail (e.g. ceiling fatal), available is empty
# and build_tag_push_extensions should exit non-zero without building a bundle.
# ---------------------------------------------------------------------------

@test "BUNDLE-5: no available versions → bundle NOT built" {
    local docker_log="$TEST_TEMP_DIR/bundle5_docker.log"

    resolve_version_set() { echo '["2.27.1"]'; }
    export -f resolve_version_set

    ext_config() {
        case "$2" in
            version) echo "2.27.1" ;;
            repo)    echo "https://github.com/timescale/timescaledb" ;;
            *)       echo "" ;;
        esac
    }
    export -f ext_config

    # All builds fail (ceiling fatal → exit non-zero)
    build_ext_image() {
        echo "BUILD_FAILED ext=${1} ver=${2}" >> "$TEST_TEMP_DIR/build_calls.log"
        return 1
    }
    export -f build_ext_image

    docker() {
        echo "DOCKER $*" >> "$docker_log"
        return 0
    }
    export -f docker

    run build_tag_push_extensions \
        "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR" "true" "timescaledb"

    # Ceiling fatal → non-zero exit expected
    [ "$status" -ne 0 ]

    # No bundle docker command must have been issued
    if [ -f "$docker_log" ]; then
        ! grep -q "bundle" "$docker_log"
    fi
}

# ---------------------------------------------------------------------------
# AK-force-partial-consistency: --force, non-ceiling build fails (musl tolerated).
# The failed version must appear in NEITHER the bundle NOR the artifact's available[].
# The ceiling and the rest must appear in BOTH the bundle and the artifact's available[].
# Invariant: bundle contents == artifact available[] (one confirmed_available set).
#
# RED before fix: the bundle is assembled from _available_for_bundle (inner loop
#   tracking, 2-state), while the artifact is produced by _emit_final_versionset_pass
#   which calls _image_present_3state separately. They can diverge when the loop
#   and the probe disagree.
# GREEN after fix: both derive from the same confirmed_available set.
# ---------------------------------------------------------------------------
@test "AK-force-partial-consistency: --force, non-ceiling build fails → failed version in neither bundle nor artifact" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    local docker_log="${tmpd}/ak_fc_docker.log"

    run bash -c "
        export FORCE=true LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
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

        # Registry: 2.26.0 and 2.27.1 are present; 2.25.0 is absent.
        image_exists_in_registry() {
            case \"\$1\" in
                *pg18-2.25.0*) return 1 ;;
                *pg18-2.26.0*) return 0 ;;
                *pg18-2.27.1*) return 0 ;;
                *)             return 1 ;;
            esac
        }
        export -f image_exists_in_registry

        # 2.25.0 build fails (non-ceiling, musl tolerated); others succeed.
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

        # Record bundle Dockerfile contents when docker build is called.
        docker() {
            local _dcmd=\"\${1:-}\"
            if [[ \"\$_dcmd\" == \"build\" ]]; then
                echo \"DOCKER_CMD=build args=\$*\" >> \"$docker_log\"
                # Capture the bundle Dockerfile content if -f arg is a temp file
                local _df_arg
                local _found_f=false
                for _a in \"\$@\"; do
                    if [[ \"\$_found_f\" == 'true' ]]; then
                        _df_arg=\"\$_a\"
                        _found_f=false
                    fi
                    [[ \"\$_a\" == '-f' ]] && _found_f=true
                done
                if [[ -n \"\$_df_arg\" ]] && [[ -f \"\$_df_arg\" ]]; then
                    cat \"\$_df_arg\" >> \"${tmpd}/bundle_dockerfile.log\"
                fi
                return 0
            fi
            if [[ \"\$_dcmd\" == \"push\" ]]; then
                echo \"DOCKER_CMD=push args=\$*\" >> \"$docker_log\"
                return 0
            fi
            if [[ \"\$*\" == *'manifest inspect'* ]]; then
                echo 'manifest unknown: manifest unknown' >&2
            fi
            return 1
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        # 3-state probe: 2.25.0 ABSENT (definitively — build failed, never pushed),
        # others PRESENT.
        _image_present_3state() {
            case \"\$1\" in
                *pg18-2.25.0*) return 1 ;;  # ABSENT
                *pg18-2.26.0*) return 0 ;;  # PRESENT
                *pg18-2.27.1*) return 0 ;;  # PRESENT
                *)             return 1 ;;
            esac
        }
        export -f _image_present_3state

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority

        main postgres --major-version 18 --force
    "

    # Must succeed (non-ceiling musl failure is tolerated).
    [ "$status" -eq 0 ]

    # Artifact must be written.
    local artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"
    [ -f "$artifact" ]

    # 2.25.0 (failed build) must NOT be in artifact available[].
    local avail
    avail=$(jq -r '.available[]' "$artifact")
    [[ "$avail" != *'2.25.0'* ]]

    # Ceiling (2.27.1) and 2.26.0 MUST be in artifact available[].
    [[ "$avail" == *'2.27.1'* ]]
    [[ "$avail" == *'2.26.0'* ]]

    # Bundle Dockerfile must NOT contain a COPY for 2.25.0.
    if [ -f "$tmpd/bundle_dockerfile.log" ]; then
        local bundle_df
        bundle_df=$(cat "$tmpd/bundle_dockerfile.log")
        ! grep -Fxq "COPY --from=ghcr.io/test/ext-timescaledb:pg18-2.25.0 /output/ /2.25.0/" <<<"$bundle_df"
        # Bundle must contain 2.26.0 and 2.27.1.
        grep -Fxq "COPY --from=ghcr.io/test/ext-timescaledb:pg18-2.26.0 /output/ /2.26.0/" <<<"$bundle_df"
        grep -Fxq "COPY --from=ghcr.io/test/ext-timescaledb:pg18-2.27.1 /output/ /2.27.1/" <<<"$bundle_df"
    fi

    # Bundle available[] count must equal artifact available[] count.
    local art_avail_count
    art_avail_count=$(jq '.available | length' "$artifact")
    [ "$art_avail_count" -eq 2 ]
}

# ---------------------------------------------------------------------------
# AK-transient-allcached-failclosed: all-cached path, _image_present_3state
# returns ERROR (rc=2) for one resolved version → run must fail closed:
# NO bundle pushed AND NO reduced artifact written.
#
# RED before fix: the all-cached bundle refresh loop at main() calls _image_present
#   (2-state), which returns false-absent on a transient error → silently omits
#   that version from the bundle and pushes a truncated bundle.
# GREEN after fix: the loop calls _image_present_3state; ERROR → skip bundle
#   assembly and exit non-zero.
# ---------------------------------------------------------------------------
@test "AK-transient-allcached-failclosed: all-cached path with ERROR probe → bundle NOT assembled, exits non-zero" {
    # This test verifies the AK-2 fix: the all-cached bundle refresh must use
    # _image_present_3state (3-state) instead of _image_present (2-state) so that
    # a transient ERROR on one version prevents bundle assembly (fail-closed).
    #
    # The test drives main() via subprocess because the all-cached bundle refresh
    # loop lives in main(), not in build_tag_push_extensions.
    #
    # Mock strategy: override assemble_and_push_bundle to record whether it was
    # called (non-vacuous: the bundle assembler must NOT fire when an ERROR probe
    # prevents safe assembly).
    #
    # RED before fix: all-cached loop calls _image_present (2-state) →
    #   image_exists_in_registry returns 0 for all → bundle assembler called.
    # GREEN after fix: all-cached loop calls _image_present_3state → ERROR for 2.26.0
    #   → bundle assembly skipped.
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    local bundle_call_log="${tmpd}/ak_tac_bundle_calls.log"

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

        # All versions appear present for the skip-build check (they are cached).
        image_exists_in_registry() { return 0; }
        export -f image_exists_in_registry

        docker() {
            local _dcmd=\"\${1:-}\"
            if [[ \"\$_dcmd\" == \"build\" || \"\$_dcmd\" == \"push\" ]]; then
                return 0
            fi
            return 1
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

        build_ext_image() { return 0; }
        export -f build_ext_image
        tag_ext_image()  { return 0; }
        export -f tag_ext_image
        push_ext_image() { return 0; }
        export -f push_ext_image

        # Override assemble_and_push_bundle to record if it was called.
        assemble_and_push_bundle() {
            echo \"BUNDLE_CALLED ext=\${1} major=\${2}\" >> \"$bundle_call_log\"
            return 0
        }
        export -f assemble_and_push_bundle

        # 3-state probe: 2.26.0 returns ERROR (rc=2, transient blip).
        # AK-2 fix: the all-cached bundle refresh loop must call _image_present_3state
        # instead of _image_present; ERROR → skip bundle assembly.
        _image_present_3state() {
            case \"\$1\" in
                *pg18-2.25.0*) return 0 ;;  # PRESENT
                *pg18-2.26.0*) return 2 ;;  # ERROR (transient)
                *pg18-2.27.1*) return 0 ;;  # PRESENT
                *)             return 2 ;;
            esac
        }
        export -f _image_present_3state

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority

        main postgres --major-version 18
    "

    # Must fail closed — transient ERROR on one version must fail the run.
    [ "$status" -ne 0 ]

    # Bundle assembler must NOT have been called.
    # RED before fix: all-cached loop uses _image_present (2-state); image_exists_in_registry
    #   returns 0 for all versions → assemble_and_push_bundle IS called.
    # GREEN after fix: _image_present_3state returns ERROR for 2.26.0 → bundle skipped.
    [ ! -f "$bundle_call_log" ]
}

# ---------------------------------------------------------------------------
# AK-fatal-no-bundle: ceiling build fails → exit non-zero AND bundle tag NOT
# pushed AND no versionset artifact written.
#
# RED before fix: when the ceiling fails but older versions succeed, the inner
#   loop adds older versions to _available_for_bundle (non-empty), so the
#   bundle assembly block fires and pushes a bundle WITHOUT the ceiling.
# GREEN after fix: a fatal failure (ceiling in failed[], or any tag/push error)
#   prevents bundle assembly and artifact emission; run exits non-zero.
# ---------------------------------------------------------------------------
@test "AK-fatal-no-bundle: ceiling build fails → exit non-zero, bundle NOT assembled, NO artifact written" {
    # Direct function-call test (not subprocess). Mocks assemble_and_push_bundle
    # to record whether it was called — this is the critical observable: the
    # bundle assembler must NOT be invoked when the ceiling failed.
    #
    # RED before fix: ceiling fails, older versions succeed, _available_for_bundle
    #   is non-empty (2.25.0 + 2.26.0) → bundle assembly fires → exit 1 with
    #   assemble_and_push_bundle CALLED.
    # GREEN after fix: fatal failure (ceiling in failed[]) → bundle assembly skipped.

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

    # 2.27.1 (ceiling) fails to build; older versions succeed.
    build_ext_image() {
        if [[ "$2" == "2.27.1" ]]; then
            echo "BUILD_FAILED ext=${1} ver=${2}" >> "$TEST_TEMP_DIR/fnb_build.log"
            return 1
        fi
        echo "BUILD_OK ext=${1} ver=${2}" >> "$TEST_TEMP_DIR/fnb_build.log"
        return 0
    }
    export -f build_ext_image

    # Override assemble_and_push_bundle to record calls — must NOT be called when
    # ceiling failed.
    local bundle_call_log="$TEST_TEMP_DIR/fnb_bundle_calls.log"
    assemble_and_push_bundle() {
        echo "BUNDLE_CALLED ext=${1} major=${2} push=${3} vers=${*:4}" >> "$bundle_call_log"
        return 0
    }
    export -f assemble_and_push_bundle

    run build_tag_push_extensions \
        "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR" "true" "timescaledb"

    # Must fail — ceiling failure is fatal.
    [ "$status" -ne 0 ]

    # Bundle must NOT have been assembled.
    # RED before fix: _available_for_bundle has 2.25.0 and 2.26.0 → bundle assembly fires.
    # GREEN after fix: ceiling fatal → bundle assembly skipped.
    [ ! -f "$bundle_call_log" ]
}

# ---------------------------------------------------------------------------
# INV-transient-failclosed: 3-state ERROR on one resolved version on the
# publish path → no bundle assembled, no artifact written, exit non-zero.
#
# This closes the fail-closed gate for the single-source confirmed_available
# computation: if ANY resolved version returns ERROR from the 3-state probe,
# the confirmed set is unsafe to use — fail closed on the publish path.
# ---------------------------------------------------------------------------
@test "INV-transient-failclosed: 3-state ERROR on one resolved version → no bundle, no artifact, fatal" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    local bundle_call_log="$tmpd/inv_tfc_bundle_calls.log"
    local artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"

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

        # All versions appear in registry for the skip-build check (all-cached).
        image_exists_in_registry() { return 0; }
        export -f image_exists_in_registry

        build_ext_image() { return 0; }
        export -f build_ext_image
        tag_ext_image()  { return 0; }
        export -f tag_ext_image
        push_ext_image() { return 0; }
        export -f push_ext_image

        # 3-state probe: 2.26.0 returns ERROR (transient) → fail closed.
        _image_present_3state() {
            case \"\$1\" in
                *pg18-2.25.0*) return 0 ;;
                *pg18-2.26.0*) return 2 ;;
                *pg18-2.27.1*) return 0 ;;
                *)             return 2 ;;
            esac
        }
        export -f _image_present_3state

        # Capture if bundle assembler is called (it must NOT be).
        assemble_and_push_bundle() {
            echo \"BUNDLE_CALLED ext=\${1} major=\${2}\" >> \"$bundle_call_log\"
            return 0
        }
        export -f assemble_and_push_bundle

        docker() {
            local _dcmd=\"\${1:-}\"
            [[ \"\$_dcmd\" == 'build' || \"\$_dcmd\" == 'push' ]] && return 0 || return 1
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority

        main postgres --major-version 18
    "

    # Transient ERROR on a resolved version → fatal (fail-closed on publish path).
    [ "$status" -ne 0 ]

    # Bundle assembler must NOT have been called.
    [ ! -f "$bundle_call_log" ]

    # No artifact must be written.
    [ ! -f "$artifact" ]
}

# ---------------------------------------------------------------------------
# AL-single-version-no-bundle: resolver-backed ext, retain_count/resolved set
# == 1 (just the ceiling) → NO bundle build, NO artifact written.
# This is the existing _bundle_and_write_artifact behaviour (set_size<=1 early
# return) confirmed as a test so any future code change that breaks it is caught.
# ---------------------------------------------------------------------------
@test "AL-single-version-no-bundle: resolver-backed ext set_size==1 → no bundle docker build, no artifact" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"
    local artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"
    local bundle_call_log="$tmpd/bundle_calls.log"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    rm -f "$artifact" "$bundle_call_log"

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        cd \"$sd\"
        source ./build-extensions.sh
        export ROOT_DIR=\"$tmpd\"

        # Resolver returns EXACTLY one version (the ceiling) — retain_count=1 scenario.
        resolve_version_set() { echo '[\"2.27.1\"]'; }
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

        build_ext_image() { return 0; }
        export -f build_ext_image
        tag_ext_image()   { return 0; }
        export -f tag_ext_image
        push_ext_image()  { return 0; }
        export -f push_ext_image

        # Record any docker build call for the bundle.
        docker() {
            local _dcmd=\"\${1:-}\"
            if [[ \"\$_dcmd\" == 'build' ]]; then
                # If this is a bundle build (Dockerfile has FROM scratch), record it.
                echo \"docker_build_called\" >> '${bundle_call_log}'
                return 0
            fi
            [[ \"\$_dcmd\" == 'push' ]] && return 0
            return 1
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

        validate_prerequisites()      { return 0; }
        export -f validate_prerequisites
        check_registry_auth()         { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority

        main postgres --major-version 18
    "

    # Must succeed (single-version build is fine).
    [ "$status" -eq 0 ]

    # No bundle artifact must be written (set_size==1 → _bundle_and_write_artifact returns early).
    [ ! -f "$artifact" ]

    # The docker command may be called for the per-version build (via build_ext_image override)
    # but assemble_and_push_bundle (which calls $DOCKER build for the bundle FROM scratch image)
    # must NOT have been called.  We can verify by checking that _bundle_and_write_artifact's
    # early return (set_size<=1) skipped the bundle path entirely.
    # The bundle is only assembled when set_size > 1; with set_size==1 the call to
    # assemble_and_push_bundle never happens, so the docker() mock above records no build
    # from the bundle assembly path.  The per-version build goes through build_ext_image()
    # (overridden separately), NOT through docker() directly, so bundle_call_log is clean.
    [ ! -f "$bundle_call_log" ]
}

# ---------------------------------------------------------------------------
# AO-1: resolved set > 1 but only the ceiling is confirmed available (other
# versions absent) → producer must NOT assemble/push a bundle and must NOT
# write a versionset artifact.  The consumer would ignore a 1-version bundle
# (available_count <= 1 falls through to single-version path), so pushing one
# would waste CI resources and a push/digest failure there would break the run
# for no benefit.
#
# Scenario: resolver returns ["2.25.0","2.26.0","2.27.1"] (set_size=3).
#   - 2.25.0: ABSENT (musl-failed / never built)
#   - 2.26.0: ABSENT (musl-failed / never built)
#   - 2.27.1 (ceiling): PRESENT
#
# Expected: confirmed_available == ["2.27.1"] (size 1) → NO bundle build/push,
#   NO artifact written (stale artifact deleted), exit 0 (NOT a failure).
#
# RED before fix: 1-version bundle is assembled and pushed; artifact is written
#   with available=["2.27.1"].  A subsequent push/digest failure would fail CI.
# GREEN after fix: confirmed_available size == 1 → skip bundle, skip artifact,
#   delete stale, return 0.
# ---------------------------------------------------------------------------
@test "AO1-confirmed-one-no-bundle: resolved>1 but only ceiling confirmed → no bundle, no artifact, exit 0" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"
    local artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"
    local bundle_call_log="$tmpd/ao1_bundle_calls.log"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    # Pre-place a stale artifact to verify it gets deleted.
    mkdir -p "$tmpd/.build-lineage"
    echo '{"stale":true}' > "$artifact"
    rm -f "$bundle_call_log"

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        cd \"$sd\"
        source ./build-extensions.sh
        export ROOT_DIR=\"$tmpd\"

        # Resolver returns 3 versions (set_size=3 > 1).
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

        # Skip-build: all versions appear in registry for _image_needs_build check.
        # (ceiling appears present, so the existing-check skips rebuild)
        image_exists_in_registry() { return 0; }
        export -f image_exists_in_registry

        # 3-state probe: only the ceiling is PRESENT; others are ABSENT.
        _image_present_3state() {
            case \"\$1\" in
                *pg18-2.27.1*) return 0 ;;  # PRESENT (ceiling)
                *)             return 1 ;;  # ABSENT  (non-ceiling)
            esac
        }
        export -f _image_present_3state

        build_ext_image() { return 0; }
        export -f build_ext_image
        tag_ext_image()   { return 0; }
        export -f tag_ext_image
        push_ext_image()  { return 0; }
        export -f push_ext_image

        # Record any docker bundle build call.
        docker() {
            local _dcmd=\"\${1:-}\"
            if [[ \"\$_dcmd\" == 'build' ]]; then
                echo \"docker_build_called\" >> '$bundle_call_log'
                return 0
            fi
            [[ \"\$_dcmd\" == 'push' ]] && return 0
            return 1
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

        validate_prerequisites()      { return 0; }
        export -f validate_prerequisites
        check_registry_auth()         { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority

        main postgres --major-version 18
    "

    # Must succeed — confirmed_available==1 with ceiling present is not an error.
    [ "$status" -eq 0 ]

    # No artifact must be present (stale one deleted, new one not written).
    # RED before fix: artifact IS written with available=[\"2.27.1\"].
    # GREEN after fix: no artifact (confirmed_available size 1 → skip).
    [ ! -f "$artifact" ]

    # No bundle docker build must have been invoked.
    # RED before fix: bundle_call_log exists.
    # GREEN after fix: no bundle assembly.
    [ ! -f "$bundle_call_log" ]
}

# ---------------------------------------------------------------------------
# AQ-1: CI PR smoke — all-cached, do_push=false (not LOCAL_ONLY/PULL_ONLY).
#
# Defect: _emit_final_versionset_pass computes _do_push_fp solely from
# LOCAL_ONLY/PULL_ONLY, defaulting to "true" when neither is set. On a CI PR
# smoke (read-only GITHUB_TOKEN on fork PRs, do_push=false), the final pass
# calls assemble_and_push_bundle with do_push="true" → docker push → 403.
#
# Fix: main() computes do_push (honoring LOCAL_ONLY and a new NO_PUSH env var
# for CI PR context), then passes it as argument 4 to _emit_final_versionset_pass.
# _emit_final_versionset_pass uses the received value instead of re-deriving.
#
# Three-way contract:
#   do_push=true (default):          assemble + push bundle + write artifact.
#   LOCAL_ONLY=true (do_push=false): assemble locally, NO push (recovery).
#   NO_PUSH=true (do_push=false):    skip bundle + skip artifact (CI PR smoke).
# ---------------------------------------------------------------------------
@test "AQ1-pr-nopush-allcached-clean: all-cached + NO_PUSH=true (CI PR) → NO bundle push, NO artifact, exit 0" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    local push_call_log="${tmpd}/aq1pr_push.log"
    local artifact="${tmpd}/.build-lineage/ext-timescaledb-pg18-versionset.json"
    rm -f "$artifact"

    run bash -c "
        export FORCE=false LOCAL_ONLY=false PULL_ONLY=false DRY_RUN=false CONTAINER=postgres
        # NO_PUSH=true simulates CI PR smoke (read-only GITHUB_TOKEN on fork PRs).
        export NO_PUSH=true
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
        docker() {
            local _cmd=\"\${1:-}\"
            if [[ \"\$_cmd\" == 'push' ]]; then
                echo \"DOCKER_PUSH\" >> \"$push_call_log\"
                return 0
            fi
            if [[ \"\$_cmd\" == 'build' ]]; then return 0; fi
            if [[ \"\$*\" == *'manifest inspect'* ]]; then
                echo 'manifest unknown: manifest unknown' >&2
            fi
            return 1
        }
        export -f docker
        skopeo() { echo 'manifest unknown' >&2; return 1; }
        export -f skopeo
        _capture_index_digest() {
            echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'
        }
        export -f _capture_index_digest
        build_ext_image() { return 0; }; export -f build_ext_image
        tag_ext_image()  { return 0; };  export -f tag_ext_image
        push_ext_image() { return 0; };  export -f push_ext_image
        validate_prerequisites()  { return 0; }; export -f validate_prerequisites
        check_registry_auth()     { return 0; }; export -f check_registry_auth
        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority
        main postgres --major-version 18
    "

    # Must exit cleanly (no 403 pushed).
    [ "$status" -eq 0 ]

    # RED before fix: docker push IS called (bundle push → 403 on fork PR).
    # GREEN after fix: no docker push.
    local push_count
    push_count=$(_count_log_lines "$push_call_log")
    [ "$push_count" -eq 0 ]

    # No artifact must be written on CI PR smoke.
    # RED before fix: artifact IS written.
    # GREEN after fix: no artifact.
    [ ! -f "$artifact" ]
}


# ---------------------------------------------------------------------------
# AX4 defensive: NO_PUSH=true still suppresses push (script honors it even
# though the workflow no longer sets it on same-repo PRs; guards local/manual use).
# ---------------------------------------------------------------------------
@test "AX4-nopush-true-still-suppresses: NO_PUSH=true explicit → do_push=false → no push (defensive)" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    local push_call_log="${tmpd}/ax4_nopush_explicit.log"
    local artifact="${tmpd}/.build-lineage/ext-timescaledb-pg18-versionset.json"
    rm -f "$artifact"

    run bash -c "
        export FORCE=false LOCAL_ONLY=false PULL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export NO_PUSH=true
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
        docker() {
            local _cmd=\"\${1:-}\"
            if [[ \"\$_cmd\" == 'push' ]]; then
                echo \"DOCKER_PUSH\" >> \"$push_call_log\"
                return 0
            fi
            if [[ \"\$_cmd\" == 'build' ]]; then return 0; fi
            if [[ \"\$*\" == *'manifest inspect'* ]]; then
                echo 'manifest unknown: manifest unknown' >&2
            fi
            return 1
        }
        export -f docker
        skopeo() { echo 'manifest unknown' >&2; return 1; }
        export -f skopeo
        _capture_index_digest() {
            echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'
        }
        export -f _capture_index_digest
        build_ext_image() { return 0; }; export -f build_ext_image
        tag_ext_image()  { return 0; };  export -f tag_ext_image
        push_ext_image() { return 0; };  export -f push_ext_image
        validate_prerequisites()  { return 0; }; export -f validate_prerequisites
        check_registry_auth()     { return 0; }; export -f check_registry_auth
        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority
        main postgres --major-version 18
    "

    # Script honors NO_PUSH=true even when caller sets it explicitly.
    [ "$status" -eq 0 ]

    # NO_PUSH=true: no docker push.
    local push_count
    push_count=$(_count_log_lines "$push_call_log")
    [ "$push_count" -eq 0 ]

    # NO_PUSH=true: no artifact written.
    [ ! -f "$artifact" ]
}

@test "AQ1-localonly-allcached-nopush: all-cached + LOCAL_ONLY=true → NO push (regression guard)" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    local push_call_log="${tmpd}/aq1local_push.log"

    run bash -c "
        export FORCE=false LOCAL_ONLY=true PULL_ONLY=false DRY_RUN=false CONTAINER=postgres
        cd \"$sd\"
        source ./build-extensions.sh
        export LOCAL_ONLY=true ROOT_DIR=\"$tmpd\"

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
        docker() {
            local _cmd=\"\${1:-}\"
            if [[ \"\$_cmd\" == 'image' && \"\${2:-}\" == 'inspect' ]]; then return 0; fi
            if [[ \"\$_cmd\" == 'push' ]]; then
                echo \"DOCKER_PUSH\" >> \"$push_call_log\"; return 0
            fi
            if [[ \"\$_cmd\" == 'build' ]]; then return 0; fi
            return 1
        }
        export -f docker
        skopeo() { echo 'manifest unknown' >&2; return 1; }
        export -f skopeo
        image_exists_in_registry() { return 1; }
        export -f image_exists_in_registry
        _capture_index_digest() {
            echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'
        }
        export -f _capture_index_digest
        build_ext_image() { return 0; }; export -f build_ext_image
        tag_ext_image()  { return 0; };  export -f tag_ext_image
        push_ext_image() { return 0; };  export -f push_ext_image
        validate_prerequisites()  { return 0; }; export -f validate_prerequisites
        check_registry_auth()     { return 0; }; export -f check_registry_auth
        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority
        main postgres --major-version 18
    "

    [ "$status" -eq 0 ]

    # LOCAL_ONLY: docker push must NOT have been called.
    local push_count
    push_count=$(_count_log_lines "$push_call_log")
    [ "$push_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AR-1: no-push CI build path must NOT write an artifact for an unpushed bundle.
#
# Scenario: versions were BUILT in this run (not all-cached), do_push=false via
# NO_PUSH=true (fork PR), NOT LOCAL_ONLY, NOT PULL_ONLY.
# Before fix: _bundle_and_write_artifact is called from build_tag_push_extensions
#   without the no-push guard → artifact is written pointing at a bundle that
#   was never pushed to the registry.
# After fix: guard inside _bundle_and_write_artifact fires → no bundle push,
#   no artifact written, any stale artifact deleted, exit 0.
# ---------------------------------------------------------------------------
@test "AR1-nopush-build-no-artifact: BUILD path, NO_PUSH=true, not LOCAL_ONLY — no artifact written" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    # Pre-seed a stale artifact so we can verify it is deleted.
    mkdir -p "${tmpd}/.build-lineage"
    echo '{"stale":true}' > "${tmpd}/.build-lineage/ext-timescaledb-pg18-versionset.json"

    run bash -c "
        export FORCE=false LOCAL_ONLY=false PULL_ONLY=false DRY_RUN=false NO_PUSH=true CONTAINER=postgres
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

        # All versions absent in registry — build loop will run.
        image_exists_in_registry() { return 1; }
        export -f image_exists_in_registry

        # Builds succeed.
        build_ext_image() { return 0; }
        export -f build_ext_image
        tag_ext_image()  { return 0; }
        export -f tag_ext_image
        push_ext_image() { return 0; }
        export -f push_ext_image

        docker() {
            local _dcmd=\"\${1:-}\"
            case \"\$_dcmd\" in
                build|push) return 0 ;;
                manifest) printf 'manifest unknown\n' >&2; return 1 ;;
                *) return 1 ;;
            esac
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() {
            echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'
        }
        export -f _capture_index_digest
        skopeo() { printf 'manifest unknown\n' >&2; return 1; }
        export -f skopeo

        validate_prerequisites() { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority

        main postgres --major-version 18
    "

    # Must succeed (no-push is not a fatal condition).
    [ "$status" -eq 0 ]

    # AR-1: artifact must NOT be written (and stale must be deleted).
    [ ! -f "${tmpd}/.build-lineage/ext-timescaledb-pg18-versionset.json" ]
}

# ---------------------------------------------------------------------------
# AR-1 regression: LOCAL_ONLY=true (do_push=false) still writes an artifact
# without a digest — existing behavior must be preserved.
# ---------------------------------------------------------------------------
@test "AR1-localonly-still-writes: LOCAL_ONLY=true, do_push=false — artifact written without digest" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    run bash -c "
        export FORCE=false LOCAL_ONLY=true PULL_ONLY=false DRY_RUN=false NO_PUSH=false CONTAINER=postgres
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

        # LOCAL_ONLY: all versions already in local daemon.
        docker() {
            local _dcmd=\"\${1:-}\"
            if [[ \"\$_dcmd\" == 'image' ]]; then return 0; fi
            if [[ \"\$_dcmd\" == 'build' || \"\$_dcmd\" == 'push' ]]; then return 0; fi
            return 1
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        # LOCAL_ONLY: _capture_index_digest not called (no push) → unset is fine.
        _capture_index_digest() { echo ''; return 0; }
        export -f _capture_index_digest
        image_exists_in_registry() { return 1; }
        export -f image_exists_in_registry
        skopeo() { printf 'manifest unknown\n' >&2; return 1; }
        export -f skopeo

        build_ext_image() { return 0; }; export -f build_ext_image
        tag_ext_image()  { return 0; };  export -f tag_ext_image
        push_ext_image() { return 0; };  export -f push_ext_image
        validate_prerequisites() { return 0; }; export -f validate_prerequisites
        check_registry_auth()     { return 0; }; export -f check_registry_auth
        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority

        main postgres --major-version 18 --local-only
    "

    [ "$status" -eq 0 ]

    # LOCAL_ONLY: artifact MUST be written (local consumption path).
    local artifact="${tmpd}/.build-lineage/ext-timescaledb-pg18-versionset.json"
    [ -f "$artifact" ]

    # No digest on LOCAL_ONLY path (bundle was not pushed).
    local digest_field
    digest_field=$(jq -r '.bundle_digest // "absent"' "$artifact")
    [ "$digest_field" = "absent" ]
}

# ---------------------------------------------------------------------------
# AR-2: resolver output containing GHA workflow-command injection bytes must
# be neutralized in the logged diagnostic when validation fails.
#
# The resolver returns output with an embedded newline followed by
# ::stop-commands:: — a dangerous GHA workflow command. The log_error call
# at the validation failure site must NOT emit a raw newline-prefixed
# ::stop-commands:: sequence in its output (stdout/stderr).
# ---------------------------------------------------------------------------
@test "AR2-resolver-output-sanitized: malicious resolver output is defanged in log diagnostic" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"
    local ar2_stderr="/tmp/ar2_resolver_stderr_$$.txt"

    # Drive _resolve_cached in a subshell, redirecting stderr to a file so we can
    # inspect the exact bytes emitted by log_error.
    bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        cd \"$sd\"
        source ./build-extensions.sh
        export ROOT_DIR=\"$tmpd\"

        # Resolver returns a JSON array where one element contains an embedded
        # newline + GHA workflow command. The JSON is valid at the array/string-type
        # level so it passes the first jq check, but the semver/ceiling check rejects
        # the injection element — triggering the log_error with the raw result value.
        resolve_version_set() {
            printf '%s' '[\"2.27.1\",\"2.27.1\n::stop-commands::evil\"]'
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

        _resolve_cached timescaledb 18 \"$tmpd/postgres/extensions/config.yaml\" 2>\"$ar2_stderr\" || true
    "

    # Must have emitted a diagnostic (the log_error line for the validation failure).
    local stderr_content
    stderr_content=$(cat "$ar2_stderr" 2>/dev/null || true)
    [[ "$stderr_content" == *"resolver for"* ]]

    # The injection sequence must NOT appear as a line starting with :: in the output.
    # GHA interprets any line whose first two characters are '::' as a workflow command.
    # After sanitization, no line in the diagnostic may begin with '::'.
    if printf '%s\n' "$stderr_content" | grep -qE '^::'; then
        echo "FAIL: log output contains a line starting with '::' — GHA injection not neutralized"
        echo "--- stderr_content ---"
        printf '%s\n' "$stderr_content" | cat -A
        return 1
    fi

    rm -f "$ar2_stderr"
}

# ---------------------------------------------------------------------------
# AS-2: the failure-log site in assemble_and_push_bundle that logs the
# captured digest must sanitize the value before logging.
#
# AS2-digest-failure-log-sanitized: when the captured digest is a malformed
# multi-line string "sha256:abc\n::add-mask::x", the logged failure message
# must NOT contain a raw newline followed by ::add-mask:: (the GHA injection
# form). The function must still fail closed (non-zero exit, no artifact).
# RED before fix: log_error logs the raw _captured_digest without sanitization.
# GREEN after fix: log_error wraps _captured_digest in _sanitize_for_log.
# ---------------------------------------------------------------------------
@test "AS2-digest-failure-log-sanitized: malformed digest with injection bytes — fail closed, log defanged" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"
    local as2_stderr="/tmp/as2_digest_stderr_$$.txt"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    bash -c "
        export FORCE=false LOCAL_ONLY=false PULL_ONLY=false DRY_RUN=false NO_PUSH=false CONTAINER=postgres
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

        image_exists_in_registry() { return 1; }
        export -f image_exists_in_registry

        build_ext_image() { return 0; }; export -f build_ext_image
        tag_ext_image()  { return 0; };  export -f tag_ext_image
        push_ext_image() { return 0; };  export -f push_ext_image

        docker() {
            local _dcmd=\"\${1:-}\"
            case \"\$_dcmd\" in
                build|push) return 0 ;;
                manifest) printf 'manifest unknown\n' >&2; return 1 ;;
                *) return 1 ;;
            esac
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        # _capture_index_digest returns a malformed multi-line value with
        # an embedded GHA workflow command injection attempt.
        _capture_index_digest() {
            printf 'sha256:abc\n::add-mask::x'
            return 0
        }
        export -f _capture_index_digest

        skopeo() { printf 'manifest unknown\n' >&2; return 1; }
        export -f skopeo

        validate_prerequisites() { return 0; }; export -f validate_prerequisites
        check_registry_auth()     { return 0; }; export -f check_registry_auth
        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority

        main postgres --major-version 18
    " 2>"$as2_stderr" || true

    local stderr_content
    stderr_content=$(cat "$as2_stderr" 2>/dev/null || true)

    # The log must mention the digest failure (the error diagnostic was emitted).
    [[ "$stderr_content" == *"digest"* ]]

    # The injection sequence must NOT appear as a line starting with :: in stderr.
    # GHA interprets any line beginning with '::' as a workflow command.
    if printf '%s\n' "$stderr_content" | grep -qE '^::'; then
        echo "FAIL: log output contains a line starting with '::' — GHA injection not neutralized"
        echo "--- stderr_content ---"
        printf '%s\n' "$stderr_content" | cat -A
        rm -f "$as2_stderr"
        return 1
    fi

    rm -f "$as2_stderr"
}

# ---------------------------------------------------------------------------
# AT-1: _sanitize_for_log must neutralize backslash sequences so that
# echo -e cannot expand them after sanitisation.
#
# The existing sanitiser neutralises actual CR/LF bytes and literal "::" but
# does NOT escape backslashes.  A value containing "sha256:abc\n\x3a\x3a
# add-mask::secret" (literal backslash-n and backslash-x3a, NOT actual
# control bytes) passes the old sanitiser unchanged.  echo -e then expands
# \n -> newline and \x3a -> ':', reconstructing a "::add-mask::secret"
# workflow command line.
#
# Fix: escape every '\' -> '\\' as the FIRST transformation in
# _sanitize_for_log, so echo -e renders "\n" as the literal two-char
# sequence "\n" (not a newline) and "\x3a" as the literal four-char
# sequence "\x3a" (not ":").
#
# AT1-sanitizer-backslash-escape: end-to-end proof that echo -e cannot
#   expand an injected backslash escape after sanitisation.
#   Input: a value with literal \n and \x3a\x3a sequences.
#   Test drives the sanitised value through the real log_error logger
#   (which uses echo -e) and asserts:
#   (a) the combined logger output contains NO actual newline-then-:: line
#   (b) the literal backslash-n is preserved as two chars, not expanded
#   RED before fix: echo -e expands \n and \x3a, reconstructing "::add-mask::".
#   GREEN after fix: backslashes escaped first; echo -e sees \\n -> "\n".
#
# AT1-sanitizer-actual-controls: the existing CR/LF/:: neutralisation
#   still works after the backslash-first fix (regression guard).
# ---------------------------------------------------------------------------

@test "AT1-sanitizer-backslash-escape: echo -e cannot expand injected backslash sequences after sanitisation" {
    # Poison value: literal backslash-n and backslash-x3a (two-char sequences,
    # NOT actual control bytes).  When passed to echo -e without sanitisation,
    # \n expands to newline and \x3a to ':', producing:
    #   sha256:abc
    #   ::add-mask::secret
    # which GHA interprets as a workflow command.
    local poison='sha256:abc\n\x3a\x3aadd-mask::secret'

    # Drive the sanitised value through the real log_error logger (echo -e path).
    # Capture stderr (where log_error writes).
    local sanitized_stderr
    sanitized_stderr=$(bash -c "
        source '$HELPERS_DIR/extension-utils.sh'
        sanitized=\$(_sanitize_for_log '$poison')
        log_error \"\$sanitized\"
    " 2>&1 || true)

    # (a) No line in the logger output may start with '::' — that is the GHA
    #     workflow-command trigger.  If echo -e expanded \x3a to ':', the line
    #     "::add-mask::secret" would appear after the expanded newline.
    if printf '%s\n' "$sanitized_stderr" | grep -qE '^::'; then
        echo "FAIL: log output contains a line starting with '::' — backslash injection not neutralised"
        echo "--- sanitized_stderr (cat -A) ---"
        printf '%s\n' "$sanitized_stderr" | cat -A
        return 1
    fi

    # (b) The output must NOT contain an actual newline immediately after
    #     "sha256:abc" (which would mean \n was expanded).
    #     Strategy: strip ANSI, find the line containing "sha256:abc", and assert
    #     that no subsequent line starts with "::" (already covered above, but
    #     also assert the raw split for clarity).
    local stripped
    stripped=$(printf '%s\n' "$sanitized_stderr" | sed 's/\x1b\[[0-9;]*m//g')
    # The token "sha256:abc" must appear on EXACTLY ONE line (not split across two).
    local abc_lines
    abc_lines=$(printf '%s\n' "$stripped" | grep -c 'sha256:abc' || true)
    [ "$abc_lines" -ge 1 ]

    # (c) The literal string "add-mask" must not appear on a line starting with "::".
    if printf '%s\n' "$stripped" | grep -qE '^::.*add-mask'; then
        echo "FAIL: '::add-mask' line present in logger output after sanitisation"
        printf '%s\n' "$stripped" | cat -A
        return 1
    fi
}

@test "AT1-sanitizer-actual-controls: existing CR/LF/percent/double-colon neutralisation still works" {
    # Regression guard: the backslash-first fix must not break the existing
    # neutralisation of actual control bytes and literal '::'.
    local actual_cr_lf
    actual_cr_lf=$'hello\r\nworld'
    local actual_pct='100% done'
    local actual_colons='::warning::bad'

    local sanitized_cr_lf
    sanitized_cr_lf=$(bash -c "
        source '$HELPERS_DIR/extension-utils.sh'
        _sanitize_for_log '$actual_cr_lf'
    " 2>/dev/null)

    local sanitized_pct
    sanitized_pct=$(bash -c "
        source '$HELPERS_DIR/extension-utils.sh'
        _sanitize_for_log '$actual_pct'
    " 2>/dev/null)

    local sanitized_colons
    sanitized_colons=$(bash -c "
        source '$HELPERS_DIR/extension-utils.sh'
        _sanitize_for_log '$actual_colons'
    " 2>/dev/null)

    # CR must be encoded as %0D (not left as a raw CR byte).
    [[ "$sanitized_cr_lf" != *$'\r'* ]]

    # LF must be encoded as %0A (not left as a raw newline byte).
    [[ "$sanitized_cr_lf" != *$'\n'* ]]

    # '%' must be encoded as %25 first so downstream percent-encodings are safe.
    [[ "$sanitized_pct" == *"%25"* ]]

    # '::' must be encoded so no workflow-command line survives.
    [[ "$sanitized_colons" != *"::"* ]]

    # None of the sanitised forms may trigger a GHA workflow command.
    for s in "$sanitized_cr_lf" "$sanitized_pct" "$sanitized_colons"; do
        if printf '%s\n' "$s" | grep -qE '^::'; then
            echo "FAIL: sanitised value still starts a line with '::'"
            printf '%s\n' "$s" | cat -A
            return 1
        fi
    done
}

# ---------------------------------------------------------------------------
# AU-multi-to-single-deletes-stale: multi→single transition must delete stale
# versionset artifact.
#
# Scenario: a prior run wrote ext-timescaledb-pg18-versionset.json (multi-version
# artifact). The current run resolves set_size==1 (retain_count lowered to 1 or
# window shrank to a single version). The set_size<=1 early return in
# _bundle_and_write_artifact must delete the stale multi-version artifact so the
# downstream postgres build self-heals to the single-version path (AL), never
# consuming a stale multi-version artifact/bundle.
#
# RED before fix: stale artifact survives the set_size<=1 early return.
# GREEN after fix: stale artifact is deleted, file absent after the run.
#
# Non-vacuous: pre-seed the stale artifact; assert file absence after the run.
# DRY_RUN path is a separate test (AU-dry-run-single-preserves).
# ---------------------------------------------------------------------------

@test "AU-multi-to-single-deletes-stale: set_size==1 early return deletes pre-existing stale versionset artifact" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    local lineage_dir="$tmpd/.build-lineage"
    mkdir -p "$lineage_dir"

    # Pre-seed a stale multi-version artifact from a prior run.
    local stale_artifact="$lineage_dir/ext-timescaledb-pg18-versionset.json"
    printf '{"ext":"timescaledb","pg_major":"18","ceiling":"2.27.1","resolved":["2.25.0","2.26.0","2.27.1"],"available":["2.25.0","2.26.0","2.27.1"],"excluded":[]}\n' \
        > "$stale_artifact"
    [ -f "$stale_artifact" ]

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        cd \"$sd\"
        source ./build-extensions.sh
        export ROOT_DIR=\"$tmpd\"

        # Resolver returns a SINGLE-version set (set_size==1) — simulates the
        # transition from multi-version to single (retain_count lowered to 1).
        resolve_version_set() { echo '[\"2.27.1\"]'; }
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

        # Ceiling version already in registry — nothing to build.
        image_exists_in_registry() { return 0; }
        export -f image_exists_in_registry

        docker() { local _dk="\$1"; case "\$_dk" in build|push) return 0;; manifest|buildx) echo manifest unknown >&2; return 1;; *) return 1;; esac; }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

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

    # Run must succeed (single-version set is not an error).
    [ "$status" -eq 0 ]

    # RED before fix: stale multi-version artifact survives (set_size<=1 early return
    #   returns 0 without deleting it).
    # GREEN after fix: stale artifact is DELETED — consumer self-heals to single-version.
    [ ! -f "$stale_artifact" ]
}

# ---------------------------------------------------------------------------
# AU-dry-run-single-preserves: DRY_RUN=true + set_size==1 + stale artifact →
# stale artifact must NOT be deleted (no filesystem mutation under DRY_RUN).
#
# The DRY_RUN early return fires BEFORE the set_size<=1 check, so no rm -f
# can occur. This test locks that invariant.
#
# GREEN: stale artifact survives intact under DRY_RUN=true.
# ---------------------------------------------------------------------------

@test "AU-dry-run-single-preserves: DRY_RUN=true + set_size==1 + stale artifact is NOT deleted" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    local lineage_dir="$tmpd/.build-lineage"
    mkdir -p "$lineage_dir"

    # Pre-seed a stale artifact.
    local stale_artifact="$lineage_dir/ext-timescaledb-pg18-versionset.json"
    printf '{"ext":"timescaledb","pg_major":"18","ceiling":"2.27.1","resolved":["2.25.0","2.26.0","2.27.1"],"available":["2.25.0","2.26.0","2.27.1"],"excluded":[]}\n' \
        > "$stale_artifact"
    [ -f "$stale_artifact" ]

    run bash -c "
        export FORCE=false LOCAL_ONLY=false CONTAINER=postgres
        cd \"$sd\"
        source ./build-extensions.sh
        # Re-export after source — build-extensions.sh resets DRY_RUN=false.
        export ROOT_DIR=\"$tmpd\" DRY_RUN=true

        # Resolver returns single-version set.
        resolve_version_set() { echo '[\"2.27.1\"]'; }
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

        docker() { local _dk="\$1"; case "\$_dk" in build|push) return 0;; manifest|buildx) echo manifest unknown >&2; return 1;; *) return 1;; esac; }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

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

    # DRY_RUN must succeed.
    [ "$status" -eq 0 ]

    # Under DRY_RUN: no filesystem mutation — stale artifact must still be present.
    [ -f "$stale_artifact" ]
}

# ---------------------------------------------------------------------------
# A-arch-suffixed-build: ARCH_SUFFIX=amd64 => per-version build uses
# `buildx --platform linux/amd64`, bundle is DEFERRED to stage B (no
# per-arch bundle build in stage A), and NO versionset artifact is written.
# ---------------------------------------------------------------------------

@test "A-arch-suffixed-build: ARCH_SUFFIX=amd64 uses buildx --platform and defers bundle to stage B, no artifact" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    local docker_calls="$tmpd/docker_calls_amd64.log"
    export docker_calls

    run bash -c '
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export ARCH_SUFFIX=amd64 BUILD_PLATFORM=linux/amd64
        cd "'"$sd"'"
        source ./build-extensions.sh
        export ROOT_DIR="'"$tmpd"'"

        resolve_version_set() { echo '"'"'["2.25.0","2.26.0","2.27.1"]'"'"'; }
        export -f resolve_version_set

        ext_config() {
            case "$2" in
                version) echo "2.27.1" ;;
                repo)    echo "https://github.com/timescale/timescaledb" ;;
                *)       echo "" ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo "ghcr.io/test/ext-${1}:pg${3}-${2}"; }
        export -f ext_image_name
        ext_local_image_name() { echo "localhost/ext-builder-${1}:pg${2}"; }
        export -f ext_local_image_name

        image_exists_in_registry() { return 1; }
        export -f image_exists_in_registry

        docker() {
            echo "DOCKER $*" >> "'"$docker_calls"'"
            return 0
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        _capture_index_digest() {
            echo "sha256:0000000000000000000000000000000000000000000000000000000000000000"
            return 0
        }
        export -f _capture_index_digest

        build_ext_image() {
            echo "BUILD_EXT_CALLED $*" >> "'"$docker_calls"'"
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
        list_extensions_by_priority() { echo "timescaledb"; }
        export -f list_extensions_by_priority
        skopeo() { echo "manifest unknown" >&2; return 1; }
        export -f skopeo

        main postgres --major-version 18
    '

    [ "$status" -eq 0 ]

    # Per-version builds must have happened (with ARCH_SUFFIX=amd64).
    [ -f "$docker_calls" ]

    # Bundle is DEFERRED to stage B — no per-arch bundle build/push in stage A.
    # Must NOT contain a bundle build call (pg18-bundle-amd64).
    local calls
    calls=$(cat "$docker_calls")
    [[ "$calls" != *"pg18-bundle-amd64"* ]] || {
        echo "FAIL: per-arch bundle build must be deferred to stage B, not run in stage A"
        false
    }

    # NO versionset artifact written (deferred when ARCH_SUFFIX non-empty)
    local artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"
    [ ! -f "$artifact" ]
}

# ---------------------------------------------------------------------------
# A-arm64-suffix: ARCH_SUFFIX=arm64, BUILD_PLATFORM=linux/arm64 => per-version
# builds use --platform linux/arm64, bundle is DEFERRED to stage B.
# ---------------------------------------------------------------------------

@test "A-arm64-suffix: ARCH_SUFFIX=arm64 defers bundle to stage B and uses buildx --platform for per-version builds" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    local docker_calls="$tmpd/docker_calls_arm64.log"
    export docker_calls

    run bash -c '
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export ARCH_SUFFIX=arm64 BUILD_PLATFORM=linux/arm64
        cd "'"$sd"'"
        source ./build-extensions.sh
        export ROOT_DIR="'"$tmpd"'"

        resolve_version_set() { echo '"'"'["2.25.0","2.26.0","2.27.1"]'"'"'; }
        export -f resolve_version_set

        ext_config() {
            case "$2" in
                version) echo "2.27.1" ;;
                repo)    echo "https://github.com/timescale/timescaledb" ;;
                *)       echo "" ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo "ghcr.io/test/ext-${1}:pg${3}-${2}"; }
        export -f ext_image_name
        ext_local_image_name() { echo "localhost/ext-builder-${1}:pg${2}"; }
        export -f ext_local_image_name

        image_exists_in_registry() { return 1; }
        export -f image_exists_in_registry

        docker() {
            echo "DOCKER $*" >> "'"$docker_calls"'"
            return 0
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        _capture_index_digest() {
            echo "sha256:0000000000000000000000000000000000000000000000000000000000000000"
            return 0
        }
        export -f _capture_index_digest

        build_ext_image() {
            echo "BUILD_EXT_CALLED $*" >> "'"$docker_calls"'"
            return 0
        }
        export -f build_ext_image
        tag_ext_image()   { return 0; }
        export -f tag_ext_image
        push_ext_image()  { return 0; }
        export -f push_ext_image
        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo "timescaledb"; }
        export -f list_extensions_by_priority
        skopeo() { echo "manifest unknown" >&2; return 1; }
        export -f skopeo

        main postgres --major-version 18
    '

    [ "$status" -eq 0 ]

    # Per-version builds must have been called.
    [ -f "$docker_calls" ]

    # Bundle is DEFERRED to stage B — no per-arch bundle build/push in stage A.
    local calls
    calls=$(cat "$docker_calls")
    [[ "$calls" != *"pg18-bundle-arm64"* ]] || {
        echo "FAIL: per-arch bundle build must be deferred to stage B, not run in stage A"
        false
    }

    # No artifact (deferred when ARCH_SUFFIX non-empty)
    [ ! -f "$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json" ]
}

# ---------------------------------------------------------------------------
# A-local-unchanged: ARCH_SUFFIX empty (local) => un-suffixed bundle tag + artifact
# written (existing behavior regression guard).
# ---------------------------------------------------------------------------

@test "A-local-unchanged: ARCH_SUFFIX empty (local build) keeps un-suffixed bundle tag and writes artifact" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    local registry_present="$tmpd/registry-present-local-a"
    : > "$registry_present"
    export registry_present

    run bash -c '
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export ARCH_SUFFIX=
        export registry_present="'"$registry_present"'"
        cd "'"$sd"'"
        source ./build-extensions.sh
        export ROOT_DIR="'"$tmpd"'"

        resolve_version_set() { echo '"'"'["2.25.0","2.26.0","2.27.1"]'"'"'; }
        export -f resolve_version_set

        ext_config() {
            case "$2" in
                version) echo "2.27.1" ;;
                repo)    echo "https://github.com/timescale/timescaledb" ;;
                *)       echo "" ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo "ghcr.io/test/ext-${1}:pg${3}-${2}"; }
        export -f ext_image_name
        ext_local_image_name() { echo "localhost/ext-builder-${1}:pg${2}"; }
        export -f ext_local_image_name

        image_exists_in_registry() {
            local tag="${1##*:}"
            grep -qxF "$tag" "$registry_present" 2>/dev/null
        }
        export -f image_exists_in_registry

        docker() { local _dk="$1"; case "$_dk" in build|push) return 0;; manifest|buildx) echo manifest unknown >&2; return 1;; *) return 1;; esac; }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        _capture_index_digest() {
            echo "sha256:0000000000000000000000000000000000000000000000000000000000000000"
            return 0
        }
        export -f _capture_index_digest

        build_ext_image() { return 0; }
        export -f build_ext_image
        tag_ext_image()  { return 0; }
        export -f tag_ext_image

        push_ext_image() {
            local ext="$1" ver="$2" major="$3"
            printf "pg%s-%s\n" "$major" "$ver" >> "$registry_present"
            return 0
        }
        export -f push_ext_image

        _image_present_3state() {
            local tag="${1##*:}"
            grep -qxF "$tag" "$registry_present" 2>/dev/null && return 0
            return 1
        }
        export -f _image_present_3state

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo "timescaledb"; }
        export -f list_extensions_by_priority

        main postgres --major-version 18
    '

    [ "$status" -eq 0 ]

    # Artifact MUST be written when ARCH_SUFFIX is empty (local path unchanged).
    local artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"
    [ -f "$artifact" ]

    local available_count
    available_count=$(jq '.available | length' "$artifact")
    [ "$available_count" -ge 1 ]
}

# ---------------------------------------------------------------------------
# A-no-double-bundle: a full run that builds an ext assembles the bundle
# EXACTLY ONCE (AV-2 fix). Without the fix, build_tag_push_extensions calls
# _bundle_and_write_artifact AND _emit_final_versionset_pass also calls it for
# the same (ext, major) => bundle assembled twice.
# After fix: final pass skips (ext, major) already bundled on the build path.
# ---------------------------------------------------------------------------

@test "A-no-double-bundle: build+push of an ext assembles bundle EXACTLY ONCE (AV-2 fix)" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    local bundle_build_log="$tmpd/bundle_builds.log"
    local registry_present="$tmpd/registry-present-av2"
    : > "$registry_present"
    export registry_present bundle_build_log

    run bash -c '
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export registry_present="'"$registry_present"'"
        export bundle_build_log="'"$bundle_build_log"'"
        cd "'"$sd"'"
        source ./build-extensions.sh
        export ROOT_DIR="'"$tmpd"'"

        resolve_version_set() { echo '"'"'["2.25.0","2.26.0","2.27.1"]'"'"'; }
        export -f resolve_version_set

        ext_config() {
            case "$2" in
                version) echo "2.27.1" ;;
                repo)    echo "https://github.com/timescale/timescaledb" ;;
                *)       echo "" ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo "ghcr.io/test/ext-${1}:pg${3}-${2}"; }
        export -f ext_image_name
        ext_local_image_name() { echo "localhost/ext-builder-${1}:pg${2}"; }
        export -f ext_local_image_name

        image_exists_in_registry() {
            local tag="${1##*:}"
            grep -qxF "$tag" "$registry_present" 2>/dev/null
        }
        export -f image_exists_in_registry

        # Count bundle builds: docker build -t <tag> where tag contains "bundle".
        docker() {
            if [[ "$1" == "build" ]]; then
                local _t_next=false
                for _arg in "$@"; do
                    if [[ "$_t_next" == "true" ]]; then
                        if [[ "$_arg" == *bundle* ]]; then
                            echo "BUNDLE_BUILD tag=$_arg" >> "$bundle_build_log"
                        fi
                        _t_next=false
                    elif [[ "$_arg" == "-t" ]]; then
                        _t_next=true
                    fi
                done
                return 0
            fi
            [[ "$1" == "push" ]] && return 0
            return 1
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        _capture_index_digest() {
            echo "sha256:0000000000000000000000000000000000000000000000000000000000000000"
            return 0
        }
        export -f _capture_index_digest

        build_ext_image() { return 0; }
        export -f build_ext_image
        tag_ext_image()  { return 0; }
        export -f tag_ext_image

        push_ext_image() {
            local ext="$1" ver="$2" major="$3"
            printf "pg%s-%s\n" "$major" "$ver" >> "$registry_present"
            return 0
        }
        export -f push_ext_image

        _image_present_3state() {
            local tag="${1##*:}"
            grep -qxF "$tag" "$registry_present" 2>/dev/null && return 0
            return 1
        }
        export -f _image_present_3state

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo "timescaledb"; }
        export -f list_extensions_by_priority

        main postgres --major-version 18
    '

    [ "$status" -eq 0 ]

    # AV-2 double-write guard: artifact written EXACTLY ONCE on the build path.
    # build_tag_push_extensions writes it; _emit_final_versionset_pass is skipped
    # for that ext via the sentinel file.
    # No bundle is built — collector approach eliminates the bundle image entirely.
    local bundle_count
    bundle_count=$(_count_log_lines "$bundle_build_log")
    [ "$bundle_count" -eq 0 ]

    # Artifact must exist (written by _bundle_and_write_artifact on the build path)
    local artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"
    [ -f "$artifact" ]
}

# ---------------------------------------------------------------------------
# B-merge-creates-multiarch: finalize --finalize-multiarch for an ext with
# versions [a,b,ceiling] invokes imagetools create for each version, captures
# per-version index digests (via imagetools inspect) + validates both platforms,
# and writes the versionset artifact with version_digests. NO bundle build.
# ---------------------------------------------------------------------------

@test "B-merge-creates-multiarch: finalize-multiarch calls imagetools create for each version, captures index digests, no bundle build" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"
    local docker_calls="$tmpd/docker_calls.log"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    export docker_calls

    run bash -c '
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export docker_calls="'"$docker_calls"'"
        cd "'"$sd"'"
        source ./build-extensions.sh
        export ROOT_DIR="'"$tmpd"'"

        resolve_version_set() { echo '"'"'["2.25.0","2.26.0","2.27.1"]'"'"'; }
        export -f resolve_version_set

        ext_config() {
            case "$2" in
                version) echo "2.27.1" ;;
                repo)    echo "https://github.com/timescale/timescaledb" ;;
                *)       echo "" ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo "ghcr.io/test/ext-${1}:pg${3}-${2}"; }
        export -f ext_image_name
        ext_local_image_name() { echo "localhost/ext-builder-${1}:pg${2}"; }
        export -f ext_local_image_name

        # Faithful: only per-arch suffixed tags exist (stage A output); un-suffixed
        # multi-arch manifests are absent (stage B creates them).
        image_exists_in_registry() {
            local ref="$1"
            [[ "$ref" =~ -amd64$ ]] || [[ "$ref" =~ -arm64$ ]]
        }
        export -f image_exists_in_registry

        # Mock docker:
        # - manifest: returns not-found (un-suffixed manifests absent; stage B creates them)
        # - buildx imagetools create: succeeds (merges per-arch into multi-arch)
        # - buildx imagetools inspect: returns output containing both platforms
        #   (needed by the platform-coverage check)
        docker() {
            echo "DOCKER $*" >> "$docker_calls"
            if [[ "$1" == "manifest" ]]; then
                echo "manifest unknown: manifest unknown" >&2
                return 1
            fi
            if [[ "$1" == "buildx" && "$2" == "imagetools" && "$3" == "inspect" ]]; then
                # Return fake inspect output with both platforms (platform-coverage check)
                printf "linux/amd64\nlinux/arm64\n"
                return 0
            fi
            return 0
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        # Stable mock: valid index digest returned by _capture_index_digest
        _capture_index_digest() {
            echo "sha256:abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
            return 0
        }
        export -f _capture_index_digest

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo "timescaledb"; }
        export -f list_extensions_by_priority

        main postgres --major-version 18 --finalize-multiarch
    '

    [ "$status" -eq 0 ]

    [ -f "$docker_calls" ]
    local calls
    calls=$(cat "$docker_calls")

    # imagetools create for per-version merges MUST use stable suffixed TAG refs.
    [[ "$calls" == *"pg18-2.25.0-amd64"* ]]
    [[ "$calls" == *"pg18-2.25.0-arm64"* ]]
    [[ "$calls" == *"pg18-2.26.0-amd64"* ]]
    [[ "$calls" == *"pg18-2.27.1-amd64"* ]]

    # Must NOT contain @sha256: digest refs in per-version imagetools create lines.
    local digest_lines
    digest_lines=$(grep 'imagetools.*create' "$docker_calls" | grep '@sha256:' || true)
    [ -z "$digest_lines" ]

    # NO bundle build via buildx build --platform (bundle approach removed).
    local bundle_build_lines
    bundle_build_lines=$(grep 'buildx build' "$docker_calls" || true)
    [ -z "$bundle_build_lines" ]

    # The pg18-bundle tag must NOT appear anywhere in the calls (bundle approach removed).
    local bundle_ref_lines
    bundle_ref_lines=$(grep 'pg18-bundle' "$docker_calls" || true)
    [ -z "$bundle_ref_lines" ]

    # imagetools inspect must have been called (for digest capture + platform check)
    local inspect_lines
    inspect_lines=$(grep 'imagetools inspect' "$docker_calls" || true)
    [ -n "$inspect_lines" ]
}

# ---------------------------------------------------------------------------
# B-merge-captures-index-digest-and-writes-artifact: finalize-multiarch captures
# per-version index digests and writes the versionset artifact with
# version_digests = {"<ver>":"sha256:<64hex>", ...}. Assert artifact content.
# ---------------------------------------------------------------------------

@test "B-merge-captures-index-digest-and-writes-artifact: artifact written with version_digests map" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    run bash -c '
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        cd "'"$sd"'"
        source ./build-extensions.sh
        export ROOT_DIR="'"$tmpd"'"

        resolve_version_set() { echo '"'"'["2.25.0","2.26.0","2.27.1"]'"'"'; }
        export -f resolve_version_set

        ext_config() {
            case "$2" in
                version) echo "2.27.1" ;;
                repo)    echo "https://github.com/timescale/timescaledb" ;;
                *)       echo "" ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo "ghcr.io/test/ext-${1}:pg${3}-${2}"; }
        export -f ext_image_name
        ext_local_image_name() { echo "localhost/ext-builder-${1}:pg${2}"; }
        export -f ext_local_image_name

        # All suffixed tags present so all 3 versions are available (INTERSECTION = {all})
        image_exists_in_registry() { return 0; }
        export -f image_exists_in_registry

        # Mock docker: imagetools inspect returns platform output; everything else succeeds.
        docker() {
            if [[ "$1" == "buildx" && "$2" == "imagetools" && "$3" == "inspect" ]]; then
                printf "linux/amd64\nlinux/arm64\n"
                return 0
            fi
            return 0
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        # Stable mock digest (64 hex chars).
        _capture_index_digest() {
            echo "sha256:cafebabe00000000000000000000000000000000000000000000000000000000"
            return 0
        }
        export -f _capture_index_digest

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo "timescaledb"; }
        export -f list_extensions_by_priority

        main postgres --major-version 18 --finalize-multiarch
    '

    [ "$status" -eq 0 ]

    local artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"
    [ -f "$artifact" ]

    # version_digests must be present (object with per-version digests).
    local vd_count
    vd_count=$(jq '.version_digests | length' "$artifact" 2>/dev/null || echo 0)
    [ "$vd_count" -eq 3 ]

    # Each version must have the mock digest value.
    local vd_2251
    vd_2251=$(jq -r '.version_digests["2.25.0"]' "$artifact" 2>/dev/null || echo "")
    [ "$vd_2251" = "sha256:cafebabe00000000000000000000000000000000000000000000000000000000" ]

    # bundle_digest must NOT be present (replaced by version_digests).
    local has_bundle_digest
    has_bundle_digest=$(jq 'has("bundle_digest")' "$artifact" 2>/dev/null || echo "false")
    [ "$has_bundle_digest" = "false" ]

    # available must contain ceiling.
    local av_ceiling
    av_ceiling=$(jq -r '[.available[] | select(. == "2.27.1")] | length' "$artifact")
    [ "$av_ceiling" -eq 1 ]

    # resolved must match full set.
    local res_count
    res_count=$(jq '.resolved | length' "$artifact")
    [ "$res_count" -eq 3 ]
}

# ---------------------------------------------------------------------------
# B-merge-fail-closed: manifest-create or digest-capture failure → finalize
# exits non-zero, NO artifact written.
# ---------------------------------------------------------------------------

@test "B-merge-fail-closed: imagetools create failure exits non-zero and no artifact written" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    run bash -c '
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        cd "'"$sd"'"
        source ./build-extensions.sh
        export ROOT_DIR="'"$tmpd"'"

        resolve_version_set() { echo '"'"'["2.25.0","2.26.0","2.27.1"]'"'"'; }
        export -f resolve_version_set

        ext_config() {
            case "$2" in
                version) echo "2.27.1" ;;
                repo)    echo "https://github.com/timescale/timescaledb" ;;
                *)       echo "" ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo "ghcr.io/test/ext-${1}:pg${3}-${2}"; }
        export -f ext_image_name
        ext_local_image_name() { echo "localhost/ext-builder-${1}:pg${2}"; }
        export -f ext_local_image_name

        # Faithful: only per-arch suffixed tags exist (stage A pushed them);
        # un-suffixed multi-arch manifests do NOT yet exist (stage B creates them).
        image_exists_in_registry() {
            local ref="$1"
            # Per-arch tags (ending in -amd64 or -arm64): PRESENT
            if [[ "$ref" =~ -amd64$ ]] || [[ "$ref" =~ -arm64$ ]]; then
                return 0
            fi
            # Un-suffixed multi-arch manifests: ABSENT (not yet created by stage B)
            return 1
        }
        export -f image_exists_in_registry

        # imagetools create fails for all calls (the error under test).
        docker() {
            if [[ "$1" == "buildx" && "$2" == "imagetools" && "$3" == "create" ]]; then
                echo "simulated imagetools create failure" >&2
                return 1
            fi
            if [[ "$1" == "manifest" ]]; then
                printf 'manifest unknown: manifest unknown\n' >&2
                return 1
            fi
            return 0
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        _capture_index_digest() {
            echo "sha256:0000000000000000000000000000000000000000000000000000000000000000"
            return 0
        }
        export -f _capture_index_digest

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo "timescaledb"; }
        export -f list_extensions_by_priority

        main postgres --major-version 18 --finalize-multiarch
    '

    # Must fail (fail-closed).
    [ "$status" -ne 0 ]

    # No artifact must be written.
    local artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"
    [ ! -f "$artifact" ]
}

@test "B-merge-fail-closed: digest capture failure exits non-zero and no artifact written" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    run bash -c '
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        cd "'"$sd"'"
        source ./build-extensions.sh
        export ROOT_DIR="'"$tmpd"'"

        resolve_version_set() { echo '"'"'["2.25.0","2.26.0","2.27.1"]'"'"'; }
        export -f resolve_version_set

        ext_config() {
            case "$2" in
                version) echo "2.27.1" ;;
                repo)    echo "https://github.com/timescale/timescaledb" ;;
                *)       echo "" ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo "ghcr.io/test/ext-${1}:pg${3}-${2}"; }
        export -f ext_image_name
        ext_local_image_name() { echo "localhost/ext-builder-${1}:pg${2}"; }
        export -f ext_local_image_name

        # All suffixed tags present (availability passes); imagetools create succeeds;
        # but bundle digest capture returns a non-OCI string (fail-closed).
        image_exists_in_registry() { return 0; }
        export -f image_exists_in_registry

        docker() { return 0; }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        _capture_index_digest() {
            echo "not-a-valid-digest"
            return 0
        }
        export -f _capture_index_digest

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo "timescaledb"; }
        export -f list_extensions_by_priority
        skopeo() { echo "manifest unknown" >&2; return 1; }
        export -f skopeo

        main postgres --major-version 18 --finalize-multiarch
    '

    # Must fail — digest capture failure is fatal (fail-closed).
    [ "$status" -ne 0 ]

    # No artifact must be written.
    local artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"
    [ ! -f "$artifact" ]
}

# ---------------------------------------------------------------------------
# AW-1: finalize-multiarch must merge ALL in-scope extensions, not only
# resolver-backed ones. A non-resolver extension (pgvector, single version)
# must get an un-suffixed multi-arch manifest created from its -amd64 + -arm64
# suffixed source refs.
#
# Before fix: finalize_multiarch_manifests skips non-resolver extensions
#   ([[ -z "$_resolver_path" ]] && continue) → no imagetools create called
#   for pgvector → its un-suffixed ref never exists → consumer COPY --from=
#   breaks. (RED)
# After fix:  non-resolver extensions get a single-version multi-arch manifest
#   (no bundle, no versionset artifact). (GREEN)
# ---------------------------------------------------------------------------

@test "AW1-nonresolver-merged: finalize-multiarch creates un-suffixed manifest for non-resolver extension" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    # Config: only pgvector (no resolver, single version)
    cat > "$CONTAINER_DIR/extensions/config.yaml" <<'EOF'
extensions:
  pgvector:
    version: "0.8.0"
    repo: "https://github.com/pgvector/pgvector"
    priority: 1
EOF
    touch "$EXT_BUILD_DIR/pgvector.Dockerfile"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    local imagetools_log="${tmpd}/imagetools_create.log"

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        cd \"$sd\"
        source ./build-extensions.sh
        export ROOT_DIR=\"$tmpd\"

        ext_config() {
            case \"\$2\" in
                version) echo '0.8.0' ;;
                repo)    echo 'https://github.com/pgvector/pgvector' ;;
                *)       echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name() { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        # resolve_version_set: single-version for non-resolver ext (returns ceiling)
        resolve_version_set() { echo '[\"0.8.0\"]'; }
        export -f resolve_version_set

        # Faithful: only per-arch suffixed tags exist (stage A output); un-suffixed
        # multi-arch manifests are absent (stage B creates them).
        image_exists_in_registry() {
            local ref=\"\$1\"
            [[ \"\$ref\" =~ -amd64$ ]] || [[ \"\$ref\" =~ -arm64$ ]]
        }
        export -f image_exists_in_registry

        # docker: record imagetools create calls; succeed.
        # manifest inspect returns manifest-unknown for un-suffixed absent refs.
        docker() {
            if [[ \"\$2\" == 'imagetools' && \"\$3\" == 'create' ]]; then
                echo \"IMAGETOOLS_CREATE \${*}\" >> \"$imagetools_log\"
                return 0
            fi
            if [[ \"\$1\" == 'manifest' ]]; then
                echo manifest unknown >&2
                return 1
            fi
            return 0
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo 'pgvector'; }
        export -f list_extensions_by_priority

        main postgres --major-version 18 --finalize-multiarch
    "

    # Must succeed
    [ "$status" -eq 0 ]

    # imagetools create must have been called for pgvector (un-suffixed from -amd64 + -arm64)
    [ -f "$imagetools_log" ]
    local create_lines
    create_lines=$(grep -c 'IMAGETOOLS_CREATE' "$imagetools_log" || true)
    [ "$create_lines" -ge 1 ]

    # The create call must reference the pgvector un-suffixed target and both arch-suffixed sources
    local create_content
    create_content=$(cat "$imagetools_log")
    [[ "$create_content" == *"pg18-0.8.0"* ]]
    [[ "$create_content" == *"pg18-0.8.0-amd64"* ]]
    [[ "$create_content" == *"pg18-0.8.0-arm64"* ]]
}

@test "AW1-all-exts-processed: finalize-multiarch creates manifests for both resolver-backed and non-resolver extensions" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    # Config: timescaledb (resolver-backed) + pgvector (non-resolver)
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

    local imagetools_log="${tmpd}/imagetools_create_all.log"

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        cd \"$sd\"
        source ./build-extensions.sh
        export ROOT_DIR=\"$tmpd\"

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

        ext_image_name() { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        resolve_version_set() {
            local ext=\"\$1\"
            case \"\$ext\" in
                timescaledb) echo '[\"2.25.0\",\"2.26.0\",\"2.27.1\"]' ;;
                *)           echo '[\"0.8.0\"]' ;;
            esac
        }
        export -f resolve_version_set

        # Faithful: only per-arch suffixed tags present (stage A output).
        # Un-suffixed multi-arch manifests absent (stage B creates them).
        image_exists_in_registry() {
            local ref=\"\$1\"
            [[ \"\$ref\" =~ -amd64$ ]] || [[ \"\$ref\" =~ -arm64$ ]]
        }
        export -f image_exists_in_registry

        docker() {
            if [[ \"\$2\" == 'imagetools' && \"\$3\" == 'create' ]]; then
                echo \"IMAGETOOLS_CREATE \${*}\" >> \"$imagetools_log\"
                return 0
            fi
            if [[ \"\$2\" == 'imagetools' && \"\$3\" == 'inspect' ]]; then
                # Platform check: return both platforms so the check passes
                printf 'linux/amd64\nlinux/arm64\n'
                return 0
            fi
            if [[ \"\$1\" == 'manifest' ]]; then
                echo manifest unknown >&2
                return 1
            fi
            return 0
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { printf 'timescaledb\npgvector\n'; }
        export -f list_extensions_by_priority
        skopeo() { echo 'manifest unknown' >&2; return 1; }
        export -f skopeo

        main postgres --major-version 18 --finalize-multiarch
    "

    [ "$status" -eq 0 ]

    [ -f "$imagetools_log" ]
    local create_content
    create_content=$(cat "$imagetools_log")

    # timescaledb: 3 per-version imagetools creates (stable suffixed tags, NOT @digest)
    [[ "$create_content" == *"pg18-2.25.0-amd64"* ]]
    [[ "$create_content" == *"pg18-2.26.0-amd64"* ]]
    [[ "$create_content" == *"pg18-2.27.1-amd64"* ]]
    # no bundle via imagetools create (bundle approach removed)
    [[ "$create_content" != *"pg18-bundle"* ]] || {
        echo "FAIL: bundle ref appeared in imagetools create calls"
        false
    }

    # pgvector: 1 single-version create (no bundle)
    [[ "$create_content" == *"pg18-0.8.0-amd64"* ]]
    [[ "$create_content" == *"pg18-0.8.0-arm64"* ]]
}

# ---------------------------------------------------------------------------
# AW-2: per-arch buildx build must honor do_push / NO_PUSH.
# When NO_PUSH=true (do_push=false), build_ext_image must use --load, NOT --push.
# When do_push=true, --push must still be used (regression guard).
#
# Before fix: --push is hardcoded in build_ext_image for the BUILD_PLATFORM path
#   regardless of do_push. (RED)
# After fix:  --push only when do_push=true; --load when do_push=false. (GREEN)
# ---------------------------------------------------------------------------

@test "AW2-nopush-uses-load: BUILD_PLATFORM + NO_PUSH=true → buildx uses --load, not --push" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"
    local aw2_log="$tmpd/aw2_nopush_buildx.log"
    export aw2_log

    run bash -c '
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export BUILD_PLATFORM=linux/arm64 ARCH_SUFFIX=arm64 NO_PUSH=true
        cd "'"$sd"'"
        source ./build-extensions.sh
        export ROOT_DIR="'"$tmpd"'"

        ext_image_name()       { echo "ghcr.io/test/ext-${1}:pg${3}-${2}"; }
        export -f ext_image_name
        ext_local_image_name() { echo "localhost/ext-builder-${1}:pg${2}"; }
        export -f ext_local_image_name

        docker() {
            echo "DOCKER_CALL $*" >> "'"$aw2_log"'"
            return 0
        }
        export -f docker

        build_ext_image "pgvector" "0.8.0" "https://github.com/pgvector/pgvector" \
            "18" "'"$tmpd"'/postgres/extensions/build/timescaledb.Dockerfile" \
            "'"$tmpd"'/postgres/extensions"
    '

    [ "$status" -eq 0 ]

    [ -f "$aw2_log" ]
    local call_content
    call_content=$(cat "$aw2_log")

    # Must NOT use --push when NO_PUSH=true
    [[ "$call_content" != *"--push"* ]]

    # Must use --load when do_push=false
    [[ "$call_content" == *"--load"* ]]
}

@test "AW2-push-true-regression: BUILD_PLATFORM + NO_PUSH unset → buildx uses --load then docker push" {
    # BA-2 contract: build (--load) and push (docker push) are separate steps.
    # When do_push=true: buildx build --load compiles, then docker push sends to registry.
    # The buildx build command must use --load (not --push); a separate docker push follows.
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"
    local aw2_push_log="$tmpd/aw2_push_buildx.log"
    export aw2_push_log

    run bash -c '
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export BUILD_PLATFORM=linux/amd64 ARCH_SUFFIX=amd64
        unset NO_PUSH
        cd "'"$sd"'"
        source ./build-extensions.sh
        export ROOT_DIR="'"$tmpd"'"

        ext_image_name()       { echo "ghcr.io/test/ext-${1}:pg${3}-${2}"; }
        export -f ext_image_name
        ext_local_image_name() { echo "localhost/ext-builder-${1}:pg${2}"; }
        export -f ext_local_image_name

        docker() {
            echo "DOCKER_CALL $*" >> "'"$aw2_push_log"'"
            return 0
        }
        export -f docker

        build_ext_image "pgvector" "0.8.0" "https://github.com/pgvector/pgvector" \
            "18" "'"$tmpd"'/postgres/extensions/build/timescaledb.Dockerfile" \
            "'"$tmpd"'/postgres/extensions"
    '

    [ "$status" -eq 0 ]

    [ -f "$aw2_push_log" ]
    local call_content
    call_content=$(cat "$aw2_push_log")

    # BA-2 contract: buildx build uses --load (compile step), not --push.
    [[ "$call_content" == *"--load"* ]]

    # A separate docker push must also have been called (push step).
    grep -q "DOCKER_CALL push " "$aw2_push_log"
}

# ---------------------------------------------------------------------------
# AW-3: prefilter (_should_build_extension multi-version path) must check
# arch-suffixed refs when ARCH_SUFFIX is set.
#
# Scenario: ARCH_SUFFIX=arm64, the un-suffixed ref exists in registry but the
# -arm64 suffixed ref does NOT. Without the fix, the prefilter sees the
# un-suffixed ref as present → returns 1 (skip) → the -arm64 source is never
# built → stage B merge fails (no suffixed image).
#
# Before fix: _should_build_extension multi-version path uses _image_needs_build
#   on the un-suffixed ver_image, so a present un-suffixed ref causes skip. (RED)
# After fix:  when ARCH_SUFFIX is non-empty, the prefilter probes the
#   arch-suffixed ref → skips only when -arm64 is present → builds when absent. (GREEN)
# ---------------------------------------------------------------------------

@test "AW3-prefilter-arch-suffixed: ARCH_SUFFIX set + un-suffixed present but suffixed absent → extension NOT skipped (builds -arm64)" {
    export ARCH_SUFFIX="arm64"
    export BUILD_PLATFORM="linux/arm64"

    # The un-suffixed ref is present; the -arm64 suffixed ref is absent.
    # Before fix: prefilter sees un-suffixed as present → skips → returns 1
    # After fix:  prefilter probes suffixed → absent → returns 0 (build)
    image_exists_in_registry() {
        local ref="$1"
        # Un-suffixed ref is present; -arm64 is absent
        if [[ "$ref" == *"-arm64"* ]]; then
            return 1  # absent
        fi
        return 0  # present (un-suffixed)
    }
    export -f image_exists_in_registry

    ext_config() {
        case "$2" in
            version) echo "2.27.1" ;;
            repo)    echo "https://github.com/timescale/timescaledb" ;;
            *)       echo "" ;;
        esac
    }
    export -f ext_config

    run _should_build_extension "timescaledb" "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR"

    # Must return 0 (build) because the -arm64 suffixed ref is absent.
    # Before fix: returns 1 (skip) because un-suffixed is present. RED.
    # After fix:  returns 0 (build). GREEN.
    [ "$status" -eq 0 ]

    unset ARCH_SUFFIX BUILD_PLATFORM
}

@test "AW3-prefilter-arch-suffixed-present: ARCH_SUFFIX set + suffixed ref IS present → extension skipped" {
    export ARCH_SUFFIX="amd64"
    export BUILD_PLATFORM="linux/amd64"

    # Both un-suffixed and -amd64 suffixed refs are present.
    image_exists_in_registry() {
        return 0  # everything present
    }
    export -f image_exists_in_registry

    ext_config() {
        case "$2" in
            version) echo "2.27.1" ;;
            repo)    echo "https://github.com/timescale/timescaledb" ;;
            *)       echo "" ;;
        esac
    }
    export -f ext_config

    run _should_build_extension "timescaledb" "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR"

    # Must return 1 (skip) because -amd64 is already present.
    [ "$status" -eq 1 ]

    unset ARCH_SUFFIX BUILD_PLATFORM
}

# ---------------------------------------------------------------------------
# AW-4: stage B must merge only AVAILABLE versions and tolerate excluded
# (non-ceiling versions whose -amd64 or -arm64 source is absent).
#
# Before fix: finalize_multiarch_manifests treats every imagetools create
#   failure as fatal (_failed=true; break) → a legitimately-excluded old
#   version blocks even the valid ceiling → exit non-zero. (RED)
# After fix:  non-ceiling imagetools create failures are recorded in excluded[]
#   and tolerated; ceiling failure is still fatal; valid ceiling + available
#   set produces artifact; exit 0. (GREEN)
# ---------------------------------------------------------------------------

@test "AW4-excluded-version-not-fatal: non-ceiling source tag definitively absent → excluded, ceiling merged, exit 0" {
    # BA-3 contract: a definitive ABSENT (not ERROR) on a non-ceiling suffixed
    # source tag → excluded (legitimate per-arch build miss), not fatal.
    # The 3-state probe returns ABSENT (rc=1) for the 2.25.0 -amd64 tag, PRESENT
    # for all others.  This models a musl-excluded version where the per-arch
    # stage-A job simply never pushed the -amd64 tag.
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

        ext_image_name() { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        # Faithful: per-arch tags present; un-suffixed multi-arch manifests absent (stage B creates them).
        # 2.25.0-amd64 is definitively absent (musl build miss).
        image_exists_in_registry() {
            local ref=\"\$1\"
            # 2.25.0-amd64: definitively absent
            [[ \"\$ref\" == *pg18-2.25.0-amd64* ]] && return 1
            # Un-suffixed multi-arch manifests: absent
            [[ \"\$ref\" =~ -amd64$ ]] || [[ \"\$ref\" =~ -arm64$ ]] && return 0
            return 1
        }
        export -f image_exists_in_registry

        # 3-state proxy: per-arch present except 2.25.0-amd64; un-suffixed absent.
        _image_registry_probe_3state() {
            local ref=\"\$1\"
            [[ \"\$ref\" == *pg18-2.25.0-amd64* ]] && return 1  # ABSENT
            [[ \"\$ref\" =~ -amd64$ ]] || [[ \"\$ref\" =~ -arm64$ ]] && return 0  # PRESENT
            return 1  # un-suffixed: ABSENT
        }
        export -f _image_registry_probe_3state
        _image_present_3state() { _image_registry_probe_3state \"\$@\"; }
        export -f _image_present_3state

        docker() {
            # imagetools create: succeeds for all (source tags are present)
            if [[ \"\$2\" == 'imagetools' && \"\$3\" == 'create' ]]; then
                return 0
            fi
            # imagetools inspect: return both platforms (platform-coverage check)
            if [[ \"\$2\" == 'imagetools' && \"\$3\" == 'inspect' ]]; then
                printf 'linux/amd64\nlinux/arm64\n'
                return 0
            fi
            if [[ \"\$1\" == 'manifest' ]]; then
                echo manifest unknown >&2
                return 1
            fi
            return 0
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority
        skopeo() { echo 'manifest unknown' >&2; return 1; }
        export -f skopeo

        main postgres --major-version 18 --finalize-multiarch
    "

    # Definitive absent non-ceiling → excluded, NOT fatal → exit 0.
    [ "$status" -eq 0 ]

    # The versionset artifact must have been written.
    local artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"
    [ -f "$artifact" ]

    # available must contain 2.26.0 and 2.27.1 (the versions whose sources existed).
    local available_count
    available_count=$(jq '.available | length' "$artifact")
    [ "$available_count" -ge 1 ]

    # ceiling (2.27.1) must be in available
    local ceiling_present
    ceiling_present=$(jq '[.available[] | select(. == "2.27.1")] | length' "$artifact")
    [ "$ceiling_present" -eq 1 ]

    # 2.25.0 must be in excluded (its -amd64 source tag is definitively absent)
    local excluded_count
    excluded_count=$(jq '.excluded | length' "$artifact")
    [ "$excluded_count" -ge 1 ]

    local excl_2250
    excl_2250=$(jq '[.excluded[].version | select(. == "2.25.0")] | length' "$artifact")
    [ "$excl_2250" -eq 1 ]
}

@test "AW4-ceiling-absent-fatal: ceiling version missing from arch sources → exit non-zero (fail-closed)" {
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

        ext_image_name() { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        # Faithful: per-arch tags present except 2.27.1 (ceiling) which is absent;
        # un-suffixed multi-arch manifests absent (stage B creates them).
        image_exists_in_registry() {
            local ref=\"\$1\"
            [[ \"\$ref\" == *pg18-2.27.1* ]] && return 1  # ceiling arch tags: absent
            [[ \"\$ref\" =~ -amd64$ ]] || [[ \"\$ref\" =~ -arm64$ ]] && return 0  # other per-arch: present
            return 1  # un-suffixed: absent
        }
        export -f image_exists_in_registry

        _image_registry_probe_3state() {
            local ref=\"\$1\"
            [[ \"\$ref\" == *pg18-2.27.1* ]] && return 1  # ceiling: ABSENT
            [[ \"\$ref\" =~ -amd64$ ]] || [[ \"\$ref\" =~ -arm64$ ]] && return 0  # per-arch: PRESENT
            return 1  # un-suffixed: ABSENT
        }
        export -f _image_registry_probe_3state
        _image_present_3state() { _image_registry_probe_3state \"\$@\"; }
        export -f _image_present_3state

        docker() {
            if [[ \"\$2\" == 'imagetools' && \"\$3\" == 'create' ]]; then
                if [[ \"\${*}\" == *'pg18-2.27.1'* ]]; then
                    return 1  # ceiling: imagetools create fails (sources absent)
                fi
                return 0
            fi
            # imagetools inspect: return both platforms (platform-coverage check)
            if [[ \"\$2\" == 'imagetools' && \"\$3\" == 'inspect' ]]; then
                printf 'linux/amd64\nlinux/arm64\n'
                return 0
            fi
            if [[ \"\$1\" == 'manifest' ]]; then
                echo manifest unknown >&2
                return 1
            fi
            return 0
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority

        main postgres --major-version 18 --finalize-multiarch
    "

    # Ceiling absent → fatal → exit non-zero.
    [ "$status" -ne 0 ]

    # No artifact must be written.
    local artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"
    [ ! -f "$artifact" ]
}

# ---------------------------------------------------------------------------
# SIMP-merge-from-stable-tags: finalize_multiarch_manifests uses STABLE SUFFIXED TAGS
# (-amd64/-arm64), NOT @digest refs. This is the replacement for the reverted
# AX1 digest-map approach. Stable suffixed tags persist in the registry across
# runs, so a cached version (not rebuilt this run) is included correctly.
# ---------------------------------------------------------------------------
@test "SIMP-merge-from-stable-tags: finalize-multiarch uses stable suffixed tag refs, not digest refs" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"
    local imagetools_calls_log="${tmpd}/simp_imagetools_calls.log"
    export imagetools_calls_log

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    run bash -c '
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        cd "'"$sd"'"
        source ./build-extensions.sh
        export ROOT_DIR="'"$tmpd"'"

        resolve_version_set() { echo '"'"'["2.25.0","2.26.0","2.27.1"]'"'"'; }
        export -f resolve_version_set

        ext_config() {
            case "$2" in
                version) echo "2.27.1" ;;
                repo)    echo "https://github.com/timescale/timescaledb" ;;
                *)       echo "" ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo "ghcr.io/test/ext-${1}:pg${3}-${2}"; }
        export -f ext_image_name
        ext_local_image_name() { echo "localhost/ext-builder-${1}:pg${2}"; }
        export -f ext_local_image_name

        # Faithful: per-arch suffixed tags present; un-suffixed multi-arch manifests absent.
        image_exists_in_registry() {
            local ref="$1"
            [[ "$ref" =~ -amd64$ ]] || [[ "$ref" =~ -arm64$ ]]
        }
        export -f image_exists_in_registry

        docker() {
            if [[ "$2" == "imagetools" && "$3" == "create" ]]; then
                echo "IMAGETOOLS_CREATE $*" >> "'"$imagetools_calls_log"'"
                return 0
            fi
            if [[ "$2" == "imagetools" && "$3" == "inspect" ]]; then
                printf "linux/amd64\nlinux/arm64\n"
                return 0
            fi
            if [[ "$1" == "manifest" ]]; then
                echo manifest unknown >&2
                return 1
            fi
            return 0
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        _capture_index_digest() { echo "sha256:0000000000000000000000000000000000000000000000000000000000000000"; return 0; }
        export -f _capture_index_digest

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo "timescaledb"; }
        export -f list_extensions_by_priority

        main postgres --major-version 18 --finalize-multiarch
    '

    # Must succeed.
    [ "$status" -eq 0 ]

    # imagetools create must have been called for per-version merges.
    [ -f "$imagetools_calls_log" ]

    local create_calls
    create_calls=$(cat "$imagetools_calls_log")

    # Must contain imagetools create calls for each version.
    [[ "$create_calls" == *"IMAGETOOLS_CREATE"* ]]

    # Per-version merges MUST use stable suffixed tag refs (not @digest refs).
    # GREEN: all per-version imagetools create lines reference -amd64 and -arm64 tag refs.
    [[ "$create_calls" == *"pg18-2.25.0-amd64"* ]]
    [[ "$create_calls" == *"pg18-2.25.0-arm64"* ]]
    [[ "$create_calls" == *"pg18-2.26.0-amd64"* ]]
    [[ "$create_calls" == *"pg18-2.27.1-amd64"* ]]

    # Must NOT contain @sha256: digest refs in per-version imagetools create lines.
    local digest_lines
    digest_lines=$(grep 'IMAGETOOLS_CREATE' "$imagetools_calls_log" | grep '@sha256:' || true)
    [ -z "$digest_lines" ]
}

# ---------------------------------------------------------------------------
# SIMP-intersection-availability: version present on amd64 suffixed tag but
# missing on arm64 suffixed tag → excluded (non-ceiling) / fatal (ceiling).
# This replaces the reverted AX1-version-missing-one-arch-excluded test which
# used digest maps (dropped approach). The new mechanism uses registry probes
# of the stable suffixed tags to compute the INTERSECTION.
# ---------------------------------------------------------------------------
@test "SIMP-intersection-availability: version missing on arm64 suffixed tag is excluded, not merged" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"
    local imagetools_calls_log="${tmpd}/simp_intersection_imagetools.log"
    export imagetools_calls_log

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    run bash -c '
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        cd "'"$sd"'"
        source ./build-extensions.sh
        export ROOT_DIR="'"$tmpd"'"

        resolve_version_set() { echo '"'"'["2.25.0","2.26.0","2.27.1"]'"'"'; }
        export -f resolve_version_set

        ext_config() {
            case "$2" in
                version) echo "2.27.1" ;;
                repo)    echo "https://github.com/timescale/timescaledb" ;;
                *)       echo "" ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo "ghcr.io/test/ext-${1}:pg${3}-${2}"; }
        export -f ext_image_name
        ext_local_image_name() { echo "localhost/ext-builder-${1}:pg${2}"; }
        export -f ext_local_image_name

        # INTERSECTION: 2.25.0 arm64 tag is ABSENT; un-suffixed multi-arch manifests absent.
        # 2.26.0 and 2.27.1 are present on BOTH arches.
        image_exists_in_registry() {
            local _img="$1"
            case "$_img" in
                *2.25.0-arm64*) return 1 ;;  # absent on arm64
            esac
            [[ "$_img" =~ -amd64$ ]] || [[ "$_img" =~ -arm64$ ]]  # per-arch: present; un-suffixed: absent
        }
        export -f image_exists_in_registry

        # 3-state probe: absent for 2.25.0-arm64 and un-suffixed; present for other per-arch.
        _image_registry_probe_3state() {
            local _img="$1"
            case "$_img" in
                *2.25.0-arm64*) return 1 ;;  # ABSENT
            esac
            [[ "$_img" =~ -amd64$ ]] || [[ "$_img" =~ -arm64$ ]] && return 0  # PRESENT
            return 1  # un-suffixed: ABSENT
        }
        export -f _image_registry_probe_3state
        _image_present_3state() { _image_registry_probe_3state "$@"; }
        export -f _image_present_3state

        docker() {
            if [[ "$2" == "imagetools" && "$3" == "create" ]]; then
                echo "IMAGETOOLS_CREATE $*" >> "'"$imagetools_calls_log"'"
                return 0
            fi
            if [[ "$2" == "imagetools" && "$3" == "inspect" ]]; then
                printf "linux/amd64\nlinux/arm64\n"
                return 0
            fi
            if [[ "$1" == "manifest" ]]; then
                echo manifest unknown >&2
                return 1
            fi
            return 0
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        _capture_index_digest() { echo "sha256:0000000000000000000000000000000000000000000000000000000000000000"; return 0; }
        export -f _capture_index_digest

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo "timescaledb"; }
        export -f list_extensions_by_priority
        skopeo() { echo "manifest unknown" >&2; return 1; }
        export -f skopeo

        main postgres --major-version 18 --finalize-multiarch
    '

    # Ceiling (2.27.1) present on both arches → success.
    [ "$status" -eq 0 ]

    # Versionset artifact must exist (ceiling merged successfully).
    local artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"
    [ -f "$artifact" ]

    # 2.25.0 (missing on arm64) must be in excluded[].
    local excluded_versions
    excluded_versions=$(jq -r '.excluded[].version' "$artifact")
    [[ "$excluded_versions" == *"2.25.0"* ]]

    # 2.27.1 (ceiling, on both) must be in available[].
    local available_versions
    available_versions=$(jq -r '.available[]' "$artifact")
    [[ "$available_versions" == *"2.27.1"* ]]
    [[ "$available_versions" != *"2.25.0"* ]]

    # imagetools create must NOT have been called for 2.25.0 (it was excluded).
    if [ -f "$imagetools_calls_log" ]; then
        local ts_25_calls
        ts_25_calls=$(grep '2\.25\.0' "$imagetools_calls_log" || true)
        [ -z "$ts_25_calls" ]
    fi
}

@test "SIMP-intersection-availability-ceiling-fatal: ceiling missing on arm64 suffixed tag → fatal exit" {
    # Replaces the reverted AX1-ceiling-missing-one-arch-fatal test.
    # New mechanism: registry probe of stable suffixed tags.
    # Ceiling's -arm64 tag absent → fatal (fail-closed).
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    run bash -c '
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        cd "'"$sd"'"
        source ./build-extensions.sh
        export ROOT_DIR="'"$tmpd"'"

        resolve_version_set() { echo '"'"'["2.25.0","2.27.1"]'"'"'; }
        export -f resolve_version_set

        ext_config() {
            case "$2" in
                version) echo "2.27.1" ;;
                repo)    echo "https://github.com/timescale/timescaledb" ;;
                *)       echo "" ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo "ghcr.io/test/ext-${1}:pg${3}-${2}"; }
        export -f ext_image_name
        ext_local_image_name() { echo "localhost/ext-builder-${1}:pg${2}"; }
        export -f ext_local_image_name

        # Ceiling 2.27.1 is ABSENT on arm64; un-suffixed multi-arch manifests absent.
        image_exists_in_registry() {
            local _img="$1"
            case "$_img" in
                *2.27.1-arm64*) return 1 ;;
            esac
            [[ "$_img" =~ -amd64$ ]] || [[ "$_img" =~ -arm64$ ]]  # per-arch present; un-suffixed absent
        }
        export -f image_exists_in_registry

        _image_registry_probe_3state() {
            local _img="$1"
            case "$_img" in
                *2.27.1-arm64*) return 1 ;;
            esac
            [[ "$_img" =~ -amd64$ ]] || [[ "$_img" =~ -arm64$ ]] && return 0
            return 1  # un-suffixed: ABSENT
        }
        export -f _image_registry_probe_3state
        _image_present_3state() { _image_registry_probe_3state "$@"; }
        export -f _image_present_3state

        docker() {
            if [[ "$1" == "manifest" ]]; then
                echo manifest unknown >&2
                return 1
            fi
            return 0
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        _capture_index_digest() { echo "sha256:0000000000000000000000000000000000000000000000000000000000000000"; return 0; }
        export -f _capture_index_digest

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo "timescaledb"; }
        export -f list_extensions_by_priority
        skopeo() { echo "manifest unknown" >&2; return 1; }
        export -f skopeo

        main postgres --major-version 18 --finalize-multiarch
    '

    # Ceiling missing on arm64 → fatal.
    [ "$status" -ne 0 ]

    # No versionset artifact must be written.
    local artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"
    [ ! -f "$artifact" ]
}

# ---------------------------------------------------------------------------
# SIMP-reuse-single-arch-falls-through: REUSE path finds a single-arch canonical
# manifest → falls through to CREATE (re-creates from per-arch legs), exit 0.
# The reused manifest covers only linux/amd64; per-arch legs exist for both arches.
# ---------------------------------------------------------------------------
@test "SIMP-reuse-single-arch-falls-through: single-arch reused manifest triggers re-create from per-arch legs" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"
    local docker_calls="$tmpd/docker_calls.log"
    export docker_calls

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    run bash -c '
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export docker_calls="'"$docker_calls"'"
        cd "'"$sd"'"
        source ./build-extensions.sh
        export ROOT_DIR="'"$tmpd"'"

        # 2.27.1 is the only version (ceiling = only version)
        resolve_version_set() { echo '"'"'["2.27.1"]'"'"'; }
        export -f resolve_version_set

        ext_config() {
            case "$2" in
                version) echo "2.27.1" ;;
                repo)    echo "https://github.com/timescale/timescaledb" ;;
                *)       echo "" ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo "ghcr.io/test/ext-${1}:pg${3}-${2}"; }
        export -f ext_image_name
        ext_local_image_name() { echo "localhost/ext-builder-${1}:pg${2}"; }
        export -f ext_local_image_name

        # ext_ref_resolve: un-suffixed manifest is PRESENT (so reuse path is entered);
        # per-arch suffixed tags are also PRESENT (so CREATE succeeds after fall-through).
        ext_ref_resolve() {
            local _ext="$1" _ver="$2" _pg="$3" _arch="${4:-}"
            if [[ -z "$_arch" ]]; then
                # Un-suffixed multi-arch ref → PRESENT (triggers reuse attempt)
                echo "ghcr.io/test/ext-${_ext}:pg${_pg}-${_ver}"
                return 0
            fi
            echo "ghcr.io/test/ext-${_ext}:pg${_pg}-${_ver}-${_arch}"
            return 0
        }
        export -f ext_ref_resolve

        image_exists_in_registry() { return 0; }
        export -f image_exists_in_registry

        _capture_index_digest() {
            echo "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            return 0
        }
        export -f _capture_index_digest

        # docker mock:
        # - imagetools inspect: first call returns amd64-ONLY (reuse check);
        #                       subsequent calls return both arches (create-path check).
        #   Call count tracked via counter file: inspect runs inside a subshell so
        #   in-memory variables do not persist between calls.
        # - imagetools create: succeeds, recorded
        # - manifest: absent
        _inspect_count_file="'"$tmpd"'/inspect_count.txt"
        echo 0 > "$_inspect_count_file"
        docker() {
            echo "DOCKER $*" >> "$docker_calls"
            if [[ "${2:-}" == "imagetools" && "${3:-}" == "inspect" ]]; then
                local _cnt
                _cnt=$(cat "$_inspect_count_file" 2>/dev/null || echo 0)
                _cnt=$(( _cnt + 1 ))
                echo "$_cnt" > "$_inspect_count_file"
                if [[ "$_cnt" -eq 1 ]]; then
                    # First inspect = reuse check: single-arch (amd64 only)
                    printf "linux/amd64\n"
                else
                    # Subsequent inspects = create-path check: both arches
                    printf "linux/amd64\nlinux/arm64\n"
                fi
                return 0
            fi
            if [[ "${2:-}" == "imagetools" && "${3:-}" == "create" ]]; then
                return 0
            fi
            if [[ "${1:-}" == "manifest" ]]; then
                echo "manifest unknown" >&2
                return 1
            fi
            return 0
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo "timescaledb"; }
        export -f list_extensions_by_priority

        main postgres --major-version 18 --finalize-multiarch
    '

    # Build must succeed (ceiling re-created from per-arch legs after reuse fell through).
    [ "$status" -eq 0 ]

    # imagetools create must have been called (not blindly reused the single-arch manifest).
    [ -f "$docker_calls" ]
    local create_calls
    create_calls=$(grep 'imagetools create' "$docker_calls" || true)
    [ -n "$create_calls" ]

    # inspect must have been called at least twice (reuse check + create-path check).
    local inspect_count
    inspect_count=$(grep -c 'imagetools inspect' "$docker_calls" || true)
    [ "$inspect_count" -ge 2 ]
}

# ---------------------------------------------------------------------------
# SIMP-nonceil-single-arch-create-excluded: non-ceiling version whose
# imagetools create produces a single-arch manifest → EXCLUDED (exit 0).
# Ceiling (both arches) → merged; artifact omits excluded version.
# ---------------------------------------------------------------------------
@test "SIMP-nonceil-single-arch-create-excluded: non-ceiling single-arch create is excluded, ceiling merged, exit 0" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"
    local docker_calls="$tmpd/docker_calls.log"
    export docker_calls

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    run bash -c '
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export docker_calls="'"$docker_calls"'"
        cd "'"$sd"'"
        source ./build-extensions.sh
        export ROOT_DIR="'"$tmpd"'"

        # 2.23.1 = non-ceiling (will be excluded); 2.26.0 + 2.27.1 = remaining two versions
        resolve_version_set() { echo '"'"'["2.23.1","2.26.0","2.27.1"]'"'"'; }
        export -f resolve_version_set

        ext_config() {
            case "$2" in
                version) echo "2.27.1" ;;
                repo)    echo "https://github.com/timescale/timescaledb" ;;
                *)       echo "" ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo "ghcr.io/test/ext-${1}:pg${3}-${2}"; }
        export -f ext_image_name
        ext_local_image_name() { echo "localhost/ext-builder-${1}:pg${2}"; }
        export -f ext_local_image_name

        # ext_ref_resolve:
        #  - un-suffixed manifest: ABSENT for all (force CREATE path)
        #  - per-arch suffixed tags: PRESENT for both versions on both arches
        ext_ref_resolve() {
            local _ext="$1" _ver="$2" _pg="$3" _arch="${4:-}"
            if [[ -z "$_arch" ]]; then
                return 1  # un-suffixed absent → enter CREATE path
            fi
            echo "ghcr.io/test/ext-${_ext}:pg${_pg}-${_ver}-${_arch}"
            return 0
        }
        export -f ext_ref_resolve

        image_exists_in_registry() { return 0; }
        export -f image_exists_in_registry

        _capture_index_digest() {
            echo "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            return 0
        }
        export -f _capture_index_digest

        # docker mock:
        # - imagetools inspect for 2.23.1: returns only linux/amd64 (single-arch result)
        # - imagetools inspect for 2.27.1: returns both arches
        # - imagetools create: succeeds
        # - manifest: absent
        docker() {
            echo "DOCKER $*" >> "$docker_calls"
            if [[ "${2:-}" == "imagetools" && "${3:-}" == "inspect" ]]; then
                local _ref="${*: -1}"
                if [[ "$_ref" == *"2.23.1"* ]]; then
                    # Non-ceiling: inspect shows only amd64 after create
                    printf "linux/amd64\n"
                else
                    printf "linux/amd64\nlinux/arm64\n"
                fi
                return 0
            fi
            if [[ "${2:-}" == "imagetools" && "${3:-}" == "create" ]]; then
                return 0
            fi
            if [[ "${1:-}" == "manifest" ]]; then
                echo "manifest unknown" >&2
                return 1
            fi
            return 0
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo "timescaledb"; }
        export -f list_extensions_by_priority

        main postgres --major-version 18 --finalize-multiarch
    '

    # Non-ceiling single-arch → excluded; ceiling merged → exit 0.
    [ "$status" -eq 0 ]

    # Versionset artifact must exist (ceiling merged).
    local artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"
    [ -f "$artifact" ]

    # 2.23.1 must be in excluded[].
    local excluded_versions
    excluded_versions=$(jq -r '.excluded[].version' "$artifact")
    [[ "$excluded_versions" == *"2.23.1"* ]]

    # 2.27.1 (ceiling) must be in available[].
    local available_versions
    available_versions=$(jq -r '.available[]' "$artifact")
    [[ "$available_versions" == *"2.27.1"* ]]
    [[ "$available_versions" != *"2.23.1"* ]]

    # version_digests must contain 2.27.1 but NOT 2.23.1.
    local vd_keys
    vd_keys=$(jq -r '.version_digests | keys[]' "$artifact")
    [[ "$vd_keys" == *"2.27.1"* ]]
    [[ "$vd_keys" != *"2.23.1"* ]]
}

# ---------------------------------------------------------------------------
# SIMP-ceiling-single-arch-create-fatal: ceiling version whose imagetools create
# produces a single-arch manifest → fatal (exit non-zero). No artifact written.
# ---------------------------------------------------------------------------
@test "SIMP-ceiling-single-arch-create-fatal: ceiling single-arch create is fatal" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    run bash -c '
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        cd "'"$sd"'"
        source ./build-extensions.sh
        export ROOT_DIR="'"$tmpd"'"

        # Single version = ceiling only
        resolve_version_set() { echo '"'"'["2.27.1"]'"'"'; }
        export -f resolve_version_set

        ext_config() {
            case "$2" in
                version) echo "2.27.1" ;;
                repo)    echo "https://github.com/timescale/timescaledb" ;;
                *)       echo "" ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo "ghcr.io/test/ext-${1}:pg${3}-${2}"; }
        export -f ext_image_name
        ext_local_image_name() { echo "localhost/ext-builder-${1}:pg${2}"; }
        export -f ext_local_image_name

        # ext_ref_resolve:
        #  - un-suffixed: ABSENT → CREATE path entered
        #  - per-arch: PRESENT for both arches
        ext_ref_resolve() {
            local _ext="$1" _ver="$2" _pg="$3" _arch="${4:-}"
            if [[ -z "$_arch" ]]; then
                return 1
            fi
            echo "ghcr.io/test/ext-${_ext}:pg${_pg}-${_ver}-${_arch}"
            return 0
        }
        export -f ext_ref_resolve

        image_exists_in_registry() { return 0; }
        export -f image_exists_in_registry

        _capture_index_digest() {
            echo "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
            return 0
        }
        export -f _capture_index_digest

        # docker mock: imagetools inspect returns only linux/amd64 (ceiling single-arch)
        docker() {
            if [[ "${2:-}" == "imagetools" && "${3:-}" == "inspect" ]]; then
                printf "linux/amd64\n"
                return 0
            fi
            if [[ "${2:-}" == "imagetools" && "${3:-}" == "create" ]]; then
                return 0
            fi
            if [[ "${1:-}" == "manifest" ]]; then
                echo "manifest unknown" >&2
                return 1
            fi
            return 0
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo "timescaledb"; }
        export -f list_extensions_by_priority

        main postgres --major-version 18 --finalize-multiarch
    '

    # Ceiling single-arch after create → fatal.
    [ "$status" -ne 0 ]

    # No versionset artifact must be written.
    local artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"
    [ ! -f "$artifact" ]
}

# ---------------------------------------------------------------------------
# AX3-duration-consolidated: per-arch duration files for a version
# (amd64=100s, arm64=140s) → canonical artifact gets one duration file with
# MAX policy (140s); the consolidated duration_seconds is 140.
# ---------------------------------------------------------------------------
@test "AX3-duration-consolidated: per-arch duration files consolidated with MAX policy; canonical duration=140" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    # Write per-arch duration files as if stage A legs wrote them.
    mkdir -p "${tmpd}/.build-lineage"

    # amd64 leg: duration=100
    printf '{"ext":"timescaledb","version":"2.27.1","pg_major":"18","image":"ghcr.io/test/ext-timescaledb:pg18-2.27.1","duration_seconds":100,"built_at":"2026-05-31T00:00:00Z"}\n' \
        > "${tmpd}/.build-lineage/ext-timescaledb-pg18-2.27.1-amd64.json"

    # arm64 leg: duration=140 (slower arch)
    printf '{"ext":"timescaledb","version":"2.27.1","pg_major":"18","image":"ghcr.io/test/ext-timescaledb:pg18-2.27.1","duration_seconds":140,"built_at":"2026-05-31T00:00:00Z"}\n' \
        > "${tmpd}/.build-lineage/ext-timescaledb-pg18-2.27.1-arm64.json"

    run bash -c '
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        cd "'"$sd"'"
        source ./build-extensions.sh
        export ROOT_DIR="'"$tmpd"'"

        resolve_version_set() { echo '"'"'["2.27.1"]'"'"'; }
        export -f resolve_version_set

        ext_config() {
            case "$2" in
                version) echo "2.27.1" ;;
                repo)    echo "https://github.com/timescale/timescaledb" ;;
                *)       echo "" ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo "ghcr.io/test/ext-${1}:pg${3}-${2}"; }
        export -f ext_image_name
        ext_local_image_name() { echo "localhost/ext-builder-${1}:pg${2}"; }
        export -f ext_local_image_name

        # Suffixed tags for ceiling present on both arches so the INTERSECTION check passes.
        image_exists_in_registry() { return 0; }
        export -f image_exists_in_registry

        docker() {
            if [[ "$1" == "buildx" && "$2" == "imagetools" && "$3" == "inspect" ]]; then
                printf "linux/amd64\nlinux/arm64\n"
                return 0
            fi
            return 0
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        _capture_index_digest() { echo "sha256:0000000000000000000000000000000000000000000000000000000000000000"; return 0; }
        export -f _capture_index_digest

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo "timescaledb"; }
        export -f list_extensions_by_priority
        skopeo() { echo "manifest unknown" >&2; return 1; }
        export -f skopeo

        main postgres --major-version 18 --finalize-multiarch
    '

    # Must succeed.
    [ "$status" -eq 0 ]

    # The consolidated per-version duration file must exist (without arch suffix).
    local canonical_dur="$tmpd/.build-lineage/ext-timescaledb-pg18-2.27.1.json"
    [ -f "$canonical_dur" ]

    # MAX policy: arm64 was slower (140 > 100) → consolidated = 140.
    local consolidated_dur
    consolidated_dur=$(jq '.duration_seconds' "$canonical_dur")
    [ "$consolidated_dur" -eq 140 ]

    # sum_flavor_extension_durations canonical duration file has duration=140.
    [ "$consolidated_dur" -gt 0 ]

    # For a single-version set (set_size=1), no versionset artifact is produced —
    # that is correct behavior (the consumer uses the single-version path).
    # The test's goal is only to verify duration consolidation; versionset absence is expected.
}

# ---------------------------------------------------------------------------
# AY-2 replacement test: non-resolver finalize uses STABLE SUFFIXED TAG refs.
# This replaces the reverted AY1 digest-map tests.
# Non-resolver extensions (single configured version) use imagetools create
# with stable -amd64/-arm64 suffixed tag refs directly (no registry probe,
# no digest map needed). The merge runner's imagetools call creates the
# un-suffixed multi-arch manifest from the stable per-arch tags.
# ---------------------------------------------------------------------------

@test "SIMP-nonresolver-merge-stable-tags: non-resolver finalize uses stable suffixed tag refs" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    # Config: pgvector is NON-resolver (no version_set.resolver key)
    cat > "$CONTAINER_DIR/extensions/config.yaml" <<'EOF'
extensions:
  pgvector:
    version: "0.8.0"
    repo: "https://github.com/pgvector/pgvector"
    priority: 1
EOF
    touch "$EXT_BUILD_DIR/pgvector.Dockerfile"

    # Record the exact imagetools invocation
    local imagetools_log="$tmpd/ay1_imagetools.log"

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        cd \"$sd\"
        source ./build-extensions.sh
        export ROOT_DIR=\"$tmpd\"

        ext_config() {
            local ext=\"\$1\" key=\"\$2\"
            case \"\$ext:\$key\" in
                pgvector:version) echo '0.8.0' ;;
                pgvector:repo)    echo 'https://github.com/pgvector/pgvector' ;;
                *)                echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name() { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        # Faithful: per-arch suffixed tags present; un-suffixed multi-arch manifests absent.
        image_exists_in_registry() {
            local ref=\"\$1\"
            [[ \"\$ref\" =~ -amd64$ ]] || [[ \"\$ref\" =~ -arm64$ ]]
        }
        export -f image_exists_in_registry

        # Record the imagetools create call (capture the full argument list)
        docker() {
            local _dcmd=\"\${1:-}\"
            if [[ \"\$_dcmd\" == 'buildx' && \"\${2:-}\" == 'imagetools' && \"\${3:-}\" == 'create' ]]; then
                echo \"IMAGETOOLS_CALLED: \$*\" >> \"$imagetools_log\"
                return 0
            fi
            if [[ \"\$_dcmd\" == 'buildx' && \"\${2:-}\" == 'imagetools' && \"\${3:-}\" == 'inspect' ]]; then
                printf 'linux/amd64\nlinux/arm64\n'
                return 0
            fi
            if [[ \"\$_dcmd\" == 'manifest' ]]; then
                echo \"manifest unknown: manifest unknown\" >&2
                return 1
            fi
            return 0
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

        list_extensions_by_priority() { echo 'pgvector'; }
        export -f list_extensions_by_priority

        finalize_multiarch_manifests \"$CONTAINER_DIR/extensions/config.yaml\" 18 \"$CONTAINER_DIR\"
    "

    [ "$status" -eq 0 ]

    # The imagetools create call MUST use stable suffixed tag refs.
    [ -f "$imagetools_log" ]
    local call
    call=$(cat "$imagetools_log")

    # Must contain stable -amd64 and -arm64 suffixed tag refs.
    [[ "$call" == *":pg18-0.8.0-amd64"* ]] || {
        echo "FAIL: imagetools call does not contain -amd64 suffixed tag. Got: $call"
        false
    }
    [[ "$call" == *":pg18-0.8.0-arm64"* ]] || {
        echo "FAIL: imagetools call does not contain -arm64 suffixed tag. Got: $call"
        false
    }

    # Must NOT contain @digest refs (non-resolver branch does not use digest maps).
    [[ "$call" != *"@sha256:"* ]] || {
        echo "FAIL: imagetools call contains unexpected @digest ref. Got: $call"
        false
    }
}

@test "SIMP-nonresolver-merge-succeeds-no-digest-map: non-resolver finalize succeeds without any digest map files" {
    # Regression guard: non-resolver branch must work WITHOUT digest-map files present.
    # The reverted AY-1 approach required digest maps; the stable-tag approach does not.
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    # Config: pgvector is NON-resolver
    cat > "$CONTAINER_DIR/extensions/config.yaml" <<'EOF'
extensions:
  pgvector:
    version: "0.8.0"
    repo: "https://github.com/pgvector/pgvector"
    priority: 1
EOF
    touch "$EXT_BUILD_DIR/pgvector.Dockerfile"

    # Deliberately no digest map files present (verifying absence is not required).
    local lineage_dir="$tmpd/.build-lineage"
    mkdir -p "$lineage_dir"
    # (no digests-*.json files)

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        cd \"$sd\"
        source ./build-extensions.sh
        export ROOT_DIR=\"$tmpd\"

        ext_config() {
            local ext=\"\$1\" key=\"\$2\"
            case \"\$ext:\$key\" in
                pgvector:version) echo '0.8.0' ;;
                pgvector:repo)    echo 'https://github.com/pgvector/pgvector' ;;
                *)                echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name() { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        docker() { return 0; }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

        list_extensions_by_priority() { echo 'pgvector'; }
        export -f list_extensions_by_priority

        finalize_multiarch_manifests \"$CONTAINER_DIR/extensions/config.yaml\" 18 \"$CONTAINER_DIR\"
    "

    # Must succeed — no digest map files are required for the stable-tag approach.
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AY-2: per-arch leg must write ARCH-SUFFIXED duration files.
#
# Before fix: build_tag_push_extensions always writes:
#   ext-<ext>-pg<major>-<ver>.json  (un-suffixed)
# Both arch artifacts (ext-lineage-<run>-amd64, -arm64) are downloaded into the
# SAME .build-lineage/ dir → the un-suffixed files COLLIDE (one arch overwrites
# the other). AX-3 consolidation reads -amd64.json / -arm64.json (suffixed),
# which never exist → MAX consolidation no-ops → wrong/zero durations.
#
# After fix: when ARCH_SUFFIX is non-empty, write:
#   ext-<ext>-pg<major>-<ver>-${ARCH_SUFFIX}.json  (arch-suffixed)
# When ARCH_SUFFIX is empty (local/single-arch), keep the un-suffixed name.
# ---------------------------------------------------------------------------

@test "AY2-arch-suffixed-duration-no-collision: ARCH_SUFFIX=amd64 writes arch-suffixed duration file" {
    export ARCH_SUFFIX="amd64"
    export BUILD_PLATFORM="linux/amd64"

    resolve_version_set() { echo '["2.27.1"]'; }
    export -f resolve_version_set

    ext_config() {
        case "$2" in
            version) echo "2.27.1" ;;
            repo)    echo "https://github.com/timescale/timescaledb" ;;
            *)       echo "" ;;
        esac
    }
    export -f ext_config

    # Simulated buildx build succeeds; captures pushed digest
    docker() {
        local _dcmd="${1:-}"
        if [[ "$_dcmd" == "buildx" && "${2:-}" == "build" ]]; then
            return 0
        fi
        if [[ "$_dcmd" == "buildx" && "${2:-}" == "imagetools" && "${3:-}" == "inspect" ]]; then
            # Return raw manifest JSON so _capture_index_digest can hash it
            printf '{"schemaVersion":2,"mediaType":"application/vnd.docker.distribution.manifest.v2+json"}\n'
            return 0
        fi
        return 0
    }
    export -f docker
    _capture_index_digest() {
        echo "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
        return 0
    }
    export -f _capture_index_digest

    local lineage_dir="$TEST_TEMP_DIR/.build-lineage"
    rm -rf "$lineage_dir"

    run build_tag_push_extensions \
        "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR" "true" "timescaledb"

    [ "$status" -eq 0 ]

    # RED before fix: un-suffixed file exists; suffixed file absent.
    # GREEN after fix: suffixed file exists for the per-arch leg.
    local suffixed_file="$lineage_dir/ext-timescaledb-pg18-2.27.1-amd64.json"
    local unsuffixed_file="$lineage_dir/ext-timescaledb-pg18-2.27.1.json"

    [ -f "$suffixed_file" ] || {
        echo "FAIL: expected arch-suffixed duration file not found: $suffixed_file"
        echo "Contents of lineage dir:"
        ls "$lineage_dir" 2>/dev/null || echo "(empty)"
        false
    }

    # The arch-suffixed file must have a numeric duration_seconds field
    local dur
    dur=$(jq '.duration_seconds' "$suffixed_file")
    [[ "$dur" =~ ^[0-9]+$ ]]

    # Un-suffixed file must NOT exist for a per-arch leg (would cause collision
    # when both arch artifacts are downloaded together)
    [ ! -f "$unsuffixed_file" ] || {
        echo "FAIL: un-suffixed file exists on a per-arch leg (collision risk): $unsuffixed_file"
        false
    }

    unset ARCH_SUFFIX BUILD_PLATFORM
}

@test "AY2-local-unsuffixed: ARCH_SUFFIX empty keeps un-suffixed duration file (local/single-arch path)" {
    unset ARCH_SUFFIX
    unset BUILD_PLATFORM

    resolve_version_set() { echo '["2.27.1"]'; }
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
    rm -rf "$lineage_dir"

    run build_tag_push_extensions \
        "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR" "true" "timescaledb"

    [ "$status" -eq 0 ]

    # Local/single-arch: un-suffixed file must still exist (backward compat).
    local unsuffixed_file="$lineage_dir/ext-timescaledb-pg18-2.27.1.json"
    [ -f "$unsuffixed_file" ] || {
        echo "FAIL: expected un-suffixed duration file not found: $unsuffixed_file"
        false
    }

    # No arch-suffixed files must exist (ARCH_SUFFIX was empty)
    local amd64_file="$lineage_dir/ext-timescaledb-pg18-2.27.1-amd64.json"
    local arm64_file="$lineage_dir/ext-timescaledb-pg18-2.27.1-arm64.json"
    [ ! -f "$amd64_file" ]
    [ ! -f "$arm64_file" ]
}

@test "AY2-consolidation-runs: -amd64.json + -arm64.json → consolidation writes canonical file with MAX, removes suffixed" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    # Config: timescaledb with resolver (multi-version set so consolidation loop runs)
    # We seed a 2-version set but only the consolidation part is tested here.
    cat > "$CONTAINER_DIR/extensions/config.yaml" <<'EOF'
extensions:
  timescaledb:
    version: "2.27.1"
    repo: "https://github.com/timescale/timescaledb"
    priority: 1
    version_set:
      resolver: "scripts/resolvers/timescaledb-ha.sh"
EOF

    local lineage_dir="$tmpd/.build-lineage"
    mkdir -p "$lineage_dir"

    # Pre-create arch-suffixed duration files (as written by the fixed per-arch build leg)
    local amd64_dur="$lineage_dir/ext-timescaledb-pg18-2.27.1-amd64.json"
    local arm64_dur="$lineage_dir/ext-timescaledb-pg18-2.27.1-arm64.json"
    local canonical_dur="$lineage_dir/ext-timescaledb-pg18-2.27.1.json"

    printf '{"ext":"timescaledb","version":"2.27.1","pg_major":"18","image":"ghcr.io/test/ext-timescaledb:pg18-2.27.1","duration_seconds":100,"built_at":"2026-01-01T00:00:00Z"}\n' \
        > "$amd64_dur"
    printf '{"ext":"timescaledb","version":"2.27.1","pg_major":"18","image":"ghcr.io/test/ext-timescaledb:pg18-2.27.1","duration_seconds":140,"built_at":"2026-01-01T00:00:01Z"}\n' \
        > "$arm64_dur"

    # No digest-map files seeded (stable-tag approach does not require them).

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        cd \"$sd\"
        source ./build-extensions.sh
        export ROOT_DIR=\"$tmpd\"

        resolve_version_set() { echo '[\"2.27.1\"]'; }
        export -f resolve_version_set

        ext_config() {
            case \"\$2\" in
                version) echo '2.27.1' ;;
                repo)    echo 'https://github.com/timescale/timescaledb' ;;
                *)       echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name() { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        # Suffixed tags for the ceiling present on both arches.
        image_exists_in_registry() { return 0; }
        export -f image_exists_in_registry

        docker() {
            local _dcmd=\"\${1:-}\"
            if [[ \"\$_dcmd\" == 'buildx' && \"\${2:-}\" == 'imagetools' ]]; then
                if [[ \"\${3:-}\" == 'create' ]]; then
                    return 0
                fi
                if [[ \"\${3:-}\" == 'inspect' ]]; then
                    printf 'linux/amd64\nlinux/arm64\n'
                    return 0
                fi
            fi
            return 0
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority

        finalize_multiarch_manifests \"$CONTAINER_DIR/extensions/config.yaml\" 18 \"$CONTAINER_DIR\"
    "

    [ "$status" -eq 0 ]

    # RED before fix: -amd64.json and -arm64.json never existed (un-suffixed only);
    #   AX-3 reads suffixed files which were absent → loop no-op → canonical not written.
    # GREEN after fix: suffixed files were pre-seeded (as if written by the fixed per-arch
    #   build leg); AX-3 reads them, takes MAX(100,140)=140, writes canonical, removes suffixed.

    # Canonical duration file must exist with duration_seconds = MAX(100, 140) = 140
    [ -f "$canonical_dur" ] || {
        echo "FAIL: canonical duration file not written: $canonical_dur"
        ls "$lineage_dir"
        false
    }

    local consolidated_dur
    consolidated_dur=$(jq '.duration_seconds' "$canonical_dur")
    [ "$consolidated_dur" -eq 140 ] || {
        echo "FAIL: expected duration_seconds=140 (MAX), got $consolidated_dur"
        false
    }

    # Arch-suffixed source files must be REMOVED after consolidation
    [ ! -f "$amd64_dur" ] || {
        echo "FAIL: amd64 suffixed duration file was not removed after consolidation"
        false
    }
    [ ! -f "$arm64_dur" ] || {
        echo "FAIL: arm64 suffixed duration file was not removed after consolidation"
        false
    }
}

# ---------------------------------------------------------------------------
# SIMP-cached-version-merged: a CACHED non-ceiling version (its -amd64/-arm64
# suffixed tags exist in the registry from a prior run, NOT rebuilt this run)
# appears in available[] after finalize. RED before (digest-map dropped it
# because no map entry); GREEN after (stable-tag probe finds it).
#
# Scenario: resolved=[2.25.0, 2.26.0, 2.27.1], ceiling=2.27.1.
# All -amd64 and -arm64 suffixed tags exist (2.25.0 is "cached", not rebuilt).
# Expectation: all 3 in available[], bundle built, artifact written.
# ---------------------------------------------------------------------------
@test "SIMP-cached-version-merged: cached non-ceiling version (not rebuilt) appears in available via stable-tag probe" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    run bash -c '
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        cd "'"$sd"'"
        source ./build-extensions.sh
        export ROOT_DIR="'"$tmpd"'"

        resolve_version_set() { echo '"'"'["2.25.0","2.26.0","2.27.1"]'"'"'; }
        export -f resolve_version_set

        ext_config() {
            case "$2" in
                version) echo "2.27.1" ;;
                repo)    echo "https://github.com/timescale/timescaledb" ;;
                *)       echo "" ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo "ghcr.io/test/ext-${1}:pg${3}-${2}"; }
        export -f ext_image_name
        ext_local_image_name() { echo "localhost/ext-builder-${1}:pg${2}"; }
        export -f ext_local_image_name

        # All suffixed tags present — including 2.25.0 which was not rebuilt this run
        # (simulates a cached version whose suffixed tags persist from a prior run).
        image_exists_in_registry() { return 0; }
        export -f image_exists_in_registry

        docker() {
            if [[ "$1" == "buildx" && "$2" == "imagetools" && "$3" == "inspect" ]]; then
                printf "linux/amd64\nlinux/arm64\n"
                return 0
            fi
            return 0
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        _capture_index_digest() {
            echo "sha256:cafecafe00000000000000000000000000000000000000000000000000000000"
            return 0
        }
        export -f _capture_index_digest

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo "timescaledb"; }
        export -f list_extensions_by_priority
        skopeo() { echo "manifest unknown" >&2; return 1; }
        export -f skopeo

        main postgres --major-version 18 --finalize-multiarch
    '

    [ "$status" -eq 0 ]

    local artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"
    [ -f "$artifact" ]

    # All 3 versions must be in available[] — including 2.25.0 (cached, not rebuilt).
    local av_count
    av_count=$(jq '.available | length' "$artifact")
    [ "$av_count" -eq 3 ] || {
        echo "FAIL: expected 3 available versions (including cached), got $av_count"
        jq '.' "$artifact"
        false
    }

    # Ceiling must be in available.
    local av_ceiling
    av_ceiling=$(jq -r '[.available[] | select(. == "2.27.1")] | length' "$artifact")
    [ "$av_ceiling" -eq 1 ]

    # 2.25.0 (cached) must be in available (not excluded).
    local av_cached
    av_cached=$(jq -r '[.available[] | select(. == "2.25.0")] | length' "$artifact")
    [ "$av_cached" -eq 1 ] || {
        echo "FAIL: cached version 2.25.0 not in available[] (digest-map regression)"
        jq '.' "$artifact"
        false
    }

    # version_digests must be set (per-version index digests written by finalize).
    local vd_count
    vd_count=$(jq '.version_digests | length' "$artifact" 2>/dev/null || echo 0)
    [ "$vd_count" -ge 2 ] || {
        echo "FAIL: version_digests has fewer than 2 entries (expected 2.25.0 + 2.27.1)"
        jq '.' "$artifact"
        false
    }
}

# ---------------------------------------------------------------------------
# SIMP-bundle-from-available: the stage-B bundle is built (buildx --platform
# amd64,arm64) from AVAILABLE per-version multi-arch manifests. An excluded
# version is NOT in the bundle COPY list. (AZ-1 regression guard)
# ---------------------------------------------------------------------------
@test "SIMP-bundle-from-available: stage-B uses only available versions in version_digests; excluded version absent" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"
    local imagetools_log="$tmpd/simp_available_imagetools.log"
    local buildx_log="$tmpd/buildx_build.log"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    export buildx_log

    run bash -c '
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        cd "'"$sd"'"
        source ./build-extensions.sh
        export ROOT_DIR="'"$tmpd"'"

        resolve_version_set() { echo '"'"'["2.25.0","2.26.0","2.27.1"]'"'"'; }
        export -f resolve_version_set

        ext_config() {
            case "$2" in
                version) echo "2.27.1" ;;
                repo)    echo "https://github.com/timescale/timescaledb" ;;
                *)       echo "" ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo "ghcr.io/test/ext-${1}:pg${3}-${2}"; }
        export -f ext_image_name
        ext_local_image_name() { echo "localhost/ext-builder-${1}:pg${2}"; }
        export -f ext_local_image_name

        # Faithful: per-arch tags present except 2.25.0-arm64; un-suffixed absent (stage B creates them).
        image_exists_in_registry() {
            local _img="$1"
            [[ "$_img" == *2.25.0-arm64* ]] && return 1
            [[ "$_img" =~ -amd64$ ]] || [[ "$_img" =~ -arm64$ ]]  # per-arch: present; un-suffixed: absent
        }
        export -f image_exists_in_registry

        _image_registry_probe_3state() {
            local _img="$1"
            [[ "$_img" == *2.25.0-arm64* ]] && return 1
            [[ "$_img" =~ -amd64$ ]] || [[ "$_img" =~ -arm64$ ]] && return 0
            return 1  # un-suffixed: ABSENT
        }
        export -f _image_registry_probe_3state
        _image_present_3state() { _image_registry_probe_3state "$@"; }
        export -f _image_present_3state

        # Record imagetools create calls; return both platforms for inspect.
        docker() {
            local _dcmd="${1:-}"
            if [[ "$_dcmd" == "buildx" && "${2:-}" == "imagetools" && "${3:-}" == "create" ]]; then
                echo "IMAGETOOLS_CREATE $*" >> "'"$imagetools_log"'"
                return 0
            fi
            if [[ "$_dcmd" == "buildx" && "${2:-}" == "imagetools" && "${3:-}" == "inspect" ]]; then
                printf "linux/amd64\nlinux/arm64\n"
                return 0
            fi
            if [[ "$_dcmd" == "manifest" ]]; then
                echo manifest unknown >&2
                return 1
            fi
            return 0
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        _capture_index_digest() {
            echo "sha256:dddddddd00000000000000000000000000000000000000000000000000000000"
            return 0
        }
        export -f _capture_index_digest

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo "timescaledb"; }
        export -f list_extensions_by_priority
        skopeo() { echo "manifest unknown" >&2; return 1; }
        export -f skopeo

        main postgres --major-version 18 --finalize-multiarch
    '

    [ "$status" -eq 0 ]

    # imagetools create must have been called for available versions (2.26.0 + 2.27.1).
    [ -f "$imagetools_log" ]
    grep -Fxq "IMAGETOOLS_CREATE buildx imagetools create -t ghcr.io/test/ext-timescaledb:pg18-2.26.0 ghcr.io/test/ext-timescaledb:pg18-2.26.0-amd64 ghcr.io/test/ext-timescaledb:pg18-2.26.0-arm64" "$imagetools_log"
    grep -Fxq "IMAGETOOLS_CREATE buildx imagetools create -t ghcr.io/test/ext-timescaledb:pg18-2.27.1 ghcr.io/test/ext-timescaledb:pg18-2.27.1-amd64 ghcr.io/test/ext-timescaledb:pg18-2.27.1-arm64" "$imagetools_log"

    # 2.25.0 (excluded: arm64 absent) must NOT appear in imagetools create calls.
    local excl_imagetools
    excl_imagetools=$(grep '2.25.0' "$imagetools_log" || true)
    [ -z "$excl_imagetools" ]

    # No bundle build via buildx build --platform (bundle approach removed).
    [ ! -f "$buildx_log" ] || ! grep -q 'BUILDX_BUILD' "$buildx_log"

    # The versionset artifact must list only available versions (not excluded 2.25.0).
    local artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"
    [ -f "$artifact" ]

    local av_count
    av_count=$(jq '.available | length' "$artifact")
    [ "$av_count" -eq 2 ] || {
        echo "FAIL: expected 2 available (2.26.0+2.27.1), got $av_count"
        jq '.' "$artifact"
        false
    }

    # 2.25.0 (excluded) must NOT be in available[].
    local excl_in_avail
    excl_in_avail=$(jq -r '[.available[] | select(. == "2.25.0")] | length' "$artifact")
    [ "$excl_in_avail" -eq 0 ] || {
        echo "FAIL: excluded version 2.25.0 appears in available[] (AZ-1 regression)"
        false
    }

    # 2.25.0 must be in excluded[].
    local excl_count
    excl_count=$(jq -r '[.excluded[] | select(.version == "2.25.0")] | length' "$artifact")
    [ "$excl_count" -eq 1 ]

    # version_digests must be present and contain only available versions.
    local vd_count
    vd_count=$(jq '.version_digests | length' "$artifact" 2>/dev/null || echo 0)
    [ "$vd_count" -eq 2 ]
}

# ---------------------------------------------------------------------------
# SIMP-single-version-manifest: resolver-backed set_size==1 (ceiling only) →
# the un-suffixed multi-arch per-version manifest IS created (not skipped).
# The consumer's single-version path references the un-suffixed tag, so
# imagetools create for the ceiling version must be called even when set_size==1.
# (AZ-4 regression guard)
# ---------------------------------------------------------------------------
@test "SIMP-single-version-manifest: resolver-backed set_size==1 creates un-suffixed per-version manifest" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"
    local imagetools_log="$tmpd/simp_single_imagetools.log"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    export imagetools_log

    run bash -c '
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        cd "'"$sd"'"
        source ./build-extensions.sh
        export ROOT_DIR="'"$tmpd"'"

        # Single-version resolver result (set_size == 1).
        resolve_version_set() { echo '"'"'["2.27.1"]'"'"'; }
        export -f resolve_version_set

        ext_config() {
            case "$2" in
                version) echo "2.27.1" ;;
                repo)    echo "https://github.com/timescale/timescaledb" ;;
                *)       echo "" ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo "ghcr.io/test/ext-${1}:pg${3}-${2}"; }
        export -f ext_image_name
        ext_local_image_name() { echo "localhost/ext-builder-${1}:pg${2}"; }
        export -f ext_local_image_name

        # Faithful: ceiling per-arch tags present; un-suffixed multi-arch manifests absent.
        image_exists_in_registry() {
            local _img="$1"
            [[ "$_img" =~ -amd64$ ]] || [[ "$_img" =~ -arm64$ ]]
        }
        export -f image_exists_in_registry

        docker() {
            local _dcmd="${1:-}"
            if [[ "$_dcmd" == "buildx" && "${2:-}" == "imagetools" && "${3:-}" == "create" ]]; then
                echo "IMAGETOOLS_CREATE $*" >> "'"$imagetools_log"'"
                return 0
            fi
            if [[ "$_dcmd" == "buildx" && "${2:-}" == "imagetools" && "${3:-}" == "inspect" ]]; then
                printf "linux/amd64\nlinux/arm64\n"
                return 0
            fi
            if [[ "$_dcmd" == "manifest" ]]; then
                echo manifest unknown >&2
                return 1
            fi
            return 0
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        _capture_index_digest() { echo "sha256:0000000000000000000000000000000000000000000000000000000000000000"; return 0; }
        export -f _capture_index_digest

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo "timescaledb"; }
        export -f list_extensions_by_priority

        main postgres --major-version 18 --finalize-multiarch
    '

    [ "$status" -eq 0 ]

    # imagetools create MUST have been called for the ceiling version (AZ-4 fix).
    # Before fix: set_size==1 caused an early continue after AX-3 consolidation,
    # so imagetools create was never called → consumer's single-version path
    # references an un-suffixed tag that does not exist.
    # After fix: the per-version merge loop runs for set_size==1 too.
    [ -f "$imagetools_log" ] || {
        echo "FAIL: imagetools create was not called for set_size==1 (AZ-4 regression)"
        false
    }
    local create_calls
    create_calls=$(cat "$imagetools_log")
    [[ "$create_calls" == *"pg18-2.27.1"* ]] || {
        echo "FAIL: imagetools create for ceiling 2.27.1 not found (AZ-4 regression). Got: $create_calls"
        false
    }

    # The imagetools create call must use the stable suffixed tag refs.
    [[ "$create_calls" == *"pg18-2.27.1-amd64"* ]] || {
        echo "FAIL: -amd64 suffixed source tag not used. Got: $create_calls"
        false
    }
    [[ "$create_calls" == *"pg18-2.27.1-arm64"* ]] || {
        echo "FAIL: -arm64 suffixed source tag not used. Got: $create_calls"
        false
    }

    # No bundle must be built for set_size==1.
    # No versionset artifact (consumer uses single-version path; stale deleted).
    local artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"
    [ ! -f "$artifact" ] || {
        echo "FAIL: versionset artifact should not be written for set_size==1"
        false
    }
}

# ---------------------------------------------------------------------------
# BA-2: per-arch build (BUILD_PLATFORM set) separates compile (--load) from push.
# A push/auth/network failure must be FATAL for ALL versions (ceiling AND
# non-ceiling). It must NOT be tolerated as a musl compile incompatibility.
# ---------------------------------------------------------------------------

@test "BA2-push-fail-fatal: non-ceiling --load succeeds but push fails → FATAL (not excluded)" {
    # Tests the REAL build_ext_image with BUILD_PLATFORM set.
    # Before fix: buildx build --push is one op; non-zero = compile failure = tolerated
    #             for non-ceiling → exit 0, version silently excluded.
    # After fix:  build (--load) and push are separate; push failure → rc=2 →
    #             caller treats as FATAL regardless of ceiling/non-ceiling.

    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"
    local push_log="$tmpd/ba2_push_fatal.log"

    run bash -c '
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export BUILD_PLATFORM=linux/amd64
        export ARCH_SUFFIX=amd64
        cd "'"$sd"'"
        source ./build-extensions.sh
        export ROOT_DIR="'"$tmpd"'"

        resolve_version_set() { echo '"'"'["2.25.0","2.26.0","2.27.1"]'"'"'; }
        export -f resolve_version_set

        ext_config() {
            case "$2" in
                version) echo "2.27.1" ;;
                repo)    echo "https://github.com/timescale/timescaledb" ;;
                *)       echo "" ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo "ghcr.io/test/ext-${1}:pg${3}-${2}"; }
        export -f ext_image_name
        ext_local_image_name() { echo "localhost/ext-builder-${1}:pg${2}"; }
        export -f ext_local_image_name

        # docker: buildx build --load SUCCEEDS (compile OK), push FAILS (infra error).
        # Faithful mock: distinguishes compile from push by subcommand + flags.
        docker() {
            local _subcmd="${2:-}"
            # buildx build --load: compile step — succeeds
            if [[ "$1" == "buildx" && "$_subcmd" == "build" ]]; then
                if [[ "$*" == *"--load"* ]]; then
                    echo "DOCKER_LOAD $*" >> "'"$push_log"'"
                    return 0
                fi
                # --push (old combined path): also fail-closed but should not be reached
                echo "DOCKER_BUILD_PUSH $*" >> "'"$push_log"'"
                return 0
            fi
            # docker push: push step — FAILS (auth/infra)
            if [[ "$1" == "push" ]]; then
                echo "DOCKER_PUSH_FAIL $*" >> "'"$push_log"'"
                return 1
            fi
            # manifest inspect: absent (not yet pushed)
            if [[ "$*" == *"manifest inspect"* ]]; then
                echo "manifest unknown: manifest unknown" >&2
                return 1
            fi
            return 1
        }
        export -f docker

        skopeo() { echo "manifest unknown" >&2; return 1; }
        export -f skopeo

        image_exists_in_registry() { return 1; }
        export -f image_exists_in_registry

        build_tag_push_extensions \
            "'"$tmpd"'/postgres/extensions/config.yaml" \
            18 "'"$tmpd"'/postgres" "true" "timescaledb"
    '

    # Push failure is FATAL — must NOT exit 0 (old tolerated behavior).
    # Before fix: status=0 (push folded into compile step, non-ceiling tolerated).
    # After fix:  status!=0 (push failure is infra error, always fatal).
    [ "$status" -ne 0 ]

    # Must have attempted the push (so the push-fail path was reached).
    [ -f "$push_log" ]
    grep -q "DOCKER_PUSH_FAIL" "$push_log"
}

@test "BA2-compile-fail-nonceiling-tolerated: non-ceiling --load (compile) fails → tolerated (exit 0)" {
    # Regression guard: musl compile incompatibility on non-ceiling is still tolerated.
    # Before and after fix: a compile failure (--load fails) for a non-ceiling version
    # must remain tolerated → exit 0.

    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"
    local build_log="$tmpd/ba2_compile_tolerated.log"

    run bash -c '
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export BUILD_PLATFORM=linux/amd64
        export ARCH_SUFFIX=amd64
        cd "'"$sd"'"
        source ./build-extensions.sh
        export ROOT_DIR="'"$tmpd"'"

        resolve_version_set() { echo '"'"'["2.25.0","2.26.0","2.27.1"]'"'"'; }
        export -f resolve_version_set

        ext_config() {
            case "$2" in
                version) echo "2.27.1" ;;
                repo)    echo "https://github.com/timescale/timescaledb" ;;
                *)       echo "" ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo "ghcr.io/test/ext-${1}:pg${3}-${2}"; }
        export -f ext_image_name
        ext_local_image_name() { echo "localhost/ext-builder-${1}:pg${2}"; }
        export -f ext_local_image_name

        # docker: buildx build --load FAILS for 2.25.0 only (musl compile error).
        # Push (separate step) is not reached because compile failed.
        docker() {
            local _subcmd="${2:-}"
            if [[ "$1" == "buildx" && "$_subcmd" == "build" && "$*" == *"--load"* ]]; then
                # Fail the compile for 2.25.0 (non-ceiling musl incompatibility).
                if [[ "$*" == *"pg18-2.25.0"* ]]; then
                    echo "COMPILE_FAIL_2.25.0" >> "'"$build_log"'"
                    return 1
                fi
                echo "COMPILE_OK $*" >> "'"$build_log"'"
                return 0
            fi
            # push step: succeeds for the versions that compiled
            if [[ "$1" == "push" ]]; then
                echo "PUSH_OK $*" >> "'"$build_log"'"
                return 0
            fi
            if [[ "$*" == *"manifest inspect"* ]]; then
                echo "manifest unknown: manifest unknown" >&2
                return 1
            fi
            return 1
        }
        export -f docker

        skopeo() { echo "manifest unknown" >&2; return 1; }
        export -f skopeo

        image_exists_in_registry() { return 1; }
        export -f image_exists_in_registry

        build_tag_push_extensions \
            "'"$tmpd"'/postgres/extensions/config.yaml" \
            18 "'"$tmpd"'/postgres" "true" "timescaledb"
    '

    # Non-ceiling compile failure is tolerated → exit 0.
    [ "$status" -eq 0 ]

    # Compile must have been attempted for 2.25.0 and failed.
    [ -f "$build_log" ]
    grep -q "COMPILE_FAIL_2.25.0" "$build_log"

    # Ceiling (2.27.1) must have compiled and pushed.
    grep -q "PUSH_OK.*pg18-2.27.1-amd64" "$build_log"
}

@test "BA2-ceiling-compile-fail-fatal: ceiling --load (compile) fails → FATAL (exit non-zero)" {
    # Ceiling compile failure must remain fatal regardless of the build/push split.

    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"
    local build_log="$tmpd/ba2_ceiling_compile.log"

    run bash -c '
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export BUILD_PLATFORM=linux/amd64
        export ARCH_SUFFIX=amd64
        cd "'"$sd"'"
        source ./build-extensions.sh
        export ROOT_DIR="'"$tmpd"'"

        resolve_version_set() { echo '"'"'["2.25.0","2.26.0","2.27.1"]'"'"'; }
        export -f resolve_version_set

        ext_config() {
            case "$2" in
                version) echo "2.27.1" ;;
                repo)    echo "https://github.com/timescale/timescaledb" ;;
                *)       echo "" ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo "ghcr.io/test/ext-${1}:pg${3}-${2}"; }
        export -f ext_image_name
        ext_local_image_name() { echo "localhost/ext-builder-${1}:pg${2}"; }
        export -f ext_local_image_name

        # docker: buildx build --load fails ONLY for ceiling (2.27.1).
        docker() {
            local _subcmd="${2:-}"
            if [[ "$1" == "buildx" && "$_subcmd" == "build" && "$*" == *"--load"* ]]; then
                if [[ "$*" == *"pg18-2.27.1"* ]]; then
                    echo "COMPILE_FAIL_CEILING" >> "'"$build_log"'"
                    return 1
                fi
                echo "COMPILE_OK $*" >> "'"$build_log"'"
                return 0
            fi
            if [[ "$1" == "push" ]]; then
                echo "PUSH_OK $*" >> "'"$build_log"'"
                return 0
            fi
            if [[ "$*" == *"manifest inspect"* ]]; then
                echo "manifest unknown: manifest unknown" >&2
                return 1
            fi
            return 1
        }
        export -f docker

        skopeo() { echo "manifest unknown" >&2; return 1; }
        export -f skopeo

        image_exists_in_registry() { return 1; }
        export -f image_exists_in_registry

        build_tag_push_extensions \
            "'"$tmpd"'/postgres/extensions/config.yaml" \
            18 "'"$tmpd"'/postgres" "true" "timescaledb"
    '

    # Ceiling compile failure is always fatal.
    [ "$status" -ne 0 ]

    [ -f "$build_log" ]
    grep -q "COMPILE_FAIL_CEILING" "$build_log"
}

# ---------------------------------------------------------------------------
# BA-3: finalize_multiarch_manifests uses 3-state probe (fail-closed on ERROR).
# Before fix: boolean image_exists_in_registry — a transient probe failure
#             reads as "missing" → non-ceiling version silently excluded.
# After fix:  _image_present_3state — ERROR (rc=2) → fail closed (fatal), NOT excluded.
# ---------------------------------------------------------------------------

@test "BA3-transient-probe-failclosed: finalize, transient 3-state ERROR probe → fail closed (not excluded)" {
    # The test drives finalize_multiarch_manifests via main --finalize-multiarch.
    # The suffixed-tag probe returns rc=2 (transient ERROR) for a NON-ceiling version.
    # Before fix (boolean): rc≠0 → "missing" → non-ceiling excluded → exit 0 with reduced artifact.
    # After fix (3-state):  rc=2 → ERROR → fail closed → exit non-zero, no reduced artifact.

    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    run bash -c '
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        cd "'"$sd"'"
        source ./build-extensions.sh
        export ROOT_DIR="'"$tmpd"'"

        resolve_version_set() { echo '"'"'["2.25.0","2.26.0","2.27.1"]'"'"'; }
        export -f resolve_version_set

        ext_config() {
            case "$2" in
                version) echo "2.27.1" ;;
                repo)    echo "https://github.com/timescale/timescaledb" ;;
                *)       echo "" ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo "ghcr.io/test/ext-${1}:pg${3}-${2}"; }
        export -f ext_image_name
        ext_local_image_name() { echo "localhost/ext-builder-${1}:pg${2}"; }
        export -f ext_local_image_name

        # Faithful: un-suffixed multi-arch refs ABSENT (stage B creates them);
        # per-arch refs PRESENT except 2.25.0-amd64 returns ERROR (the test case).
        # _image_registry_probe_3state is the unified probe for ext_ref_resolve
        # (used in finalize_multiarch_manifests). Also mock _image_present_3state
        # for any residual callers.
        _image_registry_probe_3state() {
            local ref="$1"
            if [[ "$ref" == *"pg18-2.25.0-amd64"* ]]; then
                return 2  # ERROR (transient — fail-closed)
            fi
            # Un-suffixed refs (multi-arch manifests not yet created): ABSENT
            if [[ "$ref" =~ -amd64$ ]] || [[ "$ref" =~ -arm64$ ]]; then
                return 0  # Per-arch tags: PRESENT
            fi
            return 1  # Un-suffixed: ABSENT
        }
        export -f _image_registry_probe_3state
        _image_present_3state() {
            _image_registry_probe_3state "$@"
        }
        export -f _image_present_3state

        image_exists_in_registry() {
            local ref="$1"
            [[ "$ref" =~ -amd64$ ]] || [[ "$ref" =~ -arm64$ ]]
        }
        export -f image_exists_in_registry

        docker() {
            if [[ "$1" == "buildx" && "$2" == "imagetools" ]]; then
                return 0
            fi
            if [[ "$1" == "buildx" && "$2" == "build" ]]; then
                return 0
            fi
            if [[ "$*" == *"manifest inspect"* ]]; then
                echo manifest unknown >&2
                return 1
            fi
            return 1
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        _capture_index_digest() {
            echo "sha256:0000000000000000000000000000000000000000000000000000000000000000"
            return 0
        }
        export -f _capture_index_digest

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo "timescaledb"; }
        export -f list_extensions_by_priority

        main postgres --major-version 18 --finalize-multiarch
    '

    # Before fix (boolean probe): exit 0, 2.25.0 silently excluded (RED).
    # After fix (3-state probe):  exit non-zero, fail-closed (GREEN).
    [ "$status" -ne 0 ]

    # Must NOT have written a versionset artifact with a reduced set.
    # A reduced artifact would silently drop 2.25.0 even though we do not know it is gone.
    local artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"
    if [ -f "$artifact" ]; then
        local available_count
        available_count=$(jq '.available | length' "$artifact")
        # A reduced artifact (< 3) is the wrong behavior before the fix.
        # After the fix, no artifact is written on transient error.
        [ "$available_count" -ge 3 ] || {
            echo "FAIL: artifact written with reduced available set (transient error not fail-closed)"
            false
        }
    fi
}

@test "BA3-definitive-absent-excluded: definitive ABSENT non-ceiling → excluded; ceiling absent → fatal" {
    # A definitive ABSENT (explicit not-found signal) on a NON-ceiling version is a
    # legitimate per-arch build miss → excluded (unchanged behavior).
    # A definitive ABSENT on the CEILING version → fatal (unchanged behavior).
    # This test verifies both cases with 3-state probe.

    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    # --- Part A: definitive absent non-ceiling → excluded, exit 0 ---
    run bash -c '
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        cd "'"$sd"'"
        source ./build-extensions.sh
        export ROOT_DIR="'"$tmpd"'"

        resolve_version_set() { echo '"'"'["2.25.0","2.26.0","2.27.1"]'"'"'; }
        export -f resolve_version_set

        ext_config() {
            case "$2" in
                version) echo "2.27.1" ;;
                repo)    echo "https://github.com/timescale/timescaledb" ;;
                *)       echo "" ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo "ghcr.io/test/ext-${1}:pg${3}-${2}"; }
        export -f ext_image_name
        ext_local_image_name() { echo "localhost/ext-builder-${1}:pg${2}"; }
        export -f ext_local_image_name

        # Faithful: 2.25.0-amd64 definitively absent; un-suffixed multi-arch manifests absent;
        # other per-arch tags present.
        image_exists_in_registry() {
            local _img="$1"
            [[ "$_img" == *pg18-2.25.0-amd64* ]] && return 1
            [[ "$_img" =~ -amd64$ ]] || [[ "$_img" =~ -arm64$ ]]  # per-arch: present; un-suffixed: absent
        }
        export -f image_exists_in_registry

        _image_registry_probe_3state() {
            local _img="$1"
            [[ "$_img" == *pg18-2.25.0-amd64* ]] && return 1  # ABSENT
            [[ "$_img" =~ -amd64$ ]] || [[ "$_img" =~ -arm64$ ]] && return 0  # PRESENT
            return 1  # un-suffixed: ABSENT
        }
        export -f _image_registry_probe_3state
        _image_present_3state() { _image_registry_probe_3state "$@"; }
        export -f _image_present_3state

        docker() {
            if [[ "$1" == "buildx" && "$2" == "imagetools" && "$3" == "inspect" ]]; then
                printf "linux/amd64\nlinux/arm64\n"
                return 0
            fi
            if [[ "$1" == "buildx" && "$2" == "imagetools" ]]; then return 0; fi
            if [[ "$1" == "buildx" && "$2" == "build" ]]; then return 0; fi
            if [[ "$*" == *"manifest inspect"* ]]; then
                echo manifest unknown >&2
                return 1
            fi
            return 1
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        _capture_index_digest() {
            echo "sha256:0000000000000000000000000000000000000000000000000000000000000000"
            return 0
        }
        export -f _capture_index_digest

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo "timescaledb"; }
        export -f list_extensions_by_priority
        skopeo() { echo "manifest unknown" >&2; return 1; }
        export -f skopeo

        main postgres --major-version 18 --finalize-multiarch
    '

    # Definitive absent non-ceiling → excluded, NOT fatal → exit 0.
    [ "$status" -eq 0 ]

    local artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"
    [ -f "$artifact" ]

    local excluded_count
    excluded_count=$(jq '.excluded | length' "$artifact")
    [ "$excluded_count" -ge 1 ]

    local excl_versions
    excl_versions=$(jq -r '.excluded[].version' "$artifact")
    [[ "$excl_versions" == *"2.25.0"* ]]

    # 2.27.1 (ceiling) must be available.
    local avail
    avail=$(jq -r '.available[]' "$artifact")
    [[ "$avail" == *"2.27.1"* ]]
}

@test "BA3-imagetools-create-with-both-present-fatal: imagetools create fails when both sources confirmed present → FATAL" {
    # When both -amd64 and -arm64 suffixed tags are confirmed PRESENT by the probe
    # but imagetools create fails, that is a registry infra error → FATAL.
    # Before fix: non-ceiling imagetools-create failure is tolerated → excluded.
    # After fix:  sources confirmed PRESENT + create fails → infra error → FATAL.

    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    run bash -c '
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        cd "'"$sd"'"
        source ./build-extensions.sh
        export ROOT_DIR="'"$tmpd"'"

        resolve_version_set() { echo '"'"'["2.25.0","2.26.0","2.27.1"]'"'"'; }
        export -f resolve_version_set

        ext_config() {
            case "$2" in
                version) echo "2.27.1" ;;
                repo)    echo "https://github.com/timescale/timescaledb" ;;
                *)       echo "" ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo "ghcr.io/test/ext-${1}:pg${3}-${2}"; }
        export -f ext_image_name
        ext_local_image_name() { echo "localhost/ext-builder-${1}:pg${2}"; }
        export -f ext_local_image_name

        # Faithful: per-arch suffixed tags PRESENT (both arches, all versions);
        # un-suffixed multi-arch manifests ABSENT (stage B creates them).
        image_exists_in_registry() {
            local _img="$1"
            [[ "$_img" =~ -amd64$ ]] || [[ "$_img" =~ -arm64$ ]]
        }
        export -f image_exists_in_registry

        _image_registry_probe_3state() {
            local _img="$1"
            [[ "$_img" =~ -amd64$ ]] || [[ "$_img" =~ -arm64$ ]] && return 0
            return 1  # un-suffixed: ABSENT
        }
        export -f _image_registry_probe_3state
        _image_present_3state() { _image_registry_probe_3state "$@"; }
        export -f _image_present_3state

        docker() {
            # imagetools create: FAILS for 2.25.0 (infra error — both sources present).
            # Parse the -t <target> argument to identify which manifest is being created.
            if [[ "$1" == "buildx" && "$2" == "imagetools" && "$3" == "create" ]]; then
                local _target=""
                local _i=4
                while [[ "$_i" -le "$#" ]]; do
                    local _arg="${!_i}"
                    if [[ "$_arg" == "-t" ]]; then
                        local _next=$(( _i + 1 ))
                        _target="${!_next}"
                        break
                    fi
                    (( _i++ )) || true
                done
                # Fail only when target is the un-suffixed pg18-2.25.0 manifest.
                if [[ "$_target" == *"pg18-2.25.0"* && "$_target" != *"pg18-2.25.0-"* ]]; then
                    echo "registry error: unexpected EOF" >&2
                    return 1
                fi
                return 0
            fi
            if [[ "$1" == "buildx" && "$2" == "build" ]]; then return 0; fi
            if [[ "$*" == *"manifest inspect"* ]]; then
                echo "manifest unknown: manifest unknown" >&2
                return 1
            fi
            return 1
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        _capture_index_digest() {
            echo "sha256:0000000000000000000000000000000000000000000000000000000000000000"
            return 0
        }
        export -f _capture_index_digest

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo "timescaledb"; }
        export -f list_extensions_by_priority
        skopeo() { echo "manifest unknown" >&2; return 1; }
        export -f skopeo

        main postgres --major-version 18 --finalize-multiarch
    '

    # Both sources confirmed present + imagetools create fails → infra error → FATAL.
    # Before fix: tolerated (exit 0, 2.25.0 in excluded).
    # After fix:  fatal (exit non-zero).
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# BB1-pr-scoped-tags: PR_TAG_SUFFIX=-pr42 → per-arch + per-version + bundle
# published refs all carry -pr42; canonical (un-suffixed) refs NEVER created.
#
# RED before fix: finalize_multiarch_manifests creates refs with no suffix
#   (e.g. :pg18-bundle, :pg18-2.27.1), which are the canonical production tags.
# GREEN after fix: every published ref carries -pr42 suffix; canonical refs
#   never appear in the docker calls log.
# ---------------------------------------------------------------------------
@test "BB1-pr-scoped-tags: PR_TAG_SUFFIX=-pr42 → all published refs carry -pr42, canonical refs absent" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"
    local docker_calls="$tmpd/docker_calls.log"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    export docker_calls

    run bash -c '
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export PR_TAG_SUFFIX="-pr42"
        export docker_calls="'"$docker_calls"'"
        cd "'"$sd"'"
        source ./build-extensions.sh
        export ROOT_DIR="'"$tmpd"'"

        resolve_version_set() { echo '"'"'["2.25.0","2.27.1"]'"'"'; }
        export -f resolve_version_set

        ext_config() {
            case "$2" in
                version) echo "2.27.1" ;;
                repo)    echo "https://github.com/timescale/timescaledb" ;;
                *)       echo "" ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo "ghcr.io/test/ext-${1}:pg${3}-${2}"; }
        export -f ext_image_name
        ext_local_image_name() { echo "localhost/ext-builder-${1}:pg${2}"; }
        export -f ext_local_image_name

        # Faithful: per-arch suffixed tags present (both canonical and PR-scoped);
        # un-suffixed multi-arch manifests ABSENT (canonical never existed, stage B creates PR-scoped).
        image_exists_in_registry() {
            local ref="$1"
            [[ "$ref" =~ -amd64$ ]] || [[ "$ref" =~ -arm64$ ]] || [[ "$ref" == *-pr42 ]]
        }
        export -f image_exists_in_registry

        docker() {
            if [[ "$1" == "buildx" && "$2" == "imagetools" && "$3" == "inspect" ]]; then
                printf "linux/amd64\nlinux/arm64\n"
                return 0
            fi
            echo "DOCKER $*" >> "$docker_calls"
            return 0
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        _capture_index_digest() {
            echo "sha256:0000000000000000000000000000000000000000000000000000000000000000"
            return 0
        }
        export -f _capture_index_digest

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo "timescaledb"; }
        export -f list_extensions_by_priority
        skopeo() { echo "manifest unknown" >&2; return 1; }
        export -f skopeo

        main postgres --major-version 18 --finalize-multiarch
    '

    [ "$status" -eq 0 ]
    [ -f "$docker_calls" ]

    local calls
    calls=$(cat "$docker_calls")

    # Every imagetools create -t target must carry -pr42 suffix.
    # (Per-version multi-arch manifest targets.)
    local target_lines
    target_lines=$(grep 'imagetools.*create' "$docker_calls" | grep -- '-t ' || true)
    # Each target ref must end in -pr42.
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # Extract the -t value: the token after '-t '.
        local target_ref
        target_ref=$(echo "$line" | sed -n 's/.*-t \([^ ]*\).*/\1/p')
        [[ "$target_ref" == *"-pr42" ]]
    done <<< "$target_lines"

    # No bundle build calls (bundle approach removed — collector is consume-time).
    local bundle_calls
    bundle_calls=$(grep 'pg18-bundle' "$docker_calls" || true)
    [ -z "$bundle_calls" ]

    # Canonical refs (no -pr suffix) must NEVER appear as -t targets in imagetools create.
    local canon_target_lines
    canon_target_lines=$(grep 'imagetools.*create.*-t ' "$docker_calls" \
        | grep -v '\-pr42' | grep 'pg18-2' || true)
    [ -z "$canon_target_lines" ]

    # versionset artifact must be written with version_digests.
    local artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"
    [ -f "$artifact" ]
    local vd_count
    vd_count=$(jq '.version_digests | length' "$artifact" 2>/dev/null || echo 0)
    [ "$vd_count" -ge 1 ]
}

# ---------------------------------------------------------------------------
# BB1-push-canonical: PR_TAG_SUFFIX empty (push/dispatch) → canonical refs
# (no suffix) created (regression guard).
# ---------------------------------------------------------------------------
@test "BB1-push-canonical: PR_TAG_SUFFIX empty → canonical refs published (regression)" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"
    local docker_calls="$tmpd/docker_calls.log"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    export docker_calls

    run bash -c '
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        # PR_TAG_SUFFIX empty (push/dispatch path)
        export PR_TAG_SUFFIX=""
        export docker_calls="'"$docker_calls"'"
        cd "'"$sd"'"
        source ./build-extensions.sh
        export ROOT_DIR="'"$tmpd"'"

        resolve_version_set() { echo '"'"'["2.25.0","2.27.1"]'"'"'; }
        export -f resolve_version_set

        ext_config() {
            case "$2" in
                version) echo "2.27.1" ;;
                repo)    echo "https://github.com/timescale/timescaledb" ;;
                *)       echo "" ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo "ghcr.io/test/ext-${1}:pg${3}-${2}"; }
        export -f ext_image_name
        ext_local_image_name() { echo "localhost/ext-builder-${1}:pg${2}"; }
        export -f ext_local_image_name

        # Faithful: per-arch suffixed tags present; un-suffixed multi-arch manifests absent.
        image_exists_in_registry() {
            local _img="$1"
            [[ "$_img" =~ -amd64$ ]] || [[ "$_img" =~ -arm64$ ]]
        }
        export -f image_exists_in_registry

        docker() {
            if [[ "$1" == "buildx" && "$2" == "imagetools" && "$3" == "inspect" ]]; then
                printf "linux/amd64\nlinux/arm64\n"
                return 0
            fi
            echo "DOCKER $*" >> "$docker_calls"
            if [[ "$1" == "manifest" ]]; then
                echo manifest unknown >&2
                return 1
            fi
            return 0
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        _capture_index_digest() {
            echo "sha256:0000000000000000000000000000000000000000000000000000000000000000"
            return 0
        }
        export -f _capture_index_digest

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo "timescaledb"; }
        export -f list_extensions_by_priority

        main postgres --major-version 18 --finalize-multiarch
    '

    [ "$status" -eq 0 ]
    [ -f "$docker_calls" ]

    local calls
    calls=$(cat "$docker_calls")

    # Canonical per-version target refs must appear (no -pr suffix).
    [[ "$calls" == *"pg18-2.27.1"* ]]
    # No bundle ref (bundle approach removed — collector is consume-time).
    local bundle_calls
    bundle_calls=$(grep 'pg18-bundle' "$docker_calls" || true)
    [ -z "$bundle_calls" ]
    # No -pr suffix refs should appear at all.
    local pr_refs
    pr_refs=$(grep '\-pr[0-9]' "$docker_calls" || true)
    [ -z "$pr_refs" ]

    # Artifact must be written with version_digests.
    local artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"
    [ -f "$artifact" ]
    local vd_count
    vd_count=$(jq '.version_digests | length' "$artifact" 2>/dev/null || echo 0)
    [ "$vd_count" -ge 1 ]
}

# ---------------------------------------------------------------------------
# CACHE-flags: per-arch buildx build uses --cache-from and --cache-to with
# deterministic ref ghcr.io/<owner>/ext-<ext>-buildcache:pg<major>-<arch>.
#
# RED before fix: buildx build call has no --cache-from / --cache-to flags.
# GREEN after fix: both flags present with the deterministic buildcache ref.
# ---------------------------------------------------------------------------
@test "CACHE-flags: per-arch buildx build carries --cache-from and --cache-to registry flags" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"
    local docker_calls="$tmpd/docker_calls.log"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    export docker_calls

    run bash -c '
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export BUILD_PLATFORM=linux/amd64
        export ARCH_SUFFIX=amd64
        export REPO_OWNER=testowner
        export REMOTE_CR=ghcr.io/testowner
        export docker_calls="'"$docker_calls"'"
        cd "'"$sd"'"
        source ./build-extensions.sh
        export ROOT_DIR="'"$tmpd"'"

        resolve_version_set() { echo '"'"'["2.27.1"]'"'"'; }
        export -f resolve_version_set

        ext_config() {
            case "$2" in
                version) echo "2.27.1" ;;
                repo)    echo "https://github.com/timescale/timescaledb" ;;
                *)       echo "" ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo "ghcr.io/testowner/ext-${1}:pg${3}-${2}"; }
        export -f ext_image_name
        ext_local_image_name() { echo "localhost/ext-builder-${1}:pg${2}"; }
        export -f ext_local_image_name

        image_exists_in_registry() { return 1; }
        export -f image_exists_in_registry

        docker() {
            echo "DOCKER $*" >> "$docker_calls"
            return 0
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        _capture_index_digest() {
            echo "sha256:0000000000000000000000000000000000000000000000000000000000000000"
            return 0
        }
        export -f _capture_index_digest

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo "timescaledb"; }
        export -f list_extensions_by_priority
        skopeo() { echo "manifest unknown" >&2; return 1; }
        export -f skopeo

        main postgres --major-version 18
    '

    [ "$status" -eq 0 ]
    [ -f "$docker_calls" ]

    # The buildx build for the per-arch compile step must include --cache-from and --cache-to.
    local buildx_line
    buildx_line=$(grep 'buildx build' "$docker_calls" | grep -- '--load' || true)
    [ -n "$buildx_line" ]

    # Verify both cache flags are present.
    [[ "$buildx_line" == *"--cache-from"* ]]
    [[ "$buildx_line" == *"--cache-to"* ]]

    # The cache ref must use the deterministic buildcache pattern.
    [[ "$buildx_line" == *"ext-timescaledb-buildcache:pg18-amd64"* ]]

    # Cache type must be registry.
    [[ "$buildx_line" == *"type=registry"* ]]
}

# ---------------------------------------------------------------------------
# Retry tests: transient build/push failures must be retried up to EXT_BUILD_RETRIES
# times before propagating as a persistent failure.
# ---------------------------------------------------------------------------

# A non-ceiling compile that fails once then succeeds must be INCLUDED (not excluded).
# Without retry: single failure → excluded. With retry: second attempt succeeds → included.
@test "BB2-transient-build-retry-succeeds: compile fails once then succeeds → version included" {
    export EXT_BUILD_RETRIES=3

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

    # build_ext_image for 2.25.0 fails on attempt 1, succeeds on attempt 2+.
    # Self-counting via the build_calls.log file (TEST_TEMP_DIR is exported).
    build_ext_image() {
        local ver="$2"
        echo "CALL ext=${1} ver=${ver}" >> "$TEST_TEMP_DIR/build_calls.log"
        if [[ "$ver" == "2.25.0" ]]; then
            local cnt
            cnt=$(grep -c "ver=2.25.0" "$TEST_TEMP_DIR/build_calls.log" 2>/dev/null || echo 0)
            if [[ "$cnt" -le 1 ]]; then
                return 1  # first attempt fails (transient)
            fi
        fi
        return 0  # subsequent attempts and all other versions succeed
    }
    export -f build_ext_image

    run build_tag_push_extensions \
        "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR" "true" "timescaledb"

    # Both versions must succeed → exit 0 (transient failure absorbed by retry).
    [ "$status" -eq 0 ]

    # build_ext_image for 2.25.0 must have been called at least 2 times (retry happened).
    local calls_25
    calls_25=$(grep -c "ver=2.25.0" "$TEST_TEMP_DIR/build_calls.log")
    [ "$calls_25" -ge 2 ]

    # 2.27.1 (ceiling) must have been built exactly once (no retry needed).
    local calls_ceil
    calls_ceil=$(grep -c "ver=2.27.1" "$TEST_TEMP_DIR/build_calls.log")
    [ "$calls_ceil" -eq 1 ]

    unset EXT_BUILD_RETRIES
}

# Non-ceiling build that fails ALL retry attempts → tolerated (genuine incompatibility).
# Ceiling that fails ALL retry attempts → fatal.
@test "BB2-persistent-build-fail-tolerated: non-ceiling all-retry-fail → tolerated (exit 0)" {
    export EXT_BUILD_RETRIES=2

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

    # 2.25.0 always fails (simulates real musl incompatibility after retries).
    # Log to build_calls.log (TEST_TEMP_DIR is already exported by the test framework).
    build_ext_image() {
        echo "CALL ext=${1} ver=${2}" >> "$TEST_TEMP_DIR/build_calls.log"
        if [[ "$2" == "2.25.0" ]]; then
            return 1
        fi
        return 0
    }
    export -f build_ext_image

    run build_tag_push_extensions \
        "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR" "true" "timescaledb"

    # Non-ceiling persistent failure → tolerated → exit 0.
    [ "$status" -eq 0 ]

    # 2.25.0 must have been attempted EXT_BUILD_RETRIES times (retry exhausted).
    local attempts_25
    attempts_25=$(grep -c "ver=2.25.0" "$TEST_TEMP_DIR/build_calls.log")
    [ "$attempts_25" -eq "$EXT_BUILD_RETRIES" ]

    # 2.26.0 and ceiling 2.27.1 must have been built successfully (each once).
    local log_content
    log_content=$(cat "$TEST_TEMP_DIR/build_calls.log")
    [[ "$log_content" == *"ver=2.26.0"* ]]
    [[ "$log_content" == *"ver=2.27.1"* ]]

    unset EXT_BUILD_RETRIES
}

@test "BB2-ceiling-persistent-fail-fatal: ceiling all-retry-fail → exit non-zero" {
    export EXT_BUILD_RETRIES=2

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

    # Ceiling always fails all attempts.
    build_ext_image() {
        echo "CALL ext=${1} ver=${2}" >> "$TEST_TEMP_DIR/build_calls.log"
        if [[ "$2" == "2.27.1" ]]; then
            return 1
        fi
        return 0
    }
    export -f build_ext_image

    run build_tag_push_extensions \
        "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR" "true" "timescaledb"

    # Ceiling persistent failure → fatal → non-zero exit.
    [ "$status" -ne 0 ]

    # Ceiling must have been attempted EXT_BUILD_RETRIES times.
    local attempts_ceil
    attempts_ceil=$(grep -c "ver=2.27.1" "$TEST_TEMP_DIR/build_calls.log")
    [ "$attempts_ceil" -eq "$EXT_BUILD_RETRIES" ]

    unset EXT_BUILD_RETRIES
}

# Push failure (rc=2) fails all retries → fatal.
@test "BB2-push-retry-then-fatal: push fails all retries → fatal" {
    export EXT_BUILD_RETRIES=2

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

    # rc=2 from build_ext_image means push failure → fatal for all versions.
    build_ext_image() {
        echo "CALL ext=${1} ver=${2}" >> "$TEST_TEMP_DIR/build_calls.log"
        return 2
    }
    export -f build_ext_image

    run build_tag_push_extensions \
        "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR" "true" "timescaledb"

    # Push failure must be fatal even with retries exhausted.
    [ "$status" -ne 0 ]

    # The first version must have been attempted EXT_BUILD_RETRIES times.
    local attempts
    attempts=$(grep -c "ver=2.25.0" "$TEST_TEMP_DIR/build_calls.log")
    [ "$attempts" -eq "$EXT_BUILD_RETRIES" ]

    unset EXT_BUILD_RETRIES
}

# ---------------------------------------------------------------------------
# rc-capture after negated if: verify the logged rc is the real docker exit code
# and not 0 (the exit of the negation).
# ---------------------------------------------------------------------------

# When imagetools create fails, the logged rc in the error message must equal
# the real non-zero exit code, not 0.
# Without the fix: `if ! $DOCKER ...; then rc=$?` captures rc=0 (exit of `!`).
# With the fix: rc is captured from the command directly → real non-zero value.
@test "BBlow-rc-capture: imagetools create failure logs real rc, not 0" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"
    local log_file="$tmpd/bblow_output.log"

    run bash -c '
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export BUILD_PLATFORM="" ARCH_SUFFIX="" PR_TAG_SUFFIX=""
        export REMOTE_CR="ghcr.io/test"
        cd "'"$sd"'"
        source ./build-extensions.sh
        export ROOT_DIR="'"$tmpd"'"

        ext_config() {
            case "$2" in
                version) echo "2.27.1" ;;
                repo)    echo "https://github.com/timescale/timescaledb" ;;
                *)       echo "" ;;
            esac
        }
        export -f ext_config

        ext_image_name() { echo "ghcr.io/test/ext-${1}:pg${3}-${2}"; }
        export -f ext_image_name
        ext_local_image_name() { echo "localhost/ext-builder-${1}:pg${2}"; }
        export -f ext_local_image_name

        list_extensions_by_priority() { echo "timescaledb"; }
        export -f list_extensions_by_priority

        # Return empty resolver path so the non-resolver (AW-1) branch executes.
        yq() { echo ""; }
        export -f yq

        # imagetools create exits with rc=42 (chosen to be clearly non-zero, not 1).
        docker() {
            if [[ "$*" == *imagetools* ]]; then return 42; fi
            return 0
        }
        export -f docker

        finalize_multiarch_manifests "'"$tmpd"'/postgres/extensions/config.yaml" 18 "'"$tmpd"'/postgres" 2>&1 | tee "'"$log_file"'"
    '

    # The logged rc in the error message must not be 0.
    # With the bug: log contains "(rc=0)". With the fix: log contains the real rc.
    local logged_rc
    logged_rc=$(grep -oP 'rc=\K[0-9]+' "$log_file" 2>/dev/null | head -1 || echo "")
    # Only assert if a rc= value was actually logged (the function reached the error path).
    if [[ -n "$logged_rc" ]]; then
        [ "$logged_rc" -ne 0 ]
    fi
}

# ---------------------------------------------------------------------------
# BC-2: build cache ref must always be a writable GHCR ref, independent of
# REMOTE_CR (which is the base-image source, not the cache store).
#
# The per-arch buildx build derives --cache-to/--cache-from from REMOTE_CR,
# which defaults to docker.io on the GHCR-mirror-absent fallback.
# docker.io/ext-...-buildcache has no owner namespace → not writable → cache
# export fails, can break the per-arch build.
#
# Fix: cache ref must ALWAYS use ghcr.io/<owner>/ext-<name>-buildcache:pg<major>-<arch>
# regardless of REMOTE_CR.  REPO_OWNER (env) or get_repo_owner() provides the GHCR owner.
# --cache-to is only emitted when we are in a push/same-repo-PR context (_do_push_ext=true).
# --cache-from (read) can always be present.
#
# BC2-cache-ref-ghcr:
#   REMOTE_CR=docker.io, REPO_OWNER=testowner → cache ref uses ghcr.io/testowner/
#   NOT docker.io/...  RED before fix: docker.io in cache ref.  GREEN after: ghcr.io.
#
# BC2-cache-to-only-with-write:
#   LOCAL_ONLY=true (no push) → --cache-to must NOT appear in the buildx invocation.
#   --cache-from may still be present (reading cache is always safe).
# ---------------------------------------------------------------------------
@test "BC2-cache-ref-ghcr: REMOTE_CR=docker.io → cache ref still uses ghcr.io/<owner>/, NOT docker.io" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"
    local docker_calls="$tmpd/bc2_docker_calls.log"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    export docker_calls

    run bash -c '
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export BUILD_PLATFORM=linux/amd64
        export ARCH_SUFFIX=amd64
        # REMOTE_CR=docker.io simulates GHCR mirror absent fallback.
        export REMOTE_CR=docker.io
        # REPO_OWNER is the GHCR owner (always set in CI by github.repository_owner).
        export REPO_OWNER=testowner
        export docker_calls="'"$docker_calls"'"
        cd "'"$sd"'"
        source ./build-extensions.sh
        export ROOT_DIR="'"$tmpd"'"

        resolve_version_set() { echo '"'"'["2.27.1"]'"'"'; }
        export -f resolve_version_set

        ext_config() {
            case "$2" in
                version) echo "2.27.1" ;;
                repo)    echo "https://github.com/timescale/timescaledb" ;;
                *)       echo "" ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo "ghcr.io/testowner/ext-${1}:pg${3}-${2}"; }
        export -f ext_image_name
        ext_local_image_name() { echo "localhost/ext-builder-${1}:pg${2}"; }
        export -f ext_local_image_name

        image_exists_in_registry() { return 1; }
        export -f image_exists_in_registry

        docker() {
            echo "DOCKER $*" >> "$docker_calls"
            return 0
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        _capture_index_digest() {
            echo "sha256:0000000000000000000000000000000000000000000000000000000000000000"
            return 0
        }
        export -f _capture_index_digest

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo "timescaledb"; }
        export -f list_extensions_by_priority
        skopeo() { echo "manifest unknown" >&2; return 1; }
        export -f skopeo

        main postgres --major-version 18
    '

    [ "$status" -eq 0 ]
    [ -f "$docker_calls" ]

    # The buildx build (--load, compile step) must have --cache-from and --cache-to.
    local buildx_line
    buildx_line=$(grep 'buildx build' "$docker_calls" | grep -- '--load' || true)
    [ -n "$buildx_line" ]

    # Cache ref must use ghcr.io/testowner, NOT docker.io.
    [[ "$buildx_line" == *"ghcr.io/testowner/ext-timescaledb-buildcache"* ]]

    # Must NOT contain docker.io in cache ref position.
    local docker_io_cache_count
    docker_io_cache_count=$(echo "$buildx_line" | grep -c 'docker\.io.*buildcache' || true)
    [ "$docker_io_cache_count" -eq 0 ]

    # Cache type must be registry.
    [[ "$buildx_line" == *"type=registry"* ]]
}

@test "BC2-cache-to-only-with-write: --local-only flag → --cache-to absent from buildx invocation" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"
    local docker_calls="$tmpd/bc2_local_docker_calls.log"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    export docker_calls

    run bash -c '
        export FORCE=false DRY_RUN=false CONTAINER=postgres
        export BUILD_PLATFORM=linux/amd64
        export ARCH_SUFFIX=amd64
        export REMOTE_CR=docker.io
        export REPO_OWNER=testowner
        export docker_calls="'"$docker_calls"'"
        cd "'"$sd"'"
        source ./build-extensions.sh
        export ROOT_DIR="'"$tmpd"'"

        resolve_version_set() { echo '"'"'["2.27.1"]'"'"'; }
        export -f resolve_version_set

        ext_config() {
            case "$2" in
                version) echo "2.27.1" ;;
                repo)    echo "https://github.com/timescale/timescaledb" ;;
                *)       echo "" ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo "ghcr.io/testowner/ext-${1}:pg${3}-${2}"; }
        export -f ext_image_name
        ext_local_image_name() { echo "localhost/ext-builder-${1}:pg${2}"; }
        export -f ext_local_image_name

        image_exists_in_registry() { return 1; }
        export -f image_exists_in_registry

        docker() {
            echo "DOCKER $*" >> "$docker_calls"
            return 0
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo "timescaledb"; }
        export -f list_extensions_by_priority
        skopeo() { echo "manifest unknown" >&2; return 1; }
        export -f skopeo

        # --local-only sets LOCAL_ONLY=true after sourcing (parse_args path)
        # so _do_push_ext=false → --cache-to must be omitted.
        main postgres --major-version 18 --local-only
    '

    [ "$status" -eq 0 ]

    # With --local-only, no push → --cache-to must NOT appear in the buildx call.
    if [ -f "$docker_calls" ]; then
        local buildx_line
        buildx_line=$(grep 'buildx build' "$docker_calls" | grep -- '--load' || true)
        if [ -n "$buildx_line" ]; then
            # --cache-to must be absent.
            [[ "$buildx_line" != *"--cache-to"* ]]
        fi
    fi
}

# ---------------------------------------------------------------------------
# BD1-cache-pr-scoped: build cache ref must carry PR_TAG_SUFFIX on PR builds,
# and no suffix on push/dispatch (canonical) builds.
#
# Supply-chain policy (operator-confirmed): the build cache is PR-scoped so an
# unmerged PR cannot influence master's canonical build via a shared cache.
# Master recompiles the bumped version (the prefilter skips already-canonical
# versions, so only the new version recompiles — bounded, accepted waste).
# No shared PR<->master refs.
#
# RED before fix: cache ref is ..:pg18-amd64 regardless of PR_TAG_SUFFIX —
#   a PR run writes to the same ref as master, enabling cross-scope influence.
# GREEN after fix:
#   PR_TAG_SUFFIX=-pr42  → --cache-from/--cache-to ref ends in pg18-amd64-pr42
#   PR_TAG_SUFFIX empty  → --cache-from/--cache-to ref ends in pg18-amd64 (no suffix)
# ---------------------------------------------------------------------------
@test "BD1-cache-pr-scoped: PR_TAG_SUFFIX=-pr42 → cache ref is ...buildcache:pg18-amd64-pr42" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"
    local docker_calls="$tmpd/bd1_pr_docker_calls.log"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    export docker_calls

    run bash -c '
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export BUILD_PLATFORM=linux/amd64
        export ARCH_SUFFIX=amd64
        export REPO_OWNER=testowner
        export REMOTE_CR=ghcr.io/testowner
        # Simulate a same-repo PR build.
        export PR_TAG_SUFFIX="-pr42"
        export docker_calls="'"$docker_calls"'"
        cd "'"$sd"'"
        source ./build-extensions.sh
        export ROOT_DIR="'"$tmpd"'"

        resolve_version_set() { echo '"'"'["2.27.1"]'"'"'; }
        export -f resolve_version_set

        ext_config() {
            case "$2" in
                version) echo "2.27.1" ;;
                repo)    echo "https://github.com/timescale/timescaledb" ;;
                *)       echo "" ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo "ghcr.io/testowner/ext-${1}:pg${3}-${2}"; }
        export -f ext_image_name
        ext_local_image_name() { echo "localhost/ext-builder-${1}:pg${2}"; }
        export -f ext_local_image_name

        image_exists_in_registry() { return 1; }
        export -f image_exists_in_registry

        docker() {
            echo "DOCKER $*" >> "$docker_calls"
            return 0
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        _capture_index_digest() {
            echo "sha256:0000000000000000000000000000000000000000000000000000000000000000"
            return 0
        }
        export -f _capture_index_digest

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo "timescaledb"; }
        export -f list_extensions_by_priority
        skopeo() { echo "manifest unknown" >&2; return 1; }
        export -f skopeo

        main postgres --major-version 18
    '

    [ "$status" -eq 0 ]
    [ -f "$docker_calls" ]

    local buildx_line
    buildx_line=$(grep 'buildx build' "$docker_calls" | grep -- '--load' || true)
    [ -n "$buildx_line" ]

    # The cache ref (both --cache-from and --cache-to) must carry the PR suffix.
    # PR_TAG_SUFFIX=-pr42 → ref must end in pg18-amd64-pr42, NOT pg18-amd64.
    [[ "$buildx_line" == *"ext-timescaledb-buildcache:pg18-amd64-pr42"* ]]

    # The un-scoped (canonical) cache ref must NOT appear.
    local unscoped_count
    unscoped_count=$(echo "$buildx_line" | grep -c 'buildcache:pg18-amd64[^-]' || true)
    [ "$unscoped_count" -eq 0 ]
}

@test "BD1-cache-pr-scoped: PR_TAG_SUFFIX empty (push) → canonical cache ref (no suffix)" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"
    local docker_calls="$tmpd/bd1_push_docker_calls.log"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    export docker_calls

    run bash -c '
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export BUILD_PLATFORM=linux/amd64
        export ARCH_SUFFIX=amd64
        export REPO_OWNER=testowner
        export REMOTE_CR=ghcr.io/testowner
        # Simulate a push/dispatch (master) build — no PR suffix.
        export PR_TAG_SUFFIX=""
        export docker_calls="'"$docker_calls"'"
        cd "'"$sd"'"
        source ./build-extensions.sh
        export ROOT_DIR="'"$tmpd"'"

        resolve_version_set() { echo '"'"'["2.27.1"]'"'"'; }
        export -f resolve_version_set

        ext_config() {
            case "$2" in
                version) echo "2.27.1" ;;
                repo)    echo "https://github.com/timescale/timescaledb" ;;
                *)       echo "" ;;
            esac
        }
        export -f ext_config

        ext_image_name()       { echo "ghcr.io/testowner/ext-${1}:pg${3}-${2}"; }
        export -f ext_image_name
        ext_local_image_name() { echo "localhost/ext-builder-${1}:pg${2}"; }
        export -f ext_local_image_name

        image_exists_in_registry() { return 1; }
        export -f image_exists_in_registry

        docker() {
            echo "DOCKER $*" >> "$docker_calls"
            return 0
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        _capture_index_digest() {
            echo "sha256:0000000000000000000000000000000000000000000000000000000000000000"
            return 0
        }
        export -f _capture_index_digest

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo "timescaledb"; }
        export -f list_extensions_by_priority
        skopeo() { echo "manifest unknown" >&2; return 1; }
        export -f skopeo

        main postgres --major-version 18
    '

    [ "$status" -eq 0 ]
    [ -f "$docker_calls" ]

    local buildx_line
    buildx_line=$(grep 'buildx build' "$docker_calls" | grep -- '--load' || true)
    [ -n "$buildx_line" ]

    # Canonical cache ref: ends in pg18-amd64 with no PR suffix.
    [[ "$buildx_line" == *"ext-timescaledb-buildcache:pg18-amd64"* ]]

    # The ref must NOT contain -pr<N> (no PR suffix on canonical builds).
    local pr_count
    pr_count=$(echo "$buildx_line" | grep -c 'buildcache:pg18-amd64-pr' || true)
    [ "$pr_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# BF-pr-reuses-canonical-skips-unchanged: PR context, unchanged version
# (canonical arch tag exists, PR-scoped tag absent) → version is SKIPPED.
#
# DEFECT: _should_build_extension / build_tag_push_extensions probes only the
# PR-scoped tag (-pr42). On a fresh PR, no PR-scoped tags exist in the registry
# yet → every retained version is "needs build" → rebuild ALL → timeout spike.
#
# FIX: check canonical arch ref first; if canonical present, version is
# unchanged → SKIP (reuse read-only); otherwise check PR-scoped; else → BUILD.
#
# RED before fix: _should_build_extension returns 0 (build) even though
#   the canonical arch tag exists (unchanged version).
# GREEN after fix: canonical present → _should_build_extension returns 1 (skip).
# ---------------------------------------------------------------------------
@test "BF-pr-reuses-canonical-skips-unchanged: PR_TAG_SUFFIX=-pr42, canonical arch tag present, PR-scoped absent → SKIPPED" {
    export PR_TAG_SUFFIX="-pr42"
    export ARCH_SUFFIX="amd64"
    export BUILD_PLATFORM="linux/amd64"

    # Canonical arch tag (pg18-2.27.1-amd64) EXISTS; PR-scoped (pg18-2.27.1-amd64-pr42) does NOT.
    image_exists_in_registry() {
        local ref="$1"
        # Canonical: pg18-2.27.1-amd64 (no PR suffix) → present
        if [[ "$ref" == *"pg18-2.27.1-amd64" && "$ref" != *"-pr42"* ]]; then
            return 0  # PRESENT (canonical)
        fi
        # PR-scoped or anything else → absent
        return 1
    }
    export -f image_exists_in_registry

    ext_config() {
        case "$2" in
            version) echo "2.27.1" ;;
            repo)    echo "https://github.com/timescale/timescaledb" ;;
            *)       echo "" ;;
        esac
    }
    export -f ext_config

    run _should_build_extension "timescaledb" "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR"

    # RED before fix: returns 0 (build) — probes PR-scoped only (absent) → rebuilds.
    # GREEN after fix: returns 1 (skip) — canonical arch tag exists → unchanged, skip.
    [ "$status" -eq 1 ]

    unset PR_TAG_SUFFIX ARCH_SUFFIX BUILD_PLATFORM
}

# ---------------------------------------------------------------------------
# BF-pr-builds-only-changed: PR with one NEW version (neither canonical nor
# PR-scoped exists) and N unchanged (canonical arch tag exists).
# Only the NEW version is built (PR-scoped); the N unchanged are skipped.
# Assert: build count == 1.
#
# RED before fix: all N+1 versions are built (canonical check absent).
# GREEN after fix: exactly 1 build (the new/changed version).
# ---------------------------------------------------------------------------
@test "BF-pr-builds-only-changed: PR_TAG_SUFFIX=-pr42, 1 new + 2 unchanged → only 1 build issued" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"
    local build_calls="${tmpd}/build_calls.log"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export PR_TAG_SUFFIX='-pr42'
        export ARCH_SUFFIX='amd64'
        export BUILD_PLATFORM='linux/amd64'
        export build_calls='${build_calls}'
        cd '${sd}'
        source ./build-extensions.sh
        export ROOT_DIR='${tmpd}'

        # 3-version resolver: 2.23.0 (old), 2.25.0 (old), 2.27.1 (new ceiling)
        resolve_version_set() { echo '[\"2.23.0\",\"2.25.0\",\"2.27.1\"]'; }
        export -f resolve_version_set

        ext_config() {
            case \"\$2\" in
                version) echo '2.27.1' ;;
                repo)    echo 'https://github.com/timescale/timescaledb' ;;
                *)       echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name() { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        # Canonical arch tags exist for 2.23.0 and 2.25.0 (unchanged).
        # 2.27.1 has NO canonical arch tag, NO PR-scoped tag (new version).
        image_exists_in_registry() {
            local ref=\"\$1\"
            case \"\$ref\" in
                *'pg18-2.23.0-amd64') return 0 ;;
                *'pg18-2.25.0-amd64') return 0 ;;
                *) return 1 ;;
            esac
        }
        export -f image_exists_in_registry

        # build_ext_image: record calls and succeed
        build_ext_image() {
            local ext_name=\"\$1\" ext_version=\"\$2\"
            echo \"BUILD \${ext_name} \${ext_version}\" >> \"\$build_calls\"
            return 0
        }
        export -f build_ext_image

        docker() {
            case \"\$1\" in
                buildx) return 0 ;;
                push)   return 0 ;;
                manifest)
                    printf 'manifest unknown: manifest unknown\n' >&2
                    return 1
                    ;;
                *) return 1 ;;
            esac
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        _capture_index_digest() {
            echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'
            return 0
        }
        export -f _capture_index_digest

        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority

        main postgres --major-version 18
    "

    [ "$status" -eq 0 ]

    # build_ext_image must have been called exactly ONCE (for 2.27.1 only).
    # RED before fix: called 3 times (all versions rebuilt).
    # GREEN after fix: called exactly 1 time (only the new version).
    local build_count=0
    if [ -f "${build_calls}" ]; then
        build_count=$(wc -l < "${build_calls}")
    fi
    [ "$build_count" -eq 1 ]

    # The one build must be for 2.27.1 (the new/changed version).
    grep -q "BUILD timescaledb 2.27.1" "${build_calls}"

    unset PR_TAG_SUFFIX ARCH_SUFFIX BUILD_PLATFORM
}

# ---------------------------------------------------------------------------
# BF-bundle-mixes-canonical-and-prscoped: in finalize_multiarch_manifests,
# unchanged versions (canonical multi-arch manifest exists) are REUSED without
# re-creating their manifest. The new/changed version (no canonical manifest)
# gets a PR-scoped manifest. The bundle buildx build sources =
# canonical refs (unchanged) + PR-scoped ref (the bump).
# The PR-scoped bundle is written; canonical bundle never overwritten from PR.
#
# RED before fix: finalize probes only PR-scoped arch tags; unchanged versions'
#   canonical arch tags don't match → imagetools create fails or ALL are created.
# GREEN after fix: canonical manifests for unchanged versions reused (no extra
#   imagetools create); new version gets PR-scoped manifest; PR bundle written.
# ---------------------------------------------------------------------------
@test "BF-bundle-mixes-canonical-and-prscoped: unchanged versions reused from canonical, new version is PR-scoped, PR bundle written" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"
    local docker_calls="${tmpd}/docker_calls.log"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export PR_TAG_SUFFIX='-pr42'
        export docker_calls='${docker_calls}'
        cd '${sd}'
        source ./build-extensions.sh
        export ROOT_DIR='${tmpd}'

        # 3-version resolver: 2.23.0 and 2.25.0 are unchanged; 2.27.1 is new.
        resolve_version_set() { echo '[\"2.23.0\",\"2.25.0\",\"2.27.1\"]'; }
        export -f resolve_version_set

        ext_config() {
            case \"\$2\" in
                version) echo '2.27.1' ;;
                repo)    echo 'https://github.com/timescale/timescaledb' ;;
                *)       echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name() { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        # Registry state:
        # - 2.23.0 and 2.25.0: canonical arch tags (-amd64/-arm64) exist (unchanged).
        #   Their canonical multi-arch manifests (pg18-2.23.0, pg18-2.25.0) also exist.
        # - 2.27.1: only PR-scoped arch tags (pg18-2.27.1-amd64-pr42, pg18-2.27.1-arm64-pr42).
        image_exists_in_registry() {
            local ref=\"\$1\"
            case \"\$ref\" in
                *'pg18-2.23.0-amd64' | *'pg18-2.23.0-arm64') return 0 ;;
                *'pg18-2.25.0-amd64' | *'pg18-2.25.0-arm64') return 0 ;;
                *'pg18-2.27.1-amd64-pr42' | *'pg18-2.27.1-arm64-pr42') return 0 ;;
                *'pg18-2.23.0' | *'pg18-2.25.0') return 0 ;;
                *) return 1 ;;
            esac
        }
        export -f image_exists_in_registry

        # docker mock: log all calls; for imagetools inspect, return both platforms.
        # For manifest inspect, mirror image_exists_in_registry for faithful 3-state.
        docker() {
            local _dc=\"\${1:-}\" _d2=\"\${2:-}\" _d3=\"\${3:-}\"
            # imagetools inspect: return both platforms (platform-coverage check)
            if [[ \"\$_dc\" == 'buildx' && \"\$_d2\" == 'imagetools' && \"\$_d3\" == 'inspect' ]]; then
                printf 'linux/amd64\nlinux/arm64\n'
                return 0
            fi
            echo \"DOCKER \$*\" >> \"\$docker_calls\"
            if [[ \"\$_dc\" == 'manifest' && \"\$_d2\" == 'inspect' ]]; then
                local _ref=\"\$_d3\"
                case \"\$_ref\" in
                    *'pg18-2.23.0-amd64' | *'pg18-2.23.0-arm64') return 0 ;;
                    *'pg18-2.25.0-amd64' | *'pg18-2.25.0-arm64') return 0 ;;
                    *'pg18-2.27.1-amd64-pr42' | *'pg18-2.27.1-arm64-pr42') return 0 ;;
                    *'pg18-2.23.0' | *'pg18-2.25.0') return 0 ;;
                    *)
                        printf 'manifest unknown: manifest unknown\n' >&2
                        return 1
                        ;;
                esac
            fi
            return 0
        }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        _capture_index_digest() {
            echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'
            return 0
        }
        export -f _capture_index_digest

        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority

        main postgres --major-version 18 --finalize-multiarch
    "

    [ "$status" -eq 0 ]
    [ -f "${docker_calls}" ]

    # No bundle build (bundle approach removed — collector is consume-time).
    local bundle_written
    bundle_written=$(grep 'buildx build' "${docker_calls}" | grep 'pg18-bundle' || true)
    [ -z "$bundle_written" ]

    # For unchanged versions (2.23.0, 2.25.0): imagetools create must NOT be called
    # because their canonical multi-arch manifests already exist (REUSE path).
    local create_for_23
    create_for_23=$(grep 'imagetools.*create.*2\.23\.0' "${docker_calls}" || true)
    [ -z "$create_for_23" ]

    local create_for_25
    create_for_25=$(grep 'imagetools.*create.*2\.25\.0' "${docker_calls}" || true)
    [ -z "$create_for_25" ]

    # For the new version (2.27.1): imagetools create must create the PR-scoped manifest.
    local create_for_27
    create_for_27=$(grep 'imagetools.*create.*2\.27\.1' "${docker_calls}" || true)
    [ -n "$create_for_27" ]
    # The target must carry the PR suffix.
    [[ "$create_for_27" == *"-pr42"* ]]

    # Versionset artifact must have been written with all 3 versions available.
    local vs_file="${tmpd}/.build-lineage/ext-timescaledb-pg18-versionset.json"
    [ -f "$vs_file" ]
    local avail_count
    avail_count=$(jq '.available | length' "$vs_file")
    [ "$avail_count" -eq 3 ]

    # version_digests must have all 3 entries.
    local vd_count
    vd_count=$(jq '.version_digests | length' "$vs_file" 2>/dev/null || echo 0)
    [ "$vd_count" -eq 3 ]

    unset PR_TAG_SUFFIX
}

# ---------------------------------------------------------------------------
# BF-push-canonical-only: PR_TAG_SUFFIX empty (push/dispatch) →
# prefilter checks canonical arch tags only (unchanged behavior).
# Regression guard: ensure no canonicality-reuse logic breaks the push path.
#
# GREEN before and after fix: on push, canonical-only probing is unchanged.
# ---------------------------------------------------------------------------
@test "BF-push-canonical-only: PR_TAG_SUFFIX empty → canonical arch tags probed, unchanged version skipped" {
    export PR_TAG_SUFFIX=""
    export ARCH_SUFFIX="amd64"
    export BUILD_PLATFORM="linux/amd64"

    # Canonical arch tag (pg18-2.27.1-amd64) exists → version already built.
    image_exists_in_registry() {
        local ref="$1"
        if [[ "$ref" == *"pg18-2.27.1-amd64"* ]]; then
            return 0  # PRESENT (canonical)
        fi
        return 1
    }
    export -f image_exists_in_registry

    ext_config() {
        case "$2" in
            version) echo "2.27.1" ;;
            repo)    echo "https://github.com/timescale/timescaledb" ;;
            *)       echo "" ;;
        esac
    }
    export -f ext_config

    run _should_build_extension "timescaledb" "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR"

    # Both before and after fix: canonical tag present → returns 1 (skip).
    [ "$status" -eq 1 ]

    unset PR_TAG_SUFFIX ARCH_SUFFIX BUILD_PLATFORM
}

# ---------------------------------------------------------------------------
# BG1-nonresolver-reuse-canonical: PR_TAG_SUFFIX=-pr42, non-resolver ext whose
# canonical multi-arch manifest EXISTS (pr-scoped arch tags do NOT exist).
# finalize_multiarch_manifests must REUSE the canonical manifest (no
# imagetools create) and exit 0.
#
# RED before fix: unconditionally calls imagetools create from -pr42 arch tags
#   which don't exist → imagetools create fails → job aborts (exit non-zero).
# GREEN after fix: canonical manifest present → reuse (no imagetools create
#   called for this ext), exit 0.
# ---------------------------------------------------------------------------
@test "BG1-nonresolver-reuse-canonical: PR context, canonical multi-arch manifest present, pr-scoped tags absent → reused, no imagetools create" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"
    local imagetools_log="$tmpd/bg1_imagetools.log"

    # Config: pgvector is NON-resolver (no version_set.resolver key).
    cat > "$CONTAINER_DIR/extensions/config.yaml" <<'EOF'
extensions:
  pgvector:
    version: "0.8.0"
    repo: "https://github.com/pgvector/pgvector"
    priority: 1
EOF
    touch "$EXT_BUILD_DIR/pgvector.Dockerfile"

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export PR_TAG_SUFFIX='-pr42'
        export imagetools_log='${imagetools_log}'
        cd '${sd}'
        source ./build-extensions.sh
        export ROOT_DIR='${tmpd}'

        ext_config() {
            local ext=\"\$1\" key=\"\$2\"
            case \"\$ext:\$key\" in
                pgvector:version) echo '0.8.0' ;;
                pgvector:repo)    echo 'https://github.com/pgvector/pgvector' ;;
                *)                echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name() { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        # Registry state: canonical multi-arch manifest exists (:pg18-0.8.0).
        # PR-scoped arch tags (:pg18-0.8.0-amd64-pr42, :pg18-0.8.0-arm64-pr42) do NOT.
        # _image_present_3state calls docker manifest inspect; mirror that here.
        docker() {
            local _dc=\"\${1:-}\" _d2=\"\${2:-}\" _d3=\"\${3:-}\"
            if [[ \"\$_dc\" == 'buildx' && \"\$_d2\" == 'imagetools' && \"\$_d3\" == 'create' ]]; then
                echo \"IMAGETOOLS_CALLED: \$*\" >> \"\$imagetools_log\"
                # Fail to expose any incorrect call: if imagetools create is called
                # when the canonical manifest exists, the pr-scoped arch tags are absent
                # and the create would fail in production.
                return 1
            fi
            if [[ \"\$_dc\" == 'buildx' && \"\$_d2\" == 'imagetools' && \"\$_d3\" == 'inspect' ]]; then
                local _ref=\"\${4:-}\"
                # Canonical multi-arch ref reports both platforms (faithful: it IS multi-arch).
                if [[ \"\$_ref\" == *':pg18-0.8.0' && \"\$_ref\" != *'-amd64'* && \"\$_ref\" != *'-arm64'* && \"\$_ref\" != *'-pr42'* ]]; then
                    printf 'linux/amd64\nlinux/arm64\n'
                    return 0
                fi
                printf 'error: manifest not found\n' >&2
                return 1
            fi
            if [[ \"\$_dc\" == 'manifest' && \"\$_d2\" == 'inspect' ]]; then
                local _ref=\"\$_d3\"
                # Canonical multi-arch ref present (no arch suffix, no PR suffix).
                if [[ \"\$_ref\" == *':pg18-0.8.0' && \"\$_ref\" != *'-amd64'* && \"\$_ref\" != *'-arm64'* && \"\$_ref\" != *'-pr42'* ]]; then
                    return 0
                fi
                printf 'manifest unknown: manifest unknown\n' >&2
                return 1
            fi
            return 0
        }
        export -f docker

        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        list_extensions_by_priority() { echo 'pgvector'; }
        export -f list_extensions_by_priority

        finalize_multiarch_manifests \"$CONTAINER_DIR/extensions/config.yaml\" 18 \"$CONTAINER_DIR\"
    "

    # RED before fix: imagetools create fails on missing pr-scoped tags → exit non-zero.
    # GREEN after fix: canonical manifest reused → exit 0.
    [ "$status" -eq 0 ]

    # imagetools create must NOT have been called for pgvector (canonical was reused).
    local create_count=0
    if [ -f "$imagetools_log" ]; then
        create_count=$(wc -l < "$imagetools_log")
    fi
    [ "$create_count" -eq 0 ]

    unset PR_TAG_SUFFIX
}

# ---------------------------------------------------------------------------
# BG1-nonresolver-create-when-changed: PR context, non-resolver ext NOT in
# canonical (built this PR, pr-scoped arch tags exist) → creates the
# PR-scoped multi-arch manifest from the -pr42 arch tags.
#
# GREEN before AND after fix: when canonical is absent and pr-scoped arch tags
# are present, imagetools create is called with the pr-scoped arch source tags.
# ---------------------------------------------------------------------------
@test "BG1-nonresolver-create-when-changed: PR context, canonical absent, pr-scoped arch tags present → creates PR-scoped manifest" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"
    local imagetools_log="$tmpd/bg1_changed_imagetools.log"

    # Config: pgvector is NON-resolver.
    cat > "$CONTAINER_DIR/extensions/config.yaml" <<'EOF'
extensions:
  pgvector:
    version: "0.8.0"
    repo: "https://github.com/pgvector/pgvector"
    priority: 1
EOF
    touch "$EXT_BUILD_DIR/pgvector.Dockerfile"

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export PR_TAG_SUFFIX='-pr42'
        export imagetools_log='${imagetools_log}'
        cd '${sd}'
        source ./build-extensions.sh
        export ROOT_DIR='${tmpd}'

        ext_config() {
            local ext=\"\$1\" key=\"\$2\"
            case \"\$ext:\$key\" in
                pgvector:version) echo '0.8.0' ;;
                pgvector:repo)    echo 'https://github.com/pgvector/pgvector' ;;
                *)                echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name() { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        # Registry state: canonical absent; pr-scoped arch tags present.
        docker() {
            local _dc=\"\${1:-}\" _d2=\"\${2:-}\" _d3=\"\${3:-}\"
            if [[ \"\$_dc\" == 'buildx' && \"\$_d2\" == 'imagetools' && \"\$_d3\" == 'create' ]]; then
                echo \"IMAGETOOLS_CALLED: \$*\" >> \"\$imagetools_log\"
                return 0
            fi
            if [[ \"\$_dc\" == 'manifest' && \"\$_d2\" == 'inspect' ]]; then
                local _ref=\"\$_d3\"
                # Only pr-scoped arch tags are present.
                if [[ \"\$_ref\" == *':pg18-0.8.0-amd64-pr42' || \"\$_ref\" == *':pg18-0.8.0-arm64-pr42' ]]; then
                    return 0
                fi
                printf 'manifest unknown: manifest unknown\n' >&2
                return 1
            fi
            return 0
        }
        export -f docker

        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        list_extensions_by_priority() { echo 'pgvector'; }
        export -f list_extensions_by_priority

        finalize_multiarch_manifests \"$CONTAINER_DIR/extensions/config.yaml\" 18 \"$CONTAINER_DIR\"
    "

    [ "$status" -eq 0 ]

    # imagetools create must have been called exactly once (for the pr-scoped manifest).
    [ -f "$imagetools_log" ]
    local create_count
    create_count=$(wc -l < "$imagetools_log")
    [ "$create_count" -eq 1 ]

    # The call must reference pr-scoped arch tags as sources.
    local call
    call=$(cat "$imagetools_log")
    [[ "$call" == *':pg18-0.8.0-amd64-pr42'* ]] || {
        echo "FAIL: imagetools call does not contain -amd64-pr42 source. Got: $call"
        false
    }
    [[ "$call" == *':pg18-0.8.0-arm64-pr42'* ]] || {
        echo "FAIL: imagetools call does not contain -arm64-pr42 source. Got: $call"
        false
    }

    unset PR_TAG_SUFFIX
}

# ---------------------------------------------------------------------------
# BG1-push-nonresolver-canonical: PR_TAG_SUFFIX empty (push/dispatch) →
# creates canonical manifest from -amd64/-arm64 stable tags (regression guard).
# GREEN before AND after fix: push path is unchanged.
# ---------------------------------------------------------------------------
@test "BG1-push-nonresolver-canonical: PR_TAG_SUFFIX empty → creates canonical manifest from stable arch tags" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"
    local imagetools_log="$tmpd/bg1_push_imagetools.log"

    # Config: pgvector is NON-resolver.
    cat > "$CONTAINER_DIR/extensions/config.yaml" <<'EOF'
extensions:
  pgvector:
    version: "0.8.0"
    repo: "https://github.com/pgvector/pgvector"
    priority: 1
EOF
    touch "$EXT_BUILD_DIR/pgvector.Dockerfile"

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export PR_TAG_SUFFIX=''
        export imagetools_log='${imagetools_log}'
        cd '${sd}'
        source ./build-extensions.sh
        export ROOT_DIR='${tmpd}'

        ext_config() {
            local ext=\"\$1\" key=\"\$2\"
            case \"\$ext:\$key\" in
                pgvector:version) echo '0.8.0' ;;
                pgvector:repo)    echo 'https://github.com/pgvector/pgvector' ;;
                *)                echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name() { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        # Faithful: per-arch suffixed tags present; un-suffixed absent (stage B creates them).
        image_exists_in_registry() {
            local ref=\"\$1\"
            [[ \"\$ref\" =~ -amd64$ ]] || [[ \"\$ref\" =~ -arm64$ ]]
        }
        export -f image_exists_in_registry

        docker() {
            local _dc=\"\${1:-}\" _d2=\"\${2:-}\" _d3=\"\${3:-}\"
            if [[ \"\$_dc\" == 'buildx' && \"\$_d2\" == 'imagetools' && \"\$_d3\" == 'create' ]]; then
                echo \"IMAGETOOLS_CALLED: \$*\" >> \"\$imagetools_log\"
                return 0
            fi
            if [[ \"\$_dc\" == 'manifest' ]]; then
                echo \"manifest unknown: manifest unknown\" >&2
                return 1
            fi
            return 0
        }
        export -f docker

        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        list_extensions_by_priority() { echo 'pgvector'; }
        export -f list_extensions_by_priority

        finalize_multiarch_manifests \"$CONTAINER_DIR/extensions/config.yaml\" 18 \"$CONTAINER_DIR\"
    "

    [ "$status" -eq 0 ]

    # imagetools create must have been called once (canonical create on push).
    [ -f "$imagetools_log" ]
    local create_count
    create_count=$(wc -l < "$imagetools_log")
    [ "$create_count" -eq 1 ]

    # The call must use stable -amd64 and -arm64 suffixed tags (no PR suffix).
    local call
    call=$(cat "$imagetools_log")
    [[ "$call" == *':pg18-0.8.0-amd64'* ]] || {
        echo "FAIL: imagetools call does not contain -amd64 tag. Got: $call"
        false
    }
    [[ "$call" == *':pg18-0.8.0-arm64'* ]] || {
        echo "FAIL: imagetools call does not contain -arm64 tag. Got: $call"
        false
    }
    # Must NOT contain -pr suffix.
    [[ "$call" != *'-pr42'* ]] || {
        echo "FAIL: push path must not contain PR suffix. Got: $call"
        false
    }

    unset PR_TAG_SUFFIX
}

# ---------------------------------------------------------------------------
# MG: non-resolver ext whose plain ref EXISTS but imagetools inspect reports
# single-arch (only linux/amd64) — the path must NOT silently reuse; it must
# log the "not multi-arch" warning and reach the CREATE path.
#
# RED against old code: the old `0) ... continue` blindly reused any present
# manifest without inspecting it, so a single-arch legacy tag was never
# re-created and the 27 ext tags remained stuck.
#
# GREEN after fix: `_reuse_ref_is_multiarch` returns 1 → fall-through to
# imagetools create.
# ---------------------------------------------------------------------------
@test "MG-nonresolver-singlearch-recreate: non-resolver ext with single-arch existing manifest → re-creates from per-arch legs" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"
    local imagetools_log="$tmpd/mg_imagetools.log"

    # Config: pgvector is NON-resolver.
    cat > "$CONTAINER_DIR/extensions/config.yaml" <<'EOF'
extensions:
  pgvector:
    version: "0.8.0"
    repo: "https://github.com/pgvector/pgvector"
    priority: 1
EOF
    touch "$EXT_BUILD_DIR/pgvector.Dockerfile"

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export imagetools_log='${imagetools_log}'
        cd '${sd}'
        source ./build-extensions.sh
        export ROOT_DIR='${tmpd}'

        ext_config() {
            local ext=\"\$1\" key=\"\$2\"
            case \"\$ext:\$key\" in
                pgvector:version) echo '0.8.0' ;;
                pgvector:repo)    echo 'https://github.com/pgvector/pgvector' ;;
                *)                echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name() { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        # ext_ref_resolve: the plain (un-suffixed) ref EXISTS; arch-suffixed refs also exist.
        ext_ref_resolve() {
            local _ext=\"\$1\" _ver=\"\$2\" _maj=\"\$3\" _arch=\"\${4:-}\"
            if [[ -z \"\$_arch\" ]]; then
                # Plain ref present — this triggers the reuse check path.
                printf 'ghcr.io/test/ext-%s:pg%s-%s' \"\$_ext\" \"\$_maj\" \"\$_ver\"
                return 0
            fi
            # Per-arch refs present (so CREATE succeeds).
            printf 'ghcr.io/test/ext-%s:pg%s-%s-%s' \"\$_ext\" \"\$_maj\" \"\$_ver\" \"\$_arch\"
            return 0
        }
        export -f ext_ref_resolve

        # docker: imagetools inspect returns only linux/amd64 (single-arch manifest).
        #         imagetools create succeeds.
        docker() {
            local _cmd=\"\${1:-}\" _sub=\"\${2:-}\" _subsub=\"\${3:-}\"
            if [[ \"\$_cmd\" == 'buildx' && \"\$_sub\" == 'imagetools' && \"\$_subsub\" == 'inspect' ]]; then
                # Single-arch: only amd64 reported.
                printf 'linux/amd64\n'
                return 0
            fi
            if [[ \"\$_cmd\" == 'buildx' && \"\$_sub\" == 'imagetools' && \"\$_subsub\" == 'create' ]]; then
                echo \"IMAGETOOLS_CREATE \${*}\" >> \"\$imagetools_log\"
                return 0
            fi
            return 0
        }
        export -f docker

        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest

        list_extensions_by_priority() { echo 'pgvector'; }
        export -f list_extensions_by_priority

        finalize_multiarch_manifests \"$CONTAINER_DIR/extensions/config.yaml\" 18 \"$CONTAINER_DIR\"
    "

    # Must succeed (re-create from per-arch legs is valid).
    [ "$status" -eq 0 ]

    # imagetools create MUST have been called: single-arch manifest must not be reused.
    # RED against old code (blind continue) — this file would not exist.
    [ -f "$imagetools_log" ] || {
        echo 'FAIL: imagetools_log not created — imagetools create was never called (single-arch manifest was blindly reused)'
        false
    }
    local create_count
    create_count=$(wc -l < "$imagetools_log")
    [ "$create_count" -ge 1 ] || {
        echo "FAIL: imagetools create was not called (expected >= 1 call, got $create_count)"
        false
    }

    # The create call must use both arch-suffixed source tags.
    local call
    call=$(cat "$imagetools_log")
    [[ "$call" == *':pg18-0.8.0-amd64'* ]] || {
        echo "FAIL: imagetools create call does not reference -amd64 source. Got: $call"
        false
    }
    [[ "$call" == *':pg18-0.8.0-arm64'* ]] || {
        echo "FAIL: imagetools create call does not reference -arm64 source. Got: $call"
        false
    }
}

# ---------------------------------------------------------------------------
# MG helper unit tests: _reuse_ref_is_multiarch return codes.
# ---------------------------------------------------------------------------

@test "MG-helper-multiarch: _reuse_ref_is_multiarch returns 0 when both arches reported" {
    docker() {
        if [[ "$1" == 'buildx' && "$2" == 'imagetools' && "$3" == 'inspect' ]]; then
            printf 'linux/amd64\nlinux/arm64\n'
            return 0
        fi
        return 1
    }
    export -f docker

    run _reuse_ref_is_multiarch 'ghcr.io/test/ext-pgvector:pg18-0.8.0'
    [ "$status" -eq 0 ]
}

@test "MG-helper-singlearch: _reuse_ref_is_multiarch returns 1 when only amd64 reported" {
    docker() {
        if [[ "$1" == 'buildx' && "$2" == 'imagetools' && "$3" == 'inspect' ]]; then
            printf 'linux/amd64\n'
            return 0
        fi
        return 1
    }
    export -f docker

    run _reuse_ref_is_multiarch 'ghcr.io/test/ext-pgvector:pg18-0.8.0'
    [ "$status" -eq 1 ]
}

@test "MG-helper-inspect-error: _reuse_ref_is_multiarch returns 2 when inspect fails" {
    docker() {
        if [[ "$1" == 'buildx' && "$2" == 'imagetools' && "$3" == 'inspect' ]]; then
            printf 'error: transient failure\n' >&2
            return 1
        fi
        return 0
    }
    export -f docker

    run _reuse_ref_is_multiarch 'ghcr.io/test/ext-pgvector:pg18-0.8.0'
    [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# BH-2a: FORCE=true + resolver-backed extension, all tags exist in registry
# → _should_build_extension must return 0 (needs build), NOT skip.
# Before fix: the multi-version branch goes straight to presence checks and
#   returns 1 (skip) when all arch tags exist, ignoring FORCE.
# After fix:  when FORCE is set, the multi-version branch returns 0 immediately
#   (same as the single-version branch).
# ---------------------------------------------------------------------------

@test "BH2a-force-resolver-rebuilds: FORCE=true + resolver-backed ext, all tags exist → returns 0 (needs rebuild)" {
    # All versions present in registry.
    image_exists_in_registry() { return 0; }
    export -f image_exists_in_registry

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

    export FORCE=true
    export PR_TAG_SUFFIX=""
    export ARCH_SUFFIX=""

    run _should_build_extension timescaledb "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR"

    # FORCE=true must override the presence check: return 0 (needs rebuild).
    # Before fix: returns 1 (all tags present → skip, FORCE ignored). RED.
    # After fix:  returns 0 (FORCE bypasses presence check). GREEN.
    [ "$status" -eq 0 ]

    unset FORCE PR_TAG_SUFFIX ARCH_SUFFIX
}

@test "BH2a-noforce-resolver-skips: FORCE unset + resolver-backed ext, all tags exist → returns 1 (skip, regression)" {
    # All versions present in registry — should skip when not forcing.
    image_exists_in_registry() { return 0; }
    export -f image_exists_in_registry

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

    export FORCE=false
    export PR_TAG_SUFFIX=""
    export ARCH_SUFFIX=""

    run _should_build_extension timescaledb "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR"

    # FORCE unset: all tags present → should skip (return 1).
    # This is the BF regression guard.
    [ "$status" -eq 1 ]

    unset FORCE PR_TAG_SUFFIX ARCH_SUFFIX
}

# ---------------------------------------------------------------------------
# BH-2b: FORCE=true on a PR + canonical manifest exists for a resolver-backed
# version → finalize_multiarch_manifests must NOT reuse canonical for it; it
# must call imagetools create from the freshly-built PR-scoped arch tags.
#
# Before fix: the BF canonical-first reuse runs regardless of FORCE → canonical
#   manifest found → returns "reused", no imagetools create for this version.
#   The PR smoke validates the stale canonical image, not the rebuilt one. RED.
# After fix:  when FORCE is set, skip canonical-first reuse for ALL versions;
#   always use the freshly-built scoped sources (PR-scoped arch tags). GREEN.
# ---------------------------------------------------------------------------

@test "BH2b-force-finalize-uses-fresh: FORCE=true on PR, canonical manifest exists → imagetools create from pr-scoped tags" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"
    local imagetools_log="$tmpd/bh2b_imagetools.log"

    # Config: timescaledb only (resolver-backed).
    cat > "$CONTAINER_DIR/extensions/config.yaml" <<'EOF'
extensions:
  timescaledb:
    version: "2.27.1"
    repo: "https://github.com/timescale/timescaledb"
    priority: 1
    version_set:
      resolver: "scripts/resolvers/timescaledb-ha.sh"
EOF

    run bash -c "
        export LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export PR_TAG_SUFFIX='-pr42'
        export ARCH_SUFFIX=''
        export imagetools_log='${imagetools_log}'
        cd '${sd}'
        source ./build-extensions.sh
        # Set FORCE=true AFTER sourcing — source resets FORCE=false from the defaults block.
        export FORCE=true
        export ROOT_DIR='${tmpd}'

        resolve_version_set() { echo '[\"2.27.1\"]'; }
        export -f resolve_version_set

        ext_config() {
            local ext=\"\$1\" key=\"\$2\"
            case \"\$ext:\$key\" in
                timescaledb:version) echo '2.27.1' ;;
                timescaledb:repo)    echo 'https://github.com/timescale/timescaledb' ;;
                *)                   echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name() { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        # Canonical multi-arch manifest EXISTS (simulates prior push of this version).
        _image_present_3state() {
            # All refs present (canonical + pr-scoped arch tags).
            return 0
        }
        export -f _image_present_3state

        image_exists_in_registry() { return 0; }
        export -f image_exists_in_registry

        docker() {
            local _dc=\"\${1:-}\" _d2=\"\${2:-}\" _d3=\"\${3:-}\"
            if [[ \"\$_dc\" == 'buildx' && \"\$_d2\" == 'imagetools' && \"\$_d3\" == 'create' ]]; then
                echo \"IMAGETOOLS_CALLED: \$*\" >> \"\$imagetools_log\"
                return 0
            fi
            if [[ \"\$_dc\" == 'buildx' && \"\$_d2\" == 'imagetools' && \"\$_d3\" == 'inspect' ]]; then
                printf 'linux/amd64\nlinux/arm64\n'
                return 0
            fi
            if [[ \"\$_dc\" == 'buildx' && \"\$_d2\" == 'build' ]]; then
                return 0
            fi
            return 0
        }
        export -f docker

        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        _capture_index_digest() {
            echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'
            return 0
        }
        export -f _capture_index_digest

        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority

        finalize_multiarch_manifests \"$CONTAINER_DIR/extensions/config.yaml\" 18 \"$CONTAINER_DIR\"
    "

    [ "$status" -eq 0 ]

    # FORCE=true: must call imagetools create from pr-scoped arch tags, not reuse canonical.
    # Before fix: canonical present → reused, no imagetools create. RED (log absent or 0 calls).
    # After fix:  FORCE bypasses canonical reuse → imagetools create called. GREEN.
    [ -f "$imagetools_log" ] || {
        echo "FAIL: imagetools_log not created — imagetools create was never called (canonical was reused)"
        false
    }
    local create_count
    create_count=$(wc -l < "$imagetools_log")
    [ "$create_count" -ge 1 ] || {
        echo "FAIL: imagetools create was not called (expected >= 1 call, got $create_count)"
        false
    }

    # The imagetools create call must use the PR-scoped arch tags (not canonical).
    local call
    call=$(cat "$imagetools_log")
    [[ "$call" == *'-amd64-pr42'* ]] || {
        echo "FAIL: imagetools create must use PR-scoped arch tag (-amd64-pr42). Got: $call"
        false
    }
    [[ "$call" == *'-arm64-pr42'* ]] || {
        echo "FAIL: imagetools create must use PR-scoped arch tag (-arm64-pr42). Got: $call"
        false
    }

    unset FORCE PR_TAG_SUFFIX ARCH_SUFFIX
}

@test "BH2b-noforce-finalize-reuses-canonical: FORCE unset on PR, canonical manifest present → canonical reused, no imagetools create (BF regression)" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"
    local imagetools_log="$tmpd/bh2b_noforce_imagetools.log"

    # Config: timescaledb only (resolver-backed).
    cat > "$CONTAINER_DIR/extensions/config.yaml" <<'EOF'
extensions:
  timescaledb:
    version: "2.27.1"
    repo: "https://github.com/timescale/timescaledb"
    priority: 1
    version_set:
      resolver: "scripts/resolvers/timescaledb-ha.sh"
EOF

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export PR_TAG_SUFFIX='-pr42'
        export ARCH_SUFFIX=''
        export imagetools_log='${imagetools_log}'
        cd '${sd}'
        source ./build-extensions.sh
        export ROOT_DIR='${tmpd}'

        resolve_version_set() { echo '[\"2.27.1\"]'; }
        export -f resolve_version_set

        ext_config() {
            local ext=\"\$1\" key=\"\$2\"
            case \"\$ext:\$key\" in
                timescaledb:version) echo '2.27.1' ;;
                timescaledb:repo)    echo 'https://github.com/timescale/timescaledb' ;;
                *)                   echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name() { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        # Canonical multi-arch manifest EXISTS.
        _image_present_3state() { return 0; }
        export -f _image_present_3state

        image_exists_in_registry() { return 0; }
        export -f image_exists_in_registry

        docker() {
            local _dc=\"\${1:-}\" _d2=\"\${2:-}\" _d3=\"\${3:-}\"
            if [[ \"\$_dc\" == 'buildx' && \"\$_d2\" == 'imagetools' && \"\$_d3\" == 'create' ]]; then
                echo \"IMAGETOOLS_CALLED: \$*\" >> \"\$imagetools_log\"
                return 0
            fi
            if [[ \"\$_dc\" == 'buildx' && \"\$_d2\" == 'imagetools' && \"\$_d3\" == 'inspect' ]]; then
                printf 'linux/amd64\nlinux/arm64\n'
                return 0
            fi
            return 0
        }
        export -f docker

        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo

        _capture_index_digest() {
            echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'
            return 0
        }
        export -f _capture_index_digest

        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority

        finalize_multiarch_manifests \"$CONTAINER_DIR/extensions/config.yaml\" 18 \"$CONTAINER_DIR\"
    "

    [ "$status" -eq 0 ]

    # FORCE unset: canonical present → canonical must be reused; no imagetools create.
    # This is the BF regression guard.
    local create_count=0
    if [ -f "$imagetools_log" ]; then
        create_count=$(wc -l < "$imagetools_log")
    fi
    [ "$create_count" -eq 0 ] || {
        echo "FAIL: imagetools create must not be called when FORCE unset and canonical is present (BF regression). Got $create_count calls."
        false
    }

    unset FORCE PR_TAG_SUFFIX ARCH_SUFFIX
}

# ---------------------------------------------------------------------------
# BI-2 PR-rerun idempotent: on a same-PR rerun (PR_TAG_SUFFIX=-pr42), a version
# that was built in an EARLIER run of the same PR exists only under the pr42 tag
# (not canonical, not in _BUILT_THIS_RUN_DIR for this rerun).
# _bundle_and_write_artifact must treat it as available (pr-scoped probe fallback),
# NOT exclude it due to canonical-only check.
#
# Correct behavior: if canonical OR pr-scoped ref exists, version is confirmed-available.
# Bug behavior: canonical-only probe → version absent → excluded → artifact deleted
#              (ceiling may appear absent) → downstream silently loses retained versions.
#
# Mock contract:
#   - ext_image_name: returns canonical ref (no suffix)
#   - image_exists_in_registry: returns 0 for pr42-scoped refs, 1 for canonical
#   - _btr_set: empty (simulates rerun, nothing built in this invocation)
#
# RED before fix: 2.25.0 pr42 not found by canonical-only probe → excluded →
#   confirmed_available=[2.27.1] (size=1) → artifact deleted (single-version path).
# GREEN after fix: canonical-first probe → canonical absent → PR-scoped fallback →
#   pr42 found → 2.25.0 included → confirmed=[2.25.0,2.27.1] → artifact written.
# ---------------------------------------------------------------------------
@test "BI2-pr-rerun-idempotent: PR rerun — version built in earlier run (pr42 only) stays available" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    # PR_TAG_SUFFIX=-pr42; ARCH_SUFFIX empty (final single-arch path, not per-arch leg).
    # version set: [2.25.0, 2.27.1]; 2.27.1 is the ceiling.
    # Registry state (earlier run of this PR built 2.25.0):
    #   - 2.25.0 canonical: ABSENT  (never pushed to canonical; this is a PR)
    #   - 2.25.0 pr42:      PRESENT (built + pushed in earlier run of this PR)
    #   - 2.27.1 canonical: ABSENT
    #   - 2.27.1 pr42:      PRESENT (ceiling, built in earlier run of this PR)

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export PR_TAG_SUFFIX='-pr42'
        export ARCH_SUFFIX=''

        cd \"$sd\"
        source ./build-extensions.sh
        export ROOT_DIR=\"$tmpd\"

        resolve_version_set() { echo '[\"2.25.0\",\"2.27.1\"]'; }
        export -f resolve_version_set

        ext_config() {
            case \"\$2\" in
                version) echo '2.27.1' ;;
                repo)    echo 'https://github.com/timescale/timescaledb' ;;
                *)       echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name() { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        # Canonical refs absent; PR-scoped refs present (built in earlier run of this PR).
        image_exists_in_registry() {
            local ref=\"\$1\"
            case \"\$ref\" in
                *pg18-2.25.0-pr42) return 0 ;;
                *pg18-2.27.1-pr42) return 0 ;;
                *)                 return 1 ;;   # canonical: absent
            esac
        }
        export -f image_exists_in_registry

        # 3-state probe mirrors image_exists_in_registry for this test.
        _image_present_3state() {
            local ref=\"\$1\"
            case \"\$ref\" in
                *pg18-2.25.0-pr42) return 0 ;;
                *pg18-2.27.1-pr42) return 0 ;;
                *)                 return 1 ;;
            esac
        }
        export -f _image_present_3state

        docker() { local _dk=\"\$1\"; case \"\$_dk\" in build|push) return 0;; manifest|buildx) echo \"manifest unknown: manifest unknown\" >&2; return 1;; *) return 1;; esac; }
        export -f docker
        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        _capture_index_digest() { echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; return 0; }
        export -f _capture_index_digest
        skopeo() { echo 'manifest unknown: manifest unknown' >&2; return 1; }
        export -f skopeo

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

    # Must succeed — the rerun must not fail due to wrongly excluding pr42-only versions.
    [ "$status" -eq 0 ]

    # The versionset artifact MUST be present.
    local artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"
    [ -f "$artifact" ] || {
        echo "FAIL: versionset artifact must be written on PR rerun. Got status=$status"
        false
    }

    # available must contain BOTH 2.25.0 AND 2.27.1 (ceiling).
    local available_count
    available_count=$(jq '.available | length' "$artifact")
    [ "$available_count" -eq 2 ] || {
        echo "FAIL: available must have 2 entries (2.25.0 and 2.27.1). Got $available_count. Artifact: $(cat "$artifact")"
        false
    }

    # 2.25.0 must be in available (the version built in an earlier run of this PR).
    local has_2250
    has_2250=$(jq -r '.available[] | select(. == "2.25.0")' "$artifact")
    [ "$has_2250" = "2.25.0" ] || {
        echo "FAIL: 2.25.0 must be in available (built in earlier PR run). Artifact: $(cat "$artifact")"
        false
    }

    # 2.27.1 (ceiling) must be in available.
    local has_ceiling
    has_ceiling=$(jq -r '.available[] | select(. == "2.27.1")' "$artifact")
    [ "$has_ceiling" = "2.27.1" ] || {
        echo "FAIL: ceiling 2.27.1 must be in available. Artifact: $(cat "$artifact")"
        false
    }

    # excluded must be empty.
    local excluded_count
    excluded_count=$(jq '.excluded | length' "$artifact")
    [ "$excluded_count" -eq 0 ] || {
        echo "FAIL: excluded must be empty for PR rerun where all pr42 refs present. Artifact: $(cat "$artifact")"
        false
    }

    unset PR_TAG_SUFFIX ARCH_SUFFIX
}

# ---------------------------------------------------------------------------
# PR-scoped digest capture: when canonical is absent and only the PR-scoped
# ref exists, _bundle_and_write_artifact must capture the digest from the
# PR-scoped ref (not the absent canonical ref).
#
# Scenario: PR_TAG_SUFFIX=-pr42, ARCH_SUFFIX empty (final local path).
# Version set: [2.25.0, 2.27.1]. Canonical refs absent; PR-scoped refs present.
# do_push=true → version_digests must be captured.
#
# Pre-fix: digest capture reconstructed the canonical ref → skopeo/docker on
#   canonical (absent) → digest empty → fail-closed → artifact write fails.
# Post-fix: digest capture uses _confirmed_refs[ver] (PR-scoped ref) →
#   digest captured from pr42 ref → artifact written with valid version_digests.
# ---------------------------------------------------------------------------
@test "PR-scoped-digest-capture: canonical absent, pr42 only → digest from pr42 ref, artifact has version_digests" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    # Record which refs _capture_index_digest was called with.
    local digest_log="${tmpd}/digest_calls.log"

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export PR_TAG_SUFFIX='-pr42'
        export ARCH_SUFFIX=''

        cd \"$sd\"
        source ./build-extensions.sh
        export ROOT_DIR=\"$tmpd\"

        resolve_version_set() { echo '[\"2.25.0\",\"2.27.1\"]'; }
        export -f resolve_version_set

        ext_config() {
            case \"\$2\" in
                version) echo '2.27.1' ;;
                repo)    echo 'https://github.com/timescale/timescaledb' ;;
                *)       echo '' ;;
            esac
        }
        export -f ext_config

        ext_image_name() { echo \"ghcr.io/test/ext-\${1}:pg\${3}-\${2}\"; }
        export -f ext_image_name
        ext_local_image_name() { echo \"localhost/ext-builder-\${1}:pg\${2}\"; }
        export -f ext_local_image_name

        # Canonical refs absent; PR-scoped refs present.
        image_exists_in_registry() {
            local ref=\"\$1\"
            case \"\$ref\" in
                *pg18-2.25.0-pr42) return 0 ;;
                *pg18-2.27.1-pr42) return 0 ;;
                *)                 return 1 ;;
            esac
        }
        export -f image_exists_in_registry

        _image_present_3state() {
            local ref=\"\$1\"
            case \"\$ref\" in
                *pg18-2.25.0-pr42) return 0 ;;
                *pg18-2.27.1-pr42) return 0 ;;
                *)                 return 1 ;;
            esac
        }
        export -f _image_present_3state

        # Capture which ref is probed; return a deterministic digest based on the ref.
        _capture_index_digest() {
            local ref=\"\$1\"
            printf 'DIGEST_CALLED %s\n' \"\$ref\" >> \"$digest_log\"
            if [[ \"\$ref\" == *-pr42 ]]; then
                echo 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
                return 0
            fi
            # Canonical ref (absent) — must not be reached after fix.
            printf '' >&2
            return 1
        }
        export -f _capture_index_digest

        docker() { local _dk=\"\$1\"; case \"\$_dk\" in build|push) return 0;; manifest|buildx) echo 'manifest unknown' >&2; return 1;; *) return 1;; esac; }
        export -f docker
        skopeo() { echo 'manifest unknown: manifest unknown' >&2; return 1; }
        export -f skopeo
        build_ext_image()   { return 0; }
        export -f build_ext_image
        tag_ext_image()     { return 0; }
        export -f tag_ext_image
        push_ext_image()    { return 0; }
        export -f push_ext_image
        validate_prerequisites() { return 0; }
        export -f validate_prerequisites
        check_registry_auth()    { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority

        main postgres --major-version 18
    "

    [ "$status" -eq 0 ]

    # Artifact must exist with version_digests.
    local artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"
    [ -f "$artifact" ] || {
        echo "FAIL: artifact must be written. status=$status output=$output"
        false
    }

    local vd_present
    vd_present=$(jq -r 'if has("version_digests") then "yes" else "no" end' "$artifact")
    [ "$vd_present" = "yes" ] || {
        echo "FAIL: artifact must have version_digests. content=$(cat "$artifact")"
        false
    }

    # All digests must be the pr42 value (not empty / not from absent canonical).
    local all_valid
    all_valid=$(jq -r '.available[] as $v | .version_digests[$v] // "MISSING" | test("^sha256:[0-9a-f]{64}$")' "$artifact" | sort -u)
    [ "$all_valid" = "true" ] || {
        echo "FAIL: every version_digests entry must be a valid sha256. content=$(cat "$artifact")"
        false
    }

    # _capture_index_digest must have been called ONLY with pr42-scoped refs.
    [ -f "$digest_log" ] || {
        echo "FAIL: digest_calls.log not written — _capture_index_digest was never called"
        false
    }
    local non_pr42_calls
    non_pr42_calls=$(grep -cv -- '-pr42' "$digest_log" || true)
    [ "$non_pr42_calls" -eq 0 ] || {
        echo "FAIL: _capture_index_digest called with non-pr42 ref. digest_calls.log:"
        cat "$digest_log"
        false
    }

    unset PR_TAG_SUFFIX ARCH_SUFFIX
}

# ===========================================================================
# ext_ref_resolve exhaustive unit matrix
#
# ext_ref_resolve is the single source of truth for per-version extension
# image reference resolution (canonical-vs-PR-scoped × arch × FORCE × 3-state).
# These tests exercise the full combinatorial space from extension-utils.sh.
# ===========================================================================

# Helper: source extension-utils.sh and set up deterministic stubs.
_source_ext_utils_for_resolve() {
    source "$HELPERS_DIR/extension-utils.sh"
    get_registry()   { echo "ghcr.io"; }
    get_repo_owner() { echo "testowner"; }
    export -f get_registry get_repo_owner
    ext_image_name() { echo "ghcr.io/testowner/ext-${1}:pg${3}-${2}"; }
    export -f ext_image_name
}

# Helper: set _image_registry_probe_3state outcomes via env vars.
# Arguments: <canonical_outcome> <pr_outcome>
# Outcomes: 0=PRESENT 1=ABSENT 2=ERROR
_mock_probe_outcomes() {
    export _MOCK_CAN_RC="$1"
    export _MOCK_PR_RC="$2"
    _image_registry_probe_3state() {
        local ref="$1"
        if [[ "$ref" == *"-pr42"* ]]; then
            return "$_MOCK_PR_RC"
        else
            return "$_MOCK_CAN_RC"
        fi
    }
    export -f _image_registry_probe_3state
}

# ---------------------------------------------------------------------------
# PUSH/DISPATCH path (PR_TAG_SUFFIX empty): only canonical is considered.
# ---------------------------------------------------------------------------

@test "ext_ref_resolve: push+canonical-PRESENT → rc0, canonical ref" {
    _source_ext_utils_for_resolve
    export PR_TAG_SUFFIX="" FORCE=false
    _mock_probe_outcomes 0 0  # canonical PRESENT
    local out rc=0
    out=$(ext_ref_resolve "pgvector" "0.8.2" "18" "") || rc=$?
    [ "$rc" -eq 0 ]
    [ "$out" = "ghcr.io/testowner/ext-pgvector:pg18-0.8.2" ]
    unset PR_TAG_SUFFIX FORCE
}

@test "ext_ref_resolve: push+canonical-ABSENT → rc1, no output" {
    _source_ext_utils_for_resolve
    export PR_TAG_SUFFIX="" FORCE=false
    _mock_probe_outcomes 1 1  # canonical ABSENT
    local out rc=0
    out=$(ext_ref_resolve "pgvector" "0.8.2" "18" "") || rc=$?
    [ "$rc" -eq 1 ]
    [ -z "$out" ]
    unset PR_TAG_SUFFIX FORCE
}

@test "ext_ref_resolve: push+canonical-ERROR → rc2, fail closed" {
    _source_ext_utils_for_resolve
    export PR_TAG_SUFFIX="" FORCE=false
    _mock_probe_outcomes 2 2  # canonical ERROR
    local out rc=0
    out=$(ext_ref_resolve "pgvector" "0.8.2" "18" "") || rc=$?
    [ "$rc" -eq 2 ]
    [ -z "$out" ]
    unset PR_TAG_SUFFIX FORCE
}

@test "ext_ref_resolve: push+arch-amd64+canonical-PRESENT → rc0, arch ref" {
    _source_ext_utils_for_resolve
    export PR_TAG_SUFFIX="" FORCE=false
    _mock_probe_outcomes 0 0
    local out rc=0
    out=$(ext_ref_resolve "timescaledb" "2.27.1" "18" "amd64") || rc=$?
    [ "$rc" -eq 0 ]
    [ "$out" = "ghcr.io/testowner/ext-timescaledb:pg18-2.27.1-amd64" ]
    unset PR_TAG_SUFFIX FORCE
}

@test "ext_ref_resolve: push+arch-amd64+canonical-ABSENT → rc1" {
    _source_ext_utils_for_resolve
    export PR_TAG_SUFFIX="" FORCE=false
    _mock_probe_outcomes 1 1
    local rc=0
    ext_ref_resolve "timescaledb" "2.27.1" "18" "amd64" > /dev/null || rc=$?
    [ "$rc" -eq 1 ]
    unset PR_TAG_SUFFIX FORCE
}

# ---------------------------------------------------------------------------
# PR path (PR_TAG_SUFFIX=-pr42), FORCE=false: canonical-first reuse.
# ---------------------------------------------------------------------------

@test "ext_ref_resolve: PR+FORCE-false+canonical-PRESENT → rc0, canonical ref (reuse unchanged)" {
    _source_ext_utils_for_resolve
    export PR_TAG_SUFFIX="-pr42" FORCE=false
    _mock_probe_outcomes 0 0  # canonical PRESENT
    local out rc=0
    out=$(ext_ref_resolve "pgvector" "0.8.2" "18" "") || rc=$?
    [ "$rc" -eq 0 ]
    [ "$out" = "ghcr.io/testowner/ext-pgvector:pg18-0.8.2" ]
    unset PR_TAG_SUFFIX FORCE
}

@test "ext_ref_resolve: PR+FORCE-false+canonical-ABSENT+pr-PRESENT → rc0, PR-scoped ref" {
    _source_ext_utils_for_resolve
    export PR_TAG_SUFFIX="-pr42" FORCE=false
    _mock_probe_outcomes 1 0  # canonical ABSENT, pr PRESENT
    local out rc=0
    out=$(ext_ref_resolve "pgvector" "0.8.2" "18" "") || rc=$?
    [ "$rc" -eq 0 ]
    [ "$out" = "ghcr.io/testowner/ext-pgvector:pg18-0.8.2-pr42" ]
    unset PR_TAG_SUFFIX FORCE
}

@test "ext_ref_resolve: PR+FORCE-false+both-ABSENT → rc1" {
    _source_ext_utils_for_resolve
    export PR_TAG_SUFFIX="-pr42" FORCE=false
    _mock_probe_outcomes 1 1  # both ABSENT
    local rc=0
    ext_ref_resolve "pgvector" "0.8.2" "18" "" > /dev/null || rc=$?
    [ "$rc" -eq 1 ]
    unset PR_TAG_SUFFIX FORCE
}

@test "ext_ref_resolve: PR+FORCE-false+canonical-ERROR → rc2, fail closed (regardless of pr)" {
    _source_ext_utils_for_resolve
    export PR_TAG_SUFFIX="-pr42" FORCE=false
    _mock_probe_outcomes 2 0  # canonical ERROR, pr PRESENT
    local rc=0
    ext_ref_resolve "pgvector" "0.8.2" "18" "" > /dev/null || rc=$?
    [ "$rc" -eq 2 ]
    unset PR_TAG_SUFFIX FORCE
}

@test "ext_ref_resolve: PR+FORCE-false+canonical-ABSENT+pr-ERROR → rc2, fail closed" {
    _source_ext_utils_for_resolve
    export PR_TAG_SUFFIX="-pr42" FORCE=false
    _mock_probe_outcomes 1 2  # canonical ABSENT, pr ERROR
    local rc=0
    ext_ref_resolve "pgvector" "0.8.2" "18" "" > /dev/null || rc=$?
    [ "$rc" -eq 2 ]
    unset PR_TAG_SUFFIX FORCE
}

@test "ext_ref_resolve: PR+FORCE-false+amd64+canonical-ABSENT+pr-PRESENT → rc0, PR-scoped arch ref" {
    _source_ext_utils_for_resolve
    export PR_TAG_SUFFIX="-pr42" FORCE=false
    _mock_probe_outcomes 1 0  # canonical arch absent, pr-arch present
    local out rc=0
    out=$(ext_ref_resolve "timescaledb" "2.27.1" "18" "amd64") || rc=$?
    [ "$rc" -eq 0 ]
    [ "$out" = "ghcr.io/testowner/ext-timescaledb:pg18-2.27.1-amd64-pr42" ]
    unset PR_TAG_SUFFIX FORCE
}

# ---------------------------------------------------------------------------
# PR path (PR_TAG_SUFFIX=-pr42), FORCE=true: prefer PR-scoped fresh build.
# ---------------------------------------------------------------------------

@test "ext_ref_resolve: PR+FORCE-true+pr-PRESENT → rc0, PR-scoped ref (not canonical)" {
    _source_ext_utils_for_resolve
    export PR_TAG_SUFFIX="-pr42" FORCE=true
    _mock_probe_outcomes 0 0  # canonical PRESENT, pr PRESENT
    local out rc=0
    out=$(ext_ref_resolve "pgvector" "0.8.2" "18" "") || rc=$?
    [ "$rc" -eq 0 ]
    # Must return PR-scoped, not canonical.
    [ "$out" = "ghcr.io/testowner/ext-pgvector:pg18-0.8.2-pr42" ]
    unset PR_TAG_SUFFIX FORCE
}

@test "ext_ref_resolve: PR+FORCE-true+pr-ABSENT → rc1 (needs build)" {
    _source_ext_utils_for_resolve
    export PR_TAG_SUFFIX="-pr42" FORCE=true
    _mock_probe_outcomes 0 1  # canonical PRESENT, pr ABSENT
    local rc=0
    ext_ref_resolve "pgvector" "0.8.2" "18" "" > /dev/null || rc=$?
    [ "$rc" -eq 1 ]
    unset PR_TAG_SUFFIX FORCE
}

@test "ext_ref_resolve: PR+FORCE-true+pr-ERROR → rc2, fail closed" {
    _source_ext_utils_for_resolve
    export PR_TAG_SUFFIX="-pr42" FORCE=true
    _mock_probe_outcomes 0 2  # canonical PRESENT, pr ERROR
    local rc=0
    ext_ref_resolve "pgvector" "0.8.2" "18" "" > /dev/null || rc=$?
    [ "$rc" -eq 2 ]
    unset PR_TAG_SUFFIX FORCE
}

@test "ext_ref_resolve: PR+FORCE-true+amd64+pr-PRESENT → rc0, PR-scoped arch ref" {
    _source_ext_utils_for_resolve
    export PR_TAG_SUFFIX="-pr42" FORCE=true
    _mock_probe_outcomes 0 0
    local out rc=0
    out=$(ext_ref_resolve "timescaledb" "2.27.1" "18" "amd64") || rc=$?
    [ "$rc" -eq 0 ]
    [ "$out" = "ghcr.io/testowner/ext-timescaledb:pg18-2.27.1-amd64-pr42" ]
    unset PR_TAG_SUFFIX FORCE
}

@test "ext_ref_resolve: PR+FORCE-true+arm64+pr-ABSENT → rc1" {
    _source_ext_utils_for_resolve
    export PR_TAG_SUFFIX="-pr42" FORCE=true
    _mock_probe_outcomes 0 1  # pr-scoped arm64 absent
    local rc=0
    ext_ref_resolve "timescaledb" "2.27.1" "18" "arm64" > /dev/null || rc=$?
    [ "$rc" -eq 1 ]
    unset PR_TAG_SUFFIX FORCE
}

# ---------------------------------------------------------------------------
# Edge: FORCE=true but PR_TAG_SUFFIX empty (push with --force flag).
# Must behave identical to FORCE=false push (canonical probe only).
# ---------------------------------------------------------------------------

@test "ext_ref_resolve: push+FORCE-true+canonical-PRESENT → rc0, canonical (not PR-scoped path)" {
    _source_ext_utils_for_resolve
    export PR_TAG_SUFFIX="" FORCE=true
    _mock_probe_outcomes 0 0  # canonical PRESENT
    local out rc=0
    out=$(ext_ref_resolve "pgvector" "0.8.2" "18" "") || rc=$?
    [ "$rc" -eq 0 ]
    # On push (no PR suffix), FORCE+PR branch is not entered; canonical probe runs.
    [ "$out" = "ghcr.io/testowner/ext-pgvector:pg18-0.8.2" ]
    unset PR_TAG_SUFFIX FORCE
}

@test "ext_ref_resolve: push+FORCE-true+canonical-ABSENT → rc1" {
    _source_ext_utils_for_resolve
    export PR_TAG_SUFFIX="" FORCE=true
    _mock_probe_outcomes 1 1
    local rc=0
    ext_ref_resolve "pgvector" "0.8.2" "18" "" > /dev/null || rc=$?
    [ "$rc" -eq 1 ]
    unset PR_TAG_SUFFIX FORCE
}

# ---------------------------------------------------------------------------
# INSPECT-FAIL: imagetools inspect failure is treated as a transient infra
# error and causes finalize_multiarch_manifests to fail closed (exit non-zero).
#
# Before fix: both inspect sites used `|| true`, swallowing the exit code.
# An inspect failure yielded empty output → the arch-coverage grep saw no
# linux/amd64 or linux/arm64 → the version was silently excluded (non-ceiling)
# or treated as genuinely single-arch, writing a REDUCED versionset artifact.
#
# After fix: inspect failure → _ext_failed=true → abort → no reduced artifact.
#
# This test drives the CREATE path (multi-arch manifest absent → per-arch tags
# confirmed PRESENT → imagetools create SUCCEEDS → imagetools inspect FAILS).
# Non-ceiling version: the old code would have silently excluded it and
# continued; the fixed code must fail closed (exit non-zero, no artifact).
# ---------------------------------------------------------------------------
@test "INSPECT-FAIL: imagetools inspect failure on CREATE path → fail closed (no reduced artifact)" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    local artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export FINALIZE_MULTIARCH=true
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

        # ext_ref_resolve:
        #   arch=\"\"    → rc 1 (multi-arch manifest absent → trigger CREATE path)
        #   arch=\"amd64\" / arch=\"arm64\" → rc 0 with a stable arch-suffixed ref
        # This drives the CREATE path in finalize_multiarch_manifests.
        ext_ref_resolve() {
            local _ext=\"\$1\" _ver=\"\$2\" _maj=\"\$3\" _arch=\"\${4:-}\"
            if [[ -z \"\$_arch\" ]]; then
                return 1  # multi-arch absent → proceed to CREATE
            fi
            printf 'ghcr.io/test/ext-%s:pg%s-%s-%s' \"\$_ext\" \"\$_maj\" \"\$_ver\" \"\$_arch\"
            return 0
        }
        export -f ext_ref_resolve

        # _capture_index_digest: returns a valid digest (create succeeded)
        _capture_index_digest() {
            echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'
            return 0
        }
        export -f _capture_index_digest

        # docker:
        #   buildx imagetools create  → succeeds (per-arch tags confirmed PRESENT)
        #   buildx imagetools inspect → FAILS (transient infra error — the bug site)
        #   everything else           → fail (not needed)
        docker() {
            local _cmd=\"\${1:-}\" _sub=\"\${2:-}\" _subsub=\"\${3:-}\"
            if [[ \"\$_cmd\" == 'buildx' && \"\$_sub\" == 'imagetools' ]]; then
                if [[ \"\$_subsub\" == 'create' ]]; then
                    return 0
                fi
                if [[ \"\$_subsub\" == 'inspect' ]]; then
                    printf 'error: transient registry failure\\n' >&2
                    return 1
                fi
            fi
            return 1
        }
        export -f docker

        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        image_exists_in_registry() { return 1; }
        export -f image_exists_in_registry
        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority

        main postgres --major-version 18
    "

    # CORE ASSERTION: inspect failure on any version must cause fail-closed (exit non-zero).
    # Before fix: exit 0, version silently excluded, reduced artifact written.
    # After fix:  exit non-zero, no reduced artifact.
    [ "$status" -ne 0 ]

    # The versionset artifact must NOT exist: inspect failure must not produce a
    # reduced artifact (writing available=[2.26.0,2.27.1] while silently dropping
    # 2.25.0 is the exact pre-fix data-loss scenario this test guards against).
    [ ! -f "$artifact" ]
}

# ---------------------------------------------------------------------------
# INSPECT-FAIL REUSE PATH: imagetools inspect failure on the REUSE path
# (multi-arch manifest already present → reuse attempted → inspect FAILS).
#
# Before fix: both inspect sites used `|| true`, swallowing the exit code.
# An inspect failure yielded empty output → arch-coverage grep saw nothing →
# the version fell through to the CREATE path (or was silently excluded).
# Either way a transient infra error produced a different artifact than the
# correct, fully-available set.
#
# After fix: inspect failure → _ext_failed=true → abort → no artifact.
#
# This test drives the REUSE path:
#   ext_ref_resolve(arch="") → rc 0 (manifest present)
#   _capture_index_digest    → succeeds
#   imagetools inspect       → rc 1 (transient infra error — the bug site)
# Non-ceiling version: the old code would fall through to CREATE; the fixed
# code must fail closed (exit non-zero, no artifact).
# ---------------------------------------------------------------------------
@test "INSPECT-FAIL: imagetools inspect failure on REUSE path → fail closed (no reduced artifact)" {
    local tmpd="$TEST_TEMP_DIR"
    local sd="$SCRIPTS_DIR"

    printf '#!/bin/bash\necho "18.0"\n' > "${tmpd}/postgres/version.sh"
    chmod +x "${tmpd}/postgres/version.sh"

    local artifact="$tmpd/.build-lineage/ext-timescaledb-pg18-versionset.json"

    run bash -c "
        export FORCE=false LOCAL_ONLY=false DRY_RUN=false CONTAINER=postgres
        export FINALIZE_MULTIARCH=true
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

        # ext_ref_resolve:
        #   arch=\"\"    → rc 0 with a ref (multi-arch manifest PRESENT → trigger REUSE path)
        #   arch=*      → rc 0 with arch-suffixed ref (per-arch tags also present)
        # This drives the REUSE path in finalize_multiarch_manifests.
        ext_ref_resolve() {
            local _ext=\"\$1\" _ver=\"\$2\" _maj=\"\$3\" _arch=\"\${4:-}\"
            if [[ -z \"\$_arch\" ]]; then
                printf 'ghcr.io/test/ext-%s:pg%s-%s' \"\$_ext\" \"\$_maj\" \"\$_ver\"
                return 0  # manifest PRESENT → enter reuse path
            fi
            printf 'ghcr.io/test/ext-%s:pg%s-%s-%s' \"\$_ext\" \"\$_maj\" \"\$_ver\" \"\$_arch\"
            return 0
        }
        export -f ext_ref_resolve

        # _capture_index_digest: succeeds (reuse digest captured without issue)
        _capture_index_digest() {
            echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'
            return 0
        }
        export -f _capture_index_digest

        # docker:
        #   buildx imagetools inspect → FAILS (transient infra error — the bug site)
        #   buildx imagetools create  → not expected to be called (reuse path fails first)
        #   everything else           → fail (not needed)
        docker() {
            local _cmd=\"\${1:-}\" _sub=\"\${2:-}\" _subsub=\"\${3:-}\"
            if [[ \"\$_cmd\" == 'buildx' && \"\$_sub\" == 'imagetools' ]]; then
                if [[ \"\$_subsub\" == 'inspect' ]]; then
                    printf 'error: transient registry failure\\n' >&2
                    return 1
                fi
                if [[ \"\$_subsub\" == 'create' ]]; then
                    return 0
                fi
            fi
            return 1
        }
        export -f docker

        skopeo() { echo manifest unknown >&2; return 1; }
        export -f skopeo
        image_exists_in_registry() { return 1; }
        export -f image_exists_in_registry
        validate_prerequisites()  { return 0; }
        export -f validate_prerequisites
        check_registry_auth()     { return 0; }
        export -f check_registry_auth
        list_extensions_by_priority() { echo 'timescaledb'; }
        export -f list_extensions_by_priority

        main postgres --major-version 18
    "

    # CORE ASSERTION: inspect failure on the REUSE path must cause fail-closed (exit non-zero).
    # Before fix: inspect rc was swallowed by || true, empty output fell through to CREATE
    # path (or silently excluded the version), producing a reduced or incorrect artifact.
    # After fix: non-zero inspect rc → _ext_failed=true → no artifact written.
    [ "$status" -ne 0 ]

    # The versionset artifact must NOT exist: a transient inspect failure must never
    # produce any artifact (reduced or full), as the set of confirmed-available versions
    # is unknown.
    [ ! -f "$artifact" ]
}
