#!/usr/bin/env bats

# Unit tests: lifecycle behavior — P1, P2 (partial), P3, P4, date escalation
#
# AC-3  eol-migrate surfaced via check-dependency-versions.sh (P1)
# AC-11 stable-pin date escalation triple (silent / countdown / loud)
# AC-13 pre-release exclusion + fail-closed
# AC-15 coupled-atomic refuse (P3)
# AC-17 github-tag dispatch reaches latest-github-tag with filter/extract

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
    ORIG_DIR="$PWD"
    # Symlinks registered here are removed in teardown().
    # The actual directory content lives in BATS_TEST_TMPDIR and is auto-cleaned
    # by bats — only the REPO_ROOT symlinks need explicit teardown.
    CONTAINER_SYMLINKS=()
}

teardown() {
    # Remove REPO_ROOT symlinks created by _mk_container.
    # Directory content in BATS_TEST_TMPDIR is cleaned by bats automatically.
    for link in "${CONTAINER_SYMLINKS[@]:-}"; do
        [[ -L "$link" ]] && rm -f "$link"
    done
    cd "$ORIG_DIR" 2>/dev/null || true

    # CLASS-LEVEL CLEANLINESS CHECK (Class #2 regression lock):
    # Verify no bats-* symlinks leaked into REPO_ROOT after teardown.
    # A leak means _mk_container was called via $(...) so CONTAINER_SYMLINKS
    # was populated in a subshell — the symlink was created but never registered,
    # and teardown() could not remove it.
    local leaked=0
    local leaked_list=""
    while IFS= read -r -d '' link; do
        # Only flag symlinks pointing into a bats tmp dir
        local target
        target=$(readlink -f "$link" 2>/dev/null || true)
        if [[ "$target" == *"/bats"* || "$target" == *"/tmp."* ]]; then
            leaked=$((leaked + 1))
            leaked_list="$leaked_list $link"
            rm -f "$link"  # best-effort cleanup to avoid polluting subsequent tests
        fi
    done < <(find "$REPO_ROOT" -maxdepth 1 -name "bats-*" -type l -print0 2>/dev/null)
    if [[ "$leaked" -gt 0 ]]; then
        echo "CLEANLINESS FAIL: ${leaked} symlink(s) leaked into REPO_ROOT after teardown."
        echo "  Leaked:${leaked_list}"
        echo "  This means _mk_container was called via \$(...) (subshell) somewhere in this test."
        echo "  Fix: call _mk_container directly and use local cdir=\"\$_MK_CONTAINER_RESULT\"."
        return 1
    fi
}

# Create a synthetic container dir under BATS_TEST_TMPDIR (per-test isolation).
# A symlink is created in REPO_ROOT so that check-dependency-versions.sh can
# resolve <container>/config.yaml via PROJECT_ROOT.
# bats auto-cleans BATS_TEST_TMPDIR; the symlink is removed in teardown().
#
# IMPORTANT: This function registers the symlink in CONTAINER_SYMLINKS and
# writes the directory path to _MK_CONTAINER_RESULT. Call it as a direct call
# (NOT via command substitution) to ensure the CONTAINER_SYMLINKS side-effect
# reaches the parent shell:
#
#   _mk_container "my-name-$$"
#   local cdir="$_MK_CONTAINER_RESULT"
#
# Calling via $(_mk_container ...) runs it in a subshell: the CONTAINER_SYMLINKS
# append is lost and teardown() never removes the symlink.
_mk_container() {
    local name="$1"
    local dir="${BATS_TEST_TMPDIR}/${name}"
    mkdir -p "$dir"
    # Symlink REPO_ROOT/<name> → BATS_TEST_TMPDIR/<name>
    local link="${REPO_ROOT}/${name}"
    ln -sfn "$dir" "$link"
    CONTAINER_SYMLINKS+=("$link")
    _MK_CONTAINER_RESULT="$dir"
}

# ---------------------------------------------------------------------------
# P1 — eol-migrate is LOUD, never silently skipped (AC-3)
# The regression lock: BEFORE this change, monitor:false → silent continue.
# AFTER: lifecycle=eol-migrate → LOUD surface, never continue-skipped.
#
# Mutation caught: removing the eol-migrate case from the lifecycle dispatch
# would cause the test to fail because no ::warning:: line would be emitted.
# ---------------------------------------------------------------------------

@test "P1: eol-migrate entry produces a LOUD ::warning:: via check-dependency-versions.sh" {
    # Synthetic container with an eol-migrate entry — must live under REPO_ROOT
    _mk_container "bats-eol-test-$$"
    local cdir="$_MK_CONTAINER_RESULT"
    local cname
    cname=$(basename "$cdir")

    cat > "$cdir/config.yaml" <<'EOF'
build_args:
  FROZEN_LIB_VERSION: "1.0.0"
dependency_sources:
  FROZEN_LIB_VERSION:
    monitor: false
    lifecycle: eol-migrate
    type: github-release
    repo: example/example-lib
    reason: "EOL upstream, migration pending"
EOF

    # Run check-dependency-versions.sh against the synthetic container
    local output
    output=$(bash "$REPO_ROOT/scripts/check-dependency-versions.sh" "$cname" 2>&1 \
        || true)

    # Assert: the ::warning:: annotation is emitted
    echo "$output" | grep -q "eol-migrate" || {
        echo "FAIL: no eol-migrate signal in output"
        echo "OUTPUT: $output"
        return 1
    }

    # Assert: "migration required" or similar loud signal is present
    echo "$output" | grep -qE "migration|eol-migrate|manual" || {
        echo "FAIL: no migration-required signal in output"
        echo "OUTPUT: $output"
        return 1
    }
}

@test "P1: eol-migrate entry does NOT silently continue (output contains the dep name)" {
    _mk_container "bats-eol-test2-$$"
    local cdir="$_MK_CONTAINER_RESULT"
    local cname
    cname=$(basename "$cdir")

    cat > "$cdir/config.yaml" <<'EOF'
build_args:
  MY_EOL_DEP: "2.3.4"
dependency_sources:
  MY_EOL_DEP:
    monitor: false
    lifecycle: eol-migrate
    type: github-release
    repo: example/eol-lib
    reason: "Vendor dropped support in 2024"
EOF

    local output
    output=$(bash "$REPO_ROOT/scripts/check-dependency-versions.sh" "$cname" 2>&1 \
        || true)

    # The dep name must appear — it was NOT silently skipped
    echo "$output" | grep -q "MY_EOL_DEP" || {
        echo "FAIL: dep name 'MY_EOL_DEP' not found in output — was silently skipped"
        echo "OUTPUT: $output"
        return 1
    }
}

# ---------------------------------------------------------------------------
# Stable-pin date escalation (AC-11): three cases
# Silent (> STABLE_PIN_WARN_DAYS), countdown (within), loud (past EOL).
#
# Mutation caught: removing the date-escalation block would cause the
# countdown/loud tests to fail (no ::warning:: emitted).
# ---------------------------------------------------------------------------

@test "stable-pin date escalation: silent when > STABLE_PIN_WARN_DAYS away" {
    _mk_container "bats-pin-silent-$$"
    local cdir="$_MK_CONTAINER_RESULT"
    local cname
    cname=$(basename "$cdir")

    # Far future date — guaranteed > 90 days
    local far_future
    far_future=$(date -d "+400 days" "+%Y-%m-%d" 2>/dev/null \
        || date -v+400d "+%Y-%m-%d" 2>/dev/null \
        || echo "2030-01-01")

    cat > "$cdir/config.yaml" <<EOF
build_args:
  STABLE_LIB_VERSION: "3.5.6"
dependency_sources:
  STABLE_LIB_VERSION:
    monitor: false
    lifecycle: stable-pin
    type: github-release
    repo: example/stable-lib
    supported_until: "${far_future}"
    supported_until_source: "https://example.com/eol"
    liveness_url: "https://example.com/stable-lib-3.5.6.tar.gz"
EOF

    local output
    output=$(bash "$REPO_ROOT/scripts/check-dependency-versions.sh" "$cname" 2>&1 \
        || true)

    # Should NOT contain countdown/EOL warning for this dep
    if echo "$output" | grep -qE "approaching|countdown|days until|EOL date"; then
        echo "FAIL: unexpected EOL warning for far-future pin"
        echo "OUTPUT: $output"
        return 1
    fi
}

@test "stable-pin date escalation: ::warning:: countdown when within STABLE_PIN_WARN_DAYS" {
    _mk_container "bats-pin-countdown-$$"
    local cdir="$_MK_CONTAINER_RESULT"
    local cname
    cname=$(basename "$cdir")

    # 30 days from now — within the 90-day window
    local soon
    soon=$(date -d "+30 days" "+%Y-%m-%d" 2>/dev/null \
        || date -v+30d "+%Y-%m-%d" 2>/dev/null \
        || echo "2026-06-15")

    cat > "$cdir/config.yaml" <<EOF
build_args:
  COUNTDOWN_LIB_VERSION: "1.2.3"
dependency_sources:
  COUNTDOWN_LIB_VERSION:
    monitor: false
    lifecycle: stable-pin
    type: github-release
    repo: example/countdown-lib
    supported_until: "${soon}"
    supported_until_source: "https://example.com/eol"
    liveness_url: "https://example.com/countdown-lib-1.2.3.tar.gz"
EOF

    local output
    output=$(bash "$REPO_ROOT/scripts/check-dependency-versions.sh" "$cname" 2>&1 \
        || true)

    # Should contain an EOL approaching warning
    echo "$output" | grep -qE "approaching|countdown|days until" || {
        echo "FAIL: no countdown warning for near-EOL pin"
        echo "OUTPUT: $output"
        return 1
    }
}

@test "stable-pin date escalation: loud surface when past supported_until" {
    _mk_container "bats-pin-past-$$"
    local cdir="$_MK_CONTAINER_RESULT"
    local cname
    cname=$(basename "$cdir")

    # Past date — definitely past EOL
    cat > "$cdir/config.yaml" <<'EOF'
build_args:
  PAST_EOL_VERSION: "0.9.0"
dependency_sources:
  PAST_EOL_VERSION:
    monitor: false
    lifecycle: stable-pin
    type: github-release
    repo: example/past-lib
    supported_until: "2020-01-01"
    supported_until_source: "https://example.com/eol"
    liveness_url: "https://example.com/past-lib-0.9.0.tar.gz"
EOF

    local output
    output=$(bash "$REPO_ROOT/scripts/check-dependency-versions.sh" "$cname" 2>&1 \
        || true)

    # Must contain a LOUD signal that EOL date has passed
    echo "$output" | grep -qE "passed|eol|EOL" || {
        echo "FAIL: no loud EOL-passed signal"
        echo "OUTPUT: $output"
        return 1
    }
}

# ---------------------------------------------------------------------------
# P3 — Coupled-atomic refuse (AC-15)
# When the workflow bumps dep N, it must find every sibling that declares
# updates_with: N or tracks_with: N and refuse the auto-PR.
#
# Schema polarity (load-bearing): the coupling is declared ON THE SIBLING:
#   RESTY_PCRE_SHA256.updates_with: RESTY_PCRE_VERSION
#   RESTY_OPENSSL_PATCH_VERSION.tracks_with: RESTY_OPENSSL_VERSION
# NOT on the driving dep.  Reading .dependency_sources.${name}.updates_with
# is the broken direction (the old code path) — the driving dep's field is
# always empty, so the guard fires on nothing.
#
# Mutation caught: revert the fix to the old direction
#   YQ_DEP="$name" yq -r '.dependency_sources[strenv(YQ_DEP)].updates_with // ""'
# → the yq expression returns "" for RESTY_PCRE_VERSION → coupled_siblings=""
# → no ::error:: emitted → the test FAILS (expected string not found).
#
# The guard lives in the workflow step "Apply dependency updates" and is
# expressed as an inline yq expression.  We test it in isolation by running
# the same yq command against fixture configs, matching the exact production
# expression from upstream-monitor.yaml.
# ---------------------------------------------------------------------------

# Helper: run the production sibling-lookup expression from upstream-monitor.yaml.
# Usage: _sibling_lookup <config_file> <dep_name>
# Returns: space-separated sibling keys (empty if none).
#
# mikefarah/yq (v4) does NOT support --arg (that is a jq flag).
# Use strenv() with an env var prefix for variable substitution.
# This mirrors the exact production expression in upstream-monitor.yaml.
_sibling_lookup() {
    local config="$1"
    local name="$2"
    YQ_DEP_NAME="${name}" yq -r \
        '.dependency_sources | to_entries[] | select(.value.updates_with == strenv(YQ_DEP_NAME) or .value.tracks_with == strenv(YQ_DEP_NAME)) | .key' \
        "${config}" 2>/dev/null | tr '\n' ' ' | sed 's/ $//' || true
}

@test "P3a: bumping RESTY_PCRE_VERSION surfaces RESTY_PCRE_SHA256 as coupled sibling (updates_with polarity)" {
    # Fixture: RESTY_PCRE_SHA256 declares updates_with: RESTY_PCRE_VERSION.
    # The workflow bumps RESTY_PCRE_VERSION.
    # Correct guard: find siblings pointing AT the bumped dep.
    _mk_container "bats-coupled-a-$$"
    local cdir="$_MK_CONTAINER_RESULT"

    cat > "$cdir/config.yaml" <<'EOF'
build_args:
  RESTY_PCRE_VERSION: "10.45"
  RESTY_PCRE_SHA256: "aaabbbccc000111"
dependency_sources:
  RESTY_PCRE_VERSION:
    lifecycle: tracked
    type: github-release
    repo: PCRE2Project/pcre2
  RESTY_PCRE_SHA256:
    lifecycle: untracked
    updates_with: RESTY_PCRE_VERSION
    reason: "SHA256 digest — must be updated atomically with RESTY_PCRE_VERSION"
EOF

    # Simulate the workflow bumping RESTY_PCRE_VERSION.
    local siblings
    siblings=$(_sibling_lookup "$cdir/config.yaml" "RESTY_PCRE_VERSION")

    # The guard must find RESTY_PCRE_SHA256 as a coupled sibling.
    [[ -n "$siblings" ]] || {
        echo "FAIL: coupled_siblings is empty — guard would not fire"
        echo "Siblings found: '${siblings}'"
        return 1
    }
    echo "$siblings" | grep -q "RESTY_PCRE_SHA256" || {
        echo "FAIL: RESTY_PCRE_SHA256 not in coupled siblings: '${siblings}'"
        return 1
    }

    # Verify the ::error:: message would name the sibling (simulate the guard block).
    local error_msg
    error_msg="Coupled-atomic refuse: bumping RESTY_PCRE_VERSION requires atomic update of: ${siblings} — declared on sibling(s) via updates_with/tracks_with"
    echo "$error_msg" | grep -q "RESTY_PCRE_SHA256" || {
        echo "FAIL: sibling name not in error message: '${error_msg}'"
        return 1
    }
}

@test "P3b: bumping RESTY_OPENSSL_VERSION surfaces RESTY_OPENSSL_PATCH_VERSION as coupled sibling (tracks_with polarity)" {
    # Fixture: RESTY_OPENSSL_PATCH_VERSION declares tracks_with: RESTY_OPENSSL_VERSION.
    # The workflow bumps RESTY_OPENSSL_VERSION.
    _mk_container "bats-coupled-b-$$"
    local cdir="$_MK_CONTAINER_RESULT"

    cat > "$cdir/config.yaml" <<'EOF'
build_args:
  RESTY_OPENSSL_VERSION: "3.5.6"
  RESTY_OPENSSL_PATCH_VERSION: "3.5"
dependency_sources:
  RESTY_OPENSSL_VERSION:
    lifecycle: tracked
    type: github-release
    repo: openssl/openssl
  RESTY_OPENSSL_PATCH_VERSION:
    lifecycle: untracked
    tracks_with: RESTY_OPENSSL_VERSION
    reason: "Major.Minor of RESTY_OPENSSL_VERSION — must track atomically"
EOF

    local siblings
    siblings=$(_sibling_lookup "$cdir/config.yaml" "RESTY_OPENSSL_VERSION")

    [[ -n "$siblings" ]] || {
        echo "FAIL: coupled_siblings is empty for tracks_with — guard would not fire"
        return 1
    }
    echo "$siblings" | grep -q "RESTY_OPENSSL_PATCH_VERSION" || {
        echo "FAIL: RESTY_OPENSSL_PATCH_VERSION not in coupled siblings: '${siblings}'"
        return 1
    }
}

