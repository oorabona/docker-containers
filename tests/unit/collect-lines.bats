#!/usr/bin/env bats

# Unit and structural guards for helpers/collect-lines.sh.
#
# This guard covers array collection through mapfile/readarray from process
# substitution in scripts/ and helpers/. It does not cover while-read
# process-substitution consumers: 61 non-test sites remain and are tracked
# separately in #1117. The existing bound excludes
# github-runner/cleanup-offline-runners.sh and test-all-containers.sh.

load "../test_helper"

setup() {
    source "$HELPERS_DIR/collect-lines.sh"
}

emit_lines() {
    printf '%s\n' first second
}

emit_nothing() {
    :
}

emit_blank_line() {
    printf '\n'
}

emit_then_fail() {
    printf '%s\n' partial-one partial-two
    return 37
}

@test "collect_lines atomically replaces its output after a successful producer" {
    local output_file
    output_file=$(mktemp)

    collect_lines "$output_file" -- emit_lines
    mapfile -t actual < "$output_file"
    rm -f "$output_file"

    [ "${#actual[@]}" -eq 2 ]
    [ "${actual[0]}" = first ]
    [ "${actual[1]}" = second ]
}

@test "collect_lines preserves successful empty output" {
    local output_file
    output_file=$(mktemp)

    collect_lines "$output_file" -- emit_nothing

    [ ! -s "$output_file" ]
    rm -f "$output_file"
}

@test "collect_lines preserves one blank output line" {
    local output_file
    output_file=$(mktemp)

    collect_lines "$output_file" -- emit_blank_line
    mapfile -t actual < "$output_file"
    rm -f "$output_file"

    [ "${#actual[@]}" -eq 1 ]
    [ -z "${actual[0]}" ]
}

@test "collect_lines leaves its output unchanged when a producer fails after output" {
    local output_file
    output_file=$(mktemp)
    printf '%s\n' before one > "$output_file"
    local status

    if collect_lines "$output_file" -- emit_then_fail; then
        false
    else
        status=$?
    fi

    [ "$status" -eq 37 ]
    mapfile -t actual < "$output_file"
    rm -f "$output_file"
    [ "${#actual[@]}" -eq 2 ]
    [ "${actual[0]}" = before ]
    [ "${actual[1]}" = one ]
}

@test "collect_lines rejects invalid output destinations" {
    local status

    if collect_lines "$BATS_TEST_TMPDIR/missing/output" -- emit_lines; then
        false
    else
        status=$?
    fi

    [ "$status" -eq 2 ]

    if collect_lines "$BATS_TEST_TMPDIR" -- emit_lines; then
        false
    else
        status=$?
    fi

    [ "$status" -eq 2 ]
}

@test "real callers propagate collection failure from if, bang, and or contexts" {
    run bash -c '
        set -euo pipefail
        source "$1"
        producer() { printf "partial\\n"; return 37; }
        output=$(mktemp)
        from_if() { if collect_lines "$output" -- producer; then :; else return "$?"; fi; }
        from_bang() { if ! collect_lines "$output" -- producer; then return 37; fi; }
        from_or() { collect_lines "$output" -- producer || return "$?"; }
        for caller in from_if from_bang from_or; do
            if "$caller"; then
                exit 1
            else
                [[ "$?" -eq 37 ]] || exit 1
            fi
        done
    ' _ "$HELPERS_DIR/collect-lines.sh"

    [ "$status" -eq 0 ]
}

assert_consumer_uses_collector() {
    local script="$1"

    grep -Eq 'source .*helpers/collect-lines\.sh' "$PROJECT_ROOT/$script"
    ! grep -Eq '(^|[;[:space:]])(mapfile|readarray)[[:space:]].*<[[:space:]]*<\(' "$PROJECT_ROOT/$script"
}

@test "audit-base-image-cache sources the collector and has no raw process-substitution reader" {
    assert_consumer_uses_collector scripts/audit-base-image-cache.sh
}

@test "build-container sources the collector and has no raw process-substitution reader" {
    assert_consumer_uses_collector scripts/build-container.sh
}

@test "check-dependency-versions sources the collector and has no raw process-substitution reader" {
    assert_consumer_uses_collector scripts/check-dependency-versions.sh
}

@test "check-gpg-keys sources the collector and has no raw process-substitution reader" {
    assert_consumer_uses_collector scripts/check-gpg-keys.sh
}

@test "cleanup-ext-images sources the collector and has no raw process-substitution reader" {
    assert_consumer_uses_collector scripts/cleanup-ext-images.sh
}

@test "commit-stats-snapshot sources the collector and has no raw process-substitution reader" {
    assert_consumer_uses_collector scripts/commit-stats-snapshot.sh
}

@test "detect-base-digest-drift sources the collector and has no raw process-substitution reader" {
    assert_consumer_uses_collector scripts/detect-base-digest-drift.sh
}

@test "rotate-versions sources the collector and has no raw process-substitution reader" {
    assert_consumer_uses_collector scripts/rotate-versions.sh
}

@test "process-substitution reader guard is bounded to scripts and helpers" {
    local file
    local raw_readers

    raw_readers=$(rg -l -U '(mapfile|readarray)[^\n]*<[[:space:]]*<\(' "$PROJECT_ROOT/scripts" "$PROJECT_ROOT/helpers" || true)
    for file in $raw_readers; do
        [ "$file" = "$PROJECT_ROOT/helpers/collect-lines.sh" ] || {
            echo "raw process-substitution reader outside collector: $file" >&2
            return 1
        }
    done
}
