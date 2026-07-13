#!/usr/bin/env bats

setup() {
    TEST_DIR=$(mktemp -d)
    ORIG_DIR="$PWD"
    cd "$TEST_DIR" || exit 1

    local _saved_exit_trap
    _saved_exit_trap=$(trap -p EXIT 2>/dev/null) || true
    source "$ORIG_DIR/helpers/logging.sh" 2>/dev/null || true
    source "$ORIG_DIR/helpers/variant-utils.sh" 2>/dev/null || true
    source "$ORIG_DIR/generate-dashboard.sh" 2>/dev/null || true
    _SOURCED_TRIVY_CACHE="${TRIVY_CACHE_FILE:-}"
    if [[ -n "$_saved_exit_trap" ]]; then
        eval "$_saved_exit_trap" 2>/dev/null || true
    else
        trap - EXIT 2>/dev/null || true
    fi

    export SCRIPT_DIR="$TEST_DIR"
    DOCKERHUB_PULL_TRENDS_CACHE=""

    mkdir -p "$TEST_DIR/stats" "$TEST_DIR/docs/site/_data" "$TEST_DIR/docs/site/_containers"
    DATA_FILE="$TEST_DIR/docs/site/_data/containers.yml"
    CONTAINERS_DIR="$TEST_DIR/docs/site/_containers"
    STATS_FILE="$TEST_DIR/docs/site/_data/stats.yml"
    TRIVY_CACHE_FILE=$(mktemp)
    export DATA_FILE CONTAINERS_DIR STATS_FILE TRIVY_CACHE_FILE

    get_container_versions()             { echo "1.0.0|1.0.0|green|Up to date"; }
    get_container_description()          { echo "Alpha test container"; }
    get_container_build_status()         { echo "success"; }
    populate_container_build_status_cache() { :; }
    get_dockerhub_stats()                { echo "pulls:120 stars:3"; }
    get_ghcr_sizes()                     { echo ""; }
    ghcr_get_manifest_sizes()            { echo ""; }
    get_build_lineage_field()            { echo "unknown"; }
    get_build_lineage_args_json()        { echo "[]"; }
    has_variants()                       { return 1; }
    get_sbom_summary()                   { echo "{}"; }
    get_sbom_packages()                  { echo "{}"; }
    get_changelog()                      { echo "{}"; }
    get_build_history()                  { echo "[]"; }
    resolve_variant_lineage_file()       { echo ""; }
    build_trivy_category()               { echo "alpha:1.0.0"; }
    get_attestation_id()                 { return 1; }
    get_attestation_url()                { echo ""; }
    get_trivy_summary()                  { echo "{}"; }
    generate_container_page()            { :; }
    fetch_recent_activity()              { echo "recent_activity: []"; }
    calculate_build_success_rate()       { echo "1:1:100"; }
}

teardown() {
    cd "$ORIG_DIR" || true
    rm -f "${TRIVY_CACHE_FILE:-}" 2>/dev/null || true
    rm -f "${_SOURCED_TRIVY_CACHE:-}" 2>/dev/null || true
    rm -rf "$TEST_DIR"
}

reset_trend_cache() {
    DOCKERHUB_PULL_TRENDS_CACHE=""
}

# Asserts a "x1,y1 x2,y2 ..." points string has exactly $n pairs, real single
# spaces between every pair (the regression lock for #876 — Liquid silently
# ate this separator), and every coordinate inside the 120x28 SVG viewBox.
assert_svg_points_in_bounds() {
    local points="$1" n="$2"
    local space_count field_count
    space_count=$(grep -o ' ' <<< "$points" | wc -l)
    [ "$space_count" -eq "$((n - 1))" ]

    field_count=$(wc -w <<< "$points")
    [ "$field_count" -eq "$n" ]

    local pair x y
    for pair in $points; do
        [[ "$pair" =~ ^([0-9]+),([0-9]+)$ ]] || return 1
        x="${BASH_REMATCH[1]}"
        y="${BASH_REMATCH[2]}"
        [ "$x" -ge 0 ] && [ "$x" -le 120 ] || return 1
        [ "$y" -ge 0 ] && [ "$y" -le 28 ] || return 1
    done
}

