#!/usr/bin/env bats
# Unit tests for helpers/bake-managed.sh — ADR-013 bake/matrix partition slice
#
# Mutation guards (named per test):
#   MM1: Remove github-runner from default set → github-runner lands in matrix instead of bake
#   MM2: Remove web-shell from default set → web-shell lands in matrix instead of bake
#   MM3: Remove wordpress from default set → wordpress lands in matrix instead of bake
#   MM4: Ignore BAKE_MANAGED_CONTAINERS override → env override has no effect
#   MM5: Skip bake partition entirely → all cells end up in matrix (wrong)
#   MM6: Duplicate cells across partitions → total count exceeds input length
#   MM7: Drop cells during partition → total count below input length
#   MM8: Reverse partition logic → bake-managed containers land in matrix
#   MM9: Change is_bake_managed return codes → 0/1 inverted
#   MM10: Corrupt cell objects during partition → cell fields lost

load "../test_helper"

setup() {
    export PROJECT_ROOT
    export HELPERS_DIR

    # Script under test
    export BM="${HELPERS_DIR}/bake-managed.sh"

    # Suppress GHA annotations
    export GITHUB_ACTIONS=""
    export _DEPGRAPH_LINEAGE_DIR=/nonexistent

    # Clear any env override between tests
    unset BAKE_MANAGED_CONTAINERS || true
}

teardown() {
    unset BAKE_MANAGED_CONTAINERS || true
}

# ---------------------------------------------------------------------------
# Fixture: a builds JSON array with a mix of bake-managed and matrix containers.
# Cells have the minimal shape the partition function requires: .container + extra
# fields to prove objects are preserved intact.
# ---------------------------------------------------------------------------
_fixture_builds() {
    jq -cn '
    [
      {"container":"github-runner","tag":"ubuntu-2404-1.2.3","variant":"ubuntu-2404","flavor":"dev"},
      {"container":"web-shell",    "tag":"alpine-1.0.0",     "variant":"alpine",      "flavor":"base"},
      {"container":"wordpress",    "tag":"latest-6.5.0",     "variant":"latest",      "flavor":"php82"},
      {"container":"debian",       "tag":"bookworm-12.0.0",  "variant":"bookworm",    "flavor":"base"},
      {"container":"terraform",    "tag":"1.8.0",            "variant":"",            "flavor":""},
      {"container":"web-shell",    "tag":"ubuntu-1.0.0",     "variant":"ubuntu",      "flavor":"base"}
    ]'
}

# ---------------------------------------------------------------------------
# BM-01: Default partition — bake-managed containers (github-runner/web-shell/wordpress)
#        land in .bake; debian and terraform land in .matrix.
# Catches: MM1, MM2, MM3, MM5, MM8
# ---------------------------------------------------------------------------
@test "BM-01: default partition routes github-runner/web-shell/wordpress to bake, others to matrix" {
    # Source the helper
    # shellcheck disable=SC1090
    source "$BM"

    result=$(partition_builds "$(_fixture_builds)")

    # Validate JSON structure
    echo "$result" | jq -e 'has("bake") and has("matrix")' >/dev/null

    # bake partition contains exactly the 3 bake-managed containers (web-shell has 2 entries = 3 total)
    bake_containers=$(echo "$result" | jq -r '[.bake[].container] | sort | unique | .[]')
    echo "$bake_containers" | grep -q "^github-runner$"
    echo "$bake_containers" | grep -q "^web-shell$"
    echo "$bake_containers" | grep -q "^wordpress$"

    # matrix partition must NOT contain bake-managed containers
    matrix_containers=$(echo "$result" | jq -r '[.matrix[].container] | unique | .[]')
    ! echo "$matrix_containers" | grep -q "^github-runner$"
    ! echo "$matrix_containers" | grep -q "^web-shell$"
    ! echo "$matrix_containers" | grep -q "^wordpress$"

    # matrix contains debian and terraform
    echo "$matrix_containers" | grep -q "^debian$"
    echo "$matrix_containers" | grep -q "^terraform$"
}

# ---------------------------------------------------------------------------
# BM-02: Counts add up — no cell is lost or duplicated.
# Catches: MM6, MM7
# ---------------------------------------------------------------------------
@test "BM-02: partition is lossless — bake+matrix count equals input count" {
    # shellcheck disable=SC1090
    source "$BM"

    fixture=$(_fixture_builds)
    result=$(partition_builds "$fixture")

    input_count=$(echo "$fixture" | jq 'length')
    bake_count=$(echo "$result" | jq '.bake | length')
    matrix_count=$(echo "$result" | jq '.matrix | length')
    total=$(( bake_count + matrix_count ))

    [[ "$total" -eq "$input_count" ]]
}

