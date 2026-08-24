#!/usr/bin/env bats

# Unit tests for _should_build_extension() truth table plus CLI entry-point,
# enumeration, cache-read, and prerequisite coverage in scripts/build-extensions.sh
#
# Mocking strategy:
#   - docker()           : bash function override (exits 0 = image found, 1 = not found)
#   - image_exists_in_registry(): bash function override (same convention)
#   - ext_config()       : returns a deterministic version "1.2.3"
#   - ext_image_name()   : returns a deterministic tag "ghcr.io/test/ext-pgvector:pg17-1.2.3"
#   - Dockerfile presence: created/absent in TEST_TEMP_DIR

load "../test_helper"

# ---------------------------------------------------------------------------
# Source helper: build-extensions.sh resolves its own SCRIPT_DIR/ROOT_DIR.
# build-extensions.sh has a BASH_SOURCE guard so main() is NOT called when
# the script is sourced rather than executed directly.
# ---------------------------------------------------------------------------
_source_build_extensions() {
    # shellcheck disable=SC1091
    source "$SCRIPTS_DIR/build-extensions.sh"
}

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
    setup_temp_dir
    STATUS_TARGET_FIXTURES=()

    # Minimal extension filesystem under TEST_TEMP_DIR
    CONTAINER_DIR="$TEST_TEMP_DIR/postgres"
    EXT_BUILD_DIR="$CONTAINER_DIR/extensions/build"
    mkdir -p "$EXT_BUILD_DIR"

    # Minimal config.yaml (ext_config reads from it via yq)
    mkdir -p "$CONTAINER_DIR/extensions"
    cat > "$CONTAINER_DIR/extensions/config.yaml" <<'EOF'
extensions:
  pgvector:
    version: "1.2.3"
    repo: "https://github.com/pgvector/pgvector"
    priority: 1
EOF

    CONFIG_FILE="$CONTAINER_DIR/extensions/config.yaml"
    MAJOR_VER="17"
    EXT_DOCKERFILE="$EXT_BUILD_DIR/pgvector.Dockerfile"

    # Default: Dockerfile present
    touch "$EXT_DOCKERFILE"

    # Reset globals that _should_build_extension reads
    export FORCE=false
    export LOCAL_ONLY=false
    export CONTAINER="postgres"

    _source_build_extensions

    # Install mocks AFTER sourcing — build-extensions.sh sources
    # helpers/extension-utils.sh which defines real `ext_config` and
    # `ext_image_name`. Mocks declared before would be overwritten.
    _setup_default_mocks

    # After sourcing, redirect ROOT_DIR to our temp tree
    ROOT_DIR="$TEST_TEMP_DIR"
}

teardown() {
    local fixture cleanup_failed=0
    # Status-target refusal tests may return before their final assertion. Keep
    # their deliberately-invalid fixtures outside the test body cleanup so
    # Bats removes them on both passing and failing paths.
    for fixture in "${STATUS_TARGET_FIXTURES[@]}"; do
        chmod -R u+w -- "$fixture" 2>/dev/null || true
        rm -rf -- "$fixture"
        if [[ -e "$fixture" || -L "$fixture" ]]; then
            echo "FAIL: status-target fixture remains after teardown: $fixture" >&2
            cleanup_failed=1
        fi
    done
    # Sourcing the script creates both per-run directories; it installs no EXIT
    # trap when sourced, so each test would otherwise leave two behind.
    [[ -z "${_RESOLVER_CACHE_DIR:-}" ]] || rm -rf -- "$_RESOLVER_CACHE_DIR"
    [[ -z "${_BUILT_THIS_RUN_DIR:-}" ]] || rm -rf -- "$_BUILT_THIS_RUN_DIR"
    teardown_temp_dir
    unset FORCE LOCAL_ONLY CONTAINER ROOT_DIR
    return "$cleanup_failed"
}

# ---------------------------------------------------------------------------
# CLI entry-point behavior
# ---------------------------------------------------------------------------