# Captures the exact container_json generate_data() builds (after the
# pull_trend/jq step) instead of letting generate_container_page write it
# to disk and discard the in-memory value.
capture_container_page() {
    generate_container_page() {
        local container="$1" container_json="$2"
        echo "$container_json" > "$TEST_DIR/captured-${container}.json"
    }
}

# Creates a minimal container directory that satisfies generate_data()'s
# discovery loop (is_skip_directory / has_dockerfile / version.sh presence).
make_fixture_container() {
    local name="$1"
    mkdir -p "$TEST_DIR/$name"
    printf '#!/usr/bin/env bash\necho "1.0.0"\n' > "$TEST_DIR/$name/version.sh"
    chmod +x "$TEST_DIR/$name/version.sh"
    printf 'FROM alpine:3.21\n' > "$TEST_DIR/$name/Dockerfile"
}

@test "Docker Hub pull trend skips malformed rows, sorts by date, and dedupes with last row winning" {
    cat > "$TEST_DIR/stats/dockerhub-pull-history.jsonl" <<'EOF'
not json
{"date":"2026-01-03","container":"alpha","pull_count":30}
{"date":"2026-01-01","container":"alpha","pull_count":10}
{"date":"2026-01-02","container":"alpha","pull_count":20}
{"date":"2026-01-02","container":"alpha","pull_count":25}
{"date":"2026-01-04","container":"alpha"}
{"date":"2026-01-05","container":"alpha","pull_count":"35"}
{"date":"2026-01-01","container":"beta","pull_count":5}
EOF
    reset_trend_cache

    run get_dockerhub_pull_trend "alpha"
    [ "$status" -eq 0 ]

    echo "$output" | jq -e '
        length == 4 and
        .[0] == {"date":"2026-01-01","pull_count":10} and
        .[1] == {"date":"2026-01-02","pull_count":25} and
        .[2] == {"date":"2026-01-03","pull_count":30} and
        .[3] == {"date":"2026-01-05","pull_count":35}
    ' >/dev/null
}

@test "Docker Hub pull trend returns only the last 30 daily points" {
    : > "$TEST_DIR/stats/dockerhub-pull-history.jsonl"
    for day in $(seq -w 1 31); do
        jq -nc \
            --arg date "2026-01-${day}" \
            --argjson pull_count "$((10#$day))" \
            '{date: $date, container: "alpha", pull_count: $pull_count}' \
            >> "$TEST_DIR/stats/dockerhub-pull-history.jsonl"
    done
    reset_trend_cache

    run get_dockerhub_pull_trend "alpha"
    [ "$status" -eq 0 ]

    echo "$output" | jq -e '
        length == 30 and
        .[0].date == "2026-01-02" and
        .[29].date == "2026-01-31"
    ' >/dev/null
}

@test "Docker Hub pull trend loads history once across multiple lookups" {
    cat > "$TEST_DIR/stats/dockerhub-pull-history.jsonl" <<'EOF'
{"date":"2026-02-01","container":"alpha","pull_count":10}
{"date":"2026-02-01","container":"beta","pull_count":20}
EOF
    reset_trend_cache

    eval "$(declare -f load_dockerhub_pull_trends | sed '1s/load_dockerhub_pull_trends/load_dockerhub_pull_trends_uncounted/')"
    load_trends_count_file="$TEST_DIR/load-trends-count"
    echo 0 > "$load_trends_count_file"
    load_dockerhub_pull_trends() {
        local calls
        calls=$(cat "$load_trends_count_file")
        echo $((calls + 1)) > "$load_trends_count_file"
        load_dockerhub_pull_trends_uncounted "$@"
    }

    get_dockerhub_pull_trend "alpha" > "$TEST_DIR/alpha-trend.json"
    get_dockerhub_pull_trend "beta" > "$TEST_DIR/beta-trend.json"
    get_dockerhub_pull_trend "alpha" > "$TEST_DIR/alpha-trend-again.json"
    alpha_trend=$(cat "$TEST_DIR/alpha-trend.json")
    beta_trend=$(cat "$TEST_DIR/beta-trend.json")
    alpha_again=$(cat "$TEST_DIR/alpha-trend-again.json")

    [ "$(cat "$load_trends_count_file")" -eq 1 ]
    echo "$alpha_trend" | jq -e 'map(.pull_count) == [10]' >/dev/null
    echo "$beta_trend" | jq -e 'map(.pull_count) == [20]' >/dev/null
    [ "$alpha_again" = "$alpha_trend" ]
}

