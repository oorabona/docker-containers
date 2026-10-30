#!/usr/bin/env bats

# Opt-in image qualification for the ARC sample. It does not contact GitHub or
# exercise a Kubernetes cluster. Set ARC_RUNTIME_TESTS=1, ARC_TEST_RUNTIME to
# podman or docker, and ARC_TEST_IMAGE to a pre-pulled image to run it.
#
# Host tools: Bash, Bats Core, jq, Mike Farah yq v4, tr, grep -E, base64 (GNU or
# BSD; line wrapping is stripped with tr), and a tar that lists with -tv and
# accepts --numeric-owner (GNU tar or bsdtar). `timeout` (or Homebrew's
# `gtimeout`) bounds every runtime call to ARC_TEST_TIMEOUT seconds (default
# 120); without either, calls are unbounded. Only Podman on Linux without
# SELinux enforcement has been measured; the `z` relabel option and the BSD
# tool paths below are not yet qualified on a real host.
#
# Every container and volume carries the label arc-offline-test=<run id>. A new
# name must be unused, and teardown only removes resources carrying this run's
# label, so a stale resource from an earlier run is reported, never reused or
# deleted.

SAMPLE_RUNNER_ROOT=/home/runner/actions-runner
SAMPLE_WORKDIR=/home/runner/actions-runner/_work
SAMPLE_TOOL_CACHE=/home/runner/actions-runner/_tool

setup() {
    local arc_values expected_image runner

    CONTAINER_NAME=
    INIT_NAME=
    VOLUME_NAME=
    RUN_ID=
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
    RUN_ID="$(date +%s)-$$-${RANDOM}"
    CONTAINER_NAME="arc-offline-${BATS_TEST_NUMBER}-${RUN_ID}"
    INIT_NAME="${CONTAINER_NAME}-init"
    VOLUME_NAME="${CONTAINER_NAME}-work"
    require_unused_name container "$CONTAINER_NAME" || return 1
    require_unused_name container "$INIT_NAME" || return 1
    require_unused_name volume "$VOLUME_NAME" || return 1
    rt volume create --label "$RUN_LABEL=$RUN_ID" "$VOLUME_NAME" >/dev/null
    rt run --name "$INIT_NAME" --label "$RUN_LABEL=$RUN_ID" --pull=never --network=none \
        --user 0:0 --cap-drop=ALL --cap-add=CHOWN --security-opt=no-new-privileges \
        --volume "$VOLUME_NAME:/probe" \
        --entrypoint /bin/bash "$ARC_TEST_IMAGE" -ec \
        'chmod 2770 /probe && chown 0:1001 /probe'
}

teardown() {
    if [[ -n "${ARC_TEST_RUNTIME:-}" && -n "${RUN_ID:-}" ]]; then
        remove_owned container "$CONTAINER_NAME"
        remove_owned container "$INIT_NAME"
        remove_owned volume "$VOLUME_NAME"
    fi
}

# Run the runtime under a deadline so a wedged daemon or container cannot hang
# the suite silently; exit 124 is reported with the command that stalled.
rt() {
    local limit="${ARC_TEST_TIMEOUT:-120}" bound status=0

    bound=$(command -v timeout || command -v gtimeout || true)
    if [[ -n "$bound" ]]; then
        "$bound" "$limit" "$ARC_TEST_RUNTIME" "$@" || status=$?
        if [[ "$status" -eq 124 ]]; then
            printf 'runtime call timed out after %ss: %s %s\n' "$limit" "$ARC_TEST_RUNTIME" "$*" >&2
        fi
        return "$status"
    fi
    "$ARC_TEST_RUNTIME" "$@"
}

RUN_LABEL=arc-offline-test

# The name must not exist yet: reusing a stale resource would test the wrong state.
require_unused_name() {
    local kind="$1" name="$2"

    if rt "$kind" inspect "$name" >/dev/null 2>&1; then
        printf 'stale %s %s already exists; remove it manually, it is not owned by this run\n' "$kind" "$name" >&2
        return 1
    fi
}

# Remove a container or volume only if it carries this run's label; report anything else.
remove_owned() {
    local kind="$1" name="$2" fmt owner

    [[ -n "$name" ]] || return 0
    if [[ "$kind" == volume ]]; then
        fmt='{{index .Labels "arc-offline-test"}}'
    else
        fmt='{{index .Config.Labels "arc-offline-test"}}'
    fi
    if ! owner=$(rt "$kind" inspect --format "$fmt" "$name" 2>/dev/null); then
        return 0
    fi
    if [[ "$owner" != "$RUN_ID" ]]; then
        printf 'not removing %s %s: label %s=%q is not this run (%s)\n' "$kind" "$name" "$RUN_LABEL" "$owner" "$RUN_ID" >&2
        return 0
    fi
    if [[ "$kind" == volume ]]; then
        rt volume rm -f "$name" >/dev/null 2>&1 || printf 'cleanup failed: volume %s was not removed\n' "$name" >&2
    else
        rt rm -f "$name" >/dev/null 2>&1 || printf 'cleanup failed: container %s was not removed\n' "$name" >&2
    fi
}

diagnose_container() {
    {
        printf 'container %s state: ' "$CONTAINER_NAME"
        rt inspect --format '{{.State.Status}} exit={{.State.ExitCode}}' "$CONTAINER_NAME" 2>&1 || true
        printf 'last log lines:\n'
        rt logs --tail 20 "$CONTAINER_NAME" 2>&1 || true
    } >&2
}

