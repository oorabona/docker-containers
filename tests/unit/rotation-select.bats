#!/usr/bin/env bats

# End-to-end tests for the read-only extension rotation selector.  The real
# config supplies the pair universe; gh is the only mocked process boundary.

load "../test_helper"

setup() {
    setup_temp_dir
    export GH_TOKEN="test-token"
    export OWNER="test-owner"
    export EXT_CONFIG="$PROJECT_ROOT/postgres/extensions/config.yaml"
    export GH_FIXTURE_DIR="$TEST_TEMP_DIR/ghcr"
    export GH_ISSUES_JSON='[]'
    export GH_API_MODE="success"
    export GH_ISSUE_MODE="success"
    export GH_REPO_MODE="success"
    export GH_CALLS_FILE="$TEST_TEMP_DIR/gh-calls"
    export GITHUB_OUTPUT="$TEST_TEMP_DIR/github-output"
    export GH_STUB_PROBE=""
    mkdir -p "$GH_FIXTURE_DIR"
    : > "$GH_CALLS_FILE"
    : > "$GITHUB_OUTPUT"
    _write_fresh_registry
}

teardown() {
    teardown_temp_dir
    unset GH_TOKEN OWNER EXT_CONFIG GH_FIXTURE_DIR GH_ISSUES_JSON GH_API_MODE GH_ISSUE_MODE GH_REPO_MODE GH_CALLS_FILE GITHUB_OUTPUT GH_STUB_PROBE STALENESS_DAYS
}

_write_fresh_registry() {
    local ext_name
    local version
    local pg_major
    local records
    local record
    local fresh_updated_at

    fresh_updated_at=$(date -u -d '7 days ago' +'%Y-%m-%dT%H:%M:%SZ')

    while IFS=' ' read -r ext_name version; do
        records='[]'
        while IFS= read -r pg_major; do
            record=$(jq -cn --arg tag "pg${pg_major}-${version}" --arg fresh_updated_at "$fresh_updated_at" '[{
                id: 1,
                name: "sha256:test",
                updated_at: $fresh_updated_at,
                metadata: {container: {tags: [$tag]}}
            }]')
            records=$(jq -c --argjson record "$record" '. + $record' <<< "$records")
        done < <(yq -r '.pg_versions[]' "$EXT_CONFIG")
        printf '%s\n' "$records" > "$GH_FIXTURE_DIR/ext-${ext_name}.json"
    done < <(yq -r '.extensions | to_entries[] | .key + " " + .value.version' "$EXT_CONFIG")
}

_set_pair_updated_at() {
    local ext_name="$1"
    local pg_major="$2"
    local version="$3"
    local updated_at="$4"
    local fixture="$GH_FIXTURE_DIR/ext-${ext_name}.json"

    jq --arg tag "pg${pg_major}-${version}" --arg updated_at "$updated_at" '
      map(if any(.metadata.container.tags[]; . == $tag) then .updated_at = $updated_at else . end)
    ' "$fixture" > "$fixture.next"
    mv "$fixture.next" "$fixture"
}

_remove_pair_updated_at() {
    local ext_name="$1"
    local pg_major="$2"
    local version="$3"
    local fixture="$GH_FIXTURE_DIR/ext-${ext_name}.json"

    jq --arg tag "pg${pg_major}-${version}" '
      map(if any(.metadata.container.tags[]; . == $tag) then del(.updated_at) else . end)
    ' "$fixture" > "$fixture.next"
    mv "$fixture.next" "$fixture"
}

_remove_canonical_record() {
    local ext_name="$1"
    local pg_major="$2"
    local version="$3"
    local fixture="$GH_FIXTURE_DIR/ext-${ext_name}.json"

    jq --arg tag "pg${pg_major}-${version}" '
      map(select(any(.metadata.container.tags[]; . == $tag) | not))
    ' "$fixture" > "$fixture.next"
    mv "$fixture.next" "$fixture"
}

_duplicate_canonical_record() {
    local ext_name="$1"
    local pg_major="$2"
    local version="$3"
    local fixture="$GH_FIXTURE_DIR/ext-${ext_name}.json"

    jq --arg tag "pg${pg_major}-${version}" '
      . as $records
      | $records + [$records[] | select(any(.metadata.container.tags[]; . == $tag))]
    ' "$fixture" > "$fixture.next"
    mv "$fixture.next" "$fixture"
}