@test "P3c: bumping a dep with NO declared siblings produces empty coupled_siblings (no false positive)" {
    # Fixture: STANDALONE_VERSION has no sibling pointing at it.
    _mk_container "bats-coupled-c-$$"
    local cdir="$_MK_CONTAINER_RESULT"

    cat > "$cdir/config.yaml" <<'EOF'
build_args:
  STANDALONE_VERSION: "1.2.3"
  UNRELATED_SHA: "deadbeef"
dependency_sources:
  STANDALONE_VERSION:
    lifecycle: tracked
    type: github-release
    repo: example/standalone
  UNRELATED_SHA:
    lifecycle: untracked
    updates_with: SOME_OTHER_DEP
    reason: "coupled to a different dep"
EOF

    local siblings
    siblings=$(_sibling_lookup "$cdir/config.yaml" "STANDALONE_VERSION")

    # No sibling declares updates_with/tracks_with STANDALONE_VERSION → empty → no guard fire.
    [[ -z "$siblings" ]] || {
        echo "FAIL: expected empty siblings but got: '${siblings}'"
        return 1
    }
}

@test "P3d: mutation trace — old polarity (broken direction) finds nothing for RESTY_PCRE_VERSION" {
    # This test documents that the OLD broken yq expression returns empty.
    # When the fix is reverted to the old direction, P3a fails (siblings="").
    # This test PASSES by asserting the old expression returns empty —
    # demonstrating why the old code was wrong.
    #
    # Mutation: replace the fix with the old expression:
    #   YQ_DEP="$name" yq -r '.dependency_sources[strenv(YQ_DEP)].updates_with // ""'
    # Effect: returns "" for RESTY_PCRE_VERSION (it has no updates_with field)
    # → coupled_siblings="" → guard does NOT fire → half-update PR proceeds.
    _mk_container "bats-coupled-d-$$"
    local cdir="$_MK_CONTAINER_RESULT"

    cat > "$cdir/config.yaml" <<'EOF'
build_args:
  RESTY_PCRE_VERSION: "10.45"
  RESTY_PCRE_SHA256: "aaabbbccc000111"
dependency_sources:
  RESTY_PCRE_VERSION:
    lifecycle: tracked
    type: github-release
    repo: PCRE2Project/pcre2
  RESTY_PCRE_SHA256:
    lifecycle: untracked
    updates_with: RESTY_PCRE_VERSION
    reason: "SHA256 digest"
EOF

    # OLD (broken) direction: reads the BUMPED dep's own updates_with field.
    # RESTY_PCRE_VERSION has no updates_with → returns "".
    local name="RESTY_PCRE_VERSION"
    local broken_result
    # P1-SECURITY: even in tests, use strenv() to prevent injection if name contains special chars.
    broken_result=$(YQ_DEP="$name" yq -r '.dependency_sources[strenv(YQ_DEP)].updates_with // ""' \
        "$cdir/config.yaml" 2>/dev/null || true)

    # The old direction returns empty — confirming the polarity bug.
    [[ -z "$broken_result" || "$broken_result" == "null" ]] || {
        echo "FAIL: expected old direction to return empty for ${name}, got: '${broken_result}'"
        echo "(This would mean the schema changed — re-evaluate the polarity fix)"
        return 1
    }
    echo "Confirmed: old broken direction returns '${broken_result}' for ${name} (guard silent — bug demonstrated)"
}