@test "entry point refuses invalid invocations and accepts deliberate help" {
    run "$SCRIPTS_DIR/build-extensions.sh" postgres --no-cach
    [ "$status" -eq 2 ] || {
        echo "FAIL: unknown option must exit 2"
        return 1
    }

    run "$SCRIPTS_DIR/build-extensions.sh" postgres extra
    [ "$status" -eq 2 ] || {
        echo "FAIL: unexpected argument must exit 2"
        return 1
    }

    run "$SCRIPTS_DIR/build-extensions.sh"
    [ "$status" -eq 2 ] || {
        echo "FAIL: missing container must exit 2"
        return 1
    }

    run "$SCRIPTS_DIR/build-extensions.sh" --help
    [ "$status" -eq 0 ] || {
        echo "FAIL: deliberate --help must exit zero"
        return 1
    }
    local temp_root="$TEST_TEMP_DIR/status-refusal-tmp"
    local directory_target="$TEST_TEMP_DIR/status-target-directory"
    local symlink_target="$TEST_TEMP_DIR/status-target-symlink"
    local symlink_destination="$TEST_TEMP_DIR/status-target-destination"
    local unwritable_parent="$TEST_TEMP_DIR/status-target-unwritable"
    local unwritable_target="$unwritable_parent/build-status"
    mkdir -p "$temp_root" "$directory_target" "$unwritable_parent"
    printf 'unchanged\n' > "$symlink_destination"
    ln -s "$symlink_destination" "$symlink_target"
    chmod u-w "$unwritable_parent"
    STATUS_TARGET_FIXTURES=("$directory_target" "$symlink_target" "$symlink_destination" "$unwritable_parent")

    run env TMPDIR="$temp_root" ROTATION_STATUS_FILE="$directory_target" \
        "$SCRIPTS_DIR/build-extensions.sh" --help
    [ "$status" -ne 0 ]
    [[ "$output" == *"ROTATION_STATUS_FILE must name a regular file"* ]]
    [[ -z "$(find "$temp_root" -mindepth 1 -print -quit)" ]]

    run env TMPDIR="$temp_root" ROTATION_STATUS_FILE="$symlink_target" \
        "$SCRIPTS_DIR/build-extensions.sh" --help
    [ "$status" -ne 0 ]
    [[ -z "$(find "$temp_root" -mindepth 1 -print -quit)" ]]

    run env TMPDIR="$temp_root" ROTATION_STATUS_FILE="$unwritable_target" \
        "$SCRIPTS_DIR/build-extensions.sh" --help
    [ "$status" -ne 0 ]
    [[ -z "$(find "$temp_root" -mindepth 1 -print -quit)" ]]
}

@test "EXIT cleanup failure records infra instead of a success verdict" {
    local bin_dir="$TEST_TEMP_DIR/cleanup-failure-bin"
    local status_file="$TEST_TEMP_DIR/cleanup-failure-status"
    mkdir -p "$bin_dir"
    cat > "$bin_dir/rm" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == -rf ]]; then
    exit 1
fi
exec /bin/rm "$@"
EOF
    chmod +x "$bin_dir/rm"

    run env PATH="$bin_dir:$PATH" ROTATION_STATUS_FILE="$status_file" \
        "$SCRIPTS_DIR/build-extensions.sh" --help

    [ "$status" -ne 0 ]
    [ "$(<"$status_file")" = infra ]
}

@test "entry point refuses missing and option-shaped option values" {
    run bash -c '"$@" 2>&1' _ "$SCRIPTS_DIR/build-extensions.sh" postgres --major-version --dry-run
    [ "$status" -eq 2 ] || {
        echo "FAIL: --major-version with an option-shaped value must exit 2"
        return 1
    }
    printf '%s' "$output" | grep -Fq "Option --major-version requires a value" || {
        echo "FAIL: --major-version with an option-shaped value must name the option"
        return 1
    }
    ! printf '%s' "$output" | grep -Fq "All extensions are up to date" || {
        echo "FAIL: --major-version with an option-shaped value must not report a no-build success"
        return 1
    }

    run bash -c '"$@" 2>&1' _ "$SCRIPTS_DIR/build-extensions.sh" postgres --major-version
    [ "$status" -eq 2 ] || {
        echo "FAIL: --major-version without a value must exit 2"
        return 1
    }
    printf '%s' "$output" | grep -Fq "Option --major-version requires a value" || {
        echo "FAIL: --major-version without a value must name the option"
        return 1
    }

    run bash -c '"$@" 2>&1' _ "$SCRIPTS_DIR/build-extensions.sh" postgres --extension
    [ "$status" -eq 2 ] || {
        echo "FAIL: --extension without a value must exit 2"
        return 1
    }
    printf '%s' "$output" | grep -Fq "Option --extension requires a value" || {
        echo "FAIL: --extension without a value must name the option"
        return 1
    }

    run bash -c '"$@" 2>&1' _ "$SCRIPTS_DIR/build-extensions.sh" postgres --extension --dry-run
    [ "$status" -eq 2 ] || {
        echo "FAIL: --extension with an option-shaped value must exit 2"
        return 1
    }
    printf '%s' "$output" | grep -Fq "Option --extension requires a value" || {
        echo "FAIL: --extension with an option-shaped value must name the option"
        return 1
    }
}