_replace_with_unobserved_record() {
    local ext_name="$1"
    local fixture="$GH_FIXTURE_DIR/ext-${ext_name}.json"

    jq -cn '[{
      id: 100,
      name: "sha256:unobserved",
      updated_at: "2020-01-01T00:00:00Z",
      metadata: {container: {tags: null}}
    }]' > "$fixture"
}

_append_unobserved_record() {
    local ext_name="$1"
    local fixture="$GH_FIXTURE_DIR/ext-${ext_name}.json"

    jq '. + [{
      id: 100,
      name: "sha256:unobserved",
      updated_at: "2020-01-01T00:00:00Z",
      metadata: {container: {tags: null}}
    }]' "$fixture" > "$fixture.next"
    mv "$fixture.next" "$fixture"
}

_expected_full_pairs() {
    local pg_major
    while IFS= read -r pg_major; do
        pgver="$pg_major" yq -r '
          . as $root
          | .flavors.full[] as $ext_name
          | select(
              ($root.extensions[$ext_name].disabled == true | not) and
              (($root.extensions[$ext_name].max_pg_version // 999) >= (strenv(pgver) | tonumber))
            )
          | [$ext_name, strenv(pgver), $root.extensions[$ext_name].version]
          | @tsv
        ' "$EXT_CONFIG"
    done < <(yq -r '.pg_versions[]' "$EXT_CONFIG") | LC_ALL=C sort -u
}

_run_selector() {
    run env \
        PROJECT_ROOT="$PROJECT_ROOT" \
        GH_TOKEN="$GH_TOKEN" \
        OWNER="$OWNER" \
        EXT_CONFIG="$EXT_CONFIG" \
        GH_FIXTURE_DIR="$GH_FIXTURE_DIR" \
        GH_ISSUES_JSON="$GH_ISSUES_JSON" \
        GH_API_MODE="$GH_API_MODE" \
        GH_ISSUE_MODE="$GH_ISSUE_MODE" \
        GH_REPO_MODE="$GH_REPO_MODE" \
        GH_CALLS_FILE="$GH_CALLS_FILE" \
        GITHUB_OUTPUT="$GITHUB_OUTPUT" \
        GH_STUB_PROBE="$GH_STUB_PROBE" \
        STALENESS_DAYS="${STALENESS_DAYS:-}" \
        bash -c '
            gh() {
                printf "%s\\n" "$*" >> "$GH_CALLS_FILE"
                if [[ "${1:-}" == "api" && "$#" -eq 7 && "${2:-}" == "-H" && "${3:-}" == "Accept: application/vnd.github+json" && "${4:-}" == "-H" && "${5:-}" == "X-GitHub-Api-Version: 2022-11-28" && "${6:-}" == "/users/${OWNER}/packages/container/ext-"*"/versions" && "${7:-}" == "--paginate" ]]; then
                    [[ "$GH_API_MODE" != "fail" ]] || return 1
                    if [[ "$GH_API_MODE" == "empty-output" ]]; then
                        return 0
                    fi
                    if [[ "$GH_API_MODE" == "invalid-json" ]]; then
                        printf "{\\n"
                        return 0
                    fi
                    local arg endpoint=""
                    for arg in "$@"; do
                        [[ "$arg" == /users/*/packages/container/*/versions ]] && endpoint="$arg"
                    done
                    local package_name="${endpoint%/versions}"
                    package_name="${package_name##*/}"
                    cat "$GH_FIXTURE_DIR/${package_name}.json"
                    return
                fi

                if [[ "${1:-}" == "repo" && "$#" -eq 6 && "${2:-}" == "view" && "${3:-}" == "--json" && "${4:-}" == "nameWithOwner" && "${5:-}" == "--jq" && "${6:-}" == ".nameWithOwner" ]]; then
                    [[ "$GH_REPO_MODE" != "fail" ]] || return 1
                    printf "%s\\n" "test-owner/test-repository"
                    return
                fi

                if [[ "${1:-}" == "issue" && "$#" -eq 12 && "${2:-}" == "list" && "${3:-}" == "--repo" && "${4:-}" == "test-owner/test-repository" && "${5:-}" == "--state" && "${6:-}" == "open" && "${7:-}" == "--label" && "${8:-}" == "extension-rotation-blocked" && "${9:-}" == "--json" && "${10:-}" == "number,body" && "${11:-}" == "--limit" && "${12:-}" == "1000" ]]; then
                    [[ "$GH_ISSUE_MODE" != "fail" ]] || return 1
                    printf "%s\\n" "$GH_ISSUES_JSON"
                    return
                fi

                printf "%s\\n" "unexpected gh invocation: $*" >&2
                return 98
            }
            export -f gh
            case "$GH_STUB_PROBE" in
                "") ;;
                api-form) gh api -f data=one /users/test-owner/packages/container/ext-pgvector/versions; exit $? ;;
                api-input) gh api --input payload.json /users/test-owner/packages/container/ext-pgvector/versions; exit $? ;;
                api-graphql) gh api graphql -f query="query { viewer { login } }"; exit $? ;;
                *) printf "%s\\n" "unknown gh stub probe: $GH_STUB_PROBE" >&2; exit 99 ;;
            esac
            exec "$PROJECT_ROOT/scripts/rotation-select.sh"
        '
}

