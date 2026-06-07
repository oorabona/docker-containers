#!/usr/bin/env bats

# Unit tests for scripts/cleanup-outdated-tags.sh
# Focus: is_valid_tag — bake cache tag validity derived from underlying base tag

# Source is_valid_tag from the script.
# The script has top-level guards (GH_TOKEN, OWNER) and a main loop; we set
# dummy env vars and an empty CONTAINERS so the loop is a no-op on source.
# We do NOT use bats `run` for is_valid_tag since that would re-execute the
# main loop in the subshell.  Instead we call the function directly and check
# the return code.

setup() {
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"

    export GH_TOKEN="test-token"
    export OWNER="test-owner"
    export DRY_RUN="true"
    # Empty CONTAINERS prevents the main loop from iterating anything
    export CONTAINERS=""

    # Create a stub make so the script doesn't call the real one
    _STUB_DIR="$(mktemp -d)"
    mkdir -p "$_STUB_DIR"
    printf '#!/bin/bash\necho ""\n' > "$_STUB_DIR/make"
    chmod +x "$_STUB_DIR/make"
    export PATH="$_STUB_DIR:$PATH"

    # Source the script; the main loop runs but CONTAINERS="" → no iterations
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh" 2>/dev/null || true

    export _STUB_DIR
}

teardown() {
    rm -rf "${_STUB_DIR:-}"
    unset GH_TOKEN OWNER DRY_RUN CONTAINERS _STUB_DIR
}

# ---------------------------------------------------------------------------
# Helper: build a newline-separated valid-tag list
# ---------------------------------------------------------------------------
make_valid_tags() {
    printf '%s\n' "$@"
}

# ---------------------------------------------------------------------------
# Direct-match tests (regression: existing behaviour must be preserved)
# ---------------------------------------------------------------------------

@test "is_valid_tag: exact match returns valid" {
    local valid_tags
    valid_tags=$(make_valid_tags "2.334.0" "latest" "buildcache")
    is_valid_tag "2.334.0" "$valid_tags"
}

@test "is_valid_tag: unknown tag returns invalid" {
    local valid_tags
    valid_tags=$(make_valid_tags "2.334.0" "latest" "buildcache")
    ! is_valid_tag "9.9.9" "$valid_tags"
}

@test "is_valid_tag: arch-specific of a valid base tag (amd64) returns valid" {
    local valid_tags
    valid_tags=$(make_valid_tags "2.334.0" "latest" "buildcache")
    is_valid_tag "2.334.0-amd64" "$valid_tags"
}

@test "is_valid_tag: arch-specific of a valid base tag (arm64) returns valid" {
    local valid_tags
    valid_tags=$(make_valid_tags "2.334.0" "latest" "buildcache")
    is_valid_tag "2.334.0-arm64" "$valid_tags"
}

# ---------------------------------------------------------------------------
# Bare buildcache (flat-matrix rolling cache) — must stay preserved
# ---------------------------------------------------------------------------

@test "is_valid_tag: bare 'buildcache' preserved via direct match" {
    # bare buildcache is emitted into valid_tags by build_valid_tags; direct match
    local valid_tags
    valid_tags=$(make_valid_tags "2.334.0" "latest" "buildcache")
    is_valid_tag "buildcache" "$valid_tags"
}

# ---------------------------------------------------------------------------
# Bake cache tags — new derived-validity logic
# ---------------------------------------------------------------------------

@test "is_valid_tag: buildcache-<valid-tag>-amd64 is kept when base tag is valid" {
    local valid_tags
    valid_tags=$(make_valid_tags "2.334.0" "latest" "buildcache")
    is_valid_tag "buildcache-2.334.0-amd64" "$valid_tags"
}

@test "is_valid_tag: buildcache-<valid-tag>-arm64 is kept when base tag is valid" {
    local valid_tags
    valid_tags=$(make_valid_tags "2.334.0" "latest" "buildcache")
    is_valid_tag "buildcache-2.334.0-arm64" "$valid_tags"
}

