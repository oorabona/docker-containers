#!/usr/bin/env bats

# Unit tests for _should_build_extension() in scripts/build-extensions.sh
#
# 8-case truth table covering LOCAL_ONLY, FORCE, docker-inspect result,
# registry presence, and missing Dockerfile.
#
# Mocking strategy:
#   - docker()           : bash function override (exits 0 = image found, 1 = not found)
#   - image_exists_in_registry(): bash function override (same convention)
#   - ext_config()       : returns a deterministic version "1.2.3"
#   - ext_image_name()   : returns a deterministic tag "ghcr.io/test/ext-pgvector:pg17-1.2.3"
#   - Dockerfile presence: created/absent in TEST_TEMP_DIR

load "../test_helper"

# ---------------------------------------------------------------------------
# Source helper: push to scripts/ so SCRIPT_DIR/ROOT_DIR resolve correctly.
# build-extensions.sh has a BASH_SOURCE guard so main() is NOT called when
# the script is sourced rather than executed directly.
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

    # Override ROOT_DIR so that build-extensions.sh path resolution doesn't
    # point at the real repo (we re-assign after sourcing below)
    export ROOT_DIR="$TEST_TEMP_DIR"

    _source_build_extensions

    # Install mocks AFTER sourcing — build-extensions.sh sources
    # helpers/extension-utils.sh which defines real `ext_config` and
    # `ext_image_name`. Mocks declared before would be overwritten.
    _setup_default_mocks

    # After sourcing, redirect ROOT_DIR to our temp tree
    ROOT_DIR="$TEST_TEMP_DIR"
}

teardown() {
    teardown_temp_dir
    unset FORCE LOCAL_ONLY CONTAINER ROOT_DIR
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
    ! [[ '-foo' =~ ^[A-Za-z0-9_][A-Za-z0-9_-]*$ ]] || {
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