_output_value() {
    local name="$1"
    sed -n "s/^${name}=//p" "$GITHUB_OUTPUT" | tail -1
}

@test "all fresh pairs select nothing and emit all output keys" {
    _run_selector

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Nothing is overdue."* ]]
    [[ "$(awk -F '\t' 'NF == 6 && $1 != "EXTENSION" { count++ } END { print count + 0 }' <<< "$output")" -eq "$(wc -l < <(_expected_full_pairs))" ]]
    [[ "$(_output_value selected)" == "false" ]]
    [[ -z "$(_output_value extension)" ]]
    [[ -z "$(_output_value major)" ]]
    [[ -z "$(_output_value version)" ]]
}

@test "a single overdue pair is selected" {
    _set_pair_updated_at pgvector 17 0.8.6 "2020-01-01T00:00:00Z"

    _run_selector

    [[ "$status" -eq 0 ]]
    [[ "$output" == *$'pgvector\t17\t0.8.6\t'*$'\tOVERDUE'* ]]
    [[ "$output" == *"Selected pair: pgvector pg17 0.8.6"* ]]
    [[ "$(_output_value selected)" == "true" ]]
    [[ "$(_output_value extension)" == "pgvector" ]]
    [[ "$(_output_value major)" == "17" ]]
    [[ "$(_output_value version)" == "0.8.6" ]]
}

@test "the oldest of two overdue pairs wins" {
    _set_pair_updated_at pgvector 17 0.8.6 "2021-01-01T00:00:00Z"
    _set_pair_updated_at postgis 18 3.6.4 "2020-01-01T00:00:00Z"

    _run_selector

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Selected pair: postgis pg18 3.6.4"* ]]
}

@test "an absent canonical record selects ahead of a dated overdue pair" {
    _remove_canonical_record pgvector 17 0.8.6
    _set_pair_updated_at postgis 18 3.6.4 "2020-01-01T00:00:00Z"

    _run_selector

    [[ "$status" -eq 0 ]]
    [[ "$output" == *$'pgvector\t17\t0.8.6\tunknown\tUNKNOWN\tELIGIBLE'* ]]
    [[ "$output" == *"Selected pair: pgvector pg17 0.8.6 (freshness UNKNOWN)"* ]]
    [[ "$(_output_value selected)" == "true" ]]
}

@test "a recent amd64 sibling cannot make an old multi-arch record fresh" {
    _set_pair_updated_at pgvector 17 0.8.6 "2020-01-01T00:00:00Z"
    local fixture="$GH_FIXTURE_DIR/ext-pgvector.json"
    jq '. + [{
      id: 99,
      name: "sha256:amd64",
      updated_at: "2099-01-01T00:00:00Z",
      metadata: {container: {tags: ["pg17-0.8.6-amd64"]}}
    }]' "$fixture" > "$fixture.next"
    mv "$fixture.next" "$fixture"

    _run_selector

    [[ "$status" -eq 0 ]]
    [[ "$output" == *$'pgvector\t17\t0.8.6\t'*$'\tOVERDUE'* ]]
    [[ "$output" == *"Selected pair: pgvector pg17 0.8.6"* ]]
}

