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

write_packages_sbom() {
    local path="$1"
    local packages="$2"
    "$SYSTEM_JQ" -n --argjson packages "$packages" '{packages: $packages}' > "$path"
}

write_validation_status_jq_stub() {
    cat > "$TEST_TEMP_DIR/bin/jq" <<'STUB'
#!/usr/bin/env bash
last_argument="${!#}"
if [[ "$last_argument" == "${JQ_STUB_FAIL_PATH:?}" ]]; then
    printf '%s\n' "$last_argument" >> "${JQ_STUB_CALL_LOG:?}"
    exit "${JQ_STUB_STATUS:?}"
fi
exec "$SYSTEM_JQ" "$@"
STUB
    chmod +x "$TEST_TEMP_DIR/bin/jq"
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

@test "compare_sboms keeps large package arrays out of argv" {
    local arg_max name_length=1024 package_count serialized_size
    local sbom="$TEST_TEMP_DIR/large.sbom.json"
    local changelog="$TEST_TEMP_DIR/large.changelog.json"

    arg_max=$(getconf ARG_MAX)
    package_count=$(((arg_max + 131072) / (name_length + 50) + 1))
    "$SYSTEM_JQ" -n --argjson count "$package_count" --argjson name_length "$name_length" '
        {packages: [range(0; $count) |
            {name: ("pkg-" + ("x" * $name_length) + tostring), versionInfo: "1.0.0",
             externalRefs: [{referenceCategory: "PACKAGE-MANAGER", referenceType: "purl",
                             referenceLocator: ("pkg:npm/pkg-" + tostring + "@1.0.0")}]}]}
    ' > "$sbom"
    serialized_size=$("$SYSTEM_JQ" -c '[.packages[] | {pkg_type: "npm", name, version: .versionInfo}]' "$sbom" | wc -c)
    [ "$serialized_size" -gt "$arg_max" ] || return 1

    run bash -c 'source "$1"; compare_sboms "$2" "$2" "$3"' _ "$SBOM_UTILS" "$sbom" "$changelog"
    [ "$status" -eq 0 ] || return 1
    "$SYSTEM_JQ" -e '.summary == {added: 0, removed: 0, updated: 0}' "$changelog" >/dev/null
}

@test "compare_sboms uses purl identity and updates only the changed ecosystem version" {
    local old_sbom="$TEST_TEMP_DIR/old.sbom.json"
    local new_sbom="$TEST_TEMP_DIR/new.sbom.json"
    local changelog="$TEST_TEMP_DIR/result.changelog.json"
    local old_packages='[
      {"name":"tar","versionInfo":"1.35","externalRefs":[{"referenceCategory":"PACKAGE-MANAGER","referenceType":"purl","referenceLocator":"pkg:deb/debian/tar@1.35?arch=amd64"}]},
      {"name":"tar","versionInfo":"6.2.1","externalRefs":[{"referenceCategory":"PACKAGE-MANAGER","referenceType":"purl","referenceLocator":"pkg:npm/tar@6.2.1"}]},
      {"name":"tar","versionInfo":"7.5.16","externalRefs":[{"referenceCategory":"PACKAGE-MANAGER","referenceType":"purl","referenceLocator":"pkg:npm/tar@7.5.16"}]}
    ]'
    local new_packages='[
      {"name":"tar","versionInfo":"1.35","externalRefs":[{"referenceCategory":"PACKAGE-MANAGER","referenceType":"purl","referenceLocator":"pkg:deb/debian/tar@1.35?arch=amd64"}]},
      {"name":"tar","versionInfo":"6.2.1","externalRefs":[{"referenceCategory":"PACKAGE-MANAGER","referenceType":"purl","referenceLocator":"pkg:npm/tar@6.2.1"}]},
      {"name":"tar","versionInfo":"7.5.17","externalRefs":[{"referenceCategory":"PACKAGE-MANAGER","referenceType":"purl","referenceLocator":"pkg:npm/tar@7.5.17"}]}
    ]'

    write_packages_sbom "$old_sbom" "$old_packages"
    write_packages_sbom "$new_sbom" "$old_packages"
    run bash -c 'source "$1"; compare_sboms "$2" "$3" "$4"' _ "$SBOM_UTILS" "$new_sbom" "$old_sbom" "$changelog"
    [ "$status" -eq 0 ] || return 1
    "$SYSTEM_JQ" -e '.summary == {added: 0, removed: 0, updated: 0}' "$changelog" >/dev/null || return 1

    write_packages_sbom "$new_sbom" "$new_packages"
    run bash -c 'source "$1"; compare_sboms "$2" "$3" "$4"' _ "$SBOM_UTILS" "$new_sbom" "$old_sbom" "$changelog"
    [ "$status" -eq 0 ] || return 1
    "$SYSTEM_JQ" -e '.summary == {added: 0, removed: 0, updated: 1} and
        .changes == [{type: "updated", name: "tar", pkg_type: "npm", from: "7.5.16", to: "7.5.17"}]' "$changelog" >/dev/null
}

