#!/usr/bin/env bats
#
# The e2e gate decides whether a run without an e2e execution may still report
# success. It gets a decision table of its own because the one thing it must
# never do — call an unrun suite verified — is invisible from a green check.

load "../test_helper"

setup() {
    setup_temp_dir
    GATE_BODY=$(yq -r '.jobs["e2e-gate"].steps[0].run' \
        "$PROJECT_ROOT/.github/workflows/auto-build.yaml")
    ELIGIBLE='[{"container":"openvpn","tag":"v2.7.5-alpine"}]'
}

teardown() {
    unset DETECT_RESULT E2E_RESULT E2E_BUILDS EVENT_NAME GATE_BODY ELIGIBLE
    teardown_temp_dir
}

run_gate() { # detect, e2e, builds, event
    DETECT_RESULT="$1" E2E_RESULT="$2" E2E_BUILDS="$3" EVENT_NAME="$4" \
        run bash -c "$GATE_BODY"
}

@test "deleting the fork check would report a suite verified that never ran" {
    # The job is skipped for a pull request from a fork, which cannot be given
    # the registry access e2e needs. Passing there is the false green.
    run_gate success skipped "$ELIGIBLE" pull_request
    [ "$status" -ne 0 ]
    [[ "$output" == *"did not run"* ]]
}

@test "deleting the event check would fail every push that touches an e2e container" {
    # e2e is pull-request-only by design, so a push skips it with eligible
    # containers as a matter of course — and the images are already published by
    # the time this gate runs.
    run_gate success skipped "$ELIGIBLE" push
    [ "$status" -eq 0 ]
}

@test "deleting the event check would also fail a manual or called run" {
    run_gate success skipped "$ELIGIBLE" workflow_dispatch
    [ "$status" -eq 0 ]
    run_gate success skipped "$ELIGIBLE" workflow_call
    [ "$status" -eq 0 ]
}

@test "deleting the eligibility check would fail a pull request with nothing to test" {
    run_gate success skipped '[]' pull_request
    [ "$status" -eq 0 ]
    run_gate success skipped '' pull_request
    [ "$status" -eq 0 ]
}

@test "deleting the result check would pass a pull request whose e2e failed" {
    run_gate success failure "$ELIGIBLE" pull_request
    [ "$status" -ne 0 ]
    run_gate success cancelled "$ELIGIBLE" pull_request
    [ "$status" -ne 0 ]
}

@test "a green e2e on a pull request passes" {
    run_gate success success "$ELIGIBLE" pull_request
    [ "$status" -eq 0 ]
}

@test "deleting the detection check would pass a run that never computed what to test" {
    run_gate failure skipped '[]' pull_request
    [ "$status" -ne 0 ]
    run_gate cancelled success "$ELIGIBLE" pull_request
    [ "$status" -ne 0 ]
}

@test "reading the build list through the environment keeps a hostile name inert" {
    # e2e_builds carries container names and upstream-derived versions. Were it
    # interpolated into the script instead, a quote would end the assignment.
    local marker="$TEST_TEMP_DIR/executed"
    run_gate success skipped "[{\"container\":\"x'; touch $marker; #\"}]" pull_request
    [ ! -e "$marker" ]
}