@test "a record carrying only amd64 is UNKNOWN and is selected" {
    local fixture="$GH_FIXTURE_DIR/ext-pgvector.json"
    jq 'map(select(any(.metadata.container.tags[]; . != "pg17-0.8.6"))) + [{
      id: 100,
      name: "sha256:amd64-only",
      updated_at: "2099-01-01T00:00:00Z",
      metadata: {container: {tags: ["pg17-0.8.6-amd64"]}}
    }]' "$fixture" > "$fixture.next"
    mv "$fixture.next" "$fixture"

    _run_selector

    [[ "$status" -eq 0 ]]
    [[ "$output" == *$'pgvector\t17\t0.8.6\tunknown\tUNKNOWN\tELIGIBLE'* ]]
    [[ "$output" == *"Selected pair: pgvector pg17 0.8.6 (freshness UNKNOWN)"* ]]
}

@test "missing updated_at is UNKNOWN and selects ahead of a dated overdue pair" {
    _remove_pair_updated_at pgvector 17 0.8.6
    _set_pair_updated_at postgis 18 3.6.4 "2020-01-01T00:00:00Z"

    _run_selector

    [[ "$status" -eq 0 ]]
    [[ "$output" == *$'pgvector\t17\t0.8.6\tunknown\tUNKNOWN\tELIGIBLE'* ]]
    [[ "$output" == *"Selected pair: pgvector pg17 0.8.6 (freshness UNKNOWN)"* ]]
}

@test "malformed updated_at is UNKNOWN and selects ahead of a dated overdue pair" {
    _set_pair_updated_at pgvector 17 0.8.6 "not-a-date"
    _set_pair_updated_at postgis 18 3.6.4 "2020-01-01T00:00:00Z"

    _run_selector

    [[ "$status" -eq 0 ]]
    [[ "$output" == *$'pgvector\t17\t0.8.6\tunknown\tUNKNOWN\tELIGIBLE'* ]]
    [[ "$output" == *"Selected pair: pgvector pg17 0.8.6 (freshness UNKNOWN)"* ]]
}

@test "a canonical record dated beyond five minutes in the future is UNKNOWN and a candidate" {
    _set_pair_updated_at pgvector 17 0.8.6 "2099-01-01T00:00:00Z"

    _run_selector

    [[ "$status" -eq 0 ]]
    [[ "$output" == *$'pgvector\t17\t0.8.6\tunknown\tUNKNOWN\tELIGIBLE'* ]]
    [[ "$output" == *"Selected pair: pgvector pg17 0.8.6 (freshness UNKNOWN)"* ]]
}

@test "two canonical records do not yield a freshness verdict" {
    _duplicate_canonical_record pgvector 17 0.8.6

    _run_selector

    [[ "$status" -eq 0 ]]
    [[ "$output" == *$'pgvector\t17\t0.8.6\tunknown\tUNKNOWN\tELIGIBLE'* ]]
    [[ "$output" == *"Selected pair: pgvector pg17 0.8.6 (freshness UNKNOWN)"* ]]
}

@test "GHCR API failure selects nothing and exits non-zero" {
    export GH_API_MODE="fail"

    _run_selector

    [[ "$status" -ne 0 ]]
    [[ "$output" != *"Selected pair:"* ]]
    [[ "$output" == *"GHCR version listing failed"* ]]
}

@test "invalid GHCR JSON selects nothing and exits non-zero" {
    export GH_API_MODE="invalid-json"

    _run_selector

    [[ "$status" -ne 0 ]]
    [[ "$output" != *"Selected pair:"* ]]
    [[ "$output" == *"GHCR version listing failed"* ]]
}

@test "a zero-byte GHCR response refuses instead of becoming an empty registry" {
    export GH_API_MODE="empty-output"

    _run_selector

    [[ "$status" -ne 0 ]]
    [[ "$output" == *"GHCR version listing failed"* ]]
    [[ "$output" != *$'pgvector\t17\t0.8.6\tunknown'* ]]
}

