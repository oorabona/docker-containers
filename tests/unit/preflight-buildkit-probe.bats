#!/usr/bin/env bats

# The preflight probe reports that it failed, not why — and it reports it once.
#
# `docker manifest inspect` fails for absence, for a rate limit, for a 5xx, for
# an expired token and for a DNS blip. The probe used to read every non-zero
# exit as absence and tell the reader to re-seed the builder image. Issue #1073
# was filed on that basis after four attempts failed during a burst of
# concurrent runs, while 110 sibling jobs in the same run were pulling from and
# pushing to GHCR successfully.
#
# Classifying the registry's free-form stderr was tried and abandoned: every
# pattern list is a denylist, the next unseen wording escapes it, and the wrong
# half of the guess is the defect being fixed. The probe states that it cannot
# distinguish, and leaves docker's own output in the log for the reader.
#
# The probe runs under `retry-run`, so its script executes once per attempt.
# Issue #1075: a `::error::` printed there fired on every failing attempt — a job
# that failed three times and succeeded on the fourth ended green carrying three
# error annotations, and a per-attempt `timeout` killed the script before its
# failure path ran at all, losing the annotation entirely. So the two halves are
# now two steps and are tested as two: the retried block signals with its exit
# status and prints no workflow command, and a following step, which the timeout
# cannot reach and which runs once, carries the operator-facing message.

load "../test_helper"

setup() {
    setup_temp_dir
}

teardown() {
    teardown_temp_dir
}

_step_script() {
    local step_id="$1"
    # The probe's body is a composite-action input (.with.run); the diagnosis is
    # an ordinary step body (.run). Reading both spellings keeps this anchored to
    # whichever shape each step actually has.
    id="$step_id" yq -r \
        '.runs.steps[] | select(.id == strenv(id)) | (.with.run // .run)' \
        "$PROJECT_ROOT/.github/actions/preflight-buildkit/action.yaml"
}

# Renders the probe script the way the runner does: the step's body is a
# composite-action input, and the image ref reaches it by expression
# substitution. A renamed expression leaves `${{` in the body and bash rejects
# it, so this fails loudly rather than testing a script nobody runs.
run_probe() {
    local stub_stderr="$1"
    local stub_rc="$2"
    local script="$TEST_TEMP_DIR/probe.sh"
    local digest image
    digest=$(printf '0%.0s' {1..64})
    image="ghcr.io/owner/buildkit@sha256:$digest"

    _step_script probe | sed "s|\${{ inputs.image }}|$image|g" > "$script"
    [ -s "$script" ] || fail "no script extracted for the probe step"

    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/docker" <<STUB
#!/usr/bin/env bash
printf '%s\n' "$stub_stderr" >&2
printf 'a manifest nobody should see in the log\n'
exit $stub_rc
STUB
    chmod +x "$TEST_TEMP_DIR/bin/docker"

    PATH="$TEST_TEMP_DIR/bin:$PATH" run bash -e -o pipefail "$script"
}

# The diagnosis step needs no docker: it runs only after the probe has failed,
# and says the same thing whatever the registry answered.
run_diagnosis() {
    local script="$TEST_TEMP_DIR/diagnose.sh"

    _step_script diagnose > "$script"
    [ -s "$script" ] || fail "no script extracted for the diagnose step"

    run bash -e -o pipefail "$script"
}

# ---------------------------------------------------------------------------
# The retried block: exit status and docker's own output, no workflow commands.
# ---------------------------------------------------------------------------

@test "probe: a present image exits clean and says nothing" {
    run_probe "" 0
    [ "$status" -eq 0 ]
    [[ "$output" != *"::error::"* ]]
}

@test "probe: a failing probe fails the step" {
    run_probe "manifest unknown" 1
    [ "$status" -eq 1 ]
}

# The #1075 lock, and the reason the message moved. This block runs once per
# retry attempt, so a workflow command here is emitted once per attempt —
# including attempts a later retry makes moot.
@test "probe: the retried block emits no workflow command, in either direction" {
    run_probe "manifest unknown" 1
    [[ "$output" != *"::error::"* ]]
    [[ "$output" != *"::warning::"* ]]
    [[ "$output" != *"::notice::"* ]]

    run_probe "" 0
    [[ "$output" != *"::"* ]]
}

