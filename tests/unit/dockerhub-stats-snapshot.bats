#!/usr/bin/env bats

load "../test_helper"

setup() {
    setup_temp_dir
    TEST_REPO="$TEST_TEMP_DIR/repo"
    mkdir -p "$TEST_REPO/scripts" "$TEST_REPO/helpers" "$TEST_REPO/bin"

    ln -s "$SCRIPTS_DIR/snapshot-stats.sh" "$TEST_REPO/scripts/snapshot-stats.sh"
    cp "$HELPERS_DIR/logging.sh" "$TEST_REPO/helpers/logging.sh"

    for container in alpha beta gamma; do
        mkdir -p "$TEST_REPO/$container"
        printf 'FROM alpine:3.21\n' > "$TEST_REPO/$container/Dockerfile"
    done

    mkdir -p "$TEST_REPO/.build-lineage"
    for day in 01 02 03 04 05; do
        for container in alpha beta gamma; do
            jq -nc \
                --arg ts "2026-01-${day}T00:00:00Z" \
                --arg date "2026-01-${day}" \
                --arg container "$container" \
                --argjson pull_count "$((10#$day * 100))" \
                --argjson star_count 1 \
                '{ts: $ts, date: $date, container: $container, pull_count: $pull_count, star_count: $star_count, source: "dockerhub"}' \
                >> "$TEST_REPO/.build-lineage/stats-history.jsonl"
        done
    done

    CURL_LOG="$TEST_TEMP_DIR/curl.log"
    export CURL_LOG
    cat > "$TEST_REPO/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url="${*: -1}"
container="${url%/}"
container="${container##*/}"
echo "$container" >> "$CURL_LOG"
case "$container" in
  alpha) printf '{"pull_count":600,"star_count":6}\n' ;;
  beta)  printf '{"pull_count":700,"star_count":7}\n' ;;
  gamma) printf '{"pull_count":800,"star_count":8}\n' ;;
  *)     printf '{"pull_count":0,"star_count":0}\n' ;;
esac
EOF
    chmod +x "$TEST_REPO/bin/curl"
    export PATH="$TEST_REPO/bin:$PATH"
}

teardown() {
    teardown_temp_dir
}

install_jq_counter() {
    REAL_JQ=$(command -v jq)
    JQ_COUNT_FILE="$TEST_TEMP_DIR/jq-count"
    echo 0 > "$JQ_COUNT_FILE"
    cat > "$TEST_REPO/bin/jq" <<EOF
#!/usr/bin/env bash
set -euo pipefail
count=\$(cat "$JQ_COUNT_FILE")
echo \$((count + 1)) > "$JQ_COUNT_FILE"
exec "$REAL_JQ" "\$@"
EOF
    chmod +x "$TEST_REPO/bin/jq"
    export REAL_JQ JQ_COUNT_FILE
}

