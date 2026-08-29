#!/usr/bin/env bats

# Unit tests for scripts/cleanup-outdated-tags.sh
# Focus: is_valid_tag — bake cache tag validity derived from underlying base tag;
# GHCR manifest-protection contract and end-to-end deletion assertions

bats_require_minimum_version 1.7.0

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
    if ! source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh" 2>/dev/null; then
        echo "ASSERTION FAILED: required functions script_root, build_valid_tags, is_valid_tag, purge_ghcr, purge_dockerhub, and main are unavailable because cleanup-outdated-tags.sh could not be sourced" >&2
        return 1
    fi

    local required_function
    for required_function in script_root build_valid_tags is_valid_tag purge_ghcr purge_dockerhub main; do
        if ! declare -F "$required_function" >/dev/null; then
            echo "ASSERTION FAILED: $required_function must be defined after sourcing cleanup-outdated-tags.sh" >&2
            return 1
        fi
    done

    export _STUB_DIR
}

teardown() {
    PATH="$ORIGINAL_PATH"
    export PATH
    rm -rf "${_STUB_DIR:-}"
    unset GH_TOKEN OWNER DRY_RUN _STUB_DIR ORIGINAL_PATH ROOT_DIR
}

@test "sourcing cleanup-outdated-tags leaves caller command and colour variables unset" {
    run env PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN="true" bash -c '
        set -euo pipefail
        unset DOCKER SKOPEO RED GREEN YELLOW BLUE NC
        source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
        for variable in DOCKER SKOPEO RED GREEN YELLOW BLUE NC; do
            if [[ -v "$variable" ]]; then
                printf "%s was changed while sourcing\\n" "$variable" >&2
                exit 1
            fi
        done
    '

    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Helper: build a newline-separated valid-tag list
# ---------------------------------------------------------------------------
make_valid_tags() {
    printf '%s\n' "$@"
}

@test "build_valid_tags consumes the shared tag plan for containers without declared aliases" {
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
        "latest-windows-ltsc2022-dev")

    [[ "$valid_tags" == "$expected_tags" ]]
    is_valid_tag "latest-windows-ltsc2022-dev" "$valid_tags"
    is_valid_tag "latest-debian-trixie-base" "$valid_tags"
    run ! is_valid_tag "latest-debian-trixie" "$valid_tags"
    run ! is_valid_tag "latest-windows-ltsc2025" "$valid_tags"
    run ! is_valid_tag "latest-windows-ltsc2022" "$valid_tags"
    run ! is_valid_tag "latest-nonexistent" "$valid_tags"
    run ! is_valid_tag "latest-windows-ltsc2019" "$valid_tags"
}