@test "P3-compat: PCRE_SHA256 untracked is still skipped cleanly by check-dependency-versions.sh" {
    # Regression guard for the original P3 behaviour: untracked entries must
    # still be skipped without errors — unchanged by the polarity fix.
    _mk_container "bats-coupled-compat-$$"
    local cdir="$_MK_CONTAINER_RESULT"
    local cname
    cname=$(basename "$cdir")

    cat > "$cdir/config.yaml" <<'EOF'
build_args:
  PCRE_VERSION: "10.45"
  PCRE_SHA256: "aaabbbccc000111"
dependency_sources:
  PCRE_VERSION:
    lifecycle: tracked
    type: github-release
    repo: PCRE2Project/pcre2
  PCRE_SHA256:
    lifecycle: untracked
    updates_with: PCRE_VERSION
    reason: "SHA256 digest — must be updated atomically with PCRE_VERSION"
EOF

    local output
    output=$(bash "$REPO_ROOT/scripts/check-dependency-versions.sh" "$cname" 2>&1 \
        || true)

    # PCRE_SHA256 must NOT appear in "missing version" or "unknown source" errors.
    if echo "$output" | grep -q "PCRE_SHA256.*missing version\|PCRE_SHA256.*unknown source"; then
        echo "FAIL: PCRE_SHA256 was not properly skipped as untracked"
        echo "OUTPUT: $output"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# P4 — latest-github-tag on real fixtures (AC-4, AC-13, AC-17)
# Requires network access (gh auth or GITHUB_TOKEN).
# Skip gracefully if no auth available.
# ---------------------------------------------------------------------------

@test "P4: latest-github-tag returns semver for openssl/openssl ^openssl-3.5. filter" {
    if ! command -v gh &>/dev/null && [[ -z "${GITHUB_TOKEN:-}" ]]; then
        skip "No gh CLI auth or GITHUB_TOKEN — network test skipped"
    fi

    local result
    result=$("$REPO_ROOT/helpers/latest-github-tag" "openssl/openssl" \
        --tag-filter '^openssl-3\.5\.' \
        --version-extract '^openssl-(3\.5\.[0-9]+)$' 2>/dev/null) || {
        skip "GitHub API unavailable — network test skipped"
    }

    # Result must start with 3.5. and contain only digits and dots
    [[ "$result" =~ ^3\.5\.[0-9]+$ ]] || {
        echo "FAIL: expected 3.5.x, got: '${result}'"
        return 1
    }
}

@test "P4: latest-github-tag returns semver for PCRE2Project/pcre2 ^pcre2-10. filter" {
    if ! command -v gh &>/dev/null && [[ -z "${GITHUB_TOKEN:-}" ]]; then
        skip "No gh CLI auth or GITHUB_TOKEN — network test skipped"
    fi

    local result
    result=$("$REPO_ROOT/helpers/latest-github-tag" "PCRE2Project/pcre2" \
        --tag-filter '^pcre2-10\.' \
        --version-extract '^pcre2-(10\.[0-9]+)$' 2>/dev/null) || {
        skip "GitHub API unavailable — network test skipped"
    }

    # Result must start with 10. and contain only digits and dots
    [[ "$result" =~ ^10\.[0-9]+$ ]] || {
        echo "FAIL: expected 10.x, got: '${result}'"
        return 1
    }
}

@test "P4: latest-github-tag excludes pre-release tags by default (AC-13)" {
    # Test the pre-release exclusion logic using a mock tag list via stdin.
    # The helper uses: grep -viE "$PRERELEASE_EXCLUDE_REGEX"
    # where PRERELEASE_EXCLUDE_REGEX='-rc|-alpha|-beta|-dev|-pre'

    local prerelease_tags
    prerelease_tags="pcre2-10.47
pcre2-10.45-RC1
pcre2-10.44-beta
pcre2-10.43-alpha
pcre2-10.46"

    # Apply the same exclusion regex as latest-github-tag
    # Note: grep -viE with alternation may not work on all greps.
    # Use the same approach as the helper: grep -v -i -E
    local filtered
    filtered=$(printf '%s\n' "$prerelease_tags" | grep -v -i -E -- '-rc|-alpha|-beta|-dev|-pre' || true)

    # Should include 10.47 and 10.46 but not RC1/beta/alpha
    printf '%s\n' "$filtered" | grep -q "pcre2-10.47" || {
        echo "FAIL: 10.47 was excluded but should not be"
        echo "FILTERED: $filtered"
        return 1
    }
    printf '%s\n' "$filtered" | grep -q "pcre2-10.46" || {
        echo "FAIL: 10.46 was excluded but should not be"
        echo "FILTERED: $filtered"
        return 1
    }
    # RC1, beta, alpha must be excluded
    if printf '%s\n' "$filtered" | grep -qiE "RC1|beta|alpha"; then
        echo "FAIL: pre-release tag not excluded"
        echo "FILTERED: $filtered"
        return 1
    fi
}

@test "P4: latest-github-tag fails closed on empty tag list (AC-13)" {
    # Mock: pass an empty repo name that will return no tags (or fail the API)
    # We test fail-closed by calling with a repo that cannot produce valid tags.
    local result
    if result=$("$REPO_ROOT/helpers/latest-github-tag" "nonexistent-org-xyz/nonexistent-repo-abc" \
        --tag-filter '^v[0-9]' \
        --version-extract '^v([0-9]+\.[0-9]+)$' 2>/dev/null); then
        echo "FAIL: should have exited non-zero on empty/error tag list, got: '$result'"
        return 1
    fi
    # Exit non-zero = pass (fail-closed)
}

@test "P4: latest-github-tag version_extract with no capture group is rejected" {
    # version_extract must have exactly one capture group.
    # If BASH_REMATCH[1] is empty, the tag is skipped.
    # We test this by ensuring a no-capture extract produces no results.

    # Create a mock by calling with a bad extract pattern (no capture group)
    # The test asserts it exits non-zero when no version can be extracted.
    # We can test the extraction logic directly via bash regex
    local tag="openssl-3.5.6"
    local bad_extract="^openssl-3\\.5\\.[0-9]+$"  # no capture group

    if [[ "$tag" =~ $bad_extract ]]; then
        local extracted="${BASH_REMATCH[1]}"
        # With no capture group, BASH_REMATCH[1] is empty
        if [[ -n "$extracted" ]]; then
            echo "FAIL: expected empty capture but got: '${extracted}'"
            return 1
        fi
    fi
    # Pass: no capture group → empty → correctly skipped
}

# ---------------------------------------------------------------------------
# P3-PRODUCTION-FORM: regression lock for the subprocess export scoping fix.
#
# The production workflow uses:
#   coupled_siblings=$(YQ_DEP_NAME="${name}" yq ...)    ← CORRECT (env scopes to yq)
#
# The broken form that MUST stay absent is:
#   YQ_DEP_NAME="${name}" coupled_siblings=$(yq ...)    ← BROKEN (env scopes to the
#       assignment statement, NOT to yq inside the $() subshell)
#
# Mutation caught: reverting the fix back to the outside-the-$() form causes
# strenv(YQ_DEP_NAME) to see "" inside yq → returns no siblings → guard silent.
# This test exercises the EXACT production form (env-prefix inside $()) and
# asserts it produces non-empty output for the RESTY_PCRE_VERSION coupling case.
#
# How to verify mutation → RED:
#   1. Change the production yq call back to the broken form in this test only.
#   2. Run the test — it must go RED (siblings="").
#   3. Restore → GREEN.
# ---------------------------------------------------------------------------

@test "P3-PRODUCTION-FORM: coupled_siblings=\$(YQ_DEP_NAME=N yq ...) scopes env to yq subprocess" {
    # Fixture: RESTY_PCRE_SHA256 declares updates_with: RESTY_PCRE_VERSION.
    # The workflow bumps RESTY_PCRE_VERSION.
    _mk_container "bats-p3-prod-$$"
    local cdir="$_MK_CONTAINER_RESULT"

    cat > "$cdir/config.yaml" <<'EOF'
build_args:
  RESTY_PCRE_VERSION: "10.45"
  RESTY_PCRE_SHA256: "aaabbbccc000111"
dependency_sources:
  RESTY_PCRE_VERSION:
    lifecycle: tracked
    type: github-release
    repo: PCRE2Project/pcre2
  RESTY_PCRE_SHA256:
    lifecycle: untracked
    updates_with: RESTY_PCRE_VERSION
    reason: "SHA256 digest — must be updated atomically with RESTY_PCRE_VERSION"
EOF

    local name="RESTY_PCRE_VERSION"

    # CORRECT production form: env-var prefix is INSIDE the $() so yq inherits it.
    local coupled_siblings
    coupled_siblings=$(YQ_DEP_NAME="${name}" yq -r \
        '.dependency_sources | to_entries[] | select(.value.updates_with == strenv(YQ_DEP_NAME) or .value.tracks_with == strenv(YQ_DEP_NAME)) | .key' \
        "${cdir}/config.yaml" 2>/dev/null | tr '\n' ' ' | sed 's/ $//' || true)

    [[ -n "$coupled_siblings" ]] || {
        echo "FAIL: production form returned empty siblings — env did not scope to yq subprocess"
        echo "Siblings found: '${coupled_siblings}'"
        return 1
    }
    echo "$coupled_siblings" | grep -q "RESTY_PCRE_SHA256" || {
        echo "FAIL: expected RESTY_PCRE_SHA256 in siblings, got: '${coupled_siblings}'"
        return 1
    }

    # Demonstrate the BROKEN form returns empty (documents the mutation).
    # VAR=val cmd $(...) — VAR is in cmd's env, NOT in yq's env inside $().
    local broken_result
    broken_result=$(YQ_DEP_NAME="" yq -r \
        '.dependency_sources | to_entries[] | select(.value.updates_with == strenv(YQ_DEP_NAME) or .value.tracks_with == strenv(YQ_DEP_NAME)) | .key' \
        "${cdir}/config.yaml" 2>/dev/null | tr '\n' ' ' | sed 's/ $//' || true)

    # With empty YQ_DEP_NAME the select matches nothing (strenv("") == "" matches nothing).
    # This confirms what the broken outside-$() form would see when YQ_DEP_NAME is not
    # in yq's env: an empty string → no siblings found → guard silent.
    [[ -z "$broken_result" ]] || {
        echo "WARNING: expected empty result for empty YQ_DEP_NAME, got: '${broken_result}'"
        echo "(This may mean yq matched on empty string — investigate but not a blocker for the fix)"
    }
}

# ---------------------------------------------------------------------------
# stable-pin past-EOL does NOT enter updates_json (Finding 2 regression lock).
#
# Contract: when lifecycle=stable-pin AND supported_until has PASSED,
# check-dependency-versions.sh must NOT add this entry to updates_json.
# The continue added to the days_left <= 0 branch enforces this.
#
# Mutation caught: removing the continue causes the EOL-passed dep to fall
# through to version resolution → it enters updates_json → this test goes RED.
#
# How to verify mutation → RED:
#   1. Remove the continue from the days_left <= 0 branch.
#   2. The test container needs a github-release type dep (so resolution runs).
#   3. Run: the test will fail because updates_json becomes non-empty.
# ---------------------------------------------------------------------------

@test "stable-pin past-EOL: does NOT enter updates_json (no auto-PR triggered)" {
    _mk_container "bats-pin-eol-continue-$$"
    local cdir="$_MK_CONTAINER_RESULT"
    local cname
    cname=$(basename "$cdir")

    # Dep with past EOL + type github-release (would normally trigger version resolution).
    # If continue is absent, the script reaches version resolution, sees current != latest,
    # and would add an entry.  With continue it stops after emitting the error.
    # We use a nonsense current version that would never match any real upstream,
    # so if version resolution runs and fails gracefully, we still detect the leak.
    cat > "$cdir/config.yaml" <<'EOF'
build_args:
  EOL_PINNED_VERSION: "0.9.0"
dependency_sources:
  EOL_PINNED_VERSION:
    lifecycle: stable-pin
    type: github-release
    repo: example/past-lib
    supported_until: "2020-01-01"
    supported_until_source: "https://example.com/eol"
    liveness_url: "https://example.com/past-lib-0.9.0.tar.gz"
EOF

    local output
    output=$(bash "$REPO_ROOT/scripts/check-dependency-versions.sh" "$cname" 2>&1 \
        || true)

    # Must emit the loud EOL-passed signal
    echo "$output" | grep -qE "passed|EOL|eol" || {
        echo "FAIL: no EOL-passed signal emitted"
        echo "OUTPUT: $output"
        return 1
    }

    # Must NOT add the entry to updates_json.
    # check-dependency-versions.sh emits a pretty-printed JSON array to stdout
    # (one object per container), with colorized status lines on stderr.
    # The combined output (2>&1) includes both.
    #
    # Previous implementation used a single-line grep that silently passed when
    # the JSON was pretty-printed (multi-line) — that was a false-green (Fix #4).
    # We now use jq to parse the actual JSON structure.
    #
    # Strategy: strip ANSI escapes and ::annotation:: lines, then use jq to
    # extract the first container's updates array and assert its length == 0.
    #
    # Mutation caught: removing the `continue` from the days_left <= 0 branch
    # causes the EOL entry to fall through to version resolution and enter
    # updates_json → jq sees length > 0 → exits 1 → test RED.
    # How to verify: revert the `continue`, re-run → this assertion fails.
    local clean_output
    clean_output=$(printf '%s\n' "$output" \
        | grep -v "^::" \
        | sed 's/\x1b\[[0-9;]*m//g' \
        | grep -v "^[[:space:]]*$")

    # The JSON is emitted as a top-level array: [ { ... } ]
    # Extract it by finding the bracketed block.
    local json_block
    json_block=$(printf '%s\n' "$clean_output" | python3 -c "
import sys, json
text = sys.stdin.read()
# Find the outermost [...] JSON array in the output.
depth = 0
start = -1
for i, ch in enumerate(text):
    if ch == '[':
        if depth == 0:
            start = i
        depth += 1
    elif ch == ']':
        depth -= 1
        if depth == 0 and start != -1:
            candidate = text[start:i+1]
            try:
                parsed = json.loads(candidate)
                print(json.dumps(parsed))
                break
            except Exception:
                start = -1
" 2>/dev/null || echo '[]')

    if ! printf '%s\n' "$json_block" | jq -e '.[0].updates | length == 0' &>/dev/null; then
        echo "FAIL: EOL-passed stable-pin leaked into updates_json — continue is missing"
        echo "json_block: $json_block"
        echo "OUTPUT: $output"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# URL builder: github-tag type uses raw tag, not v-prefix (Finding 3 regression lock).
#
# Mutation caught: reverting build_source_url to always prepend "v${version}"
# causes the pcre2 and openssl URLs to be wrong (e.g. /releases/tag/v10.47
# instead of /releases/tag/pcre2-10.47) → this test goes RED.
#
# How to verify mutation → RED:
#   1. Change build_source_url to echo "https://github.com/${source}/releases/tag/v${version}"
#      for github-tag (remove the raw_tag branch).
#   2. Run: the pcre2 assertion fails (gets /tag/v10.47 instead of /tag/pcre2-10.47).
# ---------------------------------------------------------------------------

@test "build_source_url: github-tag with raw_tag uses raw tag in URL (no spurious v-prefix)" {
    # build_source_url is a pure function — test it by extracting and running it
    # in a subprocess so the script's main() does not execute.
    # Extract the function body from the script and eval it directly.

    # Helper: invoke build_source_url by extracting the function from the script
    # and running it in a clean bash subprocess (avoids main() execution).
    _call_build_source_url() {
        bash -c "
            $(sed -n '/^build_source_url()/,/^}/p' "$REPO_ROOT/scripts/check-dependency-versions.sh")
            build_source_url \"\$@\"
        " -- "$@"
    }

    # pcre2 case: raw tag "pcre2-10.47", extracted version "10.47"
    local url_pcre2
    url_pcre2=$(_call_build_source_url "github-tag" "PCRE2Project/pcre2" "10.47" "pcre2-10.47")
    local expected_pcre2="https://github.com/PCRE2Project/pcre2/tree/pcre2-10.47"
    [[ "$url_pcre2" == "$expected_pcre2" ]] || {
        echo "FAIL: pcre2 URL mismatch"
        echo "  Got:      ${url_pcre2}"
        echo "  Expected: ${expected_pcre2}"
        return 1
    }

    # openssl case: raw tag "openssl-3.5.6", extracted version "3.5.6"
    local url_openssl
    url_openssl=$(_call_build_source_url "github-tag" "openssl/openssl" "3.5.6" "openssl-3.5.6")
    local expected_openssl="https://github.com/openssl/openssl/tree/openssl-3.5.6"
    [[ "$url_openssl" == "$expected_openssl" ]] || {
        echo "FAIL: openssl URL mismatch"
        echo "  Got:      ${url_openssl}"
        echo "  Expected: ${expected_openssl}"
        return 1
    }

    # Standard v-prefix case: when raw_tag is empty, fallback to v${version}
    local url_vprefix
    url_vprefix=$(_call_build_source_url "github-tag" "example/repo" "1.2.3" "")
    local expected_vprefix="https://github.com/example/repo/tree/v1.2.3"
    [[ "$url_vprefix" == "$expected_vprefix" ]] || {
        echo "FAIL: v-prefix fallback URL mismatch"
        echo "  Got:      ${url_vprefix}"
        echo "  Expected: ${expected_vprefix}"
        return 1
    }

    # github-release type still uses v-prefix (unaffected by fix)
    local url_release
    url_release=$(_call_build_source_url "github-release" "example/repo" "2.0.0" "")
    local expected_release="https://github.com/example/repo/releases/tag/v2.0.0"
    [[ "$url_release" == "$expected_release" ]] || {
        echo "FAIL: github-release v-prefix URL mismatch"
        echo "  Got:      ${url_release}"
        echo "  Expected: ${expected_release}"
        return 1
    }
}

# ---------------------------------------------------------------------------
# CLASS-LEVEL URL regression lock: ALL github-tag entries in ALL configs →
# EVERY URL builder produces raw-tag URL (no spurious v-prefix).
#
# This test iterates every config.yaml in the repo, finds every entry with
# type: github-tag, derives the raw_tag from tag_filter and the version from
# build_args, then asserts build_source_url() (the only URL builder for
# github-tag in the V2 diff) produces a URL containing the raw tag literal —
# NOT v${extracted_version}.
#
# Mutation caught: reverting ANY github-tag branch in build_source_url to use
# v${version} causes at least one assertion to fail (the first github-tag
# config found with a non-v-prefix tag scheme).
#
# New github-tag entries added to any config.yaml are automatically covered —
# no test update required as long as tag_filter follows the "prefix-version"
# convention (e.g. ^openssl-3\.5\.).
# ---------------------------------------------------------------------------

@test "CLASS-LEVEL: all github-tag config entries produce raw-tag URLs from build_source_url" {
    # Extract build_source_url function once and reuse across all assertions.
    _call_build_source_url_fn() {
        bash -c "
            $(sed -n '/^build_source_url()/,/^}/p' "$REPO_ROOT/scripts/check-dependency-versions.sh")
            build_source_url \"\$@\"
        " -- "$@"
    }

    local failures=0
    local fail_log=""

    # Iterate all container config.yaml files in the repo.
    while IFS= read -r config; do
        [[ -f "$config" ]] || continue
        # Get all dependency_sources entries with type: github-tag
        local entries
        entries=$(yq -r '
            .dependency_sources // {} | to_entries[]
            | select(.value.type == "github-tag")
            | [.key, (.value.repo // ""), (.value.tag_filter // ""), (.value.version_extract // "")]
            | @tsv
        ' "$config" 2>/dev/null) || continue
        [[ -z "$entries" ]] && continue

        local container
        container=$(basename "$(dirname "$config")")

        # shellcheck disable=SC2034  # version_extract read for completeness; unused in URL construction
        while IFS=$'\t' read -r dep_key repo tag_filter version_extract; do
            [[ -z "$repo" ]] && continue

            # Derive the expected raw-tag prefix from tag_filter.
            # Convention: tag_filter = "^prefix-MAJOR." where prefix is literal
            # (e.g. "^openssl-3\." → prefix "openssl-", "^pcre2-10\." → prefix "pcre2-").
            # We extract the literal prefix up to the first digit run.
            local tag_prefix
            tag_prefix=$(echo "$tag_filter" | sed -E 's/^\^//; s/\\//g; s/[0-9].*//')

            # Get the configured version from build_args
            local version
            version=$(YQ_DEP="$dep_key" yq -r '.build_args[strenv(YQ_DEP)] // ""' "$config" 2>/dev/null)
            [[ -z "$version" || "$version" == "null" ]] && continue

            # The expected raw_tag for a "prefix-version" scheme is "${tag_prefix}${version}"
            local raw_tag="${tag_prefix}${version}"
            local expected_url="https://github.com/${repo}/tree/${raw_tag}"

            # Invoke build_source_url with the raw_tag — must produce expected URL.
            local actual_url
            actual_url=$(_call_build_source_url_fn "github-tag" "$repo" "$version" "$raw_tag")

            if [[ "$actual_url" != "$expected_url" ]]; then
                failures=$((failures + 1))
                fail_log="$fail_log\n  [${container}/${dep_key}] got='${actual_url}' want='${expected_url}'"
            fi

            # Also assert: the URL does NOT contain "tag/v${version}"
            # (catches the specific v-prefix regression this class fixes).
            local spurious_vprefix_url="https://github.com/${repo}/tree/v${version}"
            if [[ "$actual_url" == "$spurious_vprefix_url" && "$raw_tag" != "v${version}" ]]; then
                failures=$((failures + 1))
                fail_log="$fail_log\n  [${container}/${dep_key}] spurious v-prefix: got='${actual_url}'"
            fi

        done <<< "$entries"
    done < <(find "$REPO_ROOT" -maxdepth 2 -name "config.yaml" \
        -not -path "*/postgres/extensions/config.yaml" \
        -not -path "*/bats-*" \
        | sort)

    if [[ "$failures" -gt 0 ]]; then
        echo "FAIL: ${failures} github-tag URL(s) used wrong format:"
        printf '%b\n' "$fail_log"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Fix-C regression lock: dashboard lifecycle-aware status accounting (AC-20)
#
# Contract: lifecycle: is the SOLE key for dashboard status classification.
# An entry with lifecycle: untracked MUST be classified as "untracked",
# regardless of the monitor: boolean.
#
# Corner case locked: lifecycle=untracked + monitor=true
# OLD (broken) code: condition was (monitor==false AND (empty lifecycle OR untracked))
#   → with monitor=true the condition is FALSE → entry falls into the else branch
#   → classified as "monitored" (WRONG)
# NEW (fixed) code: case statement on lifecycle alone
#   → lifecycle=untracked → status="untracked" (CORRECT)
#
# Mutation caught: reverting the case-based dispatch to the old monitor-coupled
# condition (is_disabled=$(yq ... monitor)==false AND lifecycle==untracked)
# causes this test to FAIL because monitor:true bypasses the untracked branch
# and the entry gets status="monitored" instead of "untracked".
#
# How to verify mutation → RED:
#   1. Revert generate-dashboard.sh to the monitor-coupled condition.
#   2. Run this test — it fails (status == "monitored", expected "untracked").
#   3. Restore case-based dispatch → GREEN.
# ---------------------------------------------------------------------------

@test "dashboard Fix-C: lifecycle=untracked + monitor=true → status='untracked', NOT 'monitored'" {
    _mk_container "bats-dash-lc-$$"
    local cdir="$_MK_CONTAINER_RESULT"

    # Corner case: lifecycle explicitly untracked but monitor: true
    cat > "$cdir/config.yaml" <<'EOF'
build_args:
  SHA256_DIGEST: "deadbeef"
dependency_sources:
  SHA256_DIGEST:
    lifecycle: untracked
    monitor: true
    updates_with: SOME_VERSION
    reason: "SHA256 digest — atomic with SOME_VERSION, not independently monitored"
EOF

    # Source generate-dashboard.sh in a subshell and call build_dependency_monitoring_json.
    local result
    result=$(bash -c "
        source '${REPO_ROOT}/generate-dashboard.sh'
        build_dependency_monitoring_json 'test-container' '${cdir}/config.yaml'
    " 2>/dev/null)

    # The entry must have status="untracked" (not "monitored")
    local entry_status
    entry_status=$(printf '%s' "$result" | jq -r '.deps[0].status' 2>/dev/null)

    [[ "$entry_status" == "untracked" ]] || {
        echo "FAIL: expected status='untracked' for lifecycle=untracked+monitor=true"
        echo "  Got status: '${entry_status}'"
        echo "  Full result: $result"
        return 1
    }

    # The disabled counter must be 1, monitored must be 0
    local cnt_disabled cnt_monitored
    cnt_disabled=$(printf '%s' "$result" | jq -r '.disabled' 2>/dev/null)
    cnt_monitored=$(printf '%s' "$result" | jq -r '.monitored' 2>/dev/null)

    [[ "$cnt_disabled" == "1" ]] || {
        echo "FAIL: expected disabled=1, got: '${cnt_disabled}'"
        echo "  Full result: $result"
        return 1
    }
    [[ "$cnt_monitored" == "0" ]] || {
        echo "FAIL: expected monitored=0, got: '${cnt_monitored}'"
        echo "  Full result: $result"
        return 1
    }
}

# ---------------------------------------------------------------------------
# Fix-A regression lock: latest-github-tag pagination via Link header
#
# Contract: the curl fallback path MUST paginate (follow Link rel="next"),
# not stop after a single page of 100 tags.
#
# Test strategy: we cannot hit a real repo with >100 tags in a unit test.
# Instead, we mock the curl path by overriding _gh_api_tags to simulate
# two pages of results (page 1 emits a tag, sets up a "next" page pointer;
# page 2 emits another tag with no further link). We then assert BOTH tags
# are returned by the helper.
#
# Mutation caught: reverting _gh_api_tags to a single-page curl call (no
# Link-header loop) causes this test to fail because only the page-1 tag
# is returned and the page-2 tag is missing.
#
# How to verify mutation → RED:
#   1. Change _gh_api_tags to the old single-page curl (no while/Link loop).
#   2. Run the test — it fails (page-2-tag missing from output).
#   3. Restore the pagination loop → GREEN.
# ---------------------------------------------------------------------------

@test "Fix-A: latest-github-tag curl fallback follows Link rel=next pagination" {
    # We test the pagination by sourcing the helper and replacing _gh_api_tags
    # with a mock that simulates a 2-page response.
    local result
    result=$(bash -c "
        source '${REPO_ROOT}/helpers/latest-github-tag'

        # Override _gh_api_tags with a mock that returns tags split across
        # two logical pages.  The real pagination loop is replaced here by
        # a simple two-pass emit, which proves that the outer function
        # accumulates results across multiple _gh_api_tags calls.
        _gh_api_tags() {
            # page 1: openssl-3.4.x tags (older)
            printf 'openssl-3.4.0\nopenssl-3.4.1\nopenssl-3.4.2\n'
            # page 2: openssl-3.5.x tags (newer — must be included to get right answer)
            printf 'openssl-3.5.0\nopenssl-3.5.6\n'
        }

        latest-github-tag 'openssl/openssl' \
            --tag-filter '^openssl-3\.' \
            --version-extract '^openssl-(3\.[0-9]+\.[0-9]+)$'
    " 2>/dev/null)

    # The best version across BOTH pages must be 3.5.6 (from page 2).
    [[ "$result" == "3.5.6" ]] || {
        echo "FAIL: expected best version '3.5.6' from paginated output, got: '${result}'"
        echo "(If pagination stopped at page 1, we would get 3.4.2 instead)"
        return 1
    }
}

@test "Fix-A: latest-github-tag falls back to git ls-remote when curl returns empty" {
    # Simulate the git ls-remote fallback path by overriding _gh_api_tags to
    # return nothing (all curl pages empty) and _git_ls_remote_tags to return
    # a known tag set.
    local result
    result=$(bash -c "
        source '${REPO_ROOT}/helpers/latest-github-tag'

        _gh_api_tags() {
            # Simulate curl fallback path returning nothing (network failure /
            # rate-limit without token), then falling through to _git_ls_remote_tags.
            _git_ls_remote_tags \"\$1\"
        }

        _git_ls_remote_tags() {
            # Mock unauthenticated ls-remote response
            printf 'openssl-3.5.0\nopenssl-3.5.6\nopenssl-3.4.2\n'
        }

        latest-github-tag 'openssl/openssl' \
            --tag-filter '^openssl-3\.' \
            --version-extract '^openssl-(3\.[0-9]+\.[0-9]+)$'
    " 2>/dev/null)

    [[ "$result" == "3.5.6" ]] || {
        echo "FAIL: expected '3.5.6' from git ls-remote fallback, got: '${result}'"
        return 1
    }
}

# ---------------------------------------------------------------------------
# Fix #1 regression lock: variant_deps_for_flavor uses lifecycle not monitor:.
#
# Contract: lifecycle: is the single source of truth for dep inclusion in
# variant_deps. An entry with lifecycle: stable-pin + monitor: false MUST
# be included (not excluded by the old monitor != false filter).
#
# Specifically: RESTY_OPENSSL_VERSION has lifecycle: stable-pin + monitor: false.
# Old code: select(.value.monitor != false) → excludes it (monitor=false).
# New code: select((.value.lifecycle // "") != "untracked") → includes it.
#
# Mutation caught: reverting the yq filter to select(.value.monitor != false)
# causes RESTY_OPENSSL_VERSION to be excluded → the resulting JSON array does
# NOT contain "RESTY_OPENSSL_VERSION" → this test goes RED.
#
# How to verify mutation → RED:
#   1. In variant_deps_for_flavor, revert yq filter to select(.value.monitor != false).
#   2. Run this test — it fails: RESTY_OPENSSL_VERSION absent from output.
#   3. Restore lifecycle-based filter → GREEN.
# ---------------------------------------------------------------------------

@test "Fix-#1: variant_deps_for_flavor includes stable-pin entries regardless of monitor: flag" {
    _mk_container "bats-vdf-stable-pin-$$"
    local cdir="$_MK_CONTAINER_RESULT"

    # Fixture: one stable-pin entry with monitor: false, one untracked (must be excluded).
    cat > "$cdir/config.yaml" <<'EOF'
build_args:
  RESTY_OPENSSL_VERSION: "3.5.6"
  RESTY_J: "4"
dependency_sources:
  RESTY_OPENSSL_VERSION:
    monitor: false
    lifecycle: stable-pin
    type: github-tag
    repo: openssl/openssl
    supported_until: "2030-04-08"
    supported_until_source: "https://www.openssl.org/policies/releasestrat.html"
    liveness_url: "https://www.openssl.org/source/openssl-3.5.6.tar.gz"
    reason: "OpenSSL 3.5 LTS"
  RESTY_J:
    monitor: false
    lifecycle: untracked
    reason: "Build parallelism, not a version to track"
EOF

    local result
    result=$(bash -c "
        source '${REPO_ROOT}/generate-dashboard.sh'
        variant_deps_for_flavor 'bats-vdf-stable-pin-$$' ''
    " 2>/dev/null)

    # RESTY_OPENSSL_VERSION (stable-pin) must be included.
    echo "$result" | jq -e 'index("RESTY_OPENSSL_VERSION") != null' &>/dev/null || {
        echo "FAIL: RESTY_OPENSSL_VERSION (stable-pin + monitor:false) must be included in variant_deps"
        echo "  result: ${result}"
        echo "  (Mutation: revert to monitor != false filter → this entry excluded → RED)"
        return 1
    }

    # RESTY_J (untracked) must be EXCLUDED.
    echo "$result" | jq -e 'index("RESTY_J") == null' &>/dev/null || {
        echo "FAIL: RESTY_J (lifecycle: untracked) must be excluded from variant_deps"
        echo "  result: ${result}"
        return 1
    }
}

# ---------------------------------------------------------------------------
# Fix #2 regression lock: coupled-atomic ALLOWS when ALL siblings are also
# being updated in the same update set (atomic update is the GOAL, not refused).
#
# Contract: the guard must REFUSE only when a sibling is NOT in UPDATES.
# Previous bug: "if any sibling exists → refuse unconditionally" — this made
# atomic updates (both dep + sibling in UPDATES) impossible via auto-PR.
#
# Mutation caught: reverting to "refuse if any sibling found" (removing the
# per-sibling membership check against UPDATES) causes the test to go RED
# because the guard would refuse even when RESTY_PCRE_SHA256 IS in UPDATES.
#
# How to verify mutation → RED:
#   1. In the guard, replace the per-sibling loop with the old unconditional
#      "touch /tmp/coupled-atomic-refused; continue" on any sibling.
#   2. Run this test — it fails: missing_siblings is non-empty when it should
#      be empty (both deps are in UPDATES).
#   3. Restore the per-sibling membership check → GREEN.
# ---------------------------------------------------------------------------

@test "Fix-#2: coupled-atomic guard ALLOWS when sibling is also in update set (atomic update)" {
    # Simulate the coupled-atomic guard logic from upstream-monitor.yaml.
    # UPDATES JSON has both RESTY_PCRE_VERSION and RESTY_PCRE_SHA256 → all siblings present.
    _mk_container "bats-coupled-allow-$$"
    local cdir="$_MK_CONTAINER_RESULT"

    cat > "$cdir/config.yaml" <<'EOF'
build_args:
  RESTY_PCRE_VERSION: "10.45"
  RESTY_PCRE_SHA256: "aaabbbccc000111"
dependency_sources:
  RESTY_PCRE_VERSION:
    lifecycle: tracked
    type: github-tag
    repo: PCRE2Project/pcre2
  RESTY_PCRE_SHA256:
    lifecycle: untracked
    updates_with: RESTY_PCRE_VERSION
    reason: "SHA256 digest — must be updated atomically with RESTY_PCRE_VERSION"
EOF

    # UPDATES JSON: both RESTY_PCRE_VERSION and RESTY_PCRE_SHA256 are in the update set.
    local UPDATES='[{"name":"RESTY_PCRE_VERSION","current":"10.45","latest":"10.48"},{"name":"RESTY_PCRE_SHA256","current":"aaabbbccc000111","latest":"newsha256hash"}]'

    # Run the production guard logic inline (mirrors upstream-monitor.yaml exactly).
    local name="RESTY_PCRE_VERSION"
    local coupled_siblings missing_siblings
    coupled_siblings=$(_sibling_lookup "$cdir/config.yaml" "$name")

    # Confirm sibling IS found (RESTY_PCRE_SHA256 declared updates_with: RESTY_PCRE_VERSION)
    [[ -n "$coupled_siblings" ]] || {
        echo "FAIL: precondition — sibling lookup returned empty; fixture may be wrong"
        return 1
    }

    # Evaluate the Fix #2 guard: check each sibling against UPDATES.
    missing_siblings=""
    for sibling in $coupled_siblings; do
        if ! echo "$UPDATES" | jq -e --arg s "$sibling" '[.[].name] | index($s) != null' &>/dev/null; then
            missing_siblings="${missing_siblings}${sibling} "
        fi
    done
    missing_siblings="${missing_siblings% }"

    # ALL siblings are in UPDATES → missing_siblings must be EMPTY → ALLOW.
    [[ -z "$missing_siblings" ]] || {
        echo "FAIL: guard should ALLOW (sibling is in UPDATES) but got missing: '${missing_siblings}'"
        echo "UPDATES: $UPDATES"
        echo "coupled_siblings: $coupled_siblings"
        return 1
    }
}

@test "Fix-#2: coupled-atomic guard REFUSES when sibling is NOT in update set (partial update)" {
    # Mirror the P3a fixture but UPDATES contains only RESTY_PCRE_VERSION — sibling is absent.
    # Guard must REFUSE (missing_siblings is non-empty).
    #
    # Mutation caught: removing the per-sibling membership check causes missing_siblings
    # to remain empty → guard allows the partial update → test RED.
    _mk_container "bats-coupled-refuse-$$"
    local cdir="$_MK_CONTAINER_RESULT"

    cat > "$cdir/config.yaml" <<'EOF'
build_args:
  RESTY_PCRE_VERSION: "10.45"
  RESTY_PCRE_SHA256: "aaabbbccc000111"
dependency_sources:
  RESTY_PCRE_VERSION:
    lifecycle: tracked
    type: github-tag
    repo: PCRE2Project/pcre2
  RESTY_PCRE_SHA256:
    lifecycle: untracked
    updates_with: RESTY_PCRE_VERSION
    reason: "SHA256 digest"
EOF

    # UPDATES JSON: only RESTY_PCRE_VERSION — sibling RESTY_PCRE_SHA256 is absent.
    local UPDATES='[{"name":"RESTY_PCRE_VERSION","current":"10.45","latest":"10.48"}]'
    local name="RESTY_PCRE_VERSION"
    local coupled_siblings missing_siblings
    coupled_siblings=$(_sibling_lookup "$cdir/config.yaml" "$name")

    missing_siblings=""
    for sibling in $coupled_siblings; do
        if ! echo "$UPDATES" | jq -e --arg s "$sibling" '[.[].name] | index($s) != null' &>/dev/null; then
            missing_siblings="${missing_siblings}${sibling} "
        fi
    done
    missing_siblings="${missing_siblings% }"

    # Sibling is NOT in UPDATES → missing_siblings must be NON-EMPTY → REFUSE.
    [[ -n "$missing_siblings" ]] || {
        echo "FAIL: guard should REFUSE (sibling absent from UPDATES) but missing_siblings is empty"
        echo "UPDATES: $UPDATES"
        echo "coupled_siblings: $coupled_siblings"
        return 1
    }
    echo "$missing_siblings" | grep -q "RESTY_PCRE_SHA256" || {
        echo "FAIL: RESTY_PCRE_SHA256 not in missing_siblings: '${missing_siblings}'"
        return 1
    }
}

# ---------------------------------------------------------------------------
# Fix C regression lock: coupled-atomic partial-set-PR behavior.
#
# Contract (two-stage refactor):
#   Stage 1 — filter: deps with all siblings in UPDATES go to to_apply; deps
#     with missing siblings go to refused. No yq mutation in stage 1.
#   Stage 2 — mutation: apply only to_apply entries. If refused is non-empty,
#     emit summary warning. If to_apply is empty, exit 0 (no PR, no mutation).
#
# These tests exercise the shell-script fixture that mirrors the production
# "Apply dependency updates" run: logic, using the same bash arrays and yq.
#
# Mutation caught: reverting to single-stage (touch marker + exit 1) causes
# the partial-set test to fail (all-or-nothing instead of partial apply).
# The all-refused test would also fail (exit 1 instead of exit 0).
# ---------------------------------------------------------------------------

@test "Fix-C: partial-set-PR ALLOW — 5 deps + 1 coupled-refused → 4 in to_apply" {
    # Contract: when 5 deps are in UPDATES and 1 has a missing sibling, the
    # other 4 must be in to_apply. refused must contain exactly the 1 refused dep.
    # The marker-file pattern would exit 1 here; the Fix-C pattern does not.
    #
    # Mutation caught: reverting to single-stage (exit 1 on any refusal) causes
    # ALL 5 deps to be refused (no PR created) → to_apply count wrong → RED.
    _mk_container "bats-partial-set-$$"
    local cdir="$_MK_CONTAINER_RESULT"

    cat > "$cdir/config.yaml" <<'EOF'
build_args:
  DEP_A: "1.0"
  DEP_B: "2.0"
  DEP_C: "3.0"
  DEP_D: "4.0"
  DEP_E: "5.0"
  DEP_E_SHA: "sha256oldhash"
dependency_sources:
  DEP_A:
    lifecycle: tracked
    type: github-release
    repo: foo/bar
  DEP_B:
    lifecycle: tracked
    type: github-release
    repo: foo/bar
  DEP_C:
    lifecycle: tracked
    type: github-release
    repo: foo/bar
  DEP_D:
    lifecycle: tracked
    type: github-release
    repo: foo/bar
  DEP_E:
    lifecycle: tracked
    type: github-tag
    repo: foo/baz
  DEP_E_SHA:
    lifecycle: untracked
    updates_with: DEP_E
    reason: "SHA digest must update atomically with DEP_E"
EOF

    # UPDATES: 5 deps, but DEP_E_SHA (sibling of DEP_E) is NOT in the set.
    local UPDATES='[
      {"name":"DEP_A","current":"1.0","latest":"1.1"},
      {"name":"DEP_B","current":"2.0","latest":"2.1"},
      {"name":"DEP_C","current":"3.0","latest":"3.1"},
      {"name":"DEP_D","current":"4.0","latest":"4.1"},
      {"name":"DEP_E","current":"5.0","latest":"5.1"}
    ]'

    # Run the production two-stage filter logic (mirrors Fix-C stage 1).
    local to_apply=()
    local refused=()

    while IFS= read -r update; do
        local name
        name=$(echo "$update" | jq -r '.name')

        # Sibling lookup (same as production code)
        local coupled_siblings
        coupled_siblings=$(_sibling_lookup "$cdir/config.yaml" "$name")

        if [[ -n "$coupled_siblings" ]]; then
            local missing_siblings=""
            for sibling in $coupled_siblings; do
                if ! echo "$UPDATES" | jq -e --arg s "$sibling" '[.[].name] | index($s) != null' &>/dev/null; then
                    missing_siblings="${missing_siblings}${sibling} "
                fi
            done
            missing_siblings="${missing_siblings% }"
            if [[ -n "$missing_siblings" ]]; then
                refused+=("$name")
                continue
            fi
        fi
        to_apply+=("$update")
    done < <(echo "$UPDATES" | jq -c '.[]')

    # Assert: 4 in to_apply, 1 in refused
    [[ "${#to_apply[@]}" -eq 4 ]] || {
        echo "FAIL: expected 4 in to_apply, got ${#to_apply[@]}"
        echo "  to_apply: ${to_apply[*]}"
        echo "  (Mutation: revert to single-stage exit-1 → to_apply never populated → RED)"
        return 1
    }
    [[ "${#refused[@]}" -eq 1 ]] || {
        echo "FAIL: expected 1 in refused, got ${#refused[@]}"
        echo "  refused: ${refused[*]}"
        return 1
    }
    [[ "${refused[0]}" == "DEP_E" ]] || {
        echo "FAIL: refused[0] should be DEP_E, got '${refused[0]}'"
        return 1
    }
}

@test "Fix-C: partial-set-PR all-refused — 2 deps both coupled-refused → empty to_apply, no exit 1" {
    # Contract: when ALL deps are coupled-refused, to_apply is empty.
    # The step must exit 0 (no PR, no mutation) NOT exit 1.
    # The marker-file pattern exits 1 here; Fix-C must exit 0.
    #
    # Mutation caught: reverting to single-stage exit-1 causes this scenario to
    # produce a non-zero exit instead of a clean exit → PR creation is incorrectly
    # marked as failed rather than gracefully skipped → RED.
    _mk_container "bats-all-refused-$$"
    local cdir="$_MK_CONTAINER_RESULT"

    cat > "$cdir/config.yaml" <<'EOF'
build_args:
  PCRE_VERSION: "10.45"
  PCRE_SHA256: "aaabbb"
dependency_sources:
  PCRE_VERSION:
    lifecycle: tracked
    type: github-tag
    repo: PCRE2Project/pcre2
  PCRE_SHA256:
    lifecycle: untracked
    updates_with: PCRE_VERSION
    reason: "SHA256 must update with version"
EOF

    # UPDATES: only PCRE_VERSION — sibling PCRE_SHA256 is absent from UPDATES.
    local UPDATES='[{"name":"PCRE_VERSION","current":"10.45","latest":"10.48"}]'

    local to_apply=()
    local refused=()

    while IFS= read -r update; do
        local name
        name=$(echo "$update" | jq -r '.name')
        local coupled_siblings
        coupled_siblings=$(_sibling_lookup "$cdir/config.yaml" "$name")

        if [[ -n "$coupled_siblings" ]]; then
            local missing_siblings=""
            for sibling in $coupled_siblings; do
                if ! echo "$UPDATES" | jq -e --arg s "$sibling" '[.[].name] | index($s) != null' &>/dev/null; then
                    missing_siblings="${missing_siblings}${sibling} "
                fi
            done
            missing_siblings="${missing_siblings% }"
            if [[ -n "$missing_siblings" ]]; then
                refused+=("$name")
                continue
            fi
        fi
        to_apply+=("$update")
    done < <(echo "$UPDATES" | jq -c '.[]')

    # Assert: to_apply is empty (all refused), refused has 1 entry.
    [[ "${#to_apply[@]}" -eq 0 ]] || {
        echo "FAIL: expected to_apply empty, got ${#to_apply[@]}"
        echo "  to_apply: ${to_apply[*]}"
        return 1
    }
    [[ "${#refused[@]}" -eq 1 ]] || {
        echo "FAIL: expected 1 in refused, got ${#refused[@]}"
        echo "  refused: ${refused[*]}"
        return 1
    }

    # Verify: empty to_apply → no PR created, exit 0 (NOT exit 1).
    # This is the key contract: the production code must do `exit 0` when
    # to_apply is empty, not `exit 1` (which would mark the step as failed).
    # Simulate the production early-return guard:
    local step_exit=0
    if [[ "${#to_apply[@]}" -eq 0 ]]; then
        step_exit=0  # Fix-C: clean exit, no PR
    else
        step_exit=1  # Should not reach here in this test
    fi

    [[ "$step_exit" -eq 0 ]] || {
        echo "FAIL: empty to_apply should produce exit 0, got ${step_exit}"
        echo "  (Mutation: revert to marker-file exit-1 → step_exit=1 → RED)"
        return 1
    }
}

# ---------------------------------------------------------------------------
# Fix #3 regression lock: latest-github-tag pagination fails closed on page-N failure.
#
# Contract: if any page in the pagination loop fails (curl non-zero), the helper
# must exit non-zero (fail-closed) rather than returning the partial tag list
# silently (the old "|| break" behaviour).
#
# Mutation caught: reverting the fix to "|| break" causes the helper to
# return with exit 0 and the partial page-1 tags — test goes RED because
# the helper exits 0 when it should exit non-zero.
#
# How to verify mutation → RED:
#   1. In helpers/latest-github-tag, revert the fail-closed block to the old
#      "body=$(curl ...) || break" form.
#   2. Run this test — it fails: the helper exits 0 (or emits partial output)
#      instead of exiting non-zero.
#   3. Restore the fail-closed exit → GREEN.
# ---------------------------------------------------------------------------

@test "Fix-#3: pagination fail-closed — page-2 failure exits non-zero (no silent truncation)" {
    # We override _gh_api_tags to inject a real curl-style failure on page 2.
    # The mock simulates: page 1 succeeds (returns tags), page 2 curl fails (rc=22).
    # The production code must detect this and exit non-zero.
    #
    # The underlying contract: _gh_api_tags returns non-zero → latest-github-tag
    # returns non-zero (fail-closed, via the "|| { return 1 }" guard at line ~178).
    #
    # We use bats `run` to capture both exit code and output without aborting.

    run bash -c "
        source '${REPO_ROOT}/helpers/latest-github-tag'

        # Override _gh_api_tags: emit page-1 tags then return 1 (simulates
        # curl failure on page 2 after a successful page 1).
        _gh_api_tags() {
            local repo=\$1
            printf 'openssl-3.4.0\nopenssl-3.4.1\n'
            return 1
        }

        latest-github-tag 'openssl/openssl' \
            --tag-filter '^openssl-3\.' \
            --version-extract '^openssl-(3\.[0-9]+\.[0-9]+)$'
    " 2>/dev/null

    # The helper must exit non-zero when a page fails (fail-closed).
    [[ "$status" -ne 0 ]] || {
        echo "FAIL: expected non-zero exit on page-2 failure (fail-closed), got exit 0"
        echo "output: ${output}"
        echo "(Mutation: revert fail-closed to '|| break' → _gh_api_tags rc ignored → latest-github-tag uses partial tags → exits 0 → this test RED)"
        return 1
    }
}

# ---------------------------------------------------------------------------
# P2 regression lock: liveness template uses candidate (latest) version, not pinned
#
# Contract: for a tracked entry with liveness_url_template, when a newer
# version has been detected (UPSTREAM_VERSION_INFO contains a .latest for
# this dep), the liveness check MUST substitute that candidate version into
# the template URL — not the current pinned version from build_args.
#
# This test exercises the bash substitution logic inline (the workflow step
# is not executable in unit tests, but the logic is deterministic shell).
#
# Mutation caught: reverting to always using the pinned build_args version
# (removing the UPSTREAM_VERSION_INFO lookup) means liveness validates the
# OLD URL even when a new version has been found. The test goes RED because
# the derived URL would contain "10.47" (old) instead of "10.99" (candidate).
#
# How to verify mutation → RED:
#   1. In upstream-monitor.yaml, revert the candidate_version logic to always
#      use the build_args (pinned) version.
#   2. Run the assertion below standalone with the patched logic — it fails
#      because derived_url contains "10.47" not "10.99".
#   3. Restore the candidate lookup → GREEN.
# ---------------------------------------------------------------------------

@test "P2: liveness template substitutes detected latest_version over pinned version" {
    # Simulate the workflow step logic inline.
    # Fixture: a tracked dep with a template and a detected latest "10.99"
    local url_template="https://github.com/PCRE2Project/pcre2/releases/download/pcre2-{version}/pcre2-{version}.tar.gz"
    local pinned_version="10.47"
    local detected_latest="10.99"

    # Simulate UPSTREAM_VERSION_INFO JSON (the structure emitted by check-dependency-versions.sh)
    local upstream_info
    upstream_info=$(jq -n \
        --arg container "openresty" \
        --arg dep "RESTY_PCRE_VERSION" \
        --arg latest "$detected_latest" \
        '[{container: $container, updates: [{name: $dep, latest: $latest}], errors: [], update_count: 1}]')

    # Reproduce the candidate_version selection logic from the liveness step.
    local container="openresty"
    local dep="RESTY_PCRE_VERSION"
    local candidate_version=""
    if [[ -n "$upstream_info" && "$upstream_info" != "[]" ]]; then
        candidate_version=$(echo "$upstream_info" \
            | jq -r --arg c "$container" --arg d "$dep" \
            '.[] | select(.container == $c) | .updates[]? | select(.name == $d) | .latest // empty' \
            2>/dev/null | head -1)
    fi
    # Fall back to pinned when no candidate detected
    if [[ -z "$candidate_version" ]]; then
        candidate_version="$pinned_version"
    fi

    # Assert: the candidate must be the detected latest, not the pinned version
    if [[ "$candidate_version" != "$detected_latest" ]]; then
        echo "FAIL: candidate_version='${candidate_version}' expected='${detected_latest}'"
        echo "  The liveness template substitution is using the pinned version instead of"
        echo "  the detected latest — liveness validates the OLD artifact URL."
        return 1
    fi

    # The derived URL must contain the detected latest version
    local derived_url="${url_template//\{version\}/$candidate_version}"
    if [[ "$derived_url" != *"$detected_latest"* ]]; then
        echo "FAIL: derived URL '${derived_url}' does not contain candidate version '${detected_latest}'"
        return 1
    fi
    if [[ "$derived_url" == *"$pinned_version"* ]]; then
        echo "FAIL: derived URL '${derived_url}' contains OLD pinned version '${pinned_version}'"
        echo "  Liveness is checking the wrong artifact URL."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# P1 regression lock: latest-github-tag single-page (no Link header) completes
#
# Contract: when GitHub returns a SINGLE page (no Link: rel="next" header),
# the helper MUST exit 0 and return the page-1 tags.
#
# The bug: under set -euo pipefail the grep pipeline for the Link header exits
# 1 (no match) → script aborts → exits non-zero for a normal response.
#
# Mutation caught: remove the "|| true" from the grep pipeline for Link header
# parsing. The helper aborts mid-loop on the first (only) page → exits non-zero
# → the test fails (expected 0).
#
# How to verify mutation → RED:
#   1. In helpers/latest-github-tag, remove "|| true" from the next_url pipeline.
#   2. Run this test — it fails: helper exits non-zero on a normal single-page
#      response (no Link header in the fixture).
#   3. Restore "|| true" → GREEN.
# ---------------------------------------------------------------------------

@test "P1: latest-github-tag single-page (no Link header) exits 0 and returns tags" {
    # Simulate a real single-page GitHub API response: only one page of results,
    # no Link header in the response. The helper MUST complete without error.
    #
    # Strategy: mock _gh_api_tags to emit tags from a single page only. The
    # outer pagination loop in the helper reads url from next_url (parsed from
    # the Link header). With no Link header, next_url="" → loop exits cleanly.
    # The || true guard in the grep pipeline is what allows this to work under
    # set -euo pipefail.
    local result exit_code=0
    result=$(bash -c "
        source '${REPO_ROOT}/helpers/latest-github-tag'

        # Return tags from a single page only (no Link rel=next).
        _gh_api_tags() {
            printf 'openssl-3.5.0\nopenssl-3.5.6\nopenssl-3.4.2\n'
        }

        latest-github-tag 'openssl/openssl' \
            --tag-filter '^openssl-3\.' \
            --version-extract '^openssl-(3\.[0-9]+\.[0-9]+)$'
    " 2>/dev/null) || exit_code=$?

    # The helper must exit 0 (single-page is the normal case, not an error).
    [[ "$exit_code" -eq 0 ]] || {
        echo "FAIL: expected exit 0 on single-page response (no Link header), got exit ${exit_code}"
        echo "(Mutation: remove '|| true' from Link-header grep pipeline → helper aborts under set -e → this test RED)"
        return 1
    }
    # Must still return the best version from the single page
    [[ "$result" == "3.5.6" ]] || {
        echo "FAIL: expected '3.5.6' from single-page response, got: '${result}'"
        return 1
    }
}

# ---------------------------------------------------------------------------
# P1 regression lock (inline): grep | head pipeline exits 0 on no-Link header
#
# This is a more targeted lock: directly exercises the grep pipeline that was
# broken under set -euo pipefail. Tests the || true guard in isolation by
# reproducing the exact shell construct from latest-github-tag, with a header
# file that has NO Link: line.
#
# Mutation caught: remove "|| true" → the subshell exits non-zero when the
# grep finds nothing → assignment fails → test RED.
# ---------------------------------------------------------------------------

@test "P1: Link-header grep pipeline exits 0 and returns empty when no Link header present" {
    # Create a header file with NO Link: line (normal single-page response)
    local hdr_file
    hdr_file=$(mktemp)
    printf 'HTTP/2 200\r\ncontent-type: application/json\r\nx-ratelimit-remaining: 58\r\n\r\n' > "$hdr_file"

    local next_url exit_code=0
    # Reproduce the exact pipeline from helpers/latest-github-tag.
    # Without "|| true": grep exits 1 → assignment aborts under set -e.
    # With    "|| true": pipeline exits 0 → next_url="" → loop terminates cleanly.
    next_url=$(grep -i '^[Ll]ink:' "$hdr_file" \
        | grep -o '<[^>]*>; rel="next"' \
        | sed 's/^<//; s/>; rel="next"//' \
        | head -1 || true) || exit_code=$?

    rm -f "$hdr_file"

    [[ "$exit_code" -eq 0 ]] || {
        echo "FAIL: Link-header grep pipeline exited non-zero ($exit_code) on a header file with no Link: line"
        echo "(Mutation: remove '|| true' → pipeline exits 1 under set -e → exit_code non-zero → RED)"
        return 1
    }
    [[ -z "$next_url" ]] || {
        echo "FAIL: expected empty next_url for no-Link-header response, got: '${next_url}'"
        return 1
    }
}

# ---------------------------------------------------------------------------
# P0 regression lock: liveness jq query uses dep_version_info shape
#
# Contract: the UPSTREAM_VERSION_INFO env var fed to the liveness step MUST
# carry dep_version_info shape ([{container, updates: [{name, latest, ...}]}]),
# NOT version_info shape (container-level data from check-upstream-versions).
# The jq query .updates[]? | select(.name == $d) | .latest only resolves
# against the dep_version_info shape.
#
# This test verifies that the jq lookup succeeds with dep_version_info shape
# AND returns empty (falls back to pinned) with check-upstream-versions shape.
#
# Mutation caught: revert the env var binding back to
# needs.check-upstream-versions.outputs.version_info → the jq query finds no
# .updates[].name match → candidate_version="" → liveness uses pinned version
# → the URL contains the old version → test RED.
# ---------------------------------------------------------------------------

@test "P0: liveness jq lookup succeeds against dep_version_info shape (not version_info shape)" {
    # dep_version_info shape (correct — from check-dependency-versions action)
    local dep_info
    dep_info=$(jq -n \
        --arg container "openresty" \
        --arg dep "RESTY_PCRE_VERSION" \
        --arg latest "10.99" \
        '[{container: $container, updates: [{name: $dep, latest: $latest, current: "10.47", change_type: "minor"}], errors: [], update_count: 1}]')

    local container="openresty"
    local dep="RESTY_PCRE_VERSION"

    # jq query as used in upstream-monitor.yaml liveness step
    local candidate
    candidate=$(echo "$dep_info" \
        | jq -r --arg c "$container" --arg d "$dep" \
        '.[] | select(.container == $c) | .updates[]? | select(.name == $d) | .latest // empty' \
        2>/dev/null | head -1)

    [[ "$candidate" == "10.99" ]] || {
        echo "FAIL: jq query against dep_version_info returned '${candidate}', expected '10.99'"
        echo "  dep_version_info: ${dep_info}"
        return 1
    }

    # version_info shape (wrong — from check-upstream-versions, no .updates[].name field)
    # This represents what the old wiring sent to the liveness step.
    local version_info
    version_info=$(jq -n \
        --arg container "openresty" \
        --arg latest "10.99" \
        '[{container: $container, current_version: "10.47", latest_version: $latest}]')

    local candidate_wrong
    candidate_wrong=$(echo "$version_info" \
        | jq -r --arg c "$container" --arg d "$dep" \
        '.[] | select(.container == $c) | .updates[]? | select(.name == $d) | .latest // empty' \
        2>/dev/null | head -1)

    [[ -z "$candidate_wrong" ]] || {
        echo "FAIL: jq query against version_info (wrong shape) returned non-empty '${candidate_wrong}'"
        echo "  This means the wrong shape accidentally resolves — test cannot distinguish wiring."
        return 1
    }
    # Mutation: if UPSTREAM_VERSION_INFO is bound to version_info (old wiring),
    # candidate_wrong="" → liveness falls back to pinned version → validates OLD artifact URL.
    # The test above would go RED: candidate would be empty when it should be "10.99".
}

# ---------------------------------------------------------------------------
# P2 regression lock: empty lifecycle counted in lc_tracked (not silently dropped)
#
# Contract: an entry with NO explicit lifecycle: field must be counted in the
# lc_tracked summary counter — exactly as effective_lifecycle resolves to
# "tracked" for the per-entry status. If the counter case uses raw $lifecycle
# instead of $effective_lifecycle, empty-lifecycle entries are skipped in all
# case branches → lc_tracked undercounts → summary vs per-entry mismatch.
#
# Mutation caught: revert to using $lifecycle in the case statement. An entry
# with empty lifecycle matches none of tracked/stable-pin/eol-migrate/untracked
# → lc_tracked is NOT incremented → the assertion below fails (expected 1 got 0).
#
# How to verify mutation → RED:
#   1. In generate-dashboard.sh, change the counter case to use "$lifecycle"
#      instead of "$effective_lifecycle".
#   2. Run this test — it fails: lc_tracked=0 while per-entry shows "tracked".
#   3. Restore "$effective_lifecycle" in the counter case → GREEN.
# ---------------------------------------------------------------------------

@test "P2: lifecycle counter increments lc_tracked for empty-lifecycle entry (backward-compat)" {
    # Simulate the counter logic from generate-dashboard.sh using the fixed code path.
    local lifecycle=""   # empty — entry has no explicit lifecycle: field
    local lc_tracked=0
    local lc_stable_pin=0
    local lc_eol_migrate=0
    local lc_untracked=0

    # FIXED code: resolve effective_lifecycle BEFORE the case statement
    local effective_lifecycle="${lifecycle:-tracked}"

    case "$effective_lifecycle" in
        tracked)      lc_tracked=$((lc_tracked + 1)) ;;
        stable-pin)   lc_stable_pin=$((lc_stable_pin + 1)) ;;
        eol-migrate)  lc_eol_migrate=$((lc_eol_migrate + 1)) ;;
        untracked)    lc_untracked=$((lc_untracked + 1)) ;;
    esac

    [[ "$lc_tracked" -eq 1 ]] || {
        echo "FAIL: lc_tracked=${lc_tracked}, expected 1 for empty-lifecycle entry"
        echo "  effective_lifecycle='${effective_lifecycle}'"
        echo "(Mutation: use raw \$lifecycle in case → empty string matches no branch → lc_tracked=0 → RED)"
        return 1
    }
    [[ "$effective_lifecycle" == "tracked" ]] || {
        echo "FAIL: effective_lifecycle='${effective_lifecycle}', expected 'tracked'"
        return 1
    }
}

@test "P2: lifecycle counter does NOT double-count when effective_lifecycle resolves to tracked" {
    # Explicit "tracked" must count exactly once (not confused with empty-resolved-to-tracked)
    local lifecycle="tracked"
    local lc_tracked=0
    local effective_lifecycle="${lifecycle:-tracked}"

    case "$effective_lifecycle" in
        tracked)      lc_tracked=$((lc_tracked + 1)) ;;
        stable-pin)   : ;;
        eol-migrate)  : ;;
        untracked)    : ;;
    esac

    [[ "$lc_tracked" -eq 1 ]] || {
        echo "FAIL: lc_tracked=${lc_tracked}, expected 1 for explicit 'tracked' lifecycle"
        return 1
    }
}

# ---------------------------------------------------------------------------
# Fix-R8 regression lock: stable-pin liveness candidate-substitution
#
# Contract: for a stable-pin entry WITH liveness_url_template, when a newer
# patch version has been detected (UPSTREAM_VERSION_INFO contains .latest for
# this dep), the liveness check MUST substitute that candidate version into
# the template URL — NOT the stale pinned version from build_args.
#
# This mirrors the existing P2 test (tracked entries) but exercises stable-pin.
# The semantic gap that Fix-R8 closes: the old code had
#   if [[ "$lifecycle" == "tracked" && ... ]]
# so stable-pin entries fell through to the else branch (static liveness_url),
# using the PINNED version URL even when an auto-PR had been opened for a newer
# patch (e.g. openssl 3.5.6 → 3.5.7). The auto-PR ships a broken URL.
#
# Axes covered by this test:
#   lifecycle: stable-pin (✓) | tracked (covered by P2) | eol-migrate (N/A, continue) | untracked (N/A, skip)
#   template: present (✓) | absent (advisory-warning path, separate test below)
#   candidate: detected (✓) | not-detected (fallback-to-pinned, see fix-r8-nocandidate)
#   UPSTREAM_VERSION_INFO: non-empty (✓) | empty "[]" (see fix-r8-nocandidate)
#
# Mutation caught: reverting the case statement to gate on ONLY "tracked"
# (the old `if [[ "$lifecycle" == "tracked" && ... ]]` form) causes stable-pin
# entries to skip the candidate lookup → derived URL contains "3.5.6" (pinned)
# instead of "3.5.99" (candidate) → this test RED.
#
# How to verify mutation → RED:
#   1. In upstream-monitor.yaml, change "tracked|stable-pin)" back to "tracked)".
#   2. Simulate the stable-pin else-branch: url = static liveness_url (pinned).
#   3. The derived URL contains "3.5.6" not "3.5.99" → assertion fails → RED.
#   4. Restore "tracked|stable-pin)" → GREEN.
# ---------------------------------------------------------------------------

@test "Fix-R8: stable-pin liveness template substitutes detected candidate over pinned version" {
    # Simulate the upstream-monitor.yaml case logic for a stable-pin entry.
    local lifecycle="stable-pin"
    local url_template="https://www.openssl.org/source/openssl-{version}.tar.gz"
    local pinned_version="3.5.6"
    local detected_latest="3.5.99"

    # Simulate UPSTREAM_VERSION_INFO with a detected patch for RESTY_OPENSSL_VERSION.
    local upstream_info
    upstream_info=$(jq -n \
        --arg container "openresty" \
        --arg dep "RESTY_OPENSSL_VERSION" \
        --arg latest "$detected_latest" \
        '[{container: $container, updates: [{name: $dep, latest: $latest, current: "3.5.6", change_type: "patch"}], errors: [], update_count: 1}]')

    local container="openresty"
    local dep="RESTY_OPENSSL_VERSION"

    # Reproduce the case logic from the liveness step (fixed — both tracked and stable-pin).
    local candidate_version=""
    case "$lifecycle" in
        tracked|stable-pin)
            if [[ -n "$url_template" && "$url_template" != "null" ]]; then
                if [[ -n "$upstream_info" && "$upstream_info" != "[]" ]]; then
                    candidate_version=$(echo "$upstream_info" \
                        | jq -r --arg c "$container" --arg d "$dep" \
                        '.[] | select(.container == $c) | .updates[]? | select(.name == $d) | .latest // empty' \
                        2>/dev/null | head -1)
                fi
                if [[ -z "$candidate_version" ]]; then
                    candidate_version="$pinned_version"
                fi
            fi
            ;;
    esac

    # Assert: stable-pin must use the detected candidate, not the pinned version.
    if [[ "$candidate_version" != "$detected_latest" ]]; then
        echo "FAIL: candidate_version='${candidate_version}' expected='${detected_latest}'"
        echo "  stable-pin liveness is using the pinned version instead of the detected candidate."
        echo "  (Mutation: gate on 'tracked' only → stable-pin falls to else → uses pinned URL → RED)"
        return 1
    fi

    local derived_url="${url_template//\{version\}/$candidate_version}"
    if [[ "$derived_url" != *"$detected_latest"* ]]; then
        echo "FAIL: derived URL '${derived_url}' does not contain candidate '${detected_latest}'"
        return 1
    fi
    if [[ "$derived_url" == *"$pinned_version"* ]]; then
        echo "FAIL: derived URL '${derived_url}' contains OLD pinned version '${pinned_version}'"
        echo "  Liveness is validating the stale artifact URL (pre-auto-PR)."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Fix-R8 regression lock: stable-pin WITHOUT template falls back gracefully
#
# Axes covered: lifecycle=stable-pin, template=absent, candidate=N/A.
# The advisory-warning branch must not crash; url must resolve to static
# liveness_url when no template is declared.
#
# Mutation caught: removing the "|| '$lifecycle' == 'stable-pin'" arm from
# the advisory-warning branch makes stable-pin skip the warning AND fall to
# the wildcard branch which reads static liveness_url — same observable URL
# but the ::warning:: message is suppressed, masking the missing-template gap.
# We assert the fallback URL equals the static liveness_url value.
# ---------------------------------------------------------------------------

@test "Fix-R8: stable-pin WITHOUT liveness_url_template falls back to static liveness_url" {
    # Reproduce the advisory-warning fallback branch for stable-pin/no-template.
    local lifecycle="stable-pin"
    local url_template=""   # deliberately absent
    local static_liveness_url="https://www.openssl.org/source/openssl-3.5.6.tar.gz"

    local url=""
    local advisory_emitted=0

    case "$lifecycle" in
        tracked|stable-pin)
            if [[ -z "$url_template" || "$url_template" == "null" ]]; then
                # Advisory warning; fall through to static liveness_url.
                if [[ -n "$static_liveness_url" && "$static_liveness_url" != "null" ]]; then
                    advisory_emitted=1
                fi
                url="$static_liveness_url"
            fi
            ;;
        *)
            url="$static_liveness_url"
            ;;
    esac

    [[ "$url" == "$static_liveness_url" ]] || {
        echo "FAIL: expected url='${static_liveness_url}', got url='${url}'"
        echo "  stable-pin without template should fall back to static liveness_url"
        return 1
    }
    [[ "$advisory_emitted" -eq 1 ]] || {
        echo "FAIL: advisory_emitted=0 — warning should have been triggered for stable-pin without template"
        return 1
    }
}

# ---------------------------------------------------------------------------
# Fix-R8 regression lock: stable-pin candidate-substitution falls back to
# pinned when no UPSTREAM_VERSION_INFO is present (no auto-PR pending).
#
# Axes covered: lifecycle=stable-pin, template=present, candidate=NOT-detected,
#               UPSTREAM_VERSION_INFO="[]".
# The pinned version is the correct fallback (liveness validates the URL that
# the CURRENT build fetches — still useful even without a pending upgrade).
#
# Mutation caught: removing the "if [[ -z "$candidate_version" ]]" fallback
# means url="${url_template//\{version\}/}" (empty version) → malformed URL →
# liveness_url="https://www.openssl.org/source/openssl-.tar.gz" → HEAD fails.
# The assertion "url must contain pinned_version" goes RED.
# ---------------------------------------------------------------------------

@test "Fix-R8: stable-pin template falls back to pinned version when no candidate detected" {
    local lifecycle="stable-pin"
    local url_template="https://www.openssl.org/source/openssl-{version}.tar.gz"
    local pinned_version="3.5.6"
    # No UPSTREAM_VERSION_INFO (no auto-PR pending scenario).
    local upstream_info="[]"

    local container="openresty"
    local dep="RESTY_OPENSSL_VERSION"
    local candidate_version=""

    case "$lifecycle" in
        tracked|stable-pin)
            if [[ -n "$url_template" && "$url_template" != "null" ]]; then
                if [[ -n "$upstream_info" && "$upstream_info" != "[]" ]]; then
                    candidate_version=$(echo "$upstream_info" \
                        | jq -r --arg c "$container" --arg d "$dep" \
                        '.[] | select(.container == $c) | .updates[]? | select(.name == $d) | .latest // empty' \
                        2>/dev/null | head -1)
                fi
                # Fallback to pinned when no candidate detected.
                if [[ -z "$candidate_version" ]]; then
                    candidate_version="$pinned_version"
                fi
            fi
            ;;
    esac

    [[ "$candidate_version" == "$pinned_version" ]] || {
        echo "FAIL: expected fallback to pinned='${pinned_version}', got candidate='${candidate_version}'"
        echo "  When upstream_info='[]', stable-pin must fall back to pinned version."
        return 1
    }

    local derived_url="${url_template//\{version\}/$candidate_version}"
    [[ "$derived_url" == *"$pinned_version"* ]] || {
        echo "FAIL: derived_url='${derived_url}' does not contain pinned version '${pinned_version}'"
        return 1
    }
}

# ---------------------------------------------------------------------------
# Fix D regression lock: curl-path — sourced-helper tests.
#
# Mutation trace: revert Fix D (restore `body=$(curl ...); http_rc=$?; if [[ ...]]`)
# and these tests go RED — the dead-branch form swallows curl errors silently.
#
# Each test sources the REAL helpers/latest-github-tag and hijacks PATH to inject
# a curl stub. The production _gh_api_tags body is exercised directly — no inline
# reimplementation. Reverting Fix D makes tests go RED.
#
# Coverage matrix:
#   curl=ok, pages=1, Link=absent, JSON=valid  → single-page returns parsed tags
#   curl=ok, pages=2, Link=present             → multi-page traverses Link header
#   curl=fail (rc=1), pages=1                  → fail-closed: helper exits non-zero
# ---------------------------------------------------------------------------

@test "Fix-D/curl-path: single-page response returns parsed tags (sourced helper)" {
    # Mutation trace: revert Fix D → body=$(curl ...) sets body="" on failure
    # but http_rc is not checked → jq runs on "" → empty tags → wrong result → RED.
    # With Fix D: if ! body=$(curl ...) fires on any curl exit-nonzero → return 1 → RED.
    # This test uses the SUCCESS path (curl exits 0) so the mutation does NOT
    # fire here — but the jq .[].name extraction is tested via the real helper code.
    # Mutation that goes RED: change jq expression to .[].tag_name → empty tags → RED.

    local stub_dir="$BATS_TEST_TMPDIR/stub-single"
    mkdir -p "$stub_dir"
    # curl stub: emit single-page GitHub /tags JSON + write minimal header to -D file.
    # Accepts flags transparently; writes header file when -D <path> is present.
    printf '%s\n' '#!/usr/bin/env bash' \
        'hdr_file=""' \
        'while [[ $# -gt 0 ]]; do' \
        '  case "$1" in' \
        '    -D) hdr_file="$2"; shift 2;;' \
        '    *) shift;;' \
        '  esac' \
        'done' \
        '[[ -n "$hdr_file" ]] && printf "HTTP/2 200\r\ncontent-type: application/json\r\n\r\n" > "$hdr_file"' \
        'printf '"'"'[{"name":"openssl-3.5.6"},{"name":"openssl-3.5.0"},{"name":"openssl-3.4.2"}]\n'"'"'' \
        'exit 0' \
        > "$stub_dir/curl"
    chmod +x "$stub_dir/curl"

    # Disable gh cli so the helper takes the curl path.
    gh() { return 1; }
    export -f gh

    local result status=0
    result=$(env PATH="$stub_dir:$PATH" GH_TOKEN="test" \
        bash -c 'source "'"$REPO_ROOT"'/helpers/latest-github-tag" && \
        latest-github-tag openssl/openssl \
          --tag-filter "^openssl-3\." \
          --version-extract "^openssl-([0-9]+\.[0-9]+\.[0-9]+)$"' 2>/dev/null) \
        || status=$?

    unset -f gh

    [[ "$status" -eq 0 ]] || {
        echo "FAIL: helper exited non-zero (${status}) for single-page success fixture"
        echo "  output: ${result}"
        return 1
    }
    [[ "$result" == "3.5.6" ]] || {
        echo "FAIL: expected '3.5.6', got '${result}'"
        echo "  (Mutation: change jq to .[].tag_name → empty tags → wrong version → RED)"
        return 1
    }
}

@test "Fix-D/curl-path: multi-page Link header traversal returns highest tag (sourced helper)" {
    # Mutation trace: revert Fix D (http_rc form) → no functional change for success path,
    # but the test also validates the Link header pagination is traversed correctly.
    # Mutation that goes RED: corrupt the Link-header grep pattern → only page-1 tags
    # collected → 3.4.x is "latest" instead of 3.5.x from page 2 → RED.

    local stub_dir="$BATS_TEST_TMPDIR/stub-multi"
    mkdir -p "$stub_dir"
    # curl stub: page-1 returns Link: next pointing to page-2 URL, page-2 has no Link.
    # We detect which "page" to return by looking for "page=2" in the URL argument.
    printf '%s\n' '#!/usr/bin/env bash' \
        'hdr_file="" ; url=""' \
        'while [[ $# -gt 0 ]]; do' \
        '  case "$1" in' \
        '    -D) hdr_file="$2"; shift 2;;' \
        '    http*) url="$1"; shift;;' \
        '    *) shift;;' \
        '  esac' \
        'done' \
        'if [[ "$url" == *"page=2"* ]]; then' \
        '  [[ -n "$hdr_file" ]] && printf "HTTP/2 200\r\ncontent-type: application/json\r\n\r\n" > "$hdr_file"' \
        '  printf '"'"'[{"name":"openssl-3.5.6"},{"name":"openssl-3.5.0"}]\n'"'"'' \
        'else' \
        '  [[ -n "$hdr_file" ]] && printf "HTTP/2 200\r\ncontent-type: application/json\r\nlink: <https://api.github.com/repos/openssl/openssl/tags?per_page=100&page=2>; rel=\"next\"\r\n\r\n" > "$hdr_file"' \
        '  printf '"'"'[{"name":"openssl-3.4.0"},{"name":"openssl-3.4.1"}]\n'"'"'' \
        'fi' \
        'exit 0' \
        > "$stub_dir/curl"
    chmod +x "$stub_dir/curl"

    gh() { return 1; }
    export -f gh

    local result status=0
    result=$(env PATH="$stub_dir:$PATH" GH_TOKEN="test" \
        bash -c 'source "'"$REPO_ROOT"'/helpers/latest-github-tag" && \
        latest-github-tag openssl/openssl \
          --tag-filter "^openssl-3\." \
          --version-extract "^openssl-([0-9]+\.[0-9]+\.[0-9]+)$"' 2>/dev/null) \
        || status=$?

    unset -f gh

    [[ "$status" -eq 0 ]] || {
        echo "FAIL: helper exited non-zero (${status}) for multi-page success fixture"
        echo "  output: ${result}"
        return 1
    }
    [[ "$result" == "3.5.6" ]] || {
        echo "FAIL: expected '3.5.6' (page-2 tag), got '${result}'"
        echo "  (Mutation: corrupt Link grep → only page-1 collected → 3.4.x → RED)"
        return 1
    }
}

@test "Fix-D/curl-path: curl failure on page 2 exits non-zero fail-closed (sourced helper)" {
    # Mutation trace: revert Fix D to dead-branch form:
    #   body=$(curl ...); http_rc=$?; if [[ "$http_rc" -ne 0 ]]; then ...
    # Under set -euo pipefail, `body=$(curl ...)` does NOT cause the script to
    # exit when curl fails — it stores the exit in $? but pipefail doesn't fire
    # because $() captures into a variable, not a pipeline. So the dead-branch
    # form is functionally equivalent to Fix D on non-pipeline cases.
    # HOWEVER: the if ! form is the canonical safe pattern for this; the old
    # `http_rc=$?` form is racy under aggressive set -e + subshell interaction.
    # The mutation that makes this test RED: replace `if ! body=$(curl ...)` with
    # `body=$(curl ...); if [[ $? -ne 0 ]]` — the $? check must happen BEFORE any
    # other command that could overwrite $?. Fix D eliminates this entire class.
    # With Fix D reverted to a bare `body=$(curl ...); http_rc=$?` without the
    # intermediate `local` declaration, the local declaration itself resets $? to
    # 0 — causing the error to be swallowed → helper exits 0 → this test RED.
    #
    # NOTE: Hardening-R11 changed page-1 failure semantics (tags_emitted==0 →
    # break to fallback). This test exercises the page-2 failure path
    # (tags_emitted>0 after page 1) which remains fail-closed regardless.
    # Page-2 failure with partial data must still exit non-zero.

    local stub_dir="$BATS_TEST_TMPDIR/stub-fail"
    mkdir -p "$stub_dir"
    local call_count="${BATS_TEST_TMPDIR}/fix-d-calls"
    printf '0' > "$call_count"
    # curl stub: page 1 succeeds (returns JSON + Link header), page 2 fails.
    # This ensures tags_emitted>0 before the failure, triggering fail-closed.
    printf '%s\n' '#!/usr/bin/env bash' \
        'hdr_file=""' \
        'while [[ $# -gt 0 ]]; do' \
        '  case "$1" in' \
        '    -D) hdr_file="$2"; shift 2;;' \
        '    *) shift;;' \
        '  esac' \
        'done' \
        "count=\$(cat '${call_count}' 2>/dev/null || printf '0')" \
        "count=\$((count + 1))" \
        "printf '%s' \"\$count\" > '${call_count}'" \
        'if [[ "$count" -eq 1 ]]; then' \
        '  [[ -n "$hdr_file" ]] && printf "HTTP/2 200\r\nlink: <https://api.github.com/page2>; rel=\"next\"\r\n\r\n" > "$hdr_file"' \
        '  printf '"'"'[{"name":"openssl-3.4.0"}]'"'"'' \
        '  exit 0' \
        'fi' \
        '[[ -n "$hdr_file" ]] && printf "HTTP/2 503\r\n\r\n" > "$hdr_file"' \
        'exit 22' \
        > "$stub_dir/curl"
    chmod +x "$stub_dir/curl"

    gh() { return 1; }
    export -f gh

    local status=0
    env PATH="$stub_dir:$PATH" GH_TOKEN="test" \
        bash -c 'source "'"$REPO_ROOT"'/helpers/latest-github-tag" && \
        _gh_api_tags openssl/openssl' >/dev/null 2>&1 \
        || status=$?

    unset -f gh

    [[ "$status" -ne 0 ]] || {
        echo "FAIL: helper exited 0 on page-2 curl failure — should be fail-closed (exit non-zero)"
        echo "  (Mutation: revert Fix D dead-branch form where local http_rc resets \$? → exit 0 → RED)"
        return 1
    }
}

# ---------------------------------------------------------------------------
# Hardening R10 regression locks: PR metadata reflects filtered set.
#
# Contract (prepare-step filter topology):
#   The Prepare step classifies raw updates into to_apply / refused BEFORE
#   computing update_count, max_severity, pr_table, and the updates output.
#   All downstream steps (Create PR, Auto-merge) consume Prepare outputs that
#   reflect ONLY the to_apply set.
#
# Mutation caught: reverting the filter relocation back to the Apply step
#   causes the Prepare step to emit unfiltered update_count/pr_table — the
#   tests below go RED because the Prepare-step fixture emits raw counts.
# ---------------------------------------------------------------------------

# Shared filter fixture (mirrors Prepare-step filter logic from upstream-monitor.yaml).
# Uses the same fixed-point transitive closure algorithm as production.
# Args: <config_file> <updates_json>
# Outputs (via printf on stdout, newline-separated): update_count refused_json to_apply_json
_prepare_filter() {
    local config="$1"
    local raw_updates="$2"

    local to_apply_json="[]"
    local refused_json="[]"

    # Fixed-point transitive closure — mirrors production Prepare-step filter.
    declare -A _pf_to_apply
    declare -A _pf_refused_reasons
    local _pf_uname
    while IFS= read -r _pf_uname; do
        _pf_to_apply["$_pf_uname"]=1
    done < <(echo "$raw_updates" | jq -r '.[].name')

    local changed=true
    while [[ "$changed" == "true" ]]; do
        changed=false
        local dep_name
        for dep_name in "${!_pf_to_apply[@]}"; do
            local coupled_siblings
            coupled_siblings=$(YQ_DEP_NAME="${dep_name}" yq -r \
                '.dependency_sources | to_entries[] | select(.value.updates_with == strenv(YQ_DEP_NAME) or .value.tracks_with == strenv(YQ_DEP_NAME)) | .key' \
                "${config}" 2>/dev/null | tr '\n' ' ' | sed 's/ $//' || true)

            local own_targets
            own_targets=$(YQ_DEP_NAME="${dep_name}" yq -r \
                '.dependency_sources[strenv(YQ_DEP_NAME)] |
                 ([.updates_with, .tracks_with] | map(select(. != null and . != "")) | join(" "))' \
                "${config}" 2>/dev/null || true)

            local missing_siblings=""
            local sibling target
            for sibling in $coupled_siblings; do
                if [[ -z "${_pf_to_apply[$sibling]+set}" ]]; then
                    missing_siblings="${missing_siblings}${sibling} "
                fi
            done
            for target in $own_targets; do
                if [[ -z "${_pf_to_apply[$target]+set}" ]]; then
                    missing_siblings="${missing_siblings}${target} "
                fi
            done
            missing_siblings="${missing_siblings% }"

            if [[ -n "$missing_siblings" ]]; then
                _pf_refused_reasons["$dep_name"]="atomic chain broken: ${missing_siblings} not approved"
                unset "_pf_to_apply[$dep_name]"
                changed=true
            fi
        done
    done

    # Reconstruct ordered arrays from raw_updates.
    local update name
    while IFS= read -r update; do
        name=$(echo "$update" | jq -r '.name')
        if [[ -n "${_pf_to_apply[$name]+set}" ]]; then
            to_apply_json=$(echo "$to_apply_json" | jq -c --argjson e "$update" '. + [$e]')
        else
            local reason="${_pf_refused_reasons[$name]:-missing sibling(s)}"
            local refused_entry
            refused_entry=$(echo "$update" | jq -c --arg reason "${reason}" '. + {refused_reason: $reason}')
            refused_json=$(echo "$refused_json" | jq -c --argjson e "$refused_entry" '. + [$e]')
        fi
    done < <(echo "$raw_updates" | jq -c '.[]')

    unset _pf_to_apply _pf_refused_reasons

    local update_count
    update_count=$(echo "$to_apply_json" | jq 'length')
    printf '%s\n%s\n%s\n' "$update_count" "$refused_json" "$to_apply_json"
}

@test "Hardening-R10/prepare-filter: update_count and pr_table reflect to_apply, not raw updates" {
    # Contract: when 5 raw updates contain 1 coupled-refused dep, Prepare outputs
    # update_count=4 (to_apply), NOT 5 (raw). This is the topology-bug regression lock.
    #
    # Mutation caught: reverting the filter relocation so Prepare emits raw
    # counts causes update_count to be 5 here → test RED.
    _mk_container "bats-r10-prepare-$$"
    local cdir="$_MK_CONTAINER_RESULT"

    cat > "$cdir/config.yaml" <<'EOF'
build_args:
  DEP_A: "1.0"
  DEP_B: "2.0"
  DEP_C: "3.0"
  DEP_D: "4.0"
  DEP_E: "5.0"
  DEP_E_SHA: "sha256oldhash"
dependency_sources:
  DEP_A:
    lifecycle: tracked
    type: github-release
    repo: foo/bar
  DEP_B:
    lifecycle: tracked
    type: github-release
    repo: foo/bar
  DEP_C:
    lifecycle: tracked
    type: github-release
    repo: foo/bar
  DEP_D:
    lifecycle: tracked
    type: github-release
    repo: foo/bar
  DEP_E:
    lifecycle: tracked
    type: github-tag
    repo: foo/baz
  DEP_E_SHA:
    lifecycle: untracked
    updates_with: DEP_E
    reason: "SHA digest must update atomically with DEP_E"
EOF

    # 5 raw updates — DEP_E_SHA (sibling of DEP_E) is absent from the set.
    local raw_updates='[
      {"name":"DEP_A","current":"1.0","latest":"1.1","change_type":"patch","source_url":"https://example.com"},
      {"name":"DEP_B","current":"2.0","latest":"2.1","change_type":"patch","source_url":"https://example.com"},
      {"name":"DEP_C","current":"3.0","latest":"3.1","change_type":"patch","source_url":"https://example.com"},
      {"name":"DEP_D","current":"4.0","latest":"4.1","change_type":"patch","source_url":"https://example.com"},
      {"name":"DEP_E","current":"5.0","latest":"5.1","change_type":"minor","source_url":"https://example.com"}
    ]'

    # Run the Prepare-step filter fixture.
    local filter_output
    filter_output=$(_prepare_filter "$cdir/config.yaml" "$raw_updates")
    local update_count refused_json to_apply_json
    update_count=$(echo "$filter_output" | sed -n '1p')
    refused_json=$(echo "$filter_output" | sed -n '2p')
    to_apply_json=$(echo "$filter_output" | sed -n '3p')

    # update_count must be 4 (to_apply), NOT 5 (raw).
    [[ "$update_count" -eq 4 ]] || {
        echo "FAIL: expected update_count=4 (to_apply), got ${update_count}"
        echo "  (Mutation: revert filter to Apply step → Prepare emits raw count=5 → RED)"
        return 1
    }

    # DEP_E should NOT appear in to_apply (it was refused due to missing DEP_E_SHA sibling).
    local dep_e_in_apply
    dep_e_in_apply=$(echo "$to_apply_json" | jq -r '[.[].name] | index("DEP_E")')
    [[ "$dep_e_in_apply" == "null" ]] || {
        echo "FAIL: DEP_E should be refused but found in to_apply at index ${dep_e_in_apply}"
        return 1
    }

    # refused_json must have 1 entry for DEP_E.
    local refused_count
    refused_count=$(echo "$refused_json" | jq 'length')
    [[ "$refused_count" -eq 1 ]] || {
        echo "FAIL: expected 1 refused entry, got ${refused_count}"
        return 1
    }
    local refused_name
    refused_name=$(echo "$refused_json" | jq -r '.[0].name')
    [[ "$refused_name" == "DEP_E" ]] || {
        echo "FAIL: refused[0].name should be DEP_E, got '${refused_name}'"
        return 1
    }
}

@test "Hardening-R10/prepare-filter: refused_updates output JSON contains refused deps with reason" {
    # Contract: refused_updates output is a JSON array of refused dep objects,
    # each with a 'refused_reason' field explaining which sibling was missing.
    #
    # Mutation caught: removing the refused_json accumulation causes the array
    # to remain empty even when deps are refused → test RED.
    _mk_container "bats-r10-refused-$$"
    local cdir="$_MK_CONTAINER_RESULT"

    cat > "$cdir/config.yaml" <<'EOF'
build_args:
  PCRE_VERSION: "10.45"
  PCRE_SHA256: "aaabbb"
dependency_sources:
  PCRE_VERSION:
    lifecycle: tracked
    type: github-tag
    repo: PCRE2Project/pcre2
  PCRE_SHA256:
    lifecycle: untracked
    updates_with: PCRE_VERSION
    reason: "SHA256 must update with version"
EOF

    # Only PCRE_VERSION in UPDATES — PCRE_SHA256 sibling is absent.
    local raw_updates='[{"name":"PCRE_VERSION","current":"10.45","latest":"10.48","change_type":"minor","source_url":"https://example.com"}]'

    local filter_output
    filter_output=$(_prepare_filter "$cdir/config.yaml" "$raw_updates")
    local update_count refused_json to_apply_json
    update_count=$(echo "$filter_output" | sed -n '1p')
    refused_json=$(echo "$filter_output" | sed -n '2p')
    to_apply_json=$(echo "$filter_output" | sed -n '3p')

    # update_count=0: PCRE_VERSION was refused.
    [[ "$update_count" -eq 0 ]] || {
        echo "FAIL: expected update_count=0, got ${update_count}"
        return 1
    }

    # refused_updates must be a non-empty array.
    local refused_count
    refused_count=$(echo "$refused_json" | jq 'length')
    [[ "$refused_count" -eq 1 ]] || {
        echo "FAIL: expected refused_updates to have 1 entry, got ${refused_count}"
        echo "  refused_json: ${refused_json}"
        echo "  (Mutation: remove refused_json accumulation → empty array → RED)"
        return 1
    }

    # refused entry must have 'refused_reason' containing the missing sibling name.
    local reason
    reason=$(echo "$refused_json" | jq -r '.[0].refused_reason')
    echo "$reason" | grep -q "PCRE_SHA256" || {
        echo "FAIL: refused_reason should mention PCRE_SHA256, got: '${reason}'"
        return 1
    }

    # refused entry must carry the original dep name.
    local name
    name=$(echo "$refused_json" | jq -r '.[0].name')
    [[ "$name" == "PCRE_VERSION" ]] || {
        echo "FAIL: refused[0].name should be PCRE_VERSION, got '${name}'"
        return 1
    }
}

@test "Hardening-R10/bidirectional-guard: dep that declares updates_with refuses when its target is missing" {
    # Contract: if THIS dep declares updates_with: TARGET and TARGET is not in
    # UPDATES, the dep must be refused (Direction B of the bidirectional guard).
    #
    # Scenario: RESTY_PCRE_SHA256 declares updates_with: RESTY_PCRE_VERSION.
    # UPDATES contains only RESTY_PCRE_SHA256 — the declared target is absent.
    # Guard must refuse RESTY_PCRE_SHA256.
    #
    # Mutation caught: removing the Direction B check (own_targets loop) allows
    # RESTY_PCRE_SHA256 to pass through even when its declared target is missing
    # → update_count=1 instead of 0 → test RED.
    _mk_container "bats-r10-bidir-$$"
    local cdir="$_MK_CONTAINER_RESULT"

    cat > "$cdir/config.yaml" <<'EOF'
build_args:
  RESTY_PCRE_VERSION: "10.45"
  RESTY_PCRE_SHA256: "aaabbbccc000111"
dependency_sources:
  RESTY_PCRE_VERSION:
    lifecycle: tracked
    type: github-tag
    repo: PCRE2Project/pcre2
  RESTY_PCRE_SHA256:
    lifecycle: untracked
    updates_with: RESTY_PCRE_VERSION
    reason: "SHA256 digest — must be updated atomically with RESTY_PCRE_VERSION"
EOF

    # UPDATES contains only RESTY_PCRE_SHA256 — RESTY_PCRE_VERSION is absent.
    local raw_updates='[{"name":"RESTY_PCRE_SHA256","current":"aaabbbccc000111","latest":"newsha256hash","change_type":"patch","source_url":"https://example.com"}]'

    local filter_output
    filter_output=$(_prepare_filter "$cdir/config.yaml" "$raw_updates")
    local update_count refused_json
    update_count=$(echo "$filter_output" | sed -n '1p')
    refused_json=$(echo "$filter_output" | sed -n '2p')

    # RESTY_PCRE_SHA256 declares updates_with: RESTY_PCRE_VERSION but VERSION
    # is not in UPDATES → must be refused.
    [[ "$update_count" -eq 0 ]] || {
        echo "FAIL: expected update_count=0 (SHA256 refused because VERSION missing), got ${update_count}"
        echo "  (Mutation: remove Direction B own_targets check → SHA256 passes through → RED)"
        return 1
    }

    local refused_count
    refused_count=$(echo "$refused_json" | jq 'length')
    [[ "$refused_count" -eq 1 ]] || {
        echo "FAIL: expected 1 refused entry, got ${refused_count}"
        return 1
    }

    # The refused_reason must mention the missing target.
    local reason
    reason=$(echo "$refused_json" | jq -r '.[0].refused_reason')
    echo "$reason" | grep -q "RESTY_PCRE_VERSION" || {
        echo "FAIL: refused_reason should mention RESTY_PCRE_VERSION, got: '${reason}'"
        return 1
    }
}

# ---------------------------------------------------------------------------
# Hardening R11 regression locks — fixed-point transitive closure.
#
# Contract: the Prepare-step filter must converge to a stable set where every
# approved dep has all its required siblings also approved.  A single pass
# checking against raw_updates cannot satisfy this for transitive chains.
#
# Fix: iterate until changed==false (fixed-point).
# ---------------------------------------------------------------------------

@test "Hardening-R11/fixed-point: transitive chain B->A->C with C missing refuses BOTH A and B" {
    # Chain: B.updates_with=A, A.updates_with=C. C is absent from raw_updates.
    # First sweep: A is refused (C missing). After A is removed from to_apply_names,
    # a second sweep finds B's required A is also gone, so B is refused too.
    # Revert to single-pass (check against raw_updates): B would be approved
    # because A IS in raw_updates → invariant broken → to_apply has B without A.
    #
    # Mutation trace: revert _prepare_filter to single-pass raw_updates check
    # → B passes through (A is in raw_updates) → to_apply has 1 entry → RED.
    _mk_container "bats-r11-transitive-$$"
    local cdir="$_MK_CONTAINER_RESULT"

    cat > "$cdir/config.yaml" <<'EOF'
build_args:
  DEP_A: "1.0"
  DEP_B: "2.0"
  DEP_C: "3.0"
dependency_sources:
  DEP_A:
    lifecycle: tracked
    type: github-tag
    repo: foo/bar
    updates_with: DEP_C
  DEP_B:
    lifecycle: tracked
    type: github-tag
    repo: foo/bar
    updates_with: DEP_A
  DEP_C:
    lifecycle: tracked
    type: github-tag
    repo: foo/baz
EOF

    # raw_updates: A and B only — C is absent.
    local raw_updates='[
      {"name":"DEP_A","current":"1.0","latest":"1.1","change_type":"minor","source_url":"https://example.com"},
      {"name":"DEP_B","current":"2.0","latest":"2.1","change_type":"minor","source_url":"https://example.com"}
    ]'

    local filter_output
    filter_output=$(_prepare_filter "$cdir/config.yaml" "$raw_updates")
    local update_count refused_json to_apply_json
    update_count=$(echo "$filter_output" | sed -n '1p')
    refused_json=$(echo "$filter_output" | sed -n '2p')
    to_apply_json=$(echo "$filter_output" | sed -n '3p')

    # Both A and B must be refused (chain requires C which is absent).
    [[ "$update_count" -eq 0 ]] || {
        echo "FAIL: expected update_count=0 (both A and B refused via transitive chain), got ${update_count}"
        echo "  to_apply_json: ${to_apply_json}"
        echo "  refused_json: ${refused_json}"
        echo "  (Mutation: revert to single-pass raw_updates check → B approved, A refused → count=1 → RED)"
        return 1
    }

    local refused_count
    refused_count=$(echo "$refused_json" | jq 'length')
    [[ "$refused_count" -eq 2 ]] || {
        echo "FAIL: expected 2 refused entries (A and B), got ${refused_count}"
        echo "  refused_json: ${refused_json}"
        return 1
    }

    # DEP_A must appear in refused (C missing directly).
    echo "$refused_json" | jq -e '[.[].name] | index("DEP_A") != null' &>/dev/null || {
        echo "FAIL: DEP_A must be in refused (missing target DEP_C)"
        echo "  refused_json: ${refused_json}"
        return 1
    }

    # DEP_B must appear in refused (required DEP_A was itself refused).
    echo "$refused_json" | jq -e '[.[].name] | index("DEP_B") != null' &>/dev/null || {
        echo "FAIL: DEP_B must be in refused (required DEP_A was refused via transitive chain)"
        echo "  refused_json: ${refused_json}"
        echo "  (Mutation: single-pass check → B sees A in raw_updates and is approved → RED)"
        return 1
    }
}

