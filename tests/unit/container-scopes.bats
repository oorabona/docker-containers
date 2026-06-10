#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
    TEST_DIR=$(mktemp -d)
    ORIG_DIR="$PWD"
    cd "$TEST_DIR" || exit 1

    source "$ORIG_DIR/helpers/variant-utils.sh"
    source "$ORIG_DIR/helpers/container-scopes.sh"

    create_postgres_variants "postgres"
    create_debian_variants "debian"
}

teardown() {
    cd "$ORIG_DIR" || true
    rm -rf "$TEST_DIR"
}

create_postgres_variants() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/variants.yaml" <<'YAML'
build:
  base_suffix: "-alpine"
  requires_extensions: true

versions:
  - tag: "18"
    variants:
      - name: base
        suffix: ""
        flavor: base
        default: true
      - name: full
        suffix: "-full"
        flavor: full
  - tag: "17"
    variants:
      - name: base
        suffix: ""
        flavor: base
        default: true
      - name: full
        suffix: "-full"
        flavor: full
YAML
}

create_debian_variants() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/variants.yaml" <<'YAML'
build:
  base_suffix: ""

versions:
  - tag: "12"
    variants:
      - name: bookworm
        suffix: ""
        flavor: base
        default: true
      - name: slim
        suffix: "-slim"
        flavor: slim
YAML
}

normalize_json() {
    jq -S -c . <<< "$1"
}

@test "empty object container_scopes normalizes to empty string" {
    run --separate-stderr normalize_container_scopes '{}'

    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "container_scopes map applies per-container versions and leaves unscoped containers unfiltered" {
    scopes=$(normalize_container_scopes '{"postgres":{"versions":"17"},"debian":{}}')

    run --separate-stderr expand_variants_for_containers \
        '["postgres","debian"]' \
        '{"postgres":"18","debian":"12"}' \
        '{"postgres":false,"debian":false}' \
        "$scopes" \
        "" \
        "" \
        ""

    [ "$status" -eq 0 ]
    [ "$(jq -r '[.[] | select(.container == "postgres") | .version] | unique | join(",")' <<< "$output")" = "17" ]
    [ "$(jq '[.[] | select(.container == "debian")] | length' <<< "$output")" -eq 2 ]
    [ "$(jq -r '[.[] | select(.container == "debian") | .variant] | sort | join(",")' <<< "$output")" = "bookworm,slim" ]
}

@test "container_scopes map applies per-container flavor filter" {
    scopes=$(normalize_container_scopes '{"postgres":{"flavors":"full"}}')

    run --separate-stderr expand_variants_for_containers \
        '["postgres"]' \
        '{"postgres":"18"}' \
        '{"postgres":false}' \
        "$scopes" \
        "" \
        "" \
        ""

    [ "$status" -eq 0 ]
    [ "$(jq 'length' <<< "$output")" -eq 1 ]
    [ "$(jq -r '.[0].container' <<< "$output")" = "postgres" ]
    [ "$(jq -r '.[0].flavor' <<< "$output")" = "full" ]
}

@test "container_scopes rejects invalid container keys" {
    scopes=$(normalize_container_scopes '{"nonexistent":{}}')

    run --separate-stderr validate_container_scope_keys "$scopes" $'postgres\ndebian'

    [ "$status" -ne 0 ]
    [[ "$stderr" == *"nonexistent"* ]]
}

@test "container_scopes rejects regex-like container keys" {
    run --separate-stderr validate_container_scope_keys '{"post.*":{}}' $'postgres\ndebian'

    [ "$status" -ne 0 ]
    [[ "$stderr" == *"post.*"* ]]
}

@test "container_scopes rejects keys containing newlines" {
    run --separate-stderr validate_container_scope_keys '{"postgres\ndebian":{"versions":"17"}}' $'postgres\ndebian'

    [ "$status" -ne 0 ]
    [[ "$stderr" == *"postgres"* ]]
    [[ "$stderr" == *"debian"* ]]
}

@test "container_scopes rejects keys containing control characters" {
    run --separate-stderr validate_container_scope_keys '{"postgres\u0001":{"versions":"17"}}' $'postgres\ndebian'

    [ "$status" -ne 0 ]
    [[ "$stderr" == *"postgres"* ]]
}

@test "container_scopes accepts valid multiple container keys" {
    run --separate-stderr validate_container_scope_keys '{"postgres":{"versions":"17"},"debian":{}}' $'postgres\ndebian'

    [ "$status" -eq 0 ]
}

@test "container_scopes rejects malformed JSON with workflow error annotation" {
    run --separate-stderr normalize_container_scopes '{"postgres":'

    [ "$status" -ne 0 ]
    [[ "$stderr" == *"::error::container_scopes"* ]]
}

@test "empty object container_scopes preserves legacy global scope_versions filtering" {
    scopes=$(normalize_container_scopes '{}')
    [ -z "$scopes" ]

    run --separate-stderr container_scope_keys "$scopes"
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    all_postgres=$(list_container_builds "postgres" "18" "true")
    expected=$(filter_builds_by_version_flavor_scope "$all_postgres" "17" "")

    run --separate-stderr expand_variants_for_containers \
        '["postgres"]' \
        '{"postgres":"18"}' \
        '{"postgres":false}' \
        "$scopes" \
        "17" \
        "" \
        ""

    [ "$status" -eq 0 ]
    [ "$(normalize_json "$output")" = "$(normalize_json "$expected")" ]
}

@test "empty container_scopes preserves legacy global scope_versions filtering" {
    all_postgres=$(list_container_builds "postgres" "18" "true")
    expected=$(filter_builds_by_version_flavor_scope "$all_postgres" "17" "")

    run --separate-stderr expand_variants_for_containers \
        '["postgres"]' \
        '{"postgres":"18"}' \
        '{"postgres":false}' \
        "" \
        "17" \
        "" \
        ""

    [ "$status" -eq 0 ]
    [ "$(normalize_json "$output")" = "$(normalize_json "$expected")" ]
}

@test "empty container_scopes and empty scopes preserve unfiltered legacy matrix" {
    postgres_builds=$(list_container_builds "postgres" "18" "true")
    debian_builds=$(list_container_builds "debian" "12" "false")
    expected=$(jq -c --argjson pg "$postgres_builds" --argjson deb "$debian_builds" '$pg + $deb' <<< '{}')

    run --separate-stderr expand_variants_for_containers \
        '["postgres","debian"]' \
        '{"postgres":"18","debian":"12"}' \
        '{"postgres":true,"debian":false}' \
        "" \
        "" \
        "" \
        ""

    [ "$status" -eq 0 ]
    [ "$(normalize_json "$output")" = "$(normalize_json "$expected")" ]
}
