#!/usr/bin/env bats

# Unit tests for the GitHub runner Windows Dockerfile split.

load "../test_helper"

source_build_script() {
    pushd "$SCRIPTS_DIR" > /dev/null 2>&1 || return 1
    source "./build-container.sh"
    popd > /dev/null 2>&1 || return 1
}

setup() {
    export ORIGINAL_PATH="$PATH"
    export RUNNER_DIR="${GITHUB_RUNNER_DIR:-$PROJECT_ROOT/github-runner}"

    source "$HELPERS_DIR/logging.sh"
    source "$HELPERS_DIR/variant-utils.sh"
    source_build_script

    # _resolve_base_image probes image manifests after computing the reference.
    # This stub preserves that production function's parsing path without a network call.
    # shellcheck disable=SC2317 # Invoked indirectly by _resolve_base_image.
    docker() { return 0; }
}

teardown() {
    export PATH="$ORIGINAL_PATH"
    unset RUNNER_DIR
}

@test "GitHub runner Windows variants route every base and dev cell to its Dockerfile" {
    local version variant expected actual
    local cells_checked=0

    while IFS= read -r version; do
        [[ -z "$version" ]] && continue
        while IFS= read -r variant; do
            case "$variant" in
                windows-ltsc2022-base)
                    expected="Dockerfile.windows"
                    ;;
                windows-ltsc2022-dev)
                    expected="Dockerfile.windows-dev"
                    ;;
                windows-ltsc2022-*)
                    echo "Unexpected Windows variant in $version: $variant"
                    return 1
                    ;;
                *)
                    continue
                    ;;
            esac

            actual=$(variant_property "$RUNNER_DIR" "$variant" "dockerfile" "$version")
            [[ "$actual" == "$expected" ]] || {
                echo "Expected $version/$variant to use $expected, got $actual"
                return 1
            }
            cells_checked=$((cells_checked + 1))
        done < <(list_variants "$RUNNER_DIR" "$version")
    done < <(list_versions "$RUNNER_DIR")

    [[ "$cells_checked" -gt 0 ]] || {
        echo "No Windows variant cells found"
        return 1
    }
}

@test "GitHub runner Windows Dockerfiles derive their distinct base-image references" {
    local label_args=""

    cd "$RUNNER_DIR"

    _resolve_base_image "Dockerfile.windows" "2.337.0" "label_args"
    [[ "$_BASE_IMAGE_REF" == "mcr.microsoft.com/windows/servercore:ltsc2022" ]] || {
        echo "Expected Dockerfile.windows base image mcr.microsoft.com/windows/servercore:ltsc2022, got $_BASE_IMAGE_REF"
        return 1
    }

    _resolve_base_image "Dockerfile.windows-dev" "2.337.0" "label_args"
    [[ "$_BASE_IMAGE_REF" == "mcr.microsoft.com/windows/server:ltsc2022" ]] || {
        echo "Expected Dockerfile.windows-dev base image mcr.microsoft.com/windows/server:ltsc2022, got $_BASE_IMAGE_REF"
        return 1
    }
    [[ -z "$label_args" ]]
}
