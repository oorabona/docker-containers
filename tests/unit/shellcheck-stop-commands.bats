#!/usr/bin/env bats

# Proves the lint workflow treats repository-controlled diagnostics as text,
# including the failure path that would otherwise leave command parsing stopped.

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

_workflow_step() {
    local name=$1

    STEP_NAME=$name yq -r \
        '.jobs.shellcheck.steps[] | select(.name == strenv(STEP_NAME)) | .run' \
        "$PROJECT_ROOT/.github/workflows/shellcheck.yaml"
}

_install_hostile_linter() {
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/hostile-linter" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '::warning::forged annotation from linted source stdout one'
printf '%s\n' '::error::forged annotation from linted source stderr one' >&2
printf '%s\n' '::warning::forged annotation from linted source stdout two'
if [[ $1 == true ]]; then
    printf '%s\n' '::error::forged annotation from linted source stderr two' >&2
else
    printf '%s' '::error::forged annotation from linted source stderr two' >&2
fi
exit 1
EOF
    chmod +x "$TEST_TEMP_DIR/bin/hostile-linter"
}

_install_failing_uuidgen() {
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/uuidgen" <<'EOF'
#!/usr/bin/env bash
exit 70
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

_install_stderr_only_linter() {
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/shellcheck" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'counting-pass stderr must stay hidden' >&2
EOF
    chmod +x "$TEST_TEMP_DIR/bin/shellcheck"
}

_wrapper_from_step() {
    awk '
        /^run_with_workflow_commands_stopped\(\) \(/ { in_wrapper = 1 }
        in_wrapper { print }
        in_wrapper && /^\)$/ { exit }
    '
}

_assert_every_forged_command_is_bracketed() {
    local line active_marker
    local forged=0 stdout_forged=0 stderr_forged=0 outside_span=0

    while IFS= read -r line; do
        if [[ "$line" =~ ^::stop-commands::([[:alnum:]-]+)$ ]]; then
            active_marker=${BASH_REMATCH[1]}
        elif [[ -n ${active_marker:-} && "$line" == "::$active_marker::" ]]; then
            active_marker=
        elif [[ "$line" =~ ^::(warning|error)::forged\ annotation\ from\ linted\ source\ (stdout|stderr)\ (one|two)(::[[:alnum:]-]+::)?$ ]]; then
            forged=$((forged + 1))
            if [[ ${BASH_REMATCH[2]} == stdout ]]; then
                stdout_forged=$((stdout_forged + 1))
            else
                stderr_forged=$((stderr_forged + 1))
            fi
            [[ -n ${active_marker:-} ]] || outside_span=$((outside_span + 1))
        fi
    done <<< "$output"

    [ "$forged" -ge 4 ] \
        || _die "the hostile linter did not emit all four crafted diagnostics"
    [ "$stdout_forged" -ge 2 ] && [ "$stderr_forged" -ge 2 ] \
        || _die "the hostile linter did not emit crafted diagnostics on both streams"
    [ "$outside_span" -eq 0 ] \
        || _die "a crafted linter diagnostic was not inside a stopped command span"
}

_assert_no_command_span_is_left_open() {
    local line active_marker

    while IFS= read -r line; do
        if [[ "$line" =~ ^::stop-commands::([[:alnum:]-]+)$ ]]; then
            [[ -z ${active_marker:-} ]] \
                || _die "a second stopped command span opened before the first one resumed"
            active_marker=${BASH_REMATCH[1]}
        elif [[ -n ${active_marker:-} && "$line" == "::$active_marker::" ]]; then
            active_marker=
        fi
    done <<< "$output"

    [[ -z ${active_marker:-} ]] \
        || _die "a stopped command span remained open at end of output"
}

_run_hostile_linter_through_wrapper() {
    local step=$1 final_newline=${2:-true} wrapper

    wrapper=$(_wrapper_from_step <<< "$step")
    [ -n "$wrapper" ] || _die "could not extract the linter command span"

    run bash -c 'set -euo pipefail
        PATH="$1:$PATH"
        eval "$2"
        run_with_workflow_commands_stopped hostile-linter "$3"' \
        _ "$TEST_TEMP_DIR/bin" "$wrapper" "$final_newline"

    [ "$status" -eq 1 ] || _die "the hostile linter did not keep the command verdict"
    _assert_every_forged_command_is_bracketed
    _assert_no_command_span_is_left_open
}

@test "shellcheck failure is bracketed by a stopped and resumed command span" {
    local script summary

    _install_hostile_linter
    ln -s hostile-linter "$TEST_TEMP_DIR/bin/shellcheck"
    script=$(_workflow_step 'Run shellcheck on scripts')
    summary="$TEST_TEMP_DIR/summary"
    : > "$summary"

    run bash -c 'cd "$1"
        PATH="$2:$PATH" GITHUB_STEP_SUMMARY="$3" bash -c "$4"' \
        _ "$PROJECT_ROOT" "$TEST_TEMP_DIR/bin" "$summary" "$script"

    [ "$status" -eq 1 ] || _die "the lint failure did not keep the step verdict"
    _assert_every_forged_command_is_bracketed
    _assert_no_command_span_is_left_open
}

@test "a set-e shellcheck failure resumes workflow commands before exiting" {
    local script wrapper

    _install_hostile_linter
    ln -s hostile-linter "$TEST_TEMP_DIR/bin/shellcheck"
    script=$(_workflow_step 'Run shellcheck on scripts')
    wrapper=$(_wrapper_from_step <<< "$script")
    [ -n "$wrapper" ] || _die "could not extract the shellcheck command span"

    run bash -c 'set -euo pipefail
        PATH="$1:$PATH"
        eval "$2"
        run_with_workflow_commands_stopped shellcheck' \
        _ "$TEST_TEMP_DIR/bin" "$wrapper"

    [ "$status" -eq 1 ] || _die "the set-e lint failure did not keep the command verdict"
    _assert_every_forged_command_is_bracketed
    _assert_no_command_span_is_left_open
}

@test "both linter wrappers fail closed and resume on a separate line" {
    local yaml_step shellcheck_step step wrapper

    yaml_step=$(_workflow_step 'Check duplicate YAML mapping keys')
    shellcheck_step=$(_workflow_step 'Run shellcheck on scripts')

    for step in "$yaml_step" "$shellcheck_step"; do
        wrapper=$(_wrapper_from_step <<< "$step")
        [[ "$wrapper" == *'if ! stop_marker=$(uuidgen) || [[ -z "$stop_marker" ]]; then'* ]] \
            || _die "linter span does not reject a failed or empty marker"
        [[ "$wrapper" == *'return 1'* ]] \
            || _die "linter span does not stop before opening a span when marker minting fails"
        [[ "$wrapper" == *"trap 'printf \"\\n::%s::\\n\" \"\$stop_marker\"' EXIT"* ]] \
            || _die "linter span does not force the resume marker onto a new line"
        [[ "$wrapper" == *'"$@" 2>&1'* ]] \
            || _die "linter wrapper does not merge stderr into its stdout descriptor"
    done
}

@test "hostile commands on both linter streams are inside one stopped span" {
    local yaml_step shellcheck_step

    _install_hostile_linter
    yaml_step=$(_workflow_step 'Check duplicate YAML mapping keys')
    shellcheck_step=$(_workflow_step 'Run shellcheck on scripts')

    _run_hostile_linter_through_wrapper "$yaml_step"
    _run_hostile_linter_through_wrapper "$shellcheck_step"
}

@test "both linter wrappers do not invoke a child when marker minting fails in errexit-exempt callers" {
    local yaml_step shellcheck_step step wrapper

    _install_failing_uuidgen
    _install_recording_linter
    yaml_step=$(_workflow_step 'Check duplicate YAML mapping keys')
    shellcheck_step=$(_workflow_step 'Run shellcheck on scripts')

    for step in "$yaml_step" "$shellcheck_step"; do
        wrapper=$(_wrapper_from_step <<< "$step")
        [ -n "$wrapper" ] || _die "could not extract the linter command span"
        rm -f "$TEST_TEMP_DIR/invocations"

        run bash -c 'set -euo pipefail
            export PATH="$1:$PATH" LINTER_INVOCATIONS="$2"
            eval "$3"
            if run_with_workflow_commands_stopped recording-linter; then
                exit 91
            fi
            run_with_workflow_commands_stopped recording-linter || true' \
            _ "$TEST_TEMP_DIR/bin" "$TEST_TEMP_DIR/invocations" "$wrapper"

        [ "$status" -eq 0 ] || _die "a failed marker did not return failure from both errexit-exempt callers"
        [ ! -e "$TEST_TEMP_DIR/invocations" ] \
            || _die "a failed marker invoked the linter from an if condition or the left side of ||"
        [[ "$output" != *'::stop-commands::'* ]] \
            || _die "a failed marker opened a stopped command span"
    done
}

@test "a hostile final write without a newline still closes both stopped command spans" {
    local yaml_step shellcheck_step

    _install_hostile_linter
    yaml_step=$(_workflow_step 'Check duplicate YAML mapping keys')
    shellcheck_step=$(_workflow_step 'Run shellcheck on scripts')

    _run_hostile_linter_through_wrapper "$yaml_step" false
    _run_hostile_linter_through_wrapper "$shellcheck_step" false
}

@test "shellcheck counting pass keeps its stderr suppressed inside the stopped span" {
    local script summary

    _install_stderr_only_linter
    script=$(_workflow_step 'Run shellcheck on scripts')
    summary="$TEST_TEMP_DIR/summary"
    : > "$summary"

    run bash -c 'cd "$1"
        PATH="$2:$PATH" GITHUB_STEP_SUMMARY="$3" bash -c "$4"' \
        _ "$PROJECT_ROOT" "$TEST_TEMP_DIR/bin" "$summary" "$script"

    [ "$status" -eq 0 ] || _die "the all-passing shellcheck counting pass did not keep the step verdict"
    [[ "$output" != *'counting-pass stderr must stay hidden'* ]] \
        || _die "the shellcheck counting pass leaked diagnostics that its 2>/dev/null must suppress"
}

@test "recognised explicit linter launch shapes are wrapped" {
    local yaml_step shellcheck_step invocation
    local -a invocations trusted_yamllint_version_calls

    yaml_step=$(_workflow_step 'Check duplicate YAML mapping keys')
    shellcheck_step=$(_workflow_step 'Run shellcheck on scripts')

    mapfile -t trusted_yamllint_version_calls < <(
        grep -E '^[[:space:]]*"\$yamllint_venv/bin/yamllint" --version$' <<< "$yaml_step"
    )
    [ "${#trusted_yamllint_version_calls[@]}" -eq 1 ] \
        || _die "yamllint --version must remain the sole trusted unwrapped invocation"

    mapfile -t invocations < <(
        {
            printf '%s\n' "$yaml_step"
            printf '%s\n' "$shellcheck_step"
        } | awk '
            /^[[:space:]]*#/ { next }
            /"\$yamllint_venv\/bin\/yamllint"([[:space:]]|$)/ && !/--version/ { print }
            /run_with_workflow_commands_stopped run_shellcheck_counting_pass[[:space:]]/ { print }
            /run_with_workflow_commands_stopped shellcheck[[:space:]]/ { print }
        '
    )

    for invocation in "${invocations[@]}"; do
        [[ "$invocation" == *'run_with_workflow_commands_stopped '* ]] \
            || _die "a recognised explicit linter launch is not wrapped: $invocation"
    done
    [ "${#invocations[@]}" -eq 3 ] \
        || _die "expected three recognised explicit linter launch shapes, found ${#invocations[@]}"
}