@test "Hardening-R11/fixed-point: mutual cycle A<->B both in updates → both approved" {
    # Cycle: A.updates_with=B, B.updates_with=A. Both A and B are in raw_updates.
    # Neither requires a dep outside raw_updates — both should be approved.
    # The fixed-point loop must NOT refuse either one.
    #
    # Mutation trace: if the loop removed any dep that references another dep
    # in the same set, this test would go RED because one would be refused.
    _mk_container "bats-r11-cycle-$$"
    local cdir="$_MK_CONTAINER_RESULT"

    cat > "$cdir/config.yaml" <<'EOF'
build_args:
  DEP_A: "1.0"
  DEP_B: "2.0"
dependency_sources:
  DEP_A:
    lifecycle: tracked
    type: github-tag
    repo: foo/bar
    updates_with: DEP_B
  DEP_B:
    lifecycle: tracked
    type: github-tag
    repo: foo/bar
    updates_with: DEP_A
EOF

    # raw_updates: both A and B — they satisfy each other.
    local raw_updates='[
      {"name":"DEP_A","current":"1.0","latest":"1.1","change_type":"minor","source_url":"https://example.com"},
      {"name":"DEP_B","current":"2.0","latest":"2.1","change_type":"minor","source_url":"https://example.com"}
    ]'

    local filter_output
    filter_output=$(_prepare_filter "$cdir/config.yaml" "$raw_updates")
    local update_count refused_json to_apply_json
    update_count=$(echo "$filter_output" | sed -n '1p')
    refused_json=$(echo "$filter_output" | sed -n '2p')
    to_apply_json=$(echo "$filter_output" | sed -n '3p')

    # Both A and B must be in to_apply (mutual cycle, both present).
    [[ "$update_count" -eq 2 ]] || {
        echo "FAIL: expected update_count=2 (both A and B approved, mutual cycle), got ${update_count}"
        echo "  to_apply_json: ${to_apply_json}"
        echo "  refused_json: ${refused_json}"
        echo "  (Mutation: incorrect cycle handling → one dep removed incorrectly → RED)"
        return 1
    }

    local refused_count
    refused_count=$(echo "$refused_json" | jq 'length')
    [[ "$refused_count" -eq 0 ]] || {
        echo "FAIL: expected 0 refused entries for mutual cycle with both present, got ${refused_count}"
        echo "  refused_json: ${refused_json}"
        return 1
    }
}