@test "entry point validates values consumed by options" {
    run bash -c '"$@" 2>&1' _ "$SCRIPTS_DIR/build-extensions.sh" postgres --major-version 17x
    [ "$status" -eq 2 ] || {
        echo "FAIL: --major-version must refuse a non-decimal value with status 2"
        return 1
    }
    printf '%s' "$output" | grep -Fq "Option --major-version must match ^[0-9]+$" || {
        echo "FAIL: --major-version must explain its ASCII-digit grammar"
        return 1
    }

    run bash -c '"$@" 2>&1' _ "$SCRIPTS_DIR/build-extensions.sh" postgres --extension 'pg/vector'
    [ "$status" -eq 2 ] || {
        echo "FAIL: --extension must refuse a non-name-shaped value with status 2"
        return 1
    }
    printf '%s' "$output" | grep -Fq "Option --extension must match ^[A-Za-z0-9_][A-Za-z0-9_-]*$" || {
        echo "FAIL: --extension must explain its command-line name grammar"
        return 1
    }
}

@test "entry point applies ASCII option grammars in a UTF-8 locale" {
    run locale -a
    [ "$status" -eq 0 ] || {
        echo "FAIL: locale -a must succeed before testing en_US.utf8"
        return 1
    }
    printf '%s\n' "$output" | grep -Fxq 'en_US.utf8' || {
        echo "FAIL: en_US.utf8 locale is required to test locale-independent ASCII option grammars"
        return 1
    }

    run env LC_ALL=en_US.utf8 bash -c '[[ "$1" =~ ^[[:alpha:]]+$ ]]' _ 'É'
    [ "$status" -eq 0 ] || {
        echo "FAIL: en_US.utf8 locale control must accept non-ASCII É with [[:alpha:]]"
        return 1
    }

    run env LC_ALL=en_US.utf8 "$SCRIPTS_DIR/build-extensions.sh" postgres --major-version '١' --dry-run
    [ "$status" -eq 2 ] || {
        echo "FAIL: --major-version must reject Arabic-Indic digit ١ in en_US.utf8"
        return 1
    }
    printf '%s' "$output" | grep -Fq "Option --major-version must match ^[0-9]+$" || {
        echo "FAIL: --major-version must name its ASCII-digit grammar for ١"
        return 1
    }

    run env LC_ALL=en_US.utf8 "$SCRIPTS_DIR/build-extensions.sh" postgres --major-version '²' --dry-run
    [ "$status" -eq 2 ] || {
        echo "FAIL: --major-version must reject superscript digit ² in en_US.utf8"
        return 1
    }
    printf '%s' "$output" | grep -Fq "Option --major-version must match ^[0-9]+$" || {
        echo "FAIL: --major-version must name its ASCII-digit grammar for ²"
        return 1
    }

    run env LC_ALL=en_US.utf8 "$SCRIPTS_DIR/build-extensions.sh" postgres --extension 'É' --dry-run
    [ "$status" -eq 2 ] || {
        echo "FAIL: --extension must reject É in en_US.utf8"
        return 1
    }
    printf '%s' "$output" | grep -Fq "Option --extension must match ^[A-Za-z0-9_][A-Za-z0-9_-]*$" || {
        echo "FAIL: --extension must name its ASCII grammar for É"
        return 1
    }
}

@test "entry point extension diagnostic names the accepted grammar" {
    run env LC_ALL=en_US.utf8 "$SCRIPTS_DIR/build-extensions.sh" postgres --major-version 17 --extension _pgvector-1 --dry-run
    [ "$status" -eq 1 ] || {
        echo "FAIL: --extension must parse _pgvector-1, which its diagnostic grammar describes"
        return 1
    }
    printf '%s' "$output" | grep -Fq "Extension '_pgvector-1': no Dockerfile" || {
        echo "FAIL: --extension must reach later validation after accepting _pgvector-1"
        return 1
    }

    run "$SCRIPTS_DIR/build-extensions.sh" postgres --extension '-foo' --dry-run
    [ "$status" -eq 2 ] || {
        echo "FAIL: --extension -foo must exit 2"
        return 1
    }
    printf '%s' "$output" | grep -Fq "Option --extension requires a value" || {
        echo "FAIL: --extension -foo must remain option-shaped rather than grammar-valid"
        return 1
    }
    local option_shaped_extension='-foo'
    ! [[ "$option_shaped_extension" =~ ^[A-Za-z0-9_][A-Za-z0-9_-]*$ ]] || {
        echo "FAIL: extension diagnostic grammar must not describe -foo as valid"
        return 1
    }
}

