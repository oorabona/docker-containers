#!/usr/bin/env bats

# Unit tests for scripts/cleanup-outdated-tags.sh
# Focus: is_valid_tag — bake cache tag validity derived from underlying base tag

# Source is_valid_tag from the script.  Sourcing is intentionally inert: it
# defines functions only, so these tests do not need to arrange a fake main.

setup() {
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
    ORIGINAL_PATH="$PATH"

    export GH_TOKEN="test-token"
    export OWNER="test-owner"
    export DRY_RUN="true"
    # Keep a stub make available for tests that invoke main.
    _STUB_DIR="$(mktemp -d)"
    mkdir -p "$_STUB_DIR"
    printf '#!/bin/bash\necho ""\n' > "$_STUB_DIR/make"
    chmod +x "$_STUB_DIR/make"
    export PATH="$_STUB_DIR:$PATH"

    # Source the script without triggering validation, output, or main.
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh" 2>/dev/null || true

    export _STUB_DIR
}

teardown() {
    PATH="$ORIGINAL_PATH"
    export PATH
    rm -rf "${_STUB_DIR:-}"
    unset GH_TOKEN OWNER DRY_RUN _STUB_DIR ORIGINAL_PATH ROOT_DIR
}

# ---------------------------------------------------------------------------
# Helper: build a newline-separated valid-tag list
# ---------------------------------------------------------------------------
make_valid_tags() {
    printf '%s\n' "$@"
}

@test "build_valid_tags mirrors rolling aliases from Linux variants and Windows flavors" {
    local root_dir="$BATS_TEST_TMPDIR/build-valid-tags-root"
    mkdir -p "$root_dir"
    export ROOT_DIR="$root_dir"
    printf '%s\n' \
        '#!/bin/bash' \
        'if [[ "$1" == "list-builds" && "$2" == "github-runner" ]]; then' \
        '  printf "%s\\n" '\''[{"version":"2.334.0","os":"windows","variant":"windows-ltsc2022-dev","tag":"2.334.0-windows-ltsc2022-dev","flavor":"windows-ltsc2022","is_default":false,"is_latest_version":true},{"version":"2.334.0","os":"linux","variant":"debian-trixie-base","tag":"2.334.0-debian-trixie-base","flavor":"debian-trixie","is_default":false,"is_latest_version":true},{"version":"2.334.0","os":"windows","variant":"","tag":"2.334.0","flavor":"windows-ltsc2025","is_default":true,"is_latest_version":true},{"version":"2.333.0","os":"windows","variant":"windows-ltsc2019-dev","tag":"2.333.0-windows-ltsc2019-dev","flavor":"windows-ltsc2019","is_default":false,"is_latest_version":false}]'\'' ' \
        'fi' > "$root_dir/make"
    chmod +x "$root_dir/make"

    local valid_tags expected_tags
    valid_tags=$(build_valid_tags "github-runner")
    expected_tags=$(make_valid_tags \
        "2.333.0-windows-ltsc2019-dev" \
        "2.334.0" \
        "2.334.0-debian-trixie-base" \
        "2.334.0-windows-ltsc2022-dev" \
        "buildcache" \
        "latest" \
        "latest-debian-trixie-base" \
        "latest-windows-ltsc2022" \
        "latest-windows-ltsc2022-dev")

    [[ "$valid_tags" == "$expected_tags" ]]
    is_valid_tag "latest-windows-ltsc2022" "$valid_tags"
    is_valid_tag "latest-windows-ltsc2022-dev" "$valid_tags"
    is_valid_tag "latest-debian-trixie-base" "$valid_tags"
    ! is_valid_tag "latest-debian-trixie" "$valid_tags"
    ! is_valid_tag "latest-windows-ltsc2025" "$valid_tags"
    ! is_valid_tag "latest-nonexistent" "$valid_tags"
    ! is_valid_tag "latest-windows-ltsc2019" "$valid_tags"
}

