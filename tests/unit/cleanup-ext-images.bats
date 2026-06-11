#!/usr/bin/env bats

# Unit tests for scripts/cleanup-ext-images.sh.
#
# These tests mock GHCR as package VERSION RECORDS:
#   [{ id, metadata: { container: { tags: [...] } } }]
#
# They never hit the real network.

load "../test_helper"

setup() {
    setup_temp_dir

    export GH_TOKEN="test-token"
    export OWNER="test-owner"

    mkdir -p "$TEST_TEMP_DIR/postgres/extensions"
    cat > "$TEST_TEMP_DIR/postgres/extensions/config.yaml" <<'EOF'
pg_versions:
  - "17"
extensions:
  timescaledb:
    version: "2.27.2"
    version_set:
      resolver: "scripts/resolvers/timescaledb-ha.sh"
      retain_count: 12
EOF
    export EXT_CONFIG="$TEST_TEMP_DIR/postgres/extensions/config.yaml"

    # shellcheck disable=SC1091
    source "$PROJECT_ROOT/scripts/cleanup-ext-images.sh"
}

teardown() {
    teardown_temp_dir
    unset GH_TOKEN OWNER EXT_CONFIG
}

_write_window() {
    local windows_dir="$1"
    local pg_major="$2"
    local window_json="$3"

    mkdir -p "$windows_dir"
    printf '%s\n' "$window_json" > "$windows_dir/pg${pg_major}.json"
}

_run_cleanup_main_with_records() {
    local records_file="$1"
    local windows_dir="$2"
    local delete_mode="$3"
    local delete_calls_file="$4"
    local list_mode="$5"
    shift 5

    run env \
        PROJECT_ROOT="$PROJECT_ROOT" \
        EXT_CONFIG="$EXT_CONFIG" \
        GH_TOKEN="$GH_TOKEN" \
        OWNER="$OWNER" \
        CLEANUP_RECORDS_FILE="$records_file" \
        CLEANUP_WINDOWS_DIR="$windows_dir" \
        CLEANUP_DELETE_MODE="$delete_mode" \
        CLEANUP_DELETE_CALLS_FILE="$delete_calls_file" \
        CLEANUP_LIST_MODE="$list_mode" \
        bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/scripts/cleanup-ext-images.sh"

            _discover_resolver_extensions() { printf "%s\n" "timescaledb"; }
            _discover_pg_versions() { printf "%s\n" "17"; }
            resolve_version_set() {
                local pg_major="$2"
                local window_file="$CLEANUP_WINDOWS_DIR/pg${pg_major}.json"
                [[ -f "$window_file" ]] || return 1
                cat "$window_file"
            }
            gh() {
                if [[ "$*" == *"--method DELETE"* ]]; then
                    local arg
                    local last_arg=""
                    for arg in "$@"; do
                        last_arg="$arg"
                    done
                    printf "DELETE:%s\n" "${last_arg##*/}" >> "$CLEANUP_DELETE_CALLS_FILE"
                    [[ "$CLEANUP_DELETE_MODE" != "fail" ]]
                    return
                fi

                [[ "$CLEANUP_LIST_MODE" != "fail" ]] || return 1
                cat "$CLEANUP_RECORDS_FILE"
            }

            main "$@"
        ' _ "$@"
}

@test "_parse_ext_managed_tag parses base and arch extension tags" {
    [[ "$(_parse_ext_managed_tag "pg17-2.27.1")" == "17|2.27.1" ]]
    [[ "$(_parse_ext_managed_tag "pg17-2.27.1-amd64")" == "17|2.27.1" ]]
    [[ "$(_parse_ext_managed_tag "pg17-2.27.1-arm64")" == "17|2.27.1" ]]
}

@test "_parse_ext_managed_tag rejects unparseable and foreign tags" {
    ! _parse_ext_managed_tag "pg17-latest"
    ! _parse_ext_managed_tag "pg17-2.27.1-windows"
    ! _parse_ext_managed_tag "latest"
    ! _parse_ext_managed_tag "other-image-tag"
}

@test "mixed-tag version record is kept; separate all-stale record is selected" {
    local records_file="$TEST_TEMP_DIR/mixed-records.json"
    local windows_dir="$TEST_TEMP_DIR/windows"
    local delete_calls_file="$TEST_TEMP_DIR/mixed-deletes"

    cat > "$records_file" <<'EOF'
[
  {
    "id": 101,
    "name": "sha256:mixed",
    "metadata": { "container": { "tags": ["pg17-2.27.1", "pg17-2.23.0"] } }
  },
  {
    "id": 102,
    "name": "sha256:stale",
    "metadata": { "container": { "tags": ["pg17-2.22.0"] } }
  }
]
EOF
    _write_window "$windows_dir" "17" '["2.27.1"]'

    _run_cleanup_main_with_records "$records_file" "$windows_dir" "success" "$delete_calls_file" "success"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"KEEP  version_id=101"* ]]
    [[ "$output" == *"contains retained tag: pg17-2.27.1"* ]]
    [[ "$output" != *"Would delete ext-timescaledb version_id=101"* ]]
    [[ "$output" == *"PRUNE version_id=102"* ]]
    [[ "$output" == *"[DRY-RUN] Would delete ext-timescaledb version_id=102"* ]]
    [[ "$output" == *"Summary: kept=1, pruned=1, failed=0"* ]]
    [[ ! -f "$delete_calls_file" ]]
}

