#!/usr/bin/env bats

# Proves actionlint's repository-controlled diagnostics never reach the runner
# while command parsing is live.

load "../test_helper"

setup() {
    setup_temp_dir
}

teardown() {
    teardown_temp_dir
}

_die() {
    printf '%s\n' "$1" >&2
    return 1
}

_actionlint_step() {
    yq -r '.jobs.actionlint.steps[] | select(.name == "Run actionlint on workflows") | .run' \
        "$PROJECT_ROOT/.github/workflows/actionlint.yaml"
}

_install_passing_actionlint() {
    cat > "$TEST_TEMP_DIR/actionlint" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/actionlint"
}

_install_versioned_shellcheck() {
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/shellcheck" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == --version ]]; then
    printf '%s\n' 'ShellCheck - shell script analysis tool' 'version: 0.10.0'
fi
EOF
    chmod +x "$TEST_TEMP_DIR/bin/shellcheck"
}

_install_uuidgen() {
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/uuidgen" <<'EOF'
#!/bin/sh
printf '%s\n' actionlint-test-marker
EOF
    chmod +x "$TEST_TEMP_DIR/bin/uuidgen"
}

_install_recording_linter() {
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/recording-linter" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' invoked >> "$LINTER_INVOCATIONS"
EOF
    chmod +x "$TEST_TEMP_DIR/bin/recording-linter"
}

_wrapper() {
    awk '
        /^run_with_workflow_commands_stopped\(\) \(/ { in_wrapper = 1 }
        in_wrapper { print }
        in_wrapper && /^\)$/ { exit }
    '
}

_install_hostile_actionlint() {
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/hostile-actionlint" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '::warning::forged actionlint stdout'
printf '%s\n' '::error::forged actionlint stderr' >&2
printf '%s' '::stop-commands::forged-actionlint-token' >&2
exit 1
EOF
    chmod +x "$TEST_TEMP_DIR/bin/hostile-actionlint"
}

_assert_forged_output_is_bracketed() {
    local line active_marker outside=0 forged=0

    while IFS= read -r line; do
        if [[ "$line" =~ ^::stop-commands::([[:alnum:]-]+)$ && "$line" != '::stop-commands::forged-actionlint-token' ]]; then
            active_marker=${BASH_REMATCH[1]}
        elif [[ -n ${active_marker:-} && "$line" == "::$active_marker::" ]]; then
            active_marker=
        elif [[ "$line" == '::warning::forged actionlint stdout' || "$line" == '::error::forged actionlint stderr' || "$line" == '::stop-commands::forged-actionlint-token' ]]; then
            forged=$((forged + 1))
            [[ -n ${active_marker:-} ]] || outside=$((outside + 1))
        fi
    done <<< "$output"

    [ "$forged" -eq 3 ] || _die "the hostile actionlint stub did not emit all crafted output"
    [ "$outside" -eq 0 ] || _die "a forged actionlint command reached the runner outside a stopped span"
    [[ -z ${active_marker:-} ]] || _die "a stopped actionlint span remained open at end of output"
}

_assert_opening_write_failure_refuses_linter() {
    local wrapper=$1

    rm -f "$TEST_TEMP_DIR/invocations"
    run bash -c 'set -euo pipefail
        export PATH="$1:$PATH" LINTER_INVOCATIONS="$2"
        eval "$3"
        if run_with_workflow_commands_stopped recording-linter > /dev/full; then
            printf "%s\n" WRAPPER_REPORTED_SUCCESS
        fi' \
        _ "$TEST_TEMP_DIR/bin" "$TEST_TEMP_DIR/invocations" "$wrapper"

    [ "$status" -eq 0 ] || _die "a failed opening marker did not return failure from an errexit-exempt caller"
    [ ! -e "$TEST_TEMP_DIR/invocations" ] \
        || _die "a failed opening marker invoked the linter in an errexit-exempt caller"
    [[ "$output" == *'::error::could not write workflow command stop marker; refusing to run linter'* ]] \
        || _die "a failed opening marker did not name the refused linter launch"
    [[ "$output" != *'WRAPPER_REPORTED_SUCCESS'* ]] \
        || _die "a failed opening marker reported the linter as clean"
}

_assert_resume_write_failure_is_not_clean() {
    local wrapper=$1

    rm -f "$TEST_TEMP_DIR/invocations"
    run bash -c 'set -euo pipefail
        export PATH="$1:$PATH" LINTER_INVOCATIONS="$2"
        eval "$3"
        printf() {
            if [[ ${1:-} == '\''\n::%s::\n'\'' ]]; then
                return 1
            fi
            builtin printf "$@"
        }
        if run_with_workflow_commands_stopped recording-linter; then
            printf "%s\n" WRAPPER_REPORTED_SUCCESS
        fi' \
        _ "$TEST_TEMP_DIR/bin" "$TEST_TEMP_DIR/invocations" "$wrapper"

    [ "$status" -eq 0 ] || _die "a failed resume marker did not return failure from an errexit-exempt caller"
    [ -e "$TEST_TEMP_DIR/invocations" ] \
        || _die "a failed resume marker did not invoke the linter before closing the span"
    [[ "$output" == *'::error::could not write workflow command resume marker; refusing to report lint success'* ]] \
        || _die "a failed resume marker did not name the failed resume"
    [[ "$output" != *'WRAPPER_REPORTED_SUCCESS'* ]] \
        || _die "a failed resume marker reported the linter as clean"
}