@test "compare_sboms preserves package multiplicity" {
    local old_sbom="$TEST_TEMP_DIR/old.sbom.json"
    local new_sbom="$TEST_TEMP_DIR/new.sbom.json"
    local changelog="$TEST_TEMP_DIR/result.changelog.json"
    local package='{"name":"a","versionInfo":"1","externalRefs":[{"referenceCategory":"PACKAGE-MANAGER","referenceType":"purl","referenceLocator":"pkg:npm/a@1"}]}'

    write_packages_sbom "$old_sbom" "[$package, $package]"
    write_packages_sbom "$new_sbom" "[$package]"
    run bash -c 'source "$1"; compare_sboms "$2" "$3" "$4"' _ "$SBOM_UTILS" "$new_sbom" "$old_sbom" "$changelog"
    [ "$status" -eq 0 ] || return 1
    "$SYSTEM_JQ" -e '.summary == {added: 0, removed: 1, updated: 0} and
        .changes == [{type: "removed", name: "a", pkg_type: "npm", version: "1"}]' "$changelog" >/dev/null
}

@test "compare_sboms keeps purl qualifiers in package identity" {
    local old_sbom="$TEST_TEMP_DIR/old.sbom.json"
    local new_sbom="$TEST_TEMP_DIR/new.sbom.json"
    local changelog="$TEST_TEMP_DIR/result.changelog.json"
    local old_package='{"name":"libc6","versionInfo":"2.36","externalRefs":[{"referenceCategory":"PACKAGE-MANAGER","referenceType":"purl","referenceLocator":"pkg:deb/debian/libc6@2.36?arch=amd64"}]}'
    local new_package='{"name":"libc6","versionInfo":"2.36","externalRefs":[{"referenceCategory":"PACKAGE-MANAGER","referenceType":"purl","referenceLocator":"pkg:deb/debian/libc6@2.36?arch=arm64"}]}'

    write_packages_sbom "$old_sbom" "[$old_package]"
    write_packages_sbom "$new_sbom" "[$new_package]"
    run bash -c 'source "$1"; compare_sboms "$2" "$3" "$4"' _ "$SBOM_UTILS" "$new_sbom" "$old_sbom" "$changelog"
    [ "$status" -eq 0 ] || return 1
    "$SYSTEM_JQ" -e '.summary == {added: 1, removed: 1, updated: 0} and
        ([.changes[].type] | sort) == ["added", "removed"]' "$changelog" >/dev/null
}

@test "compare_sboms finds a purl after a non-purl package-manager reference" {
    local old_sbom="$TEST_TEMP_DIR/old.sbom.json"
    local new_sbom="$TEST_TEMP_DIR/new.sbom.json"
    local changelog="$TEST_TEMP_DIR/result.changelog.json"
    local old_package='{"name":"a","versionInfo":"1","externalRefs":[{"referenceCategory":"PACKAGE-MANAGER","referenceType":"cpe23Type","referenceLocator":"cpe:2.3:a:vendor:a:1"},{"referenceCategory":"PACKAGE-MANAGER","referenceType":"purl","referenceLocator":"pkg:npm/a@1"}]}'
    local new_package='{"name":"a","versionInfo":"2","externalRefs":[{"referenceCategory":"PACKAGE-MANAGER","referenceType":"cpe23Type","referenceLocator":"cpe:2.3:a:vendor:a:2"},{"referenceCategory":"PACKAGE-MANAGER","referenceType":"purl","referenceLocator":"pkg:npm/a@2"}]}'

    write_packages_sbom "$old_sbom" "[$old_package]"
    write_packages_sbom "$new_sbom" "[$new_package]"
    run bash -c 'source "$1"; compare_sboms "$2" "$3" "$4"' _ "$SBOM_UTILS" "$new_sbom" "$old_sbom" "$changelog"
    [ "$status" -eq 0 ] || return 1
    "$SYSTEM_JQ" -e '.changes == [{type: "updated", name: "a", pkg_type: "npm", from: "1", to: "2"}]' "$changelog" >/dev/null
}

