#!/usr/bin/env bats

# The helper owns both alias names and publisher ownership. Publishers only
# name themselves and pass cell attributes.

load "../test_helper"

setup() {
    ROUTING_SCRIPT="$PROJECT_ROOT/scripts/list-cell-rolling-tag-suffixes.sh"
    ACTION="$PROJECT_ROOT/.github/actions/build-container/action.yaml"
    WORKFLOW="$PROJECT_ROOT/.github/workflows/auto-build.yaml"
}

@test "a default cell has bare latest only, owned by its publisher" {
    run "$ROUTING_SCRIPT" "linux-manifest" "18-alpine-base" "linux" "base" "base" "true"

    [ "$status" -eq 0 ]
    [ "$output" = "latest" ] || {
        echo "ASSERTION FAILED: a default cell must publish bare latest and no variant alias" >&2
        return 1
    }
}

@test "Windows aliases are partitioned between the action and manifest publishers" {
    run "$ROUTING_SCRIPT" "windows-action" \
        "2.337.0-windows-ltsc2022-dev" "windows" \
        "windows-ltsc2022-dev" "windows-ltsc2022" "false"

    [ "$status" -eq 0 ]
    [ "$output" = "latest-windows-ltsc2022" ] || {
        echo "ASSERTION FAILED: the Windows action must own only the flavor alias" >&2
        return 1
    }

    run "$ROUTING_SCRIPT" "windows-manifest" \
        "2.337.0-windows-ltsc2022-dev" "windows" \
        "windows-ltsc2022-dev" "windows-ltsc2022" "false"

    [ "$status" -eq 0 ]
    [ "$output" = "latest-windows-ltsc2022-dev" ] || {
        echo "ASSERTION FAILED: the Windows manifest publisher must own only the variant alias" >&2
        return 1
    }
}

@test "a Windows alias with equal variant and flavor has one writer" {
    run "$ROUTING_SCRIPT" "windows-action" \
        "2.337.0-windows-ltsc2022" "windows" \
        "windows-ltsc2022" "windows-ltsc2022" "false"
    [ "$status" -eq 0 ]
    [ "$output" = "latest-windows-ltsc2022" ]

    run "$ROUTING_SCRIPT" "windows-manifest" \
        "2.337.0-windows-ltsc2022" "windows" \
        "windows-ltsc2022" "windows-ltsc2022" "false"
    [ "$status" -eq 0 ]
    [ -z "$output" ] || {
        echo "ASSERTION FAILED: an equal Windows variant/flavor alias must have one publisher" >&2
        return 1
    }
}

@test "manifest helper asks the shared owner router for a Linux cell variant alias" {
    source "$PROJECT_ROOT/helpers/create-manifest.sh"
    export TAG="18-alpine-vector" VERSION="18" FULL_VERSION="18.3-alpine"
    export CELL_OS="linux" VARIANT="vector" FLAVOR="alpine"
    export IS_DEFAULT="false" IS_LATEST_VERSION="true"

    run _compute_tag_args "ghcr.io/example/postgres"

    [ "$status" -eq 0 ]
    [[ "$output" == *'-t ghcr.io/example/postgres:latest-vector'* ]] || {
        echo "ASSERTION FAILED: a non-default Linux cell must publish its variant alias through the manifest helper" >&2
        return 1
    }
}

@test "build-container action asks only for its Windows ownership share" {
    local run_body
    run_body=$(yq -r '.runs.steps[] | select(.name == "Create early tag alias") | .run' "$ACTION")

    [[ "$run_body" == *'list-cell-rolling-tag-suffixes.sh'* &&
       "$run_body" == *'"windows-action" "$current_tag" "windows" "$variant" "$flavor" "$is_default"'* ]] || {
        echo "ASSERTION FAILED: the build-container action must request only its owned Windows aliases" >&2
        return 1
    }
    [[ "$run_body" != *'latest_tag="latest'* && "$run_body" != *'${{ '* ]] || {
        echo "ASSERTION FAILED: the build-container action must not reintroduce inline rolling-tag naming" >&2
        return 1
    }
}

@test "auto-build Windows manifest steps ask only for their ownership share" {
    local step_name run_body query count=0
    local -a manifest_steps=(
        $'Create GHCR multi-arch manifest (primary)\t.jobs."create-manifest".steps[] | select(.name == "Create GHCR multi-arch manifest (primary)") | .run'
        $'Create Docker Hub multi-arch manifest (secondary)\t.jobs."create-manifest".steps[] | select(.name == "Create Docker Hub multi-arch manifest (secondary)") | .run'
    )
    for manifest_step in "${manifest_steps[@]}"; do
        step_name="${manifest_step%%$'\t'*}"
        query="${manifest_step#*$'\t'}"
        run_body=$(yq -r "$query" "$WORKFLOW")
        [[ "$run_body" == *'"windows-manifest" "$TAG" "$CELL_OS" "$VARIANT" "$FLAVOR" "$IS_DEFAULT"'* ]] || {
            echo "ASSERTION FAILED: $step_name must request only its owned Windows aliases" >&2
            return 1
        }
        [[ "$run_body" != *'latest_tag="latest'* && "$run_body" != *'${{ '* ]] || {
            echo "ASSERTION FAILED: $step_name must not reintroduce inline rolling-tag naming" >&2
            return 1
        }
        count=$((count + 1))
    done

    [ "$count" -eq 2 ]
}