@test "build_valid_tags keeps every exact and declared postgres tag from all 21 cells" {
    local root_dir="$BATS_TEST_TMPDIR/build-postgres-aliases-root"
    local cells='[]' version flavor tag is_default is_latest valid_tags alias expected_count
    local -a versions=("18.6" "17.11" "16.15")
    local -a flavors=("base" "vector" "analytics" "timeseries" "spatial" "distributed" "full")

    mkdir -p "$root_dir/postgres"
    cp "$PROJECT_ROOT/postgres/variants.yaml" "$root_dir/postgres/variants.yaml"
    for version in "${versions[@]}"; do
        for flavor in "${flavors[@]}"; do
            tag="${version}-alpine"
            [[ "$flavor" == "base" ]] || tag+="-${flavor}"
            is_default=false
            [[ "$flavor" == "base" ]] && is_default=true
            is_latest=false
            [[ "$version" == "18.6" ]] && is_latest=true
            cells=$(jq -cn --argjson cells "$cells" --arg tag "$tag" --arg flavor "$flavor" \
                --argjson is_default "$is_default" --argjson is_latest_version "$is_latest" \
                '$cells + [{tag: $tag, variant: $flavor, flavor: $flavor, os: "linux", is_default: $is_default, is_latest_version: $is_latest_version}]')
        done
    done
    printf '%s\n' '#!/usr/bin/env bash' "printf '%s\\n' '$cells'" > "$root_dir/make"
    chmod +x "$root_dir/make"
    export ROOT_DIR="$root_dir"

    valid_tags=$(build_valid_tags postgres)
    expected_count=50 # 21 exact + 21 declared aliases + 7 global aliases + buildcache
    if [[ "$(wc -l <<< "$valid_tags")" -ne "$expected_count" ]]; then
        echo "ASSERTION FAILED: cleanup must keep the 50 tags planned for all 21 postgres cells" >&2
        return 1
    fi

    for version in "${versions[@]}"; do
        for flavor in "${flavors[@]}"; do
            tag="${version}-alpine"
            alias="${version%%.*}-alpine"
            [[ "$flavor" == "base" ]] || {
                tag+="-${flavor}"
                alias+="-${flavor}"
            }
            if ! is_valid_tag "$tag" "$valid_tags"; then
                echo "ASSERTION FAILED: cleanup must retain the exact postgres tag $tag" >&2
                return 1
            fi
            if ! is_valid_tag "$alias" "$valid_tags"; then
                echo "ASSERTION FAILED: cleanup must retain the declared postgres alias $alias" >&2
                return 1
            fi
        done
    done
    run ! is_valid_tag "19-alpine" "$valid_tags"
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
        if declare -F purge_ghcr >/dev/null; then
            echo "ASSERTION FAILED: purge_ghcr must not exist after failed validation-helper source" >&2
            exit 1
        fi
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

run_manifest_protection_refusal() {
    local manifest_json="$1"
    local expected_reason="$2"
    local gh_log="$_STUB_DIR/manifest-protection-gh.log"
    local dockerhub_calls="$_STUB_DIR/manifest-protection-dockerhub.log"

    run env \
        PROJECT_ROOT="$PROJECT_ROOT" \
        MANIFEST_JSON="$manifest_json" \
        GH_LOG="$gh_log" \
        DOCKERHUB_CALLS="$dockerhub_calls" \
        GH_TOKEN="$GH_TOKEN" \
        OWNER="$OWNER" \
        DRY_RUN="false" \
        bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            build_valid_tags() { printf "%s\\n" "latest"; }
            purge_dockerhub() { printf "%s\\n" "$1" >> "$DOCKERHUB_CALLS"; printf "%s\\n" "0|0"; }
            gh() {
                if [[ "$*" == *"--method DELETE"* ]]; then printf "DELETE:%s\\n" "$*" >> "$GH_LOG"; return 0; fi
                if [[ "$*" != *"/versions"* ]]; then printf "%s\\n" "{\"version_count\":2}"; return 0; fi
                printf "%s\\n" "[{\"id\":101,\"name\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"metadata\":{\"container\":{\"tags\":[\"latest\"]}}},{\"id\":102,\"name\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"metadata\":{\"container\":{\"tags\":[\"stale\"]}}}]"
            }
            curl() {
                if [[ "$*" == *"/token?"* ]]; then printf "%s\\n" "{\"token\":\"registry-token\"}"
                elif [[ "$*" == *"/manifests/"* ]]; then printf "%s\\n" "$MANIFEST_JSON"
                else echo "unexpected curl: $*" >&2; return 1
                fi
            }
            main protected
        '

    if [[ "$status" -ne 1 ]]; then
        echo "ASSERTION FAILED: manifest protection refusal was not returned" >&2
        return 1
    fi
    if [[ "$output" != *"Refused manifest protection for sha256:aaaaaaaaaaaa"* || "$output" != *"$expected_reason"* ]]; then
        echo "ASSERTION FAILED: refusal did not name the kept digest and reason" >&2
        return 1
    fi
    if [[ -s "$gh_log" || -s "$dockerhub_calls" ]]; then
        echo "ASSERTION FAILED: manifest protection refusal attempted a registry deletion" >&2
        return 1
    fi
}

run_outdated_tags_safety_case() {
    local listing_json="$1"
    local package_json="$2"
    local manifest_body="$3"
    local delete_failure_id="$4"
    local gh_log="$_STUB_DIR/outdated-tags-safety-gh.log"

    run env \
        PROJECT_ROOT="$PROJECT_ROOT" \
        LISTING_JSON="$listing_json" \
        PACKAGE_JSON="$package_json" \
        MANIFEST_BODY="$manifest_body" \
        DELETE_FAILURE_ID="$delete_failure_id" \
        GH_LOG="$gh_log" \
        GH_TOKEN="$GH_TOKEN" \
        OWNER="$OWNER" \
        DOCKERHUB_USERNAME="" \
        DOCKERHUB_TOKEN="" \
        DRY_RUN="false" \
        bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            build_valid_tags() { printf "%s\\n" "latest"; }
            gh() {
                if [[ "$*" == *"--method DELETE"* ]]; then
                    printf "DELETE:%s\\n" "$*" >> "$GH_LOG"
                    [[ -z "$DELETE_FAILURE_ID" || "$*" != *"/versions/$DELETE_FAILURE_ID"* ]] || return 1
                    return 0
                elif [[ "$*" == *"/versions"* ]]; then
                    printf "%s\\n" "$LISTING_JSON"
                else
                    printf "%s\\n" "$PACKAGE_JSON"
                fi
            }
            curl() {
                if [[ "$*" == *"/token?"* ]]; then printf "%s\\n" "{\"token\":\"registry-token\"}"
                elif [[ "$*" == *"/manifests/"* ]]; then printf "%s" "$MANIFEST_BODY"
                else echo "unexpected curl: $*" >&2; return 1
                fi
            }
            main stale
        '
}

run_orphan_phase_completion_case() {
    local listing_json="$1"
    local delete_failure_id="$2"
    local base64_abort_at="$3"
    local gh_log="$_STUB_DIR/orphan-phase-gh.log"
    local dockerhub_calls="$_STUB_DIR/orphan-phase-dockerhub.log"

    run env \
        PROJECT_ROOT="$PROJECT_ROOT" \
        LISTING_JSON="$listing_json" \
        DELETE_FAILURE_ID="$delete_failure_id" \
        BASE64_ABORT_AT="$base64_abort_at" \
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
                if [[ "$*" == *"--method DELETE"* ]]; then
                    printf "DELETE:%s\\n" "$*" >> "$GH_LOG"
                    [[ -z "$DELETE_FAILURE_ID" || "$*" != *"/versions/$DELETE_FAILURE_ID"* ]] || return 1
                    return 0
                fi
                if [[ "$*" != *"/versions"* ]]; then
                    printf "%s\\n" "{\"version_count\":$(command jq length <<< "$LISTING_JSON")}"
                    return 0
                fi
                printf "%s\\n" "$LISTING_JSON"
            }
            base64() {
                calls=0; [[ -f "$BASE64_CALLS" ]] && calls=$(<"$BASE64_CALLS")
                calls=$((calls + 1)); printf "%s\\n" "$calls" > "$BASE64_CALLS"
                [[ -z "$BASE64_ABORT_AT" || "$calls" -ne "$BASE64_ABORT_AT" ]] || { echo "base64: prepared record lost" >&2; return 1; }
                command base64 "$@"
            }
            export BASE64_CALLS="$GH_LOG.base64-calls"
            main stale
        '
}

