#!/usr/bin/env bats

# The preflight probe reports that it failed, not why.
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
# half of the guess is the defect being fixed. The probe now states that it
# cannot distinguish, and leaves docker's own output in the log for the reader.

load "../test_helper"

setup() {
    setup_temp_dir
}

teardown() {
    teardown_temp_dir
}

# Renders the probe script the way the runner does: the step's body is a
# composite-action input, and the image ref reaches it by expression
# substitution. A renamed expression leaves `${{` in the body and bash rejects
# it, so this fails loudly rather than testing a script nobody runs.
run_probe() {
    local stub_stderr="$1"
    local stub_rc="$2"
    local script="$TEST_TEMP_DIR/probe.sh"
    local image="ghcr.io/owner/buildkit@sha256:$(printf '0%.0s' {1..64})"

    yq -r '.runs.steps[] | select(.id == "probe") | .with.run' \
        "$PROJECT_ROOT/.github/actions/preflight-buildkit/action.yaml" \
        | sed "s|\${{ inputs.image }}|$image|g" > "$script"

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

@test "probe: a present image exits clean and says nothing" {
    run_probe "" 0
    [ "$status" -eq 0 ]
    [[ "$output" != *"::error::"* ]]
}

@test "probe: a failing probe fails the step" {
    run_probe "manifest unknown" 1
    [ "$status" -eq 1 ]
    [[ "$output" == *"::error::"* ]]
}

# The #1073 regression lock. A registry answer that looks like absence must not
# make the step assert absence, because the same exit code arrives from a rate
# limit and the reader acts on what the message claims.
@test "probe: an absence-looking answer does not make the step claim absence" {
    run_probe "manifest unknown" 1
    [[ "$output" == *"does NOT establish that the image is absent"* ]]
}

@test "probe: a rate limit produces the same non-committal message" {
    run_probe "toomanyrequests: retry-after 60" 1
    [ "$status" -eq 1 ]
    [[ "$output" == *"does NOT establish that the image is absent"* ]]
}

@test "probe: the reader is told to re-run before seeding anything" {
    run_probe "denied: denied" 1
    [ "$status" -eq 1 ]
    [[ "$output" == *"Re-run first"* ]]
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
