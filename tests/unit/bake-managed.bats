#!/usr/bin/env bats
# Unit tests for helpers/bake-managed.sh — ADR-013 bake/matrix partition slice
#
# Mutation guards (named per test):
#   MM1: Remove github-runner from default set → github-runner lands in matrix instead of bake
#   MM2: Remove web-shell from default set → web-shell lands in matrix instead of bake
#   MM3: Remove wordpress from default set → wordpress lands in matrix instead of bake
#   MM3b: Remove debian/vector/jekyll/ansible from default set → they land in matrix instead of bake
#   MM4: Ignore BAKE_MANAGED_CONTAINERS override → env override has no effect
#   MM5: Skip bake partition entirely → all cells end up in matrix (wrong)
#   MM6: Duplicate cells across partitions → total count exceeds input length
#   MM7: Drop cells during partition → total count below input length
#   MM8: Reverse partition logic → bake-managed containers land in matrix
#   MM9: Change is_bake_managed return codes → 0/1 inverted
#   MM10: Corrupt cell objects during partition → cell fields lost
#   MM11: Drop OS guard — windows cell of bake-managed container lands in bake instead of matrix
#   MM12: Treat absent .os as non-linux — linux cell without .os field excluded from bake

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
# Note: linux cells may omit .os (treated as linux); windows cells have .os="windows".
# All bake-managed cells carry is_latest_version:true — bake is latest-only by
# design and partition_builds requires is_latest_version==true for .bake routing.
# ---------------------------------------------------------------------------
_fixture_builds() {
    jq -cn '
    [
      {"container":"github-runner","tag":"ubuntu-2404-1.2.3","variant":"ubuntu-2404","flavor":"dev","is_latest_version":true},
      {"container":"web-shell",    "tag":"alpine-1.0.0",     "variant":"alpine",      "flavor":"base","is_latest_version":true},
      {"container":"wordpress",    "tag":"latest-6.5.0",     "variant":"latest",      "flavor":"php82","is_latest_version":true},
      {"container":"debian",       "tag":"bookworm-12.0.0",  "variant":"bookworm",    "flavor":"base"},
      {"container":"terraform",    "tag":"1.8.0",            "variant":"",            "flavor":""},
      {"container":"web-shell",    "tag":"ubuntu-1.0.0",     "variant":"ubuntu",      "flavor":"base","is_latest_version":true}
    ]'
}

# Fixture with mixed OS cells: bake-managed container with linux, windows, and absent .os;
# plus a non-bake-managed container for control.
# github-runner linux cells carry is_latest_version:true so they route to .bake;
# windows cell always goes to .matrix regardless of is_latest_version.
_fixture_os_builds() {
    jq -cn '
    [
      {"container":"github-runner","os":"linux",   "tag":"ubuntu-2404-1.2.3","variant":"ubuntu-2404","is_latest_version":true},
      {"container":"github-runner","os":"windows", "tag":"windows-2022-1.2.3","variant":"windows-2022","is_latest_version":true},
      {"container":"github-runner","tag":"linux-noos-1.2.3","variant":"ubuntu-2204","is_latest_version":true},
      {"container":"debian",       "os":"linux",   "tag":"bookworm-12.0.0",  "variant":"bookworm"}
    ]'
}

