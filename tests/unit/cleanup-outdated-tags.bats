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

run_dockerhub_fixture() {
    local page_one="$1"
    local page_two="$2"
    local delete_http_code="$3"
    local dry_run="$4"
    local valid_tags="$5"
    local dockerhub_dry_run="${6-false}"
    local -a environment=(env)

    if [[ "$dockerhub_dry_run" == unset ]]; then
        environment+=(-u DOCKERHUB_DRY_RUN)
    else
        environment+=("DOCKERHUB_DRY_RUN=$dockerhub_dry_run")
    fi

    DH_CURL_LOG="$BATS_TEST_TMPDIR/dockerhub-curl.log"
    : > "$DH_CURL_LOG"
    run "${environment[@]}" \
        PROJECT_ROOT="$PROJECT_ROOT" \
        DH_PAGE_ONE="$page_one" \
        DH_PAGE_TWO="$page_two" \
        DH_DELETE_HTTP_CODE="$delete_http_code" \
        DH_CURL_LOG="$DH_CURL_LOG" \
        GH_TOKEN="$GH_TOKEN" \
        OWNER="$OWNER" \
        DOCKERHUB_USERNAME="test-user" \
        DOCKERHUB_TOKEN="test-password" \
        DRY_RUN="$dry_run" \
        DH_VALID_TAGS="$valid_tags" \
        bash -c '
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            LISTING_FAILURE=10 PROCESSING_FAILURE=11 DELETE_FAILURE=12
            write_listing() {
                local body="$1" output_file="" curl_arg previous=""
                for curl_arg in "$@"; do
                    if [[ "$previous" == "--output" ]]; then output_file="$curl_arg"; break; fi
                    previous="$curl_arg"
                done
                [[ -n "$output_file" ]] || { echo "listing did not use --output" >&2; return 1; }
                printf "%s" "$body" > "$output_file"
            }
            curl() {
                printf "%s\\n" "$*" >> "$DH_CURL_LOG"
                case "$*" in
                    *"/users/login"*) printf "%s\\n" "{\"token\":\"fixture-jwt\"}" ;;
                    *"auth.docker.io/token"*) printf "%s\\n" "{\"token\":\"fixture-registry-jwt\"}" ;;
                    *"registry-1.docker.io"*"/manifests/"*)
                        header_file="" previous=""
                        for curl_arg in "$@"; do
                            [[ "$previous" != "-D" ]] || header_file="$curl_arg"
                            previous="$curl_arg"
                        done
                        [[ -n "$header_file" ]] || return 1
                        printf "Docker-Content-Digest: sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\\r\\n" > "$header_file"
                        printf "%s" 200
                        ;;
                    *"ghcr.io/token"*) printf "%s\\n" "{\"token\":\"fixture-ghcr-jwt\"}" ;;
                    *"ghcr.io/v2/"*"/manifests/"*) printf "%s" 404 ;;
                    *"page_size=100"*) write_listing "$DH_PAGE_ONE" "$@" ;;
                    *"page=2"*) write_listing "$DH_PAGE_TWO" "$@" ;;
                    *"-X DELETE"*) printf '%s' "$DH_DELETE_HTTP_CODE" ;;
                    *) echo "unexpected curl request: $*" >&2; return 1 ;;
                esac
            }
            purge_dockerhub app "$DH_VALID_TAGS"
        '
}

run_dockerhub_manifest_authority_case() {
    local ghcr_manifest_status="$1"
    local curl_log="$BATS_TEST_TMPDIR/dockerhub-manifest-authority-curl.log"
    : > "$curl_log"

    run env PROJECT_ROOT="$PROJECT_ROOT" GH_TOKEN="$GH_TOKEN" OWNER="$OWNER" \
        DOCKERHUB_USERNAME=test-user DOCKERHUB_TOKEN=test-password \
        GHCR_MANIFEST_STATUS="$ghcr_manifest_status" CURL_LOG="$curl_log" \
        DRY_RUN=true DOCKERHUB_DRY_RUN=true bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            build_valid_tags() { printf "%s\\n" latest; }
            purge_ghcr() { printf "%s\\n" "0|0|0|0|0"; }
            gh() {
                if [[ "$*" == *"/versions"* ]]; then printf "%s\\n" "[]";
                else printf "%s\\n" "{\"version_count\":0}"; fi
            }
            curl() {
                printf "%s\\n" "$*" >> "$CURL_LOG"
                case "$*" in
                    *"/users/login"*) printf "%s\\n" "{\"token\":\"hub-jwt\"}" ;;
                    *"auth.docker.io/token"*) printf "%s\\n" "{\"token\":\"registry-jwt\"}" ;;
                    *"registry-1.docker.io"*)
                        header_file="" previous=""
                        for curl_arg in "$@"; do [[ "$previous" != "-D" ]] || header_file="$curl_arg"; previous="$curl_arg"; done
                        printf "Docker-Content-Digest: sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\\r\\n" > "$header_file"
                        printf "%s" 200
                        ;;
                    *"ghcr.io/token"*) printf "%s\\n" "{\"token\":\"ghcr-jwt\"}" ;;
                    *"ghcr.io/v2/"*"/manifests/"*) printf "%s" "$GHCR_MANIFEST_STATUS" ;;
                    *"page_size=100"*)
                        output_file="" previous=""
                        for curl_arg in "$@"; do [[ "$previous" != "--output" ]] || output_file="$curl_arg"; previous="$curl_arg"; done
                        printf "%s" "{\"count\":1,\"results\":[{\"name\":\"obsolete\"}],\"next\":null}" > "$output_file"
                        ;;
                    *) echo "unexpected curl request: $*" >&2; return 1 ;;
                esac
            }
            main app
        '
}

@test "Docker Hub keeps a candidate when the GHCR re-list omits it but its manifest is live" {
    run_dockerhub_manifest_authority_case 200

    [[ "$status" -eq 0 ]]
    [[ "$output" != *"Would delete Docker Hub tag: obsolete"* ]]
    [[ "$output" == *"kept_by_ghcr_digest=1, candidates=0"* ]]
}

@test "Docker Hub keeps the candidate when GHCR confirms manifest absence" {
    run_dockerhub_manifest_authority_case 404

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Would delete Docker Hub tag: obsolete"* ]]
    [[ "$output" == *"candidates=1"* ]]
}

@test "Docker Hub keeps and fails a candidate when the GHCR manifest probe fails" {
    run_dockerhub_manifest_authority_case 500

    [[ "$status" -eq 1 ]]
    [[ "$output" != *"Would delete Docker Hub tag: obsolete"* ]]
    [[ "$output" == *"Could not confirm GHCR manifest absence"* ]]
    [[ "$output" == *"delete_failures=1"* ]]
}

run_dockerhub_delete_reread_case() {
    local reread_status="$1" reread_digest="$2"
    local delete_log="$BATS_TEST_TMPDIR/dockerhub-reread-delete.log"
    local read_log="$BATS_TEST_TMPDIR/dockerhub-reread-manifest.log"
    : > "$delete_log"
    : > "$read_log"

    run env PROJECT_ROOT="$PROJECT_ROOT" GH_TOKEN="$GH_TOKEN" OWNER="$OWNER" \
        DOCKERHUB_USERNAME=test-user DOCKERHUB_TOKEN=test-password \
        REREAD_STATUS="$reread_status" REREAD_DIGEST="$reread_digest" DELETE_LOG="$delete_log" READ_LOG="$read_log" \
        DRY_RUN=false DOCKERHUB_DRY_RUN=false bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            build_valid_tags() { printf "%s\\n" latest; }
            purge_ghcr() { printf "%s\\n" "0|0|0|0|0"; }
            gh() {
                if [[ "$*" == *"/versions"* ]]; then printf "%s\\n" "[]";
                else printf "%s\\n" "{\"version_count\":0}"; fi
            }
            curl() {
                case "$*" in
                    *"/users/login"*) printf "%s\\n" "{\"token\":\"hub-jwt\"}" ;;
                    *"auth.docker.io/token"*) printf "%s\\n" "{\"token\":\"registry-jwt\"}" ;;
                    *"registry-1.docker.io"*)
                        printf read >> "$READ_LOG"
                        header_file="" previous=""
                        for curl_arg in "$@"; do [[ "$previous" != "-D" ]] || header_file="$curl_arg"; previous="$curl_arg"; done
                        if [[ "$(wc -c < "$READ_LOG")" -eq 4 ]]; then
                            printf "Docker-Content-Digest: sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\\r\\n" > "$header_file"
                            printf "%s" 200
                        elif [[ "$REREAD_STATUS" == 200 ]]; then
                            printf "Docker-Content-Digest: %s\\r\\n" "$REREAD_DIGEST" > "$header_file"
                            printf "%s" 200
                        else
                            printf "%s" "$REREAD_STATUS"
                        fi
                        ;;
                    *"ghcr.io/token"*) printf "%s\\n" "{\"token\":\"ghcr-jwt\"}" ;;
                    *"ghcr.io/v2/"*"/manifests/"*) printf "%s" 404 ;;
                    *"page_size=100"*)
                        output_file="" previous=""
                        for curl_arg in "$@"; do [[ "$previous" != "--output" ]] || output_file="$curl_arg"; previous="$curl_arg"; done
                        printf "%s" "{\"count\":1,\"results\":[{\"name\":\"obsolete\"}],\"next\":null}" > "$output_file"
                        ;;
                    *"-X DELETE"*) printf "%s\\n" "$*" >> "$DELETE_LOG"; printf "%s" 204 ;;
                    *) echo "unexpected curl request: $*" >&2; return 1 ;;
                esac
            }
            main app
        '
}

@test "Docker Hub refuses deletion when the manifest digest changed after assessment" {
    run_dockerhub_delete_reread_case 200 'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

    [[ "$status" -eq 1 ]]
    [[ ! -s "$BATS_TEST_TMPDIR/dockerhub-reread-delete.log" ]]
    [[ "$output" == *"Docker Hub tag changed or was unavailable: obsolete"* ]]
}

@test "Docker Hub refuses deletion when the manifest re-read is 404" {
    run_dockerhub_delete_reread_case 404 ''

    [[ "$status" -eq 1 ]]
    [[ ! -s "$BATS_TEST_TMPDIR/dockerhub-reread-delete.log" ]]
    [[ "$output" == *"Docker Hub tag changed or was unavailable: obsolete"* ]]
}