# ---------------------------------------------------------------------------
# GHCR deletion safety: count-agreeing listing, completed parent deletion, one manifest
# ---------------------------------------------------------------------------

@test "an untagged record skipped after an obsolete DELETE failure is unassessed and skips Docker Hub" {
    local listing='[{"id":101,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":["stale"]}}},{"id":102,"name":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","metadata":{"container":{"tags":[]}}}]'
    local gh_log="$_STUB_DIR/orphan-phase-gh.log"
    local dockerhub_calls="$_STUB_DIR/orphan-phase-dockerhub.log"

    run_orphan_phase_completion_case "$listing" 101 ''

    [[ "$status" -eq 1 ]]
    [[ "$(<"$gh_log")" == *"/versions/101"* ]]
    [[ "$(<"$gh_log")" != *"/versions/102"* ]]
    [[ ! -s "$dockerhub_calls" ]]
    [[ "$output" == *"Orphan assessment skipped: a required orphan phase did not run"* ]]
    [[ "$output" == *"GHCR summary: kept=0, obsolete=1, orphan phase not assessed, delete_failures=1"* ]]
    [[ "$output" != *"GHCR summary: kept=0, obsolete=1, orphans="* ]]
    [[ "$output" == *"Packages assessed: 0"* ]]
    [[ "$output" == *"Docker Hub cleanup skipped: GHCR safety assessment was incomplete"* ]]
}

@test "an obsolete DELETE failure without an untagged record remains assessed and runs Docker Hub" {
    local listing='[{"id":101,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":["stale"]}}}]'
    local dockerhub_calls="$_STUB_DIR/orphan-phase-dockerhub.log"

    run_orphan_phase_completion_case "$listing" 101 ''

    [[ "$status" -eq 1 ]]
    [[ -s "$dockerhub_calls" ]]
    [[ "$output" != *"Orphan assessment skipped"* ]]
    [[ "$output" == *"GHCR summary: kept=0, obsolete=1, orphans=0, delete_failures=1"* ]]
    [[ "$output" == *"Packages assessed: 1"* ]]
}

@test "an untagged record skipped after an obsolete replay abort is unassessed and skips Docker Hub" {
    local listing='[{"id":101,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":["stale-first"]}}},{"id":102,"name":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","metadata":{"container":{"tags":["stale-second"]}}},{"id":103,"name":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","metadata":{"container":{"tags":[]}}}]'
    local gh_log="$_STUB_DIR/orphan-phase-gh.log"
    local dockerhub_calls="$_STUB_DIR/orphan-phase-dockerhub.log"

    run_orphan_phase_completion_case "$listing" '' 5

    [[ "$status" -eq 1 ]]
    [[ "$(<"$gh_log")" == *"/versions/101"* ]]
    [[ "$(<"$gh_log")" != *"/versions/102"* ]]
    [[ "$(<"$gh_log")" != *"/versions/103"* ]]
    [[ ! -s "$dockerhub_calls" ]]
    [[ "$output" == *"Orphan assessment skipped: a required orphan phase did not run"* ]]
    [[ "$output" == *"GHCR summary: kept=0, obsolete=1, orphan phase not assessed, delete_failures=0"* ]]
    [[ "$output" != *"GHCR summary: kept=0, obsolete=1, orphans="* ]]
    [[ "$output" == *"Packages assessed: 0"* ]]
}