@test "Docker Hub pull trend preserves flat and downward values for the renderer" {
    cat > "$TEST_DIR/stats/dockerhub-pull-history.jsonl" <<'EOF'
{"date":"2026-02-01","container":"flat","pull_count":50}
{"date":"2026-02-02","container":"flat","pull_count":50}
{"date":"2026-02-01","container":"drop","pull_count":100}
{"date":"2026-02-02","container":"drop","pull_count":90}
EOF
    reset_trend_cache

    run get_dockerhub_pull_trend "flat"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e 'map(.pull_count) == [50, 50]' >/dev/null

    run get_dockerhub_pull_trend "drop"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e 'map(.pull_count) == [100, 90]' >/dev/null
}

@test "Docker Hub pull trend returns an empty array when history is absent or container is unseen" {
    rm -f "$TEST_DIR/stats/dockerhub-pull-history.jsonl"
    reset_trend_cache

    run get_dockerhub_pull_trend "missing"
    [ "$status" -eq 0 ]
    [ "$output" = "[]" ]
}

@test "generate_data folds pull_trend into each container JSON object" {
    mkdir -p "$TEST_DIR/alpha"
    printf '#!/usr/bin/env bash\necho "1.0.0"\n' > "$TEST_DIR/alpha/version.sh"
    chmod +x "$TEST_DIR/alpha/version.sh"
    printf 'FROM alpine:3.21\n' > "$TEST_DIR/alpha/Dockerfile"

    cat > "$TEST_DIR/stats/dockerhub-pull-history.jsonl" <<'EOF'
{"date":"2026-03-01","container":"alpha","pull_count":110}
{"date":"2026-03-02","container":"alpha","pull_count":120}
EOF
    reset_trend_cache

    generate_data >/dev/null

    yq -o=json '.' "$DATA_FILE" | jq -e '
        .[0].name == "alpha" and
        .[0].pull_trend == [
          {"date":"2026-03-01","pull_count":110},
          {"date":"2026-03-02","pull_count":120}
        ]
    ' >/dev/null
}

@test "pull_trend_svg_points has a real space between every point pair, in-bounds coordinates (regression lock for #876)" {
    make_fixture_container widget
    cat > "$TEST_DIR/stats/dockerhub-pull-history.jsonl" <<'EOF'
{"date":"2026-04-01","container":"widget","pull_count":100}
{"date":"2026-04-02","container":"widget","pull_count":340}
{"date":"2026-04-03","container":"widget","pull_count":210}
{"date":"2026-04-04","container":"widget","pull_count":480}
{"date":"2026-04-05","container":"widget","pull_count":75}
EOF
    reset_trend_cache
    capture_container_page

    generate_data >/dev/null

    local container_json points
    container_json=$(cat "$TEST_DIR/captured-widget.json")

    echo "$container_json" | jq -e 'has("pull_trend_svg_points")' >/dev/null
    echo "$container_json" | jq -e '.pull_trend_days == 5' >/dev/null
    echo "$container_json" | jq -e '.pull_trend_first == 100 and .pull_trend_last == 75' >/dev/null

    points=$(echo "$container_json" | jq -r '.pull_trend_svg_points')
    # This is the exact bug: a missing separator collapses "2,26 33,10" into
    # "2,2633,10" — a garbled, unparseable SVG polyline. Assert the general
    # invariant (every coordinate is a well-formed, in-bounds pair) rather
    # than just eyeballing the string, so the whole bug CLASS is covered.
    assert_svg_points_in_bounds "$points" 5
}