@test "Docker Hub credentials absent skips the GHCR digest re-list and returns no-op counters" {
    local ghcr_relist_log="$BATS_TEST_TMPDIR/ghcr-relist.log"
    : > "$ghcr_relist_log"

    run env PROJECT_ROOT="$PROJECT_ROOT" GH_TOKEN="$GH_TOKEN" OWNER="$OWNER" \
        DOCKERHUB_USERNAME= DOCKERHUB_TOKEN= GHCR_RELIST_LOG="$ghcr_relist_log" \
        DRY_RUN=true bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            build_valid_tags() { printf "%s\\n" latest; }
            purge_ghcr() { printf "%s\\n" "0|0|0|0|0"; }
            list_tagged_ghcr_digests() { printf called >> "$GHCR_RELIST_LOG"; }
            main app
            purge_dockerhub app latest
        '

    [[ "$status" -eq 0 ]]
    [[ ! -s "$ghcr_relist_log" ]]
    [[ "$output" == *$'0|0|0|0'* ]]
}

@test "Docker Hub cleanup plans obsolete tags unless DOCKERHUB_DRY_RUN is false" {
    local listing='{"count":1,"results":[{"name":"obsolete"}],"next":null}'
    local dockerhub_dry_run

    for dockerhub_dry_run in unset true; do
        run_dockerhub_fixture "$listing" '' 204 false latest "$dockerhub_dry_run"

        [[ "$status" -eq 0 ]]
        [[ "$output" == *"[DRY RUN] Would delete Docker Hub tag: obsolete"* ]]
        [[ "$output" == *"1|1|0|0"* ]]
        [[ "$(grep -c -- '-X DELETE' "$DH_CURL_LOG")" -eq 0 ]]
    done

    run_dockerhub_fixture "$listing" '' 204 false latest false

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"1|1|1|0"* ]]
    [[ "$(grep -c -- '-X DELETE' "$DH_CURL_LOG")" -eq 1 ]]
}

@test "Docker Hub deletion primitive refuses without DOCKERHUB_DRY_RUN opt-in" {
    run env -u DOCKERHUB_DRY_RUN PROJECT_ROOT="$PROJECT_ROOT" GH_TOKEN="$GH_TOKEN" OWNER="$OWNER" DRY_RUN=false bash -c '
        source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
        curl() { printf "%s" 204; }
        _cleanup_outdated_tags_delete dockerhub-tag fixture-jwt app obsolete
    '

    [[ "$status" -eq 64 ]]
    [[ "$output" == *"cleanup deletion refused: DOCKERHUB_DRY_RUN must be false"* ]]
}

@test "Docker Hub cleanup reads every page before deleting an obsolete tag" {
    run_dockerhub_fixture \
        '{"count":2,"results":[{"name":"latest"}],"next":"https://hub.docker.com/v2/repositories/test-user/app/tags?page=2"}' \
        '{"count":2,"results":[{"name":"obsolete"}],"next":null}' \
        204 false latest

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"1|1|1|0"* ]]
    [[ "$(<"$DH_CURL_LOG")" == *"page=2"* ]]
    [[ "$(<"$DH_CURL_LOG")" == *"/tags/obsolete/"* ]]
}

@test "Docker Hub cleanup requires count on every listing page" {
    run_dockerhub_fixture '{"results":[{"name":"latest"}],"next":null}' '' 204 false latest

    [[ "$status" -eq 10 ]]
    [[ "$output" == *"listing page was malformed"* ]]
    [[ "$(<"$DH_CURL_LOG")" != *"-X DELETE"* ]]
}

@test "Docker Hub cleanup requires next on every listing page" {
    run_dockerhub_fixture '{"count":1,"results":[{"name":"latest"}]}' '' 204 false latest

    [[ "$status" -eq 10 ]]
    [[ "$output" == *"listing page was malformed"* ]]
    [[ "$(<"$DH_CURL_LOG")" != *"-X DELETE"* ]]
}

@test "Docker Hub cleanup refuses an exponential count before deleting from the raw listing response" {
    run_dockerhub_fixture '{"count":1e20,"results":[{"name":"obsolete"}],"next":null}' '' 204 false latest

    [[ "$status" -eq 10 ]]
    [[ "$output" == *"not a canonical decimal at the Bash boundary"* ]]
    [[ "$(<"$DH_CURL_LOG")" != *"-X DELETE"* ]]
}

@test "Docker Hub cleanup accepts an exponent that jq normalizes to a canonical Bash decimal" {
    run_dockerhub_fixture '{"count":1e0,"results":[{"name":"obsolete"}],"next":null}' '' 204 false latest

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"1|1|1|0"* ]]
    [[ "$(<"$DH_CURL_LOG")" == *"-X DELETE"* ]]
}

@test "Docker Hub cleanup refuses a count above MAX_TAGS before accumulating tags" {
    local listing
    listing=$(printf '{"count":%s,"results":[{"name":"obsolete"}],"next":null}' "$((MAX_TAGS + 1))")

    run_dockerhub_fixture "$listing" '' 204 false latest

    [[ "$status" -eq 10 ]]
    [[ "$output" == *"count exceeds MAX_TAGS=$MAX_TAGS"* ]]
    [[ "$(<"$DH_CURL_LOG")" != *"-X DELETE"* ]]
}

@test "Docker Hub cleanup refuses non-integral and negative counts before deleting" {
    local listing
    for listing in \
        '{"count":1.5,"results":[{"name":"obsolete"}],"next":null}' \
        '{"count":-1,"results":[{"name":"obsolete"}],"next":null}'; do
        run_dockerhub_fixture "$listing" '' 204 false latest
        [[ "$status" -eq 10 ]]
        [[ "$output" == *"listing page was malformed"* ]]
        [[ "$(<"$DH_CURL_LOG")" != *"-X DELETE"* ]]
    done
}

@test "Docker Hub cleanup refuses unsafe continuations before sending its token" {
    local continuation listing
    for continuation in \
        'https://example.invalid/tags?page=2' \
        'http://hub.docker.com/v2/repositories/test-user/app/tags?page=2' \
        'https://hub.docker.com/v2/repositories/test-user/other/tags?page=2'; do
        listing=$(jq -cn --arg next "$continuation" '{count: 2, results: [{name: "obsolete"}], next: $next}')
        run_dockerhub_fixture "$listing" '' 204 false latest
        [[ "$status" -eq 10 ]]
        [[ "$output" == *"continuation was not for this repository"* ]]
        [[ "$(<"$DH_CURL_LOG")" != *"$continuation"* ]]
        [[ "$(<"$DH_CURL_LOG")" != *"-X DELETE"* ]]
    done
}

@test "Docker Hub cleanup refuses a non-terminal page that adds no names before deleting" {
    run_dockerhub_fixture \
        '{"count":1,"results":[],"next":"https://hub.docker.com/v2/repositories/test-user/app/tags?page=2"}' \
        '' 204 false latest

    [[ "$status" -eq 10 ]]
    [[ "$output" == *"continuation made no valid progress"* ]]
    [[ "$(<"$DH_CURL_LOG")" != *"-X DELETE"* ]]
}

@test "Docker Hub cleanup rejects every invalid entry before classifying or deleting" {
    local results listing
    for results in '[null]' '[{}]' '[{"name":42}]' '[{"name":"not/a-tag"}]'; do
        listing=$(jq -cn --argjson results "$results" '{count: 1, results: $results, next: null}')
        run_dockerhub_fixture "$listing" '' 204 false latest
        [[ "$status" -eq 10 ]]
        [[ "$output" == *"listing page was malformed"* ]]
        [[ "$(<"$DH_CURL_LOG")" != *"-X DELETE"* ]]
    done
}

@test "Docker Hub cleanup rejects a reported total that disagrees with accumulated entries" {
    run_dockerhub_fixture '{"count":2,"results":[{"name":"obsolete"}],"next":null}' '' 204 false latest

    [[ "$status" -eq 10 ]]
    [[ "$output" == *"count does not agree with accumulated entries"* ]]
    [[ "$(<"$DH_CURL_LOG")" != *"-X DELETE"* ]]
}

@test "Docker Hub cleanup records a 404 DELETE without counting it as successful" {
    run_dockerhub_fixture '{"count":1,"results":[{"name":"obsolete"}],"next":null}' '' 404 false latest

    [[ "$status" -eq 12 ]]
    [[ "$output" == *"1|1|0|1"* ]]
    [[ "$output" == *"candidates=1, successful_deletes=0, delete_failures=1"* ]]
}

@test "Docker Hub cleanup reports dry-run candidates without successful deletions" {
    run_dockerhub_fixture '{"count":1,"results":[{"name":"obsolete"}],"next":null}' '' 204 true latest

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"1|1|0|0"* ]]
    [[ "$(<"$DH_CURL_LOG")" != *"-X DELETE"* ]]
}

@test "Docker Hub cleanup rejects concatenated listing documents before deleting" {
    local page='{"count":1,"results":[{"name":"obsolete"}],"next":null}'

    run_dockerhub_fixture "$page$page" '' 204 false latest

    [[ "$status" -eq 10 ]]
    [[ "$output" == *"listing page was malformed"* ]]
    [[ "$(<"$DH_CURL_LOG")" != *"-X DELETE"* ]]
}

@test "Docker Hub cleanup rejects a tag name ending in a newline before deleting" {
    local listing
    listing=$(jq -cn --arg name $'obsolete\n' '{count: 1, results: [{name: $name}], next: null}')

    run_dockerhub_fixture "$listing" '' 204 false latest

    [[ "$status" -eq 10 ]]
    [[ "$output" == *"listing page was malformed"* ]]
    [[ "$(<"$DH_CURL_LOG")" != *"-X DELETE"* ]]
}

