#!/usr/bin/env bats
#
# Tests for the portable version sort pipeline used in install_ext(), which lives
# in postgres/install-ext.sh — the file the Dockerfile bind-mounts and sources.
#
# The pipeline must order strict-semver X.Y.Z basenames by numeric major, minor,
# patch — NOT lexically.  The discriminator case is 2.9.0 vs 2.13.0: lexical
# sort puts 2.13.0 before 2.9.0 (wrong); numeric-field sort puts 2.9.0 first
# (correct).
#
# The pipeline must NOT use `sort -V` (GNU coreutils only, absent on Alpine/
# busybox).  It must work identically under both GNU sort and busybox sort.

# ---------------------------------------------------------------------------
# The sort invocation, READ from the helper rather than copied here.
#
# It used to be transcribed by hand with a "keep this in sync" comment, which is
# a contract nothing enforces: dropping the patch key from the real pipeline
# would leave every test below green while `2.13.9` and `2.13.10` selected the
# wrong ceiling. Reading it means a divergence cannot happen — there is one
# pipeline and these tests exercise it.
# ---------------------------------------------------------------------------
_helper_sort_flags() {
    local helper="${PROJECT_ROOT:-$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)}/postgres/install-ext.sh"
    local flags
    # Everything between `sort ` and its input file, verbatim. An earlier version
    # matched a whitelist of what a key flag looks like — `-k[0-9,]*n` — and so
    # silently dropped a trailing modifier: production changed to `-k3,3nr` came
    # back as `-k3,3n`, every test below stayed green, and the real build ordered
    # 2.13.10 before 2.13.9 and picked 2.13.9 as the ceiling. Measured. Taking the
    # text as written has no such opinion about which flags exist.
    flags=$(sed -n 's/.*[^a-z-]sort \(.*\) "\$versions_file".*/\1/p' "$helper" | head -n 1)
    [ -n "$flags" ] || return 1
    printf '%s' "$flags"
}

_sort_versions() {
    # Input: one version basename per line (e.g. "2.9.0")
    # Output: same, sorted ascending by numeric major.minor.patch
    local flags
    flags=$(_helper_sort_flags) || {
        echo "could not read the sort invocation from postgres/install-ext.sh" >&2
        return 1
    }
    # shellcheck disable=SC2086  # the flags are read from the helper, one word each
    sort $flags
}

_busybox_sort_versions() {
    local flags
    flags=$(_helper_sort_flags) || {
        echo "could not read the sort invocation from postgres/install-ext.sh" >&2
        return 1
    }
    # shellcheck disable=SC2086
    busybox sort $flags
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
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"

    # Both files: the implementation moved to the helper, and the Dockerfile
    # still holds the RUN that sources it, so either could acquire the flag.
    local file
    for file in postgres/install-ext.sh postgres/Dockerfile; do
        if grep -n 'sort -V' "$PROJECT_ROOT/$file"; then
            echo "FAIL: sort -V present in $file — GNU coreutils only, absent from the image's busybox"
            return 1
        fi
    done
}

# The sort flags the tests above run are read from the helper, so a change there
# reaches them. This asserts the reading itself works: a silent failure to find
# the invocation would leave `sort` with no flags and every ordering test would
# still pass on already-sorted input.
@test "the sort invocation is readable from the helper and keeps all three keys" {
    local flags
    flags=$(_helper_sort_flags)

    [ -n "$flags" ]
    [[ "$flags" == *"-t."* ]]
    [[ "$flags" == *"-k1,1n"* ]]
    [[ "$flags" == *"-k2,2n"* ]]
    [[ "$flags" == *"-k3,3n"* ]]
    # Ascending. A trailing `r` on any key reverses production order, and the
    # ordering tests above cannot see it: they run whatever this returns, so a
    # reversed production sort would reverse them too and still agree.
    [[ "$flags" != *"r"* ]]
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