@test "an incomplete package does not add an unassessed orphan count to the run total" {
    run env \
        PROJECT_ROOT="$PROJECT_ROOT" \
        GH_TOKEN="$GH_TOKEN" \
        OWNER="$OWNER" \
        DOCKERHUB_USERNAME="" \
        DOCKERHUB_TOKEN="" \
        DRY_RUN="false" \
        bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            build_valid_tags() { printf "%s\\n" "latest"; }
            gh() {
                if [[ "$*" == *"--method DELETE"* ]]; then
                    [[ "$*" != *"/stale/versions/101"* ]]
                    return
                elif [[ "$*" == *"/stale/versions"* ]]; then
                    printf "%s\\n" "[{\"id\":101,\"name\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"metadata\":{\"container\":{\"tags\":[\"stale\"]}}},{\"id\":102,\"name\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"metadata\":{\"container\":{\"tags\":[]}}}]"
                elif [[ "$*" == *"/complete/versions"* ]]; then
                    printf "%s\\n" "[{\"id\":201,\"name\":\"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"metadata\":{\"container\":{\"tags\":[\"stale\"]}}},{\"id\":202,\"name\":\"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\",\"metadata\":{\"container\":{\"tags\":[]}}}]"
                else
                    printf "%s\\n" "{\"version_count\":2}"
                fi
            }
            main stale complete
        '

    [[ "$status" -eq 1 ]]
    [[ "$output" == *"GHCR summary: kept=0, obsolete=1, orphan phase not assessed, delete_failures=1"* ]]
    [[ "$output" == *"GHCR summary: kept=0, obsolete=1, orphans=1, delete_failures=0"* ]]
    [[ "$output" == *"GHCR — kept: 0, obsolete: 2, orphans: 1"* ]]
}

@test "an obsolete replay abort without an untagged record remains assessed and runs Docker Hub" {
    local listing='[{"id":101,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":["stale-first"]}}},{"id":102,"name":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","metadata":{"container":{"tags":["stale-second"]}}}]'
    local dockerhub_calls="$_STUB_DIR/orphan-phase-dockerhub.log"

    run_orphan_phase_completion_case "$listing" '' 4

    [[ "$status" -eq 1 ]]
    [[ -s "$dockerhub_calls" ]]
    [[ "$output" != *"Orphan assessment skipped"* ]]
    [[ "$output" == *"GHCR summary: kept=0, obsolete=1, orphans=0, delete_failures=0"* ]]
    [[ "$output" == *"Packages assessed: 1"* ]]
}

@test "a completed GHCR assessment is assessed and runs Docker Hub" {
    local listing='[{"id":101,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":["stale"]}}}]'
    local dockerhub_calls="$_STUB_DIR/orphan-phase-dockerhub.log"

    run_orphan_phase_completion_case "$listing" '' ''

    [[ "$status" -eq 0 ]]
    [[ -s "$dockerhub_calls" ]]
    [[ "$output" == *"Packages assessed: 1"* ]]
}

@test "purge_ghcr skips orphan deletion when an obsolete parent DELETE fails" {
    local listing='[{"id":101,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":["stale"]}}},{"id":102,"name":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","metadata":{"container":{"tags":[]}}}]'
    local gh_log="$_STUB_DIR/outdated-tags-safety-gh.log"

    run_outdated_tags_safety_case "$listing" '{"version_count":2}' '' 101

    [[ "$status" -eq 1 ]]
    [[ "$(<"$gh_log")" == *"/versions/101"* ]]
    [[ "$(<"$gh_log")" != *"/versions/102"* ]]
    [[ "$output" == *"GHCR summary: kept=0, obsolete=1, orphan phase not assessed, delete_failures=1"* ]]
    [[ "$output" != *"GHCR summary: kept=0, obsolete=1, orphans="* ]]
}

@test "purge_ghcr deletes an orphan after all obsolete parent DELETEs succeed" {
    local listing='[{"id":101,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":["stale"]}}},{"id":102,"name":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","metadata":{"container":{"tags":[]}}}]'
    local gh_log="$_STUB_DIR/outdated-tags-safety-gh.log"

    run_outdated_tags_safety_case "$listing" '{"version_count":2}' '' ''

    [[ "$status" -eq 0 ]]
    [[ "$(<"$gh_log")" == *"/versions/101"* ]]
    [[ "$(<"$gh_log")" == *"/versions/102"* ]]
}

@test "purge_ghcr refuses a short listing before any deletion" {
    local listing='[{"id":101,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":["stale"]}}}]'
    local gh_log="$_STUB_DIR/outdated-tags-safety-gh.log"

    run_outdated_tags_safety_case "$listing" '{"version_count":2}' '' ''

    [[ "$status" -eq 1 ]]
    [[ ! -s "$gh_log" ]]
    [[ "$output" == *"GHCR version listing count does not agree with package version_count or version_count was invalid"* ]]
}