jit_payload() {
    local runner_json runner_base64 map
    runner_json=$(jq -cn --arg work "$SAMPLE_WORKDIR" '{AgentId:"OFFLINE_JIT_PROBE", WorkFolder:$work, Ephemeral:true}')
    runner_base64=$(printf '%s' "$runner_json" | base64 | tr -d '\r\n')
    map=$(jq -cn --arg config "$runner_base64" '{".runner":$config}')
    printf '%s' "$map" | base64 | tr -d '\r\n'
}

run_sample() {
    local payload="$1"
    rt run --name "$CONTAINER_NAME" --label "$RUN_LABEL=$RUN_ID" --pull=never --network=none \
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
        if rt exec "$CONTAINER_NAME" test -f "$path" 2>/dev/null; then
            return 0
        fi
        sleep 0.1
    done
    printf 'controlled helper never created %s within 5s\n' "$path" >&2
    diagnose_container
    return 1
}

wait_for_container_stop() {
    local running attempt

    for ((attempt = 0; attempt < 50; attempt++)); do
        running=$(rt inspect --format '{{.State.Running}}' "$CONTAINER_NAME") || {
            printf 'could not inspect %s while waiting for it to stop\n' "$CONTAINER_NAME" >&2
            return 1
        }
        if [[ "$running" == false ]]; then
            return 0
        fi
        sleep 0.1
    done
    printf 'container %s still running 5s after TERM\n' "$CONTAINER_NAME" >&2
    diagnose_container
    return 1
}

@test "pinned Ubuntu image exposes the runner, Node, writable tool cache, and group-writable work directory" {
    # shellcheck disable=SC2016 # Variables expand in the container's Bash process.
    run rt run --rm --pull=never --network=none \
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

    # `cp ... -` streams a tar of just this file, so the numeric owner is read
    # without exporting the whole container filesystem.
    rt cp "$CONTAINER_NAME:$SAMPLE_RUNNER_ROOT/.runner" - > "$BATS_TEST_TMPDIR/runner.tar"
    tar -xOf "$BATS_TEST_TMPDIR/runner.tar" > "$BATS_TEST_TMPDIR/.runner"
    [ "$(jq -r '.AgentId' "$BATS_TEST_TMPDIR/.runner")" = OFFLINE_JIT_PROBE ]
    [ "$(jq -r '.WorkFolder' "$BATS_TEST_TMPDIR/.runner")" = "$SAMPLE_WORKDIR" ]
    [ "$(jq -r '.Ephemeral' "$BATS_TEST_TMPDIR/.runner")" = true ]

    # GNU tar prints 1001/1001; bsdtar prints the ids as separate columns.
    tar --numeric-owner -tvf "$BATS_TEST_TMPDIR/runner.tar" \
        | grep -Eq '(1001/1001|[[:space:]]1001[[:space:]]+1001[[:space:]]).*\.runner$'
    rt inspect "$CONTAINER_NAME" | jq -e --arg work "$SAMPLE_WORKDIR" --arg tool "$SAMPLE_TOOL_CACHE" '
        .[0].Config.WorkingDir == $work and
        ([.[0].Config.Env[] | select(. == "HOME=/home/runner" or . == "RUNNER_TOOL_CACHE=" + $tool)] | length) == 2 and
        .[0].HostConfig.NetworkMode == "none"
    ' >/dev/null
}

@test "malformed offline JIT input leaves no runner-root configuration" {
    run run_sample 'not-base64'
    [ "$status" -eq 0 ]
    [[ "$output" == *'Base-64'* || "$output" == *'base64'* ]]

    # A failed cp proves the file is absent only when the container exists and
    # the runtime names the missing file; daemon, storage or transport errors
    # (or a timeout) must fail the test instead.
    local missing_file='[Nn]o such file|[Cc]ould not find the file|[Dd]oes not exist'
    rt inspect "$CONTAINER_NAME" >/dev/null
    run rt cp "$CONTAINER_NAME:$SAMPLE_RUNNER_ROOT/.runner" -
    [ "$status" -ne 0 ]
    [[ "$output" =~ $missing_file ]] || {
        printf 'cp failed for a reason other than a missing .runner: %s\n' "$output" >&2
        return 1
    }
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

    # `z` relabels this test-owned file for SELinux-enforcing hosts and is ignored elsewhere.
    run rt run -d --name "$CONTAINER_NAME" --label "$RUN_LABEL=$RUN_ID" --pull=never --network=none \
        --user 1001:1001 --cap-drop=ALL --security-opt=no-new-privileges \
        --env RUNNER_MANUALLY_TRAP_SIG=1 \
        --volume "$helper_template:$SAMPLE_RUNNER_ROOT/run-helper.sh.template:ro,z" \
        --entrypoint "$SAMPLE_RUNNER_ROOT/run.sh" "$ARC_TEST_IMAGE"
    [ "$status" -eq 0 ]
    wait_for_controlled_helper_file "$ready_marker"

    run rt kill --signal TERM "$CONTAINER_NAME"
    [ "$status" -eq 0 ]
    wait_for_container_stop

    rt cp "$CONTAINER_NAME:$interrupt_marker" "$BATS_TEST_TMPDIR/controlled-helper-int"
    [ -f "$BATS_TEST_TMPDIR/controlled-helper-int" ]
    run rt inspect --format '{{.State.ExitCode}}' "$CONTAINER_NAME"
    [ "$status" -eq 0 ]
    [ "$output" -eq 143 ]
}

@test "standalone entrypoint reports the missing scope input first" {
    run rt run --rm --pull=never --network=none "$ARC_TEST_IMAGE"
    [ "$status" -ne 0 ]
    [[ "$output" == *'[ERROR] Must set GITHUB_REPOSITORY (owner/repo) or GITHUB_ORG (myorg).'* ]]
}