@test "an extension listing whose only record has unobserved tags selects nothing and exits non-zero" {
    _replace_with_unobserved_record pgvector

    _run_selector

    if [[ "$status" -eq 0 \
        || "$output" == *"Selected pair:"* \
        || "$(_output_value selected)" != "false" ]]; then
        printf '%s\n' 'ASSERTION FAILED: an extension listing whose only record has unobserved tags must exit non-zero and select no pair'
        return 1
    fi
    [[ "$output" == *"GHCR version listing for ext-pgvector has unobserved tags"* ]]
}

@test "an unobserved record alongside a canonical tag selects nothing and exits non-zero" {
    _append_unobserved_record pgvector

    _run_selector

    if [[ "$status" -eq 0 \
        || "$output" == *"Selected pair:"* \
        || "$(_output_value selected)" != "false" ]]; then
        printf '%s\n' 'ASSERTION FAILED: an unobserved record alongside a canonical tag must exit non-zero and select no pair'
        return 1
    fi
    [[ "$output" == *"GHCR version listing for ext-pgvector has unobserved tags"* ]]
}

@test "unobserved tags are a registry failure rather than an UNKNOWN pair" {
    _replace_with_unobserved_record pgvector

    _run_selector

    if [[ "$status" -eq 0 \
        || "$output" == *"Selected pair:"* \
        || "$output" == *$'EXTENSION\tMAJOR\tCEILING\tAGE_DAYS'* ]]; then
        printf '%s\n' 'ASSERTION FAILED: unobserved tags must be a registry failure, not an UNKNOWN pair'
        return 1
    fi
    [[ "$(_output_value selected)" == "false" ]]
}

@test "blocking issue query failure selects nothing and exits non-zero" {
    export GH_ISSUE_MODE="fail"

    _run_selector

    [[ "$status" -ne 0 ]]
    [[ "$output" != *"Selected pair:"* ]]
    [[ "$output" == *"Could not list open extension-rotation-blocked issues"* ]]
}

@test "blocking issue listing is scoped to the configuration repository" {
    _run_selector

    [[ "$status" -eq 0 ]]
    grep -Fx -- 'repo view --json nameWithOwner --jq .nameWithOwner' "$GH_CALLS_FILE"
    grep -Fx -- 'issue list --repo test-owner/test-repository --state open --label extension-rotation-blocked --json number,body --limit 1000' "$GH_CALLS_FILE"
}

@test "an unresolvable configuration repository selects nothing and exits non-zero" {
    export GH_REPO_MODE="fail"

    _run_selector

    [[ "$status" -ne 0 ]]
    [[ "$output" != *"Selected pair:"* ]]
    [[ "$output" == *"Could not establish the repository for extension rotation"* ]]
    ! grep -q '^issue list ' "$GH_CALLS_FILE"
}

@test "a current blocking issue moves selection to the next-oldest pair" {
    _set_pair_updated_at pgvector 17 0.8.6 "2020-01-01T00:00:00Z"
    _set_pair_updated_at postgis 18 3.6.4 "2021-01-01T00:00:00Z"
    export GH_ISSUES_JSON='[{"number": 1246, "body": "rotation-pair: pgvector pg17 0.8.6"}]'

    _run_selector

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Blocking marker #1246: rotation-pair: pgvector pg17 0.8.6 — matched current pair"* ]]
    [[ "$output" == *$'pgvector\t17\t0.8.6\t'*$'\tOVERDUE\tBLOCKED'* ]]
    [[ "$output" == *"Selected pair: postgis pg18 3.6.4"* ]]
}

@test "a blocked UNKNOWN pair is distinguishable from an eligible UNKNOWN pair" {
    _remove_pair_updated_at pgvector 17 0.8.6
    _set_pair_updated_at postgis 18 3.6.4 "2020-01-01T00:00:00Z"
    export GH_ISSUES_JSON='[{"number": 1248, "body": "rotation-pair: pgvector pg17 0.8.6"}]'

    _run_selector

    [[ "$status" -eq 0 ]]
    [[ "$output" == *$'pgvector\t17\t0.8.6\tunknown\tUNKNOWN\tBLOCKED'* ]]
    [[ "$output" == *"Selected pair: postgis pg18 3.6.4"* ]]
    [[ "$output" != *"Selected pair: pgvector pg17 0.8.6"* ]]
}