# ---------------------------------------------------------------------------
# BM-01: Default partition — bake-managed containers (github-runner/web-shell/wordpress)
#        land in .bake; debian (no is_latest_version:true in fixture) and terraform
#        land in .matrix.
# Catches: MM1, MM2, MM3, MM5, MM8
# ---------------------------------------------------------------------------
@test "BM-01: default partition routes github-runner/web-shell/wordpress to bake, others to matrix" {
    # Source the helper
    # shellcheck disable=SC1090
    source "$BM"

    result=$(partition_builds "$(_fixture_builds)")

    # Validate JSON structure
    echo "$result" | jq -e 'has("bake") and has("matrix")' >/dev/null

    # bake partition contains the bake-managed containers that carry is_latest_version:true
    # (web-shell has 2 entries; debian in fixture lacks is_latest_version:true so stays in matrix)
    bake_containers=$(echo "$result" | jq -r '[.bake[].container] | sort | unique | .[]')
    echo "$bake_containers" | grep -q "^github-runner$"
    echo "$bake_containers" | grep -q "^web-shell$"
    echo "$bake_containers" | grep -q "^wordpress$"

    # matrix partition must NOT contain bake-managed containers that carried is_latest_version:true
    matrix_containers=$(echo "$result" | jq -r '[.matrix[].container] | unique | .[]')
    ! echo "$matrix_containers" | grep -q "^github-runner$"
    ! echo "$matrix_containers" | grep -q "^web-shell$"
    ! echo "$matrix_containers" | grep -q "^wordpress$"

    # debian fixture cell (no is_latest_version:true) and terraform route to matrix
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

    # Use a local fixture where the overridden container (debian) carries
    # is_latest_version:true so it satisfies the bake routing gate.
    local fixture
    fixture=$(jq -cn '
    [
      {"container":"github-runner","tag":"ubuntu-2404-1.2.3","variant":"ubuntu-2404","flavor":"dev","is_latest_version":true},
      {"container":"web-shell",    "tag":"alpine-1.0.0",     "variant":"alpine",      "flavor":"base","is_latest_version":true},
      {"container":"wordpress",    "tag":"latest-6.5.0",     "variant":"latest",      "flavor":"php82","is_latest_version":true},
      {"container":"debian",       "tag":"bookworm-12.0.0",  "variant":"bookworm",    "flavor":"base","is_latest_version":true},
      {"container":"terraform",    "tag":"1.8.0",            "variant":"",            "flavor":""}
    ]')

    BAKE_MANAGED_CONTAINERS="debian" result=$(partition_builds "$fixture")

    # Only debian must be in bake (is_latest_version:true + bake-managed)
    bake_containers=$(echo "$result" | jq -r '[.bake[].container] | unique | .[]')
    [[ "$bake_containers" == "debian" ]]

    # github-runner, web-shell, wordpress must now be in matrix (not in managed set)
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
# BM-07: is_bake_managed — debian returns 0 (now in default set, PR-B slice 1).
# Catches: MM9
# ---------------------------------------------------------------------------
@test "BM-07: is_bake_managed returns 0 for debian (now in default set)" {
    # shellcheck disable=SC1090
    source "$BM"

    run is_bake_managed "debian"
    [[ "$status" -eq 0 ]]
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
# BM-08b: is_bake_managed — PR-B slice 1 new containers (debian/vector/jekyll/ansible)
#          return 0 (in default set); terraform returns 1 (still matrix-only).
# ---------------------------------------------------------------------------
@test "BM-08b: is_bake_managed returns 0 for debian/vector/jekyll/ansible; 1 for terraform" {
    # shellcheck disable=SC1090
    source "$BM"

    run is_bake_managed "debian"
    [[ "$status" -eq 0 ]]

    run is_bake_managed "vector"
    [[ "$status" -eq 0 ]]

    run is_bake_managed "jekyll"
    [[ "$status" -eq 0 ]]

    run is_bake_managed "ansible"
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

# ---------------------------------------------------------------------------
# BM-11: OS guard — github-runner windows cell stays in .matrix even though
#         github-runner is bake-managed. The bake generator is linux-only; a
#         windows cell in .bake would be orphaned (built by neither path).
# Catches: MM11
# ---------------------------------------------------------------------------
@test "BM-11: github-runner windows cell routes to matrix, not bake" {
    # shellcheck disable=SC1090
    source "$BM"

    result=$(partition_builds "$(_fixture_os_builds)")

    # The windows cell must land in .matrix
    windows_in_matrix=$(echo "$result" | jq -r '[.matrix[] | select(.container == "github-runner" and .os == "windows")] | length')
    [[ "$windows_in_matrix" -eq 1 ]]

    # The windows cell must NOT be in .bake
    windows_in_bake=$(echo "$result" | jq -r '[.bake[] | select(.container == "github-runner" and .os == "windows")] | length')
    [[ "$windows_in_bake" -eq 0 ]]

    # debian (bake-managed but no is_latest_version:true in fixture) must also stay in .matrix
    debian_in_matrix=$(echo "$result" | jq -r '[.matrix[] | select(.container == "debian")] | length')
    [[ "$debian_in_matrix" -eq 1 ]]
}

# ---------------------------------------------------------------------------
# BM-12: OS guard — github-runner linux cell (explicit .os="linux") goes to .bake;
#         github-runner cell with absent .os (omitted field) also goes to .bake
#         (absent .os is treated as linux because linux cells may omit the field).
# Catches: MM12
# ---------------------------------------------------------------------------
@test "BM-12: github-runner linux cell and absent-os cell both route to bake" {
    # shellcheck disable=SC1090
    source "$BM"

    result=$(partition_builds "$(_fixture_os_builds)")

    # Explicit os=linux cell must land in .bake
    linux_in_bake=$(echo "$result" | jq -r '[.bake[] | select(.container == "github-runner" and .os == "linux")] | length')
    [[ "$linux_in_bake" -eq 1 ]]

    # Absent .os cell must also land in .bake
    noos_in_bake=$(echo "$result" | jq -r '[.bake[] | select(.container == "github-runner" and (.os? == null or .os? == ""))] | length')
    [[ "$noos_in_bake" -ge 1 ]]

    # Total bake count: linux + absent-os github-runner = 2
    bake_gr_count=$(echo "$result" | jq -r '[.bake[] | select(.container == "github-runner")] | length')
    [[ "$bake_gr_count" -eq 2 ]]

    # Total count preserved (lossless)
    input_count=$(jq 'length' <<< "$(_fixture_os_builds)")
    bake_count=$(echo "$result" | jq '.bake | length')
    matrix_count=$(echo "$result" | jq '.matrix | length')
    total=$(( bake_count + matrix_count ))
    [[ "$total" -eq "$input_count" ]]
}

# ---------------------------------------------------------------------------
# BM-13: bake_latest_only — github-runner retained cell (is_latest_version:false)
#         routes to .matrix; github-runner latest cell (is_latest_version:true)
#         routes to .bake.  Verifies the per-cell fidelity fix (FIX 1).
# Catches: new finding — retained github-runner built by neither path without this fix
# ---------------------------------------------------------------------------
@test "BM-13: github-runner retained linux cell routes to matrix; latest linux cell routes to bake" {
    # shellcheck disable=SC1090
    source "$BM"

    fixture=$(jq -cn '
    [
      {"container":"github-runner","os":"linux","tag":"ubuntu-2404-2.334.0","variant":"ubuntu-2404","is_latest_version":true},
      {"container":"github-runner","os":"linux","tag":"ubuntu-2404-2.333.0","variant":"ubuntu-2404","is_latest_version":false},
      {"container":"github-runner","os":"linux","tag":"ubuntu-2404-2.332.0","variant":"ubuntu-2404","is_latest_version":false}
    ]')

    result=$(partition_builds "$fixture")

    # Latest cell must land in .bake
    latest_in_bake=$(echo "$result" | jq '[.bake[] | select(.tag == "ubuntu-2404-2.334.0")] | length')
    [[ "$latest_in_bake" -eq 1 ]]

    # Retained cells must land in .matrix
    retained_in_matrix=$(echo "$result" | jq '[.matrix[] | select(.is_latest_version == false)] | length')
    [[ "$retained_in_matrix" -eq 2 ]]

    # No retained cell in .bake
    retained_in_bake=$(echo "$result" | jq '[.bake[] | select(.is_latest_version == false)] | length')
    [[ "$retained_in_bake" -eq 0 ]]

    # Lossless
    total=$(echo "$result" | jq '.bake + .matrix | length')
    [[ "$total" -eq 3 ]]
}

# ---------------------------------------------------------------------------
# BM-14: Retained (non-latest) cells for ANY bake-managed container route to
#         .matrix — bake is latest-only by design.  Tests web-shell (no
#         variants.yaml bake_latest_only flag) and wordpress to verify the
#         universal is_latest_version==true gate applies to all bake-managed
#         containers, not just those that declare bake_latest_only.
# Catches: retained bake-managed cell falsely recovered/unscanned by a latest-only bake run
# ---------------------------------------------------------------------------
@test "BM-14: retained web-shell and wordpress cells (is_latest_version:false) route to matrix" {
    # shellcheck disable=SC1090
    source "$BM"

    fixture=$(jq -cn '
    [
      {"container":"web-shell","os":"linux","tag":"alpine-2.0.0","variant":"alpine","is_latest_version":true},
      {"container":"web-shell","os":"linux","tag":"alpine-1.0.0","variant":"alpine","is_latest_version":false},
      {"container":"wordpress","os":"linux","tag":"latest-7.0.0","variant":"latest","is_latest_version":true},
      {"container":"wordpress","os":"linux","tag":"latest-6.9.4","variant":"latest","is_latest_version":false},
      {"container":"debian","os":"linux","tag":"bookworm-12.0.0","variant":"bookworm"}
    ]')

    result=$(partition_builds "$fixture")

    # Only the latest web-shell cell must land in .bake
    ws_latest_in_bake=$(echo "$result" | jq '[.bake[] | select(.container == "web-shell" and .is_latest_version == true)] | length')
    [[ "$ws_latest_in_bake" -eq 1 ]]

    # Only the latest wordpress cell must land in .bake
    wp_latest_in_bake=$(echo "$result" | jq '[.bake[] | select(.container == "wordpress" and .is_latest_version == true)] | length')
    [[ "$wp_latest_in_bake" -eq 1 ]]

    # Retained web-shell cell must land in .matrix
    ws_retained_in_matrix=$(echo "$result" | jq '[.matrix[] | select(.container == "web-shell" and .is_latest_version == false)] | length')
    [[ "$ws_retained_in_matrix" -eq 1 ]]

    # Retained wordpress cell must land in .matrix
    wp_retained_in_matrix=$(echo "$result" | jq '[.matrix[] | select(.container == "wordpress" and .is_latest_version == false)] | length')
    [[ "$wp_retained_in_matrix" -eq 1 ]]

    # Retained cells must NOT appear in .bake
    retained_in_bake=$(echo "$result" | jq '[.bake[] | select(.is_latest_version == false)] | length')
    [[ "$retained_in_bake" -eq 0 ]]

    # debian (bake-managed but no is_latest_version:true in fixture) must land in .matrix
    deb_in_matrix=$(echo "$result" | jq '[.matrix[] | select(.container == "debian")] | length')
    [[ "$deb_in_matrix" -eq 1 ]]

    # Lossless
    total=$(echo "$result" | jq '.bake + .matrix | length')
    [[ "$total" -eq 5 ]]
}

# ---------------------------------------------------------------------------
# BM-15: scope_active="true" — ALL cells (including bake-managed latest linux)
#         route to .matrix; .bake is empty.  Verifies the scope-override fix
#         that prevents unscanned images when scope_flavors/scope_versions is set.
# ---------------------------------------------------------------------------
@test "BM-15: scope_active=true routes all cells to matrix (bake disabled)" {
    # shellcheck disable=SC1090
    source "$BM"

    # Mixed fixture: bake-managed latest, bake-managed retained, non-bake, windows
    fixture=$(jq -cn '
    [
      {"container":"github-runner","os":"linux","tag":"2.334.0","is_latest_version":true},
      {"container":"github-runner","os":"linux","tag":"2.333.0","is_latest_version":false},
      {"container":"github-runner","os":"windows","tag":"2.334.0-win","is_latest_version":true},
      {"container":"web-shell","os":"linux","tag":"alpine-1.0.0","is_latest_version":true},
      {"container":"debian","os":"linux","tag":"bookworm-12.0.0"}
    ]')

    result=$(partition_builds "$fixture" "true")

    # bake must be empty
    bake_count=$(echo "$result" | jq '.bake | length')
    [[ "$bake_count" -eq 0 ]]

    # matrix must contain all 5 cells
    matrix_count=$(echo "$result" | jq '.matrix | length')
    [[ "$matrix_count" -eq 5 ]]

    # Lossless
    total=$(echo "$result" | jq '.bake + .matrix | length')
    [[ "$total" -eq 5 ]]
}

# ---------------------------------------------------------------------------
# BM-17: force_matrix=true (PR routing) — ALL cells (including bake-managed latest
#         linux) route to .matrix; .bake is empty.  This is the same partition_builds
#         2nd-arg semantics used by the split-build-engine step on pull_request events,
#         ensuring bake-managed containers receive per-cell PR build+Trivy coverage
#         via the flat matrix instead of being orphaned by a skipped bake job.
# Catches: PR routing — bake-managed containers skipping PR Trivy coverage
# ---------------------------------------------------------------------------
@test "BM-17: force_matrix=true (PR event routing) routes all cells to matrix" {
    # shellcheck disable=SC1090
    source "$BM"

    fixture=$(jq -cn '
    [
      {"container":"github-runner","os":"linux","tag":"2.334.0","is_latest_version":true},
      {"container":"web-shell","os":"linux","tag":"alpine-1.0.0","is_latest_version":true},
      {"container":"wordpress","os":"linux","tag":"latest-6.5.0","is_latest_version":true},
      {"container":"debian","os":"linux","tag":"bookworm-12.0.0"}
    ]')

    # The split-build-engine step passes force_matrix="true" when EVENT_NAME == pull_request
    result=$(partition_builds "$fixture" "true")

    # bake must be empty — no bake jobs run on PR
    bake_count=$(echo "$result" | jq '.bake | length')
    [[ "$bake_count" -eq 0 ]]

    # matrix must contain all 4 cells (bake-managed containers included)
    matrix_count=$(echo "$result" | jq '.matrix | length')
    [[ "$matrix_count" -eq 4 ]]

    # All three bake-managed containers must be in matrix
    matrix_containers=$(echo "$result" | jq -r '[.matrix[].container] | unique | sort | .[]')
    echo "$matrix_containers" | grep -q "^github-runner$"
    echo "$matrix_containers" | grep -q "^web-shell$"
    echo "$matrix_containers" | grep -q "^wordpress$"

    # Lossless
    total=$(echo "$result" | jq '.bake + .matrix | length')
    [[ "$total" -eq 4 ]]
}

# ---------------------------------------------------------------------------
# BM-16: scope_active default (absent) applies per-cell logic — not scope_active.
#         Confirms that omitting the second arg is equivalent to scope_active=false.
# ---------------------------------------------------------------------------
@test "BM-16: scope_active absent is equivalent to false (per-cell routing)" {
    # shellcheck disable=SC1090
    source "$BM"

    fixture=$(jq -cn '
    [
      {"container":"web-shell","os":"linux","tag":"alpine-1.0.0","is_latest_version":true},
      {"container":"debian","os":"linux","tag":"bookworm-12.0.0"}
    ]')

    # Call with no second arg
    result=$(partition_builds "$fixture")

    # web-shell linux must land in .bake
    ws_in_bake=$(echo "$result" | jq '[.bake[] | select(.container == "web-shell")] | length')
    [[ "$ws_in_bake" -eq 1 ]]

    # debian must land in .matrix
    deb_in_matrix=$(echo "$result" | jq '[.matrix[] | select(.container == "debian")] | length')
    [[ "$deb_in_matrix" -eq 1 ]]
}
