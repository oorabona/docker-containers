#!/usr/bin/env bats

# Unit tests for the public SBOM helper contract. All producers and writers are
# local stubs; these tests never contact a registry or start a container.

load "../test_helper"

setup() {
    setup_temp_dir
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SBOM_UTILS="$PROJECT_ROOT/helpers/sbom-utils.sh"
    ORIGINAL_PATH="$PATH"
    SYSTEM_JQ="$(command -v jq)"
    export SYSTEM_JQ
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
    multi-root) printf '[]\n{"packages":[]}\n' > "$output_file" ;;
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

write_generation_failing_jq_stub() {
    cat > "$TEST_TEMP_DIR/bin/jq" <<'STUB'
#!/usr/bin/env bash
for argument in "$@"; do
    [[ "$argument" == "-n" ]] && exit 1
done
exec "$SYSTEM_JQ" "$@"
STUB
    chmod +x "$TEST_TEMP_DIR/bin/jq"
}

write_failing_wc_stub() {
    cat > "$TEST_TEMP_DIR/bin/wc" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$TEST_TEMP_DIR/bin/wc"
}

write_failing_mkdir_stub() {
    cat > "$TEST_TEMP_DIR/bin/mkdir" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$TEST_TEMP_DIR/bin/mkdir"
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

write_lineage() {
    local path="$1"
    cat > "$path" <<'JSON'
{"built_at":"2026-09-18T00:00:00Z","version":"1.0.0","build_digest":"sha256:abc"}
JSON
}

@test "generate_sbom publishes a valid JSON object" {
    write_syft_stub
    local output_file="$TEST_TEMP_DIR/result.sbom.json"

    run bash -c 'source "$1"; generate_sbom example/image:tag "$2"' _ "$SBOM_UTILS" "$output_file"

    [ "$status" -eq 0 ] || return 1
    jq -e '.packages == []' "$output_file" >/dev/null || return 1
}

@test "generate_sbom returns failure to if and || when syft writes no output" {
    write_syft_stub

    run env SYFT_STUB_MODE=no-output bash -c '
        source "$1"
        if generate_sbom example/image:tag "$2"; then
            printf "unexpected-if-success\\n"
            exit 1
        fi
        printf "if-failure-observed\\n"
        generate_sbom example/image:tag "$3" || printf "or-failure-observed\\n"
    ' _ "$SBOM_UTILS" "$TEST_TEMP_DIR/missing-if.sbom.json" "$TEST_TEMP_DIR/missing-or.sbom.json"

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"if-failure-observed"* ]] || return 1
    [[ "$output" == *"or-failure-observed"* ]] || return 1
    [[ "$output" != *"bytes)"* ]] || return 1
}

@test "generate_sbom returns failure to if and || when wc fails" {
    write_syft_stub
    write_failing_wc_stub

    run bash -c '
        source "$1"
        if generate_sbom example/image:tag "$2"; then
            printf "unexpected-if-success\\n"
            exit 1
        fi
        printf "if-failure-observed\\n"
        generate_sbom example/image:tag "$3" || printf "or-failure-observed\\n"
    ' _ "$SBOM_UTILS" "$TEST_TEMP_DIR/wc-if.sbom.json" "$TEST_TEMP_DIR/wc-or.sbom.json"

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"if-failure-observed"* ]] || return 1
    [[ "$output" == *"or-failure-observed"* ]] || return 1
    [[ "$output" != *"bytes)"* ]] || return 1
}

@test "generate_sbom rejects a multi-root JSON stream" {
    write_syft_stub
    local output_file="$TEST_TEMP_DIR/multi-root.sbom.json"

    run env SYFT_STUB_MODE=multi-root bash -c 'source "$1"; generate_sbom example/image:tag "$2" || printf "failure-observed\\n"' _ "$SBOM_UTILS" "$output_file"

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"failure-observed"* ]] || return 1
}

@test "generate_sbom returns failure to if and || when mkdir fails" {
    write_syft_stub
    write_failing_mkdir_stub

    run bash -c '
        source "$1"
        if generate_sbom example/image:tag "$2"; then
            printf "unexpected-if-success\\n"
            exit 1
        fi
        printf "if-failure-observed\\n"
        generate_sbom example/image:tag "$3" || printf "or-failure-observed\\n"
    ' _ "$SBOM_UTILS" "$TEST_TEMP_DIR/new-if/result.sbom.json" "$TEST_TEMP_DIR/new-or/result.sbom.json"

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"if-failure-observed"* ]] || return 1
    [[ "$output" == *"or-failure-observed"* ]] || return 1
}

@test "compare_sboms returns failure to if and || when a required jq read fails" {
    write_failing_jq_stub
    local new_sbom="$TEST_TEMP_DIR/new.sbom.json"
    local old_sbom="$TEST_TEMP_DIR/old.sbom.json"
    write_sbom "$new_sbom"
    write_sbom "$old_sbom"

    run bash -c '
        source "$1"
        if compare_sboms "$2" "$3" "$4"; then
            printf "unexpected-if-success\\n"
            exit 1
        fi
        printf "if-failure-observed\\n"
        compare_sboms "$2" "$3" "$5" || printf "or-failure-observed\\n"
    ' _ "$SBOM_UTILS" "$new_sbom" "$old_sbom" "$TEST_TEMP_DIR/result-if.changelog.json" "$TEST_TEMP_DIR/result-or.changelog.json"

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"if-failure-observed"* ]] || return 1
    [[ "$output" == *"or-failure-observed"* ]] || return 1
}

