#!/usr/bin/env bats

# Unit tests for scripts/track-artifact-pending.sh (escalation of a candidate
# stuck in `artifact-pending`) and the status exposed by artifact_reachable.
#
# Mutation guards:
#   opening the issue on first sight (no threshold) fails "below threshold".
#   not de-duplicating by label fails "de-duplication" (second create).
#   forgetting to clear state / close on resolution fails "auto-close".
#   keeping the old first_seen across a new candidate fails "superseded".

load "../test_helper"

setup() {
    setup_temp_dir
    export SCRIPT="$SCRIPTS_DIR/track-artifact-pending.sh"
    export GH_TOKEN="fake-token"
    export GITHUB_REPOSITORY="oorabona/docker-containers"
    export GH_LOG="$TEST_TEMP_DIR/gh.log"
    export GH_OPEN_FILE="$TEST_TEMP_DIR/gh.open"
    : > "$GH_LOG"
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
    "issue list")
        if [[ -f "$GH_OPEN_FILE" ]]; then
            printf '[{"number":%s,"title":"x"}]\n' "$(cat "$GH_OPEN_FILE")"
        else
            echo '[]'
        fi ;;
    "issue create") echo 101 > "$GH_OPEN_FILE"; echo "https://github.com/o/r/issues/101" ;;
    "issue close")  rm -f "$GH_OPEN_FILE" ;;
esac
exit 0
EOF
    cat > "$TEST_TEMP_DIR/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/gh" "$TEST_TEMP_DIR/bin/sleep"
    export ORIG_PATH="$PATH"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    # work repo + bare remote that holds the state tags
    git init -q --bare "$TEST_TEMP_DIR/remote.git"
    git init -q "$TEST_TEMP_DIR/work"
    git -C "$TEST_TEMP_DIR/work" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
    git -C "$TEST_TEMP_DIR/work" remote add origin "$TEST_TEMP_DIR/remote.git"
    export DAY=86400 T0=1800000000
}

teardown() {
    export PATH="$ORIG_PATH"
    teardown_temp_dir
}

# run_tracker <epoch> <candidate> [status] [pending_status]
run_tracker() {
    local at="$1" cand="$2" st="${3:-artifact-pending}" pst="${4:-404}"
    local json
    json=$(jq -nc --arg c "$cand" --arg s "$st" --arg p "$pst" \
        '[{container:"openvpn",latest_version:$c,status:$s,update_available:($s=="update-available"),
           pending_urls:["https://example.org/rel/openvpn-2.7.8.tar.gz","https://example.org/rel/openvpn-2.7.8.tar.gz.asc"],
           pending_status:$p}]')
    cd "$TEST_TEMP_DIR/work" || return 1
    ARTIFACT_PENDING_NOW="$at" run "$SCRIPT" <<< "$json"
}

creates() { grep -c '^issue create' "$GH_LOG" || true; }

@test "below threshold: tracks the candidate but opens no issue" {
    run_tracker "$T0" v2.7.8
    [ "$status" -eq 0 ]
    run_tracker $((T0 + 2 * DAY)) v2.7.8
    [ "$status" -eq 0 ]
    [ "$(creates)" -eq 0 ]
    ! grep -q '^issue ' "$GH_LOG"
    git -C "$TEST_TEMP_DIR/remote.git" tag -l 'artifact-pending/*' | grep -qx 'artifact-pending/openvpn'
}

@test "above threshold: opens one issue with candidate, URLs and last status" {
    run_tracker "$T0" v2.7.8
    run_tracker $((T0 + 3 * DAY)) v2.7.8 artifact-pending 404
    [ "$status" -eq 0 ]
    [ "$(creates)" -eq 1 ]
    grep -q -- '--label automation,artifact-pending:openvpn' "$GH_LOG"
    grep -q 'v2.7.8' "$GH_LOG"
    grep -q 'openvpn-2.7.8.tar.gz.asc' "$GH_LOG"
    grep -q 'Last status seen\*\* | 404' "$GH_LOG"
}

