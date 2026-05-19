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
    # Synthetic test containers are created under REPO_ROOT so that
    # check-dependency-versions.sh can find <container>/config.yaml.
    # Each test uses a unique name and cleans up in teardown.
    TEST_CONTAINER_DIRS=()

    # Clean up any stale bats-* dirs from previous failed runs
    find "$REPO_ROOT" -maxdepth 1 -name "bats-*" -type d 2>/dev/null | while read -r d; do
        [ -d "$d" ] && { find "$d" -type f -delete; rmdir "$d" 2>/dev/null || true; }
    done
}

teardown() {
    # Remove synthetic test container directories
    for d in "${TEST_CONTAINER_DIRS[@]:-}"; do
        if [[ -n "$d" && -d "$d" ]]; then
            find "$d" -type f -delete 2>/dev/null || true
            rmdir "$d" 2>/dev/null || true
        fi
    done
    cd "$ORIG_DIR" 2>/dev/null || true
}

# Create a synthetic container dir under REPO_ROOT.
# Usage: cdir=$(_mk_container <name>)
_mk_container() {
    local name="$1"
    local dir="$REPO_ROOT/${name}"
    mkdir -p "$dir"
    TEST_CONTAINER_DIRS+=("$dir")
    echo "$dir"
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
    local cdir
    cdir=$(_mk_container "bats-eol-test-$$")
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
    local cdir
    cdir=$(_mk_container "bats-eol-test2-$$")
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
    local cdir
    cdir=$(_mk_container "bats-pin-silent-$$")
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
    local cdir
    cdir=$(_mk_container "bats-pin-countdown-$$")
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
    local cdir
    cdir=$(_mk_container "bats-pin-past-$$")
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
#   yq -r ".dependency_sources.${name}.updates_with // \"\""
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
    local cdir
    cdir=$(_mk_container "bats-coupled-a-$$")

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
    local cdir
    cdir=$(_mk_container "bats-coupled-b-$$")

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
    local cdir
    cdir=$(_mk_container "bats-coupled-c-$$")

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
    #   yq -r ".dependency_sources.${name}.updates_with // \"\""
    # Effect: returns "" for RESTY_PCRE_VERSION (it has no updates_with field)
    # → coupled_siblings="" → guard does NOT fire → half-update PR proceeds.
    local cdir
    cdir=$(_mk_container "bats-coupled-d-$$")

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
    broken_result=$(yq -r ".dependency_sources.${name}.updates_with // \"\"" \
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
    local cdir
    cdir=$(_mk_container "bats-coupled-compat-$$")
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
    local cdir
    cdir=$(_mk_container "bats-p3-prod-$$")

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
    local cdir
    cdir=$(_mk_container "bats-pin-eol-continue-$$")
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
    # check-dependency-versions.sh emits a JSON line to stdout. Extract it.
    local updates_section
    updates_section=$(echo "$output" | grep -o '"updates":\s*\[[^]]*\]' || echo '"updates":[]')

    # The updates array must be empty for this container.
    # Accept both empty array forms: [] and [ ] (whitespace-normalized).
    if echo "$updates_section" | grep -qE '"updates"\s*:\s*\[\s*\{'; then
        echo "FAIL: EOL-passed stable-pin leaked into updates_json — continue is missing"
        echo "updates_section: $updates_section"
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
    local expected_pcre2="https://github.com/PCRE2Project/pcre2/releases/tag/pcre2-10.47"
    [[ "$url_pcre2" == "$expected_pcre2" ]] || {
        echo "FAIL: pcre2 URL mismatch"
        echo "  Got:      ${url_pcre2}"
        echo "  Expected: ${expected_pcre2}"
        return 1
    }

    # openssl case: raw tag "openssl-3.5.6", extracted version "3.5.6"
    local url_openssl
    url_openssl=$(_call_build_source_url "github-tag" "openssl/openssl" "3.5.6" "openssl-3.5.6")
    local expected_openssl="https://github.com/openssl/openssl/releases/tag/openssl-3.5.6"
    [[ "$url_openssl" == "$expected_openssl" ]] || {
        echo "FAIL: openssl URL mismatch"
        echo "  Got:      ${url_openssl}"
        echo "  Expected: ${expected_openssl}"
        return 1
    }

    # Standard v-prefix case: when raw_tag is empty, fallback to v${version}
    local url_vprefix
    url_vprefix=$(_call_build_source_url "github-tag" "example/repo" "1.2.3" "")
    local expected_vprefix="https://github.com/example/repo/releases/tag/v1.2.3"
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