@test "purge_ghcr accepts a listing that matches the reported version_count" {
    local listing='[{"id":101,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":["stale"]}}},{"id":102,"name":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","metadata":{"container":{"tags":[]}}}]'
    local gh_log="$_STUB_DIR/outdated-tags-safety-gh.log"

    run_outdated_tags_safety_case "$listing" '{"version_count":2}' '' ''

    [[ "$status" -eq 0 ]]
    [[ "$(<"$gh_log")" == *"/versions/101"* ]]
    [[ "$(<"$gh_log")" == *"/versions/102"* ]]
}

@test "purge_ghcr refuses absent, null, and non-numeric package version_count values" {
    local listing='[{"id":101,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":["stale"]}}}]'
    local package_json gh_log

    for package_json in '{}' '{"version_count":null}' '{"version_count":"1"}'; do
        gh_log="$_STUB_DIR/outdated-tags-safety-gh.log"
        run_outdated_tags_safety_case "$listing" "$package_json" '' ''
        [[ "$status" -eq 1 ]]
        [[ ! -s "$gh_log" ]]
        [[ "$output" == *"GHCR version listing count does not agree with package version_count or version_count was invalid"* ]]
    done
}

@test "purge_ghcr refuses a manifest response containing two JSON documents before DELETE" {
    local listing='[{"id":101,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":["latest"]}}},{"id":102,"name":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","metadata":{"container":{"tags":["stale"]}}}]'
    local gh_log="$_STUB_DIR/outdated-tags-safety-gh.log"

    run_outdated_tags_safety_case "$listing" '{"version_count":2}' '{"mediaType":"application/vnd.oci.image.manifest.v1+json"}
{"mediaType":"application/vnd.oci.image.manifest.v1+json"}' ''

    [[ "$status" -eq 1 ]]
    [[ ! -s "$gh_log" ]]
    [[ "$output" == *"must contain exactly one JSON value"* ]]
}

@test "purge_ghcr refuses an empty manifest response before DELETE" {
    local listing='[{"id":101,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":["latest"]}}},{"id":102,"name":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","metadata":{"container":{"tags":["stale"]}}}]'
    local gh_log="$_STUB_DIR/outdated-tags-safety-gh.log"

    run_outdated_tags_safety_case "$listing" '{"version_count":2}' '' ''

    [[ "$status" -eq 1 ]]
    [[ ! -s "$gh_log" ]]
    [[ "$output" == *"must contain exactly one JSON value"* ]]
}

# ---------------------------------------------------------------------------
# GHCR manifest-protection contract (#1338)
# ---------------------------------------------------------------------------

@test "purge_ghcr refuses a kept OCI index with a nested OCI index child before DELETE" {
    run_manifest_protection_refusal \
        '{"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"mediaType":"application/vnd.oci.image.index.v1+json","digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]}' \
        "nested OCI index"
}

@test "purge_ghcr refuses a kept OCI index with a nested Docker manifest list child before DELETE" {
    run_manifest_protection_refusal \
        '{"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"mediaType":"application/vnd.docker.distribution.manifest.list.v2+json","digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]}' \
        "nested Docker manifest list"
}

@test "purge_ghcr refuses an untyped sibling after a valid manifest child before DELETE" {
    run_manifest_protection_refusal \
        '{"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},{"digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}]}' \
        "child descriptor 1 has no mediaType"
}

@test "purge_ghcr refuses a child with an unsupported mediaType before DELETE" {
    run_manifest_protection_refusal \
        '{"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"mediaType":"application/vnd.example.unknown.v1+json","digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]}' \
        "unsupported mediaType"
}

@test "purge_ghcr refuses children with missing or newline-tainted digests before DELETE" {
    run_manifest_protection_refusal \
        '{"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json"}]}' \
        "child descriptor 0 has no digest"
    run_manifest_protection_refusal \
        '{"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n"}]}' \
        "child descriptor 0 has a malformed digest"
}

@test "purge_ghcr refuses top-level manifests with missing or unsupported mediaType before DELETE" {
    run_manifest_protection_refusal \
        '{"manifests":[]}' \
        "top-level manifest has no mediaType"
    run_manifest_protection_refusal \
        '{"mediaType":"application/vnd.example.unknown.v1+json","manifests":[]}' \
        "top-level manifest has unsupported mediaType"
}

@test "purge_ghcr refuses a kept OCI index without manifests before DELETE" {
    run_manifest_protection_refusal \
        '{"mediaType":"application/vnd.oci.image.index.v1+json"}' \
        "top-level OCI index has no manifests field"
}

