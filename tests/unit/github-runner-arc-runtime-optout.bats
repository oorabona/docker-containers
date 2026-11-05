#!/usr/bin/env bats

load "../test_helper"

ARC_IMAGE='ghcr.io/oorabona/github-runner:2.338.2@sha256:9df91c26565854fc5966ff98285789787d8e4aad0c2e3f60bc4076432d2a1877'
ARC_HARNESS="$PROJECT_ROOT/github-runner/tests/test-runner-arc.bats"

setup() {
    setup_temp_dir
    ARC_FAKE_BIN="$TEST_TEMP_DIR/arc-fake-bin"
    ARC_FAKE_STATE="$TEST_TEMP_DIR/arc-fake-state"
    ARC_FAKE_LOG="$TEST_TEMP_DIR/arc-fake.log"
    mkdir -p "$ARC_FAKE_BIN" "$ARC_FAKE_STATE"
    : > "$ARC_FAKE_LOG"
    create_arc_fake_runtime
}

teardown() {
    teardown_temp_dir
}

create_arc_fake_runtime() {
    cat > "$ARC_FAKE_BIN/podman" <<'EOF'
#!/bin/bash

log="$ARC_FAKE_LOG"
state="$ARC_FAKE_STATE"
printf '%q ' "$@" >> "$log"
printf '\n' >> "$log"

record_name() {
    printf '%s\n' "$2" >> "$state/$1-names"
}

label_from_args() {
    local arg next=0
    for arg in "$@"; do
        if [[ "$next" -eq 1 ]]; then
            printf '%s\n' "${arg#arc-offline-test=}"
            return
        fi
        [[ "$arg" == --label ]] && next=1
    done
}

unsupported_invocation() {
    printf 'unsupported fake runtime invocation:' >&2
    printf ' %q' "$@" >&2
    printf '\n' >&2
    exit 79
}

case "$1:$2" in
    container:ls|volume:ls)
        kind="$1"
        if [[ -f "$state/created" && "${ARC_FAKE_FAIL_CLEANUP:-}" == "$kind-list" ]]; then
            printf 'simulated %s listing failure\n' "$kind" >&2
            exit 71
        fi
        if [[ ! -f "$state/created" && "${ARC_FAKE_FAIL_SETUP_LIST:-}" == "$kind" ]]; then
            printf 'simulated %s listing failure\n' "$kind" >&2
            exit 72
        fi
        if [[ "$kind" == container && ! -f "$state/created" && "${ARC_FAKE_EXISTING_EXACT:-}" == 1 ]]; then
            candidate_pid="$PPID"
            while [[ "$candidate_pid" -gt 1 ]]; do
                printf 'arc-offline-%s-42-%s-%s\n' "$BATS_TEST_NUMBER" "$candidate_pid" "$ARC_FAKE_EXPECTED_RANDOM"
                candidate_pid=$(ps -o ppid= -p "$candidate_pid")
                candidate_pid=${candidate_pid//[[:space:]]/}
            done
        elif [[ "$kind" == container && ! -f "$state/created" && "${ARC_FAKE_SIMILAR_NAME:-}" == 1 ]]; then
            printf 'arc-offline-%s-42-similar-resource\n' "$BATS_TEST_NUMBER"
        elif [[ "${ARC_FAKE_HIDE_AFTER_SETUP:-}" != 1 && -f "$state/$kind-names" ]]; then
            cat "$state/$kind-names"
        fi
        ;;
    volume:create)
        owner=$(label_from_args "$@")
        printf '%s\n' "$owner" > "$state/owner"
        record_name volume "${!#}"
        touch "$state/created"
        ;;
    run:*)
        if [[ "${ARC_FAKE_IGNORE_TERM:-}" == 1 ]]; then
            trap '' TERM
            while :; do sleep 1; done
        fi
        name=
        previous=
        for arg in "$@"; do
            if [[ "$previous" == --name ]]; then
                name="$arg"
                break
            fi
            previous="$arg"
        done
        if [[ -n "$name" ]]; then
            record_name container "$name"
            exit 0
        fi
        printf '[ERROR] Must set GITHUB_REPOSITORY (owner/repo) or GITHUB_ORG (myorg).\n' >&2
        exit 1
        ;;
    container:inspect|volume:inspect)
        kind="$1"
        if [[ "${ARC_FAKE_FAIL_CLEANUP:-}" == "$kind-inspect" ]]; then
            printf 'simulated %s inspection failure\n' "$kind" >&2
            exit 73
        fi
        case "${ARC_FAKE_OWNER:-own}" in
            foreign) printf 'foreign-run\n' ;;
            missing) printf '\n' ;;
            *) cat "$state/owner" ;;
        esac
        ;;
    rm:*|volume:rm)
        if [[ "${ARC_FAKE_FAIL_CLEANUP:-}" == remove ]]; then
            printf 'simulated removal failure\n' >&2
            exit 74
        fi
        ;;
    exec:*)
        [[ "$#" -eq 7 && "$3" == /bin/bash && "$4" == -c && "$6" == -- &&
            "$7" == /tmp/arc-controlled-helper-ready ]] || unsupported_invocation "$@"
        grep -Fxq -- "$2" "$state/container-names" || unsupported_invocation "$@"
        if [[ -n "${ARC_FAKE_READINESS_STATUS:-}" ]]; then
            printf 'simulated readiness exec failure status %s\n' "$ARC_FAKE_READINESS_STATUS" >&2
            exit "$ARC_FAKE_READINESS_STATUS"
        fi
        if [[ "${ARC_FAKE_ABSENT_MARKER:-}" == 1 ]]; then
            exec "$3" "$4" "$5" "$6" "$state/absent-ready-marker"
        fi
        unsupported_invocation "$@"
        ;;
    inspect:--format)
        [[ "$#" -eq 4 && "$3" == '{{.State.Status}} exit={{.State.ExitCode}}' ]] || unsupported_invocation "$@"
        grep -Fxq -- "$4" "$state/container-names" || unsupported_invocation "$@"
        printf 'running exit=0\n'
        ;;
    logs:--tail)
        [[ "$#" -eq 4 && "$3" == 20 ]] || unsupported_invocation "$@"
        grep -Fxq -- "$4" "$state/container-names" || unsupported_invocation "$@"
        printf 'simulated controlled helper logs\n'
        ;;
    *) unsupported_invocation "$@" ;;
