#!/usr/bin/env bats

# Opt-in image qualification for the ARC sample. It does not contact GitHub or
# exercise a Kubernetes cluster. Set ARC_RUNTIME_TESTS=1, ARC_TEST_RUNTIME to
# podman or docker, and ARC_TEST_IMAGE to a pre-pulled image to run it.

SAMPLE_RUNNER_ROOT=/home/runner/actions-runner
SAMPLE_WORKDIR=/home/runner/actions-runner/_work
SAMPLE_TOOL_CACHE=/home/runner/actions-runner/_tool

setup() {
    local arc_values expected_image runner

    CONTAINER_NAME=
    VOLUME_NAME=
    if [[ "${ARC_RUNTIME_TESTS:-}" != 1 ]]; then
        skip "set ARC_RUNTIME_TESTS=1 to run the pre-pulled ARC image qualification"
    fi
    : "${ARC_TEST_RUNTIME:?set ARC_TEST_RUNTIME to podman or docker}"
    : "${ARC_TEST_IMAGE:?set ARC_TEST_IMAGE to the pre-pulled image reference}"
    case "$ARC_TEST_RUNTIME" in
        podman|docker) ;;
        *) printf 'ARC_TEST_RUNTIME must be podman or docker, got %s\n' "$ARC_TEST_RUNTIME" >&2; return 1 ;;
    esac
    arc_values="$BATS_TEST_DIRNAME/../examples/arc-values.yaml"
    runner=$(yq -o=json '.template.spec.containers[] | select(.name == "runner")' "$arc_values") || return 1
    expected_image=$(jq -er '.image' <<<"$runner") || return 1
    if [[ "$ARC_TEST_IMAGE" != "$expected_image" ]]; then
        printf 'ARC_TEST_IMAGE must equal the ARC sample runner image: expected %s, got %s\n' \
            "$expected_image" "$ARC_TEST_IMAGE" >&2
        return 1
    fi
    command -v "$ARC_TEST_RUNTIME" >/dev/null || {
        printf 'ARC_TEST_RUNTIME is unavailable: %s\n' "$ARC_TEST_RUNTIME" >&2
        return 1
    }
    CONTAINER_NAME="arc-offline-${BATS_TEST_NUMBER}-$$"
    VOLUME_NAME="${CONTAINER_NAME}-work"
    "$ARC_TEST_RUNTIME" volume create "$VOLUME_NAME" >/dev/null
    "$ARC_TEST_RUNTIME" run --name "${CONTAINER_NAME}-init" --pull=never --network=none \
        --user 0:0 --cap-drop=ALL --cap-add=CHOWN --security-opt=no-new-privileges \
        --volume "$VOLUME_NAME:/probe" \
        --entrypoint /bin/bash "$ARC_TEST_IMAGE" -ec \
        'chmod 2770 /probe && chown 0:1001 /probe'
}

teardown() {
    if [[ -n "${ARC_TEST_RUNTIME:-}" && -n "${CONTAINER_NAME:-}" ]]; then
        "$ARC_TEST_RUNTIME" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
        "$ARC_TEST_RUNTIME" rm -f "${CONTAINER_NAME}-init" >/dev/null 2>&1 || true
    fi
    if [[ -n "${ARC_TEST_RUNTIME:-}" && -n "${VOLUME_NAME:-}" ]]; then
        "$ARC_TEST_RUNTIME" volume rm -f "$VOLUME_NAME" >/dev/null 2>&1 || true
    fi
}

jit_payload() {
    local runner_json runner_base64 map
    runner_json=$(jq -cn --arg work "$SAMPLE_WORKDIR" '{AgentId:"OFFLINE_JIT_PROBE", WorkFolder:$work, Ephemeral:true}')
    runner_base64=$(printf '%s' "$runner_json" | base64 -w0)
    map=$(jq -cn --arg config "$runner_base64" '{".runner":$config}')
    printf '%s' "$map" | base64 -w0
}

run_sample() {
    local payload="$1"
    "$ARC_TEST_RUNTIME" run --name "$CONTAINER_NAME" --pull=never --network=none \
        --user 1001:1001 --cap-drop=ALL --security-opt=no-new-privileges \
        --volume "$VOLUME_NAME:$SAMPLE_WORKDIR" \
        --workdir "$SAMPLE_WORKDIR" \
        --env HOME=/home/runner \
        --env RUNNER_TOOL_CACHE="$SAMPLE_TOOL_CACHE" \
        --env RUNNER_MANUALLY_TRAP_SIG=1 \
        --env ACTIONS_RUNNER_INPUT_JITCONFIG="$payload" \
        --entrypoint "$SAMPLE_RUNNER_ROOT/run.sh" "$ARC_TEST_IMAGE"
}