@test "purge_ghcr refuses a kept Docker manifest list without manifests before DELETE" {
    run_manifest_protection_refusal \
        '{"mediaType":"application/vnd.docker.distribution.manifest.list.v2+json"}' \
        "top-level Docker manifest list has no manifests field"
}

@test "purge_ghcr refuses indexes whose manifests field is not an array before DELETE" {
    run_manifest_protection_refusal \
        '{"mediaType":"application/vnd.oci.image.index.v1+json","manifests":null}' \
        "top-level OCI index has a non-array manifests field"
    run_manifest_protection_refusal \
        '{"mediaType":"application/vnd.oci.image.index.v1+json","manifests":{}}' \
        "top-level OCI index has a non-array manifests field"
}

@test "purge_ghcr refuses leaf manifests that carry manifests before DELETE" {
    run_manifest_protection_refusal \
        '{"mediaType":"application/vnd.oci.image.manifest.v1+json","manifests":[]}' \
        "top-level OCI image manifest has a manifests field"
    run_manifest_protection_refusal \
        '{"mediaType":"application/vnd.docker.distribution.manifest.v2+json","manifests":[]}' \
        "top-level Docker image manifest has a manifests field"
}

@test "purge_ghcr refuses a kept leaf manifest carrying a top-level subject object before DELETE" {
    run_manifest_protection_refusal \
        '{"mediaType":"application/vnd.oci.image.manifest.v1+json","subject":{"digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}' \
        "top-level manifest has an unresolved subject"
}

@test "purge_ghcr refuses a kept index carrying a top-level subject before DELETE" {
    run_manifest_protection_refusal \
        '{"mediaType":"application/vnd.oci.image.index.v1+json","subject":{},"manifests":[]}' \
        "top-level manifest has an unresolved subject"
}

@test "purge_ghcr refuses top-level subject strings and nulls before DELETE" {
    run_manifest_protection_refusal \
        '{"mediaType":"application/vnd.oci.image.manifest.v1+json","subject":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}' \
        "top-level manifest has an unresolved subject"
    run_manifest_protection_refusal \
        '{"mediaType":"application/vnd.oci.image.manifest.v1+json","subject":null}' \
        "top-level manifest has an unresolved subject"
}

@test "purge_ghcr protects plain-manifest children and deletes only a genuinely unreferenced orphan" {
    local gh_log="$_STUB_DIR/manifest-protection-gh.log"

    run env \
        PROJECT_ROOT="$PROJECT_ROOT" \
        GH_LOG="$gh_log" \
        GH_TOKEN="$GH_TOKEN" \
        OWNER="$OWNER" \
        DOCKERHUB_USERNAME="" \
        DOCKERHUB_TOKEN="" \
        DRY_RUN="false" \
        bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            build_valid_tags() { printf "%s\\n" "latest"; }
            gh() {
                if [[ "$*" == *"--method DELETE"* ]]; then printf "DELETE:%s\\n" "$*" >> "$GH_LOG"; return 0; fi
                if [[ "$*" != *"/versions"* ]]; then printf "%s\\n" "{\"version_count\":4}"; return 0; fi
                printf "%s\\n" "[{\"id\":101,\"name\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"metadata\":{\"container\":{\"tags\":[\"latest\"]}}},{\"id\":102,\"name\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"metadata\":{\"container\":{\"tags\":[]}}},{\"id\":103,\"name\":\"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"metadata\":{\"container\":{\"tags\":[]}}},{\"id\":104,\"name\":\"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\",\"metadata\":{\"container\":{\"tags\":[]}}}]"
            }
            curl() {
                if [[ "$*" == *"/token?"* ]]; then printf "%s\\n" "{\"token\":\"registry-token\"}"
                elif [[ "$*" == *"/manifests/"* ]]; then printf "%s\\n" "{\"mediaType\":\"application/vnd.oci.image.index.v1+json\",\"manifests\":[{\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"digest\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"},{\"mediaType\":\"application/vnd.docker.distribution.manifest.v2+json\",\"digest\":\"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\"}]}"
                else echo "unexpected curl: $*" >&2; return 1
                fi
            }
            main protected
        '

    [[ "$status" -eq 0 ]]
    [[ "$(<"$gh_log")" == *"/versions/104"* ]]
    [[ "$(<"$gh_log")" != *"/versions/102"* ]]
    [[ "$(<"$gh_log")" != *"/versions/103"* ]]
}