@test "de-duplication: later pending runs refresh the open issue, never create another" {
    run_tracker "$T0" v2.7.8
    run_tracker $((T0 + 3 * DAY)) v2.7.8
    run_tracker $((T0 + 4 * DAY)) v2.7.8 artifact-pending timeout
    [ "$status" -eq 0 ]
    [ "$(creates)" -eq 1 ]
    grep -q '^issue edit 101' "$GH_LOG"
    grep -q 'Last status seen\*\* | timeout' "$GH_LOG"
}

@test "auto-close: artifact found closes the issue and clears the state" {
    run_tracker "$T0" v2.7.8
    run_tracker $((T0 + 3 * DAY)) v2.7.8
    run_tracker $((T0 + 4 * DAY)) v2.7.8 update-available
    [ "$status" -eq 0 ]
    grep -q '^issue close 101' "$GH_LOG"
    [ -z "$(git -C "$TEST_TEMP_DIR/remote.git" tag -l 'artifact-pending/*')" ]
}

@test "auto-close: a superseding candidate closes the issue and restarts the clock" {
    run_tracker "$T0" v2.7.8
    run_tracker $((T0 + 3 * DAY)) v2.7.8
    run_tracker $((T0 + 4 * DAY)) v2.7.9
    [ "$status" -eq 0 ]
    grep -q '^issue close 101' "$GH_LOG"
    [ "$(creates)" -eq 1 ]
    # the new candidate starts below the threshold: no second issue yet
    run_tracker $((T0 + 5 * DAY)) v2.7.9
    [ "$(creates)" -eq 1 ]
}

@test "resolving within the threshold leaves no issue and no state" {
    run_tracker "$T0" v2.7.8
    run_tracker $((T0 + DAY)) v2.7.8 update-available
    [ "$status" -eq 0 ]
    ! grep -q '^issue ' "$GH_LOG"
    [ -z "$(git -C "$TEST_TEMP_DIR/remote.git" tag -l 'artifact-pending/*')" ]
}

@test "lookup failures neither escalate nor reset the pending clock" {
    run_tracker "$T0" v2.7.8
    run_tracker $((T0 + DAY)) v2.7.8 upstream-lookup-failed
    run_tracker $((T0 + 3 * DAY)) v2.7.8
    [ "$(creates)" -eq 1 ]
}

# ─── artifact_reachable exposes the last status ──────────────────────────────

@test "artifact_reachable exposes the last status (404, 503, timeout, 302, 200)" {
    cd "$TEST_TEMP_DIR" || exit 1
    cp "$PROJECT_ROOT/tests/fixtures/artifact-curl-stub.sh" bin/curl
    source "$PROJECT_ROOT/helpers/artifact-utils.sh"
    local code url=https://example.org/a.tgz
    for code in 404 503 timeout 302; do
        CURL_RULES="a.tgz $code $code" artifact_reachable "$url" && return 1
        if [[ "$code" == timeout ]]; then
            [ "$ARTIFACT_LAST_STATUS" = timeout ]
        else
            [ "$ARTIFACT_LAST_STATUS" = "$code" ]
        fi
    done
    CURL_RULES="a.tgz 200 200" artifact_reachable "$url"
    [ "$ARTIFACT_LAST_STATUS" = 200 ]
}

@test "artifact_ready reports the probed URLs and blocking status when pending" {
    cd "$TEST_TEMP_DIR" || exit 1
    cp "$PROJECT_ROOT/tests/fixtures/artifact-curl-stub.sh" bin/curl
    source "$PROJECT_ROOT/helpers/logging.sh"
    source "$PROJECT_ROOT/helpers/artifact-utils.sh"
    mkdir app
    printf 'artifact_url: "https://example.org/rel/${UPSTREAM_VERSION}/t.tgz"\nartifact_signature_suffix: ".asc"\nbuild_args:\n  FOO: bar\n' > app/config.yaml
    CURL_RULES='.asc 404 404' artifact_ready app v1.2.3 && return 1
    [ "$ARTIFACT_PENDING_STATUS" = 404 ]
    [ "$ARTIFACT_PENDING_URLS" = "https://example.org/rel/v1.2.3/t.tgz https://example.org/rel/v1.2.3/t.tgz.asc" ]
}