wait_for_controlled_helper_file() {
    local path="$1" attempt

    for ((attempt = 0; attempt < 50; attempt++)); do
        if "$ARC_TEST_RUNTIME" exec "$CONTAINER_NAME" test -f "$path"; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

wait_for_container_stop() {
    local running attempt

    for ((attempt = 0; attempt < 50; attempt++)); do
        running=$("$ARC_TEST_RUNTIME" inspect --format '{{.State.Running}}' "$CONTAINER_NAME") || return 1
        if [[ "$running" == false ]]; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

@test "pinned Ubuntu image exposes the runner, Node, writable tool cache, and group-writable work directory" {
    # shellcheck disable=SC2016 # Variables expand in the container's Bash process.
    run "$ARC_TEST_RUNTIME" run --rm --pull=never --network=none \
        --user 1001:1001 --cap-drop=ALL --security-opt=no-new-privileges \
        --volume "$VOLUME_NAME:$SAMPLE_WORKDIR" \
        --workdir "$SAMPLE_WORKDIR" \
        --env HOME=/home/runner \
        --env RUNNER_TOOL_CACHE="$SAMPLE_TOOL_CACHE" \
        --entrypoint /bin/bash "$ARC_TEST_IMAGE" -ec '
            test -x /home/runner/actions-runner/run.sh
            test -x /home/runner/actions-runner/bin/Runner.Listener
            /home/runner/actions-runner/bin/Runner.Listener --version
            '"$SAMPLE_RUNNER_ROOT"'/externals/node24/bin/node --version
            mkdir -p "$RUNNER_TOOL_CACHE"
            touch "$RUNNER_TOOL_CACHE/arc-offline-probe" "$PWD/arc-offline-probe"
            test "$(stat -c %u:%g:%a "$PWD")" = 0:1001:2770
        '
    [ "$status" -eq 0 ]
    [[ "$output" == *'2.338.2'* ]]
    [[ "$output" == *'v24.22.1'* ]]
}

@test "offline JIT input follows the ARC sample command and writes the runner-root configuration" {
    payload=$(jit_payload)
    run run_sample "$payload"
    [ "$status" -eq 0 ]
    [[ "$output" == *'UInt64'* ]]

    "$ARC_TEST_RUNTIME" cp "$CONTAINER_NAME:$SAMPLE_RUNNER_ROOT/.runner" "$BATS_TEST_TMPDIR/.runner"
    [ "$(jq -r '.AgentId' "$BATS_TEST_TMPDIR/.runner")" = OFFLINE_JIT_PROBE ]
    [ "$(jq -r '.WorkFolder' "$BATS_TEST_TMPDIR/.runner")" = "$SAMPLE_WORKDIR" ]
    [ "$(jq -r '.Ephemeral' "$BATS_TEST_TMPDIR/.runner")" = true ]

    "$ARC_TEST_RUNTIME" export "$CONTAINER_NAME" > "$BATS_TEST_TMPDIR/container.tar"
    tar --numeric-owner -tvf "$BATS_TEST_TMPDIR/container.tar" | grep -Eq '1001/1001 .*home/runner/actions-runner/\.runner$'
    "$ARC_TEST_RUNTIME" inspect "$CONTAINER_NAME" | jq -e --arg work "$SAMPLE_WORKDIR" --arg tool "$SAMPLE_TOOL_CACHE" '
        .[0].Config.WorkingDir == $work and
        ([.[0].Config.Env[] | select(. == "HOME=/home/runner" or . == "RUNNER_TOOL_CACHE=" + $tool)] | length) == 2 and
        .[0].HostConfig.NetworkMode == "none"
    ' >/dev/null
}

@test "malformed offline JIT input leaves no runner-root configuration" {
    run run_sample 'not-base64'
    [ "$status" -eq 0 ]
    [[ "$output" == *'Base-64'* || "$output" == *'base64'* ]]
    run "$ARC_TEST_RUNTIME" cp "$CONTAINER_NAME:$SAMPLE_RUNNER_ROOT/.runner" "$BATS_TEST_TMPDIR/.runner"
    [ "$status" -ne 0 ]
}

@test "run.sh PID 1 wrapper forwards TERM to a controlled helper without a job or ARC integration" {
    local helper_template="$BATS_TEST_TMPDIR/controlled-helper-template.sh"
    local ready_marker=/tmp/arc-controlled-helper-ready
    local interrupt_marker=/tmp/arc-controlled-helper-int

    cat > "$helper_template" <<'EOF'
#!/bin/bash
trap 'touch /tmp/arc-controlled-helper-int; exit 0' INT
touch /tmp/arc-controlled-helper-ready
while :; do sleep 0.1; done
EOF
    chmod +x "$helper_template"

    run "$ARC_TEST_RUNTIME" run -d --name "$CONTAINER_NAME" --pull=never --network=none \
        --user 1001:1001 --cap-drop=ALL --security-opt=no-new-privileges \
        --env RUNNER_MANUALLY_TRAP_SIG=1 \
        --volume "$helper_template:$SAMPLE_RUNNER_ROOT/run-helper.sh.template:ro" \
        --entrypoint "$SAMPLE_RUNNER_ROOT/run.sh" "$ARC_TEST_IMAGE"
    [ "$status" -eq 0 ]
    wait_for_controlled_helper_file "$ready_marker"

    run "$ARC_TEST_RUNTIME" kill --signal TERM "$CONTAINER_NAME"
    [ "$status" -eq 0 ]
    wait_for_container_stop

    "$ARC_TEST_RUNTIME" cp "$CONTAINER_NAME:$interrupt_marker" "$BATS_TEST_TMPDIR/controlled-helper-int"
    [ -f "$BATS_TEST_TMPDIR/controlled-helper-int" ]
    run "$ARC_TEST_RUNTIME" inspect --format '{{.State.ExitCode}}' "$CONTAINER_NAME"
    [ "$status" -eq 0 ]
    [ "$output" -eq 143 ]
}

@test "standalone entrypoint reports the missing scope input first" {
    run "$ARC_TEST_RUNTIME" run --rm --pull=never --network=none "$ARC_TEST_IMAGE"
    [ "$status" -ne 0 ]
    [[ "$output" == *'[ERROR] Must set GITHUB_REPOSITORY (owner/repo) or GITHUB_ORG (myorg).'* ]]
}