@test "compare_sboms reports purl-less version changes as removed plus added" {
    local old_sbom="$TEST_TEMP_DIR/old.sbom.json"
    local new_sbom="$TEST_TEMP_DIR/new.sbom.json"
    local changelog="$TEST_TEMP_DIR/result.changelog.json"

    write_packages_sbom "$old_sbom" '[{"name":"a","versionInfo":"1"}]'
    write_packages_sbom "$new_sbom" '[{"name":"a","versionInfo":"2"}]'
    run bash -c 'source "$1"; compare_sboms "$2" "$3" "$4"' _ "$SBOM_UTILS" "$new_sbom" "$old_sbom" "$changelog"
    [ "$status" -eq 0 ] || return 1
    "$SYSTEM_JQ" -e '.summary == {added: 1, removed: 1, updated: 0} and
        ([.changes[].type] | sort) == ["added", "removed"]' "$changelog" >/dev/null
}

@test "compare_sboms returns 3 only for malformed old SBOMs" {
    local new_sbom="$TEST_TEMP_DIR/new.sbom.json"
    local old_sbom="$TEST_TEMP_DIR/old.sbom.json"
    write_sbom "$new_sbom"

    printf 'not-json\n' > "$old_sbom"
    run bash -c 'source "$1"; compare_sboms "$2" "$3" "$4"' _ "$SBOM_UTILS" "$new_sbom" "$old_sbom" "$TEST_TEMP_DIR/result.json"
    [ "$status" -eq 3 ] || return 1

    "$SYSTEM_JQ" -n '{packages: {not: "an array"}}' > "$old_sbom"
    run bash -c 'source "$1"; compare_sboms "$2" "$3" "$4"' _ "$SBOM_UTILS" "$new_sbom" "$old_sbom" "$TEST_TEMP_DIR/result.json"
    [ "$status" -eq 3 ]
}

@test "compare_sboms returns 3 for an empty old SBOM" {
    local new_sbom="$TEST_TEMP_DIR/new.sbom.json"
    local old_sbom="$TEST_TEMP_DIR/old.sbom.json"
    write_sbom "$new_sbom"
    : > "$old_sbom"

    run bash -c 'source "$1"; compare_sboms "$2" "$3" "$4"' _ "$SBOM_UTILS" "$new_sbom" "$old_sbom" "$TEST_TEMP_DIR/result.json"

    [ "$status" -eq 3 ]
}

@test "compare_sboms returns 3 for a whitespace-only old SBOM" {
    local new_sbom="$TEST_TEMP_DIR/new.sbom.json"
    local old_sbom="$TEST_TEMP_DIR/old.sbom.json"
    write_sbom "$new_sbom"
    printf ' \n\t\n' > "$old_sbom"

    run bash -c 'source "$1"; compare_sboms "$2" "$3" "$4"' _ "$SBOM_UTILS" "$new_sbom" "$old_sbom" "$TEST_TEMP_DIR/result.json"

    [ "$status" -eq 3 ]
}

@test "compare_sboms returns 3 for an old SBOM with two documents" {
    local new_sbom="$TEST_TEMP_DIR/new.sbom.json"
    local old_sbom="$TEST_TEMP_DIR/old.sbom.json"
    write_sbom "$new_sbom"
    printf '{"packages":[]}\n{"packages":[]}\n' > "$old_sbom"

    run bash -c 'source "$1"; compare_sboms "$2" "$3" "$4"' _ "$SBOM_UTILS" "$new_sbom" "$old_sbom" "$TEST_TEMP_DIR/result.json"

    [ "$status" -eq 3 ]
}