@test "two UNKNOWN pairs choose the lexical winner regardless configured order" {
    _remove_pair_updated_at pgvector 17 0.8.6
    _remove_pair_updated_at postgis 18 3.6.4

    _run_selector

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Selected pair: pgvector pg17 0.8.6 (freshness UNKNOWN)"* ]]

    local reversed_config="$TEST_TEMP_DIR/reversed-full-config.yaml"
    yq '.flavors.full |= reverse' "$EXT_CONFIG" > "$reversed_config"
    export EXT_CONFIG="$reversed_config"

    _run_selector

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Selected pair: pgvector pg17 0.8.6 (freshness UNKNOWN)"* ]]
}

@test "the selector uses only the documented gh read allowlist on a successful path" {
    _run_selector

    [[ "$status" -eq 0 ]]
}

@test "a stale-version blocking issue matches nothing" {
    _set_pair_updated_at pgvector 17 0.8.6 "2020-01-01T00:00:00Z"
    export GH_ISSUES_JSON='[{"number": 1247, "body": "rotation-pair: pgvector pg17 0.8.5"}]'

    _run_selector

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Blocking marker #1247: rotation-pair: pgvector pg17 0.8.5 — did not match a current pair"* ]]
    [[ "$output" == *"Selected pair: pgvector pg17 0.8.6"* ]]
}

@test "an invalid STALENESS_DAYS is rejected before gh is called" {
    export STALENESS_DAYS="0"

    _run_selector

    [[ "$status" -ne 0 ]]
    [[ "$output" == *"STALENESS_DAYS must be an integer from 1 through 9999 days"* ]]
    [[ ! -s "$GH_CALLS_FILE" ]]
}

@test "a non-digit STALENESS_DAYS is rejected before gh is called" {
    export STALENESS_DAYS="thirty"

    _run_selector

    [[ "$status" -ne 0 ]]
    [[ "$output" == *"STALENESS_DAYS must be an integer from 1 through 9999 days"* ]]
    [[ ! -s "$GH_CALLS_FILE" ]]
}

@test "the largest accepted STALENESS_DAYS is accepted" {
    export STALENESS_DAYS="9999"

    _run_selector

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Nothing is overdue."* ]]
}

@test "out-of-range STALENESS_DAYS values are rejected before gh is called" {
    local days
    for days in 10000 9223372036854775808; do
        export STALENESS_DAYS="$days"

        _run_selector

        [[ "$status" -ne 0 ]]
        [[ "$output" == *"STALENESS_DAYS must be an integer from 1 through 9999 days"* ]]
        [[ ! -s "$GH_CALLS_FILE" ]]
    done
}

@test "an extension config rejected by the shared schema validator is not read" {
    local invalid_config="$TEST_TEMP_DIR/invalid-config.yaml"
    cp "$EXT_CONFIG" "$invalid_config"
    sed -i '0,/^  pgvector:/s//  "::warning::forged":/' "$invalid_config"
    export EXT_CONFIG="$invalid_config"

    _run_selector

    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Extension config failed schema validation"* ]]
    [[ ! -s "$GH_CALLS_FILE" ]]
}

@test "a CRLF-terminated blocking marker blocks its pair" {
    _set_pair_updated_at pgvector 17 0.8.6 "2020-01-01T00:00:00Z"
    _set_pair_updated_at postgis 18 3.6.4 "2021-01-01T00:00:00Z"
    export GH_ISSUES_JSON=$'[{"number": 1250, "body": "rotation-pair: pgvector pg17 0.8.6\\r\\n"}]'

    _run_selector

    [[ "$status" -eq 0 ]]
    [[ "$output" == *$'pgvector\t17\t0.8.6\t'*$'\tOVERDUE\tBLOCKED'* ]]
    [[ "$output" == *"Selected pair: postgis pg18 3.6.4"* ]]
}

