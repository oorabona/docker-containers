#!/usr/bin/env bats

# The helper owns rolling-alias routing. Composite-action and workflow run
# bodies only supply cell attributes and publish the suffixes it returns.

load "../test_helper"

setup() {
    ROUTING_SCRIPT="$PROJECT_ROOT/scripts/list-cell-rolling-tag-suffixes.sh"
    ACTION="$PROJECT_ROOT/.github/actions/build-container/action.yaml"
    WORKFLOW="$PROJECT_ROOT/.github/workflows/auto-build.yaml"
}

@test "rolling suffix script preserves both aliases for a Windows github-runner cell" {
    run "$ROUTING_SCRIPT" \
        "2.337.0-windows-ltsc2022-dev" "windows" \
        "windows-ltsc2022-dev" "windows-ltsc2022" "false"

    [ "$status" -eq 0 ]
    [ "$output" = $'latest-windows-ltsc2022-dev\nlatest-windows-ltsc2022' ] || {
        echo "ASSERTION FAILED: a Windows github-runner cell must publish both its variant and flavor rolling aliases through the shared routing helper" >&2
        return 1
    }
}

@test "rolling suffix script preserves a Linux cell variant alias" {
    run "$ROUTING_SCRIPT" "18-alpine-vector" "linux" "vector" "alpine" "false"

    [ "$status" -eq 0 ]
    [ "$output" = "latest-vector" ] || {
        echo "ASSERTION FAILED: a Linux cell must publish its variant rolling alias through the shared routing helper" >&2
        return 1
    }
}

@test "manifest helper asks the shared router for a Linux cell variant alias" {
    source "$PROJECT_ROOT/helpers/create-manifest.sh"
    export TAG="18-alpine-vector" VERSION="18" FULL_VERSION="18.3-alpine"
    export CELL_OS="linux" VARIANT="vector" FLAVOR="alpine"
    export IS_DEFAULT="false" IS_LATEST_VERSION="true"

    run _compute_tag_args "ghcr.io/example/postgres"

    [ "$status" -eq 0 ]
    [[ "$output" == *'-t ghcr.io/example/postgres:latest-vector'* ]] || {
        echo "ASSERTION FAILED: a Linux cell must publish its variant alias through the workflow manifest helper" >&2
        return 1
    }
}

@test "build-container action publishes both Windows github-runner aliases" {
    local run_body stub_dir docker_log
    run_body=$(yq -r '.runs.steps[] | select(.name == "Create early tag alias") | .run' "$ACTION")
    stub_dir="$BATS_TEST_TMPDIR/docker-stub"
    docker_log="$BATS_TEST_TMPDIR/docker-calls"
    mkdir -p "$stub_dir"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$DOCKER_CALL_LOG"\n' > "$stub_dir/docker"
    chmod +x "$stub_dir/docker"

    run env \
        PATH="$stub_dir:$PATH" \
        DOCKER_CALL_LOG="$docker_log" \
        IMAGE_NAME="example/github-runner" \
        CURRENT_TAG="2.337.0-windows-ltsc2022-dev" \
        PLATFORM_SUFFIX="amd64" \
        VARIANT="windows-ltsc2022-dev" \
        FLAVOR="windows-ltsc2022" \
        IS_DEFAULT="false" \
        RUNNER_OS_VALUE="Windows" \
        DOCKERHUB_PUSH_SUCCEEDED="true" \
        bash -c 'cd "$1"; eval "$2"' _ "$PROJECT_ROOT" "$run_body"

    [ "$status" -eq 0 ]
    grep -qF -- '--tag ghcr.io/example/github-runner:latest-windows-ltsc2022-dev' "$docker_log"
    grep -qF -- '--tag ghcr.io/example/github-runner:latest-windows-ltsc2022' "$docker_log"
    grep -qF -- '--tag docker.io/example/github-runner:latest-windows-ltsc2022-dev' "$docker_log"
    grep -qF -- '--tag docker.io/example/github-runner:latest-windows-ltsc2022' "$docker_log" || {
        echo "ASSERTION FAILED: a Windows github-runner action cell must publish both variant and flavor aliases to both registries" >&2
        return 1
    }
}

@test "build-container action delegates Windows aliases without inline routing" {
    local run_body
    run_body=$(yq -r '.runs.steps[] | select(.name == "Create early tag alias") | .run' "$ACTION")

    [[ "$run_body" == *'list-cell-rolling-tag-suffixes.sh'* ]] || {
        echo "ASSERTION FAILED: the build-container action must ask the rolling-alias helper wrapper" >&2
        return 1
    }
    [[ "$run_body" == *'"$current_tag" "windows" "$variant" "$flavor" "$is_default"'* ]] || {
        echo "ASSERTION FAILED: the build-container action must pass its Windows cell variant and flavor to the routing helper" >&2
        return 1
    }
    [[ "$run_body" != *'latest_tag="latest'* ]] || {
        echo "ASSERTION FAILED: reintroducing inline latest-tag computation in the build-container action is forbidden" >&2
        return 1
    }
    [[ "$run_body" != *'${{ '* ]] || {
        echo "ASSERTION FAILED: the build-container action must consume GitHub values through quoted environment variables" >&2
        return 1
    }
}

@test "auto-build manifest steps delegate aliases without inline routing" {
    local step_name run_body query count=0
    local -a manifest_steps=(
        $'Create GHCR multi-arch manifest (primary)\t.jobs."create-manifest".steps[] | select(.name == "Create GHCR multi-arch manifest (primary)") | .run'
        $'Create Docker Hub multi-arch manifest (secondary)\t.jobs."create-manifest".steps[] | select(.name == "Create Docker Hub multi-arch manifest (secondary)") | .run'
    )
    for manifest_step in "${manifest_steps[@]}"; do
        step_name="${manifest_step%%$'\t'*}"
        query="${manifest_step#*$'\t'}"
        run_body=$(yq -r "$query" "$WORKFLOW")
        [[ "$run_body" == *'list-cell-rolling-tag-suffixes.sh'* ]] || {
            echo "ASSERTION FAILED: $step_name must ask the rolling-alias helper wrapper" >&2
            return 1
        }
        count=$((count + 1))
        [[ "$run_body" == *'"$TAG"'* && "$run_body" == *'"$CELL_OS"'* &&
           "$run_body" == *'"$VARIANT"'* && "$run_body" == *'"$FLAVOR"'* &&
           "$run_body" == *'"$IS_DEFAULT"'* ]] || {
            echo "ASSERTION FAILED: each auto-build manifest consumer must pass its cell attributes to the routing helper" >&2
            return 1
        }
        [[ "$run_body" != *'latest_tag="latest'* ]] || {
            echo "ASSERTION FAILED: reintroducing inline latest-tag computation in auto-build is forbidden" >&2
            return 1
        }
        [[ "$run_body" != *'${{ '* ]] || {
            echo "ASSERTION FAILED: auto-build manifest consumers must consume GitHub values through quoted environment variables" >&2
            return 1
        }
    done

    [ "$count" -eq 2 ] || {
        echo "ASSERTION FAILED: both GHCR and Docker Hub auto-build manifest consumers must delegate rolling aliases" >&2
        return 1
    }
}