@test "compare_sboms returns 1 for a new SBOM with two documents" {
    local new_sbom="$TEST_TEMP_DIR/new.sbom.json"
    local old_sbom="$TEST_TEMP_DIR/old.sbom.json"
    write_sbom "$old_sbom"
    printf '{"packages":[]}\n{"packages":[]}\n' > "$new_sbom"

    run bash -c 'source "$1"; compare_sboms "$2" "$3" "$4"' _ "$SBOM_UTILS" "$new_sbom" "$old_sbom" "$TEST_TEMP_DIR/result.json"

    [ "$status" -eq 1 ]
}

@test "compare_sboms rejects an output path equal to the old SBOM without changing it" {
    local new_sbom="$TEST_TEMP_DIR/new.sbom.json"
    local old_sbom="$TEST_TEMP_DIR/old.sbom.json"
    local before_checksum after_checksum
    write_sbom "$new_sbom"
    write_sbom "$old_sbom"
    before_checksum=$(sha256sum -- "$old_sbom")

    run bash -c 'source "$1"; compare_sboms "$2" "$3" "$3"' _ "$SBOM_UTILS" "$new_sbom" "$old_sbom"
    [ "$status" -eq 2 ] || return 1

    after_checksum=$(sha256sum -- "$old_sbom")
    [ "$after_checksum" = "$before_checksum" ]
}

@test "compare_sboms rejects an output symlink to the new SBOM without changing it" {
    local new_sbom="$TEST_TEMP_DIR/new.sbom.json"
    local old_sbom="$TEST_TEMP_DIR/old.sbom.json"
    local output_file="$TEST_TEMP_DIR/output.json"
    local before_checksum after_checksum
    write_sbom "$new_sbom"
    write_sbom "$old_sbom"
    ln -s "$new_sbom" "$output_file"
    before_checksum=$(sha256sum -- "$new_sbom")

    run bash -c 'source "$1"; compare_sboms "$2" "$3" "$4"' _ "$SBOM_UTILS" "$new_sbom" "$old_sbom" "$output_file"
    [ "$status" -eq 2 ] || return 1

    after_checksum=$(sha256sum -- "$new_sbom")
    [ "$after_checksum" = "$before_checksum" ]
}

@test "compare_sboms rejects an output alias of the new SBOM when the old SBOM is missing" {
    local new_sbom="$TEST_TEMP_DIR/new.sbom.json"
    local missing_old_sbom="$TEST_TEMP_DIR/missing-old.sbom.json"
    local before_checksum after_checksum
    write_sbom "$new_sbom"
    before_checksum=$(sha256sum -- "$new_sbom")

    run bash -c 'source "$1"; compare_sboms "$2" "$3" "$2"' _ "$SBOM_UTILS" "$new_sbom" "$missing_old_sbom"
    [ "$status" -eq 2 ] || return 1

    after_checksum=$(sha256sum -- "$new_sbom")
    [ "$after_checksum" = "$before_checksum" ]
}

@test "compare_sboms rejects an output alias of a malformed old SBOM without changing it" {
    local new_sbom="$TEST_TEMP_DIR/new.sbom.json"
    local old_sbom="$TEST_TEMP_DIR/old.sbom.json"
    local before_checksum after_checksum
    write_sbom "$new_sbom"
    printf 'not-json\n' > "$old_sbom"
    before_checksum=$(sha256sum -- "$old_sbom")

    run bash -c 'source "$1"; compare_sboms "$2" "$3" "$3"' _ "$SBOM_UTILS" "$new_sbom" "$old_sbom"
    [ "$status" -eq 2 ] || return 1

    after_checksum=$(sha256sum -- "$old_sbom")
    [ "$after_checksum" = "$before_checksum" ]
}

@test "compare_sboms rejects an output alias of a malformed new SBOM" {
    local new_sbom="$TEST_TEMP_DIR/new.sbom.json"
    local old_sbom="$TEST_TEMP_DIR/old.sbom.json"
    local before_checksum after_checksum
    printf 'not-json\n' > "$new_sbom"
    write_sbom "$old_sbom"
    before_checksum=$(sha256sum -- "$new_sbom")

    run bash -c 'source "$1"; compare_sboms "$2" "$3" "$2"' _ "$SBOM_UTILS" "$new_sbom" "$old_sbom"
    [ "$status" -eq 2 ] || return 1

    after_checksum=$(sha256sum -- "$new_sbom")
    [ "$after_checksum" = "$before_checksum" ]
}