@test "dry-run entry point reports the requested cache mode" {
    run "$SCRIPTS_DIR/build-extensions.sh" postgres --major-version 17 --dry-run --no-cache --extension pgvector

    [ "$status" -eq 0 ]
    grep -Fq -- "[DRY-RUN] Cache mode: disabled" <<<"$output" || {
        echo "FAIL: dry-run entry point must report disabled cache mode"
        return 1
    }

    run env DOCKER_NO_CACHE=false "$SCRIPTS_DIR/build-extensions.sh" postgres --major-version 17 --dry-run --extension pgvector

    [ "$status" -eq 0 ]
    grep -Fq -- "[DRY-RUN] Cache mode: enabled" <<<"$output" || {
        echo "FAIL: dry-run entry point must report enabled cache mode"
        return 1
    }
}

# ---------------------------------------------------------------------------
# Default mock helpers — individual tests override as needed
# ---------------------------------------------------------------------------

# docker image inspect: default = image NOT found locally
_mock_docker_absent() {
    docker() { return 1; }
    export -f docker
}

# docker image inspect: image found locally
_mock_docker_present() {
    docker() { return 0; }
    export -f docker
}

# image_exists_in_registry: default = NOT in registry
_mock_registry_absent() {
    image_exists_in_registry() { return 1; }
    export -f image_exists_in_registry
}

# image_exists_in_registry: image exists in registry
_mock_registry_present() {
    image_exists_in_registry() { return 0; }
    export -f image_exists_in_registry
}

_setup_default_mocks() {
    _mock_docker_absent
    _mock_registry_absent

    # ext_config always returns a deterministic version
    ext_config() { echo "1.2.3"; }
    export -f ext_config

    # ext_image_name returns a deterministic tag
    ext_image_name() { echo "ghcr.io/test/ext-pgvector:pg17-1.2.3"; }
    export -f ext_image_name
}

# ---------------------------------------------------------------------------
# 8-case truth table
# ---------------------------------------------------------------------------

# Case 1: LOCAL_ONLY=true, image found locally, FORCE=false  →  skip (return 1)
@test "LOCAL_ONLY=true, image present locally, FORCE=false → skip" {
    export LOCAL_ONLY=true
    export FORCE=false
    _mock_docker_present

    run _should_build_extension "pgvector" "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"already exists locally"* ]]
}

# Case 2: LOCAL_ONLY=true, image found locally, FORCE=true  →  build (return 0)
@test "LOCAL_ONLY=true, image present locally, FORCE=true → build" {
    export LOCAL_ONLY=true
    export FORCE=true
    _mock_docker_present

    run _should_build_extension "pgvector" "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR"
    [ "$status" -eq 0 ]
}

# Case 3: LOCAL_ONLY=true, image absent locally  →  build (return 0)
@test "LOCAL_ONLY=true, image absent locally → build" {
    export LOCAL_ONLY=true
    export FORCE=false
    _mock_docker_absent

    run _should_build_extension "pgvector" "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR"
    [ "$status" -eq 0 ]
}

# Case 4: LOCAL_ONLY=false, FORCE=true  →  build regardless (return 0)
@test "LOCAL_ONLY=false, FORCE=true → build regardless" {
    export LOCAL_ONLY=false
    export FORCE=true
    # registry check is irrelevant when FORCE=true
    _mock_registry_present

    run _should_build_extension "pgvector" "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR"
    [ "$status" -eq 0 ]
}

# Case 5: LOCAL_ONLY=false, FORCE=false, image in registry  →  skip (return 1)
@test "LOCAL_ONLY=false, FORCE=false, image in registry → skip" {
    export LOCAL_ONLY=false
    export FORCE=false
    _mock_registry_present

    run _should_build_extension "pgvector" "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"already exists in registry"* ]]
}