@test "compare_sboms returns failure to if and || when its jq writer fails" {
    write_generation_failing_jq_stub
    local new_sbom="$TEST_TEMP_DIR/new.sbom.json"
    local old_sbom="$TEST_TEMP_DIR/old.sbom.json"
    write_sbom "$new_sbom"
    write_sbom "$old_sbom"

    run bash -c '
        source "$1"
        if compare_sboms "$2" "$3" "$4"; then
            printf "unexpected-if-success\\n"
            exit 1
        fi
        printf "if-failure-observed\\n"
        compare_sboms "$2" "$3" "$5" || printf "or-failure-observed\\n"
    ' _ "$SBOM_UTILS" "$new_sbom" "$old_sbom" "$TEST_TEMP_DIR/result-if.changelog.json" "$TEST_TEMP_DIR/result-or.changelog.json"

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"if-failure-observed"* ]] || return 1
    [[ "$output" == *"or-failure-observed"* ]] || return 1
}

@test "extract_sbom_summary returns failure to if and || for invalid JSON" {
    local invalid_sbom="$TEST_TEMP_DIR/invalid.sbom.json"
    printf 'not-json\n' > "$invalid_sbom"

    run bash -c '
        source "$1"
        if extract_sbom_summary "$2"; then
            printf "unexpected-if-success\\n"
            exit 1
        fi
        printf "if-failure-observed\\n"
        extract_sbom_summary "$2" || printf "or-failure-observed\\n"
    ' _ "$SBOM_UTILS" "$invalid_sbom"

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"if-failure-observed"* ]] || return 1
    [[ "$output" == *"or-failure-observed"* ]] || return 1
}

@test "enrich_changelog returns failure to if and || when dependency freshness cannot load" {
    local changelog_file="$TEST_TEMP_DIR/example.changelog.json"
    write_changelog "$changelog_file"

    run bash -c '
        source "$1"
        source() {
            if [[ "$1" == */dependency-freshness.sh ]]; then
                return 1
            fi
            builtin source "$@"
        }
        if enrich_changelog "$2"; then
            printf "unexpected-if-success\\n"
            exit 1
        fi
        printf "if-failure-observed\\n"
        enrich_changelog "$2" || printf "or-failure-observed\\n"
    ' _ "$SBOM_UTILS" "$changelog_file"

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"if-failure-observed"* ]] || return 1
    [[ "$output" == *"or-failure-observed"* ]] || return 1
}

@test "append_build_history returns failure to if and || for malformed changelog counters" {
    local lineage_file="$TEST_TEMP_DIR/lineage.json"
    local changelog_file="$TEST_TEMP_DIR/result.changelog.json"
    local summary='{"total":1,"apk":1}'
    write_lineage "$lineage_file"
    printf '{"summary":{"added":"bad","removed":2,"updated":3}}\n' > "$changelog_file"

    run bash -c '
        source "$1"
        if append_build_history "$2" "$3" "$4" 10 "$5"; then
            printf "unexpected-if-success\\n"
            exit 1
        fi
        printf "if-failure-observed\\n"
        append_build_history "$2" "$3" "$6" 10 "$5" || printf "or-failure-observed\\n"
    ' _ "$SBOM_UTILS" "$lineage_file" "$summary" "$TEST_TEMP_DIR/result-if.history.json" "$changelog_file" "$TEST_TEMP_DIR/result-or.history.json"

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"if-failure-observed"* ]] || return 1
    [[ "$output" == *"or-failure-observed"* ]] || return 1
}

@test "append_build_history returns failure to if and || when its jq writer fails" {
    write_generation_failing_jq_stub
    local lineage_file="$TEST_TEMP_DIR/lineage.json"
    local summary='{"total":1,"apk":1}'
    write_lineage "$lineage_file"

    run bash -c '
        source "$1"
        if append_build_history "$2" "$3" "$4"; then
            printf "unexpected-if-success\\n"
            exit 1
        fi
        printf "if-failure-observed\\n"
        append_build_history "$2" "$3" "$5" || printf "or-failure-observed\\n"
    ' _ "$SBOM_UTILS" "$lineage_file" "$summary" "$TEST_TEMP_DIR/result-if.history.json" "$TEST_TEMP_DIR/result-or.history.json"

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"if-failure-observed"* ]] || return 1
    [[ "$output" == *"or-failure-observed"* ]] || return 1
}

@test "append_build_history publishes valid non-negative integer counters" {
    local lineage_file="$TEST_TEMP_DIR/lineage.json"
    local changelog_file="$TEST_TEMP_DIR/result.changelog.json"
    local history_file="$TEST_TEMP_DIR/result.history.json"
    local summary='{"total":1,"apk":1}'
    write_lineage "$lineage_file"
    printf '{"summary":{"added":1,"removed":2,"updated":3}}\n' > "$changelog_file"

    run bash -c 'source "$1"; append_build_history "$2" "$3" "$4" 10 "$5"' \
        _ "$SBOM_UTILS" "$lineage_file" "$summary" "$history_file" "$changelog_file"

    [ "$status" -eq 0 ] || return 1
    [ "$(jq -r '.[0].changes_summary' "$history_file")" = '+1 -2 ~3' ] || return 1
}
