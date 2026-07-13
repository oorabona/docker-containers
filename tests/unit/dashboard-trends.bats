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

# Asserts pull_trend_svg_dots contains exactly $n "<circle .../>" elements
# and that each circle's cx/cy attributes match the corresponding "x,y" pair
# (same order) in the pull_trend_svg_points string — i.e. the hover-tooltip
# dots line up with the polyline they annotate (#884).
assert_svg_dots_match_points() {
    local dots="$1" points="$2" n="$3"
    local circle_count
    circle_count=$(grep -o '<circle ' <<< "$dots" | wc -l)
    [ "$circle_count" -eq "$n" ]

    local -a circle_tags point_pairs
    mapfile -t circle_tags < <(grep -oE '<circle[^>]*>' <<< "$dots")
    read -r -a point_pairs <<< "$points"
    [ "${#circle_tags[@]}" -eq "${#point_pairs[@]}" ] || return 1

    local idx pair x y cx cy tag
    for idx in "${!point_pairs[@]}"; do
        pair="${point_pairs[$idx]}"
        x="${pair%,*}"
        y="${pair#*,}"
        tag="${circle_tags[$idx]}"
        [[ "$tag" =~ cx=\"([0-9]+)\" ]] || return 1
        cx="${BASH_REMATCH[1]}"
        [[ "$tag" =~ cy=\"([0-9]+)\" ]] || return 1
        cy="${BASH_REMATCH[1]}"
        [ "$cx" = "$x" ] || return 1
        [ "$cy" = "$y" ] || return 1
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

@test "pull_trend_svg_dots has one <circle> per data point, cx/cy matching pull_trend_svg_points, and correct per-point <title> text (#884 hover tooltips)" {
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

    local container_json points dots
    container_json=$(cat "$TEST_DIR/captured-widget.json")
    echo "$container_json" | jq -e 'has("pull_trend_svg_dots")' >/dev/null

    points=$(echo "$container_json" | jq -r '.pull_trend_svg_points')
    dots=$(echo "$container_json" | jq -r '.pull_trend_svg_dots')
    assert_svg_dots_match_points "$dots" "$points" 5

    # Spot check the <title> text on the first and fourth points.
    grep -q '<title>2026-04-01: 100 pulls</title>' <<< "$dots"
    grep -q '<title>2026-04-04: 480 pulls</title>' <<< "$dots"
}

@test "pull_trend_svg_dots HTML-escapes date values in <title>, never passes them through raw" {
    make_fixture_container leaky
    cat > "$TEST_DIR/stats/dockerhub-pull-history.jsonl" <<'EOF'
{"date":"2026-07-01<script>alert(1)</script>","container":"leaky","pull_count":10}
{"date":"2026-07-02","container":"leaky","pull_count":20}
EOF
    reset_trend_cache
    capture_container_page

    generate_data >/dev/null

    local container_json dots
    container_json=$(cat "$TEST_DIR/captured-leaky.json")
    dots=$(echo "$container_json" | jq -r '.pull_trend_svg_dots')

    # load_dockerhub_pull_trends only type-checks .date as a string (no
    # content validation), so a hostile/malformed date value CAN reach this
    # jq filter — @html must escape it, never interpolate it raw.
    grep -q '&lt;script&gt;alert(1)&lt;/script&gt;' <<< "$dots"
    run grep -q '<script>' <<< "$dots"
    [ "$status" -ne 0 ]
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
    echo "$container_json" | jq -e 'has("pull_trend_svg_dots") | not' >/dev/null
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
    echo "$container_json" | jq -e 'has("pull_trend_svg_dots") | not' >/dev/null
}

@test "a non-finite pull_count (1e999) is excluded from SVG coordinates but preserved in the raw pull_trend (regression lock)" {
    make_fixture_container glitchy
    cat > "$TEST_DIR/stats/dockerhub-pull-history.jsonl" <<'EOF'
{"date":"2026-08-01","container":"glitchy","pull_count":100}
{"date":"2026-08-02","container":"glitchy","pull_count":1e999}
{"date":"2026-08-03","container":"glitchy","pull_count":210}
{"date":"2026-08-04","container":"glitchy","pull_count":480}
{"date":"2026-08-05","container":"glitchy","pull_count":75}
EOF
    reset_trend_cache
    capture_container_page

    generate_data >/dev/null

    local container_json points dots
    container_json=$(cat "$TEST_DIR/captured-glitchy.json")

    # The raw field is untouched: all 5 rows survive, including the
    # non-finite one, so the page still carries the data for transparency.
    echo "$container_json" | jq -e '(.pull_trend | length) == 5' >/dev/null

    # But the derived SVG fields only see the 4 finite rows.
    echo "$container_json" | jq -e '.pull_trend_days == 4' >/dev/null
    echo "$container_json" | jq -e '.pull_trend_first == 100 and .pull_trend_last == 75' >/dev/null

    points=$(echo "$container_json" | jq -r '.pull_trend_svg_points')
    dots=$(echo "$container_json" | jq -r '.pull_trend_svg_dots')

    # This is the exact bug this test locks: jq serializes Infinity/NaN to
    # JSON `null`, so an unfiltered non-finite row produced invalid SVG
    # ("60,null" / cy="null"). Assert no literal null anywhere, and that the
    # bounds check passes for the REMAINING finite count (4), not the
    # original row count (5).
    run grep -q 'null' <<< "$points"
    [ "$status" -ne 0 ]
    run grep -q 'null' <<< "$dots"
    [ "$status" -ne 0 ]
    assert_svg_points_in_bounds "$points" 4
    assert_svg_dots_match_points "$dots" "$points" 4
}

@test "all pull_counts non-finite produces no sparkline fields, matching the existing graceful zero/one-point fallback" {
    make_fixture_container voidy
    cat > "$TEST_DIR/stats/dockerhub-pull-history.jsonl" <<'EOF'
{"date":"2026-09-01","container":"voidy","pull_count":1e999}
{"date":"2026-09-02","container":"voidy","pull_count":-1e999}
EOF
    reset_trend_cache
    capture_container_page

    generate_data >/dev/null

    local container_json
    container_json=$(cat "$TEST_DIR/captured-voidy.json")

    # Raw data still carries both non-finite rows.
    echo "$container_json" | jq -e '(.pull_trend | length) == 2' >/dev/null

    # Filtering drops both rows to 0 finite points, so no derived fields —
    # same graceful fallback as the existing 0/1-point cases.
    echo "$container_json" | jq -e 'has("pull_trend_svg_points") | not' >/dev/null
    echo "$container_json" | jq -e 'has("pull_trend_svg_dots") | not' >/dev/null
    echo "$container_json" | jq -e 'has("pull_trend_first") | not' >/dev/null
    echo "$container_json" | jq -e 'has("pull_trend_last") | not' >/dev/null
    echo "$container_json" | jq -e 'has("pull_trend_days") | not' >/dev/null
}

@test "one finite point remaining after filtering a non-finite row produces no sparkline fields (single-point fallback)" {
    make_fixture_container solo
    cat > "$TEST_DIR/stats/dockerhub-pull-history.jsonl" <<'EOF'
{"date":"2026-10-01","container":"solo","pull_count":50}
{"date":"2026-10-02","container":"solo","pull_count":1e999}
EOF
    reset_trend_cache
    capture_container_page

    generate_data >/dev/null

    local container_json
    container_json=$(cat "$TEST_DIR/captured-solo.json")

    echo "$container_json" | jq -e '(.pull_trend | length) == 2' >/dev/null
    echo "$container_json" | jq -e 'has("pull_trend_svg_points") | not' >/dev/null
    echo "$container_json" | jq -e 'has("pull_trend_svg_dots") | not' >/dev/null
}

@test "a string 'nan' pull_count round-trips to JSON null and is excluded by the type check (regression lock for refusal 3a)" {
    make_fixture_container nanny
    cat > "$TEST_DIR/stats/dockerhub-pull-history.jsonl" <<'EOF'
{"date":"2026-11-01","container":"nanny","pull_count":100}
{"date":"2026-11-02","container":"nanny","pull_count":"nan"}
{"date":"2026-11-03","container":"nanny","pull_count":210}
{"date":"2026-11-04","container":"nanny","pull_count":480}
{"date":"2026-11-05","container":"nanny","pull_count":75}
EOF
    reset_trend_cache
    capture_container_page

    generate_data >/dev/null

    local container_json points dots
    container_json=$(cat "$TEST_DIR/captured-nanny.json")

    # load_dockerhub_pull_trends' `.pull_count | tonumber?` actually PARSES
    # the string "nan" into a real IEEE754 NaN double (type "number",
    # isnan == true) rather than erroring — jq only serializes it to JSON
    # `null` when the cache round-trips through a bash variable. So the raw
    # field carries all 5 rows, with the nan one now literally `null`.
    echo "$container_json" | jq -e '(.pull_trend | length) == 5' >/dev/null
    echo "$container_json" | jq -e '.pull_trend[1].pull_count == null' >/dev/null

    # The `(.pull_count | type) == "number"` guard excludes that null entry
    # up front (type "null" != "number") — this is what actually protects
    # this case, not the output-bounds gate (a null pull_count never reaches
    # the y-coordinate arithmetic at all).
    echo "$container_json" | jq -e '.pull_trend_days == 4' >/dev/null
    echo "$container_json" | jq -e '.pull_trend_first == 100 and .pull_trend_last == 75' >/dev/null

    points=$(echo "$container_json" | jq -r '.pull_trend_svg_points')
    dots=$(echo "$container_json" | jq -r '.pull_trend_svg_dots')

    run grep -q 'null' <<< "$points"
    [ "$status" -ne 0 ]
    run grep -q 'null' <<< "$dots"
    [ "$status" -ne 0 ]
    assert_svg_points_in_bounds "$points" 4
    assert_svg_dots_match_points "$dots" "$points" 4
}

@test "a finite-but-extreme pull_count (1e308) overflows the y-coordinate arithmetic into an out-of-bounds value, caught by the output validation gate (regression lock for refusal 3b)" {
    make_fixture_container overflowy
    cat > "$TEST_DIR/stats/dockerhub-pull-history.jsonl" <<'EOF'
{"date":"2026-12-01","container":"overflowy","pull_count":100}
{"date":"2026-12-02","container":"overflowy","pull_count":210}
{"date":"2026-12-03","container":"overflowy","pull_count":480}
{"date":"2026-12-04","container":"overflowy","pull_count":75}
{"date":"2026-12-05","container":"overflowy","pull_count":300}
{"date":"2026-12-06","container":"overflowy","pull_count":1e308}
EOF
    reset_trend_cache
    capture_container_page

    generate_data >/dev/null

    local container_json
    container_json=$(cat "$TEST_DIR/captured-overflowy.json")

    # 1e308 is individually finite (not inf/nan) and a real number — it
    # passes BOTH the type check and the isinfinite/isnan input filter. But
    # $trange = 1e308 - 75 is still ~1e308, and (pull_count - $tmin) * 24
    # overflows a float64 to +/-Infinity for the OTHER points while for this
    # extreme point itself, 26 - floor(...) lands on a huge but technically
    # FINITE negative number (~-1.7976931348623157e308, i.e. -DBL_MAX) —
    # neither isinfinite nor isnan, yet wildly outside the [0,28] viewBox.
    # Only the output-bounds gate (.y >= 0 and .y <= 28) catches this; an
    # isinfinite/isnan-only check on the input would have let it through.
    # All 6 raw rows still round-trip untouched.
    echo "$container_json" | jq -e '(.pull_trend | length) == 6' >/dev/null

    # The whole sparkline is dropped (not partially emitted) because one
    # point out of six fails the output-bounds check.
    echo "$container_json" | jq -e 'has("pull_trend_svg_points") | not' >/dev/null
    echo "$container_json" | jq -e 'has("pull_trend_svg_dots") | not' >/dev/null
    echo "$container_json" | jq -e 'has("pull_trend_first") | not' >/dev/null
    echo "$container_json" | jq -e 'has("pull_trend_last") | not' >/dev/null
    echo "$container_json" | jq -e 'has("pull_trend_days") | not' >/dev/null
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
    run grep -qE '\{%-?\s*for ' <<< "$pulls_block"
    [ "$status" -ne 0 ]
    run grep -q 'forloop' <<< "$pulls_block"
    [ "$status" -ne 0 ]

    grep -q '<title id="pull-trend-title-' <<< "$pulls_block"
    grep -q 'polyline points="{{ page.pull_trend_svg_points }}"' <<< "$pulls_block"
    grep -q 'recorded days' <<< "$pulls_block"

    # #884 hover tooltips: the pre-computed <circle>/<title> markup must be
    # gated behind its own presence check and interpolated as a single
    # pre-computed string, same discipline as pull_trend_svg_points above —
    # never rebuilt as a Liquid loop.
    grep -q 'if page.pull_trend_svg_dots' <<< "$pulls_block"
    grep -q '{{ page.pull_trend_svg_dots }}' <<< "$pulls_block"
}