@test "compare_sboms treats old-SBOM validation execution failures as operational failures" {
    local new_sbom="$TEST_TEMP_DIR/new.sbom.json"
    local old_sbom="$TEST_TEMP_DIR/old.sbom.json"
    local jq_status jq_call_log="$TEST_TEMP_DIR/jq-calls.log"
    write_sbom "$new_sbom"
    write_sbom "$old_sbom"
    write_validation_status_jq_stub

    for jq_status in 2 127; do
        : > "$jq_call_log"
        run env JQ_STUB_STATUS="$jq_status" JQ_STUB_FAIL_PATH="$old_sbom" JQ_STUB_CALL_LOG="$jq_call_log" \
            bash -c 'source "$1"; compare_sboms "$2" "$3" "$4"' _ \
            "$SBOM_UTILS" "$new_sbom" "$old_sbom" "$TEST_TEMP_DIR/result-$jq_status.json"
        [ "$status" -eq 1 ] || return 1
        [ "$(< "$jq_call_log")" = "$old_sbom" ] || return 1
    done
}

@test "compare_sboms reports an unwritable output path as an operational failure" {
    local new_sbom="$TEST_TEMP_DIR/new.sbom.json"
    local old_sbom="$TEST_TEMP_DIR/old.sbom.json"
    write_sbom "$new_sbom"
    write_sbom "$old_sbom"

    run bash -c 'source "$1"; compare_sboms "$2" "$3" /dev/full' _ "$SBOM_UTILS" "$new_sbom" "$old_sbom"
    [ "$status" -eq 1 ]
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

@test "enrich_changelog preserves the original changelog when final mv fails" {
    write_failing_mv_stub
    local changelog_file="$TEST_TEMP_DIR/example.changelog.json"
    local original_file="$TEST_TEMP_DIR/example.changelog.original.json"
    write_changelog "$changelog_file"
    cp -- "$changelog_file" "$original_file"

    run bash -c 'source "$1"; enrich_changelog "$2"' _ "$SBOM_UTILS" "$changelog_file"

    [ "$status" -ne 0 ] || return 1
    cmp -s -- "$original_file" "$changelog_file" || return 1
}

@test "append_build_history rejects malformed changelog counters without publishing" {
    local lineage_file="$TEST_TEMP_DIR/lineage.json"
    local summary='{"total":1,"apk":1}'
    local field invalid_value changelog_file history_if history_or case_index=0
    write_lineage "$lineage_file"

    for field in added removed updated; do
        for invalid_value in '"bad"' '-1' '1.5'; do
            case_index=$((case_index + 1))
            changelog_file="$TEST_TEMP_DIR/malformed-${case_index}.changelog.json"
            history_if="$TEST_TEMP_DIR/malformed-${case_index}-if.history.json"
            history_or="$TEST_TEMP_DIR/malformed-${case_index}-or.history.json"
            printf '{"summary":{"added":1,"removed":2,"updated":3}}\n' \
                | "$SYSTEM_JQ" --arg field "$field" --argjson value "$invalid_value" \
                    '.summary[$field] = $value' > "$changelog_file"

            run bash -c '
                source "$1"
                if append_build_history "$2" "$3" "$4" 10 "$5"; then
                    printf "unexpected-if-success\\n"
                    exit 1
                fi
                printf "if-failure-observed\\n"
                append_build_history "$2" "$3" "$6" 10 "$5" || printf "or-failure-observed\\n"
            ' _ "$SBOM_UTILS" "$lineage_file" "$summary" "$history_if" "$changelog_file" "$history_or"

            [ "$status" -eq 0 ] || return 1
            [[ "$output" == *"if-failure-observed"* ]] || return 1
            [[ "$output" == *"or-failure-observed"* ]] || return 1
            [ ! -e "$history_if" ] || return 1
            [ ! -e "$history_or" ] || return 1
        done
    done
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