@test "Docker Hub cleanup rejects a listing with a literal NUL byte before deleting" {
    local curl_log="$BATS_TEST_TMPDIR/dockerhub-literal-nul-curl.log"
    : > "$curl_log"

    run env PROJECT_ROOT="$PROJECT_ROOT" GH_TOKEN="$GH_TOKEN" OWNER="$OWNER" \
        DOCKERHUB_USERNAME=test-user DOCKERHUB_TOKEN=test-password DRY_RUN=false DOCKERHUB_DRY_RUN=false CURL_LOG="$curl_log" bash -c '
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            LISTING_FAILURE=10 PROCESSING_FAILURE=11 DELETE_FAILURE=12
            emit_listing() {
                printf "%s" "{\"count\":1,\"results\":[{\"name\":\"obso"
                printf "\0"
                printf "%s" "lete\"}],\"next\":null}"
            }
            curl() {
                printf "%s\n" "$*" >> "$CURL_LOG"
                case "$*" in
                    *"/users/login"*) printf "%s\n" "{\"token\":\"fixture-jwt\"}" ;;
                    *"page_size=100"*)
                        output_file="" previous=""
                        for curl_arg in "$@"; do
                            [[ "$previous" != "--output" ]] || output_file="$curl_arg"
                            previous="$curl_arg"
                        done
                        if [[ -n "$output_file" ]]; then emit_listing > "$output_file"; else emit_listing; fi
                        ;;
                    *"-X DELETE"*) printf "%s" 204 ;;
                    *) return 1 ;;
                esac
            }
            purge_dockerhub app latest
        '

    [[ "$status" -eq 10 ]]
    [[ "$output" == *"listing page was malformed"* ]]
    [[ "$(<"$curl_log")" != *"-X DELETE"* ]]
}

@test "Docker Hub cleanup refuses a declared listing body above the cap before deleting" {
    local curl_log="$BATS_TEST_TMPDIR/dockerhub-declared-cap-curl.log"
    : > "$curl_log"

    run env PROJECT_ROOT="$PROJECT_ROOT" GH_TOKEN="$GH_TOKEN" OWNER="$OWNER" \
        DOCKERHUB_USERNAME=test-user DOCKERHUB_TOKEN=test-password DRY_RUN=false DOCKERHUB_DRY_RUN=false CURL_LOG="$curl_log" bash -c '
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            LISTING_FAILURE=10 PROCESSING_FAILURE=11 DELETE_FAILURE=12
            curl() {
                printf "%s\n" "$*" >> "$CURL_LOG"
                case "$*" in
                    *"/users/login"*) printf "%s\n" "{\"token\":\"fixture-jwt\"}" ;;
                    *"page_size=100"*)
                        if [[ "$*" == *"--max-filesize $DOCKERHUB_LISTING_MAX_BYTES"* ]]; then return 63; fi
                        output_file="" previous=""
                        for curl_arg in "$@"; do [[ "$previous" != "--output" ]] || output_file="$curl_arg"; previous="$curl_arg"; done
                        printf "%s" "{\"count\":1,\"results\":[{\"name\":\"obsolete\"}],\"next\":null}" > "$output_file"
                        ;;
                    *"-X DELETE"*) printf "%s" 204 ;;
                    *) return 1 ;;
                esac
            }
            purge_dockerhub app latest
        '

    [[ "$status" -eq 10 ]]
    [[ "$output" == *"Failed to list Docker Hub tags"* ]]
    [[ "$(<"$curl_log")" != *"-X DELETE"* ]]
}

@test "Docker Hub cleanup removes a streamed listing body above the cap before deleting" {
    local curl_log="$BATS_TEST_TMPDIR/dockerhub-streamed-cap-curl.log"
    local listing_file_path="$BATS_TEST_TMPDIR/dockerhub-streamed-cap-listing-path"
    : > "$curl_log"
    : > "$listing_file_path"

    run env PROJECT_ROOT="$PROJECT_ROOT" GH_TOKEN="$GH_TOKEN" OWNER="$OWNER" \
        DOCKERHUB_USERNAME=test-user DOCKERHUB_TOKEN=test-password DRY_RUN=false DOCKERHUB_DRY_RUN=false CURL_LOG="$curl_log" LISTING_FILE_PATH="$listing_file_path" bash -c '
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            LISTING_FAILURE=10 PROCESSING_FAILURE=11 DELETE_FAILURE=12
            curl() {
                printf "%s\n" "$*" >> "$CURL_LOG"
                case "$*" in
                    *"/users/login"*) printf "%s\n" "{\"token\":\"fixture-jwt\"}" ;;
                    *"page_size=100"*)
                        output_file="" previous=""
                        for curl_arg in "$@"; do [[ "$previous" != "--output" ]] || output_file="$curl_arg"; previous="$curl_arg"; done
                        [[ -n "$output_file" ]] || return 1
                        printf "%s\n" "$output_file" > "$LISTING_FILE_PATH"
                        if [[ "$*" == *"--max-filesize $DOCKERHUB_LISTING_MAX_BYTES"* ]]; then
                            head -c "$((DOCKERHUB_LISTING_MAX_BYTES + 1))" /dev/zero > "$output_file"
                            return 63
                        fi
                        printf "%s" "{\"count\":1,\"results\":[{\"name\":\"obsolete\"}],\"next\":null}" > "$output_file"
                        ;;
                    *"-X DELETE"*) printf "%s" 204 ;;
                    *) return 1 ;;
                esac
            }
            purge_dockerhub app latest
        '

    [[ "$status" -eq 10 ]]
    [[ "$output" == *"Failed to list Docker Hub tags"* ]]
    [[ "$(<"$curl_log")" != *"-X DELETE"* ]]
    [[ ! -e "$(<"$listing_file_path")" ]]
}

@test "Docker Hub cleanup refuses malformed login responses before listing" {
    local curl_log="$BATS_TEST_TMPDIR/dockerhub-malformed-login-curl.log"
    local login_response

    for login_response in \
        $'{"token":"fixture-jwt"}\n{"token":"fixture-jwt"}' \
        '{"token":null}' \
        '{"token":42}' \
        '{"token":""}'; do
        : > "$curl_log"
        run env PROJECT_ROOT="$PROJECT_ROOT" GH_TOKEN="$GH_TOKEN" OWNER="$OWNER" \
            DOCKERHUB_USERNAME=test-user DOCKERHUB_TOKEN=test-password DRY_RUN=false DOCKERHUB_DRY_RUN=false CURL_LOG="$curl_log" LOGIN_RESPONSE="$login_response" bash -c '
                source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
                LISTING_FAILURE=10 PROCESSING_FAILURE=11 DELETE_FAILURE=12
                curl() {
                    printf "%s\n" "$*" >> "$CURL_LOG"
                    case "$*" in
                        *"/users/login"*) printf "%s" "$LOGIN_RESPONSE" ;;
                        *"page_size=100"*) return 1 ;;
                        *) return 1 ;;
                    esac
                }
                purge_dockerhub app latest
            '

        [[ "$status" -eq 11 ]]
        [[ "$output" == *"Failed to authenticate to Docker Hub"* ]]
        [[ "$(<"$curl_log")" != *"page_size=100"* ]]
    done
}

@test "Docker Hub cleanup refuses a login response above its cap before listing" {
    local curl_log="$BATS_TEST_TMPDIR/dockerhub-login-cap-curl.log"
    : > "$curl_log"

    run env PROJECT_ROOT="$PROJECT_ROOT" GH_TOKEN="$GH_TOKEN" OWNER="$OWNER" \
        DOCKERHUB_USERNAME=test-user DOCKERHUB_TOKEN=test-password DRY_RUN=false DOCKERHUB_DRY_RUN=false CURL_LOG="$curl_log" bash -c '
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            LISTING_FAILURE=10 PROCESSING_FAILURE=11 DELETE_FAILURE=12
            DOCKERHUB_LOGIN_MAX_BYTES=16
            curl() {
                printf "%s\n" "$*" >> "$CURL_LOG"
                case "$*" in
                    *"/users/login"*)
                        [[ "$*" == *"--max-filesize $DOCKERHUB_LOGIN_MAX_BYTES"* ]] || { printf "%s" "{\"token\":\"fixture-jwt\"}"; return 0; }
                        head -c "$((DOCKERHUB_LOGIN_MAX_BYTES + 1))" /dev/zero
                        return 63
                        ;;
                    *"page_size=100"*) return 1 ;;
                    *) return 1 ;;
                esac
            }
            purge_dockerhub app latest
        '

    [[ "$status" -eq 11 ]]
    [[ "$output" == *"Failed to authenticate to Docker Hub"* ]]
    [[ "$(<"$curl_log")" == *"--max-filesize 16"* ]]
    [[ "$(<"$curl_log")" != *"page_size=100"* ]]
}

@test "Docker Hub cleanup accepts a listing exactly at the cap" {
    run env PROJECT_ROOT="$PROJECT_ROOT" GH_TOKEN="$GH_TOKEN" OWNER="$OWNER" \
        DOCKERHUB_USERNAME=test-user DOCKERHUB_TOKEN=test-password DRY_RUN=true bash -c '
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            LISTING_FAILURE=10 PROCESSING_FAILURE=11 DELETE_FAILURE=12
            DOCKERHUB_LISTING_MAX_BYTES=256
            dockerhub_registry_token() { printf "%s\\n" registry-jwt; }
            dockerhub_manifest_digest() { printf "%s\\n" "200|sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; }
            ghcr_manifest_token() { printf "%s\\n" ghcr-jwt; }
            ghcr_manifest_status() { printf "%s\\n" 404; }
            curl() {
                case "$*" in
                    *"/users/login"*) printf "%s\n" "{\"token\":\"fixture-jwt\"}" ;;
                    *"page_size=100"*)
                        output_file="" previous=""
                        for curl_arg in "$@"; do [[ "$previous" != "--output" ]] || output_file="$curl_arg"; previous="$curl_arg"; done
                        body="{\"count\":1,\"results\":[{\"name\":\"obsolete\",\"digest\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}],\"next\":null}"
                        printf "%s%*s" "$body" "$((DOCKERHUB_LISTING_MAX_BYTES - ${#body}))" "" > "$output_file"
                        ;;
                    *) return 1 ;;
                esac
            }
            purge_dockerhub app latest
        '

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"1|1|0|0"* ]]
}

