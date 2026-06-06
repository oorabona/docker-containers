#!/usr/bin/env bats
# Unit tests for helpers/bake-buildresult.sh — ADR-013 R2 slice (#595 emission)
#
# Mutation guards (named per test):
#   MB1: Change success condition (e.g. ignore digest) → success count wrong
#   MB2: Remove fail-closed on absent metadata → absent file yields success
#   MB3: Use wrong field name (e.g. "status" instead of "result") → shape mismatch
#   MB4: Use arch from cells instead of arg → arch field wrong
#   MB5: Omit warning on absent metadata → no ::warning:: annotation
#   MB6: target_id mismatch → all cells become failure even with valid metadata

load "../test_helper"

setup() {
    export PROJECT_ROOT
    export HELPERS_DIR

    # Bake-buildresult script under test
    export BBR="${HELPERS_DIR}/bake-buildresult.sh"

    # Suppress GHA annotations in variant-utils / list_build_matrix
    export GITHUB_ACTIONS=""
    export _DEPGRAPH_LINEAGE_DIR=/nonexistent

    # Create a per-test output directory (scope guard allows writes under
    # PROJECT_ROOT only; use mktemp under /tmp and source the script).
    export TEST_OUT_DIR
    TEST_OUT_DIR=$(mktemp -d)
}

teardown() {
    rm -rf "$TEST_OUT_DIR"
}

# ---------------------------------------------------------------------------
# Helper: read the real --cells output and build a complete metadata fixture
# that marks EVERY cell as success.
# ---------------------------------------------------------------------------
_all_success_meta() {
    local container="$1"
    # Get cells JSON; build a metadata object with one key per target_id.
    local cells
    cells=$(bash "${PROJECT_ROOT}/scripts/generate-bake-hcl.sh" --cells "$container")
    # Construct metadata: {target_id: {"containerimage.digest":"sha256:…"}}
    echo "$cells" | jq -c '
        reduce .[] as $cell (
            {};
            . + {($cell.target_id): {"containerimage.digest":("sha256:" + $cell.target_id), "image.name":"ghcr.io/test"}}
        )
    '
}

# ---------------------------------------------------------------------------
# Helper: build a partial metadata fixture — all cells EXCEPT the last one.
# ---------------------------------------------------------------------------
_partial_meta() {
    local container="$1"
    local cells
    cells=$(bash "${PROJECT_ROOT}/scripts/generate-bake-hcl.sh" --cells "$container")
    local n
    n=$(echo "$cells" | jq 'length')
    # Include n-1 cells (exclude the last)
    echo "$cells" | jq -c --argjson n "$n" '
        .[0:($n-1)] |
        reduce .[] as $cell (
            {};
            . + {($cell.target_id): {"containerimage.digest":("sha256:" + $cell.target_id), "image.name":"ghcr.io/test"}}
        )
    '
}