esac
EOF
    chmod +x "$ARC_FAKE_BIN/podman"
    cat > "$ARC_FAKE_BIN/date" <<'EOF'
#!/bin/bash
printf '42\n'
EOF
    chmod +x "$ARC_FAKE_BIN/date"
}

run_arc_harness() {
    run env PATH="$ARC_FAKE_BIN:$PATH" ARC_RUNTIME_TESTS=1 ARC_TEST_RUNTIME=podman \
        ARC_TEST_IMAGE="$ARC_IMAGE" ARC_FAKE_LOG="$ARC_FAKE_LOG" ARC_FAKE_STATE="$ARC_FAKE_STATE" \
        "$@" bats --filter 'standalone entrypoint reports the missing scope input first' "$ARC_HARNESS"
}

run_arc_helper_harness() {
    run env PATH="$ARC_FAKE_BIN:$PATH" ARC_RUNTIME_TESTS=1 ARC_TEST_RUNTIME=podman \
        ARC_TEST_IMAGE="$ARC_IMAGE" ARC_FAKE_LOG="$ARC_FAKE_LOG" ARC_FAKE_STATE="$ARC_FAKE_STATE" \
        "$@" bats --filter 'run.sh PID 1 wrapper forwards TERM to a controlled helper' "$ARC_HARNESS"
}

assert_arc_readiness_failure() {
    local readiness_status="$1" container_name

    [ "$status" -eq 1 ]
    [[ "$output" == *'not ok 1 run.sh PID 1 wrapper forwards TERM to a controlled helper'* ]]
    container_name=$(tail -n 1 "$ARC_FAKE_STATE/container-names")
    [[ "$output" == *"controlled helper readiness failed: container=$container_name path=/tmp/arc-controlled-helper-ready status=$readiness_status"* ]]
    [[ "$output" == *"container $container_name state: running exit=0"* ]]
    [[ "$output" == *'last log lines:'* ]]
    [[ "$output" == *'simulated controlled helper logs'* ]]
    [[ "$output" != *'unsupported fake runtime invocation:'* ]]
    [ "$(grep -c '^exec ' "$ARC_FAKE_LOG")" -eq 1 ]
    [ "$(grep -c '^inspect --format ' "$ARC_FAKE_LOG")" -eq 1 ]
    grep -Fxq "logs --tail 20 $container_name " "$ARC_FAKE_LOG"
    [ "$(grep -c '^rm -f ' "$ARC_FAKE_LOG")" -eq 2 ]
    [ "$(grep -c '^volume rm -f ' "$ARC_FAKE_LOG")" -eq 1 ]
    ! grep -qE '^(kill|cp) ' "$ARC_FAKE_LOG"
}

@test "ARC fake runtime rejects unsupported invocations with quoted arguments" {
    run env ARC_FAKE_LOG="$ARC_FAKE_LOG" ARC_FAKE_STATE="$ARC_FAKE_STATE" \
        "$ARC_FAKE_BIN/podman" unsupported 'argument with spaces'

    [ "$status" -eq 79 ]
    [[ "$output" == 'unsupported fake runtime invocation: unsupported argument\ with\ spaces' ]]
}