# docker writes to the step log directly, as every other command in this
# repository does. Nothing here captures, stores or replays it — which is why
# there is no file to bound and no text of ours to escape.
@test "probe: docker's own words reach the log on failure" {
    run_probe "unexpected status from HEAD request: 503 Service Unavailable" 1
    [[ "$output" == *"503 Service Unavailable"* ]]
}

@test "probe: docker's own words reach the log on success too" {
    run_probe "warning: the registry answered slowly" 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"the registry answered slowly"* ]]
}

@test "probe: the manifest body stays out of the log on success" {
    run_probe "" 0
    [[ "$output" != *"a manifest nobody should see in the log"* ]]
}

# ---------------------------------------------------------------------------
# The diagnosis step: one annotation, and what it is allowed to claim.
# ---------------------------------------------------------------------------

@test "diagnosis: emits exactly one error annotation" {
    run_diagnosis
    [ "$status" -eq 0 ]
    [ "$(grep -c '::error::' <<< "$output")" -eq 1 ]
}

# The #1073 regression lock, now asserted where the message lives. A registry
# answer that looks like absence must not make the step assert absence, because
# the same exit code arrives from a rate limit and the reader acts on the claim.
@test "diagnosis: does not claim the image is absent" {
    run_diagnosis
    [[ "$output" == *"does NOT establish that the image is absent"* ]]
}

@test "diagnosis: the reader is told to re-run before seeding anything" {
    run_diagnosis
    [[ "$output" == *"Re-run first"* ]]
}

@test "diagnosis: names the causes that all land on the same exit code" {
    run_diagnosis
    [[ "$output" == *"rate limit"* ]]
    [[ "$output" == *"expired token"* ]]
    [[ "$output" == *"DNS failure"* ]]
}

# ---------------------------------------------------------------------------
# The wiring between the two, which no execution of either script can show.
# ---------------------------------------------------------------------------

@test "the diagnosis runs only when this probe is what failed" {
    local guard
    guard=$(yq -r '.runs.steps[] | select(.id == "diagnose") | .if' \
        "$PROJECT_ROOT/.github/actions/preflight-buildkit/action.yaml")

    # The exact expression, not three substrings. Checked independently they are
    # all satisfied by `always() || steps.probe.outcome != 'failure'`, which
    # diagnoses an earlier validation failure as a registry problem and stays
    # silent after a real probe failure — the two things this guard prevents.
    #
    # always() rather than failure(): failure() is false once a job is cancelled,
    # so a cancellation landing between the exhausted probe and this step drops
    # the only explanation of a probe that really did fail, and this repository
    # cancels superseded runs. The outcome clause is what decides; measured under
    # act, neither form fires when the probe succeeds.
    [ "$guard" = "\${{ always() && steps.probe.outcome == 'failure' }}" ]
}

# Order is part of the wiring: `steps.probe.outcome` is unset until the probe has
# run, so a diagnosis placed before it is never correct however its guard reads.
@test "the diagnosis step comes after the probe it diagnoses" {
    local ids probe_index diagnose_index
    ids=$(yq -r '[.runs.steps[] | .id // ""] | to_entries | .[] | [.key, .value] | @tsv' \
        "$PROJECT_ROOT/.github/actions/preflight-buildkit/action.yaml")

    probe_index=$(awk -F'\t' '$2 == "probe" { print $1 }' <<< "$ids")
    diagnose_index=$(awk -F'\t' '$2 == "diagnose" { print $1 }' <<< "$ids")

    [ -n "$probe_index" ]
    [ -n "$diagnose_index" ]
    [ "$diagnose_index" -gt "$probe_index" ]
}

@test "the diagnosis step is not itself wrapped by retry-run" {
    local uses
    uses=$(yq -r '.runs.steps[] | select(.id == "diagnose") | (.uses // "none")' \
        "$PROJECT_ROOT/.github/actions/preflight-buildkit/action.yaml")

    [ "$uses" = "none" ]
}