@test "P1 arch siblings: in-window records kept and out-of-window records pruned" {
    local records_file="$TEST_TEMP_DIR/arch-records.json"
    local windows_dir="$TEST_TEMP_DIR/windows"
    local delete_calls_file="$TEST_TEMP_DIR/arch-deletes"

    cat > "$records_file" <<'EOF'
[
  { "id": 201, "metadata": { "container": { "tags": ["pg17-2.27.1"] } } },
  { "id": 202, "metadata": { "container": { "tags": ["pg17-2.27.1-amd64"] } } },
  { "id": 203, "metadata": { "container": { "tags": ["pg17-2.27.1-arm64"] } } },
  { "id": 204, "metadata": { "container": { "tags": ["pg17-2.23.0"] } } },
  { "id": 205, "metadata": { "container": { "tags": ["pg17-2.23.0-amd64"] } } }
]
EOF
    _write_window "$windows_dir" "17" '["2.27.1"]'

    _run_cleanup_main_with_records "$records_file" "$windows_dir" "success" "$delete_calls_file" "success"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"KEEP  version_id=201"* ]]
    [[ "$output" == *"KEEP  version_id=202"* ]]
    [[ "$output" == *"KEEP  version_id=203"* ]]
    [[ "$output" != *"PRUNE version_id=202"* ]]
    [[ "$output" != *"PRUNE version_id=203"* ]]
    [[ "$output" == *"PRUNE version_id=204"* ]]
    [[ "$output" == *"PRUNE version_id=205"* ]]
    [[ "$output" == *"Summary: kept=3, pruned=2, failed=0"* ]]
    [[ ! -f "$delete_calls_file" ]]
}

@test "retired registry-derived major is enumerated and pruned when stale" {
    local records_file="$TEST_TEMP_DIR/retired-records.json"
    local windows_dir="$TEST_TEMP_DIR/windows"
    local delete_calls_file="$TEST_TEMP_DIR/retired-deletes"

    cat > "$records_file" <<'EOF'
[
  { "id": 301, "metadata": { "container": { "tags": ["pg15-2.23.0"] } } }
]
EOF
    _write_window "$windows_dir" "17" '["2.27.1"]'
    _write_window "$windows_dir" "15" '["2.27.1"]'

    _run_cleanup_main_with_records "$records_file" "$windows_dir" "success" "$delete_calls_file" "success"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Registry PG majors: 15"* ]]
    [[ "$output" == *"PG major: 15"* ]]
    [[ "$output" == *"PRUNE version_id=301"* ]]
    [[ "$output" == *"Version records pruned: 1"* ]]
    [[ ! -f "$delete_calls_file" ]]
}

@test "retired registry-derived major is kept fail-closed when its window cannot be computed" {
    local records_file="$TEST_TEMP_DIR/retired-fail-records.json"
    local windows_dir="$TEST_TEMP_DIR/windows"
    local delete_calls_file="$TEST_TEMP_DIR/retired-fail-deletes"

    cat > "$records_file" <<'EOF'
[
  { "id": 311, "metadata": { "container": { "tags": ["pg15-2.23.0"] } } }
]
EOF
    _write_window "$windows_dir" "17" '["2.27.1"]'

    _run_cleanup_main_with_records "$records_file" "$windows_dir" "success" "$delete_calls_file" "success"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Resolver failed for timescaledb/pg15"* ]]
    [[ "$output" == *"KEEP  version_id=311"* ]]
    [[ "$output" == *"window unknown for pg15: pg15-2.23.0"* ]]
    [[ "$output" == *"Summary: kept=1, pruned=0, failed=0"* ]]
    [[ ! -f "$delete_calls_file" ]]
}

@test "unparseable or foreign tag protects the entire version record" {
    local records_file="$TEST_TEMP_DIR/foreign-records.json"
    local windows_dir="$TEST_TEMP_DIR/windows"
    local delete_calls_file="$TEST_TEMP_DIR/foreign-deletes"

    cat > "$records_file" <<'EOF'
[
  { "id": 401, "metadata": { "container": { "tags": ["pg17-2.23.0", "pg17-latest"] } } },
  { "id": 402, "metadata": { "container": { "tags": ["pg17-2.23.0", "latest"] } } }
]
EOF
    _write_window "$windows_dir" "17" '["2.27.1"]'

    _run_cleanup_main_with_records "$records_file" "$windows_dir" "success" "$delete_calls_file" "success"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"KEEP  version_id=401"* ]]
    [[ "$output" == *"contains unmanaged/unparseable tag: pg17-latest"* ]]
    [[ "$output" == *"KEEP  version_id=402"* ]]
    [[ "$output" == *"contains unmanaged/unparseable tag: latest"* ]]
    [[ "$output" == *"Summary: kept=2, pruned=0, failed=0"* ]]
    [[ ! -f "$delete_calls_file" ]]
}