@test "Docker Hub cleanup refuses a cap hit on a later page before deleting earlier candidates" {
    local curl_log="$BATS_TEST_TMPDIR/dockerhub-later-cap-curl.log"
    : > "$curl_log"

    run env PROJECT_ROOT="$PROJECT_ROOT" GH_TOKEN="$GH_TOKEN" OWNER="$OWNER" \
        DOCKERHUB_USERNAME=test-user DOCKERHUB_TOKEN=test-password DRY_RUN=false DOCKERHUB_DRY_RUN=false CURL_LOG="$curl_log" bash -c '
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            LISTING_FAILURE=10 PROCESSING_FAILURE=11 DELETE_FAILURE=12
            curl() {
                printf "%s\n" "$*" >> "$CURL_LOG"
                case "$*" in
                    *"/users/login"*) printf "%s\n" "{\"token\":\"fixture-jwt\"}" ;;
                    *"page_size=100"*)
                        output_file="" previous=""
                        for curl_arg in "$@"; do [[ "$previous" != "--output" ]] || output_file="$curl_arg"; previous="$curl_arg"; done
                        printf "%s" "{\"count\":2,\"results\":[{\"name\":\"obsolete\"}],\"next\":\"https://hub.docker.com/v2/repositories/test-user/app/tags?page=2\"}" > "$output_file"
                        ;;
                    *"page=2"*) return 63 ;;
                    *"-X DELETE"*) printf "%s" 204 ;;
                    *) return 1 ;;
                esac
            }
            purge_dockerhub app latest
        '

    [[ "$status" -eq 10 ]]
    [[ "$(<"$curl_log")" == *"page=2"* ]]
    [[ "$(<"$curl_log")" != *"-X DELETE"* ]]
}

@test "Docker Hub cleanup refuses before its first request when the shared budget is exhausted" {
    local curl_log="$BATS_TEST_TMPDIR/dockerhub-budget-first-curl.log"
    : > "$curl_log"

    run env PROJECT_ROOT="$PROJECT_ROOT" GH_TOKEN="$GH_TOKEN" OWNER="$OWNER" \
        DOCKERHUB_USERNAME=test-user DOCKERHUB_TOKEN=test-password DRY_RUN=true CURL_LOG="$curl_log" bash -c '
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            LISTING_FAILURE=10 PROCESSING_FAILURE=11 DELETE_FAILURE=12
            DOCKERHUB_REQUESTS_REMAINING=0
            curl() { printf "%s\n" "$*" >> "$CURL_LOG"; return 1; }
            purge_dockerhub app latest
        '

    [[ "$status" -eq 11 ]]
    [[ "$output" == *"request budget exhausted"* ]]
    [[ ! -s "$curl_log" ]]
}

@test "Docker Hub cleanup refuses between listing pages when the shared budget is exhausted" {
    local curl_log="$BATS_TEST_TMPDIR/dockerhub-budget-pages-curl.log"
    : > "$curl_log"

    run env PROJECT_ROOT="$PROJECT_ROOT" GH_TOKEN="$GH_TOKEN" OWNER="$OWNER" \
        DOCKERHUB_USERNAME=test-user DOCKERHUB_TOKEN=test-password DRY_RUN=true CURL_LOG="$curl_log" bash -c '
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            LISTING_FAILURE=10 PROCESSING_FAILURE=11 DELETE_FAILURE=12
            DOCKERHUB_REQUESTS_REMAINING=2
            curl() {
                printf "%s\n" "$*" >> "$CURL_LOG"
                case "$*" in
                    *"/users/login"*) printf "%s\n" "{\"token\":\"fixture-jwt\"}" ;;
                    *"page_size=100"*)
                        output_file="" previous=""
                        for curl_arg in "$@"; do [[ "$previous" != "--output" ]] || output_file="$curl_arg"; previous="$curl_arg"; done
                        printf "%s" "{\"count\":2,\"results\":[{\"name\":\"obsolete\"}],\"next\":\"https://hub.docker.com/v2/repositories/test-user/app/tags?page=2\"}" > "$output_file"
                        ;;
                    *) return 1 ;;
                esac
            }
            purge_dockerhub app latest
        '

    [[ "$status" -eq 10 ]]
    [[ "$output" == *"request budget exhausted"* ]]
    [[ "$(grep -c -- '/tags' "$curl_log")" -eq 1 ]]
}

@test "Docker Hub cleanup refuses between DELETEs when the shared budget is exhausted" {
    local curl_log="$BATS_TEST_TMPDIR/dockerhub-budget-deletes-curl.log"
    : > "$curl_log"

    run env PROJECT_ROOT="$PROJECT_ROOT" GH_TOKEN="$GH_TOKEN" OWNER="$OWNER" \
        DOCKERHUB_USERNAME=test-user DOCKERHUB_TOKEN=test-password DRY_RUN=false DOCKERHUB_DRY_RUN=false CURL_LOG="$curl_log" bash -c '
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            LISTING_FAILURE=10 PROCESSING_FAILURE=11 DELETE_FAILURE=12
            DOCKERHUB_REQUESTS_REMAINING=3
            dockerhub_registry_token() { printf "%s\\n" registry-jwt; }
            dockerhub_manifest_digest() { printf "%s\\n" "200|sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; }
            ghcr_manifest_token() { printf "%s\\n" ghcr-jwt; }
            ghcr_manifest_status() { printf "%s\\n" 404; }
            curl() {
                printf "%s\n" "$*" >> "$CURL_LOG"
                case "$*" in
                    *"/users/login"*) printf "%s\n" "{\"token\":\"fixture-jwt\"}" ;;
                    *"page_size=100"*)
                        output_file="" previous=""
                        for curl_arg in "$@"; do [[ "$previous" != "--output" ]] || output_file="$curl_arg"; previous="$curl_arg"; done
                        printf "%s" "{\"count\":2,\"results\":[{\"name\":\"obsolete-one\",\"digest\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"},{\"name\":\"obsolete-two\",\"digest\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"}],\"next\":null}" > "$output_file"
                        ;;
                    *"-X DELETE"*) printf "%s" 204 ;;
                    *) return 1 ;;
                esac
            }
            purge_dockerhub app latest
        '

    [[ "$status" -eq 12 ]]
    [[ "$output" == *"1|2|1|1"* ]]
    [[ "$(grep -c -- '-X DELETE' "$curl_log")" -eq 1 ]]
}

@test "Docker Hub request allowance is shared across containers in main" {
    local curl_log="$BATS_TEST_TMPDIR/dockerhub-shared-budget-curl.log"
    : > "$curl_log"

    run env PROJECT_ROOT="$PROJECT_ROOT" GH_TOKEN="$GH_TOKEN" OWNER="$OWNER" \
        DOCKERHUB_USERNAME=test-user DOCKERHUB_TOKEN=test-password DRY_RUN=true CURL_LOG="$curl_log" bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            DOCKERHUB_REQUESTS_REMAINING=2
            build_valid_tags() { printf "%s\n" latest; }
            purge_ghcr() { printf "%s\n" "0|0|0|0|0"; }
            list_tagged_ghcr_digests() { :; }
            curl() {
                printf "%s\n" "$*" >> "$CURL_LOG"
                case "$*" in
                    *"/users/login"*) printf "%s\n" "{\"token\":\"fixture-jwt\"}" ;;
                    *"page_size=100"*)
                        output_file="" previous=""
                        for curl_arg in "$@"; do [[ "$previous" != "--output" ]] || output_file="$curl_arg"; previous="$curl_arg"; done
                        printf "%s" "{\"count\":1,\"results\":[{\"name\":\"latest\"}],\"next\":null}" > "$output_file"
                        ;;
                    *) return 1 ;;
                esac
            }
            main first second
        '

    [[ "$status" -eq 1 ]]
    [[ "$output" == *"request budget exhausted"* ]]
    [[ "$(grep -c -- '/users/login' "$curl_log")" -eq 1 ]]
}

@test "Docker Hub cleanup rejects duplicate names across pages before deleting" {
    run_dockerhub_fixture \
        '{"count":2,"results":[{"name":"obsolete"}],"next":"https://hub.docker.com/v2/repositories/test-user/app/tags?page=2"}' \
        '{"count":2,"results":[{"name":"obsolete"}],"next":null}' \
        204 false latest

    [[ "$status" -eq 10 ]]
    [[ "$output" == *"contained a duplicate tag"* ]]
    [[ "$(<"$DH_CURL_LOG")" != *"-X DELETE"* ]]
}

@test "Docker Hub cleanup rejects changing counts across pages before deleting" {
    run_dockerhub_fixture \
        '{"count":2,"results":[{"name":"obsolete"}],"next":"https://hub.docker.com/v2/repositories/test-user/app/tags?page=2"}' \
        '{"count":3,"results":[{"name":"other"}],"next":null}' \
        204 false latest

    [[ "$status" -eq 10 ]]
    [[ "$output" == *"counts disagree between pages"* ]]
    [[ "$(<"$DH_CURL_LOG")" != *"-X DELETE"* ]]
}

@test "Docker Hub cleanup does not count a 301 DELETE as successful" {
    run_dockerhub_fixture '{"count":1,"results":[{"name":"obsolete"}],"next":null}' '' 301 false latest

    [[ "$status" -eq 12 ]]
    [[ "$output" == *"1|1|0|1"* ]]
    [[ "$output" == *"candidates=1, successful_deletes=0, delete_failures=1"* ]]
}

@test "Docker Hub cleanup refuses MAX_PAGES continuations before the next request" {
    local curl_log="$BATS_TEST_TMPDIR/dockerhub-max-pages-curl.log"
    : > "$curl_log"

    run env PROJECT_ROOT="$PROJECT_ROOT" GH_TOKEN="$GH_TOKEN" OWNER="$OWNER" \
        DOCKERHUB_USERNAME=test-user DOCKERHUB_TOKEN=test-password DRY_RUN=true CURL_LOG="$curl_log" bash -c '
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            LISTING_FAILURE=10 PROCESSING_FAILURE=11 DELETE_FAILURE=12
            dockerhub_registry_token() { printf "%s\\n" registry-jwt; }
            dockerhub_manifest_digest() { printf "%s\\n" "200|sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; }
            ghcr_manifest_token() { printf "%s\\n" ghcr-jwt; }
            ghcr_manifest_status() { printf "%s\\n" 404; }
            curl() {
                printf "%s\\n" "$*" >> "$CURL_LOG"
                case "$*" in
                    *"/users/login"*) printf "%s\\n" "{\"token\":\"fixture-jwt\"}" ;;
                    *"/tags?"*)
                        page=1
                        output_file=""
                        previous=""
                        for curl_arg in "$@"; do
                            if [[ "$previous" == "--output" ]]; then output_file="$curl_arg"; fi
                            case "$curl_arg" in *page_size=100*) page=1 ;; *page=*) page="${curl_arg##*page=}" ;; esac
                            previous="$curl_arg"
                        done
                        if [[ "$page" -gt "$MAX_PAGES" ]]; then next=null; else next="\"https://hub.docker.com/v2/repositories/test-user/app/tags?page=$((page + 1))\""; fi
                        [[ -n "$output_file" ]] || return 1
                        printf "{\"count\":%s,\"results\":[{\"name\":\"tag%s\"}],\"next\":%s}\\n" \
                            "$((MAX_PAGES + 1))" "$page" "$next" > "$output_file"
                        ;;
                    *) echo "unexpected curl request: $*" >&2; return 1 ;;
                esac
            }
            purge_dockerhub app latest
        '

    [[ "$status" -eq 10 ]]
    [[ "$output" == *"exceeds MAX_PAGES=$MAX_PAGES"* ]]
    [[ "$(grep -c -- '/tags?' "$curl_log")" -eq "$MAX_PAGES" ]]
    [[ "$(<"$curl_log")" != *"-X DELETE"* ]]
}