@test "ARC readiness exec failures retain status and diagnostics after one query" {
    local failure

    for failure in 1 3 124 125 137; do
        : > "$ARC_FAKE_LOG"
        rm -rf "$ARC_FAKE_STATE"
        mkdir "$ARC_FAKE_STATE"
        run_arc_helper_harness ARC_FAKE_READINESS_STATUS="$failure"

        assert_arc_readiness_failure "$failure"
        [[ "$output" == *"simulated readiness exec failure status $failure"* ]]
        [[ "$output" != *'marker not observed after'* ]]
        [[ "$output" != *'exceeded'* && "$output" != *'stalled'* && "$output" != *'deadline expired'* ]]
        if [[ "$failure" -eq 124 || "$failure" -eq 137 ]]; then
            [[ "$output" == *"runtime call returned status $failure under timeout wrapper (120s): podman exec "* ]]
        fi
    done
}

@test "ARC readiness runs the supplied Bash loop once and reports marker exhaustion" {
    [ ! -e "$ARC_FAKE_STATE/absent-ready-marker" ]
    run_arc_helper_harness ARC_FAKE_ABSENT_MARKER=1

    assert_arc_readiness_failure 1
    [[ "$output" == *'marker not observed after 50 checks with 0.1s sleeps'* ]]
}

@test "ARC runtime refuses a missing timeout before it mutates the runtime" {
    local bash_env="$TEST_TEMP_DIR/no-timeout.bash"

    cat > "$bash_env" <<'EOF'
command() {
    if [[ "$1" == -v && ( "$2" == timeout || "$2" == gtimeout ) ]]; then
        return 1
    fi
    builtin command "$@"
}
EOF
    run_arc_harness BASH_ENV="$bash_env"

    [ "$status" -ne 0 ]
    [[ "$output" == *'timeout or gtimeout with --kill-after is required'* ]]
    run grep -qE '^(volume create|run )' "$ARC_FAKE_LOG"
    [ "$status" -ne 0 ]
}

@test "ARC runtime validates timeout durations and accepts positive decimal seconds" {
    local duration

    for duration in 0 -1 1. invalid; do
        run_arc_harness ARC_TEST_TIMEOUT="$duration"
        [ "$status" -ne 0 ]
        [[ "$output" == *'ARC_TEST_TIMEOUT must be a positive number of seconds'* ]]
    done

    run_arc_harness ARC_TEST_TIMEOUT=0.1
    [ "$status" -eq 0 ]
}

@test "ARC runtime force-kills a TERM-ignoring runtime call and reports its observed status" {
    run env PATH="$ARC_FAKE_BIN:$PATH" ARC_RUNTIME_TESTS=1 ARC_TEST_RUNTIME=podman \
        ARC_TEST_IMAGE="$ARC_IMAGE" ARC_TEST_TIMEOUT=0.1 ARC_FAKE_IGNORE_TERM=1 \
        ARC_FAKE_LOG="$ARC_FAKE_LOG" ARC_FAKE_STATE="$ARC_FAKE_STATE" \
        timeout 8s bats --filter 'standalone entrypoint reports the missing scope input first' "$ARC_HARNESS"

    [ "$status" -eq 1 ]
    [[ "$output" == *'not ok 1 standalone entrypoint reports the missing scope input first'* ]]
    [[ "$output" == *'runtime call returned status 137 under timeout wrapper (0.1s): podman run '* ]]
}

@test "ARC runtime accepts empty listings, rejects failed listings, and distinguishes exact names" {
    local fixed_random_env="$TEST_TEMP_DIR/fixed-random.bash"

    run_arc_harness
    [ "$status" -eq 0 ]

    : > "$ARC_FAKE_LOG"
    rm -rf "$ARC_FAKE_STATE"
    mkdir "$ARC_FAKE_STATE"
    run_arc_harness ARC_FAKE_FAIL_SETUP_LIST=container
    [ "$status" -ne 0 ]
    [[ "$output" == *'could not list containers while checking'* ]]
    run grep -qE '^(volume create|run )' "$ARC_FAKE_LOG"
    [ "$status" -ne 0 ]

    : > "$ARC_FAKE_LOG"
    rm -rf "$ARC_FAKE_STATE"
    mkdir "$ARC_FAKE_STATE"
    printf 'RANDOM=123\n' > "$fixed_random_env"
    run_arc_harness ARC_FAKE_EXISTING_EXACT=1 ARC_FAKE_EXPECTED_RANDOM=2850 BASH_ENV="$fixed_random_env"
    [ "$status" -ne 0 ]
    [[ "$output" == *'stale container '* ]]
    run grep -qE '^(volume create|run )' "$ARC_FAKE_LOG"
    [ "$status" -ne 0 ]

    : > "$ARC_FAKE_LOG"
    rm -rf "$ARC_FAKE_STATE"
    mkdir "$ARC_FAKE_STATE"
    run_arc_harness ARC_FAKE_SIMILAR_NAME=1
    [ "$status" -eq 0 ]
    grep -q '^volume create ' "$ARC_FAKE_LOG"
}