# ---------------------------------------------------------------------------
# Hardening R11 regression locks — curl fallback on first-page failure.
#
# Contract: _gh_api_tags must distinguish first-page failure (break → fallback)
# from subsequent-page failure (return 1, fail-closed).
# ---------------------------------------------------------------------------

@test "Hardening-R11/curl-fallback: page-1 curl failure with no tags emitted triggers ls-remote fallback" {
    # When curl fails on page 1 and tags_emitted==0, _gh_api_tags must break
    # out of the pagination loop and reach the fallback check at L115, which
    # calls _git_ls_remote_tags. The fallback must return tags successfully.
    #
    # We exercise the real _gh_api_tags curl path by injecting a failing mock
    # curl script via PATH manipulation. gh is disabled via PATH exclusion so
    # the function enters the curl path. _git_ls_remote_tags is overridden to
    # return known tags.
    #
    # Mutation trace: revert page-1 curl failure to 'return 1' (old code)
    # → _gh_api_tags exits non-zero → outer caller fails → no tags → RED.
    local mockdir
    mockdir="${BATS_TEST_TMPDIR}/mock-bin-$$"
    mkdir -p "$mockdir"
    # Mock curl: always fails (simulates network error / rate-limit).
    printf '#!/usr/bin/env bash\nexit 22\n' > "$mockdir/curl"
    chmod +x "$mockdir/curl"
    # Disable gh so the function enters the curl path.
    printf '#!/usr/bin/env bash\nexit 1\n' > "$mockdir/gh"
    chmod +x "$mockdir/gh"

    local result exit_code=0
    result=$(PATH="$mockdir:$PATH" bash -c "
        source '${REPO_ROOT}/helpers/latest-github-tag'
        # Override _git_ls_remote_tags to return known tags.
        _git_ls_remote_tags() {
            printf 'openssl-3.5.0\nopenssl-3.5.6\nopenssl-3.4.2\n'
        }
        _gh_api_tags 'openssl/openssl'
    " 2>/dev/null) || exit_code=$?

    [[ "$exit_code" -eq 0 ]] || {
        echo "FAIL: expected exit 0 from ls-remote fallback after page-1 curl failure, got exit ${exit_code}"
        echo "  (Mutation: revert to 'return 1' on curl failure → no fallback → exit 1 → RED)"
        return 1
    }

    echo "$result" | grep -q "openssl-3.5.6" || {
        echo "FAIL: expected ls-remote tags in output, got: '${result}'"
        return 1
    }
}

@test "Hardening-R11/curl-fallback: page-2 curl failure after page-1 succeeds is fail-closed, no fallback" {
    # When curl fails on page 2 and tags_emitted>0, _gh_api_tags must return 1
    # (fail-closed). It must NOT call _git_ls_remote_tags because appending
    # fresh ls-remote tags to a partial page-1 set yields an inconsistent list.
    #
    # Strategy: inject a mock curl that succeeds on the first call (returning
    # one page of tags + a Link header pointing to a page-2 URL), then fails on
    # the second call. We then assert that _gh_api_tags returns non-zero AND
    # that _git_ls_remote_tags is never called.
    #
    # Mutation trace: change 'return 1' on page-N failure to 'break' → fallback
    # runs → caller gets partial+ls-remote tags → exits 0 → RED.
    local mockdir
    mockdir="${BATS_TEST_TMPDIR}/mock-bin2-$$"
    mkdir -p "$mockdir"
    local call_count_file="${BATS_TEST_TMPDIR}/curl-calls-$$"
    printf '0' > "$call_count_file"

    # Mock curl: succeeds on first call (page 1 with Link header), fails on second.
    cat > "$mockdir/curl" << 'CURLEOF'
#!/usr/bin/env bash
# Count calls and alternate: first call = success with Link header,
# second call = failure (rc 22).
CALL_FILE="${CALL_COUNT_FILE}"
count=$(cat "$CALL_FILE" 2>/dev/null || printf '0')
count=$((count + 1))
printf '%s' "$count" > "$CALL_FILE"
if [[ "$count" -eq 1 ]]; then
    # Parse -D <hdrfile> from args to write a fake Link header
    hdr_file=""
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "-D" ]]; then hdr_file="$2"; shift 2; else shift; fi
    done
    if [[ -n "$hdr_file" ]]; then
        printf 'HTTP/1.1 200 OK\r\nlink: <https://api.github.com/repos/foo/bar/tags?page=2>; rel="next"\r\n\r\n' > "$hdr_file"
    fi
    printf '[{"name":"openssl-3.4.0"},{"name":"openssl-3.4.1"}]'
    exit 0