@test "purge_ghcr accepts a leaf manifest without subject and deletes a genuinely unreferenced orphan" {
    local gh_log="$_STUB_DIR/manifest-protection-gh.log"

    run env \
        PROJECT_ROOT="$PROJECT_ROOT" \
        GH_LOG="$gh_log" \
        GH_TOKEN="$GH_TOKEN" \
        OWNER="$OWNER" \
        DOCKERHUB_USERNAME="" \
        DOCKERHUB_TOKEN="" \
        DRY_RUN="false" \
        bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            build_valid_tags() { printf "%s\\n" "latest"; }
            gh() {
                if [[ "$*" == *"--method DELETE"* ]]; then printf "DELETE:%s\\n" "$*" >> "$GH_LOG"; return 0; fi
                if [[ "$*" != *"/versions"* ]]; then printf "%s\\n" "{\"version_count\":2}"; return 0; fi
                printf "%s\\n" "[{\"id\":101,\"name\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"metadata\":{\"container\":{\"tags\":[\"latest\"]}}},{\"id\":102,\"name\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"metadata\":{\"container\":{\"tags\":[]}}}]"
            }
            curl() {
                if [[ "$*" == *"/token?"* ]]; then printf "%s\\n" "{\"token\":\"registry-token\"}"
                elif [[ "$*" == *"/manifests/"* ]]; then printf "%s\\n" "{\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\"}"
                else echo "unexpected curl: $*" >&2; return 1
                fi
            }
            main protected
        '

    [[ "$status" -eq 0 ]]
    [[ "$(<"$gh_log")" == *"/versions/102"* ]]
    [[ "$output" == *"GHCR summary: kept=1, obsolete=0, orphans=1, delete_failures=0"* ]]
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
    run ! is_valid_tag "9.9.9" "$valid_tags"
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
    run ! is_valid_tag "buildcache-1.0.0-amd64" "$valid_tags"
}

@test "is_valid_tag: buildcache-<rotated-out-tag>-arm64 is purged when base tag is invalid" {
    local valid_tags
    valid_tags=$(make_valid_tags "2.334.0" "latest" "buildcache")
    run ! is_valid_tag "buildcache-1.0.0-arm64" "$valid_tags"
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
    run ! is_valid_tag "buildcache-2.334.0-dev-amd64" "$valid_tags"
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
    run ! is_valid_tag "buildcache-trixie-amd64" "$valid_tags"
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
    run ! is_valid_tag "buildcache-foo-amd64-bar-amd64" "$valid_tags"
}

# ---------------------------------------------------------------------------
# Malformed / edge cases
# ---------------------------------------------------------------------------

@test "is_valid_tag: buildcache tag without arch suffix is invalid" {
    # buildcache-2.334.0 (no -amd64/-arm64) → no recognised arch suffix → invalid
    local valid_tags
    valid_tags=$(make_valid_tags "2.334.0" "latest" "buildcache")
    run ! is_valid_tag "buildcache-2.334.0" "$valid_tags"
}