# ---------------------------------------------------------------------------
# MB1 + shape: all-success case — every emitted result is "success";
#              shape is exactly {container, variant, tag, arch, result}.
# ---------------------------------------------------------------------------
@test "BBR-01: all cells success when metadata contains every target_id with digest" {
    local meta_file="$TEST_OUT_DIR/meta_all.json"
    _all_success_meta web-shell > "$meta_file"

    run bash "$BBR" "$meta_file" amd64 "$TEST_OUT_DIR/out" web-shell
    [ "$status" -eq 0 ]

    # Every emitted file must have result="success"
    local fail_count
    fail_count=$(find "$TEST_OUT_DIR/out" -name '*.json' \
        -exec jq -r '.result' {} \; | grep -c '^failure$' || true)
    [ "$fail_count" -eq 0 ]

    # Must have emitted at least one file
    local file_count
    file_count=$(find "$TEST_OUT_DIR/out" -name 'build-result-*.json' | wc -l)
    [ "$file_count" -gt 0 ]

    # MB3 / shape parity: each file has exactly the 5 keys defined by auto-build.yaml:1054-1061
    local shape_fail
    shape_fail=$(find "$TEST_OUT_DIR/out" -name '*.json' -exec jq -e '
        has("container") and has("variant") and has("tag") and has("arch") and has("result")
    ' {} \; | grep -c '^false$' || true)
    [ "$shape_fail" -eq 0 ]
}

# ---------------------------------------------------------------------------
# MB4: arch field in emitted files matches the supplied arch argument
# ---------------------------------------------------------------------------
@test "BBR-02: emitted build-result files carry the supplied arch field" {
    local meta_file="$TEST_OUT_DIR/meta_all.json"
    _all_success_meta web-shell > "$meta_file"

    run bash "$BBR" "$meta_file" arm64 "$TEST_OUT_DIR/out" web-shell
    [ "$status" -eq 0 ]

    local wrong_arch
    wrong_arch=$(find "$TEST_OUT_DIR/out" -name '*.json' \
        -exec jq -r '.arch' {} \; | grep -cv '^arm64$' || true)
    [ "$wrong_arch" -eq 0 ]
}

# ---------------------------------------------------------------------------
# partial: missing target → failure; others → success
# ---------------------------------------------------------------------------
@test "BBR-03: partial metadata — cell absent from metadata emits result=failure" {
    local meta_file="$TEST_OUT_DIR/meta_partial.json"
    _partial_meta web-shell > "$meta_file"

    local cells
    cells=$(bash "${PROJECT_ROOT}/scripts/generate-bake-hcl.sh" --cells web-shell)
    local n
    n=$(echo "$cells" | jq 'length')

    run bash "$BBR" "$meta_file" amd64 "$TEST_OUT_DIR/out" web-shell
    [ "$status" -eq 0 ]

    # Exactly 1 failure (the last cell)
    local fail_count
    fail_count=$(find "$TEST_OUT_DIR/out" -name '*.json' \
        -exec jq -r '.result' {} \; | grep -c '^failure$' || true)
    [ "$fail_count" -eq 1 ]

    # n-1 successes
    local success_count
    success_count=$(find "$TEST_OUT_DIR/out" -name '*.json' \
        -exec jq -r '.result' {} \; | grep -c '^success$' || true)
    [ "$success_count" -eq $(( n - 1 )) ]
}

# ---------------------------------------------------------------------------
# MB2 + MB5: absent metadata → fail-closed (all failure) + ::warning::
# ---------------------------------------------------------------------------
@test "BBR-04: absent metadata file → all cells failure (fail-closed)" {
    run bash "$BBR" "$TEST_OUT_DIR/nonexistent.json" amd64 "$TEST_OUT_DIR/out" web-shell 2>&1
    [ "$status" -eq 0 ]

    # All results must be failure
    local success_count
    success_count=$(find "$TEST_OUT_DIR/out" -name '*.json' \
        -exec jq -r '.result' {} \; | grep -c '^success$' || true)
    [ "$success_count" -eq 0 ]

    # Must have emitted files (fail-closed writes artifacts, not just errors)
    local file_count
    file_count=$(find "$TEST_OUT_DIR/out" -name 'build-result-*.json' | wc -l)
    [ "$file_count" -gt 0 ]
}

@test "BBR-05: absent metadata file emits a ::warning:: annotation" {
    # Run with stderr captured to combined output (bats 'run' merges them)
    run bash "$BBR" "$TEST_OUT_DIR/nonexistent.json" amd64 "$TEST_OUT_DIR/out" web-shell 2>&1
    [ "$status" -eq 0 ]
    # ::warning:: must appear in stderr (captured via 2>&1 by run)
    [[ "$output" == *"::warning::"* ]]
}

# ---------------------------------------------------------------------------
# File naming: build-result-<container>-<tag>-<arch>.json (parity with auto-build.yaml:1061)
# ---------------------------------------------------------------------------
@test "BBR-06: emitted filenames match build-result-<container>-<tag>-<arch>.json pattern" {
    local meta_file="$TEST_OUT_DIR/meta_all.json"
    _all_success_meta web-shell > "$meta_file"

    run bash "$BBR" "$meta_file" amd64 "$TEST_OUT_DIR/out" web-shell
    [ "$status" -eq 0 ]

    # Each filename must conform to the naming convention
    local bad_names
    bad_names=0
    while IFS= read -r f; do
        local fname
        fname=$(basename "$f")
        # Must match build-result-<container>-<tag>-amd64.json
        if [[ "$fname" != build-result-web-shell-*-amd64.json ]]; then
            (( bad_names++ )) || true
        fi
    done < <(find "$TEST_OUT_DIR/out" -name '*.json')
    [ "$bad_names" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Shape: emitted JSON has EXACTLY 5 keys (no extras)
# ---------------------------------------------------------------------------
@test "BBR-07: emitted JSON has exactly 5 keys: container variant tag arch result" {
    local meta_file="$TEST_OUT_DIR/meta_all.json"
    _all_success_meta web-shell > "$meta_file"

    run bash "$BBR" "$meta_file" amd64 "$TEST_OUT_DIR/out" web-shell
    [ "$status" -eq 0 ]

    local wrong_count
    wrong_count=$(find "$TEST_OUT_DIR/out" -name '*.json' \
        -exec jq 'keys | length' {} \; | grep -cv '^5$' || true)
    [ "$wrong_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# container field matches the container arg
# ---------------------------------------------------------------------------
@test "BBR-08: emitted container field matches the requested container name" {
    local meta_file="$TEST_OUT_DIR/meta_all.json"
    _all_success_meta web-shell > "$meta_file"

    run bash "$BBR" "$meta_file" amd64 "$TEST_OUT_DIR/out" web-shell
    [ "$status" -eq 0 ]

    local wrong_container
    wrong_container=$(find "$TEST_OUT_DIR/out" -name '*.json' \
        -exec jq -r '.container' {} \; | grep -cv '^web-shell$' || true)
    [ "$wrong_container" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Cell count parity: number of emitted files equals number of --cells entries
# ---------------------------------------------------------------------------
@test "BBR-09: number of emitted build-result files equals --cells entry count for web-shell" {
    local meta_file="$TEST_OUT_DIR/meta_all.json"
    _all_success_meta web-shell > "$meta_file"

    local expected_count
    expected_count=$(bash "${PROJECT_ROOT}/scripts/generate-bake-hcl.sh" \
        --cells web-shell | jq 'length')

    run bash "$BBR" "$meta_file" amd64 "$TEST_OUT_DIR/out" web-shell
    [ "$status" -eq 0 ]

    local file_count
    file_count=$(find "$TEST_OUT_DIR/out" -name 'build-result-*.json' | wc -l)
    [ "$file_count" -eq "$expected_count" ]
}

# ---------------------------------------------------------------------------
# MB6: target_id key-join correctness — a metadata keyed by ACTUAL target_ids
# yields success; swapping to wrong keys yields failure (join is tight).
# ---------------------------------------------------------------------------
@test "BBR-10: wrong target_id keys in metadata → all cells failure (join must be tight)" {
    # Build a metadata file with wrong keys (e.g. containerids with a bogus prefix)
    jq -cn '{
        "WRONG_KEY_1": {"containerimage.digest":"sha256:aaa","image.name":"ghcr.io/test"},
        "WRONG_KEY_2": {"containerimage.digest":"sha256:bbb","image.name":"ghcr.io/test"}
    }' > "$TEST_OUT_DIR/meta_wrong.json"

    run bash "$BBR" "$TEST_OUT_DIR/meta_wrong.json" amd64 "$TEST_OUT_DIR/out" web-shell
    [ "$status" -eq 0 ]

    # All cells must be failure — none of the right target_ids are in the metadata
    local success_count
    success_count=$(find "$TEST_OUT_DIR/out" -name '*.json' \
        -exec jq -r '.result' {} \; | grep -c '^success$' || true)
    [ "$success_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# tag field in emitted file matches cells tag (not overridden by arch arg)
# ---------------------------------------------------------------------------
@test "BBR-11: emitted tag field matches the cell tag (not the arch argument)" {
    local meta_file="$TEST_OUT_DIR/meta_all.json"
    _all_success_meta web-shell > "$meta_file"

    run bash "$BBR" "$meta_file" amd64 "$TEST_OUT_DIR/out" web-shell
    [ "$status" -eq 0 ]

    # Get expected tags from --cells
    local expected_tags
    expected_tags=$(bash "${PROJECT_ROOT}/scripts/generate-bake-hcl.sh" \
        --cells web-shell | jq -r '.[].tag' | sort)

    # Get actual tags from emitted files
    local actual_tags
    actual_tags=$(find "$TEST_OUT_DIR/out" -name '*.json' \
        -exec jq -r '.tag' {} \; | sort)

    [ "$expected_tags" = "$actual_tags" ]
}

# ---------------------------------------------------------------------------
# ::notice:: summary always emitted (success path)
# ---------------------------------------------------------------------------
@test "BBR-12: ::notice:: summary is emitted on success" {
    local meta_file="$TEST_OUT_DIR/meta_all.json"
    _all_success_meta web-shell > "$meta_file"

    run bash "$BBR" "$meta_file" amd64 "$TEST_OUT_DIR/out" web-shell 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"::notice::bake-buildresult:"* ]]
}

# ---------------------------------------------------------------------------
# FIX C: BAKE_GENERATE_ALL_RETAINED env controls --all-retained in --cells
# ---------------------------------------------------------------------------

# Helper: get cells count from generator directly (with or without --all-retained)
_latest_cell_count() {
    bash "${PROJECT_ROOT}/scripts/generate-bake-hcl.sh" --cells "$1" | jq 'length'
}
_retained_cell_count() {
    bash "${PROJECT_ROOT}/scripts/generate-bake-hcl.sh" --cells --all-retained "$1" | jq 'length'
}

@test "BBR-13: without BAKE_GENERATE_ALL_RETAINED, emit covers latest-only cells" {
    # terraform has more retained cells than latest-only cells (github-runner is
    # bake_latest_only, so it can't exercise the retained path).
    local latest_count
    latest_count=$(_latest_cell_count terraform)
    local retained_count
    retained_count=$(_retained_cell_count terraform)
    # Prerequisite: retained set is strictly larger than latest-only set.
    [ "$retained_count" -gt "$latest_count" ]

    # Build a metadata fixture that marks ALL cells (retained) as success so
    # the file-count diff is purely from cell enumeration, not from missing metadata.
    local meta_file="$TEST_OUT_DIR/meta_retained.json"
    cells_all=$(bash "${PROJECT_ROOT}/scripts/generate-bake-hcl.sh" --cells --all-retained terraform)
    echo "$cells_all" | jq -c '
        reduce .[] as $cell (
            {};
            . + {($cell.target_id): {"containerimage.digest":("sha256:" + $cell.target_id), "image.name":"ghcr.io/test"}}
        )
    ' > "$meta_file"

    # Run WITHOUT the retained env (default: latest-only).
    run env -u BAKE_GENERATE_ALL_RETAINED bash "$BBR" "$meta_file" amd64 "$TEST_OUT_DIR/out" terraform
    [ "$status" -eq 0 ]

    local file_count
    file_count=$(find "$TEST_OUT_DIR/out" -name 'build-result-*.json' | wc -l)
    # Must match latest-only count, NOT retained count.
    [ "$file_count" -eq "$latest_count" ]
}

@test "BBR-14: with BAKE_GENERATE_ALL_RETAINED=true, emit covers all retained cells" {
    # terraform has more retained cells than latest-only cells (github-runner is
    # bake_latest_only, so it can't exercise the retained path).
    local retained_count
    retained_count=$(_retained_cell_count terraform)

    # Build a metadata fixture that marks ALL retained cells as success.
    local meta_file="$TEST_OUT_DIR/meta_retained.json"
    cells_all=$(bash "${PROJECT_ROOT}/scripts/generate-bake-hcl.sh" --cells --all-retained terraform)
    echo "$cells_all" | jq -c '
        reduce .[] as $cell (
            {};
            . + {($cell.target_id): {"containerimage.digest":("sha256:" + $cell.target_id), "image.name":"ghcr.io/test"}}
        )
    ' > "$meta_file"

    # Run WITH BAKE_GENERATE_ALL_RETAINED=true.
    run env BAKE_GENERATE_ALL_RETAINED=true bash "$BBR" "$meta_file" amd64 "$TEST_OUT_DIR/out" terraform
    [ "$status" -eq 0 ]

    local file_count
    file_count=$(find "$TEST_OUT_DIR/out" -name 'build-result-*.json' | wc -l)
    # Must match the full retained count.
    [ "$file_count" -eq "$retained_count" ]
}