@test "Docker Hub cleanup accepts a terminal listing exactly at MAX_PAGES" {
    local curl_log="$BATS_TEST_TMPDIR/dockerhub-terminal-max-pages-curl.log"
    : > "$curl_log"

    run env PROJECT_ROOT="$PROJECT_ROOT" GH_TOKEN="$GH_TOKEN" OWNER="$OWNER" \
        DOCKERHUB_USERNAME=test-user DOCKERHUB_TOKEN=test-password DRY_RUN=true CURL_LOG="$curl_log" bash -c '
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            LISTING_FAILURE=10 PROCESSING_FAILURE=11 DELETE_FAILURE=12
            dockerhub_registry_token() { printf "%s\\n" registry-jwt; }
            dockerhub_manifest_digest() { printf "%s\\n" "200|sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; }
            ghcr_manifest_token() { printf "%s\\n" ghcr-jwt; }
            ghcr_manifest_status() { printf "%s\\n" 404; }
            curl() {
                printf "%s\\n" "$*" >> "$CURL_LOG"
                case "$*" in
                    *"/users/login"*) printf "%s\\n" "{\"token\":\"fixture-jwt\"}" ;;
                    *"/tags?"*)
                        page=1
                        output_file=""
                        previous=""
                        for curl_arg in "$@"; do
                            if [[ "$previous" == "--output" ]]; then output_file="$curl_arg"; fi
                            case "$curl_arg" in *page_size=100*) page=1 ;; *page=*) page="${curl_arg##*page=}" ;; esac
                            previous="$curl_arg"
                        done
                        if [[ "$page" -eq "$MAX_PAGES" ]]; then next=null; else next="\"https://hub.docker.com/v2/repositories/test-user/app/tags?page=$((page + 1))\""; fi
                        [[ -n "$output_file" ]] || return 1
                        printf "{\"count\":%s,\"results\":[{\"name\":\"tag%s\",\"digest\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}],\"next\":%s}\\n" \
                            "$MAX_PAGES" "$page" "$next" > "$output_file"
                        ;;
                    *) echo "unexpected curl request: $*" >&2; return 1 ;;
                esac
            }
            purge_dockerhub app latest
        '

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"1|$MAX_PAGES|0|0"* ]]
    [[ "$(grep -c -- '/tags?' "$curl_log")" -eq "$MAX_PAGES" ]]
    [[ "$(<"$curl_log")" != *"-X DELETE"* ]]
}

@test "Docker Hub authentication, listings, and DELETEs have connect and transfer timeouts" {
    run_dockerhub_fixture '{"count":1,"results":[{"name":"obsolete"}],"next":null}' '' 204 false latest

    [[ "$status" -eq 0 ]]
    local curl_request
    while IFS= read -r curl_request; do
        [[ "$curl_request" != *"ghcr.io/"* ]] || continue
        [[ "$curl_request" == *"--connect-timeout $DOCKERHUB_CURL_CONNECT_TIMEOUT"* ]]
        [[ "$curl_request" == *"--max-time $DOCKERHUB_CURL_MAX_TIME"* ]]
    done < "$DH_CURL_LOG"
}

@test "outdated-tag main aggregates Docker Hub counters and continues after a delete failure" {
    run env PROJECT_ROOT="$PROJECT_ROOT" GH_TOKEN="$GH_TOKEN" OWNER="$OWNER" \
        DOCKERHUB_USERNAME=test-user DOCKERHUB_TOKEN=test-password DRY_RUN=false DOCKERHUB_DRY_RUN=false bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            build_valid_tags() { printf "%s\\n" latest; }
            purge_ghcr() { printf "%s\\n" "0|0|0|0|0"; }
            list_tagged_ghcr_digests() { :; }
            purge_dockerhub() {
                case "$1" in
                    stale) printf "%s\\n" "1|2|1|1"; return 12 ;;
                    fresh) printf "%s\\n" "1|1|1|0" ;;
                esac
            }
            main stale fresh
        '

    [[ "$status" -eq 1 ]]
    [[ "$output" == *"Purging obsolete images: fresh"* ]]
    [[ "$output" == *"Docker Hub — candidates: 3, successful deletes: 2"* ]]
    [[ "$output" == *"Docker Hub — delete failures: 1"* ]]
}