_assert_shellcheck_probe_failure() {
    local step=$1 expected_status=$2 failure_class=$3

    rm -rf "$TEST_TEMP_DIR/probe-bin"
    mkdir -p "$TEST_TEMP_DIR/probe-bin"
    case "$failure_class" in
        non-executable)
            printf '#!/bin/sh\nexit 0\n' > "$TEST_TEMP_DIR/probe-bin/shellcheck"
            chmod -x "$TEST_TEMP_DIR/probe-bin/shellcheck"
            ;;
        arbitrary)
            printf '#!/bin/sh\nexit %s\n' "$expected_status" > "$TEST_TEMP_DIR/probe-bin/shellcheck"
            chmod +x "$TEST_TEMP_DIR/probe-bin/shellcheck"
            ;;
        missing) ;;
        *) _die "unknown ShellCheck probe failure class: $failure_class" ;;
    esac

    run /usr/bin/env PATH="$TEST_TEMP_DIR/probe-bin" /usr/bin/bash -c "$step"

    [ "$status" -eq "$expected_status" ] \
        || _die "the actionlint ShellCheck availability probe did not preserve exit $expected_status"
    [[ "$output" == *"::error::shellcheck tooling availability check failed (exit $expected_status); actionlint cannot run embedded-shell analysis"* ]] \
        || _die "the actionlint ShellCheck availability probe did not name exit $expected_status"
}

@test "actionlint output on both streams is bracketed and the span closes after a final write without newline" {
    local step summary

    _install_hostile_actionlint
    step=$(_actionlint_step)
    cp "$TEST_TEMP_DIR/bin/hostile-actionlint" "$TEST_TEMP_DIR/actionlint"
    summary="$TEST_TEMP_DIR/summary"
    : > "$summary"

    run bash -c 'cd "$1"
        GITHUB_STEP_SUMMARY="$2" bash -c "$3"' \
        _ "$TEST_TEMP_DIR" "$summary" "$step"

    [ "$status" -eq 1 ] || _die "the hostile actionlint failure did not keep the command verdict"
    _assert_forged_output_is_bracketed
}

@test "the actionlint wrapper fails closed before opening a span" {
    local step wrapper

    mkdir -p "$TEST_TEMP_DIR/bin"
    printf '#!/usr/bin/env bash\nexit 70\n' > "$TEST_TEMP_DIR/bin/uuidgen"
    chmod +x "$TEST_TEMP_DIR/bin/uuidgen"
    step=$(_actionlint_step)
    wrapper=$(_wrapper <<< "$step")

    run bash -c 'set -euo pipefail
        PATH="$1:$PATH"
        eval "$2"
        run_with_workflow_commands_stopped true' \
        _ "$TEST_TEMP_DIR/bin" "$wrapper"

    [ "$status" -eq 1 ] || _die "a failed actionlint marker did not fail closed"
    [[ "$output" != *'::stop-commands::'* ]] || _die "a failed actionlint marker opened a stopped span"
}

@test "the actionlint wrapper refuses a failed opening write before invoking the linter in an errexit-exempt caller" {
    local step wrapper

    _install_uuidgen
    _install_recording_linter
    step=$(_actionlint_step)
    wrapper=$(_wrapper <<< "$step")

    _assert_opening_write_failure_refuses_linter "$wrapper"
}

@test "the actionlint wrapper fails when its resume write fails in an errexit-exempt caller" {
    local step wrapper

    _install_uuidgen
    _install_recording_linter
    step=$(_actionlint_step)
    wrapper=$(_wrapper <<< "$step")

    _assert_resume_write_failure_is_not_clean "$wrapper"
}

@test "actionlint fails naming shellcheck when embedded-shell analysis is unavailable" {
    local step summary

    _install_passing_actionlint
    _install_uuidgen
    step=$(_actionlint_step)
    summary="$TEST_TEMP_DIR/summary"
    : > "$summary"

    run bash -c 'cd "$1"
        PATH="$2" GITHUB_STEP_SUMMARY="$3"
        eval "$4"' \
        _ "$TEST_TEMP_DIR" "$TEST_TEMP_DIR/bin" "$summary" "$step"

    [ "$status" -eq 127 ] || _die "the actionlint step did not preserve unavailable shellcheck status 127"
    [[ "$output" == *'::error::shellcheck tooling availability check failed (exit 127); actionlint cannot run embedded-shell analysis'* ]] \
        || _die "the actionlint failure did not name unavailable shellcheck embedded-shell analysis"
}

@test "actionlint preserves missing ShellCheck status 127" {
    _assert_shellcheck_probe_failure "$(_actionlint_step)" 127 missing
}

@test "actionlint preserves non-executable ShellCheck status 126" {
    _assert_shellcheck_probe_failure "$(_actionlint_step)" 126 non-executable
}

@test "actionlint preserves arbitrary ShellCheck tooling status" {
    _assert_shellcheck_probe_failure "$(_actionlint_step)" 42 arbitrary
}

@test "actionlint records the ShellCheck version before its successful verdict" {
    local step summary

    _install_passing_actionlint
    _install_versioned_shellcheck
    step=$(_actionlint_step)
    summary="$TEST_TEMP_DIR/summary"
    : > "$summary"

    run bash -c 'cd "$1"
        PATH="$2:$PATH" GITHUB_STEP_SUMMARY="$3"
        eval "$4"' \
        _ "$TEST_TEMP_DIR" "$TEST_TEMP_DIR/bin" "$summary" "$step"

    [ "$status" -eq 0 ] || _die "the actionlint step did not keep the successful verdict"
    [[ "$output" == *'ShellCheck - shell script analysis tool'* && "$output" == *'version: 0.10.0'* ]] \
        || _die "the successful actionlint step did not record the ShellCheck version"
}