@test "flat pull trend (all pull_counts identical) produces y=14 for every point" {
    make_fixture_container steady
    cat > "$TEST_DIR/stats/dockerhub-pull-history.jsonl" <<'EOF'
{"date":"2026-05-01","container":"steady","pull_count":500}
{"date":"2026-05-02","container":"steady","pull_count":500}
{"date":"2026-05-03","container":"steady","pull_count":500}
{"date":"2026-05-04","container":"steady","pull_count":500}
EOF
    reset_trend_cache
    capture_container_page

    generate_data >/dev/null

    local container_json points y
    container_json=$(cat "$TEST_DIR/captured-steady.json")
    points=$(echo "$container_json" | jq -r '.pull_trend_svg_points')
    assert_svg_points_in_bounds "$points" 4

    for pair in $points; do
        y="${pair#*,}"
        [ "$y" -eq 14 ]
    done
}

@test "a single data point produces no pull_trend_svg_points field (sparkline must not render)" {
    make_fixture_container newcomer
    cat > "$TEST_DIR/stats/dockerhub-pull-history.jsonl" <<'EOF'
{"date":"2026-06-01","container":"newcomer","pull_count":42}
EOF
    reset_trend_cache
    capture_container_page

    generate_data >/dev/null

    local container_json
    container_json=$(cat "$TEST_DIR/captured-newcomer.json")
    echo "$container_json" | jq -e '.pull_trend == [{"date":"2026-06-01","pull_count":42}]' >/dev/null
    echo "$container_json" | jq -e 'has("pull_trend_svg_points") | not' >/dev/null
}

@test "zero data points (no history) produces no pull_trend_svg_points field" {
    make_fixture_container ghostly
    rm -f "$TEST_DIR/stats/dockerhub-pull-history.jsonl"
    reset_trend_cache
    capture_container_page

    generate_data >/dev/null

    local container_json
    container_json=$(cat "$TEST_DIR/captured-ghostly.json")
    echo "$container_json" | jq -e '.pull_trend == []' >/dev/null
    echo "$container_json" | jq -e 'has("pull_trend_svg_points") | not' >/dev/null
}

@test "container detail template renders the sparkline from a pre-computed jq string, never a Liquid loop (regression lock for #876)" {
    layout="$ORIG_DIR/docs/site/_layouts/container-detail.html"
    gate_line=$(grep -n 'if page.pull_trend_svg_points' "$layout" | head -1 | cut -d: -f1)
    svg_line=$(grep -n '<svg class="pull-trend-sparkline"' "$layout" | head -1 | cut -d: -f1)
    [ -n "$gate_line" ]
    [ "$gate_line" -lt "$svg_line" ]

    pulls_block=$(sed -n '/<span class="eyebrow">PULLS<\/span>/,/^\s*<\/div>\s*$/p' "$layout")

    # #876 root cause: SVG point coordinates were computed inside a Liquid
    # {% for %} loop, using {% unless forloop.last %} to emit a separator
    # space between points. Liquid's remove_blank_strings optimization
    # silently deletes whitespace-only String bodies inside control-flow
    # blocks, so that separator vanished in production and all coordinates
    # ran together into garbage numbers. The fix moved ALL coordinate math
    # into jq (join(" ") is reliable); Liquid now only interpolates one
    # pre-computed string. Guard against regressing back to loop-based math.
    ! grep -qE '\{%-?\s*for ' <<< "$pulls_block"
    ! grep -q 'forloop' <<< "$pulls_block"

    grep -q '<title id="pull-trend-title-' <<< "$pulls_block"
    grep -q 'polyline points="{{ page.pull_trend_svg_points }}"' <<< "$pulls_block"
    grep -q 'recorded days' <<< "$pulls_block"
}