assert_tag_decode_failure_stops_before_delete() {
    local log_file="$1"
    if [[ "$status" -ne 1 || -s "$log_file" || "$output" != *"Failed to read GHCR version tags; skipping protected"* ]]; then
        echo "ASSERTION FAILED: tag decode failure must stop the package before DELETE" >&2
        return 1
    fi
}

assert_preplan_failure_is_unassessed_and_skips_dockerhub() {
    local call_file="$1"
    if [[ "$output" != *"Packages assessed: 0"* || -s "$call_file" ]]; then
        echo "ASSERTION FAILED: a pre-plan failure must stay unassessed and Docker Hub must not run" >&2
        return 1
    fi
}

assert_prepared_decode_preserves_delete_totals() {
    if [[ "$output" != *"GHCR summary: kept=0, obsolete=1, orphans=0, delete_failures=0"* || "$output" != *"Packages assessed: 1"* ]]; then
        echo "ASSERTION FAILED: a completed GHCR plan must keep successful deletes in the totals and assess the package" >&2
        return 1
    fi
}

@test "sourcing fails closed when the version validation helper is absent" {
    local missing_root="$BATS_TEST_TMPDIR/missing-helper"
    mkdir -p "$missing_root/scripts"
    cp "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh" "$missing_root/scripts/cleanup-outdated-tags.sh"

    run env -u VERSION_RECORD_VALIDATION_JQ bash -c '
        set +e
        source "$1"
        source_status=$?
        ! declare -F purge_ghcr >/dev/null
        [[ "$source_status" -ne 0 ]]
    ' _ "$missing_root/scripts/cleanup-outdated-tags.sh"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Failed to source version record validation helper: $missing_root/helpers/version-record-validation.sh"* ]]
}