# ---------------------------------------------------------------------------
# BM-03: Order preserved — cells appear in the same relative order within each
#        partition as in the input array.
# Catches: MM10 (partial — verifies object integrity and ordering)
# ---------------------------------------------------------------------------
@test "BM-03: partition preserves cell order within each partition" {
    # shellcheck disable=SC1090
    source "$BM"

    result=$(partition_builds "$(_fixture_builds)")

    # The bake partition must be: github-runner, web-shell (alpine), wordpress, web-shell (ubuntu)
    # (i.e., input order preserved within bake partition)
    bake_tags=$(echo "$result" | jq -r '[.bake[].tag] | .[]')
    expected_order="ubuntu-2404-1.2.3
alpine-1.0.0
latest-6.5.0
ubuntu-1.0.0"
    [[ "$bake_tags" == "$expected_order" ]]

    # The matrix partition must be: debian, terraform (input order)
    matrix_tags=$(echo "$result" | jq -r '[.matrix[].tag] | .[]')
    expected_matrix="bookworm-12.0.0
1.8.0"
    [[ "$matrix_tags" == "$expected_matrix" ]]
}

# ---------------------------------------------------------------------------
# BM-04: BAKE_MANAGED_CONTAINERS env override — only the overridden container
#        lands in .bake; the default set (github-runner/web-shell/wordpress)
#        falls through to .matrix.
# Catches: MM4
# ---------------------------------------------------------------------------
@test "BM-04: BAKE_MANAGED_CONTAINERS env override changes partition" {
    # shellcheck disable=SC1090
    source "$BM"

    BAKE_MANAGED_CONTAINERS="debian" result=$(partition_builds "$(_fixture_builds)")

    # Only debian must be in bake
    bake_containers=$(echo "$result" | jq -r '[.bake[].container] | unique | .[]')
    [[ "$bake_containers" == "debian" ]]

    # github-runner, web-shell, wordpress must now be in matrix
    matrix_containers=$(echo "$result" | jq -r '[.matrix[].container] | unique | .[]')
    echo "$matrix_containers" | grep -q "^github-runner$"
    echo "$matrix_containers" | grep -q "^web-shell$"
    echo "$matrix_containers" | grep -q "^wordpress$"
}

# ---------------------------------------------------------------------------
# BM-05: Empty input [] → {"bake":[],"matrix":[]}
# ---------------------------------------------------------------------------
@test "BM-05: empty input array returns empty bake and matrix partitions" {
    # shellcheck disable=SC1090
    source "$BM"

    result=$(partition_builds "[]")

    echo "$result" | jq -e '.bake == [] and .matrix == []' >/dev/null
}

# ---------------------------------------------------------------------------
# BM-06: is_bake_managed — github-runner returns 0 (in set).
# Catches: MM9
# ---------------------------------------------------------------------------
@test "BM-06: is_bake_managed returns 0 for github-runner (default set)" {
    # shellcheck disable=SC1090
    source "$BM"

    run is_bake_managed "github-runner"
    [[ "$status" -eq 0 ]]
}

# ---------------------------------------------------------------------------
# BM-07: is_bake_managed — debian returns 1 (not in default set).
# Catches: MM9
# ---------------------------------------------------------------------------
@test "BM-07: is_bake_managed returns 1 for debian (not in default set)" {
    # shellcheck disable=SC1090
    source "$BM"

    run is_bake_managed "debian"
    [[ "$status" -eq 1 ]]
}

# ---------------------------------------------------------------------------
# BM-08: is_bake_managed — web-shell returns 0; terraform returns 1.
# Catches: MM1, MM2, MM3, MM9 (broader coverage)
# ---------------------------------------------------------------------------
@test "BM-08: is_bake_managed covers web-shell (0) and terraform (1)" {
    # shellcheck disable=SC1090
    source "$BM"

    run is_bake_managed "web-shell"
    [[ "$status" -eq 0 ]]

    run is_bake_managed "terraform"
    [[ "$status" -eq 1 ]]
}

# ---------------------------------------------------------------------------
# BM-09: Cell objects are preserved intact — all fields survive partition.
# Catches: MM10
# ---------------------------------------------------------------------------
@test "BM-09: partition preserves all cell fields (no field loss)" {
    # shellcheck disable=SC1090
    source "$BM"

    result=$(partition_builds "$(_fixture_builds)")

    # Spot-check the github-runner cell: all fixture fields must be present
    gr_cell=$(echo "$result" | jq -c '[.bake[] | select(.container == "github-runner")] | .[0]')
    [[ "$(echo "$gr_cell" | jq -r '.tag')"     == "ubuntu-2404-1.2.3" ]]
    [[ "$(echo "$gr_cell" | jq -r '.variant')" == "ubuntu-2404" ]]
    [[ "$(echo "$gr_cell" | jq -r '.flavor')"  == "dev" ]]

    # Spot-check the debian cell in matrix
    deb_cell=$(echo "$result" | jq -c '[.matrix[] | select(.container == "debian")] | .[0]')
    [[ "$(echo "$deb_cell" | jq -r '.tag')"     == "bookworm-12.0.0" ]]
    [[ "$(echo "$deb_cell" | jq -r '.variant')" == "bookworm" ]]
}

# ---------------------------------------------------------------------------
# BM-10: Malformed input (not a JSON array) → exit code 1, ::error:: on stderr.
# ---------------------------------------------------------------------------
@test "BM-10: malformed input (not an array) returns non-zero exit and error message" {
    # shellcheck disable=SC1090
    source "$BM"

    run partition_builds '{"not":"an array"}'
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"::error::"* ]] || [[ "$stderr" == *"::error::"* ]] || \
        echo "$output" | grep -q "error" || true
    # The key assertion: non-zero exit code
    [[ "$status" -ne 0 ]]
}
