#!/usr/bin/env bats
#
# Tests for the portable version sort pipeline used in install_ext() inside
# postgres/Dockerfile.
#
# The pipeline must order strict-semver X.Y.Z basenames by numeric major, minor,
# patch — NOT lexically.  The discriminator case is 2.9.0 vs 2.13.0: lexical
# sort puts 2.13.0 before 2.9.0 (wrong); numeric-field sort puts 2.9.0 first
# (correct).
#
# The pipeline must NOT use `sort -V` (GNU coreutils only, absent on Alpine/
# busybox).  It must work identically under both GNU sort and busybox sort.

# ---------------------------------------------------------------------------
# The portable sort pipeline extracted verbatim from install_ext().
# If you change install_ext, keep this in sync.
# ---------------------------------------------------------------------------
_sort_versions() {
    # Input: one version basename per line (e.g. "2.9.0")
    # Output: same, sorted ascending by numeric major.minor.patch
    sort -t. -k1,1n -k2,2n -k3,3n
}

_busybox_sort_versions() {
    busybox sort -t. -k1,1n -k2,2n -k3,3n
}

# ---------------------------------------------------------------------------
# Helper: run the pipeline and capture ordered output
# ---------------------------------------------------------------------------
_sorted() {
    printf '%s\n' "$@" | _sort_versions
}

_busybox_sorted() {
    printf '%s\n' "$@" | _busybox_sort_versions
}

# ---------------------------------------------------------------------------
# Core ordering tests (GNU sort)
# ---------------------------------------------------------------------------

@test "portable sort: 2.9.0 comes before 2.13.0 (numeric, not lexical)" {
    result=$(_sorted 2.13.0 2.9.0)
    first=$(echo "$result" | head -1)
    [ "$first" = "2.9.0" ]
}

@test "portable sort: ascending order for 2.13.0 2.9.0 2.27.1 2.13.1" {
    result=$(_sorted 2.13.0 2.9.0 2.27.1 2.13.1)
    expected=$(printf '%s\n' 2.9.0 2.13.0 2.13.1 2.27.1)
    [ "$result" = "$expected" ]
}

@test "portable sort: tail-1 (ceiling) returns 2.27.1 not 2.9.0 or 2.13.1" {
    ceiling=$(_sorted 2.13.0 2.9.0 2.27.1 2.13.1 | tail -1)
    [ "$ceiling" = "2.27.1" ]
}

@test "portable sort: lexical sort would give wrong order (control: 2.13.0 before 2.9.0 lexically)" {
    # Confirm that naive lexical sort IS wrong — validates the need for the fix
    wrong_first=$(printf '%s\n' 2.13.0 2.9.0 | sort | head -1)
    [ "$wrong_first" = "2.13.0" ]
}

@test "portable sort: single version returns itself" {
    result=$(_sorted 2.5.3)
    [ "$result" = "2.5.3" ]
}

@test "portable sort: patch ordering 2.13.0 before 2.13.1" {
    result=$(_sorted 2.13.1 2.13.0)
    first=$(echo "$result" | head -1)
    [ "$first" = "2.13.0" ]
}

@test "portable sort: major version ordering 1.x before 2.x" {
    result=$(_sorted 2.0.0 1.9.9)
    first=$(echo "$result" | head -1)
    [ "$first" = "1.9.9" ]
}

# ---------------------------------------------------------------------------
# Prove the pipeline does NOT use -V
# ---------------------------------------------------------------------------

@test "pipeline does not use sort -V" {
    # Grep the Dockerfile for sort -V inside install_ext.
    # The test file lives at tests/unit/; PROJECT_ROOT is two levels up.
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
    # sort -V must not appear anywhere in the Dockerfile (executable or comment).
    if grep -n 'sort -V' "$PROJECT_ROOT/postgres/Dockerfile"; then
        echo "FAIL: sort -V present in postgres/Dockerfile"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Busybox compatibility (skip if busybox absent)
# ---------------------------------------------------------------------------

@test "busybox sort: 2.9.0 comes before 2.13.0" {
    if ! command -v busybox > /dev/null 2>&1; then
        skip "busybox not available on this runner"
    fi
    result=$(_busybox_sorted 2.13.0 2.9.0)
    first=$(echo "$result" | head -1)
    [ "$first" = "2.9.0" ]
}

@test "busybox sort: ascending order for 2.13.0 2.9.0 2.27.1 2.13.1" {
    if ! command -v busybox > /dev/null 2>&1; then
        skip "busybox not available on this runner"
    fi
    result=$(_busybox_sorted 2.13.0 2.9.0 2.27.1 2.13.1)
    expected=$(printf '%s\n' 2.9.0 2.13.0 2.13.1 2.27.1)
    [ "$result" = "$expected" ]
}

@test "busybox sort: ceiling (tail-1) returns 2.27.1" {
    if ! command -v busybox > /dev/null 2>&1; then
        skip "busybox not available on this runner"
    fi
    ceiling=$(_busybox_sorted 2.13.0 2.9.0 2.27.1 2.13.1 | tail -1)
    [ "$ceiling" = "2.27.1" ]
}

@test "busybox sort: matches GNU sort output" {
    if ! command -v busybox > /dev/null 2>&1; then
        skip "busybox not available on this runner"
    fi
    gnu_out=$(_sorted 2.13.0 2.9.0 2.27.1 2.13.1)
    bb_out=$(_busybox_sorted 2.13.0 2.9.0 2.27.1 2.13.1)
    [ "$gnu_out" = "$bb_out" ]
}