assert_dockerhub_called_after_complete_ghcr_plan() {
    local call_file="$1"
    if [[ ! -s "$call_file" ]]; then
        echo "ASSERTION FAILED: Docker Hub must run after a completed GHCR plan even when its execution fails" >&2
        return 1
    fi
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

@test "purge_ghcr listing failure is counted and makes the completed run fail" {
    run env \
        PROJECT_ROOT="$PROJECT_ROOT" \
        GH_TOKEN="$GH_TOKEN" \
        OWNER="$OWNER" \
        DRY_RUN="true" \
        bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            build_valid_tags() { printf "%s\\n" "latest"; }
            gh() {
                echo "gh: API rate limit exceeded" >&2
                return 1
            }
            main broken
        '

    [[ "$status" -eq 1 ]]
    [[ "$output" == *"gh: API rate limit exceeded"* ]]
    [[ "$output" == *"Failed to list GHCR versions; skipping broken"* ]]
    [[ "$output" == *"Packages assessed: 0"* ]]
    [[ "$output" == *"Registry listing failures: 1"* ]]
    [[ "$output" == *"GHCR — delete failures: 0"* ]]
}

@test "purge_ghcr treats a zero-status non-JSON body as a listing failure and leaves the package unassessed" {
    run env \
        PROJECT_ROOT="$PROJECT_ROOT" \
        GH_TOKEN="$GH_TOKEN" \
        OWNER="$OWNER" \
        DRY_RUN="true" \
        bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            build_valid_tags() { printf "%s\\n" "latest"; }
            gh() { printf "%s\\n" "not-json"; }
            main broken
        '

    [[ "$status" -eq 1 ]]
    [[ "$output" == *"GHCR version listing was not a JSON array; skipping broken"* ]]
    [[ "$output" == *"Packages assessed: 0"* ]]
    [[ "$output" == *"Registry listing failures: 1"* ]]
}

@test "purge_ghcr rejects a zero-byte successful listing rather than treating it as an empty array" {
    run env \
        PROJECT_ROOT="$PROJECT_ROOT" \
        GH_TOKEN="$GH_TOKEN" \
        OWNER="$OWNER" \
        DRY_RUN="true" \
        bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            build_valid_tags() { printf "%s\\n" "latest"; }
            gh() { return 0; }
            main broken
        '

    [[ "$status" -eq 1 ]]
    [[ "$output" == *"GHCR version listing was not a JSON array; skipping broken"* ]]
    [[ "$output" == *"Packages assessed: 0"* ]]
    [[ "$output" == *"Registry listing failures: 1"* ]]
}

@test "purge_ghcr flattens two paginated version arrays and classifies a second-page version" {
    run env \
        PROJECT_ROOT="$PROJECT_ROOT" \
        GH_TOKEN="$GH_TOKEN" \
        OWNER="$OWNER" \
        DRY_RUN="true" \
        bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            build_valid_tags() { printf "%s\\n" "latest"; }
            purge_dockerhub() { printf "%s\\n" "0|0"; }
            gh() {
                printf "%s\\n" "[{\"id\":101,\"name\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"metadata\":{\"container\":{\"tags\":[\"stale-first\"]}}}]"
                printf "%s\\n" "[{\"id\":102,\"name\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"metadata\":{\"container\":{\"tags\":[\"stale-second\"]}}}]"
            }
            main stale
        '

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Found 2 GHCR versions"* ]]
    [[ "$output" == *"Would delete version 102"* ]]
}

@test "purge_ghcr rejects a non-array first paginated page even when a later page is valid" {
    run env \
        PROJECT_ROOT="$PROJECT_ROOT" \
        GH_TOKEN="$GH_TOKEN" \
        OWNER="$OWNER" \
        DRY_RUN="true" \
        bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            build_valid_tags() { printf "%s\\n" "latest"; }
            gh() { printf "%s\\n" "{}" "[]"; }
            main broken
        '

    if [[ "$status" -ne 1 ]]; then
        echo "ASSERTION FAILED: expected a non-array first page to refuse the listing" >&2
        return 1
    fi
    [[ "$output" == *"GHCR version listing was not a JSON array; skipping broken"* ]]
    [[ "$output" == *"Packages assessed: 0"* ]]
    [[ "$output" == *"Registry listing failures: 1"* ]]
}

@test "Docker Hub is called only after every GHCR assessment status is complete" {
    local dockerhub_calls="$_STUB_DIR/dockerhub-calls"

    run env \
        PROJECT_ROOT="$PROJECT_ROOT" \
        DOCKERHUB_CALLS="$dockerhub_calls" \
        GH_TOKEN="$GH_TOKEN" \
        OWNER="$OWNER" \
        DRY_RUN="true" \
        bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            build_valid_tags() { printf "%s\\n" "latest"; }
            purge_dockerhub() { printf "%s\\n" "$1" >> "$DOCKERHUB_CALLS"; printf "%s\\n" "1|0"; }
            for expectation in success:0:complete:success listing:10:incomplete:failure processing:11:incomplete:failure delete:12:complete:failure post-complete:13:complete:failure uninterpretable:14:incomplete:failure protection:15:incomplete:failure incomplete-delete:16:incomplete:failure unexpected:99:incomplete:failure; do
                name=${expectation%%:*}; remainder=${expectation#*:}; stub_ghcr_status=${remainder%%:*}; remainder=${remainder#*:}; assessment=${remainder%%:*}; expected_run=${remainder#*:}
                : > "$DOCKERHUB_CALLS"
                purge_ghcr() {
                    if [[ "$stub_ghcr_status" -eq 12 ]]; then printf "%s\\n" "0|0|0|1"; else printf "%s\\n" "0|0|0|0"; fi
                    return "$stub_ghcr_status"
                }
                if main stale; then main_result=success; else main_result=failure; fi
                if [[ "$main_result" != "$expected_run" ]]; then
                    echo "ASSERTION FAILED: GHCR $name status returned $main_result instead of $expected_run" >&2
                    exit 1
                fi
                if [[ "$assessment" == incomplete && -s "$DOCKERHUB_CALLS" ]]; then
                    echo "ASSERTION FAILED: Docker Hub was called while GHCR $name protection was incomplete" >&2
                    exit 1
                fi
                if [[ "$assessment" == complete && ! -s "$DOCKERHUB_CALLS" ]]; then
                    echo "ASSERTION FAILED: Docker Hub was not called after complete GHCR $name assessment" >&2
                    exit 1
                fi
            done
            exit 0
        '

    if [[ "$status" -ne 0 ]]; then
        echo "ASSERTION FAILED: Docker Hub completion guard test exited unexpectedly" >&2
        echo "$output" >&2
        return 1
    fi
    [[ "$output" == *"Docker Hub cleanup skipped: GHCR safety assessment was incomplete"* ]]
}

@test "sourcing is inert and script_root uses BASH_SOURCE rather than the caller directory" {
    run env -u GH_TOKEN -u OWNER bash -c '
        set -e
        before=$(set +o)
        cd /
        source "$1"
        after=$(set +o)
        [[ "$before" == "$after" ]]
        [[ "$(script_root)" == "$2" ]]
    ' _ "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh" "$PROJECT_ROOT"

    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

@test "workflow attempts both registry pruners and fails after either failure" {
    local workflow purge_step
    workflow=$(<"$PROJECT_ROOT/.github/workflows/cleanup-registry.yaml")
    purge_step=$(sed -n '/- name: Purge obsolete images/,/- name: Fail if registry cleanup failed/p' "$PROJECT_ROOT/.github/workflows/cleanup-registry.yaml")

    [[ "$workflow" == *"id: cleanup_old_versions"* ]]
    [[ "$workflow" == *"id: purge_obsolete_images"* ]]
    [[ "$purge_step" == *"continue-on-error: true"* ]]
    [[ "$purge_step" == *"always() && (github.event_name == 'schedule' || inputs.purge_obsolete == true)"* ]]
    [[ "$workflow" == *"steps.cleanup_old_versions.outcome }}\" == \"failure\" || \"\${{ steps.purge_obsolete_images.outcome"* ]]

    # This is the failure path that GitHub Actions evaluates: continue-on-error
    # preserves the age-pruner outcome while always() still starts the second
    # pruner, then the final gate fails the job.
    run bash -c '
        printf "%s\\n" "Cleanup old versions ran (failure)"
        [[ "$1" == *"continue-on-error: true"* ]]
        [[ "$2" == *"always() && (github.event_name == '\''schedule'\'' || inputs.purge_obsolete == true)"* ]]
        printf "%s\\n" "Purge obsolete images ran"
        [[ "$1" == *"steps.cleanup_old_versions.outcome }}\" == \"failure\" || \"\${{ steps.purge_obsolete_images.outcome"* ]]
    ' _ "$workflow" "$purge_step"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Cleanup old versions ran (failure)"* ]]
    [[ "$output" == *"Purge obsolete images ran"* ]]
}

@test "purge_ghcr delete failure is counted and returned as a failed completed run" {
    run env \
        PROJECT_ROOT="$PROJECT_ROOT" \
        GH_TOKEN="$GH_TOKEN" \
        OWNER="$OWNER" \
        DRY_RUN="false" \
        bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            build_valid_tags() { printf "%s\\n" "latest"; }
            gh() {
                if [[ "$*" == *"--method DELETE"* ]]; then
                    echo "gh: delete denied" >&2
                    return 1
                fi
                printf "%s\\n" "[{\"id\":101,\"name\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"metadata\":{\"container\":{\"tags\":[\"stale\"]}}}]"
            }
            main stale
        '

    [[ "$status" -eq 1 ]]
    [[ "$output" == *"gh: delete denied"* ]]
    [[ "$output" == *"Failed to delete"* ]]
    [[ "$output" == *"GHCR summary: kept=0, obsolete=1, orphans=0, delete_failures=1"* ]]
    [[ "$output" == *"Packages assessed: 1"* ]]
    [[ "$output" == *"Registry listing failures: 0"* ]]
    [[ "$output" == *"GHCR — delete failures: 1"* ]]
}

@test "a failed post-delete GHCR cleanup still reports successful deletions" {
    cat > "$_STUB_DIR/rm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${RM_CALLS:-}" ]]; then
    exec /bin/rm "$@"
fi

calls=0
[[ -f "$RM_CALLS" ]] && calls=$(<"$RM_CALLS")
calls=$((calls + 1))
printf '%s\n' "$calls" > "$RM_CALLS"
exit 1
EOF
    chmod +x "$_STUB_DIR/rm"
    local rm_calls="$_STUB_DIR/rm-calls"

    run env \
        PROJECT_ROOT="$PROJECT_ROOT" \
        PATH="$_STUB_DIR:$PATH" \
        RM_CALLS="$rm_calls" \
        GH_TOKEN="$GH_TOKEN" \
        OWNER="$OWNER" \
        DRY_RUN="false" \
        bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            build_valid_tags() { printf "%s\\n" "latest"; }
            gh() {
                if [[ "$*" == *"--method DELETE"* ]]; then
                    return 0
                fi
                printf "%s\\n" "[{\"id\":101,\"name\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"metadata\":{\"container\":{\"tags\":[\"stale\"]}}}]"
            }
            main stale
        '

    [[ "$status" -eq 1 ]]
    [[ "$output" == *"Failed to remove GHCR work files after cleanup"* ]]
    [[ "$output" == *"GHCR summary: kept=0, obsolete=1, orphans=0, delete_failures=0"* ]]
    [[ "$output" == *"Packages assessed: 1"* ]]
    [[ "$output" == *"Packages skipped (processing failed): 1"* ]]
    [[ "$output" == *"GHCR — kept: 0, obsolete: 1, orphans: 0"* ]]
}

@test "a tag decode failure stops a protecting GHCR version before DELETE" {
    local gh_log="$_STUB_DIR/gh.log"
    local dockerhub_calls="$_STUB_DIR/dockerhub-calls"

    run env \
        PROJECT_ROOT="$PROJECT_ROOT" \
        GH_LOG="$gh_log" \
        DOCKERHUB_CALLS="$dockerhub_calls" \
        GH_TOKEN="$GH_TOKEN" \
        OWNER="$OWNER" \
        DRY_RUN="false" \
        bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            build_valid_tags() { printf "%s\\n" "latest"; }
            purge_dockerhub() { printf "%s\\n" "$1" >> "$DOCKERHUB_CALLS"; printf "%s\\n" "1|0"; }
            gh() {
                if [[ "$*" == *"--method DELETE"* ]]; then printf "DELETE:%s\\n" "$*" >> "$GH_LOG"; return 0; fi
                printf "%s\\n" "[{\"id\":101,\"name\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"metadata\":{\"container\":{\"tags\":[\"latest\"]}}}]"
            }
            jq() {
                if [[ "${!#}" == ".tags[]" ]]; then echo "jq: tag decode exhausted" >&2; return 1; fi
                command jq "$@"
            }
            main protected
        '

    assert_tag_decode_failure_stops_before_delete "$gh_log"
    assert_preplan_failure_is_unassessed_and_skips_dockerhub "$dockerhub_calls"
    [[ "$output" == *"Packages skipped (processing failed): 1"* ]]
}

@test "a prepared GHCR deletion decode failure assesses the completed plan, reports the DELETE, and runs Docker Hub" {
    local gh_log="$_STUB_DIR/gh.log"
    local base64_calls="$_STUB_DIR/base64-calls"
    local dockerhub_calls="$_STUB_DIR/dockerhub-calls"

    run env \
        PROJECT_ROOT="$PROJECT_ROOT" \
        GH_LOG="$gh_log" \
        BASE64_CALLS="$base64_calls" \
        DOCKERHUB_CALLS="$dockerhub_calls" \
        GH_TOKEN="$GH_TOKEN" \
        OWNER="$OWNER" \
        DRY_RUN="false" \
        bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            build_valid_tags() { printf "%s\\n" "latest"; }
            purge_dockerhub() { printf "%s\\n" "$1" >> "$DOCKERHUB_CALLS"; printf "%s\\n" "1|0"; }
            gh() {
                if [[ "$*" == *"--method DELETE"* ]]; then printf "DELETE:%s\\n" "$*" >> "$GH_LOG"; return 0; fi
                printf "%s\\n" "[{\"id\":101,\"name\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"metadata\":{\"container\":{\"tags\":[\"stale-first\"]}}},{\"id\":102,\"name\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"metadata\":{\"container\":{\"tags\":[\"stale-second\"]}}}]"
            }
            base64() {
                calls=0; [[ -f "$BASE64_CALLS" ]] && calls=$(<"$BASE64_CALLS")
                calls=$((calls + 1)); printf "%s\\n" "$calls" > "$BASE64_CALLS"
                [[ "$calls" -lt 4 ]] || { echo "base64: prepared record lost" >&2; return 1; }
                command base64 "$@"
            }
            main stale
        '

    assert_dockerhub_called_after_complete_ghcr_plan "$dockerhub_calls"
    [[ "$status" -eq 1 ]]
    [[ "$(<"$gh_log")" == *"/versions/101"* ]]
    [[ "$(<"$gh_log")" != *"/versions/102"* ]]
    assert_prepared_decode_preserves_delete_totals
    [[ "$output" == *"Packages skipped (processing failed): 1"* ]]
}

run_outdated_validation_case() {
    local response_json="$1"
    local expected_field="$2"
    local gh_log="$_STUB_DIR/validation-gh.log"
    local dockerhub_calls="$_STUB_DIR/validation-dockerhub.log"

    run env \
        PROJECT_ROOT="$PROJECT_ROOT" \
        RESPONSE_JSON="$response_json" \
        GH_LOG="$gh_log" \
        DOCKERHUB_CALLS="$dockerhub_calls" \
        GH_TOKEN="$GH_TOKEN" \
        OWNER="$OWNER" \
        DRY_RUN="false" \
        bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            build_valid_tags() { printf "%s\n" "latest"; }
            purge_dockerhub() { printf "%s\n" "$1" >> "$DOCKERHUB_CALLS"; printf "%s\n" "1|0"; }
            gh() {
                if [[ "$*" == *"--method DELETE"* ]]; then printf "%s\n" "$*" >> "$GH_LOG"; return 0; fi
                printf "%s\n" "$RESPONSE_JSON"
            }
            main malformed
        '

    [[ "$status" -eq 1 ]]
    [[ "$output" == *"validation failed: $expected_field"* ]]
    [[ "$output" == *"Packages skipped (processing failed): 1"* ]]
    [[ ! -s "$gh_log" ]]
    [[ ! -s "$dockerhub_calls" ]]
}

@test "outdated-tag cleanup maps jq exit 5 to 14 and jq exit 137 to 11" {
    run env \
        PROJECT_ROOT="$PROJECT_ROOT" \
        GH_TOKEN="$GH_TOKEN" \
        OWNER="$OWNER" \
        bash -c '
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            LISTING_FAILURE=10 PROCESSING_FAILURE=11 DELETE_FAILURE=12 POST_DELETE_PROCESSING_FAILURE=13 UNINTERPRETABLE_RECORD_FAILURE=14 PROTECTION_FAILURE=15
            gh() { printf "%s\\n" "[{\"id\":101,\"name\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"metadata\":{\"container\":{}}}]"; }
            purge_ghcr malformed latest
        '

    [[ "$status" -eq 14 ]]

    local real_jq
    real_jq="$(command -v jq)"
    cat > "$_STUB_DIR/jq" <<'EOF'
#!/usr/bin/env bash
for argument in "$@"; do
    [[ "$argument" == *"validate_outdated_tags_versions"* ]] && exit 137
done
exec "$REAL_JQ" "$@"
EOF
    chmod +x "$_STUB_DIR/jq"

    run env \
        PATH="$_STUB_DIR:$PATH" \
        REAL_JQ="$real_jq" \
        PROJECT_ROOT="$PROJECT_ROOT" \
        GH_TOKEN="$GH_TOKEN" \
        OWNER="$OWNER" \
        bash -c '
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            LISTING_FAILURE=10 PROCESSING_FAILURE=11 DELETE_FAILURE=12 POST_DELETE_PROCESSING_FAILURE=13 UNINTERPRETABLE_RECORD_FAILURE=14 PROTECTION_FAILURE=15
            gh() { printf "%s\\n" "[{\"id\":101,\"name\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"metadata\":{\"container\":{\"tags\":[]}}}]"; }
            purge_ghcr validator-killed latest
        '

    [[ "$status" -eq 11 ]]
    [[ "$output" == *"GHCR version validator could not run"* ]]
}

@test "outdated-tag validation entry point rejects non-arrays and accepts an empty array" {
    run env PROJECT_ROOT="$PROJECT_ROOT" bash -c '
        set -euo pipefail
        source "$PROJECT_ROOT/helpers/version-record-validation.sh"
        for versions in null "{}" "\"\""; do
            if validation_error=$(jq -er "$VERSION_RECORD_VALIDATION_JQ validate_outdated_tags_versions" <<< "$versions" 2>&1 >/dev/null); then
                exit 1
            else
                validation_status=$?
            fi
            [[ "$validation_status" -eq 5 ]]
            [[ "$validation_error" == *"validation failed: versions must be an array"* ]]
        done
        jq -er "$VERSION_RECORD_VALIDATION_JQ validate_outdated_tags_versions" <<< "[]" | grep -qx true
    '

    [[ "$status" -eq 0 ]]
}

@test "outdated-tag cleanup accepts an observed empty GHCR tags array" {
    run env \
        PROJECT_ROOT="$PROJECT_ROOT" \
        GH_TOKEN="$GH_TOKEN" \
        OWNER="$OWNER" \
        DRY_RUN="true" \
        bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            build_valid_tags() { printf "%s\n" "latest"; }
            gh() {
                [[ "$*" == *"--method DELETE"* ]] && return 1
                printf "%s\n" "[{\"id\":\"101\",\"name\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"metadata\":{\"container\":{\"tags\":[]}}}]"
            }
            main untagged
        '

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Packages skipped (processing failed): 0"* ]]
}

@test "outdated-tag cleanup rejects absent GHCR tags before any deletion" {
    run_outdated_validation_case \
        '[{"id":101,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{}}}]' \
        'versions[0].metadata.container.tags is missing'
}

@test "outdated-tag cleanup rejects null GHCR tags before any deletion" {
    run_outdated_validation_case \
        '[{"id":101,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":null}}}]' \
        'versions[0].metadata.container.tags is invalid'
}

@test "outdated-tag cleanup rejects a non-array GHCR tags field before any deletion" {
    run_outdated_validation_case \
        '[{"id":101,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":"latest"}}}]' \
        'versions[0].metadata.container.tags is invalid'
}

@test "outdated-tag cleanup rejects pipe and comma GHCR tags before any deletion" {
    run_outdated_validation_case \
        '[{"id":101,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":["bad|tag"]}}}]' \
        'versions[0].metadata.container.tags[0] is invalid'
    run_outdated_validation_case \
        '[{"id":101,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":["bad,tag"]}}}]' \
        'versions[0].metadata.container.tags[0] is invalid'
}

@test "outdated-tag cleanup rejects trailing newlines in tags, digests, and IDs" {
    run_outdated_validation_case \
        '[{"id":101,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":["latest\n"]}}}]' \
        'versions[0].metadata.container.tags[0] is invalid'
    run_outdated_validation_case \
        '[{"id":101,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n","metadata":{"container":{"tags":["latest"]}}}]' \
        'versions[0].name is invalid'
    run_outdated_validation_case \
        '[{"id":"101\n","name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":["latest"]}}}]' \
        'versions[0].id is invalid'
}

@test "build_valid_tags accepts a Linux build with an empty flavor" {
    local root_dir="$BATS_TEST_TMPDIR/build-empty-flavor-root"
    mkdir -p "$root_dir"
    export ROOT_DIR="$root_dir"
    printf '%s\n' '#!/usr/bin/env bash' \
        'printf "%s\n" '\''[{"tag":"1.2.3","variant":"debian","flavor":"","os":"linux","is_default":true,"is_latest_version":true}]'\''' \
        > "$root_dir/make"
    chmod +x "$root_dir/make"

    run build_valid_tags example

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"latest-debian"* ]]
}