# Case 6: LOCAL_ONLY=false, FORCE=false, image absent  →  build (return 0)
@test "LOCAL_ONLY=false, FORCE=false, image absent → build" {
    export LOCAL_ONLY=false
    export FORCE=false
    _mock_registry_absent

    run _should_build_extension "pgvector" "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR"
    [ "$status" -eq 0 ]
}

# Case 7: Dockerfile missing  →  skip with warning (return 1)
@test "Dockerfile missing → skip with warning" {
    export LOCAL_ONLY=false
    export FORCE=false
    rm -f "$EXT_DOCKERFILE"

    run _should_build_extension "pgvector" "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no Dockerfile"* ]]
}

# Case 8: LOCAL_ONLY=false, FORCE=true, image absent in registry  →  build
# Differs from case 4 (FORCE=true with registry PRESENT): exercises the
# FORCE-short-circuit path BEFORE the registry probe so a registry outage
# during a force rebuild can't accidentally skip.
@test "LOCAL_ONLY=false, FORCE=true, image absent in registry → build (force short-circuits before probe)" {
    export LOCAL_ONLY=false
    export FORCE=true
    _mock_registry_absent

    # Sentinel: registry probe must NOT be called when FORCE=true (defence
    # against a future refactor that swaps the order).
    image_exists_in_registry() {
        touch "$TEST_TEMP_DIR/registry_probe_called"
        echo "REGISTRY_PROBE_CALLED" >&2
        return 1
    }
    export -f image_exists_in_registry

    run _should_build_extension "pgvector" "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR"
    [ "$status" -eq 0 ]
    [ ! -e "$TEST_TEMP_DIR/registry_probe_called" ]
}

# ---------------------------------------------------------------------------
# Fail-closed extension enumeration
# ---------------------------------------------------------------------------

_mock_failed_extension_enumeration() {
    list_extensions_by_priority() {
        return 1
    }
}

_malformed_config_yq_path() {
    local test_path="$TEST_TEMP_DIR/malformed-config-bin"
    local malformed_config="$TEST_TEMP_DIR/malformed-config.yaml"
    local real_yq
    real_yq="$(command -v yq)"

    mkdir -p "$test_path"
    printf 'extensions: [\n' > "$malformed_config"
    cat > "$test_path/yq" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == *'.extensions | to_entries[]'* ]]; then
    printf 'pgvector\\n'
    exit 0
fi
set -- "\${@:1:\$#-1}" "$malformed_config"
exec "$real_yq" "\$@"
EOF
    chmod +x "$test_path/yq"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$test_path/docker"
    chmod +x "$test_path/docker"
    printf '%s' "$test_path"
}

@test "pull-only mode fails closed when extension enumeration fails" {
    EXTENSION=""
    _mock_failed_extension_enumeration

    run handle_pull_only_mode "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR"

    [ "$status" -ne 0 ]
    assert_output_not_contains "All extensions pulled successfully"
    assert_output_contains "extension enumeration for pull-only mode failed — aborting (fail-closed)"
}

@test "pull-only entry point fails closed when config access fails after enumeration" {
    local malformed_yq_path
    malformed_yq_path="$(_malformed_config_yq_path)"
    unset -f docker

    run env CI=true PATH="$malformed_yq_path:$PATH" "$SCRIPTS_DIR/build-extensions.sh" postgres --major-version "$MAJOR_VER" --pull-only
    [ "$status" -ne 0 ]
    assert_output_not_contains "All extensions pulled successfully"
}

@test "status listing fails closed when extension enumeration fails" {
    export EXTENSION=""
    _mock_failed_extension_enumeration

    run list_extension_status "$CONFIG_FILE" "$MAJOR_VER"
    [ "$status" -ne 0 ]
    assert_output_contains "extension enumeration for status listing failed — aborting (fail-closed)"
}

@test "list entry point fails closed when config access fails after enumeration" {
    local malformed_yq_path
    malformed_yq_path="$(_malformed_config_yq_path)"

    run env PATH="$malformed_yq_path:$PATH" "$SCRIPTS_DIR/build-extensions.sh" postgres --major-version "$MAJOR_VER" --list
    [ "$status" -ne 0 ]
    assert_output_not_contains "ghcr.io/"
}