@test "is_valid_tag: buildcache-<rotated-out-tag>-amd64 is purged when base tag is invalid" {
    # 1.0.0 is no longer in valid_tags (rotated out)
    local valid_tags
    valid_tags=$(make_valid_tags "2.334.0" "latest" "buildcache")
    ! is_valid_tag "buildcache-1.0.0-amd64" "$valid_tags"
}

@test "is_valid_tag: buildcache-<rotated-out-tag>-arm64 is purged when base tag is invalid" {
    local valid_tags
    valid_tags=$(make_valid_tags "2.334.0" "latest" "buildcache")
    ! is_valid_tag "buildcache-1.0.0-arm64" "$valid_tags"
}

@test "is_valid_tag: buildcache with variant suffix preserved when variant base is valid" {
    # buildcache-2.334.0-dev-amd64 → base tag = 2.334.0-dev
    local valid_tags
    valid_tags=$(make_valid_tags "2.334.0-dev" "latest" "buildcache")
    is_valid_tag "buildcache-2.334.0-dev-amd64" "$valid_tags"
}

@test "is_valid_tag: buildcache with variant suffix purged when variant base is invalid" {
    # 2.334.0-dev rotated out; only 2.334.0 remains
    local valid_tags
    valid_tags=$(make_valid_tags "2.334.0" "latest" "buildcache")
    ! is_valid_tag "buildcache-2.334.0-dev-amd64" "$valid_tags"
}

@test "is_valid_tag: buildcache with distro-qualified tag (trixie) preserved when base valid" {
    # buildcache-trixie-amd64 → base tag = trixie
    local valid_tags
    valid_tags=$(make_valid_tags "trixie" "latest" "buildcache")
    is_valid_tag "buildcache-trixie-amd64" "$valid_tags"
}

@test "is_valid_tag: buildcache with distro-qualified tag purged when base invalid" {
    local valid_tags
    valid_tags=$(make_valid_tags "2.334.0" "latest" "buildcache")
    ! is_valid_tag "buildcache-trixie-amd64" "$valid_tags"
}

# ---------------------------------------------------------------------------
# Arch suffix anchored at end — must not strip mid-tag -amd64 substrings
# ---------------------------------------------------------------------------

@test "is_valid_tag: trailing -amd64 stripped only from end, not mid-tag" {
    # buildcache-foo-amd64-bar-amd64 → strip trailing -amd64 → base = foo-amd64-bar
    local valid_tags
    valid_tags=$(make_valid_tags "foo-amd64-bar" "latest" "buildcache")
    is_valid_tag "buildcache-foo-amd64-bar-amd64" "$valid_tags"
}

@test "is_valid_tag: trailing -amd64 stripped at end only, base not in valid tags → invalid" {
    local valid_tags
    valid_tags=$(make_valid_tags "foo-amd64" "latest" "buildcache")
    # buildcache-foo-amd64-bar-amd64 → base = foo-amd64-bar, NOT in valid_tags
    ! is_valid_tag "buildcache-foo-amd64-bar-amd64" "$valid_tags"
}

# ---------------------------------------------------------------------------
# Malformed / edge cases
# ---------------------------------------------------------------------------

@test "is_valid_tag: buildcache tag without arch suffix is invalid" {
    # buildcache-2.334.0 (no -amd64/-arm64) → no recognised arch suffix → invalid
    local valid_tags
    valid_tags=$(make_valid_tags "2.334.0" "latest" "buildcache")
    ! is_valid_tag "buildcache-2.334.0" "$valid_tags"
}

@test "is_valid_tag: double-prefix buildcache-buildcache- is invalid" {
    local valid_tags
    valid_tags=$(make_valid_tags "2.334.0" "latest" "buildcache")
    ! is_valid_tag "buildcache-buildcache-2.334.0-amd64" "$valid_tags"
}

@test "is_valid_tag: buildcache-amd64 is valid as arch-specific variant of bare buildcache" {
    # buildcache-amd64 is matched by the arch-specific-suffix branch (not the buildcache-* branch):
    # strip trailing -amd64 → 'buildcache', which IS in valid_tags → valid.
    # This preserves the per-arch flat-matrix cache entries.
    local valid_tags
    valid_tags=$(make_valid_tags "2.334.0" "latest" "buildcache")
    is_valid_tag "buildcache-amd64" "$valid_tags"
}
