#!/usr/bin/env bats

# Execute the primary Windows manifest workflow body with a mocked registry.
# The GHCR aliases are required publication refs; Docker Hub remains secondary.

load "../test_helper"

setup() {
    WORKFLOW="$PROJECT_ROOT/.github/workflows/auto-build.yaml"
    setup_temp_dir
    mkdir -p "$TEST_TEMP_DIR/bin"
    CALL_LOG="$TEST_TEMP_DIR/imagetools-calls"
    STEP_BODY=$(yq -r '.jobs."create-manifest".steps[] | select(.name == "Create GHCR multi-arch manifest (primary)") | .run' "$WORKFLOW")
}

teardown() {
    teardown_temp_dir
}

_install_registry_mocks() {
    cat > "$TEST_TEMP_DIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

target=""
source_ref="${!#}"
while (($#)); do
    if [[ "$1" == "-t" ]]; then
        target="$2"
        shift 2
        continue
    fi
    shift
done

printf '%s\t%s\n' "$target" "$source_ref" >> "$DOCKER_CALL_LOG"
! grep -F -x -- "$target" <<< "${FAIL_REFS:-}"
EOF
    chmod +x "$TEST_TEMP_DIR/bin/docker"

    # Retries are part of the workflow contract; avoid making a refusal test
    # wait through the real backoff intervals.
    cat > "$TEST_TEMP_DIR/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/sleep"
}

_run_windows_manifest() {
    local failed_refs=${1:-}
    _install_registry_mocks

    run env \
        PATH="$TEST_TEMP_DIR/bin:$PATH" \
        DOCKER_CALL_LOG="$CALL_LOG" \
        FAIL_REFS="$failed_refs" \
        CELL_OS=windows \
        GITHUB_USERNAME=example \
        CONTAINER=runner \
        TAG=2.337.0-windows-ltsc2022-dev \
        IS_LATEST_VERSION=true \
        VARIANT=windows-ltsc2022-dev \
        FLAVOR=windows-ltsc2022 \
        IS_DEFAULT=false \
        bash -c 'cd "$1" && bash -c "$2"' _ "$PROJECT_ROOT" "$STEP_BODY"
}

_calls_for() {
    local destination=$1
    local source=$2
    printf '%s\t%s\n' "$destination" "$source" | grep -F -x -f - "$CALL_LOG" | wc -l
}

@test "a failed primary versioned GHCR alias fails the step after retrying and still attempts rolling aliases" {
    local versioned_ref="ghcr.io/example/runner:2.337.0-windows-ltsc2022-dev"
    local rolling_ref="ghcr.io/example/runner:latest-windows-ltsc2022-dev"
    local source_ref="ghcr.io/example/runner:2.337.0-windows-ltsc2022-dev-amd64"

    _run_windows_manifest "$versioned_ref"

    [ "$status" -eq 1 ] || {
        echo "ASSERTION FAILED: a failed required versioned GHCR alias must fail the primary manifest step" >&2
        return 1
    }
    [[ "$output" == *"::error::Failed to create required GHCR ref: $versioned_ref"* ]] || {
        echo "ASSERTION FAILED: the versioned-alias failure must name its GHCR ref" >&2
        return 1
    }
    [ "$(_calls_for "$versioned_ref" "$source_ref")" -eq 3 ] || {
        echo "ASSERTION FAILED: the failed versioned alias must use all three retry attempts" >&2
        return 1
    }
    [ "$(_calls_for "$rolling_ref" "$source_ref")" -eq 1 ] || {
        echo "ASSERTION FAILED: rolling aliases must still be attempted after a versioned-alias failure" >&2
        return 1
    }
}

@test "a failed primary rolling GHCR alias fails the step after retrying" {
    local rolling_ref="ghcr.io/example/runner:latest-windows-ltsc2022-dev"
    local source_ref="ghcr.io/example/runner:2.337.0-windows-ltsc2022-dev-amd64"

    _run_windows_manifest "$rolling_ref"

    [ "$status" -eq 1 ] || {
        echo "ASSERTION FAILED: a failed required rolling GHCR alias must fail the primary manifest step" >&2
        return 1
    }
    [[ "$output" == *"::error::Failed to create required GHCR ref: $rolling_ref"* ]] || {
        echo "ASSERTION FAILED: the rolling-alias failure must name its GHCR ref" >&2
        return 1
    }
    [ "$(_calls_for "$rolling_ref" "$source_ref")" -eq 3 ] || {
        echo "ASSERTION FAILED: the failed rolling alias must use all three retry attempts" >&2
        return 1
    }
}

@test "all required primary GHCR aliases succeeding leaves the Windows manifest step green" {
    local versioned_ref="ghcr.io/example/runner:2.337.0-windows-ltsc2022-dev"
    local rolling_ref="ghcr.io/example/runner:latest-windows-ltsc2022-dev"
    local source_ref="ghcr.io/example/runner:2.337.0-windows-ltsc2022-dev-amd64"

    _run_windows_manifest

    [ "$status" -eq 0 ] || {
        echo "ASSERTION FAILED: successful required GHCR aliases must leave the primary manifest step green" >&2
        return 1
    }
    [ "$(_calls_for "$versioned_ref" "$source_ref")" -eq 1 ] || {
        echo "ASSERTION FAILED: the versioned alias must be created exactly once from the Windows amd64 image" >&2
        return 1
    }
    [ "$(_calls_for "$rolling_ref" "$source_ref")" -eq 1 ] || {
        echo "ASSERTION FAILED: the rolling alias must be created exactly once from the Windows amd64 image" >&2
        return 1
    }
}

@test "both failed required GHCR aliases are retried, reported, and aggregated" {
    local versioned_ref="ghcr.io/example/runner:2.337.0-windows-ltsc2022-dev"
    local rolling_ref="ghcr.io/example/runner:latest-windows-ltsc2022-dev"
    local source_ref="ghcr.io/example/runner:2.337.0-windows-ltsc2022-dev-amd64"
    local failed_refs
    failed_refs=$(printf '%s\n%s' "$versioned_ref" "$rolling_ref")

    _run_windows_manifest "$failed_refs"

    [ "$status" -eq 1 ] || {
        echo "ASSERTION FAILED: failures of both required GHCR aliases must fail the primary manifest step" >&2
        return 1
    }
    [[ "$output" == *"::error::Failed to create required GHCR ref: $versioned_ref"* &&
       "$output" == *"::error::Failed to create required GHCR ref: $rolling_ref"* ]] || {
        echo "ASSERTION FAILED: each failed required GHCR alias must have its own error" >&2
        return 1
    }
    [[ "$output" == *"::error::Failed to create required GHCR refs after retries: $versioned_ref $rolling_ref"* ]] || {
        echo "ASSERTION FAILED: the aggregate error must name every failed required GHCR alias" >&2
        return 1
    }
    [ "$(_calls_for "$versioned_ref" "$source_ref")" -eq 3 ] || {
        echo "ASSERTION FAILED: the failed versioned alias must use all three retry attempts" >&2
        return 1
    }
    [ "$(_calls_for "$rolling_ref" "$source_ref")" -eq 3 ] || {
        echo "ASSERTION FAILED: the failed rolling alias must use all three retry attempts" >&2
        return 1
    }
}

@test "the Docker Hub manifest remains a secondary best-effort publisher" {
    local dockerhub_body continue_on_error
    dockerhub_body=$(yq -r '.jobs."create-manifest".steps[] | select(.name == "Create Docker Hub multi-arch manifest (secondary)") | .run' "$WORKFLOW")
    continue_on_error=$(yq -r '.jobs."create-manifest".steps[] | select(.name == "Create Docker Hub multi-arch manifest (secondary)") | ."continue-on-error"' "$WORKFLOW")

    [ "$continue_on_error" = true ] || {
        echo "ASSERTION FAILED: Docker Hub manifest publishing must remain continue-on-error" >&2
        return 1
    }
    [[ "$dockerhub_body" == *'docker buildx imagetools create -t "$dh_dst" "$dh_src" || echo "::warning::Failed to create Docker Hub tag alias"'* &&
       "$dockerhub_body" == *'"$dh_src" || true'* ]] || {
        echo "ASSERTION FAILED: Docker Hub Windows aliases must remain best-effort" >&2
        return 1
    }
}
