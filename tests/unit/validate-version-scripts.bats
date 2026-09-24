#!/usr/bin/env bats

load "../test_helper"

setup() {
    FIXTURE_ROOT="$BATS_TEST_TMPDIR/validate-version-scripts"

    mkdir -p "$FIXTURE_ROOT/helpers" \
        "$FIXTURE_ROOT/postgres/extensions" \
        "$FIXTURE_ROOT/missing-version"
    cp "$PROJECT_ROOT/validate-version-scripts.sh" "$FIXTURE_ROOT/"
    cp "$PROJECT_ROOT/helpers/logging.sh" \
        "$PROJECT_ROOT/helpers/validate-base-cache-schema.sh" \
        "$PROJECT_ROOT/helpers/validate-extensions-schema.sh" \
        "$FIXTURE_ROOT/helpers/"
    cp "$PROJECT_ROOT/postgres/extensions/config.yaml" \
        "$FIXTURE_ROOT/postgres/extensions/"
    touch "$FIXTURE_ROOT/missing-version/Dockerfile"
    chmod +x "$FIXTURE_ROOT/validate-version-scripts.sh"
}

run_validator() {
    run bash -c 'cd "$1" && ./validate-version-scripts.sh "$2"' \
        _ "$FIXTURE_ROOT" "$1"
}

@test "explicit container without version.sh fails and names the missing script" {
    run_validator missing-version

    [ "$status" -ne 0 ]
    assert_output_contains "missing-version/version.sh"
    assert_output_contains "Explicitly requested container is missing missing-version/version.sh"
    assert_output_not_contains "skipping"
    assert_output_contains "Failed: 1"
    assert_output_contains "Skipped: 0"
}

@test "unscoped validation keeps a container without version.sh as skipped" {
    run_validator ""

    [ "$status" -eq 0 ]
    assert_output_contains "No version.sh file found - skipping"
    assert_output_contains "Failed: 0"
    assert_output_contains "Skipped: 1"
}
