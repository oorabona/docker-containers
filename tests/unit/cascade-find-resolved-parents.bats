#!/usr/bin/env bats

# Unit tests for scripts/cascade-find-resolved-parents.sh (stranded cascade labels).
#
# Root cause locked here: a parent drift PR's master build can be cancelled by the
# auto-build concurrency group, so cascade-resolver never sees it and the child keeps
# `cascade:waiting-for-<parent>` forever. The sweep must report a parent only when the
# parent PR is merged (after the child was created), not open, AND a later master
# build succeeded.
#
# `gh` is mocked from env fixtures: WAITING (output of the children query, already
# jq-filtered), OPEN_<n>, MERGED_<n>, RUNS (JSON for `gh run list`).

load "../test_helper"

bats_require_minimum_version 1.5.0

setup() {
    setup_temp_dir
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
args="$*"
case "$args" in
  "pr list --label base-digest-drift"*)
    [[ "${GH_FAIL_CHILDREN:-}" == 1 ]] && exit 1
    printf '%s' "${WAITING:-}" ;;
  *"--head update/base-digest-"*"--state open"*)
    [[ "${GH_FAIL_OPEN:-}" == 1 ]] && exit 1
    p="${args#*update/base-digest-}"; p="${p%% *}"
    v="OPEN_${p//-/_}"; echo "${!v:-0}" ;;
  *"--head update/base-digest-"*"--state merged"*)
    p="${args#*update/base-digest-}"; p="${p%% *}"
    v="MERGED_${p//-/_}"; printf '%s' "${!v:-}" ;;
  "run list"*)
    printf '%s' "${RUNS:-[]}" ;;
  *) echo "unexpected gh call: $args" >&2; exit 99 ;;
esac
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/gh"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export GH_REPO="o/r"
    SCRIPT="$PROJECT_ROOT/scripts/cascade-find-resolved-parents.sh"
}

teardown() { teardown_temp_dir; }

@test "no waiting children → no output, exit 0" {
    WAITING="" run --separate-stderr "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "children listing failure → exit 1 (fail-closed)" {
    GH_FAIL_CHILDREN=1 run --separate-stderr "$SCRIPT"
    [ "$status" -eq 1 ]
}

@test "parent merged after child, later successful build → reported (the #2129 case)" {
    WAITING=$'debian 2026-10-22T11:20:19Z\n' \
    MERGED_debian="2026-10-22T11:22:09Z" \
    RUNS='[{"createdAt":"2026-10-24T10:27:15Z"}]' \
        run --separate-stderr "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$output" = "debian" ]
}

@test "parent drift PR still open → not reported" {
    WAITING=$'debian 2026-10-22T11:20:19Z\n' OPEN_debian=1 \
    MERGED_debian="2026-10-22T11:22:09Z" RUNS='[{"createdAt":"2026-10-24T10:27:15Z"}]' \
        run --separate-stderr "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "no merged parent PR → not reported" {
    WAITING=$'debian 2026-10-22T11:20:19Z\n' RUNS='[{"createdAt":"2026-10-24T10:27:15Z"}]' \
        run --separate-stderr "$SCRIPT"
    [ -z "$output" ]
}

@test "parent merged BEFORE the waiting child was created → not reported" {
    WAITING=$'debian 2026-10-22T11:20:19Z\n' MERGED_debian="2026-10-21T11:19:53Z" \
    RUNS='[{"createdAt":"2026-10-24T10:27:15Z"}]' run --separate-stderr "$SCRIPT"
    [ -z "$output" ]
}

@test "merged but no successful master build since → not reported" {
    WAITING=$'debian 2026-10-22T11:20:19Z\n' MERGED_debian="2026-10-22T11:22:09Z" \
    RUNS='[{"createdAt":"2026-10-22T11:00:00Z"}]' run --separate-stderr "$SCRIPT"
    [ -z "$output" ]
}

@test "open-PR lookup failure → parent skipped, exit 0 (retried next sweep)" {
    WAITING=$'debian 2026-10-22T11:20:19Z\n' GH_FAIL_OPEN=1 MERGED_debian="2026-10-22T11:22:09Z" \
    RUNS='[{"createdAt":"2026-10-24T10:27:15Z"}]' run --separate-stderr "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "invalid parent name is ignored (injection guard)" {
    WAITING=$'de bian;x 2026-10-22T11:20:19Z\n..%2F 2026-10-22T11:20:19Z\n' \
        run --separate-stderr "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "two parents: only the resolved one is reported; newest child date is used" {
    WAITING=$'debian 2026-10-22T11:20:19Z\ndebian 2026-10-22T11:30:00Z\nphp 2026-10-22T11:20:19Z\n' \
    MERGED_debian="2026-10-22T11:22:09Z" MERGED_php="2026-10-22T11:25:00Z" \
    RUNS='[{"createdAt":"2026-10-24T10:27:15Z"}]' run --separate-stderr "$SCRIPT"
    # debian merged 11:22 < newest child 11:30 → not reported; php resolved.
    [ "$output" = "php" ]
}

# ---------------------------------------------------------------------------
# Structural locks on cascade-resolver.yaml (sweep wiring)
# ---------------------------------------------------------------------------

@test "workflow: hourly schedule + workflow_dispatch(parent) triggers present" {
    local wf="$PROJECT_ROOT/.github/workflows/cascade-resolver.yaml"
    grep -q "^  schedule:" "$wf"
    grep -q "^  workflow_dispatch:" "$wf"
    grep -q "^      parent:" "$wf"
}

@test "workflow: sweep dispatches the resolver per parent (token locks live in cascade-resolver.bats)" {
    local wf="$PROJECT_ROOT/.github/workflows/cascade-resolver.yaml"
    grep -q "scripts/cascade-find-resolved-parents.sh" "$wf"
    grep -q 'gh workflow run cascade-resolver.yaml --ref master -f "parent=' "$wf"
}

@test "workflow: dispatch parent input is regex-validated before use" {
    local wf="$PROJECT_ROOT/.github/workflows/cascade-resolver.yaml"
    grep -q 'INPUT_PARENT" =~ \^\[a-z0-9_-\]+\$' "$wf"
}

@test "workflow: unblock-children never runs on schedule or on a parent-less dispatch" {
    local wf="$PROJECT_ROOT/.github/workflows/cascade-resolver.yaml"
    grep -q "inputs.parent != ''" "$wf"
    grep -q "github.event.workflow_run.conclusion == 'success'" "$wf"
}