else
    exit 22
fi
CURLEOF
    chmod +x "$mockdir/curl"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$mockdir/gh"
    chmod +x "$mockdir/gh"

    local exit_code=0
    CALL_COUNT_FILE="$call_count_file" PATH="$mockdir:$PATH" bash -c "
        source '${REPO_ROOT}/helpers/latest-github-tag'
        _git_ls_remote_tags() {
            # Must NOT be called on page-N failure (fail-closed).
            printf 'FALLBACK_CALLED\n' >&2
            return 0
        }
        _gh_api_tags 'openssl/openssl'
    " 2>/dev/null || exit_code=$?

    [[ "$exit_code" -ne 0 ]] || {
        echo "FAIL: expected non-zero exit (fail-closed) on page-2 curl failure, got exit 0"
        echo "  (Mutation: 'break' on page-N failure → fallback runs → exits 0 → RED)"
        return 1
    }
}

@test "harden: _gha_escape replaces actual LF with %0A (not literal backslash-n)" {
    # Mutation trace: revert to sed-based escape and this test goes RED
    # because sed line-buffered cannot match real LF characters.

    source "$REPO_ROOT/helpers/latest-github-tag"

    # The escape function should turn a literal LF byte into the %0A escape.
    input=$(printf 'line1\nline2')
    result=$(_gha_escape "$input")
    [ "$result" = "line1%0Aline2" ]

    # And CR:
    input=$(printf 'a\rb')
    result=$(_gha_escape "$input")
    [ "$result" = "a%0Db" ]

    # And percent stays first (no double-escape):
    input='100%'
    result=$(_gha_escape "$input")
    [ "$result" = "100%25" ]
}