@test "P2 execute mode: failed delete exits non-zero and is not counted as pruned" {
    local records_file="$TEST_TEMP_DIR/delete-failure-records.json"
    local windows_dir="$TEST_TEMP_DIR/windows"
    local delete_calls_file="$TEST_TEMP_DIR/delete-failure-calls"

    cat > "$records_file" <<'EOF'
[
  { "id": 501, "metadata": { "container": { "tags": ["pg17-2.23.0"] } } }
]
EOF
    _write_window "$windows_dir" "17" '["2.27.1"]'

    _run_cleanup_main_with_records "$records_file" "$windows_dir" "fail" "$delete_calls_file" "success" --execute

    [[ "$status" -ne 0 ]]
    [[ -f "$delete_calls_file" ]]
    grep -q "DELETE:501" "$delete_calls_file"
    [[ "$output" == *"PRUNE version_id=501"* ]]
    [[ "$output" == *"Failed to delete ext-timescaledb version_id=501"* ]]
    [[ "$output" == *"Summary: kept=0, pruned=0, failed=1"* ]]
    [[ "$output" == *"Version records pruned: 0"* ]]
    [[ "$output" == *"Delete failures: 1"* ]]
}

@test "P2 execute mode: successful delete exits zero and is counted as pruned" {
    local records_file="$TEST_TEMP_DIR/delete-success-records.json"
    local windows_dir="$TEST_TEMP_DIR/windows"
    local delete_calls_file="$TEST_TEMP_DIR/delete-success-calls"

    cat > "$records_file" <<'EOF'
[
  { "id": 502, "metadata": { "container": { "tags": ["pg17-2.23.0"] } } }
]
EOF
    _write_window "$windows_dir" "17" '["2.27.1"]'

    _run_cleanup_main_with_records "$records_file" "$windows_dir" "success" "$delete_calls_file" "success" --execute

    [[ "$status" -eq 0 ]]
    [[ -f "$delete_calls_file" ]]
    grep -q "DELETE:502" "$delete_calls_file"
    [[ "$output" == *"PRUNE version_id=502"* ]]
    [[ "$output" == *"Deleted ext-timescaledb version_id=502"* ]]
    [[ "$output" == *"Summary: kept=0, pruned=1, failed=0"* ]]
    [[ "$output" == *"Version records pruned: 1"* ]]
    [[ "$output" == *"Delete failures: 0"* ]]
}

@test "dry-run default: stale record is selected but no delete call is made" {
    local records_file="$TEST_TEMP_DIR/dry-run-records.json"
    local windows_dir="$TEST_TEMP_DIR/windows"
    local delete_calls_file="$TEST_TEMP_DIR/dry-run-calls"

    cat > "$records_file" <<'EOF'
[
  { "id": 601, "metadata": { "container": { "tags": ["pg17-2.23.0"] } } }
]
EOF
    _write_window "$windows_dir" "17" '["2.27.1"]'

    _run_cleanup_main_with_records "$records_file" "$windows_dir" "success" "$delete_calls_file" "success"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"DRY-RUN MODE"* ]]
    [[ "$output" == *"PRUNE version_id=601"* ]]
    [[ "$output" == *"[DRY-RUN] Would delete ext-timescaledb version_id=601"* ]]
    [[ "$output" == *"Version records pruned: 1"* ]]
    [[ ! -f "$delete_calls_file" ]]
}

@test "GHCR version listing failure skips extension fail-closed" {
    local records_file="$TEST_TEMP_DIR/list-fail-records.json"
    local windows_dir="$TEST_TEMP_DIR/windows"
    local delete_calls_file="$TEST_TEMP_DIR/list-fail-calls"

    printf '[]\n' > "$records_file"
    _write_window "$windows_dir" "17" '["2.27.1"]'

    _run_cleanup_main_with_records "$records_file" "$windows_dir" "success" "$delete_calls_file" "fail"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"GHCR version listing failed for ext-timescaledb"* ]]
    [[ "$output" == *"Extensions skipped (listing failed): 1"* ]]
    [[ ! -f "$delete_calls_file" ]]
}

@test "--help flag exits 0 and prints usage" {
    run bash "$PROJECT_ROOT/scripts/cleanup-ext-images.sh" --help

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Usage:"* ]]
    [[ "$output" == *"--execute"* ]]
}

@test "unknown flag exits non-zero" {
    run bash "$PROJECT_ROOT/scripts/cleanup-ext-images.sh" --unknown-flag

    [[ "$status" -ne 0 ]]
}