run_invalid_build_case() {
    local build_json="$1"
    local root_dir="$BATS_TEST_TMPDIR/build-invalid-element-root"
    mkdir -p "$root_dir"
    export ROOT_DIR="$root_dir"
    printf '%s\n' '#!/usr/bin/env bash' \
        "printf '%s\\n' '$build_json'" \
        > "$root_dir/make"
    chmod +x "$root_dir/make"

    run build_valid_tags example

    [[ "$status" -eq 1 ]]
    [[ "$output" != *"latest-"* ]]
}

@test "build_valid_tags rejects os darwin without emitting latest-" {
    run_invalid_build_case '[{"tag":"1.2.3","variant":"","flavor":"","os":"darwin","is_default":true,"is_latest_version":true}]'
}

@test "build_valid_tags rejects a string is_default without emitting latest-" {
    run_invalid_build_case '[{"tag":"1.2.3","variant":"","flavor":"","os":"linux","is_default":"false","is_latest_version":true}]'
}

@test "build_valid_tags rejects an empty tag without emitting latest-" {
    run_invalid_build_case '[{"tag":"","variant":"","flavor":"","os":"linux","is_default":true,"is_latest_version":true}]'
}

@test "build_valid_tags rejects a null variant without emitting latest-" {
    run_invalid_build_case '[{"tag":"1.2.3","variant":null,"flavor":"","os":"linux","is_default":true,"is_latest_version":true}]'
}