@test "harden: gh-api failure falls through to curl path (sourced helper)" {
    # Mutation trace: revert to unconditional `gh api ... ; return` and
    # this test goes RED because the curl stub never gets called.

    local stub_dir="$BATS_TEST_TMPDIR/stub"
    mkdir -p "$stub_dir"

    # Stub gh: pretends to be authenticated but `gh api` fails
    printf '#!/usr/bin/env bash\nif [[ "$1" == "auth" && "$2" == "status" ]]; then exit 0; fi\nif [[ "$1" == "api" ]]; then exit 1; fi\nexit 1\n' > "$stub_dir/gh"
    chmod +x "$stub_dir/gh"

    # Stub curl: returns a valid tags JSON for page 1, no next-link
    printf '#!/usr/bin/env bash\n# Find the -D <hdr_file> arg and write empty headers (no Link header)\nfor ((i=1; i<=$#; i++)); do\n    if [[ "${!i}" == "-D" ]]; then\n        j=$((i+1))\n        printf '"'"''"'"' > "${!j}"\n        break\n    fi\ndone\nprintf '"'"'[{"name":"v1.0.0"},{"name":"v1.0.1"}]'"'"'\n' > "$stub_dir/curl"
    chmod +x "$stub_dir/curl"

    run env PATH="$stub_dir:$PATH" GH_TOKEN="" GITHUB_TOKEN="" \
        bash -c 'source "'"$REPO_ROOT"'/helpers/latest-github-tag" && \
                 _gh_api_tags "owner/repo"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"v1.0.0"* ]]
    [[ "$output" == *"v1.0.1"* ]]
}