@test "ARC runtime cleanup leaves absent resources, preserves foreign labels, and removes owned labels" {
    run_arc_harness ARC_FAKE_HIDE_AFTER_SETUP=1
    [ "$status" -eq 0 ]
    run grep -qE '^(rm|volume rm) ' "$ARC_FAKE_LOG"
    [ "$status" -ne 0 ]

    : > "$ARC_FAKE_LOG"
    rm -rf "$ARC_FAKE_STATE"
    mkdir "$ARC_FAKE_STATE"
    run_arc_harness ARC_FAKE_OWNER=foreign
    [ "$status" -ne 0 ]
    [[ "$output" == *'not removing '* ]]
    run grep -qE '^(rm|volume rm) ' "$ARC_FAKE_LOG"
    [ "$status" -ne 0 ]

    : > "$ARC_FAKE_LOG"
    rm -rf "$ARC_FAKE_STATE"
    mkdir "$ARC_FAKE_STATE"
    run_arc_harness ARC_FAKE_OWNER=missing
    [ "$status" -ne 0 ]
    [[ "$output" == *'not removing '* ]]
    run grep -qE '^(rm|volume rm) ' "$ARC_FAKE_LOG"
    [ "$status" -ne 0 ]

    : > "$ARC_FAKE_LOG"
    rm -rf "$ARC_FAKE_STATE"
    mkdir "$ARC_FAKE_STATE"
    run_arc_harness
    [ "$status" -eq 0 ]
    grep -q '^rm -f ' "$ARC_FAKE_LOG"
    grep -q '^volume rm -f ' "$ARC_FAKE_LOG"
}

@test "ARC runtime cleanup reports failures and continues with other resources" {
    local failure expected later

    for failure in container-list container-inspect remove; do
        : > "$ARC_FAKE_LOG"
        rm -rf "$ARC_FAKE_STATE"
        mkdir "$ARC_FAKE_STATE"
        run_arc_harness ARC_FAKE_FAIL_CLEANUP="$failure"
        [ "$status" -ne 0 ]
        case "$failure" in
            container-list) expected='cleanup failed: cannot establish whether container'; later='^volume ls ' ;;
            container-inspect) expected='cleanup failed: could not inspect ownership label for container'; later='^volume inspect ' ;;
            remove) expected='cleanup failed: container .* was not removed'; later='^volume rm -f ' ;;
        esac
        [[ "$output" =~ $expected ]]
        grep -Eq "$later" "$ARC_FAKE_LOG"
    done
}

@test "ARC runtime opt-out preserves an inherited caller temporary directory" {
    local inherited_temp_dir sentinel

    inherited_temp_dir=$(mktemp -d "$BATS_TEST_TMPDIR/inherited-arc-temp.XXXXXX")
    sentinel="$inherited_temp_dir/caller-sentinel"
    touch "$sentinel"

    run env ARC_RUNTIME_TESTS=0 TEST_TEMP_DIR="$inherited_temp_dir" \
        bats "$PROJECT_ROOT/github-runner/tests/test-runner-arc.bats"

    [ "$status" -eq 0 ]
    [ "$(grep -c '# skip set ARC_RUNTIME_TESTS=1' <<< "$output")" -eq 5 ]
    [ -f "$sentinel" ]
}

@test "ARC runtime rejects a wrong image and preserves an inherited caller sentinel" {
    local inherited_temp_dir sentinel sibling_image

    inherited_temp_dir=$(mktemp -d "$BATS_TEST_TMPDIR/inherited-arc-temp.XXXXXX")
    sentinel="$inherited_temp_dir/caller-sentinel"
    sibling_image='ghcr.io/oorabona/github-runner:2.338.2-dev'
    touch "$sentinel"

    run env ARC_RUNTIME_TESTS=1 ARC_TEST_RUNTIME=podman ARC_TEST_IMAGE="$sibling_image" \
        TEST_TEMP_DIR="$inherited_temp_dir" \
        bats "$PROJECT_ROOT/github-runner/tests/test-runner-arc.bats"

    [ "$status" -ne 0 ]
    [[ "$output" == *"ARC_TEST_IMAGE must equal the ARC sample runner image: expected ghcr.io/oorabona/github-runner:2.338.2@sha256:9df91c26565854fc5966ff98285789787d8e4aad0c2e3f60bc4076432d2a1877, got $sibling_image"* ]]
    [ -f "$sentinel" ]
}