@test "snapshot-stats migrates legacy history and remains idempotent across two same-day runs" {
    [ ! -e "$TEST_REPO/stats/dockerhub-pull-history.jsonl" ]

    run bash -c 'cd "$1" && ./scripts/snapshot-stats.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]

    run bash -c 'cd "$1" && ./scripts/snapshot-stats.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]

    stats_file="$TEST_REPO/stats/dockerhub-pull-history.jsonl"
    [ -f "$stats_file" ]

    total_rows=$(jq -s 'length' "$stats_file")
    [ "$total_rows" -eq 18 ]

    duplicate_pairs=$(jq -s '
        group_by(.date + "/" + .container)
        | map(select(length > 1))
        | length
    ' "$stats_file")
    [ "$duplicate_pairs" -eq 0 ]

    for day in 01 02 03 04 05; do
        for container in alpha beta gamma; do
            jq -e \
                --arg date "2026-01-${day}" \
                --arg container "$container" \
                'select(.date == $date and .container == $container)' \
                "$stats_file" >/dev/null
        done
    done

    today="$(date -u +%Y-%m-%d)"
    today_rows=$(jq -s --arg today "$today" '[.[] | select(.date == $today)] | length' "$stats_file")
    [ "$today_rows" -eq 3 ]

    curl_calls=$(wc -l < "$CURL_LOG")
    [ "$curl_calls" -eq 3 ]
}

@test "snapshot-stats skips malformed legacy rows so today's real fetch is not blocked" {
    today="$(date -u +%Y-%m-%d)"
    jq -nc \
        --arg ts "${today}T00:00:00Z" \
        --arg date "$today" \
        --arg container "alpha" \
        '{ts: $ts, date: $date, container: $container, pull_count: "not-a-number", star_count: 1, source: "dockerhub"}' \
        >> "$TEST_REPO/.build-lineage/stats-history.jsonl"

    run bash -c 'cd "$1" && ./scripts/snapshot-stats.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipped 1 malformed legacy Docker Hub stats entries during migration"* ]]

    stats_file="$TEST_REPO/stats/dockerhub-pull-history.jsonl"

    jq -s -e --arg today "$today" '
        [.[] | select(.date == $today and .container == "alpha" and .pull_count == 600)]
        | length == 1
    ' "$stats_file" >/dev/null

    jq -s -e --arg today "$today" '
        [.[] | select(.date == $today and .container == "alpha" and (.pull_count | type) != "number")]
        | length == 0
    ' "$stats_file" >/dev/null

    grep -qx "alpha" "$CURL_LOG"
}

@test "snapshot-stats never migrates a same-day legacy row, always live-fetches today" {
    # Regression lock (#876 hardening): the old mechanism that wrote
    # .build-lineage/stats-history.jsonl was still active up until this
    # migration, so at cutover the legacy cache plausibly already has a
    # TODAY row (fetched hours earlier, now stale — Docker Hub pull_count
    # only increases). Migrating it would make snapshot_exists_for_today
    # wrongly treat that container as "already done", silently skipping a
    # live re-fetch for the rest of the day. Reconciliation must exclude
    # today's date — it is a one-time HISTORICAL backfill, never a
    # substitute for today's fetch.
    today="$(date -u +%Y-%m-%d)"
    jq -nc \
        --arg ts "${today}T00:00:00Z" \
        --arg date "$today" \
        --arg container "alpha" \
        --argjson pull_count 111 \
        --argjson star_count 1 \
        '{ts: $ts, date: $date, container: $container, pull_count: $pull_count, star_count: $star_count, source: "dockerhub"}' \
        >> "$TEST_REPO/.build-lineage/stats-history.jsonl"

    run bash -c 'cd "$1" && ./scripts/snapshot-stats.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]

    stats_file="$TEST_REPO/stats/dockerhub-pull-history.jsonl"

    # The stale legacy value (111) never made it in; the live fetch (600) did.
    jq -s -e --arg today "$today" '
        [.[] | select(.date == $today and .container == "alpha")]
        | length == 1 and .[0].pull_count == 600
    ' "$stats_file" >/dev/null

    grep -qx "alpha" "$CURL_LOG"
}

@test "snapshot-stats SNAPSHOT_DATE_OVERRIDE pins the bucket date regardless of the real clock" {
    # Regression lock: commit-stats-snapshot.sh's retry loop can span a UTC
    # midnight rollover across its 3 attempts. Without a pinned date, a later
    # attempt would silently start filling the NEW day instead of finishing
    # the one the run actually started for, permanently abandoning the
    # original day's still-missing rows while reporting success.
    export SNAPSHOT_DATE_OVERRIDE="2026-05-01"

    run bash -c 'cd "$1" && ./scripts/snapshot-stats.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]

    stats_file="$TEST_REPO/stats/dockerhub-pull-history.jsonl"
    jq -s -e '
        [.[] | select(.date == "2026-05-01")]
        | length == 3
        and (map(.container) | sort == ["alpha", "beta", "gamma"])
    ' "$stats_file" >/dev/null

    real_today="$(date -u +%Y-%m-%d)"
    jq -s -e --arg real_today "$real_today" '
        [.[] | select(.date == $real_today)] | length == 0
    ' "$stats_file" >/dev/null
}

@test "snapshot-stats migrates duplicate legacy rows with last row winning" {
    jq -nc \
        --arg ts "2026-01-02T23:59:00Z" \
        --arg date "2026-01-02" \
        --arg container "alpha" \
        --argjson pull_count 999 \
        --argjson star_count 9 \
        '{ts: $ts, date: $date, container: $container, pull_count: $pull_count, star_count: $star_count, source: "dockerhub"}' \
        >> "$TEST_REPO/.build-lineage/stats-history.jsonl"

    run bash -c 'cd "$1" && ./scripts/snapshot-stats.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]

    stats_file="$TEST_REPO/stats/dockerhub-pull-history.jsonl"
    jq -s -e '
        [.[] | select(.date == "2026-01-02" and .container == "alpha")]
        | length == 1 and .[0].pull_count == 999 and .[0].star_count == 9
    ' "$stats_file" >/dev/null

    total_rows=$(jq -s 'length' "$stats_file")
    [ "$total_rows" -eq 18 ]
}

@test "snapshot-stats exits nonzero when every fetch fails and no container is snapshotted" {
    cat > "$TEST_REPO/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url="${*: -1}"
container="${url%/}"
container="${container##*/}"
echo "$container" >> "$CURL_LOG"
exit 22
EOF
    chmod +x "$TEST_REPO/bin/curl"

    run bash -c 'cd "$1" && ./scripts/snapshot-stats.sh' _ "$TEST_REPO"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Stats snapshot: 0 new, 0 already-today, 3 failed"* ]]

    stats_file="$TEST_REPO/stats/dockerhub-pull-history.jsonl"
    [ -f "$stats_file" ]
    total_rows=$(jq -s 'length' "$stats_file")
    [ "$total_rows" -eq 15 ]

    curl_calls=$(wc -l < "$CURL_LOG")
    [ "$curl_calls" -eq 3 ]
}

@test "snapshot-stats exits nonzero for partial malformed Docker Hub response without writing a bad row" {
    cat > "$TEST_REPO/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url="${*: -1}"
container="${url%/}"
container="${container##*/}"
echo "$container" >> "$CURL_LOG"
case "$container" in
  alpha) printf '{"message":"rate limited","star_count":4}\n' ;;
  beta)  printf '{"pull_count":700,"star_count":7}\n' ;;
  gamma) printf '{"pull_count":800,"star_count":8}\n' ;;
  *)     printf '{"pull_count":0,"star_count":0}\n' ;;