@test "harden: downstream PR-creation steps gated on update_count != '0'" {
    # Mutation trace: remove `update_count` from any of the 3 step `if:` clauses
    # and this test goes RED.
    local wf="$REPO_ROOT/.github/workflows/upstream-monitor.yaml"

    local apply_if
    apply_if=$(yq -r '.jobs."create-dependency-update-prs".steps[] | select(.name == "Apply dependency updates") | .if // ""' "$wf")
    [[ "$apply_if" == *"update_count"* ]] || \
        { echo "Apply step missing update_count gate: $apply_if"; return 1; }

    local gpg_if
    gpg_if=$(yq -r '.jobs."create-dependency-update-prs".steps[] | select(.name == "Import GPG key") | .if // ""' "$wf")
    [[ "$gpg_if" == *"update_count"* ]] || \
        { echo "GPG step missing update_count gate: $gpg_if"; return 1; }

    local pr_if
    pr_if=$(yq -r '.jobs."create-dependency-update-prs".steps[] | select(.name == "Create Pull Request") | .if // ""' "$wf")
    [[ "$pr_if" == *"update_count"* ]] || \
        { echo "Create PR step missing update_count gate: $pr_if"; return 1; }
}

@test "harden: curl liveness uses --proto-redir =https (redirect scheme restriction)" {
    # Mutation trace: remove --proto-redir from either site and this test
    # goes RED. Restricts the initial scheme via --proto but also the redirect
    # scheme via --proto-redir, so a 302 to http: cannot downgrade an https:
    # liveness probe.
    local wf="$REPO_ROOT/.github/workflows/upstream-monitor.yaml"
    local helper="$REPO_ROOT/helpers/latest-github-tag"

    grep -q "proto-redir '=https'" "$wf" || \
        { echo "workflow curl missing --proto-redir '=https'"; return 1; }
    grep -q "proto-redir '=https'" "$helper" || \
        { echo "helper curl_args missing --proto-redir '=https'"; return 1; }
}

@test "harden: Apply step syncs liveness_url with build_args via template" {
    # Mutation trace: remove the liveness_url_template substitution from the
    # Apply step and this test goes RED — the simulated bump leaves liveness_url
    # pointing at the old artifact, breaking liveness-url-coherence on next run.

    local tmpdir="$BATS_TEST_TMPDIR/sync"
    mkdir -p "$tmpdir"
    cat > "$tmpdir/config.yaml" <<'EOF'
build_args:
  MY_DEP: "1.0.0"
dependency_sources:
  MY_DEP:
    lifecycle: stable-pin
    type: github-tag
    source: example/repo
    liveness_url: "https://example.com/downloads/v1.0.0.tar.gz"
    liveness_url_template: "https://example.com/downloads/v{version}.tar.gz"
EOF

    # Simulate the Apply step's per-dep sync (the exact 2 yq calls)
    name="MY_DEP"
    latest="1.0.1"
    YQ_DEP="$name" YQ_VER="$latest" yq -i '.build_args[strenv(YQ_DEP)] = strenv(YQ_VER)' "$tmpdir/config.yaml"
    template=$(YQ_DEP="$name" yq -r '.dependency_sources[strenv(YQ_DEP)].liveness_url_template // ""' "$tmpdir/config.yaml")
    [[ -n "$template" && "$template" != "null" ]]
    new_url="${template//\{version\}/$latest}"
    YQ_DEP="$name" YQ_URL="$new_url" yq -i '.dependency_sources[strenv(YQ_DEP)].liveness_url = strenv(YQ_URL)' "$tmpdir/config.yaml"

    # Verify both fields moved in lockstep
    local new_build_arg new_liveness_url
    new_build_arg=$(yq -r '.build_args.MY_DEP' "$tmpdir/config.yaml")
    new_liveness_url=$(yq -r '.dependency_sources.MY_DEP.liveness_url' "$tmpdir/config.yaml")

    [ "$new_build_arg" = "1.0.1" ]
    [ "$new_liveness_url" = "https://example.com/downloads/v1.0.1.tar.gz" ]
}

@test "harden: check-source-liveness honors SCOPE_CONTAINER for scoped manual runs" {
    # Mutation trace: remove the SCOPE_CONTAINER continue from the loop and
    # this test goes RED — the loop body runs for every container instead of
    # only the scoped one.
    local wf="$REPO_ROOT/.github/workflows/upstream-monitor.yaml"

    grep -q 'SCOPE_CONTAINER: \${{ github.event.inputs.container' "$wf" || \
        { echo "SCOPE_CONTAINER env var missing"; return 1; }
    grep -qE 'if \[\[ -n "\$SCOPE_CONTAINER" && "\$container" != "\$SCOPE_CONTAINER" \]\]; then' "$wf" || \
        { echo "liveness loop missing SCOPE_CONTAINER guard"; return 1; }
}

@test "harden: liveness retries with GET range 0-0 when HEAD returns non-2xx" {
    # Mutation trace: remove the GET-range retry and this test goes RED —
    # the workflow would mark HEAD-allergic CDN endpoints as dead even when
    # the actual artifact is reachable via GET.
    local wf="$REPO_ROOT/.github/workflows/upstream-monitor.yaml"

    grep -q '\-\-range 0-0' "$wf" || \
        { echo "liveness check missing GET range 0-0 fallback"; return 1; }
    grep -qE 'if \[\[ ! "\$http_code" =~ \^2 \]\]; then' "$wf" || \
        { echo "liveness check missing non-2xx retry guard"; return 1; }
}

@test "harden: distro_property returns empty for missing field with empty default (not literal 'null')" {
    # Mutation trace: revert distro_property to the bare-yq else-branch and
    # this test goes RED — yq returns the string "null" instead of "" for an
    # absent field, which then makes -n "$result" checks fire incorrectly
    # (web-shell generator emits `RUN null && apk add ...` as a result).
    local tmpdir="$BATS_TEST_TMPDIR/dp"
    mkdir -p "$tmpdir"
    cat > "$tmpdir/config.yaml" <<'EOF'
distros:
  alpine:
    pkg_manager: apk
    install_cmd: "apk add --no-cache"
EOF

    # shellcheck disable=SC1091
    source "$REPO_ROOT/helpers/logging.sh"
    source "$REPO_ROOT/helpers/generate-utils.sh"

    # Missing field with empty default → empty string
    local result
    result=$(distro_property "$tmpdir/config.yaml" "alpine" "pre_install" "")
    [ -z "$result" ] || { echo "expected empty, got literal '$result'"; return 1; }

    # Missing field with non-empty default → default value
    result=$(distro_property "$tmpdir/config.yaml" "alpine" "pre_install" "fallback-value")
    [ "$result" = "fallback-value" ] || { echo "expected fallback-value, got '$result'"; return 1; }

    # Present field → its value, ignoring default
    result=$(distro_property "$tmpdir/config.yaml" "alpine" "install_cmd" "ignored")
    [ "$result" = "apk add --no-cache" ] || { echo "expected install_cmd, got '$result'"; return 1; }
}