@test "build_valid_tags rejects trailing newlines in emitted and component tags" {
    run_invalid_build_case '[{"tag":"release\n","variant":"","flavor":"","os":"linux","is_default":true,"is_latest_version":true}]'
    run_invalid_build_case '[{"tag":"release","variant":"release\n","flavor":"","os":"linux","is_default":true,"is_latest_version":true}]'
    run_invalid_build_case '[{"tag":"release","variant":"","flavor":"release\n","os":"windows","is_default":false,"is_latest_version":true}]'
}

@test "build_valid_tags validates the full emitted latest alias length" {
    local variant_121 variant_122 root_dir build_json
    variant_121=$(printf '%*s' 121 '' | tr ' ' a)
    variant_122=$(printf '%*s' 122 '' | tr ' ' a)
    root_dir="$BATS_TEST_TMPDIR/build-alias-length-root"
    mkdir -p "$root_dir"
    export ROOT_DIR="$root_dir"
    build_json="[{\"tag\":\"release\",\"variant\":\"$variant_121\",\"flavor\":\"\",\"os\":\"linux\",\"is_default\":true,\"is_latest_version\":true}]"
    printf '%s\n' '#!/usr/bin/env bash' "printf '%s\\n' '$build_json'" > "$root_dir/make"
    chmod +x "$root_dir/make"

    run build_valid_tags example

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"latest-$variant_121"* ]]

    run_invalid_build_case "[{\"tag\":\"release\",\"variant\":\"$variant_122\",\"flavor\":\"\",\"os\":\"linux\",\"is_default\":true,\"is_latest_version\":true}]"
}