esac
EOF
    chmod +x "$TEST_REPO/bin/curl"

    today="$(date -u +%Y-%m-%d)"
    run bash -c 'cd "$1" && ./scripts/snapshot-stats.sh' _ "$TEST_REPO"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unexpected Docker Hub stats response for alpha"* ]]
    [[ "$output" == *"rate limited"* ]]
    [[ "$output" == *"Stats snapshot: 2 new, 0 already-today, 1 failed"* ]]

    stats_file="$TEST_REPO/stats/dockerhub-pull-history.jsonl"
    jq -s -e --arg today "$today" '
        [.[] | select(.date == $today and .container == "alpha")]
        | length == 0
    ' "$stats_file" >/dev/null
    jq -s -e --arg today "$today" '
        [.[] | select(.date == $today)]
        | map(.container)
        | sort == ["beta", "gamma"]
    ' "$stats_file" >/dev/null
}

@test "snapshot-stats uses bounded jq passes for large reconciliation and idempotency inputs" {
    today="$(date -u +%Y-%m-%d)"
    mkdir -p "$TEST_REPO/stats"
    for i in $(seq -w 1 250); do
        jq -nc \
            --arg ts "2025-12-${i}T00:00:00Z" \
            --arg date "2025-12-${i}" \
            --arg container "alpha" \
            --argjson pull_count "$((10#$i))" \
            --argjson star_count 1 \
            '{ts: $ts, date: $date, container: $container, pull_count: $pull_count, star_count: $star_count, source: "dockerhub"}' \
            >> "$TEST_REPO/.build-lineage/stats-history.jsonl"
    done
    for container in alpha beta gamma; do
        jq -nc \
            --arg ts "${today}T00:00:00Z" \
            --arg date "$today" \
            --arg container "$container" \
            --argjson pull_count 42 \
            --argjson star_count 1 \
            '{ts: $ts, date: $date, container: $container, pull_count: $pull_count, star_count: $star_count, source: "dockerhub"}' \
            >> "$TEST_REPO/stats/dockerhub-pull-history.jsonl"
    done

    install_jq_counter

    run bash -c 'cd "$1" && ./scripts/snapshot-stats.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Stats snapshot: 0 new, 3 already-today, 0 failed"* ]]
    [[ ! -s "$CURL_LOG" ]]

    jq_calls=$(cat "$JQ_COUNT_FILE")
    [ "$jq_calls" -le 4 ]
}

@test "snapshot-stats ignores malformed existing today row when checking idempotency" {
    today="$(date -u +%Y-%m-%d)"
    mkdir -p "$TEST_REPO/stats"
    printf '{"date":"%s","container":"alpha","pull_count":\n' "$today" \
        > "$TEST_REPO/stats/dockerhub-pull-history.jsonl"

    run bash -c 'cd "$1" && ./scripts/snapshot-stats.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]

    stats_file="$TEST_REPO/stats/dockerhub-pull-history.jsonl"
    jq -s -R -e --arg today "$today" '
        split("\n")
        | map(select(length > 0) | try fromjson catch empty)
        | [.[] | select(.date == $today and .container == "alpha" and .pull_count == 600)]
        | length == 1
    ' "$stats_file" >/dev/null

    grep -qx "alpha" "$CURL_LOG"
}
