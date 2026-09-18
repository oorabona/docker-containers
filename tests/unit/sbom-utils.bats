#!/usr/bin/env bats

# Unit tests for the public SBOM helper contract. All producers and writers are
# local stubs; these tests never contact a registry or start a container.

load "../test_helper"

setup() {
    setup_temp_dir
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SBOM_UTILS="$PROJECT_ROOT/helpers/sbom-utils.sh"
    ORIGINAL_PATH="$PATH"
    mkdir -p "$TEST_TEMP_DIR/bin"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
}

teardown() {
    export PATH="$ORIGINAL_PATH"
    teardown_temp_dir
}

write_syft_stub() {
    cat > "$TEST_TEMP_DIR/bin/syft" <<'STUB'
#!/usr/bin/env bash
for argument in "$@"; do
    [[ "$argument" == "--help" ]] && exit 0
done

output_file=""
for argument in "$@"; do
    case "$argument" in
        spdx-json=*) output_file="${argument#spdx-json=}" ;;
    esac
done

case "${SYFT_STUB_MODE:-valid}" in
    valid) printf '{"packages":[]}' > "$output_file" ;;
    no-output) ;;
    invalid) printf 'not-json' > "$output_file" ;;
    fail) exit 1 ;;
esac
STUB
    chmod +x "$TEST_TEMP_DIR/bin/syft"
}

write_failing_jq_stub() {
    cat > "$TEST_TEMP_DIR/bin/jq" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$TEST_TEMP_DIR/bin/jq"
}

write_failing_mv_stub() {
    cat > "$TEST_TEMP_DIR/bin/mv" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$TEST_TEMP_DIR/bin/mv"
}

write_failing_wc_stub() {
    cat > "$TEST_TEMP_DIR/bin/wc" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$TEST_TEMP_DIR/bin/wc"
}

write_sbom() {
    local path="$1"
    cat > "$path" <<'JSON'
{"packages":[]}
JSON
}

write_changelog() {
    local path="$1"
    cat > "$path" <<'JSON'
{"changes":[{"type":"added","pkg_type":"unknown","name":"pkg","version":"1.0.0"}]}
JSON
}

@test "generate_sbom publishes a complete JSON document only after its producer succeeds" {
    write_syft_stub
    local output_file="$TEST_TEMP_DIR/result.sbom.json"

    run bash -c 'source "$1"; generate_sbom example/image:tag "$2"' _ "$SBOM_UTILS" "$output_file"

    [ "$status" -eq 0 ] || return 1
    jq -e '.packages == []' "$output_file" >/dev/null || return 1
    [ "$(find "$TEST_TEMP_DIR" -name 'result.sbom.json.tmp.*' -print -quit)" = "" ] || return 1
}

@test "generate_sbom returns nonzero directly when syft writes no output" {
    write_syft_stub
    local output_file="$TEST_TEMP_DIR/missing.sbom.json"

    run env SYFT_STUB_MODE=no-output bash -c 'source "$1"; generate_sbom example/image:tag "$2"' _ "$SBOM_UTILS" "$output_file"

    [ "$status" -ne 0 ] || return 1
    [ ! -e "$output_file" ] || return 1
    [[ "$output" != *"bytes)"* ]] || return 1
}

@test "generate_sbom returns nonzero as an if condition when syft writes no output" {
    write_syft_stub
    local output_file="$TEST_TEMP_DIR/missing-if.sbom.json"

    run env SYFT_STUB_MODE=no-output bash -c '
        source "$1"
        if generate_sbom example/image:tag "$2"; then
            printf "unexpected-success\\n"
            exit 1
        fi
        printf "failure-observed\\n"
    ' _ "$SBOM_UTILS" "$output_file"

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"failure-observed"* ]] || return 1
    [ ! -e "$output_file" ] || return 1
}

@test "generate_sbom detects a log-size command substitution failure on the right of ||" {
    write_syft_stub
    write_failing_wc_stub
    local output_file="$TEST_TEMP_DIR/wc-failure.sbom.json"

    run bash -c '
        source "$1"
        false || generate_sbom example/image:tag "$2"
    ' _ "$SBOM_UTILS" "$output_file"

    [ "$status" -ne 0 ] || return 1
    [ ! -e "$output_file" ] || return 1
    [ "$(find "$TEST_TEMP_DIR" -name 'wc-failure.sbom.json.tmp.*' -print -quit)" = "" ] || return 1
}

@test "compare_sboms returns nonzero for a required read failure on the left of ||" {
    write_failing_jq_stub
    local new_sbom="$TEST_TEMP_DIR/new.sbom.json"
    local old_sbom="$TEST_TEMP_DIR/old.sbom.json"
    local output_file="$TEST_TEMP_DIR/result.changelog.json"
    write_sbom "$new_sbom"
    write_sbom "$old_sbom"
    printf '{"previous":true}\n' > "$output_file"

    run bash -c '
        source "$1"
        compare_sboms "$2" "$3" "$4" || printf "failure-observed\\n"
    ' _ "$SBOM_UTILS" "$new_sbom" "$old_sbom" "$output_file"

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"failure-observed"* ]] || return 1
    [ "$(cat "$output_file")" = '{"previous":true}' ] || return 1
    [ "$(find "$TEST_TEMP_DIR" -name 'result.changelog.json.tmp.*' -print -quit)" = "" ] || return 1
}

@test "extract_sbom_summary returns nonzero for invalid JSON" {
    local invalid_sbom="$TEST_TEMP_DIR/invalid.sbom.json"
    printf 'not-json\n' > "$invalid_sbom"

    run bash -c 'source "$1"; extract_sbom_summary "$2" || printf "failure-observed\\n"' _ "$SBOM_UTILS" "$invalid_sbom"

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"failure-observed"* ]] || return 1
}

@test "enrich_changelog leaves the prior JSON whole when publishing fails" {
    write_failing_mv_stub
    local changelog_file="$TEST_TEMP_DIR/example.changelog.json"
    write_changelog "$changelog_file"
    local before
    before="$(cat "$changelog_file")"

    run bash -c '
        source "$1"
        false || enrich_changelog "$2"
    ' _ "$SBOM_UTILS" "$changelog_file"

    [ "$status" -ne 0 ] || return 1
    [ "$(cat "$changelog_file")" = "$before" ] || return 1
    [ "$(find "$TEST_TEMP_DIR" -name 'example.changelog.json.tmp.*' -print -quit)" = "" ] || return 1
}

@test "append_build_history returns nonzero on write failure without a partial history" {
    write_failing_mv_stub
    local lineage_file="$TEST_TEMP_DIR/lineage.json"
    local history_file="$TEST_TEMP_DIR/result.history.json"
    local summary='{"total":1,"apk":1}'
    cat > "$lineage_file" <<'JSON'
{"built_at":"2026-09-18T00:00:00Z","version":"1.0.0","build_digest":"sha256:abc"}
JSON

    run bash -c '
        source "$1"
        if append_build_history "$2" "$4" "$3"; then
            printf "unexpected-success\\n"
            exit 1
        fi
        printf "failure-observed\\n"
    ' _ "$SBOM_UTILS" "$lineage_file" "$history_file" "$summary"

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"failure-observed"* ]] || return 1
    [ ! -e "$history_file" ] || return 1
    [ "$(find "$TEST_TEMP_DIR" -name 'result.history.json.tmp.*' -print -quit)" = "" ] || return 1
}
