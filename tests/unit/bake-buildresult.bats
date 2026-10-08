#!/usr/bin/env bats
# Unit tests for helpers/bake-buildresult.sh — ADR-013 R2 slice (#595 emission)
#
# Mutation guards (named per test):
#   Change success condition (e.g. ignore digest) → success count wrong
#   Remove fail-closed on absent metadata → absent file yields success
#   Use wrong field name (e.g. "status" instead of "result") → shape mismatch
#   Use arch from cells instead of arg → arch field wrong
#   Omit warning on absent metadata → no ::warning:: annotation
#   target_id mismatch → all cells become failure even with valid metadata

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
@test "all cells success when metadata contains every target_id with digest" {
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
# arch field in emitted files matches the supplied arch argument
# ---------------------------------------------------------------------------
@test "emitted build-result files carry the supplied arch field" {
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
@test "partial metadata — cell absent from metadata emits result=failure" {
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
@test "absent metadata file → all cells failure (fail-closed)" {
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

@test "absent metadata file emits a ::warning:: annotation" {
    # Run with stderr captured to combined output (bats 'run' merges them)
    run bash "$BBR" "$TEST_OUT_DIR/nonexistent.json" amd64 "$TEST_OUT_DIR/out" web-shell 2>&1
    [ "$status" -eq 0 ]
    # ::warning:: must appear in stderr (captured via 2>&1 by run)
    [[ "$output" == *"::warning::"* ]]
}

# ---------------------------------------------------------------------------
# File naming: build-result-<container>-<tag>-<arch>.json (parity with auto-build.yaml:1061)
# ---------------------------------------------------------------------------
@test "emitted filenames match build-result-<container>-<tag>-<arch>.json pattern" {
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
@test "emitted JSON has exactly 5 keys: container variant tag arch result" {
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
@test "emitted container field matches the requested container name" {
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
@test "number of emitted build-result files equals --cells entry count for web-shell" {
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
# target_id key-join correctness — a metadata keyed by ACTUAL target_ids
# yields success; swapping to wrong keys yields failure (join is tight).
# ---------------------------------------------------------------------------
@test "wrong target_id keys in metadata → all cells failure (join must be tight)" {
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
@test "emitted tag field matches the cell tag (not the arch argument)" {
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
@test "::notice:: summary is emitted on success" {
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

@test "without BAKE_GENERATE_ALL_RETAINED, emit covers latest-only cells" {
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

@test "with BAKE_GENERATE_ALL_RETAINED=true, emit covers all retained cells" {
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

@test "scoped build-result enumeration ignores scoped-out terraform flavors" {
    local scoped_cells
    scoped_cells=$(bash "${PROJECT_ROOT}/scripts/generate-bake-hcl.sh" \
        --cells --scope-flavors aws terraform)

    local scoped_count
    scoped_count=$(echo "$scoped_cells" | jq 'length')
    [ "$scoped_count" -eq 1 ]

    local meta_file="$TEST_OUT_DIR/meta_scoped.json"
    echo "$scoped_cells" | jq -c '
        reduce .[] as $cell (
            {};
            . + {($cell.target_id): {"containerimage.digest":("sha256:" + $cell.target_id), "image.name":"ghcr.io/test"}}
        )
    ' > "$meta_file"

    run env SCOPE_FLAVORS=aws bash "$BBR" "$meta_file" amd64 "$TEST_OUT_DIR/out" terraform
    [ "$status" -eq 0 ]

    local file_count fail_count
    file_count=$(find "$TEST_OUT_DIR/out" -name 'build-result-*.json' | wc -l)
    fail_count=$(find "$TEST_OUT_DIR/out" -name '*.json' \
        -exec jq -r '.result' {} \; | grep -c '^failure$' || true)

    [ "$file_count" -eq "$scoped_count" ]
    [ "$fail_count" -eq 0 ]

    local expected_tags actual_tags
    expected_tags=$(echo "$scoped_cells" | jq -r '.[].tag' | sort)
    actual_tags=$(find "$TEST_OUT_DIR/out" -name '*.json' \
        -exec jq -r '.tag' {} \; | sort)
    [ "$actual_tags" = "$expected_tags" ]
}

@test "container_scopes build-result enumeration ignores scoped-out github-runner flavors" {
    local container_scopes='{"github-runner":{"flavors":"debian-trixie"}}'
    local scoped_cells
    scoped_cells=$(bash "${PROJECT_ROOT}/scripts/generate-bake-hcl.sh" \
        --cells --container-scopes "$container_scopes" github-runner)

    local scoped_count unscoped_count
    scoped_count=$(echo "$scoped_cells" | jq 'length')
    unscoped_count=$(bash "${PROJECT_ROOT}/scripts/generate-bake-hcl.sh" \
        --cells github-runner | jq 'length')
    [ "$scoped_count" -gt 0 ]
    [ "$unscoped_count" -gt "$scoped_count" ]

    local meta_file="$TEST_OUT_DIR/meta_container_scopes.json"
    echo "$scoped_cells" | jq -c '
        reduce .[] as $cell (
            {};
            . + {($cell.target_id): {"containerimage.digest":("sha256:" + $cell.target_id), "image.name":"ghcr.io/test"}}
        )
    ' > "$meta_file"

    run env CONTAINER_SCOPES="$container_scopes" bash "$BBR" "$meta_file" amd64 "$TEST_OUT_DIR/out" github-runner
    [ "$status" -eq 0 ]

    local file_count fail_count
    file_count=$(find "$TEST_OUT_DIR/out" -name 'build-result-*.json' | wc -l)
    fail_count=$(find "$TEST_OUT_DIR/out" -name '*.json' \
        -exec jq -r '.result' {} \; | grep -c '^failure$' || true)

    [ "$file_count" -eq "$scoped_count" ]
    [ "$fail_count" -eq 0 ]

    local expected_tags actual_tags
    expected_tags=$(echo "$scoped_cells" | jq -r '.[].tag' | sort)
    actual_tags=$(find "$TEST_OUT_DIR/out" -name '*.json' \
        -exec jq -r '.tag' {} \; | sort)
    [ "$actual_tags" = "$expected_tags" ]
}

# ---------------------------------------------------------------------------
# Failure attribution from the captured bake log (BAKE_LOG_FILE).
#
# buildx writes no --metadata-file when a target fails and cancels the sibling
# targets, so without the log every cell is an undifferentiated "failure".
#
# Mutation guards:
#   marking every no-digest cell cause=failed would blame the cancelled siblings
#   annotating success cells would change the 5-key shape for good builds
#   ignoring BAKE_LOG_FILE unset would crash or annotate without evidence
#   a loose target regex would let a log line inject arbitrary target ids
# ---------------------------------------------------------------------------

# Two real containers, one cell each. Sets: OVPN_TID VEC_TID CELLS
_attribution_cells() {
    CELLS=$(bash "${PROJECT_ROOT}/scripts/generate-bake-hcl.sh" --cells openvpn vector)
    OVPN_TID=$(jq -r '[.[] | select(.container == "openvpn")][0].target_id' <<< "$CELLS")
    VEC_TID=$(jq -r '[.[] | select(.container == "vector")][0].target_id' <<< "$CELLS")
    [ -n "$OVPN_TID" ] && [ "$OVPN_TID" != null ]
    [ -n "$VEC_TID" ] && [ "$VEC_TID" != null ]
}

_result_file() { # <container>
    local f
    f=$(find "$TEST_OUT_DIR" -name "build-result-${1}-*-amd64.json" | head -1)
    cat "$f"
}

@test "attribution: the failing target is cause=failed, cancelled siblings are cause=aborted" {
    _attribution_cells
    local log="$TEST_OUT_DIR/bake.log"
    printf 'some progress\nERROR: target %s: failed to solve: process "/bin/sh" did not complete\n' "$OVPN_TID" > "$log"

    BAKE_LOG_FILE="$log" run bash "$BBR" "$TEST_OUT_DIR/absent.json" amd64 "$TEST_OUT_DIR" openvpn vector
    [ "$status" -eq 0 ]

    local o v
    o=$(_result_file openvpn); v=$(_result_file vector)
    # still fail-closed: neither has a digest, both are rebuilt next run
    [ "$(jq -r .result <<< "$o")" = failure ]
    [ "$(jq -r .result <<< "$v")" = failure ]
    [ "$(jq -r .cause <<< "$o")" = failed ]
    [ "$(jq -r .cause <<< "$v")" = aborted ]
    [ "$(jq -c .culprits <<< "$v")" = '["openvpn"]' ]
    [ "$(jq -c .failed_targets <<< "$v")" = "[\"$OVPN_TID\"]" ]
}

@test "attribution: a target that failed on every retry is listed once" {
    _attribution_cells
    local log="$TEST_OUT_DIR/bake.log"
    for _ in 1 2 3; do
        printf 'ERROR: target %s: failed to solve: boom\n' "$OVPN_TID"
    done > "$log"

    BAKE_LOG_FILE="$log" run bash "$BBR" "$TEST_OUT_DIR/absent.json" amd64 "$TEST_OUT_DIR" openvpn vector
    [ "$status" -eq 0 ]
    [ "$(_result_file vector | jq '.failed_targets | length')" -eq 1 ]
}

@test "attribution: no log, or a log naming no target, leaves exactly the five original keys" {
    _attribution_cells
    run bash "$BBR" "$TEST_OUT_DIR/absent.json" amd64 "$TEST_OUT_DIR" openvpn vector
    [ "$status" -eq 0 ]
    [ "$(_result_file openvpn | jq 'keys | length')" -eq 5 ]

    local log="$TEST_OUT_DIR/bake.log"
    printf 'ERROR: failed to build: unrelated\n' > "$log"
    BAKE_LOG_FILE="$log" run bash "$BBR" "$TEST_OUT_DIR/absent.json" amd64 "$TEST_OUT_DIR" openvpn vector
    [ "$status" -eq 0 ]
    [ "$(_result_file openvpn | jq 'keys | length')" -eq 5 ]
    [ "$(_result_file vector | jq 'keys | length')" -eq 5 ]
}

@test "attribution: a missing or unreadable log file is ignored, not fatal" {
    _attribution_cells
    BAKE_LOG_FILE="$TEST_OUT_DIR/does-not-exist.log" run bash "$BBR" "$TEST_OUT_DIR/absent.json" amd64 "$TEST_OUT_DIR" openvpn vector
    [ "$status" -eq 0 ]
    [ "$(_result_file openvpn | jq 'keys | length')" -eq 5 ]
}

@test "attribution: a built cell stays a plain success even when the log names another target" {
    _attribution_cells
    local meta="$TEST_OUT_DIR/meta.json" log="$TEST_OUT_DIR/bake.log"
    jq -cn --arg t "$VEC_TID" '{($t): {"containerimage.digest": "sha256:abc"}}' > "$meta"
    printf 'ERROR: target %s: failed to solve: boom\n' "$OVPN_TID" > "$log"

    BAKE_LOG_FILE="$log" run bash "$BBR" "$meta" amd64 "$TEST_OUT_DIR" openvpn vector
    [ "$status" -eq 0 ]
    [ "$(_result_file vector | jq -r .result)" = success ]
    [ "$(_result_file vector | jq 'keys | length')" -eq 5 ]
    [ "$(_result_file openvpn | jq -r .cause)" = failed ]
}

@test "attribution: only well-formed target ids are accepted from the log" {
    _attribution_cells
    local log="$TEST_OUT_DIR/bake.log"
    {
        printf 'ERROR: target evil;touch /tmp/x: failed to solve\n'
        printf 'x#ERROR: target %s: embedded mid-token\n' "$VEC_TID"
        printf 'ERROR: target %s: failed to solve: boom\n' "$OVPN_TID"
    } > "$log"

    BAKE_LOG_FILE="$log" run bash "$BBR" "$TEST_OUT_DIR/absent.json" amd64 "$TEST_OUT_DIR" openvpn vector
    [ "$status" -eq 0 ]
    [ "$(_result_file vector | jq -c .failed_targets)" = "[\"$OVPN_TID\"]" ]
    [ "$(_result_file vector | jq -r .cause)" = aborted ]
}

# ---------------------------------------------------------------------------
# Replay of the real failure that motivated #2057: run 37623415329 (2026-10-07).
# Only openvpn failed; the bake cancelled ansible, github-runner and vector,
# which all got their own "Build failed" issue. The fixture is the captured tail
# of that run's "Bake build (amd64)" job log. Cells are stubbed with that run's
# target ids so the replay does not depend on today's pinned versions.
# ---------------------------------------------------------------------------

_replay_run() { # <log file> -> $REPLAY_RESULTS (JSON array of build-result records)
    local stub="$TEST_OUT_DIR/stub"
    mkdir -p "$stub/helpers" "$stub/scripts"
    cp "$BBR" "${HELPERS_DIR}/logging.sh" "$stub/helpers/"
    cat > "$stub/scripts/generate-bake-hcl.sh" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
[{"container":"openvpn","tag":"v2.7.8-alpine","variant":"","target_id":"openvpn_v2_7_8_alpine"},
 {"container":"vector","tag":"0.59.0-alpine","variant":"","target_id":"vector_0_59_0_alpine"},
 {"container":"ansible","tag":"14.5.0-ubuntu","variant":"","target_id":"ansible_14_5_0_ubuntu"},
 {"container":"github-runner","tag":"2.338.0-ubuntu-2404","variant":"ubuntu-2404","target_id":"github_runner_2_338_0_ubuntu_2404_base"}]
JSON
STUB
    chmod +x "$stub/scripts/generate-bake-hcl.sh"
    BAKE_LOG_FILE="$1" run bash "$stub/helpers/bake-buildresult.sh" "$TEST_OUT_DIR/absent.json" amd64 "$TEST_OUT_DIR/out" openvpn vector ansible github-runner
    [ "$status" -eq 0 ]
    REPLAY_RESULTS=$(jq -s -c '.' "$TEST_OUT_DIR"/out/*.json)
}

@test "replay run 37623415329: only openvpn gets an issue, the cancelled siblings are listed on it" {
    source "${HELPERS_DIR}/coverage-checkpoint-utils.sh"
    _replay_run "${FIXTURES_DIR}/bake-abort-run-37623415329-amd64.txt"

    [ "$(jq -r '.[] | select(.container=="openvpn") | .cause' <<< "$REPLAY_RESULTS")" = failed ]
    [ "$(jq -r '[.[] | select(.container!="openvpn") | .cause] | unique | join(",")' <<< "$REPLAY_RESULTS")" = aborted ]

    local matrix='["ansible","github-runner","openvpn","vector"]' er ftr
    er=$(aggregate_build_results "$REPLAY_RESULTS" "$matrix")
    ftr=$(jq -c .failed_this_run <<< "$er")
    # every container stays failed -> all four are retried next run
    [ "$ftr" = '["ansible","github-runner","openvpn","vector"]' ]
    [ "$(merge_failed_set '[]' "$ftr" '[]' "$matrix" false)" = "$ftr" ]

    run split_aborted_failures "$REPLAY_RESULTS" "$ftr"
    [ "$status" -eq 0 ]
    [ "$(jq -c .open <<< "$output")" = '["openvpn"]' ]
    [ "$(jq -c .aborted <<< "$output")" = '{"openvpn":["ansible","github-runner","vector"]}' ]
}

@test "replay run 37623415329: if buildx's 'ERROR: target' line changes, every failed container keeps its issue" {
    source "${HELPERS_DIR}/coverage-checkpoint-utils.sh"
    sed 's/ERROR: target /ERROR: job /' "${FIXTURES_DIR}/bake-abort-run-37623415329-amd64.txt" > "$TEST_OUT_DIR/changed.log"
    _replay_run "$TEST_OUT_DIR/changed.log"

    [ "$(jq -c '[.[] | keys | length] | unique' <<< "$REPLAY_RESULTS")" = '[5]' ]
    local ftr='["ansible","github-runner","openvpn","vector"]'
    run split_aborted_failures "$REPLAY_RESULTS" "$ftr"
    [ "$status" -eq 0 ]
    [ "$(jq -c .open <<< "$output")" = "$ftr" ]
    [ "$(jq -c .aborted <<< "$output")" = '{}' ]
}
