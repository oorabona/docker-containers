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
    local versions base_count dev_count

    versions=$(list_versions "$RUNNER_DIR")
    [[ -n "$versions" ]] || {
        echo "No GitHub runner versions found"
        return 1
    }

    while IFS= read -r version; do
        [[ -z "$version" ]] && continue
        base_count=0
        dev_count=0

        while IFS= read -r variant; do
            case "$variant" in
                windows-ltsc2022-base)
                    base_count=$((base_count + 1))
                    ;;
                windows-ltsc2022-dev)
                    dev_count=$((dev_count + 1))
                    ;;
                windows-*)
                    echo "Unexpected Windows variant in $version: $variant"
                    return 1
                    ;;
                *)
                    continue
                    ;;
            esac
        done < <(list_variants "$RUNNER_DIR" "$version")

        [[ "$base_count" -eq 1 ]] || {
            echo "Expected exactly one windows-ltsc2022-base variant in $version, found $base_count"
            return 1
        }
        [[ "$dev_count" -eq 1 ]] || {
            echo "Expected exactly one windows-ltsc2022-dev variant in $version, found $dev_count"
            return 1
        }

        expected="Dockerfile.windows"
        actual=$(variant_property "$RUNNER_DIR" "windows-ltsc2022-base" "dockerfile" "$version")
        [[ "$actual" == "$expected" ]] || {
            echo "Expected $version/windows-ltsc2022-base to use $expected, got $actual"
            return 1
        }

        expected="Dockerfile.windows-dev"
        actual=$(variant_property "$RUNNER_DIR" "windows-ltsc2022-dev" "dockerfile" "$version")
        [[ "$actual" == "$expected" ]] || {
            echo "Expected $version/windows-ltsc2022-dev to use $expected, got $actual"
            return 1
        }
    done <<< "$versions"
}

# The legacy Windows builder runs every stage before --target, so a second stage
# in the dev file reintroduces the unused-stage build that exhausted runner disk (#1869).
@test "GitHub runner Windows Dockerfiles each contain only their expected FROM instruction" {
    local dockerfile expected from_count actual

    dockerfile="$RUNNER_DIR/Dockerfile.windows"
    expected="FROM mcr.microsoft.com/windows/servercore:ltsc2022 AS base"
    from_count=$(grep -Ec '^FROM .*' "$dockerfile")
    [[ "$from_count" -eq 1 ]] || {
        echo "Expected exactly one FROM instruction in $dockerfile, found $from_count"
        return 1
    }
    actual=$(grep -Ex '^FROM .*' "$dockerfile")
    [[ "$actual" == "$expected" ]] || {
        echo "Expected $dockerfile to contain '$expected', got '$actual'"
        return 1
    }

    dockerfile="$RUNNER_DIR/Dockerfile.windows-dev"
    expected="FROM mcr.microsoft.com/windows/server:ltsc2022 AS dev"
    from_count=$(grep -Ec '^FROM .*' "$dockerfile")
    [[ "$from_count" -eq 1 ]] || {
        echo "Expected exactly one FROM instruction in $dockerfile, found $from_count"
        return 1
    }
    actual=$(grep -Ex '^FROM .*' "$dockerfile")
    [[ "$actual" == "$expected" ]] || {
        echo "Expected $dockerfile to contain '$expected', got '$actual'"
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