@test "a blocking marker with trailing text or spaces does not block its pair" {
    _set_pair_updated_at pgvector 17 0.8.6 "2020-01-01T00:00:00Z"
    export GH_ISSUES_JSON='[{"number": 1251, "body": "rotation-pair: pgvector pg17 0.8.6 trailing\nrotation-pair: pgvector pg17 0.8.6 "}]'

    _run_selector

    [[ "$status" -eq 0 ]]
    [[ "$output" == *$'pgvector\t17\t0.8.6\t'*$'\tOVERDUE\tELIGIBLE'* ]]
    [[ "$output" == *"Selected pair: pgvector pg17 0.8.6"* ]]
}

@test "a registry failure prints no per-pair status rows" {
    export GH_API_MODE="fail"

    _run_selector

    [[ "$status" -ne 0 ]]
    [[ "$output" != *$'EXTENSION\tMAJOR\tCEILING\tAGE_DAYS'* ]]
    [[ "$output" != *$'pgvector\t17\t0.8.6'* ]]
}

@test "an issue listing at the cap refuses to select" {
    export GH_ISSUES_JSON
    GH_ISSUES_JSON=$(jq -cn '[range(1; 1001) | {number: ., body: ""}]')

    _run_selector

    [[ "$status" -ne 0 ]]
    [[ "$output" == *"reached the 1000-issue cap"* ]]
    [[ "$output" != *"Selected pair:"* ]]
}

@test "an OWNER different from the resolved repository owner refuses to select" {
    export OWNER="upstream-owner"

    _run_selector

    [[ "$status" -ne 0 ]]
    [[ "$output" == *"does not match rotation repository owner"* ]]
    [[ "$output" != *"Selected pair:"* ]]
    ! grep -q '^api ' "$GH_CALLS_FILE"
}

@test "every blocked candidate, including an undated one, is not reported as nothing overdue" {
    _remove_pair_updated_at pgvector 17 0.8.6
    export GH_ISSUES_JSON='[{"number": 1252, "body": "rotation-pair: pgvector pg17 0.8.6"}]'

    _run_selector

    [[ "$status" -eq 0 ]]
    [[ "$output" == *$'pgvector\t17\t0.8.6\tunknown\tUNKNOWN\tBLOCKED'* ]]
    [[ "$output" == *"every selection candidate is blocked"* ]]
    [[ "$output" != *"Nothing is overdue."* ]]
}

@test "a carriage return in a version refuses before the pair stream or gh" {
    local invalid_config="$TEST_TEMP_DIR/cr-version-config.yaml"
    cp "$EXT_CONFIG" "$invalid_config"
    local invalid_version=$'1.2.3\rselected=false'
    invalid_version="$invalid_version" yq -i '.extensions.pgvector.version = strenv(invalid_version)' "$invalid_config"
    export EXT_CONFIG="$invalid_config"

    _run_selector

    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Invalid ceiling version for pgvector/pg18; expected a numeric-dotted version"* ]]
    [[ ! -s "$GH_CALLS_FILE" ]]
    [[ "$(cat "$GITHUB_OUTPUT")" == $'selected=false\nextension=\nmajor=\nversion=' ]]
}

@test "a quote in TMPDIR cannot execute trap text" {
    local trap_probe="$TEST_TEMP_DIR/trap-probe"
    local quoted_tmpdir="${TEST_TEMP_DIR}/tmp'\$(touch ${trap_probe})'"
    mkdir -p "$quoted_tmpdir"
    export TMPDIR="$quoted_tmpdir"

    _run_selector

    [[ "$status" -eq 0 ]]
    [[ ! -e "$trap_probe" ]]
}

@test "the selected overdue count excludes the threshold" {
    _set_pair_updated_at pgvector 17 0.8.6 "$(date -u -d '31 days ago' +'%Y-%m-%dT%H:%M:%SZ')"

    _run_selector

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Selected pair: pgvector pg17 0.8.6 (1 days overdue)"* ]]
}

@test "the read-only gh allowlist rejects form, input, and GraphQL API calls" {
    local probe
    for probe in api-form api-input api-graphql; do
        export GH_STUB_PROBE="$probe"
        _run_selector
        [[ "$status" -eq 98 ]]
        [[ "$output" == *"unexpected gh invocation"* ]]
    done
}