@test "is_valid_tag: double-prefix buildcache-buildcache- is invalid" {
    local valid_tags
    valid_tags=$(make_valid_tags "2.334.0" "latest" "buildcache")
    run ! is_valid_tag "buildcache-buildcache-2.334.0-amd64" "$valid_tags"
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

@test "unfiltered main refuses an empty container discovery before making pruning decisions" {
    local stub_root="$BATS_TEST_TMPDIR/empty-container-discovery"
    local gh_calls="$BATS_TEST_TMPDIR/empty-container-discovery-gh-calls"
    mkdir -p "$stub_root"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$stub_root/make"
    chmod +x "$stub_root/make"

    run env \
        PROJECT_ROOT="$PROJECT_ROOT" \
        STUB_ROOT="$stub_root" \
        GH_CALLS="$gh_calls" \
        GH_TOKEN="$GH_TOKEN" \
        OWNER="$OWNER" \
        DRY_RUN="false" \
        bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            script_root() { printf "%s\\n" "$STUB_ROOT"; }
            gh() { printf "%s\\n" "$*" >> "$GH_CALLS"; }
            main
        '

    [ "$status" -eq 1 ]
    [[ "$output" == *"Could not enumerate containers; refusing to make pruning decisions"* ]]
    [[ "$output" != *"Purge Summary"* ]]
    [ ! -e "$gh_calls" ]
}

@test "explicitly empty container selection refuses before making API calls" {
    local stub_root="$BATS_TEST_TMPDIR/empty-explicit-container"
    local gh_calls="$BATS_TEST_TMPDIR/empty-explicit-container-gh-calls"
    mkdir -p "$stub_root"

    run env \
        PROJECT_ROOT="$PROJECT_ROOT" \
        STUB_ROOT="$stub_root" \
        GH_CALLS="$gh_calls" \
        GH_TOKEN="$GH_TOKEN" \
        OWNER="$OWNER" \
        DRY_RUN="false" \
        bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            script_root() { printf "%s\\n" "$STUB_ROOT"; }
            gh() { printf "%s\\n" "$*" >> "$GH_CALLS"; }
            for selection in "" "   "; do
                if main "$selection"; then
                    printf "main accepted an empty or whitespace selection\\n" >&2
                    exit 1
                fi
            done
            [ ! -e "$GH_CALLS" ]
        '

    [ "$status" -eq 0 ]
    [[ "$output" == *"Could not enumerate containers; refusing to make pruning decisions"* ]]
    [[ "$output" != *"Purge Summary"* ]]
    [ ! -e "$gh_calls" ]
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
                if [[ "$*" != *"/versions"* ]]; then printf "%s\\n" "{\"version_count\":2}"; return 0; fi
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

@test "cleanup workflow schedules weekly registry pruning" {
    local workflow_path
    workflow_path="$PROJECT_ROOT/.github/workflows/cleanup-registry.yaml"

    run yq -r '.on.schedule | length' "$workflow_path"
    [ "$status" -eq 0 ]
    if [ "$output" != '1' ]; then
        printf "FAIL: expected exactly one cleanup schedule, got %s\n" "$output" >&2
        return 1
    fi

    run yq -r '.on.schedule[0].cron' "$workflow_path"
    [ "$status" -eq 0 ]
    if [ "$output" != '17 3 * * 1' ]; then
        printf "FAIL: expected weekly registry prune cron '17 3 * * 1', got %s\n" "$output" >&2
        return 1
    fi

}

@test "cleanup workflow serializes registry cleanup runs" {
    local workflow_path
    workflow_path="$PROJECT_ROOT/.github/workflows/cleanup-registry.yaml"

    run yq -r '.concurrency.group' "$workflow_path"
    [ "$status" -eq 0 ]
    if [ "$output" != 'cleanup-registry' ]; then
        printf 'FAIL: expected cleanup concurrency group cleanup-registry, got %s\n' "$output" >&2
        return 1
    fi

    run yq -r '.concurrency.cancel-in-progress' "$workflow_path"
    [ "$status" -eq 0 ]
    if [ "$output" != 'false' ]; then
        printf 'FAIL: expected cleanup cancel-in-progress false, got %s\n' "$output" >&2
        return 1
    fi

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
    [[ "$purge_step" == *"github.event_name == 'schedule' && 'true' || inputs.dry_run || 'false'"* ]]

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
                if [[ "$*" != *"/versions"* ]]; then printf "%s\\n" "{\"version_count\":1}"; return 0; fi
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
                if [[ "$*" != *"/versions"* ]]; then printf "%s\\n" "{\"version_count\":1}"; return 0; fi
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
                if [[ "$*" != *"/versions"* ]]; then printf "%s\\n" "{\"version_count\":1}"; return 0; fi
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
                if [[ "$*" != *"/versions"* ]]; then printf "%s\\n" "{\"version_count\":2}"; return 0; fi
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
                if [[ "$*" != *"/versions"* ]]; then printf "%s\n" "{\"version_count\":$(jq length <<< "$RESPONSE_JSON")}"; return 0; fi
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
            gh() { if [[ "$*" == *"/versions"* ]]; then printf "%s\\n" "[{\"id\":101,\"name\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"metadata\":{\"container\":{}}}]"; else printf "%s\\n" "{\"version_count\":1}"; fi; }
            purge_ghcr malformed latest
        '

    [[ "$status" -eq 14 ]]

    local real_jq
    real_jq="$(command -v jq)"
    cat > "$_STUB_DIR/jq" <<'EOF'
#!/usr/bin/env bash
for argument in "$@"; do
    [[ "$argument" == *$'\n    validate_outdated_tags_versions' ]] && exit 137
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
            gh() { if [[ "$*" == *"/versions"* ]]; then printf "%s\\n" "[{\"id\":101,\"name\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"metadata\":{\"container\":{\"tags\":[]}}}]"; else printf "%s\\n" "{\"version_count\":1}"; fi; }
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
                if [[ "$*" != *"/versions"* ]]; then printf "%s\n" "{\"version_count\":1}"; return 0; fi
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
    [[ "$output" == *"latest"* ]]
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

@test "build_valid_tags validates the shared helper routing input length" {
    local variant_128 variant_129 root_dir build_json
    variant_128=$(printf '%*s' 128 '' | tr ' ' a)
    variant_129=$(printf '%*s' 129 '' | tr ' ' a)
    root_dir="$BATS_TEST_TMPDIR/build-alias-length-root"
    mkdir -p "$root_dir"
    export ROOT_DIR="$root_dir"
    build_json="[{\"tag\":\"release\",\"variant\":\"$variant_128\",\"flavor\":\"\",\"os\":\"linux\",\"is_default\":true,\"is_latest_version\":true}]"
    printf '%s\n' '#!/usr/bin/env bash' "printf '%s\\n' '$build_json'" > "$root_dir/make"
    chmod +x "$root_dir/make"

    run build_valid_tags example

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"latest"* ]]

    run_invalid_build_case "[{\"tag\":\"release\",\"variant\":\"$variant_129\",\"flavor\":\"\",\"os\":\"linux\",\"is_default\":true,\"is_latest_version\":true}]"
}