@test "build entry point fails closed when extension enumeration cannot parse config" {
    local test_path="$TEST_TEMP_DIR/malformed-enumeration-bin"
    local malformed_config="$TEST_TEMP_DIR/malformed-enumeration.yaml"
    local real_yq
    real_yq="$(command -v yq)"
    mkdir -p "$test_path"
    printf 'extensions: [\n' > "$malformed_config"
    cat > "$test_path/yq" <<EOF
#!/usr/bin/env bash
set -- "\${@:1:\$#-1}" "$malformed_config"
exec "$real_yq" "\$@"
EOF
    chmod +x "$test_path/yq"

    run env PATH="$test_path:$PATH" "$SCRIPTS_DIR/build-extensions.sh" postgres --major-version "$MAJOR_VER" --local-only

    [ "$status" -ne 0 ]
    assert_output_not_contains "All extensions are up to date"
    assert_output_contains "extension enumeration for build mode failed — aborting (fail-closed)"
}

@test "final versionset and multi-arch passes fail closed when extension enumeration fails" {
    export EXTENSION=""
    export DRY_RUN=false
    _mock_failed_extension_enumeration

    run _emit_final_versionset_pass "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR"
    [ "$status" -ne 0 ]
    assert_output_contains "extension enumeration for final versionset pass failed — aborting (fail-closed)"

    run finalize_multiarch_manifests "$CONFIG_FILE" "$MAJOR_VER" "$CONTAINER_DIR"
    [ "$status" -ne 0 ]
    assert_output_contains "extension enumeration for multi-arch manifest finalization failed — aborting (fail-closed)"
}

@test "an empty extension enumeration selects nothing rather than an empty name" {
    export EXTENSION=""
    export LIST_ONLY=false
    export FINALIZE_MULTIARCH=false
    export LOCAL_ONLY=true
    export PULL_ONLY=false
    export DRY_RUN=false
    export MAJOR_VERSION="$MAJOR_VER"
    # Succeeds, emits nothing: every extension disabled, or none reaching this major.
    list_extensions_by_priority() { return 0; }
    _should_build_extension() { printf 'CALLED[%s]\n' "$1"; return 1; }
    validate_extension_package_suffix() { return 0; }
    validate_prerequisites() { return 0; }
    log_dry_run_cache_mode() { :; }
    _emit_final_versionset_pass() { return 0; }

    run main postgres

    [ "$status" -eq 0 ]
    assert_output_not_contains "CALLED["
}

@test "cached resolver treats an unreadable cache entry as a miss" {
    # The cache entry is a regular file this run wrote itself, so no filesystem
    # state makes `cat` fail for a root test runner. Mock the read instead.
    printf '["9.9.9"]\n' > "${_RESOLVER_CACHE_DIR}/pgvector-${MAJOR_VER}.json"
    cat() { return 1; }
    resolve_version_set() { printf '["1.2.3"]\n'; }
    local stderr_file="$TEST_TEMP_DIR/resolver-cache-read.stderr"
    _resolve_cached_with_stderr() {
        _resolve_cached pgvector "$MAJOR_VER" "$CONFIG_FILE" 2> "$stderr_file"
    }

    run _resolve_cached_with_stderr

    [ "$status" -eq 0 ]
    assert_equals '["1.2.3"]' "$output"
    output=$(< "$stderr_file")
    assert_output_contains "resolver cache for pgvector (PG $MAJOR_VER) at ${_RESOLVER_CACHE_DIR}/pgvector-${MAJOR_VER}.json: read failed; resolving normally"
}

@test "cached resolver returns a readable cache entry" {
    printf '["1.2.3"]\n' > "${_RESOLVER_CACHE_DIR}/pgvector-${MAJOR_VER}.json"

    run _resolve_cached pgvector "$MAJOR_VER" "$CONFIG_FILE"

    [ "$status" -eq 0 ]
    assert_equals '["1.2.3"]' "$output"
}

@test "prerequisites require jq as well as yq" {
    local test_path="$TEST_TEMP_DIR/bin"
    mkdir -p "$test_path"
    printf '#!/bin/bash\nexit 0\n' > "$test_path/yq"
    chmod +x "$test_path/yq"

    ROOT_DIR="$TEST_TEMP_DIR" CONTAINER="postgres" PATH="$test_path" run validate_prerequisites
    [ "$status" -ne 0 ]
    assert_output_contains "jq is required for JSON parsing"

    printf '#!/bin/bash\nexit 0\n' > "$test_path/jq"
    chmod +x "$test_path/jq"

    ROOT_DIR="$TEST_TEMP_DIR" CONTAINER="postgres" PATH="$test_path" run validate_prerequisites
    [ "$status" -eq 0 ]
}