@test "Docker Hub DELETE path segments are percent-encoded and curl globbing is disabled" {
    local curl_log="$BATS_TEST_TMPDIR/dockerhub-delete-curl.log"
    : > "$curl_log"

    run env PROJECT_ROOT="$PROJECT_ROOT" GH_TOKEN="$GH_TOKEN" OWNER="$OWNER" \
        DOCKERHUB_USERNAME='test user' DRY_RUN=false DOCKERHUB_DRY_RUN=false CURL_LOG="$curl_log" bash -c '
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            curl() { printf "%s\\n" "$*" >> "$CURL_LOG"; printf '%s' 204; }
            _cleanup_outdated_tags_delete dockerhub-tag fixture-jwt "repo/name" "tag[{/%"
        '

    [[ "$status" -eq 0 ]]
    [[ "$(<"$curl_log")" == *"--globoff"* ]]
    [[ "$(<"$curl_log")" == *"/test%20user/repo%2Fname/tags/tag%5B%7B%2F%25/"* ]]
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

    if ! is_valid_tag "latest-windows-ltsc2022-dev" "$valid_tags"; then
        echo "ASSERTION FAILED: cleanup must keep the variant rolling alias from a Windows github-runner cell (latest-windows-ltsc2022-dev)" >&2
        return 1
    fi
    if ! is_valid_tag "latest-windows-ltsc2022" "$valid_tags"; then
        echo "ASSERTION FAILED: cleanup must keep the independent Windows flavor rolling alias (latest-windows-ltsc2022)" >&2
        return 1
    fi
    if ! is_valid_tag "latest-debian-trixie-base" "$valid_tags"; then
        echo "ASSERTION FAILED: cleanup must keep a Linux rolling alias by variant (latest-debian-trixie-base)" >&2
        return 1
    fi
    if is_valid_tag "latest-nonexistent" "$valid_tags"; then
        echo "ASSERTION FAILED: cleanup must delete a rolling alias that no cell produces (latest-nonexistent)" >&2
        return 1
    fi
    [[ "$valid_tags" == "$expected_tags" ]]
    run ! is_valid_tag "latest-debian-trixie" "$valid_tags"
    run ! is_valid_tag "latest-windows-ltsc2025" "$valid_tags"
    run ! is_valid_tag "latest-windows-ltsc2019" "$valid_tags"
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
            purge_dockerhub() { printf "%s\\n" "$1" >> "$DOCKERHUB_CALLS"; printf "%s\\n" "0|0|0|0"; }
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
                elif [[ "$*" =~ /versions/([0-9]+)$ ]]; then
                    command jq -ce --arg id "${BASH_REMATCH[1]}" ".[] | select((.id | tostring) == \$id)" <<< "$LISTING_JSON"
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
            purge_dockerhub() { printf "%s\\n" "$1" >> "$DOCKERHUB_CALLS"; printf "%s\\n" "1|0|0|0"; }
            gh() {
                if [[ "$*" == *"--method DELETE"* ]]; then
                    printf "DELETE:%s\\n" "$*" >> "$GH_LOG"
                    [[ -z "$DELETE_FAILURE_ID" || "$*" != *"/versions/$DELETE_FAILURE_ID"* ]] || return 1
                    return 0
                fi
                if [[ "$*" =~ /versions/([0-9]+)$ ]]; then
                    command jq -ce --arg id "${BASH_REMATCH[1]}" ".[] | select((.id | tostring) == \$id)" <<< "$LISTING_JSON"
                    return
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

@test "a surviving obsolete parent leaves its untagged child unassessed" {
    local listing='[{"id":101,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":["stale"]}}},{"id":102,"name":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","metadata":{"container":{"tags":[]}}}]'
    local gh_log="$_STUB_DIR/orphan-phase-gh.log"
    local dockerhub_calls="$_STUB_DIR/orphan-phase-dockerhub.log"

    run_orphan_phase_completion_case "$listing" 101 ''

    [[ "$status" -eq 1 ]]
    [[ "$(<"$gh_log")" == *"/versions/101"* ]]
    [[ "$(<"$gh_log")" != *"/versions/102"* ]]
    [[ ! -s "$dockerhub_calls" ]]
    [[ "$output" == *"Orphan assessment incomplete: an obsolete parent was not deleted"* ]]
    [[ "$output" == *"GHCR summary: kept=0, obsolete=1, orphan phase not assessed, delete_failures=1"* ]]
    [[ "$output" == *"Packages assessed: 0"* ]]
    [[ "$output" == *"GHCR — kept: 0, obsolete: 1, orphans: 0"* ]]
}

@test "a parent DELETE failure returns zero assessed orphans for its untagged child" {
    local gh_log="$_STUB_DIR/orphan-count-gh.log"

    run env \
        PROJECT_ROOT="$PROJECT_ROOT" GH_LOG="$gh_log" GH_TOKEN="$GH_TOKEN" OWNER="$OWNER" \
        DRY_RUN="false" KEEP_LATEST_COUNT="0" KEEP_MONTHS="0" \
        bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            LISTING_FAILURE=10 PROCESSING_FAILURE=11 DELETE_FAILURE=12 POST_DELETE_PROCESSING_FAILURE=13 UNINTERPRETABLE_RECORD_FAILURE=14 PROTECTION_FAILURE=15 INCOMPLETE_DELETION_FAILURE=16
            gh() {
                if [[ "$*" == *"--method DELETE"* ]]; then
                    printf "DELETE:%s\\n" "$*" >> "$GH_LOG"
                    [[ "$*" != *"/versions/101"* ]]
                    return
                fi
                if [[ "$*" == *"/versions/101"* ]]; then printf "%s\\n" "{\"id\":101,\"metadata\":{\"container\":{\"tags\":[\"stale\"]}}}"; return 0; fi
                if [[ "$*" != *"/versions"* ]]; then printf "%s\\n" "{\"version_count\":2}"; return 0; fi
                printf "%s\\n" "[{\"id\":101,\"name\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"metadata\":{\"container\":{\"tags\":[\"stale\"]}}},{\"id\":102,\"name\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"metadata\":{\"container\":{\"tags\":[]}}}]"
            }
            if result=$(purge_ghcr stale latest); then status=0; else status=$?; fi
            [[ "$status" -eq 16 ]]
            [[ "$result" == "0|1|0|1|0" ]]
        '

    [[ "$status" -eq 0 ]]
    [[ "$(<"$gh_log")" == *"/versions/101"* ]]
    [[ "$(<"$gh_log")" != *"/versions/102"* ]]
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

@test "an orphan-phase decode failure is unassessed before any parent DELETE" {
    local listing='[{"id":101,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":["stale-first"]}}},{"id":102,"name":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","metadata":{"container":{"tags":["stale-second"]}}},{"id":103,"name":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","metadata":{"container":{"tags":[]}}}]'
    local gh_log="$_STUB_DIR/orphan-phase-gh.log"
    local dockerhub_calls="$_STUB_DIR/orphan-phase-dockerhub.log"

    run_orphan_phase_completion_case "$listing" '' 2

    [[ "$status" -eq 1 ]]
    [[ ! -e "$gh_log" ]]
    [[ ! -s "$dockerhub_calls" ]]
    [[ "$output" == *"Failed to read GHCR version record; skipping stale"* ]]
    [[ "$output" == *"Packages assessed: 0"* ]]
}

@test "a withheld orphan execution remains assessed and is included in the plan total" {
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
                elif [[ "$*" == *"/versions/101"* ]]; then
                    printf "%s\\n" "{\"id\":101,\"metadata\":{\"container\":{\"tags\":[\"stale\"]}}}"
                    return
                elif [[ "$*" == *"/versions/201"* ]]; then
                    printf "%s\\n" "{\"id\":201,\"metadata\":{\"container\":{\"tags\":[\"stale\"]}}}"
                    return
                elif [[ "$*" == *"/versions/202"* ]]; then
                    printf "%s\\n" "{\"id\":202,\"metadata\":{\"container\":{\"tags\":[]}}}"
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

@test "a replay decode failure is unassessed before any parent DELETE" {
    local listing='[{"id":101,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":["stale-first"]}}},{"id":102,"name":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","metadata":{"container":{"tags":["stale-second"]}}}]'
    local dockerhub_calls="$_STUB_DIR/orphan-phase-dockerhub.log"

    run_orphan_phase_completion_case "$listing" '' 2

    [[ "$status" -eq 1 ]]
    [[ ! -s "$dockerhub_calls" ]]
    [[ "$output" == *"Failed to read GHCR version record; skipping stale"* ]]
    [[ "$output" == *"Packages assessed: 0"* ]]
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
    [[ "$output" == *"Packages assessed: 0"* ]]
}

@test "a malformed later GHCR replay record prevents every DELETE and preserves its assessment record" {
    local gh_log="$_STUB_DIR/replay-preflight-gh.log"
    local dockerhub_calls="$_STUB_DIR/replay-preflight-dockerhub.log"

    run env \
        PROJECT_ROOT="$PROJECT_ROOT" GH_LOG="$gh_log" DOCKERHUB_CALLS="$dockerhub_calls" \
        GH_TOKEN="$GH_TOKEN" OWNER="$OWNER" DRY_RUN="false" \
        bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            build_valid_tags() { printf "%s\\n" latest; }
            purge_dockerhub() { printf "%s\\n" "$1" >> "$DOCKERHUB_CALLS"; printf "%s\\n" "1|0|0|0"; }
            eval "$(declare -f load_framed_work_list | sed "1s/^load_framed_work_list /original_load_framed_work_list /")"
            load_framed_work_list() {
                if [[ "$1" == "deletion replay" ]]; then
                    printf "work-list|expected|2\\n101|sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|stale-a\\nmalformed\\nwork-list|complete|2\\n" > "$2"
                fi
                original_load_framed_work_list "$@"
            }
            gh() {
                if [[ "$*" == *"--method DELETE"* ]]; then printf "DELETE:%s\\n" "$*" >> "$GH_LOG"; return 0; fi
                if [[ "$*" != *"/versions"* ]]; then printf "%s\\n" "{\"version_count\":2}"; return 0; fi
                printf "%s\\n" "[{\"id\":101,\"name\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"metadata\":{\"container\":{\"tags\":[\"stale-a\"]}}},{\"id\":102,\"name\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"metadata\":{\"container\":{\"tags\":[\"stale-b\"]}}}]"
            }
            main stale
        '

    [[ "$status" -eq 1 ]]
    [[ ! -s "$gh_log" ]]
    [[ "$output" == *"Failed to read prepared GHCR deletion record; skipping stale"* ]]
    [[ "$output" == *"GHCR summary: kept=0, obsolete=2, orphans=0, delete_failures=0"* ]]
    [[ "$output" == *"Packages assessed: 1"* ]]
    [[ -s "$dockerhub_calls" ]]
}

@test "a malformed GHCR replay with an untagged candidate is unassessed and skips Docker Hub" {
    local gh_log="$_STUB_DIR/replay-orphan-gh.log"
    local dockerhub_calls="$_STUB_DIR/replay-orphan-dockerhub.log"

    run env \
        PROJECT_ROOT="$PROJECT_ROOT" GH_LOG="$gh_log" DOCKERHUB_CALLS="$dockerhub_calls" \
        GH_TOKEN="$GH_TOKEN" OWNER="$OWNER" DRY_RUN="false" \
        bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            build_valid_tags() { printf "%s\\n" latest; }
            purge_dockerhub() { printf "%s\\n" "$1" >> "$DOCKERHUB_CALLS"; printf "%s\\n" "1|0|0|0"; }
            eval "$(declare -f load_framed_work_list | sed "1s/^load_framed_work_list /original_load_framed_work_list /")"
            load_framed_work_list() {
                if [[ "$1" == "deletion replay" ]]; then
                    printf "work-list|expected|1\\nmalformed\\nwork-list|complete|1\\n" > "$2"
                fi
                original_load_framed_work_list "$@"
            }
            gh() {
                if [[ "$*" == *"--method DELETE"* ]]; then printf "DELETE:%s\\n" "$*" >> "$GH_LOG"; return 0; fi
                if [[ "$*" != *"/versions"* ]]; then printf "%s\\n" "{\"version_count\":2}"; return 0; fi
                printf "%s\\n" "[{\"id\":101,\"name\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"metadata\":{\"container\":{\"tags\":[\"stale\"]}}},{\"id\":102,\"name\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"metadata\":{\"container\":{\"tags\":[]}}}]"
            }
            main stale
        '

    [[ "$status" -eq 1 ]]
    [[ ! -s "$gh_log" ]]
    [[ ! -s "$dockerhub_calls" ]]
    [[ "$output" == *"Failed to read prepared GHCR deletion record; skipping stale"* ]]
    [[ "$output" == *"GHCR summary: kept=0, obsolete=1, orphan phase not assessed, delete_failures=0"* ]]
    [[ "$output" == *"Packages assessed: 0"* ]]
    [[ "$output" == *"Docker Hub cleanup skipped: GHCR safety assessment was incomplete"* ]]
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
                if [[ "$*" == *"/versions/104"* ]]; then printf "%s\\n" "{\"id\":104,\"metadata\":{\"container\":{\"tags\":[]}}}"; return 0; fi
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
                if [[ "$*" == *"/versions/102"* ]]; then printf "%s\\n" "{\"id\":102,\"metadata\":{\"container\":{\"tags\":[]}}}"; return 0; fi
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

@test "is_valid_tag: grep status 2 is preserved rather than treated as obsolete" {
    grep() { return 2; }

    run is_valid_tag "latest" "latest"

    [[ "$status" -eq 2 ]]
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
    [[ "$output" == *"cleanup target rejected: package name must match"* ]]
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
            purge_dockerhub() { printf "%s\\n" "0|0|0|0"; }
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
            purge_dockerhub() { printf "%s\\n" "$1" >> "$DOCKERHUB_CALLS"; printf "%s\\n" "1|0|0|0"; }
            list_tagged_ghcr_digests() { :; }
            for expectation in success:0:complete:success listing:10:incomplete:failure processing:11:incomplete:failure delete:12:complete:failure post-complete:13:complete:failure uninterpretable:14:incomplete:failure protection:15:incomplete:failure incomplete-delete:16:incomplete:failure unexpected:99:incomplete:failure; do
                name=${expectation%%:*}; remainder=${expectation#*:}; stub_ghcr_status=${remainder%%:*}; remainder=${remainder#*:}; assessment=${remainder%%:*}; expected_run=${remainder#*:}
                : > "$DOCKERHUB_CALLS"
                purge_ghcr() {
                    if [[ "$stub_ghcr_status" -eq 12 ]]; then printf "%s\\n" "0|0|0|1|0"; else printf "%s\\n" "0|0|0|0|0"; fi
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

@test "cleanup workflow schedules daily registry pruning" {
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
    if [ "$output" != '17 3 * * *' ]; then
        printf "FAIL: expected daily registry prune cron '17 3 * * *', got %s\n" "$output" >&2
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

@test "a targeted cleanup workflow dispatch passes only its container to both registry pruners" {
    local workflow_path age_step obsolete_step stub_dir
    local age_log obsolete_log
    workflow_path="$PROJECT_ROOT/.github/workflows/cleanup-registry.yaml"
    stub_dir="$BATS_TEST_TMPDIR/targeted-cleanup-stubs"
    age_log="$BATS_TEST_TMPDIR/age-pruner-arguments.log"
    obsolete_log="$BATS_TEST_TMPDIR/obsolete-pruner-arguments.log"
    mkdir -p "$stub_dir"

    age_step=$(yq -r '.jobs.cleanup.steps[] | select(.id == "cleanup_old_versions") | .run' "$workflow_path")
    obsolete_step=$(yq -r '.jobs.cleanup.steps[] | select(.id == "purge_obsolete_images") | .run' "$workflow_path")

    [[ "$age_step" == *'./scripts/cleanup-old-versions.sh "$CONTAINER_FILTER"'* ]]
    [[ "$obsolete_step" == *'./scripts/cleanup-outdated-tags.sh "$CONTAINER_FILTER"'* ]]

    cat > "$stub_dir/cleanup-old-versions.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$AGE_PRUNER_ARGUMENTS_LOG"
EOF
    cat > "$stub_dir/cleanup-outdated-tags.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$OBSOLETE_PRUNER_ARGUMENTS_LOG"
EOF
    chmod +x "$stub_dir/cleanup-old-versions.sh" "$stub_dir/cleanup-outdated-tags.sh"

    # The workflow invokes repository-relative scripts. Normalize only those
    # paths so this test can execute the extracted step logic against PATH stubs.
    age_step=${age_step//.\/scripts\/cleanup-old-versions.sh/cleanup-old-versions.sh}
    obsolete_step=${obsolete_step//.\/scripts\/cleanup-outdated-tags.sh/cleanup-outdated-tags.sh}

    run env \
        PATH="$stub_dir:$PATH" \
        CONTAINER_FILTER="postgres" \
        AGE_PRUNER_ARGUMENTS_LOG="$age_log" \
        OBSOLETE_PRUNER_ARGUMENTS_LOG="$obsolete_log" \
        bash -c "$age_step"

    [[ "$status" -eq 0 ]]

    run env \
        PATH="$stub_dir:$PATH" \
        CONTAINER_FILTER="postgres" \
        AGE_PRUNER_ARGUMENTS_LOG="$age_log" \
        OBSOLETE_PRUNER_ARGUMENTS_LOG="$obsolete_log" \
        bash -c "$obsolete_step"

    [[ "$status" -eq 0 ]]
    [[ "$(<"$age_log")" == "postgres" ]]
    [[ "$(<"$obsolete_log")" == "postgres" ]]
}

@test "real registry pruners refuse malformed targeted filters before processing a package" {
    local script filter

    for script in scripts/cleanup-old-versions.sh scripts/cleanup-outdated-tags.sh; do
        for filter in 'postgres vector' '*' '   ' $'postgres\nvector' ''; do
            run env \
                GH_TOKEN="test-token" \
                OWNER="test-owner" \
                DRY_RUN="true" \
                KEEP_LATEST_COUNT="0" \
                KEEP_MONTHS="0" \
                bash "$PROJECT_ROOT/$script" "$filter"

            [[ "$status" -eq 64 ]]
            [[ "$output" == *"cleanup target rejected:"* ]]
            [[ "$output" != *"Processing:"* ]]
            [[ "$output" != *"Purging obsolete images:"* ]]
            [[ "$output" != *"Packages assessed:"* ]]
        done

        run env \
            GH_TOKEN="test-token" \
            OWNER="test-owner" \
            DRY_RUN="true" \
            KEEP_LATEST_COUNT="0" \
            KEEP_MONTHS="0" \
            bash "$PROJECT_ROOT/$script" postgres vector

        [[ "$status" -eq 64 ]]
        [[ "$output" == *"cleanup target rejected:"* ]]
        [[ "$output" != *"Processing:"* ]]
        [[ "$output" != *"Purging obsolete images:"* ]]
        [[ "$output" != *"Packages assessed:"* ]]
    done
}

@test "registry pruner help promises a single exact package target" {
    local script

    for script in scripts/cleanup-old-versions.sh scripts/cleanup-outdated-tags.sh; do
        run bash "$PROJECT_ROOT/$script" --help

        [[ "$status" -eq 0 ]]
        [[ "$output" == *"exactly one package"* ]]
        [[ "$output" == *"multiple package names are rejected"* ]]
    done
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
    local purge_dry_run
    purge_dry_run=$(yq -r '.jobs.cleanup.steps[] | select(.id == "purge_obsolete_images") | .env.DRY_RUN' "$PROJECT_ROOT/.github/workflows/cleanup-registry.yaml")
    [[ "$purge_dry_run" == "\${{ inputs.dry_run || 'false' }}" ]]
    [[ "$purge_step" == *"DOCKERHUB_DRY_RUN: 'true'"* ]]

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

@test "upstream monitor does not dispatch registry cleanup after a rotation merge" {
    local workflow_path
    workflow_path="$PROJECT_ROOT/.github/workflows/upstream-monitor.yaml"

    run grep -F 'gh workflow run cleanup-registry.yaml' "$workflow_path"
    [[ "$status" -eq 1 ]]
    [[ -z "$output" ]]
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
                if [[ "$*" == *"/versions/101"* ]]; then printf "%s\\n" "{\"id\":101,\"metadata\":{\"container\":{\"tags\":[\"stale\"]}}}"; return 0; fi
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
            purge_dockerhub() { printf "%s\\n" "$1" >> "$DOCKERHUB_CALLS"; printf "%s\\n" "1|0|0|0"; }
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

@test "an orphan-phase decode failure is not reported as a completed GHCR assessment" {
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
            purge_dockerhub() { printf "%s\\n" "$1" >> "$DOCKERHUB_CALLS"; printf "%s\\n" "1|0|0|0"; }
            gh() {
                if [[ "$*" == *"--method DELETE"* ]]; then printf "DELETE:%s\\n" "$*" >> "$GH_LOG"; return 0; fi
                if [[ "$*" != *"/versions"* ]]; then printf "%s\\n" "{\"version_count\":2}"; return 0; fi
                printf "%s\\n" "[{\"id\":101,\"name\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"metadata\":{\"container\":{\"tags\":[\"stale-first\"]}}},{\"id\":102,\"name\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"metadata\":{\"container\":{\"tags\":[\"stale-second\"]}}}]"
            }
            base64() {
                calls=0; [[ -f "$BASE64_CALLS" ]] && calls=$(<"$BASE64_CALLS")
                calls=$((calls + 1)); printf "%s\\n" "$calls" > "$BASE64_CALLS"
                [[ "$calls" -lt 2 ]] || { echo "base64: prepared record lost" >&2; return 1; }
                command base64 "$@"
            }
            main stale
        '

    [[ "$status" -eq 1 ]]
    [[ ! -s "$gh_log" ]]
    [[ ! -s "$dockerhub_calls" ]]
    [[ "$output" == *"Failed to read GHCR version record; skipping stale"* ]]
    [[ "$output" == *"Packages assessed: 0"* ]]
    [[ "$output" == *"Packages skipped (processing failed): 1"* ]]
}

@test "outdated-tag main rejects GHCR and Docker Hub result records with extra lines" {
    run env \
        PROJECT_ROOT="$PROJECT_ROOT" GH_TOKEN="$GH_TOKEN" OWNER="$OWNER" DRY_RUN="false" KEEP_LATEST_COUNT="0" KEEP_MONTHS="0" \
        bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            build_valid_tags() { printf "%s\\n" latest; }
            purge_ghcr() { printf "%s\\n" stray "0|0|0|0|0"; }
            purge_dockerhub() { printf "%s\\n" "$1" >> "$DOCKERHUB_CALLS"; printf "%s\\n" "1|0|0|0"; }
            main stale
        '

    [[ "$status" -eq 1 ]]
    [[ "$output" == *"Failed to read GHCR cleanup result; skipping stale"* ]]
    [[ "$output" == *"Packages assessed: 0"* ]]

    run env \
        PROJECT_ROOT="$PROJECT_ROOT" GH_TOKEN="$GH_TOKEN" OWNER="$OWNER" DRY_RUN="false" \
        bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            build_valid_tags() { printf "%s\\n" latest; }
            purge_ghcr() { printf "%s\\n" "0|0|0|0|0"; }
            list_tagged_ghcr_digests() { :; }
            purge_dockerhub() { printf "%s\\n" "1|0|0|0" stray; }
            main stale
        '

    [[ "$status" -eq 1 ]]
    [[ "$output" == *"Failed to read Docker Hub cleanup result; skipping stale"* ]]
}

@test "outdated-tag main sends every result counter consumer through the shared parser" {
    local consumer invalid_counter

    for consumer in ghcr-complete ghcr-incomplete dockerhub; do
        for invalid_counter in 08 2147483648; do
            run env \
                PROJECT_ROOT="$PROJECT_ROOT" CONSUMER="$consumer" RESULT_COUNTER="$invalid_counter" GH_TOKEN="$GH_TOKEN" OWNER="$OWNER" DRY_RUN="false" \
                bash -c '
                    set -euo pipefail
                    source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
                    build_valid_tags() { printf "%s\\n" latest; }
                    list_tagged_ghcr_digests() { :; }
                    case "$CONSUMER" in
                      ghcr-complete)
                        purge_ghcr() { printf "%s\\n" "$RESULT_COUNTER|0|0|0|0"; return 13; }
                        purge_dockerhub() { printf "%s\\n" "1|0|0|0"; }
                        ;;
                      ghcr-incomplete)
                        purge_ghcr() { printf "%s\\n" "$RESULT_COUNTER|0|0|0|0"; return 16; }
                        purge_dockerhub() { printf "%s\\n" "1|0|0|0"; }
                        ;;
                      dockerhub)
                        purge_ghcr() { printf "%s\\n" "0|0|0|0|0"; }
                        purge_dockerhub() { printf "%s\\n" "1|0|$RESULT_COUNTER|0"; }
                        ;;
                    esac
                    main stale
                '

            [[ "$status" -eq 1 ]]
            [[ "$output" == *"rejected: counter"* ]]
            [[ "$output" != *"arithmetic expression"* ]]
            if [[ "$consumer" == dockerhub ]]; then
                [[ "$output" == *"Packages assessed: 1"* ]]
            else
                [[ "$output" == *"Packages assessed: 0"* ]]
            fi
        done
    done
}

@test "outdated-tag GHCR deletion wrapper keeps client stdout off the caller record" {
    run env \
        PROJECT_ROOT="$PROJECT_ROOT" GH_TOKEN="$GH_TOKEN" OWNER="$OWNER" DRY_RUN="false" KEEP_LATEST_COUNT="0" KEEP_MONTHS="0" \
        bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            gh() { printf "%s\\n" "client response"; }
            result=$(_cleanup_outdated_tags_delete ghcr-version stale 101)
            [[ -z "$result" ]]
        '

    [[ "$status" -eq 0 ]]
    [[ "$output" != *"client response"* ]]
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
            purge_dockerhub() { printf "%s\n" "$1" >> "$DOCKERHUB_CALLS"; printf "%s\n" "1|0|0|0"; }
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
        DRY_RUN="false" \
        KEEP_LATEST_COUNT="0" \
        KEEP_MONTHS="0" \
        bash -c '
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            validate_cleanup_authority
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
        DRY_RUN="false" \
        KEEP_LATEST_COUNT="0" \
        KEEP_MONTHS="0" \
        bash -c '
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            validate_cleanup_authority
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

    if [[ "$status" -ne 1 || "$output" == *"latest-"* ]]; then
        echo "ASSERTION FAILED: invalid build data must return 1 without emitting a rolling alias (status=$status, output=$output)" >&2
        return 1
    fi
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

@test "outdated-tag cleanup rejects invalid configuration before gh or curl" {
    local command_dir="$BATS_TEST_TMPDIR/invalid-cleanup-config-bin"
    local gh_log="$BATS_TEST_TMPDIR/invalid-cleanup-config-gh.log"
    local curl_log="$BATS_TEST_TMPDIR/invalid-cleanup-config-curl.log"
    mkdir -p "$command_dir"
    : > "$gh_log"
    : > "$curl_log"
    printf '%s\n' '#!/usr/bin/env bash' \
        'printf "%s\\n" "$*" >> "$GH_LOG"' \
        'if [[ "$*" == *"--method DELETE"* ]]; then exit 0; fi' \
        'if [[ "$*" == *"/versions"* ]]; then printf "%s\\n" '\''[{"id":101,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":["stale"]}}}]'\''; else printf "%s\\n" '\''{"version_count":1}'\''; fi' \
        > "$command_dir/gh"
    printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\\n" "$*" >> "$CURL_LOG"' > "$command_dir/curl"
    chmod +x "$command_dir/gh" "$command_dir/curl"

    run env \
        PATH="$command_dir:$PATH" \
        PROJECT_ROOT="$PROJECT_ROOT" \
        GH_LOG="$gh_log" \
        CURL_LOG="$curl_log" \
        GH_TOKEN=test-token \
        OWNER=test-owner \
        DRY_RUN=TRUE \
        KEEP_LATEST_COUNT=0 \
        KEEP_MONTHS=0 \
        bash -c 'source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"; build_valid_tags() { printf "%s\\n" latest; }; main stale'

    [[ "$status" -eq 64 ]]
    [[ "$output" == "cleanup configuration rejected: DRY_RUN must be exactly true or false" ]]
    [[ ! -s "$gh_log" ]]
    [[ ! -s "$curl_log" ]]
    [[ "$(<"$gh_log")" != *"--method DELETE"* ]]
    [[ "$(<"$curl_log")" != *"DELETE"* ]]
}

@test "outdated-tag cleanup ignores malformed retention settings" {
    run env \
        PROJECT_ROOT="$PROJECT_ROOT" \
        GH_TOKEN=test-token \
        OWNER=test-owner \
        DRY_RUN=true \
        KEEP_LATEST_COUNT=not-a-number \
        KEEP_MONTHS=not-a-number \
        bash -c '
            source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
            build_valid_tags() { printf "%s\\n" latest; }
            purge_ghcr() { printf "%s\\n" "0|0|0|0|0"; }
            list_tagged_ghcr_digests() { :; }
            purge_dockerhub() { printf "%s\\n" "0|0|0|0"; }
            main stale
        '

    [[ "$status" -eq 0 ]]
    [[ "$output" != *"cleanup configuration rejected"* ]]
    [[ "$output" == *"Packages assessed: 1"* ]]
}

@test "outdated-tag purges revalidate a marker-shaped bypass before their first network call" {
    local gh_log="$BATS_TEST_TMPDIR/direct-outdated-purge-gh.log"
    local curl_log="$BATS_TEST_TMPDIR/direct-outdated-purge-curl.log"
    : > "$gh_log"
    : > "$curl_log"

    run env PROJECT_ROOT="$PROJECT_ROOT" GH_LOG="$gh_log" CURL_LOG="$curl_log" DRY_RUN=TRUE KEEP_LATEST_COUNT=0 KEEP_MONTHS=0 CLEANUP_CONFIG_VALIDATED=true bash -c '
        source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
        gh() { printf "%s\\n" "$*" >> "$GH_LOG"; }
        curl() { printf "%s\\n" "$*" >> "$CURL_LOG"; }
        purge_ghcr stale latest
    '

    [[ "$status" -eq 64 ]]
    [[ "$output" == "cleanup configuration rejected: DRY_RUN must be exactly true or false" ]]
    [[ ! -s "$gh_log" ]]
    [[ ! -s "$curl_log" ]]
}

@test "outdated-tag deletion wrapper refuses dry-run directly without invoking clients" {
    local gh_log="$BATS_TEST_TMPDIR/direct-outdated-delete-gh.log"
    local curl_log="$BATS_TEST_TMPDIR/direct-outdated-delete-curl.log"
    : > "$gh_log"
    : > "$curl_log"

    run env PROJECT_ROOT="$PROJECT_ROOT" GH_LOG="$gh_log" CURL_LOG="$curl_log" DRY_RUN=true KEEP_LATEST_COUNT=0 KEEP_MONTHS=0 bash -c '
        source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
        gh() { printf "%s\\n" "$*" >> "$GH_LOG"; }
        curl() { printf "%s\\n" "$*" >> "$CURL_LOG"; }
        validate_cleanup_authority
        if _cleanup_outdated_tags_delete ghcr-version stale 101; then exit 1; else [[ $? -eq 64 ]]; fi
        if _cleanup_outdated_tags_delete dockerhub-tag jwt stale stale; then exit 1; else [[ $? -eq 64 ]]; fi
    '

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"cleanup deletion refused: DRY_RUN must be false"* ]]
    [[ ! -s "$gh_log" ]]
    [[ ! -s "$curl_log" ]]
}

@test "outdated-tag cleanup does not delete a tagged version whose re-read gained a valid tag" {
    local gh_log="$_STUB_DIR/reread-tagged-gh.log"

    run env PROJECT_ROOT="$PROJECT_ROOT" GH_LOG="$gh_log" GH_TOKEN="$GH_TOKEN" OWNER="$OWNER" DRY_RUN=false bash -c '
        source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
        build_valid_tags() { printf "%s\n" latest; }
        gh() {
            [[ "$*" == *"--method DELETE"* ]] && { printf "DELETE\n" >> "$GH_LOG"; return 0; }
            [[ "$*" == *"/versions/101"* ]] && { printf "%s\n" "{\"id\":101,\"metadata\":{\"container\":{\"tags\":[\"stale\",\"latest\"]}}}"; return 0; }
            [[ "$*" == *"/versions"* ]] && printf "%s\n" "[{\"id\":101,\"name\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"metadata\":{\"container\":{\"tags\":[\"stale\"]}}}]" || printf "%s\n" "{\"version_count\":1}"
        }
        main stale
    '

    [[ "$status" -eq 0 ]]
    [[ ! -s "$gh_log" ]]
    [[ "$output" == *"version 101 not deleted: re-read has a valid tag"* ]]
}

@test "outdated-tag cleanup does not delete an orphan whose re-read gained a tag" {
    local gh_log="$_STUB_DIR/reread-orphan-gh.log"

    run env PROJECT_ROOT="$PROJECT_ROOT" GH_LOG="$gh_log" GH_TOKEN="$GH_TOKEN" OWNER="$OWNER" DRY_RUN=false bash -c '
        source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
        build_valid_tags() { printf "%s\n" latest; }
        gh() {
            [[ "$*" == *"--method DELETE"* ]] && { printf "DELETE\n" >> "$GH_LOG"; return 0; }
            [[ "$*" == *"/versions/102"* ]] && { printf "%s\n" "{\"id\":102,\"metadata\":{\"container\":{\"tags\":[\"latest\"]}}}"; return 0; }
            [[ "$*" == *"/versions"* ]] && printf "%s\n" "[{\"id\":102,\"name\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"metadata\":{\"container\":{\"tags\":[]}}}]" || printf "%s\n" "{\"version_count\":1}"
        }
        main stale
    '

    [[ "$status" -eq 0 ]]
    [[ ! -s "$gh_log" ]]
    [[ "$output" == *"version 102 not deleted: re-read has tags"* ]]
}

@test "outdated-tag cleanup fails closed for failed or malformed version re-reads" {
    run env PROJECT_ROOT="$PROJECT_ROOT" GH_TOKEN="$GH_TOKEN" OWNER="$OWNER" DRY_RUN=false bash -c '
        source "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
        build_valid_tags() { printf "%s\n" latest; }
        for mode in failed malformed; do
            delete_log=$(mktemp)
            gh() {
                [[ "$*" == *"--method DELETE"* ]] && { printf "DELETE\n" >> "$delete_log"; return 0; }
                if [[ "$*" == *"/versions/101"* ]]; then
                    [[ "$mode" == failed ]] && return 1
                    printf "%s\n" "[]"
                    return 0
                fi
                [[ "$*" == *"/versions"* ]] && printf "%s\n" "[{\"id\":101,\"name\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"metadata\":{\"container\":{\"tags\":[\"stale\"]}}}]" || printf "%s\n" "{\"version_count\":1}"
            }
            main stale && exit 1
            [[ ! -s "$delete_log" ]] || exit 1
            rm -f "$delete_log"
        done
    '

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"reread_failures=1"* ]]
    [[ "$output" == *"not deleted: re-read failed"* ]]
}
