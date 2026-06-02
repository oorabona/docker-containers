#!/usr/bin/env bats

# Unit tests for scripts/check-version-drift.sh
#
# All tests invoke the script via CLI — no internal-function rigs.
# Real helpers/variant-utils.sh is used with temp variants.yaml/config.yaml fixtures.
# Only the GHCR probe is stubbed via _VDRIFT_PROBE_OVERRIDE.
# Bump timestamp is controlled via _VDRIFT_BUMP_EPOCH_OVERRIDE.
# Container list is controlled via _VDRIFT_CONTAINERS_OVERRIDE.
# GHCR owner is controlled via _VDRIFT_GHCR_OWNER_OVERRIDE.
#
# Mutation guards:
#   MG1: Remove grace check → in_flight becomes drift (breaks test 3)
#   MG2: Remove absent→drift branch → drift status never set (breaks test 2)
#   MG3: Remove probe → absent always → in_sync never set (breaks test 1)
#   MG4: Remove error propagation → error becomes in_sync (breaks test 6)

load "../test_helper"

bats_require_minimum_version 1.5.0

DRIFT_SCRIPT=""

setup() {
    setup_temp_dir

    DRIFT_SCRIPT="${SCRIPTS_DIR}/check-version-drift.sh"

    # Fixed GHCR owner to avoid git remote calls
    export _VDRIFT_GHCR_OWNER_OVERRIDE="testowner"
    # Default: bump happened long ago (older than grace window) so absent → drift
    export _VDRIFT_BUMP_EPOCH_OVERRIDE="1"

    export TEST_TEMP_DIR
    export DRIFT_SCRIPT
}

teardown() {
    teardown_temp_dir
}

# ---------------------------------------------------------------------------
# Helper: create a temp project root with one container's variants.yaml
# Returns the temp root path on stdout.
# ---------------------------------------------------------------------------
_make_temp_project() {
    local container="$1"
    local versions=("${@:2}")   # remaining args are version tags

    local root="${TEST_TEMP_DIR}/project"
    local cdir="${root}/${container}"
    mkdir -p "$cdir"

    # Create a minimal variants.yaml (simple format — no multi-variant)
    {
        printf 'build:\n  version_retention: 3\nversions:\n'
        for v in "${versions[@]}"; do
            printf '  - tag: %s\n' "$v"
        done
    } > "${cdir}/variants.yaml"

    # Stub ./make list so the script can enumerate containers
    mkdir -p "${root}"
    cat > "${root}/make" <<MAKE_EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "list" ]]; then
    echo "${container}"
fi
MAKE_EOF
    chmod +x "${root}/make"

    printf '%s' "$root"
}

# ---------------------------------------------------------------------------
# Helper: create a probe stub (script) that maps image refs to statuses.
# Usage: _make_probe_stub <image_ref_1> <status_1> [<ref_2> <status_2> ...]
# Unmatched refs return "absent" by default (can be overridden by passing
# the special marker "__default__" <status>).
#
# Generates a case-statement stub to avoid bash 4 associative array issues.
# ---------------------------------------------------------------------------
_make_probe_stub() {
    local stub_path="${TEST_TEMP_DIR}/bin/probe-stub-$$"
    mkdir -p "${TEST_TEMP_DIR}/bin"

    # Build case branches
    local case_branches=""
    local default_status="absent"
    local -a args=("$@")
    local i=0
    while (( i < ${#args[@]} )); do
        local ref="${args[$i]}"
        local st="${args[$i+1]}"
        (( i += 2 )) || true
        if [[ "$ref" == "__default__" ]]; then
            default_status="$st"
        else
            # Escape any special chars in ref for the case pattern
            local escaped_ref
            escaped_ref=$(printf '%s' "$ref" | sed 's/[\\*?[]/\\&/g')
            case_branches+="        '${escaped_ref}') printf '%s' '${st}' ;;"$'\n'
        fi
    done

    {
        printf '#!/usr/bin/env bash\n'
        printf 'case "$1" in\n'
        printf '%s' "$case_branches"
        printf "        *) printf '%%s' '%s' ;;\n" "$default_status"
        printf 'esac\n'
    } > "$stub_path"

    chmod +x "$stub_path"
    printf '%s' "$stub_path"
}

# ---------------------------------------------------------------------------
# Test 1: in_sync — declared version published → no drift row, exit 0
# MG3: if probe is removed, absent is returned → status would be drift, not in_sync
# ---------------------------------------------------------------------------
@test "in_sync: declared version published → no drift row, exit 0" {
    local root
    root=$(_make_temp_project "foo" "9.9.9")

    local probe
    probe=$(_make_probe_stub \
        "ghcr.io/testowner/foo:9.9.9" "present")

    run --separate-stderr env \
        PROJECT_ROOT="$root" \
        _VDRIFT_CONTAINERS_OVERRIDE="foo" \
        _VDRIFT_GHCR_OWNER_OVERRIDE="testowner" \
        _VDRIFT_BUMP_EPOCH_OVERRIDE="1" \
        _VDRIFT_PROBE_OVERRIDE="$probe" \
        bash "$DRIFT_SCRIPT" --mode sweep --json

    [ "$status" -eq 0 ]

    # Output must be valid JSON array
    printf '%s' "$output" | jq '.' >/dev/null

    # No drift rows
    local drift_count
    drift_count=$(printf '%s' "$output" | jq '[.[] | select(.status=="drift")] | length')
    [ "$drift_count" -eq 0 ]

    # Must have exactly one row with status in_sync
    local sync_count
    sync_count=$(printf '%s' "$output" | jq '[.[] | select(.status=="in_sync")] | length')
    [ "$sync_count" -eq 1 ]

    # Row content
    local row_name row_declared row_status
    row_name=$(printf '%s' "$output" | jq -r '.[0].name')
    row_declared=$(printf '%s' "$output" | jq -r '.[0].declared')
    row_status=$(printf '%s' "$output" | jq -r '.[0].status')
    [ "$row_name" = "foo" ]
    [ "$row_declared" = "9.9.9" ]
    [ "$row_status" = "in_sync" ]
}

# ---------------------------------------------------------------------------
# Test 2: drift — declared version absent, bump old → drift row, exit 1
# MG2: if absent→drift branch is removed, status never becomes "drift" → test fails
# ---------------------------------------------------------------------------
@test "drift: declared-absent + old bump → drift row + exit 1" {
    local root
    root=$(_make_temp_project "foo" "9.9.9")

    local probe
    probe=$(_make_probe_stub \
        "__default__" "absent")

    run --separate-stderr env \
        PROJECT_ROOT="$root" \
        _VDRIFT_CONTAINERS_OVERRIDE="foo" \
        _VDRIFT_GHCR_OWNER_OVERRIDE="testowner" \
        _VDRIFT_BUMP_EPOCH_OVERRIDE="1" \
        _VDRIFT_PROBE_OVERRIDE="$probe" \
        bash "$DRIFT_SCRIPT" --mode sweep --json

    [ "$status" -eq 1 ]

    printf '%s' "$output" | jq '.' >/dev/null

    local drift_rows
    drift_rows=$(printf '%s' "$output" | jq '[.[] | select(.status=="drift")]')

    local drift_count
    drift_count=$(printf '%s' "$drift_rows" | jq 'length')
    [ "$drift_count" -eq 1 ]

    local row
    row=$(printf '%s' "$drift_rows" | jq '.[0]')
    [ "$(printf '%s' "$row" | jq -r '.kind')" = "container" ]
    [ "$(printf '%s' "$row" | jq -r '.name')" = "foo" ]
    [ "$(printf '%s' "$row" | jq -r '.declared')" = "9.9.9" ]
    [ "$(printf '%s' "$row" | jq -r '.published')" = "" ]
    [ "$(printf '%s' "$row" | jq -r '.status')" = "drift" ]
}

# ---------------------------------------------------------------------------
# Test 3: in_flight — declared absent, bump ≤ grace hours → in_flight, exit 0
# MG1: if grace check is removed, in_flight becomes drift → exit 1 not 0
# ---------------------------------------------------------------------------
@test "in_flight: declared-absent + bump within grace → in_flight + exit 0" {
    local root
    root=$(_make_temp_project "foo" "9.9.9")

    local probe
    probe=$(_make_probe_stub "__default__" "absent")

    # bump_epoch = NOW (within grace window)
    local now
    now=$(date +%s)

    run --separate-stderr env \
        PROJECT_ROOT="$root" \
        _VDRIFT_CONTAINERS_OVERRIDE="foo" \
        _VDRIFT_GHCR_OWNER_OVERRIDE="testowner" \
        _VDRIFT_BUMP_EPOCH_OVERRIDE="$now" \
        _VDRIFT_PROBE_OVERRIDE="$probe" \
        bash "$DRIFT_SCRIPT" --mode sweep --json --grace-hours 6

    [ "$status" -eq 0 ]

    printf '%s' "$output" | jq '.' >/dev/null

    local in_flight_count
    in_flight_count=$(printf '%s' "$output" | jq '[.[] | select(.status=="in_flight")] | length')
    [ "$in_flight_count" -eq 1 ]

    local drift_count
    drift_count=$(printf '%s' "$output" | jq '[.[] | select(.status=="drift")] | length')
    [ "$drift_count" -eq 0 ]

    local row_status
    row_status=$(printf '%s' "$output" | jq -r '.[0].status')
    [ "$row_status" = "in_flight" ]
}

# ---------------------------------------------------------------------------
# Test 4: timescaledb resolver ceiling present → window_ok, exit 0
# ---------------------------------------------------------------------------
@test "timescaledb resolver ceiling published → window_ok + exit 0" {
    local root="${TEST_TEMP_DIR}/tsdb-project"
    mkdir -p "${root}/postgres/extensions"

    # Minimal extensions config with timescaledb version_set
    cat > "${root}/postgres/extensions/config.yaml" <<'YAML'
pg_versions:
  - "17"
extensions:
  timescaledb:
    version: "2.27.1"
    version_set:
      resolver: "scripts/resolvers/timescaledb-ha.sh"
      retain_count: 3
YAML

    # Stub the resolver: output a small version array
    mkdir -p "${root}/scripts/resolvers"
    cat > "${root}/scripts/resolvers/timescaledb-ha.sh" <<'RESOLVER'
#!/usr/bin/env bash
printf '["2.25.0","2.26.0","2.27.1"]'
RESOLVER
    chmod +x "${root}/scripts/resolvers/timescaledb-ha.sh"

    # Stub ./make list (no containers, only extensions)
    cat > "${root}/make" <<'MAKE_EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "list" ]]; then
    printf ''
fi
MAKE_EOF
    chmod +x "${root}/make"

    # Probe: ceiling tag present
    local probe
    probe=$(_make_probe_stub \
        "ghcr.io/testowner/ext-timescaledb:pg17-2.27.1" "present" \
        "__default__" "absent")

    run --separate-stderr env \
        PROJECT_ROOT="$root" \
        _VDRIFT_CONTAINERS_OVERRIDE="" \
        _VDRIFT_GHCR_OWNER_OVERRIDE="testowner" \
        _VDRIFT_BUMP_EPOCH_OVERRIDE="1" \
        _VDRIFT_PROBE_OVERRIDE="$probe" \
        bash "$DRIFT_SCRIPT" --mode sweep --json

    [ "$status" -eq 0 ]

    printf '%s' "$output" | jq '.' >/dev/null

    local window_ok_count
    window_ok_count=$(printf '%s' "$output" | jq '[.[] | select(.status=="window_ok")] | length')
    [ "$window_ok_count" -eq 1 ]

    local row
    row=$(printf '%s' "$output" | jq '.[0]')
    [ "$(printf '%s' "$row" | jq -r '.name')" = "ext-timescaledb:pg17" ]
    [ "$(printf '%s' "$row" | jq -r '.status')" = "window_ok" ]
}

# ---------------------------------------------------------------------------
# Test 5: timescaledb resolver ceiling absent → drift, exit 1
# ---------------------------------------------------------------------------
@test "timescaledb resolver ceiling absent + old bump → drift + exit 1" {
    local root="${TEST_TEMP_DIR}/tsdb-project2"
    mkdir -p "${root}/postgres/extensions"

    cat > "${root}/postgres/extensions/config.yaml" <<'YAML'
pg_versions:
  - "17"
extensions:
  timescaledb:
    version: "2.27.1"
    version_set:
      resolver: "scripts/resolvers/timescaledb-ha.sh"
      retain_count: 3
YAML

    mkdir -p "${root}/scripts/resolvers"
    cat > "${root}/scripts/resolvers/timescaledb-ha.sh" <<'RESOLVER'
#!/usr/bin/env bash
printf '["2.25.0","2.26.0","2.27.1"]'
RESOLVER
    chmod +x "${root}/scripts/resolvers/timescaledb-ha.sh"

    cat > "${root}/make" <<'MAKE_EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "list" ]]; then
    printf ''
fi
MAKE_EOF
    chmod +x "${root}/make"

    # Ceiling tag absent, old bump
    local probe
    probe=$(_make_probe_stub "__default__" "absent")

    run --separate-stderr env \
        PROJECT_ROOT="$root" \
        _VDRIFT_CONTAINERS_OVERRIDE="" \
        _VDRIFT_GHCR_OWNER_OVERRIDE="testowner" \
        _VDRIFT_BUMP_EPOCH_OVERRIDE="1" \
        _VDRIFT_PROBE_OVERRIDE="$probe" \
        bash "$DRIFT_SCRIPT" --mode sweep --json

    [ "$status" -eq 1 ]

    printf '%s' "$output" | jq '.' >/dev/null

    local drift_count
    drift_count=$(printf '%s' "$output" | jq '[.[] | select(.status=="drift")] | length')
    [ "$drift_count" -eq 1 ]

    local row_name
    row_name=$(printf '%s' "$output" | jq -r '.[0].name')
    [ "$row_name" = "ext-timescaledb:pg17" ]
}

# ---------------------------------------------------------------------------
# Test 6: probe error → error row, exit 2
# MG4: if error propagation is removed, error becomes absent/in_sync → exit != 2
# ---------------------------------------------------------------------------
@test "probe-error: probe returns error → error row + exit 2" {
    local root
    root=$(_make_temp_project "foo" "9.9.9")

    local probe
    probe=$(_make_probe_stub "__default__" "error")

    run --separate-stderr env \
        PROJECT_ROOT="$root" \
        _VDRIFT_CONTAINERS_OVERRIDE="foo" \
        _VDRIFT_GHCR_OWNER_OVERRIDE="testowner" \
        _VDRIFT_BUMP_EPOCH_OVERRIDE="1" \
        _VDRIFT_PROBE_OVERRIDE="$probe" \
        bash "$DRIFT_SCRIPT" --mode sweep --json

    [ "$status" -eq 2 ]

    printf '%s' "$output" | jq '.' >/dev/null

    local error_count
    error_count=$(printf '%s' "$output" | jq '[.[] | select(.status=="error")] | length')
    [ "$error_count" -eq 1 ]

    local row_status
    row_status=$(printf '%s' "$output" | jq -r '.[0].status')
    [ "$row_status" = "error" ]
}

# ---------------------------------------------------------------------------
# Test 7: --json output shape — each row has required fields
# ---------------------------------------------------------------------------
@test "--json shape: each row has kind, name, declared, published, status" {
    local root
    root=$(_make_temp_project "foo" "9.9.9")

    local probe
    probe=$(_make_probe_stub "ghcr.io/testowner/foo:9.9.9" "present")

    run --separate-stderr env \
        PROJECT_ROOT="$root" \
        _VDRIFT_CONTAINERS_OVERRIDE="foo" \
        _VDRIFT_GHCR_OWNER_OVERRIDE="testowner" \
        _VDRIFT_BUMP_EPOCH_OVERRIDE="1" \
        _VDRIFT_PROBE_OVERRIDE="$probe" \
        bash "$DRIFT_SCRIPT" --mode sweep --json

    [ "$status" -eq 0 ]

    # Valid JSON array
    printf '%s' "$output" | jq -e 'type=="array"' >/dev/null

    # published may be empty string so check for key existence explicitly
    local missing_published_key
    missing_published_key=$(printf '%s' "$output" | jq '[.[] | select(has("published") | not)] | length')
    [ "$missing_published_key" -eq 0 ]

    # Each row must have all required string fields
    local missing_required_fields
    missing_required_fields=$(printf '%s' "$output" | jq '
        [.[] | select(
            (has("kind") | not) or
            (has("name") | not) or
            (has("declared") | not) or
            (has("published") | not) or
            (has("status") | not)
        )] | length')
    [ "$missing_required_fields" -eq 0 ]

    local row
    row=$(printf '%s' "$output" | jq '.[0]')
    printf '%s' "$row" | jq -e 'has("kind")' >/dev/null
    printf '%s' "$row" | jq -e 'has("name")' >/dev/null
    printf '%s' "$row" | jq -e 'has("declared")' >/dev/null
    printf '%s' "$row" | jq -e 'has("published")' >/dev/null
    printf '%s' "$row" | jq -e 'has("status")' >/dev/null
}

# ---------------------------------------------------------------------------
# Test 8: multi-container sweep — independent rows per container
# ---------------------------------------------------------------------------
@test "multi-container: two containers produce independent drift rows" {
    local root="${TEST_TEMP_DIR}/multi-project"
    mkdir -p "${root}/foo" "${root}/bar"

    cat > "${root}/foo/variants.yaml" <<'YAML'
build:
  version_retention: 3
versions:
  - tag: "1.0.0"
YAML

    cat > "${root}/bar/variants.yaml" <<'YAML'
build:
  version_retention: 3
versions:
  - tag: "2.0.0"
YAML

    cat > "${root}/make" <<'MAKE_EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "list" ]]; then
    printf 'foo\nbar\n'
fi
MAKE_EOF
    chmod +x "${root}/make"

    # foo:1.0.0 present, bar:2.0.0 absent (old bump → drift)
    local probe
    probe=$(_make_probe_stub \
        "ghcr.io/testowner/foo:1.0.0" "present" \
        "__default__" "absent")

    run --separate-stderr env \
        PROJECT_ROOT="$root" \
        _VDRIFT_CONTAINERS_OVERRIDE="foo
bar" \
        _VDRIFT_GHCR_OWNER_OVERRIDE="testowner" \
        _VDRIFT_BUMP_EPOCH_OVERRIDE="1" \
        _VDRIFT_PROBE_OVERRIDE="$probe" \
        bash "$DRIFT_SCRIPT" --mode sweep --json

    [ "$status" -eq 1 ]

    printf '%s' "$output" | jq '.' >/dev/null

    # Two rows total
    local total
    total=$(printf '%s' "$output" | jq 'length')
    [ "$total" -eq 2 ]

    # foo is in_sync
    local foo_status
    foo_status=$(printf '%s' "$output" | jq -r '.[] | select(.name=="foo") | .status')
    [ "$foo_status" = "in_sync" ]

    # bar is drift
    local bar_status
    bar_status=$(printf '%s' "$output" | jq -r '.[] | select(.name=="bar") | .status')
    [ "$bar_status" = "drift" ]
}

# ---------------------------------------------------------------------------
# Test 9: metachar safety — container name with no-op chars in ref is safe
# ---------------------------------------------------------------------------
@test "metachar-safe: container name with dots handled safely in probe ref" {
    local root
    root=$(_make_temp_project "my-container" "1.2.3")

    local probe
    probe=$(_make_probe_stub \
        "ghcr.io/testowner/my-container:1.2.3" "present")

    run --separate-stderr env \
        PROJECT_ROOT="$root" \
        _VDRIFT_CONTAINERS_OVERRIDE="my-container" \
        _VDRIFT_GHCR_OWNER_OVERRIDE="testowner" \
        _VDRIFT_BUMP_EPOCH_OVERRIDE="1" \
        _VDRIFT_PROBE_OVERRIDE="$probe" \
        bash "$DRIFT_SCRIPT" --mode sweep --json

    [ "$status" -eq 0 ]

    printf '%s' "$output" | jq '.' >/dev/null

    local row_name
    row_name=$(printf '%s' "$output" | jq -r '.[0].name')
    [ "$row_name" = "my-container" ]

    local row_status
    row_status=$(printf '%s' "$output" | jq -r '.[0].status')
    [ "$row_status" = "in_sync" ]
}

# ---------------------------------------------------------------------------
# Test 10: post-build mode — single container scoped correctly
# ---------------------------------------------------------------------------
@test "post-build mode: --container foo only checks foo, no other containers" {
    local root
    root=$(_make_temp_project "foo" "9.9.9")

    # Create a second container that should NOT be checked
    mkdir -p "${root}/bar"
    cat > "${root}/bar/variants.yaml" <<'YAML'
build:
  version_retention: 3
versions:
  - tag: "1.0.0"
YAML

    local probe
    probe=$(_make_probe_stub \
        "ghcr.io/testowner/foo:9.9.9" "present" \
        "__default__" "error")  # bar would return error if probed

    run --separate-stderr env \
        PROJECT_ROOT="$root" \
        _VDRIFT_CONTAINERS_OVERRIDE="foo" \
        _VDRIFT_GHCR_OWNER_OVERRIDE="testowner" \
        _VDRIFT_BUMP_EPOCH_OVERRIDE="1" \
        _VDRIFT_PROBE_OVERRIDE="$probe" \
        bash "$DRIFT_SCRIPT" --mode post-build --container foo --json

    [ "$status" -eq 0 ]

    printf '%s' "$output" | jq '.' >/dev/null

    # Only foo row present
    local total
    total=$(printf '%s' "$output" | jq 'length')
    [ "$total" -eq 1 ]

    local row_name
    row_name=$(printf '%s' "$output" | jq -r '.[0].name')
    [ "$row_name" = "foo" ]

    local row_status
    row_status=$(printf '%s' "$output" | jq -r '.[0].status')
    [ "$row_status" = "in_sync" ]
}

# ---------------------------------------------------------------------------
# Test 11: timescaledb resolver failure → window_empty row
# ---------------------------------------------------------------------------
@test "timescaledb resolver failure → window_empty row" {
    local root="${TEST_TEMP_DIR}/tsdb-empty"
    mkdir -p "${root}/postgres/extensions"

    cat > "${root}/postgres/extensions/config.yaml" <<'YAML'
pg_versions:
  - "17"
extensions:
  timescaledb:
    version: "2.27.1"
    version_set:
      resolver: "scripts/resolvers/timescaledb-ha.sh"
      retain_count: 3
YAML

    # Resolver that outputs empty (fails)
    mkdir -p "${root}/scripts/resolvers"
    cat > "${root}/scripts/resolvers/timescaledb-ha.sh" <<'RESOLVER'
#!/usr/bin/env bash
exit 1
RESOLVER
    chmod +x "${root}/scripts/resolvers/timescaledb-ha.sh"

    cat > "${root}/make" <<'MAKE_EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "list" ]]; then
    printf ''
fi
MAKE_EOF
    chmod +x "${root}/make"

    local probe
    probe=$(_make_probe_stub "__default__" "present")

    run --separate-stderr env \
        PROJECT_ROOT="$root" \
        _VDRIFT_CONTAINERS_OVERRIDE="" \
        _VDRIFT_GHCR_OWNER_OVERRIDE="testowner" \
        _VDRIFT_BUMP_EPOCH_OVERRIDE="1" \
        _VDRIFT_PROBE_OVERRIDE="$probe" \
        bash "$DRIFT_SCRIPT" --mode sweep --json

    # FIX 1: window_empty is fail-closed → exit 2 (not 0 or 1).
    [ "$status" -eq 2 ]

    printf '%s' "$output" | jq '.' >/dev/null

    local window_empty_count
    window_empty_count=$(printf '%s' "$output" | jq '[.[] | select(.status=="window_empty")] | length')
    [ "$window_empty_count" -eq 1 ]

    local row_name
    row_name=$(printf '%s' "$output" | jq -r '.[0].name')
    [ "$row_name" = "ext-timescaledb:pg17" ]
}

# ---------------------------------------------------------------------------
# D5 — Structural wiring tests
#
# These tests grep the workflow files for required patterns; they do NOT run
# the workflows.  They assert that the CI wiring described in ADR-012 is present
# and injection-safe.
# ---------------------------------------------------------------------------

# Workflow file paths (resolved relative to this test file's location)
REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
AUTO_BUILD_YAML="${REPO_ROOT}/.github/workflows/auto-build.yaml"
DRIFT_YAML="${REPO_ROOT}/.github/workflows/version-drift.yaml"

# ---------------------------------------------------------------------------
# Test D5-1: auto-build.yaml summary job invokes check-version-drift.sh in
#            post-build mode.
# ---------------------------------------------------------------------------
@test "D5-1: auto-build.yaml summary job invokes check-version-drift.sh --mode post-build" {
    [ -f "$AUTO_BUILD_YAML" ]
    grep -q 'check-version-drift.sh' "$AUTO_BUILD_YAML"
    grep -q -- '--mode post-build' "$AUTO_BUILD_YAML"
}

# ---------------------------------------------------------------------------
# Test D5-2: auto-build.yaml version-drift step is advisory (continue-on-error: true)
#            and does NOT hard-exit on drift (no bare "exit 1" in advisory block).
# ---------------------------------------------------------------------------
@test "D5-2: auto-build.yaml version-drift step is advisory (continue-on-error: true, no hard exit on drift)" {
    [ -f "$AUTO_BUILD_YAML" ]
    grep -q 'continue-on-error: true' "$AUTO_BUILD_YAML"
    # Extract the advisory step block and assert no unconditional "exit 1" for drift.
    # awk collects lines from the advisory step marker until the next step/job heading.
    local advisory_block
    advisory_block=$(awk '/Check version drift \(advisory\)/,/^      - name:|^  [a-z]/' "$AUTO_BUILD_YAML" || true)
    local hard_exit_on_drift
    hard_exit_on_drift=$(printf '%s' "$advisory_block" | grep -cE '^\s*exit 1\b' || true)
    [ "$hard_exit_on_drift" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test D5-3: version-drift.yaml exists with schedule + workflow_dispatch triggers.
# ---------------------------------------------------------------------------
@test "D5-3: version-drift.yaml exists with schedule and workflow_dispatch triggers" {
    [ -f "$DRIFT_YAML" ]
    grep -q 'schedule:' "$DRIFT_YAML"
    grep -q 'cron:' "$DRIFT_YAML"
    grep -q 'workflow_dispatch:' "$DRIFT_YAML"
}

# ---------------------------------------------------------------------------
# Test D5-4: version-drift.yaml mints the GitHub App token via
#            actions/create-github-app-token with BOT_APP_ID / BOT_APP_PRIVATE_KEY.
# ---------------------------------------------------------------------------
@test "D5-4: version-drift.yaml mints App token with BOT_APP_ID / BOT_APP_PRIVATE_KEY" {
    [ -f "$DRIFT_YAML" ]
    grep -q 'create-github-app-token' "$DRIFT_YAML"
    grep -q 'BOT_APP_ID' "$DRIFT_YAML"
    grep -q 'BOT_APP_PRIVATE_KEY' "$DRIFT_YAML"
}

# ---------------------------------------------------------------------------
# Test D5-5: version-drift.yaml invokes check-version-drift.sh --mode sweep.
# ---------------------------------------------------------------------------
@test "D5-5: version-drift.yaml runs check-version-drift.sh --mode sweep" {
    [ -f "$DRIFT_YAML" ]
    grep -q 'check-version-drift.sh' "$DRIFT_YAML"
    grep -q -- '--mode sweep' "$DRIFT_YAML"
}

# ---------------------------------------------------------------------------
# Test D5-6: auto-build.yaml advisory step uses $CONTAINER env var in the shell
#            body, not raw ${{ matrix.* }} template expressions (injection-safe).
# ---------------------------------------------------------------------------
@test "D5-6: auto-build.yaml advisory step uses \$CONTAINER env var, not \${{ matrix.* }} in shell body" {
    [ -f "$AUTO_BUILD_YAML" ]
    grep -q 'CONTAINER=' "$AUTO_BUILD_YAML"
    # Extract the advisory step block and assert no ${{ matrix.* }} in it.
    local advisory_block
    advisory_block=$(awk '/Check version drift \(advisory\)/,/^      - name:|^  [a-z]/' "$AUTO_BUILD_YAML" || true)
    local matrix_interp_count
    matrix_interp_count=$(printf '%s' "$advisory_block" | grep -cE '\$\{\{ *matrix\.' || true)
    [ "$matrix_interp_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test D5-7: version-drift.yaml sweep has no raw ${{ matrix.* }} in the run shell
#            body (sweep is non-matrix; no matrix context exists).
# ---------------------------------------------------------------------------
@test "D5-7: version-drift.yaml sweep run block has no raw \${{ matrix.* }} in shell body" {
    [ -f "$DRIFT_YAML" ]
    local matrix_interp_count
    matrix_interp_count=$(grep -cE '\$\{\{ *matrix\.' "$DRIFT_YAML" || true)
    [ "$matrix_interp_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# FIX 1 — structural: advisory step is gated to non-PR events.
# ---------------------------------------------------------------------------
@test "FIX1: advisory step has 'if: github.event_name != pull_request' guard" {
    [ -f "$AUTO_BUILD_YAML" ]
    # Extract the advisory step using a robust awk that starts at the step name
    # and stops at the NEXT step (line starting with 8+ spaces "- name:") or
    # next top-level job (line starting with 2 spaces + lowercase letter).
    # We start collecting AFTER the name line to avoid the name line itself
    # triggering the stop condition.
    local advisory_block
    advisory_block=$(awk '
        /Check version drift \(advisory\)/ { capture=1; next }
        capture && /^      - name:/ { capture=0 }
        capture && /^  [a-z][a-z]/ { capture=0 }
        capture { print }
    ' "$AUTO_BUILD_YAML" || true)
    # The guard must appear in the step block.
    local guard_count
    guard_count=$(printf '%s' "$advisory_block" \
        | grep -cE "if:.*github\.event_name[[:space:]]*!=.*pull_request" || true)
    [ "$guard_count" -ge 1 ]
}

# ---------------------------------------------------------------------------
# FIX 3 — structural: advisory step validates container name pattern AND/OR
#          routes through _escape_gha_command before emitting ::warning::.
# ---------------------------------------------------------------------------
@test "FIX3: advisory step validates container name with ^[a-z0-9_-]+\$ pattern" {
    [ -f "$AUTO_BUILD_YAML" ]
    local advisory_block
    advisory_block=$(awk '
        /Check version drift \(advisory\)/ { capture=1; next }
        capture && /^      - name:/ { capture=0 }
        capture && /^  [a-z][a-z]/ { capture=0 }
        capture { print }
    ' "$AUTO_BUILD_YAML" || true)
    # Must contain a regex guard for ^[a-z0-9_-]+$
    local guard_count
    guard_count=$(printf '%s' "$advisory_block" \
        | grep -cE '\^\[a-z0-9_-\]\+\$|\^\[a-z0-9_-\]\+' || true)
    [ "$guard_count" -ge 1 ]
}

@test "FIX3: check-version-drift.sh routes untrusted names through _escape_gha_command" {
    # Every ::warning:: / ::notice:: annotation line that includes a user-derived
    # value (name, declared, status from JSON data) must route through _escape_gha_command.
    # In _append_row, annotations use $safe_name, $safe_declared, $safe_status — never
    # the raw $name/$declared/$status.  Verify no annotation line uses the raw variables.
    local raw_name_in_annotation raw_declared_in_annotation
    # Check that ::warning:: / ::notice:: lines do NOT interpolate raw $name, $declared, $status
    # (i.e. no 'printf ...::warning::...$name' outside safe_ variables)
    raw_name_in_annotation=$(grep -cE \
        '::(warning|notice)::[^"]*\$name[^_]|::(warning|notice)::[^"]*\$declared[^_]|::(warning|notice)::[^"]*\$status[^_]' \
        "$DRIFT_SCRIPT" || true)
    [ "$raw_name_in_annotation" -eq 0 ]

    # The script must define _escape_gha_command
    local fn_defined
    fn_defined=$(grep -c '_escape_gha_command()' "$DRIFT_SCRIPT" || true)
    [ "$fn_defined" -ge 1 ]

    # _append_row must assign safe_ variables via _escape_gha_command
    local safe_assignments
    safe_assignments=$(grep -c 'safe_.*=.*_escape_gha_command' "$DRIFT_SCRIPT" || true)
    [ "$safe_assignments" -ge 3 ]

    # _escape_gha_command must be called for all ::error:: lines that include user data
    # (grep for ::error:: lines that use printf %s with a subshell call to _escape_gha_command)
    local escaped_errors
    escaped_errors=$(grep -cE '::error::.*_escape_gha_command' "$DRIFT_SCRIPT" || true)
    [ "$escaped_errors" -ge 1 ]
}

# ---------------------------------------------------------------------------
# FIX 4 — structural: summary job installs yq before the advisory step.
# ---------------------------------------------------------------------------
@test "FIX4: summary job installs yq before Check version drift step" {
    [ -f "$AUTO_BUILD_YAML" ]

    # The yq install step must appear BEFORE the advisory drift step in the file.
    # Use fixed-string grep (-F) to avoid regex metachar issues with parentheses.
    local yq_line drift_line
    yq_line=$(grep -nF 'Install yq (summary job)' "$AUTO_BUILD_YAML" | head -1 | cut -d: -f1)
    drift_line=$(grep -nF 'Check version drift (advisory)' "$AUTO_BUILD_YAML" | head -1 | cut -d: -f1)
    [ -n "$yq_line" ]
    [ -n "$drift_line" ]
    [ "$yq_line" -lt "$drift_line" ]

    # The yq install step must be in the summary job section (after 'summary:' heading).
    local summary_start
    summary_start=$(grep -nP '^  summary:$' "$AUTO_BUILD_YAML" | head -1 | cut -d: -f1)
    [ -n "$summary_start" ]
    [ "$yq_line" -gt "$summary_start" ]
}

# ---------------------------------------------------------------------------
# FIX 2 — real probe classification: skopeo-based stubs on PATH.
#
# We create fake `skopeo` executables on PATH and verify that the real-probe
# branch (no _VDRIFT_PROBE_OVERRIDE) correctly maps:
#   - skopeo exits 0              → present
#   - skopeo exits 1 + "manifest unknown" on stderr → absent
#   - skopeo exits 1 + other error on stderr        → error
# ---------------------------------------------------------------------------

# Helper: prepend a fake skopeo on PATH that the drift script will pick up.
_make_fake_skopeo() {
    local exit_code="$1"   # exit code skopeo should emit
    local stderr_msg="$2"  # message to print to stderr

    local bin_dir="${TEST_TEMP_DIR}/fake-bin-$$"
    mkdir -p "$bin_dir"

    cat > "${bin_dir}/skopeo" <<SKOPEO_EOF
#!/usr/bin/env bash
printf '%s\n' "${stderr_msg}" >&2
exit ${exit_code}
SKOPEO_EOF
    chmod +x "${bin_dir}/skopeo"
    printf '%s' "$bin_dir"
}

@test "FIX2-probe: skopeo exits 0 + OCI index manifest → real probe returns present → in_sync" {
    # Real skopeo inspect --raw always emits the manifest JSON on stdout when exit 0.
    # The stub must faithfully model that: emit a valid multi-arch index manifest.
    local root
    root=$(_make_temp_project "foo" "9.9.9")

    local fake_bin
    fake_bin=$(_make_skopeo_with_manifest \
        '{"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"platform":{"os":"linux","architecture":"amd64"}},{"platform":{"os":"linux","architecture":"arm64"}}]}')

    run --separate-stderr env \
        PATH="${fake_bin}:${PATH}" \
        PROJECT_ROOT="$root" \
        _VDRIFT_CONTAINERS_OVERRIDE="foo" \
        _VDRIFT_GHCR_OWNER_OVERRIDE="testowner" \
        _VDRIFT_BUMP_EPOCH_OVERRIDE="1" \
        bash "$DRIFT_SCRIPT" --mode sweep --json

    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq '.' >/dev/null
    local sync_count
    sync_count=$(printf '%s' "$output" | jq '[.[] | select(.status=="in_sync")] | length')
    [ "$sync_count" -eq 1 ]
}

@test "FIX2-probe: skopeo exits 1 + 'manifest unknown' stderr → real probe returns absent → drift" {
    local root
    root=$(_make_temp_project "foo" "9.9.9")

    # Old bump epoch → absent maps to drift
    local fake_bin
    fake_bin=$(_make_fake_skopeo 1 "Error: manifest unknown")

    run --separate-stderr env \
        PATH="${fake_bin}:${PATH}" \
        PROJECT_ROOT="$root" \
        _VDRIFT_CONTAINERS_OVERRIDE="foo" \
        _VDRIFT_GHCR_OWNER_OVERRIDE="testowner" \
        _VDRIFT_BUMP_EPOCH_OVERRIDE="1" \
        bash "$DRIFT_SCRIPT" --mode sweep --json

    [ "$status" -eq 1 ]
    printf '%s' "$output" | jq '.' >/dev/null
    local drift_count
    drift_count=$(printf '%s' "$output" | jq '[.[] | select(.status=="drift")] | length')
    [ "$drift_count" -eq 1 ]
}

@test "FIX2-probe: skopeo exits 1 + network-error stderr → real probe returns error → exit 2" {
    local root
    root=$(_make_temp_project "foo" "9.9.9")

    local fake_bin
    fake_bin=$(_make_fake_skopeo 1 "Error: connecting to registry: dial tcp: connection refused")

    run --separate-stderr env \
        PATH="${fake_bin}:${PATH}" \
        PROJECT_ROOT="$root" \
        _VDRIFT_CONTAINERS_OVERRIDE="foo" \
        _VDRIFT_GHCR_OWNER_OVERRIDE="testowner" \
        _VDRIFT_BUMP_EPOCH_OVERRIDE="1" \
        bash "$DRIFT_SCRIPT" --mode sweep --json

    [ "$status" -eq 2 ]
    printf '%s' "$output" | jq '.' >/dev/null
    local error_count
    error_count=$(printf '%s' "$output" | jq '[.[] | select(.status=="error")] | length')
    [ "$error_count" -eq 1 ]
}

@test "FIX2-structural: real probe distinguishes absent from error (no collapsed all-null path)" {
    # Confirm the script no longer collapses all-null JSON to 'absent'.
    # The old code had: 'All-null JSON → absent (ghcr_get_multi_arch_digests returns all-null on 404/absent)'
    # That comment / code path must be gone.
    local collapsed_path_count
    collapsed_path_count=$(grep -cF \
        'ghcr_get_multi_arch_digests returns all-null on 404' \
        "$DRIFT_SCRIPT" || true)
    [ "$collapsed_path_count" -eq 0 ]

    # The script must reference skopeo for the real probe path
    local skopeo_ref_count
    skopeo_ref_count=$(grep -c 'skopeo' "$DRIFT_SCRIPT" || true)
    [ "$skopeo_ref_count" -ge 1 ]
}

# ---------------------------------------------------------------------------
# MULTIARCH-PROBE tests — verify that _vdrift_probe_published classifies
# manifests by mediaType, not merely by skopeo exit code.
#
# Stub pattern: create a fake skopeo on PATH that outputs chosen JSON on stdout
# and exits 0 (to simulate skopeo inspect --raw returning a manifest body).
# The existing _make_fake_skopeo only prints to stderr; these helpers also
# emit a manifest body on stdout.
# ---------------------------------------------------------------------------

# Helper: create a PATH-stub skopeo that prints manifest JSON on stdout + exits 0.
_make_skopeo_with_manifest() {
    local manifest_json="$1"   # JSON string to print on stdout
    local bin_dir="${TEST_TEMP_DIR}/skopeo-stub-$$"
    mkdir -p "$bin_dir"
    # Write manifest to a temp file to avoid quoting hell in heredoc
    local manifest_file="${bin_dir}/manifest.json"
    printf '%s' "$manifest_json" > "$manifest_file"
    cat > "${bin_dir}/skopeo" <<SKOPEO_EOF
#!/usr/bin/env bash
cat "${manifest_file}"
exit 0
SKOPEO_EOF
    chmod +x "${bin_dir}/skopeo"
    printf '%s' "$bin_dir"
}

# ---------------------------------------------------------------------------
# MULTIARCH-PROBE-1: OCI image index → present → in_sync, exit 0
# ---------------------------------------------------------------------------
@test "MULTIARCH-PROBE-1: skopeo returns OCI index → present → in_sync + exit 0" {
    local root
    root=$(_make_temp_project "myapp" "3.1.0")

    local index_manifest
    index_manifest='{"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"platform":{"os":"linux","architecture":"amd64"}},{"platform":{"os":"linux","architecture":"arm64"}}]}'

    local fake_bin
    fake_bin=$(_make_skopeo_with_manifest "$index_manifest")

    run --separate-stderr env \
        PATH="${fake_bin}:${PATH}" \
        PROJECT_ROOT="$root" \
        _VDRIFT_CONTAINERS_OVERRIDE="myapp" \
        _VDRIFT_GHCR_OWNER_OVERRIDE="testowner" \
        _VDRIFT_BUMP_EPOCH_OVERRIDE="1" \
        bash "$DRIFT_SCRIPT" --mode sweep --json

    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq '.' >/dev/null

    local sync_count
    sync_count=$(printf '%s' "$output" | jq '[.[] | select(.status=="in_sync")] | length')
    [ "$sync_count" -eq 1 ]

    local drift_count
    drift_count=$(printf '%s' "$output" | jq '[.[] | select(.status=="drift")] | length')
    [ "$drift_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# MULTIARCH-PROBE-2: single-image manifest for Linux tag → absent → drift, exit 1
# ---------------------------------------------------------------------------
@test "MULTIARCH-PROBE-2: skopeo returns single-arch manifest for Linux tag → absent → drift + exit 1" {
    local root
    root=$(_make_temp_project "myapp" "3.1.0")

    local single_manifest
    single_manifest='{"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"mediaType":"application/vnd.oci.image.config.v1+json"},"layers":[]}'

    local fake_bin
    fake_bin=$(_make_skopeo_with_manifest "$single_manifest")

    # Old bump epoch → absent maps to drift
    run --separate-stderr env \
        PATH="${fake_bin}:${PATH}" \
        PROJECT_ROOT="$root" \
        _VDRIFT_CONTAINERS_OVERRIDE="myapp" \
        _VDRIFT_GHCR_OWNER_OVERRIDE="testowner" \
        _VDRIFT_BUMP_EPOCH_OVERRIDE="1" \
        bash "$DRIFT_SCRIPT" --mode sweep --json

    [ "$status" -eq 1 ]
    printf '%s' "$output" | jq '.' >/dev/null

    local drift_count
    drift_count=$(printf '%s' "$output" | jq '[.[] | select(.status=="drift")] | length')
    [ "$drift_count" -eq 1 ]

    local in_sync_count
    in_sync_count=$(printf '%s' "$output" | jq '[.[] | select(.status=="in_sync")] | length')
    [ "$in_sync_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# MULTIARCH-PROBE-3: single-image manifest for Windows tag → present → in_sync, exit 0
# ---------------------------------------------------------------------------
@test "MULTIARCH-PROBE-3: skopeo returns single-arch manifest for Windows tag → present → in_sync + exit 0" {
    # Windows images are legitimately single-arch; tag contains "windows"
    local root
    root=$(_make_temp_project "github-runner" "2.321.0-windows-ltsc2022")

    local single_manifest
    single_manifest='{"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"mediaType":"application/vnd.oci.image.config.v1+json"},"layers":[]}'

    local fake_bin
    fake_bin=$(_make_skopeo_with_manifest "$single_manifest")

    run --separate-stderr env \
        PATH="${fake_bin}:${PATH}" \
        PROJECT_ROOT="$root" \
        _VDRIFT_CONTAINERS_OVERRIDE="github-runner" \
        _VDRIFT_GHCR_OWNER_OVERRIDE="testowner" \
        _VDRIFT_BUMP_EPOCH_OVERRIDE="1" \
        bash "$DRIFT_SCRIPT" --mode sweep --json

    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq '.' >/dev/null

    local sync_count
    sync_count=$(printf '%s' "$output" | jq '[.[] | select(.status=="in_sync")] | length')
    [ "$sync_count" -eq 1 ]

    local drift_count
    drift_count=$(printf '%s' "$output" | jq '[.[] | select(.status=="drift")] | length')
    [ "$drift_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# MULTIARCH-PROBE-4: skopeo exits 0 but non-JSON output → error → exit 2
# ---------------------------------------------------------------------------
@test "MULTIARCH-PROBE-4: skopeo exits 0 with non-JSON output → error → exit 2" {
    local root
    root=$(_make_temp_project "myapp" "3.1.0")

    # Create a fake skopeo that outputs garbage (non-JSON) and exits 0
    local bin_dir="${TEST_TEMP_DIR}/skopeo-garbage-$$"
    mkdir -p "$bin_dir"
    cat > "${bin_dir}/skopeo" <<'SKOPEO_EOF'
#!/usr/bin/env bash
printf 'this is not json at all\n'
exit 0
SKOPEO_EOF
    chmod +x "${bin_dir}/skopeo"

    run --separate-stderr env \
        PATH="${bin_dir}:${PATH}" \
        PROJECT_ROOT="$root" \
        _VDRIFT_CONTAINERS_OVERRIDE="myapp" \
        _VDRIFT_GHCR_OWNER_OVERRIDE="testowner" \
        _VDRIFT_BUMP_EPOCH_OVERRIDE="1" \
        bash "$DRIFT_SCRIPT" --mode sweep --json

    [ "$status" -eq 2 ]
    printf '%s' "$output" | jq '.' >/dev/null

    local error_count
    error_count=$(printf '%s' "$output" | jq '[.[] | select(.status=="error")] | length')
    [ "$error_count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# MULTIARCH-PROBE-5: existing absent (manifest unknown stderr) stub still works
# ---------------------------------------------------------------------------
@test "MULTIARCH-PROBE-5: skopeo exits 1 + 'manifest unknown' stderr → absent → drift (unchanged)" {
    local root
    root=$(_make_temp_project "myapp" "3.1.0")

    local fake_bin
    fake_bin=$(_make_fake_skopeo 1 "Error: manifest unknown")

    run --separate-stderr env \
        PATH="${fake_bin}:${PATH}" \
        PROJECT_ROOT="$root" \
        _VDRIFT_CONTAINERS_OVERRIDE="myapp" \
        _VDRIFT_GHCR_OWNER_OVERRIDE="testowner" \
        _VDRIFT_BUMP_EPOCH_OVERRIDE="1" \
        bash "$DRIFT_SCRIPT" --mode sweep --json

    [ "$status" -eq 1 ]
    printf '%s' "$output" | jq '.' >/dev/null

    local drift_count
    drift_count=$(printf '%s' "$output" | jq '[.[] | select(.status=="drift")] | length')
    [ "$drift_count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# MULTIARCH-PROBE-6: existing network error stub still works
# ---------------------------------------------------------------------------
@test "MULTIARCH-PROBE-6: skopeo exits 1 + network error stderr → error → exit 2 (unchanged)" {
    local root
    root=$(_make_temp_project "myapp" "3.1.0")

    local fake_bin
    fake_bin=$(_make_fake_skopeo 1 "Error: connecting to registry: dial tcp: connection refused")

    run --separate-stderr env \
        PATH="${fake_bin}:${PATH}" \
        PROJECT_ROOT="$root" \
        _VDRIFT_CONTAINERS_OVERRIDE="myapp" \
        _VDRIFT_GHCR_OWNER_OVERRIDE="testowner" \
        _VDRIFT_BUMP_EPOCH_OVERRIDE="1" \
        bash "$DRIFT_SCRIPT" --mode sweep --json

    [ "$status" -eq 2 ]
    printf '%s' "$output" | jq '.' >/dev/null

    local error_count
    error_count=$(printf '%s' "$output" | jq '[.[] | select(.status=="error")] | length')
    [ "$error_count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# FIX 1 — window_empty is fail-closed: resolver returns [] → exit 2
# ---------------------------------------------------------------------------
@test "FIX1: resolver returns [] → window_empty → fail-closed exit 2 (not silent exit 0)" {
    local root="${TEST_TEMP_DIR}/tsdb-empty-array"
    mkdir -p "${root}/postgres/extensions"

    cat > "${root}/postgres/extensions/config.yaml" <<'YAML'
pg_versions:
  - "17"
extensions:
  timescaledb:
    version: "2.27.1"
    version_set:
      resolver: "scripts/resolvers/timescaledb-ha.sh"
      retain_count: 3
YAML

    # Resolver that returns the empty JSON array [] (not a bash non-zero exit)
    mkdir -p "${root}/scripts/resolvers"
    cat > "${root}/scripts/resolvers/timescaledb-ha.sh" <<'RESOLVER'
#!/usr/bin/env bash
printf '[]'
RESOLVER
    chmod +x "${root}/scripts/resolvers/timescaledb-ha.sh"

    cat > "${root}/make" <<'MAKE_EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "list" ]]; then
    printf ''
fi
MAKE_EOF
    chmod +x "${root}/make"

    local probe
    probe=$(_make_probe_stub "__default__" "present")

    run --separate-stderr env \
        PROJECT_ROOT="$root" \
        _VDRIFT_CONTAINERS_OVERRIDE="" \
        _VDRIFT_GHCR_OWNER_OVERRIDE="testowner" \
        _VDRIFT_BUMP_EPOCH_OVERRIDE="1" \
        _VDRIFT_PROBE_OVERRIDE="$probe" \
        bash "$DRIFT_SCRIPT" --mode sweep --json

    # FIX 1: empty array from resolver → window_empty → _HAS_ERROR → exit 2.
    # NOT exit 0 (silent false-clean) and NOT exit 1 (drift).
    [ "$status" -eq 2 ]

    printf '%s' "$output" | jq '.' >/dev/null

    local window_empty_count
    window_empty_count=$(printf '%s' "$output" | jq '[.[] | select(.status=="window_empty")] | length')
    [ "$window_empty_count" -eq 1 ]
}

@test "FIX1: window_empty accumulator sets _HAS_ERROR (not _HAS_DRIFT)" {
    # Confirm that window_empty maps to exit 2, not exit 1.
    # This catches a regression where someone makes it set _HAS_DRIFT instead.
    # Use a failing resolver so no probe call is needed.
    local root="${TEST_TEMP_DIR}/tsdb-nofile"
    mkdir -p "${root}/postgres/extensions"

    cat > "${root}/postgres/extensions/config.yaml" <<'YAML'
pg_versions:
  - "17"
extensions:
  timescaledb:
    version: "2.27.1"
    version_set:
      resolver: "scripts/resolvers/missing-resolver.sh"
      retain_count: 3
YAML
    # Resolver script does NOT exist → window_json will be empty

    cat > "${root}/make" <<'MAKE_EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "list" ]]; then
    printf ''
fi
MAKE_EOF
    chmod +x "${root}/make"

    local probe
    probe=$(_make_probe_stub "__default__" "present")

    run --separate-stderr env \
        PROJECT_ROOT="$root" \
        _VDRIFT_CONTAINERS_OVERRIDE="" \
        _VDRIFT_GHCR_OWNER_OVERRIDE="testowner" \
        _VDRIFT_BUMP_EPOCH_OVERRIDE="1" \
        _VDRIFT_PROBE_OVERRIDE="$probe" \
        bash "$DRIFT_SCRIPT" --mode sweep --json

    # Missing resolver file → empty window_json → window_empty → exit 2
    [ "$status" -eq 2 ]

    local window_empty_count
    window_empty_count=$(printf '%s' "$output" | jq '[.[] | select(.status=="window_empty")] | length')
    [ "$window_empty_count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# FIX 2 — structural: skopeo is installed in both workflow files before the
# drift-check step.
# ---------------------------------------------------------------------------
@test "FIX2-workflow: version-drift.yaml installs skopeo before Run version-drift sweep" {
    [ -f "$DRIFT_YAML" ]

    local skopeo_line sweep_line
    skopeo_line=$(grep -n 'Install skopeo' "$DRIFT_YAML" | head -1 | cut -d: -f1)
    sweep_line=$(grep -n 'Run version-drift sweep' "$DRIFT_YAML" | head -1 | cut -d: -f1)

    [ -n "$skopeo_line" ]
    [ -n "$sweep_line" ]
    [ "$skopeo_line" -lt "$sweep_line" ]

    # The install step must call apt-get install skopeo (mirrors build jobs)
    grep -q 'apt-get install.*skopeo\|apt-get.*install.*skopeo' "$DRIFT_YAML"
}

@test "FIX2-workflow: auto-build.yaml summary job installs skopeo before Check version drift" {
    [ -f "$AUTO_BUILD_YAML" ]

    local skopeo_line drift_line
    skopeo_line=$(grep -n 'Install skopeo (summary job)' "$AUTO_BUILD_YAML" | head -1 | cut -d: -f1)
    drift_line=$(grep -n 'Check version drift (advisory)' "$AUTO_BUILD_YAML" | head -1 | cut -d: -f1)

    [ -n "$skopeo_line" ]
    [ -n "$drift_line" ]
    [ "$skopeo_line" -lt "$drift_line" ]
}

@test "FIX2-workflow: auto-build.yaml summary job has GHCR login before skopeo install" {
    [ -f "$AUTO_BUILD_YAML" ]

    local login_line skopeo_line
    login_line=$(grep -n 'Log in to GHCR (summary job)' "$AUTO_BUILD_YAML" | head -1 | cut -d: -f1)
    skopeo_line=$(grep -n 'Install skopeo (summary job)' "$AUTO_BUILD_YAML" | head -1 | cut -d: -f1)

    [ -n "$login_line" ]
    [ -n "$skopeo_line" ]
    [ "$login_line" -lt "$skopeo_line" ]
}

# ---------------------------------------------------------------------------
# FIX 3 — structural: version-drift.yaml sweep does NOT suppress stderr.
# ---------------------------------------------------------------------------
@test "FIX3-workflow: version-drift.yaml sweep does not pipe drift-check through 2>/dev/null" {
    [ -f "$DRIFT_YAML" ]

    # The line that runs check-version-drift.sh in sweep mode must not redirect
    # stderr to /dev/null.  Extract lines containing check-version-drift.sh and
    # assert none of them end with 2>/dev/null on the same continuation.
    local suppressed_count
    suppressed_count=$(grep 'check-version-drift\.sh' "$DRIFT_YAML" \
        | grep -c '2>/dev/null' || true)
    [ "$suppressed_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# FIX 4 — open_version_drift_issue validates container name before labelling.
# ---------------------------------------------------------------------------
@test "FIX4: open_version_drift_issue with invalid container name does not reach dep: label" {
    # Source the script in a controlled env (stub all gh calls and env guards)
    # then call open_version_drift_issue with a bad container name.
    # Assert that gh is never called with a dep: label containing the bad name.

    local gh_log="${TEST_TEMP_DIR}/gh-calls.log"
    local fake_bin="${TEST_TEMP_DIR}/fake-gh-bin-$$"
    mkdir -p "$fake_bin"

    # Fake gh that logs its arguments and succeeds
    cat > "${fake_bin}/gh" <<GH_EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${gh_log}"
# Simulate issue list returning empty (no existing issues)
if [[ "\${1:-}" == "issue" && "\${2:-}" == "list" ]]; then
    printf '[]'
fi
# Simulate label create succeeding
if [[ "\${1:-}" == "label" ]]; then
    exit 0
fi
# Simulate issue create returning a number
if [[ "\${1:-}" == "issue" && "\${2:-}" == "create" ]]; then
    printf 'https://github.com/test/repo/issues/42\n'
fi
exit 0
GH_EOF
    chmod +x "${fake_bin}/gh"

    # Build a minimal drift_json with one drift row
    local drift_json='[{"kind":"container","name":"foo","declared":"1.0.0","published":"","status":"drift"}]'

    # Source the script with required env vars stubbed; use the fake gh
    run --separate-stderr env \
        PATH="${fake_bin}:${PATH}" \
        GH_TOKEN="fake-token" \
        GITHUB_REPOSITORY="test/repo" \
        GITHUB_RUN_ID="12345" \
        GITHUB_SERVER_URL="https://github.com" \
        GITHUB_SHA="abcdef01" \
        GITHUB_EVENT_NAME="push" \
        GITHUB_REF_NAME="master" \
        COMMIT_SUBJECT="test" \
        DRY_RUN="false" \
        bash -c "
            source '${REPO_ROOT}/helpers/logging.sh'
            source '${REPO_ROOT}/helpers/retry.sh'
            source '${REPO_ROOT}/scripts/open-dep-failure-issue.sh'
            open_version_drift_issue '${drift_json}' 'invalid name with spaces'
        "

    # Must succeed (validation emits warning, falls back, does not abort)
    [ "$status" -eq 0 ]

    # gh must NOT have been called with a dep: label containing the bad name
    if [ -f "$gh_log" ]; then
        local bad_label_count
        bad_label_count=$(grep -c 'dep:invalid name\|dep:invalid' "$gh_log" || true)
        [ "$bad_label_count" -eq 0 ]
    fi
}

@test "FIX4: open_version_drift_issue with valid container name uses dep: label" {
    local gh_log="${TEST_TEMP_DIR}/gh-calls-valid.log"
    local fake_bin="${TEST_TEMP_DIR}/fake-gh-bin-valid-$$"
    mkdir -p "$fake_bin"

    cat > "${fake_bin}/gh" <<GH_EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${gh_log}"
if [[ "\${1:-}" == "issue" && "\${2:-}" == "list" ]]; then
    printf '[]'
fi
if [[ "\${1:-}" == "label" ]]; then
    exit 0
fi
if [[ "\${1:-}" == "issue" && "\${2:-}" == "create" ]]; then
    printf 'https://github.com/test/repo/issues/43\n'
fi
exit 0
GH_EOF
    chmod +x "${fake_bin}/gh"

    local drift_json='[{"kind":"container","name":"myapp","declared":"2.0.0","published":"","status":"drift"}]'

    run --separate-stderr env \
        PATH="${fake_bin}:${PATH}" \
        GH_TOKEN="fake-token" \
        GITHUB_REPOSITORY="test/repo" \
        GITHUB_RUN_ID="12345" \
        GITHUB_SERVER_URL="https://github.com" \
        GITHUB_SHA="abcdef01" \
        GITHUB_EVENT_NAME="push" \
        GITHUB_REF_NAME="master" \
        COMMIT_SUBJECT="test" \
        DRY_RUN="false" \
        bash -c "
            source '${REPO_ROOT}/helpers/logging.sh'
            source '${REPO_ROOT}/helpers/retry.sh'
            source '${REPO_ROOT}/scripts/open-dep-failure-issue.sh'
            open_version_drift_issue '${drift_json}' 'myapp'
        "

    [ "$status" -eq 0 ]

    # gh must have been called with dep:myapp label
    if [ -f "$gh_log" ]; then
        local good_label_count
        good_label_count=$(grep -c 'dep:myapp' "$gh_log" || true)
        [ "$good_label_count" -ge 1 ]
    fi
}

# ---------------------------------------------------------------------------
# GHA-INJ-1 — FIX 1 structural (injection-safe error/warning branches)
#
# Assert that the REJECTED-value branches do NOT interpolate the raw untrusted
# value into a ::error:: / ::warning:: annotation.
# ---------------------------------------------------------------------------

@test "GHA-INJ-1a: version-drift.yaml invalid-GRACE_HOURS branch does not interpolate raw GRACE_HOURS value" {
    [ -f "$DRIFT_YAML" ]

    # Extract the GRACE_HOURS validation block — lines between the regex guard
    # and the matching "exit 2" that follows it.
    local grace_block
    grace_block=$(awk '
        /GRACE_HOURS.*\^.*\[0-9\]/ { capture=1 }
        capture && /exit 2/ { print; capture=0; next }
        capture { print }
    ' "$DRIFT_YAML" || true)

    # The branch must contain a ::error:: annotation
    local error_line_count
    error_line_count=$(printf '%s' "$grace_block" | grep -cE '::error::' || true)
    [ "$error_line_count" -ge 1 ]

    # The ::error:: annotation must NOT contain ${GRACE_HOURS} or $GRACE_HOURS
    local raw_value_count
    raw_value_count=$(printf '%s' "$grace_block" | grep -cE '::error::.*\$\{?GRACE_HOURS\}?' || true)
    [ "$raw_value_count" -eq 0 ]
}

@test "GHA-INJ-1b: auto-build.yaml invalid-container-name branch does not interpolate raw cname value" {
    [ -f "$AUTO_BUILD_YAML" ]

    # Extract the invalid-name branch — lines between the name-validation guard
    # and the "continue" that follows.
    local invalid_block
    invalid_block=$(awk '
        /\^\[a-z0-9_-\]/ { capture=1 }
        capture && /^\s*continue/ { print; capture=0; next }
        capture { print }
    ' "$AUTO_BUILD_YAML" || true)

    # The branch must contain a ::warning:: annotation
    local warn_line_count
    warn_line_count=$(printf '%s' "$invalid_block" | grep -cE '::warning::' || true)
    [ "$warn_line_count" -ge 1 ]

    # The ::warning:: annotation must NOT contain $cname or ${cname}
    local raw_value_count
    raw_value_count=$(printf '%s' "$invalid_block" | grep -cE '::warning::.*\$\{?cname\}?' || true)
    [ "$raw_value_count" -eq 0 ]
}

@test "GHA-INJ-1c: open_version_drift_issue validation-failure branch does not interpolate raw container value" {
    local script="${REPO_ROOT}/scripts/open-dep-failure-issue.sh"
    [ -f "$script" ]

    # Extract lines around the validation-failure warning inside open_version_drift_issue.
    # The pattern: after the ^[a-z0-9_-]+$ regex test fails, a ::warning:: is emitted.
    local validation_block
    validation_block=$(awk '
        /\^\[a-z0-9_-\]\+\$/ { capture=1 }
        capture && /fi/ { print; capture=0; next }
        capture { print }
    ' "$script" || true)

    # The block must contain a ::warning:: annotation
    local warn_line_count
    warn_line_count=$(printf '%s' "$validation_block" | grep -cE '::warning::' || true)
    [ "$warn_line_count" -ge 1 ]

    # The ::warning:: annotation must NOT interpolate the raw container value
    # (i.e., must not contain $container or ${container} after ::warning::)
    local raw_value_count
    raw_value_count=$(printf '%s' "$validation_block" | grep -cE '::warning::.*\$\{?container\}?' || true)
    [ "$raw_value_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# GHA-INJ-2 — FIX 2 structural (subshell isolation of set -euo pipefail)
#
# Assert that both workflow steps source open-dep-failure-issue.sh and call
# open_version_drift_issue inside a subshell ( ... ), so the script's top-level
# "set -euo pipefail" does not leak into the step's outer shell.
# ---------------------------------------------------------------------------

@test "GHA-INJ-2a: version-drift.yaml sweeps open_version_drift_issue inside a subshell" {
    [ -f "$DRIFT_YAML" ]

    # The subshell pattern must appear: a line starting with "( source" or "(" that
    # is followed (within a few lines) by "source scripts/open-dep-failure-issue.sh"
    # and "open_version_drift_issue".
    # We verify this by checking that open_version_drift_issue appears on a line
    # that is inside a ( ... ) block — specifically by looking for the subshell
    # opening "(" and the function call in the same awk block.
    local subshell_block
    subshell_block=$(awk '
        /^\s*\(/ && !seen { seen=1; capture=1 }
        capture { print }
        capture && /open_version_drift_issue/ { found=1 }
        capture && /^\s*\)/ { capture=0 }
    ' "$DRIFT_YAML" || true)

    # Must find open_version_drift_issue inside a subshell block
    local fn_in_subshell
    fn_in_subshell=$(printf '%s' "$subshell_block" | grep -c 'open_version_drift_issue' || true)
    [ "$fn_in_subshell" -ge 1 ]

    # The subshell block must also source open-dep-failure-issue.sh
    local source_in_subshell
    source_in_subshell=$(printf '%s' "$subshell_block" | grep -c 'open-dep-failure-issue.sh' || true)
    [ "$source_in_subshell" -ge 1 ]
}

@test "GHA-INJ-2b: auto-build.yaml advisory step calls open_version_drift_issue inside a subshell" {
    [ -f "$AUTO_BUILD_YAML" ]

    # Same structural check: find the subshell block containing open_version_drift_issue
    # and verify open-dep-failure-issue.sh is sourced within it.
    local subshell_block
    subshell_block=$(awk '
        /^\s*\(/ && !seen { seen=1; capture=1 }
        capture { print }
        capture && /open_version_drift_issue/ { found=1 }
        capture && /^\s*\)/ { capture=0 }
    ' "$AUTO_BUILD_YAML" || true)

    local fn_in_subshell
    fn_in_subshell=$(printf '%s' "$subshell_block" | grep -c 'open_version_drift_issue' || true)
    [ "$fn_in_subshell" -ge 1 ]

    local source_in_subshell
    source_in_subshell=$(printf '%s' "$subshell_block" | grep -c 'open-dep-failure-issue.sh' || true)
    [ "$source_in_subshell" -ge 1 ]
}

# ---------------------------------------------------------------------------
# NEW-FIX1 — structural: advisory install steps are continue-on-error: true
# ---------------------------------------------------------------------------

@test "NEW-FIX1: Install skopeo (summary job) step has continue-on-error: true" {
    [ -f "$AUTO_BUILD_YAML" ]

    # Extract the block for the "Install skopeo (summary job)" step.
    # Collect lines from the step name until the next step or job heading.
    local skopeo_block
    skopeo_block=$(awk '
        /Install skopeo \(summary job\)/ { capture=1; next }
        capture && /^      - name:/ { capture=0 }
        capture && /^  [a-z][a-z]/ { capture=0 }
        capture { print }
    ' "$AUTO_BUILD_YAML" || true)

    # The block must contain continue-on-error: true
    local coe_count
    coe_count=$(printf '%s' "$skopeo_block" | grep -cF 'continue-on-error: true' || true)
    [ "$coe_count" -ge 1 ]
}

@test "NEW-FIX1: Install yq (summary job) step has continue-on-error: true" {
    [ -f "$AUTO_BUILD_YAML" ]

    local yq_block
    yq_block=$(awk '
        /Install yq \(summary job\)/ { capture=1; next }
        capture && /^      - name:/ { capture=0 }
        capture && /^  [a-z][a-z]/ { capture=0 }
        capture { print }
    ' "$AUTO_BUILD_YAML" || true)

    local coe_count
    coe_count=$(printf '%s' "$yq_block" | grep -cF 'continue-on-error: true' || true)
    [ "$coe_count" -ge 1 ]
}

# ---------------------------------------------------------------------------
# NEW-FIX2 — structural: sweep vs per-container label spaces are disjoint
# ---------------------------------------------------------------------------

@test "NEW-FIX2: sweep dedup uses version-drift-sweep label (structural)" {
    local script="${REPO_ROOT}/scripts/open-dep-failure-issue.sh"
    [ -f "$script" ]

    # The sweep label must appear in the script
    local sweep_label_count
    sweep_label_count=$(grep -c 'version-drift-sweep' "$script" || true)
    [ "$sweep_label_count" -ge 1 ]
}

@test "NEW-FIX2: per-container path uses dep: label and sweep path uses version-drift-sweep (mutually exclusive)" {
    local script="${REPO_ROOT}/scripts/open-dep-failure-issue.sh"
    [ -f "$script" ]

    # Per-container path sets dep:<container> in dedup_labels
    local per_container_label_count
    per_container_label_count=$(grep -cF 'dep:${validated_container}' "$script" || true)
    [ "$per_container_label_count" -ge 1 ]

    # Sweep path sets version-drift-sweep in dedup_labels
    local sweep_label_count
    sweep_label_count=$(grep -cF 'version-drift-sweep' "$script" || true)
    [ "$sweep_label_count" -ge 1 ]

    # The script must NOT have a bare "version-drift,automation" dedup_labels
    # assignment that lacks either dep: or version-drift-sweep
    # (i.e., the old sweep label set "version-drift,automation" must be gone)
    local bare_dedup_count
    bare_dedup_count=$(grep -cE 'dedup_labels="version-drift,automation"$' "$script" || true)
    [ "$bare_dedup_count" -eq 0 ]
}

@test "NEW-FIX2: sweep gh search uses version-drift-sweep label, not per-container dep: label" {
    # Stub gh: return a fake per-container issue number ONLY when query includes dep:
    # (simulates "a per-container issue exists"); return empty when query includes
    # version-drift-sweep (simulates "no existing sweep issue").
    # Assert sweep path creates a new issue rather than commenting on the per-container one.

    local gh_log="${TEST_TEMP_DIR}/gh-sweep-collision-test.log"
    local fake_bin="${TEST_TEMP_DIR}/fake-gh-sweep-$$"
    mkdir -p "$fake_bin"

    # Fake gh:
    #   - issue list with version-drift-sweep → return [] (no existing sweep issue)
    #   - issue list with dep: label → return issue #99 (per-container issue)
    #   - issue create → return URL with new issue #100
    #   - label create / issue comment → succeed silently
    cat > "${fake_bin}/gh" <<GH_EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${gh_log}"
case "\${1:-} \${2:-}" in
    "issue list")
        for a in "\$@"; do
            if [[ "\$a" == "version-drift-sweep" ]]; then
                printf '[]'
                exit 0
            fi
        done
        for a in "\$@"; do
            if [[ "\$a" == dep:* ]]; then
                printf '[{"number":99,"title":"Per-container drift issue"}]'
                exit 0
            fi
        done
        printf '[]'
        ;;
    "issue create")
        printf 'https://github.com/test/repo/issues/100\n'
        ;;
    "issue comment")
        printf 'commented\n' >&2
        ;;
    "label create")
        ;;
esac
exit 0
GH_EOF
    chmod +x "${fake_bin}/gh"

    local drift_json='[{"kind":"container","name":"foo","declared":"1.0.0","published":"","status":"drift"}]'

    # Call open_version_drift_issue with EMPTY container → sweep path
    run --separate-stderr env \
        GH_LOG="${gh_log}" \
        PATH="${fake_bin}:${PATH}" \
        GH_TOKEN="fake-token" \
        GITHUB_REPOSITORY="test/repo" \
        GITHUB_RUN_ID="12345" \
        GITHUB_SERVER_URL="https://github.com" \
        GITHUB_SHA="abcdef01" \
        GITHUB_EVENT_NAME="push" \
        GITHUB_REF_NAME="master" \
        COMMIT_SUBJECT="test" \
        DRY_RUN="false" \
        bash -c "
            source '${REPO_ROOT}/helpers/logging.sh'
            source '${REPO_ROOT}/helpers/retry.sh'
            source '${REPO_ROOT}/scripts/open-dep-failure-issue.sh'
            open_version_drift_issue '${drift_json}' ''
        "

    [ "$status" -eq 0 ]

    # The output must say "created #100" — NOT "commented #99"
    # (sweep must not have deduped onto the per-container issue)
    [[ "$output" == *"created #100"* ]]

    # Confirm the sweep did NOT comment on issue 99
    if [ -f "${gh_log}" ]; then
        local comment_on_99
        comment_on_99=$(grep -c 'issue comment.*99\|issue comment .* 99' "${gh_log}" || true)
        [ "$comment_on_99" -eq 0 ]
    fi
}

# ---------------------------------------------------------------------------
# FAILOPEN-FIX1 — open_version_drift_issue CREATE failure returns non-zero
# and does not print "created #".
# ---------------------------------------------------------------------------

@test "FAILOPEN-FIX1: open_version_drift_issue CREATE failure returns non-zero, no 'created #' output" {
    local fake_bin="${TEST_TEMP_DIR}/fake-gh-create-fail-$$"
    mkdir -p "$fake_bin"

    # gh stub: issue list returns [] (no existing issue), issue create fails.
    cat > "${fake_bin}/gh" <<'GH_EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
    "issue list")
        printf '[]'
        ;;
    "issue create")
        printf 'Error: could not create issue\n' >&2
        exit 1
        ;;
    "label create")
        exit 0
        ;;
esac
exit 0
GH_EOF
    chmod +x "${fake_bin}/gh"

    local drift_json='[{"kind":"container","name":"foo","declared":"1.0.0","published":"","status":"drift"}]'

    run --separate-stderr env \
        PATH="${fake_bin}:${PATH}" \
        GH_TOKEN="fake-token" \
        GITHUB_REPOSITORY="test/repo" \
        GITHUB_RUN_ID="12345" \
        GITHUB_SERVER_URL="https://github.com" \
        GITHUB_SHA="abcdef01" \
        GITHUB_EVENT_NAME="push" \
        GITHUB_REF_NAME="master" \
        COMMIT_SUBJECT="test" \
        DRY_RUN="false" \
        bash -c "
            source '${REPO_ROOT}/helpers/logging.sh'
            source '${REPO_ROOT}/helpers/retry.sh'
            source '${REPO_ROOT}/scripts/open-dep-failure-issue.sh'
            open_version_drift_issue '${drift_json}' 'foo'
        "

    # Must return non-zero on gh issue create failure
    [ "$status" -ne 0 ]

    # Must NOT print "created #" (no false-success output)
    [[ "$output" != *"created #"* ]]
}

# ---------------------------------------------------------------------------
# FAILOPEN-FIX1 — open_version_drift_issue COMMENT failure returns non-zero
# and does not print "commented #".
# ---------------------------------------------------------------------------

@test "FAILOPEN-FIX1: open_version_drift_issue COMMENT failure returns non-zero, no 'commented #' output" {
    local fake_bin="${TEST_TEMP_DIR}/fake-gh-comment-fail-$$"
    mkdir -p "$fake_bin"

    # gh stub: issue list returns existing issue #55, issue comment fails.
    cat > "${fake_bin}/gh" <<'GH_EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
    "issue list")
        printf '[{"number":55,"title":"Version drift detected"}]'
        ;;
    "issue comment")
        printf 'Error: could not post comment\n' >&2
        exit 1
        ;;
    "label create")
        exit 0
        ;;
esac
exit 0
GH_EOF
    chmod +x "${fake_bin}/gh"

    local drift_json='[{"kind":"container","name":"foo","declared":"1.0.0","published":"","status":"drift"}]'

    run --separate-stderr env \
        PATH="${fake_bin}:${PATH}" \
        GH_TOKEN="fake-token" \
        GITHUB_REPOSITORY="test/repo" \
        GITHUB_RUN_ID="12345" \
        GITHUB_SERVER_URL="https://github.com" \
        GITHUB_SHA="abcdef01" \
        GITHUB_EVENT_NAME="push" \
        GITHUB_REF_NAME="master" \
        COMMIT_SUBJECT="test" \
        DRY_RUN="false" \
        bash -c "
            source '${REPO_ROOT}/helpers/logging.sh'
            source '${REPO_ROOT}/helpers/retry.sh'
            source '${REPO_ROOT}/scripts/open-dep-failure-issue.sh'
            open_version_drift_issue '${drift_json}' 'foo'
        "

    # Must return non-zero on gh issue comment failure
    [ "$status" -ne 0 ]

    # Must NOT print "commented #" (no false-success output)
    [[ "$output" != *"commented #"* ]]
}

# ---------------------------------------------------------------------------
# FAILOPEN-FIX2 — container enumeration failure exits 2, not 1.
# ---------------------------------------------------------------------------

@test "FAILOPEN-FIX2: ./make list failure → script exits 2, not 1" {
    local root="${TEST_TEMP_DIR}/fail-enum-project"
    mkdir -p "$root"

    # make list exits non-zero to simulate enumeration failure
    cat > "${root}/make" <<'MAKE_EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "list" ]]; then
    echo "::error::make list failed" >&2
    exit 1
fi
MAKE_EOF
    chmod +x "${root}/make"

    # Do NOT set _VDRIFT_CONTAINERS_OVERRIDE so the real _vdrift_list_containers runs
    # and hits the failing ./make list.
    run --separate-stderr env \
        PROJECT_ROOT="$root" \
        _VDRIFT_GHCR_OWNER_OVERRIDE="testowner" \
        _VDRIFT_BUMP_EPOCH_OVERRIDE="1" \
        bash "$DRIFT_SCRIPT" --mode sweep --json

    # Enumeration failure must be exit 2 (probe/harness error), not exit 1 (drift)
    [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# FAILOPEN-FIX3 — version-drift.yaml captures issue_rc; auto-build.yaml emits
# ::warning:: on issue-open failure (structural grep tests).
# ---------------------------------------------------------------------------

@test "FAILOPEN-FIX3: version-drift.yaml captures issue_rc and exits non-zero on failure" {
    [ -f "$DRIFT_YAML" ]

    # Must capture subshell rc into a variable (not bare || true)
    local rc_capture_count
    rc_capture_count=$(grep -c 'issue_rc' "$DRIFT_YAML" || true)
    [ "$rc_capture_count" -ge 1 ]

    # Must exit 1 when issue_rc is non-zero
    local exit_on_fail_count
    exit_on_fail_count=$(grep -c 'issue_rc.*-ne 0\|exit 1' "$DRIFT_YAML" || true)
    [ "$exit_on_fail_count" -ge 1 ]

    # Must NOT have a bare "|| true" that discards the subshell rc on the
    # open_version_drift_issue call line.
    local bare_or_true
    bare_or_true=$(grep 'open_version_drift_issue' "$DRIFT_YAML" | grep -c '|| true' || true)
    [ "$bare_or_true" -eq 0 ]
}

@test "FAILOPEN-FIX3: auto-build.yaml advisory emits ::warning:: on issue-open failure, not silent || true" {
    [ -f "$AUTO_BUILD_YAML" ]

    # Extract the advisory step block
    local advisory_block
    advisory_block=$(awk '
        /Check version drift \(advisory\)/ { capture=1; next }
        capture && /^      - name:/ { capture=0 }
        capture && /^  [a-z][a-z]/ { capture=0 }
        capture { print }
    ' "$AUTO_BUILD_YAML" || true)

    # Must capture advisory_issue_rc (not bare || true)
    local rc_capture_count
    rc_capture_count=$(printf '%s' "$advisory_block" | grep -c 'advisory_issue_rc' || true)
    [ "$rc_capture_count" -ge 1 ]

    # Must emit ::warning:: on failure
    local warning_count
    warning_count=$(printf '%s' "$advisory_block" | grep -c '::warning::' || true)
    [ "$warning_count" -ge 1 ]

    # The open_version_drift_issue call must NOT have a bare || true
    local bare_or_true
    bare_or_true=$(printf '%s' "$advisory_block" | grep 'open_version_drift_issue' | grep -c '|| true' || true)
    [ "$bare_or_true" -eq 0 ]
}

# ---------------------------------------------------------------------------
# GATE-FIX1 — post-build mode checks postgres extensions when container=postgres
# ---------------------------------------------------------------------------

# Helper: create a temp project root with postgres container + extension config.
# The extension "postgis" is declared at version "3.6.3" for pg17.
# Returns the temp root path on stdout.
_make_postgres_project() {
    local root="${TEST_TEMP_DIR}/pg-project-$$"
    mkdir -p "${root}/postgres/extensions"
    mkdir -p "${root}/postgres"

    # Minimal variants.yaml for postgres itself
    cat > "${root}/postgres/variants.yaml" <<'YAML'
build:
  version_retention: 3
versions:
  - tag: "17-alpine"
YAML

    # Extension config: postgis standard extension (no version_set resolver)
    cat > "${root}/postgres/extensions/config.yaml" <<'YAML'
pg_versions:
  - "17"
extensions:
  postgis:
    version: "3.6.3"
YAML

    # Stub ./make list
    cat > "${root}/make" <<MAKE_EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "list" ]]; then
    echo "postgres"
fi
MAKE_EOF
    chmod +x "${root}/make"

    printf '%s' "$root"
}

# ---------------------------------------------------------------------------
# GATE-FIX1-a: --mode post-build --container postgres checks declared extension
#              version; absent extension → drift row, exit 1
# ---------------------------------------------------------------------------
@test "GATE-FIX1-a: post-build postgres checks extensions — absent ext version → drift + exit 1" {
    local root
    root=$(_make_postgres_project)

    # postgres container image is present; ext-postgis:pg17-3.6.3 is absent (old bump)
    local probe
    probe=$(_make_probe_stub \
        "ghcr.io/testowner/postgres:17-alpine" "present" \
        "__default__" "absent")

    run --separate-stderr env \
        PROJECT_ROOT="$root" \
        _VDRIFT_GHCR_OWNER_OVERRIDE="testowner" \
        _VDRIFT_BUMP_EPOCH_OVERRIDE="1" \
        _VDRIFT_PROBE_OVERRIDE="$probe" \
        bash "$DRIFT_SCRIPT" --mode post-build --container postgres --json

    # Extension drift detected → exit 1
    [ "$status" -eq 1 ]

    printf '%s' "$output" | jq '.' >/dev/null

    # Must have at least one extension drift row
    local ext_drift_count
    ext_drift_count=$(printf '%s' "$output" | jq '[.[] | select(.kind=="extension" and .status=="drift")] | length')
    [ "$ext_drift_count" -ge 1 ]

    # The drift row must reference the postgis extension
    local ext_name
    ext_name=$(printf '%s' "$output" | jq -r '[.[] | select(.kind=="extension" and .status=="drift")] | .[0].name')
    [[ "$ext_name" == *"postgis"* ]]
}

# ---------------------------------------------------------------------------
# GATE-FIX1-b: --mode post-build --container postgres, extension in_sync → exit 0
# ---------------------------------------------------------------------------
@test "GATE-FIX1-b: post-build postgres checks extensions — published ext → in_sync + exit 0" {
    local root
    root=$(_make_postgres_project)

    # Both postgres image AND ext-postgis:pg17-3.6.3 present
    local probe
    probe=$(_make_probe_stub \
        "ghcr.io/testowner/postgres:17-alpine" "present" \
        "ghcr.io/testowner/ext-postgis:pg17-3.6.3" "present" \
        "__default__" "absent")

    run --separate-stderr env \
        PROJECT_ROOT="$root" \
        _VDRIFT_GHCR_OWNER_OVERRIDE="testowner" \
        _VDRIFT_BUMP_EPOCH_OVERRIDE="1" \
        _VDRIFT_PROBE_OVERRIDE="$probe" \
        bash "$DRIFT_SCRIPT" --mode post-build --container postgres --json

    [ "$status" -eq 0 ]

    printf '%s' "$output" | jq '.' >/dev/null

    # Must have an extension in_sync row
    local ext_sync_count
    ext_sync_count=$(printf '%s' "$output" | jq '[.[] | select(.kind=="extension" and .status=="in_sync")] | length')
    [ "$ext_sync_count" -ge 1 ]

    # No drift rows at all
    local drift_count
    drift_count=$(printf '%s' "$output" | jq '[.[] | select(.status=="drift")] | length')
    [ "$drift_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# GATE-FIX1-c: --mode post-build --container <non-postgres> does NOT run extension checks
# ---------------------------------------------------------------------------
@test "GATE-FIX1-c: post-build non-postgres container does NOT run extension checks" {
    local root
    root=$(_make_temp_project "nginx" "1.25.0")

    # Stub probe: nginx present; any extension probe returns error (would fail the test
    # if extension checks ran for non-postgres containers)
    local probe
    probe=$(_make_probe_stub \
        "ghcr.io/testowner/nginx:1.25.0" "present" \
        "__default__" "error")

    run --separate-stderr env \
        PROJECT_ROOT="$root" \
        _VDRIFT_GHCR_OWNER_OVERRIDE="testowner" \
        _VDRIFT_BUMP_EPOCH_OVERRIDE="1" \
        _VDRIFT_PROBE_OVERRIDE="$probe" \
        bash "$DRIFT_SCRIPT" --mode post-build --container nginx --json

    # No extension check ran → exit 0 (only the nginx container row, in_sync)
    [ "$status" -eq 0 ]

    printf '%s' "$output" | jq '.' >/dev/null

    # No extension rows
    local ext_count
    ext_count=$(printf '%s' "$output" | jq '[.[] | select(.kind=="extension")] | length')
    [ "$ext_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# GATE-FIX2 — structural: summary job timeout-minutes >= 15
# ---------------------------------------------------------------------------
@test "GATE-FIX2: summary job timeout-minutes is >= 15" {
    [ -f "$AUTO_BUILD_YAML" ]

    # Extract the timeout-minutes value from the summary job block.
    # The summary job starts at "  summary:" and its timeout-minutes appears within a few lines.
    local timeout_val
    timeout_val=$(awk '
        /^  summary:/ { in_summary=1 }
        in_summary && /timeout-minutes:/ {
            match($0, /timeout-minutes:[[:space:]]*([0-9]+)/, arr)
            print arr[1]
            exit
        }
        in_summary && /^  [a-z][a-z]/ && !/^  summary:/ { exit }
    ' "$AUTO_BUILD_YAML" || true)

    [ -n "$timeout_val" ]
    [ "$timeout_val" -ge 15 ]
}

# ---------------------------------------------------------------------------
# NEW-FIX1 — fail-closed on missing tools
# ---------------------------------------------------------------------------

@test "NEW-FIX1-yq-missing: yq absent from PATH → script exits 2, not 0 (not silent false-clean)" {
    local root
    root=$(_make_temp_project "foo" "9.9.9")

    # Build a PATH that contains jq but NOT yq.
    local fake_bin="${TEST_TEMP_DIR}/no-yq-bin-$$"
    mkdir -p "$fake_bin"
    # Copy jq (or symlink the real one) so jq is available but yq is not.
    # We do NOT create a yq stub → command -v yq will fail.

    run --separate-stderr env \
        PATH="${fake_bin}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        PROJECT_ROOT="$root" \
        _VDRIFT_CONTAINERS_OVERRIDE="foo" \
        _VDRIFT_GHCR_OWNER_OVERRIDE="testowner" \
        _VDRIFT_BUMP_EPOCH_OVERRIDE="1" \
        bash "$DRIFT_SCRIPT" --mode sweep --json

    # Must fail-closed: exit 2, never exit 0 (silent false-clean)
    [ "$status" -eq 2 ]

    # stderr must mention yq
    [[ "$stderr" == *"yq"* ]]
}

@test "NEW-FIX1-jq-missing-structural: script has command -v jq prerequisite check → would exit 2 if absent" {
    # Structural test: verify the script contains the fail-closed jq prerequisite check.
    # (A functional test that removes jq from PATH is not reliably portable across
    # environments where jq shares /bin with bash itself; structural is the right oracle here.)

    # The script must contain "command -v jq" (the prerequisite check)
    local jq_check_count
    jq_check_count=$(grep -cE 'command -v jq' "$DRIFT_SCRIPT" || true)
    [ "$jq_check_count" -ge 1 ]

    # The jq check must be followed by an exit 2 in the same branch
    # (verify both appear in the prerequisite section before main logic)
    local prereq_block
    prereq_block=$(awk '
        /Prerequisite check/ { capture=1 }
        capture && /GHCR owner/ { capture=0 }
        capture { print }
    ' "$DRIFT_SCRIPT" || true)

    local jq_in_prereq
    jq_in_prereq=$(printf '%s' "$prereq_block" | grep -c 'command -v jq' || true)
    [ "$jq_in_prereq" -ge 1 ]

    local exit2_in_prereq
    exit2_in_prereq=$(printf '%s' "$prereq_block" | grep -c 'exit 2' || true)
    [ "$exit2_in_prereq" -ge 2 ]
}

# ---------------------------------------------------------------------------
# FAILOPEN-FIX4 — variants.yaml parse validation (fail-closed on malformed or
# schema-broken variants.yaml)
#
# list_versions masks yq errors (|| echo "") and always returns rc 0; a broken
# variants.yaml previously yielded empty versions → silently reported clean.
# The fix adds a direct yq -e '.versions[].tag' guard BEFORE list_versions.
# ---------------------------------------------------------------------------

@test "FAILOPEN-FIX4: malformed variants.yaml (invalid YAML) → script exits 2, not 0" {
    # A container whose variants.yaml is not parseable YAML must not be
    # reported as clean.  The script must fail-closed: exit 2 (_HAS_ERROR).
    local root="${TEST_TEMP_DIR}/malformed-project"
    local cdir="${root}/malformed-container"
    mkdir -p "$cdir"

    # Write intentionally broken YAML (unclosed bracket)
    printf 'versions: [unclosed\n' > "${cdir}/variants.yaml"

    # Stub ./make list
    cat > "${root}/make" <<'MAKE_EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "list" ]]; then
    echo "malformed-container"
fi
MAKE_EOF
    chmod +x "${root}/make"

    # Probe stub is irrelevant (validation fires before any probe call)
    local probe
    probe=$(_make_probe_stub "__default__" "present")

    run --separate-stderr env \
        PROJECT_ROOT="$root" \
        _VDRIFT_CONTAINERS_OVERRIDE="malformed-container" \
        _VDRIFT_GHCR_OWNER_OVERRIDE="testowner" \
        _VDRIFT_BUMP_EPOCH_OVERRIDE="1" \
        _VDRIFT_PROBE_OVERRIDE="$probe" \
        bash "$DRIFT_SCRIPT" --mode sweep --json

    # Must exit 2 (fail-closed), not 0 (silent false-clean)
    [ "$status" -eq 2 ]

    # The JSON output array must contain no in_sync or drift rows for this container
    # (the container was skipped as errored, not checked)
    printf '%s' "$output" | jq '.' >/dev/null

    local sync_for_malformed
    sync_for_malformed=$(printf '%s' "$output" | jq '[.[] | select(.name=="malformed-container" and .status=="in_sync")] | length')
    [ "$sync_for_malformed" -eq 0 ]
}

@test "FAILOPEN-FIX4: schema-broken variants.yaml (valid YAML, no .versions) → script exits 2, not 0" {
    # A container whose variants.yaml is valid YAML but lacks .versions[].tag
    # entries must also fail-closed: exit 2 (_HAS_ERROR), not report clean.
    local root="${TEST_TEMP_DIR}/schema-broken-project"
    local cdir="${root}/schema-broken-container"
    mkdir -p "$cdir"

    # Valid YAML structure but no 'versions' key at all
    printf 'build:\n  version_retention: 3\nno_versions_key: true\n' > "${cdir}/variants.yaml"

    cat > "${root}/make" <<'MAKE_EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "list" ]]; then
    echo "schema-broken-container"
fi
MAKE_EOF
    chmod +x "${root}/make"

    local probe
    probe=$(_make_probe_stub "__default__" "present")

    run --separate-stderr env \
        PROJECT_ROOT="$root" \
        _VDRIFT_CONTAINERS_OVERRIDE="schema-broken-container" \
        _VDRIFT_GHCR_OWNER_OVERRIDE="testowner" \
        _VDRIFT_BUMP_EPOCH_OVERRIDE="1" \
        _VDRIFT_PROBE_OVERRIDE="$probe" \
        bash "$DRIFT_SCRIPT" --mode sweep --json

    # Must exit 2 (fail-closed), not 0 (silent false-clean)
    [ "$status" -eq 2 ]

    printf '%s' "$output" | jq '.' >/dev/null

    local sync_for_schema_broken
    sync_for_schema_broken=$(printf '%s' "$output" | jq '[.[] | select(.name=="schema-broken-container" and .status=="in_sync")] | length')
    [ "$sync_for_schema_broken" -eq 0 ]
}

@test "NEW-FIX1-pg-versions-parse-fail: yq failure reading pg_versions → exit 2, not silent exit 0" {
    # The pg_versions read in _process_extensions uses a raw yq call (not wrapped
    # in || echo ""), so a yq parse failure there is directly detectable.
    # Verify: a fake yq that exits non-zero causes the extension sweep to exit 2.
    local root="${TEST_TEMP_DIR}/pg-parse-fail-project-$$"
    mkdir -p "${root}/postgres/extensions"

    # Valid YAML but the fake yq will fail on it anyway
    cat > "${root}/postgres/extensions/config.yaml" <<'YAML'
pg_versions:
  - "17"
extensions:
  pgvector:
    version: "0.8.0"
YAML

    # Stub ./make list — empty (only extension sweep matters)
    cat > "${root}/make" <<'MAKE_EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "list" ]]; then
    printf ''
fi
MAKE_EOF
    chmod +x "${root}/make"

    # Create a fake yq on PATH that always exits non-zero (simulates parse error).
    local fake_bin="${TEST_TEMP_DIR}/fail-yq-bin-$$"
    mkdir -p "$fake_bin"
    cat > "${fake_bin}/yq" <<'YQ_EOF'
#!/usr/bin/env bash
exit 1
YQ_EOF
    chmod +x "${fake_bin}/yq"

    local probe
    probe=$(_make_probe_stub "__default__" "present")

    run --separate-stderr env \
        PATH="${fake_bin}:${PATH}" \
        PROJECT_ROOT="$root" \
        _VDRIFT_CONTAINERS_OVERRIDE="" \
        _VDRIFT_GHCR_OWNER_OVERRIDE="testowner" \
        _VDRIFT_BUMP_EPOCH_OVERRIDE="1" \
        _VDRIFT_PROBE_OVERRIDE="$probe" \
        bash "$DRIFT_SCRIPT" --mode sweep --json

    # pg_versions read failure must exit 2 (fail-closed), not 0 (false-clean)
    [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# NEW-FIX2 — extension sweep respects disabled/max_pg_version filters
# ---------------------------------------------------------------------------

@test "NEW-FIX2-disabled: disabled extension is NOT checked for drift" {
    # Config with two extensions: pgvector (enabled) and citus (disabled: true).
    # citus would generate a drift row if enumerated; only pgvector must appear.
    local root="${TEST_TEMP_DIR}/disabled-ext-project-$$"
    mkdir -p "${root}/postgres/extensions"

    cat > "${root}/postgres/extensions/config.yaml" <<'YAML'
pg_versions:
  - "17"
extensions:
  pgvector:
    version: "0.8.0"
  citus:
    version: "12.1.6"
    disabled: true
YAML

    cat > "${root}/make" <<'MAKE_EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "list" ]]; then
    printf ''
fi
MAKE_EOF
    chmod +x "${root}/make"

    # pgvector present; any citus probe returns error (would fail test if called)
    local probe
    probe=$(_make_probe_stub \
        "ghcr.io/testowner/ext-pgvector:pg17-0.8.0" "present" \
        "__default__" "error")

    run --separate-stderr env \
        PROJECT_ROOT="$root" \
        _VDRIFT_CONTAINERS_OVERRIDE="" \
        _VDRIFT_GHCR_OWNER_OVERRIDE="testowner" \
        _VDRIFT_BUMP_EPOCH_OVERRIDE="1" \
        _VDRIFT_PROBE_OVERRIDE="$probe" \
        bash "$DRIFT_SCRIPT" --mode sweep --json

    # citus was disabled → its probe (error) was never called → exit 0
    [ "$status" -eq 0 ]

    printf '%s' "$output" | jq '.' >/dev/null

    # No citus rows
    local citus_count
    citus_count=$(printf '%s' "$output" | jq '[.[] | select(.name | contains("citus"))] | length')
    [ "$citus_count" -eq 0 ]

    # pgvector must be in_sync
    local pgvector_status
    pgvector_status=$(printf '%s' "$output" | jq -r '.[] | select(.name | contains("pgvector")) | .status')
    [ "$pgvector_status" = "in_sync" ]
}

@test "NEW-FIX2-max-pg-version: extension with max_pg_version < pg_major is NOT checked for drift" {
    # Config: pgvector (no max_pg_version) and pg_cron (max_pg_version: 16).
    # For pg17, pg_cron is incompatible → must not appear in results.
    local root="${TEST_TEMP_DIR}/maxpg-ext-project-$$"
    mkdir -p "${root}/postgres/extensions"

    cat > "${root}/postgres/extensions/config.yaml" <<'YAML'
pg_versions:
  - "17"
extensions:
  pgvector:
    version: "0.8.0"
  pg_cron:
    version: "1.6.4"
    max_pg_version: 16
YAML

    cat > "${root}/make" <<'MAKE_EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "list" ]]; then
    printf ''
fi
MAKE_EOF
    chmod +x "${root}/make"

    # pgvector present; pg_cron probe returns error (must not be called)
    local probe
    probe=$(_make_probe_stub \
        "ghcr.io/testowner/ext-pgvector:pg17-0.8.0" "present" \
        "__default__" "error")

    run --separate-stderr env \
        PROJECT_ROOT="$root" \
        _VDRIFT_CONTAINERS_OVERRIDE="" \
        _VDRIFT_GHCR_OWNER_OVERRIDE="testowner" \
        _VDRIFT_BUMP_EPOCH_OVERRIDE="1" \
        _VDRIFT_PROBE_OVERRIDE="$probe" \
        bash "$DRIFT_SCRIPT" --mode sweep --json

    # pg_cron was incompatible → its probe (error) never called → exit 0
    [ "$status" -eq 0 ]

    printf '%s' "$output" | jq '.' >/dev/null

    # No pg_cron rows
    local pg_cron_count
    pg_cron_count=$(printf '%s' "$output" | jq '[.[] | select(.name | contains("pg_cron"))] | length')
    [ "$pg_cron_count" -eq 0 ]

    # pgvector must be in_sync
    local pgvector_status
    pgvector_status=$(printf '%s' "$output" | jq -r '.[] | select(.name | contains("pgvector")) | .status')
    [ "$pgvector_status" = "in_sync" ]
}

# ---------------------------------------------------------------------------
# NEW-FIX3 — undeterminable bump epoch defaults to drift, not in_flight
# ---------------------------------------------------------------------------

@test "NEW-FIX3-no-commit: git log finds no commit for declaring file → absent version is drift (not in_flight)" {
    # When _VDRIFT_BUMP_EPOCH_OVERRIDE is NOT set and git log returns empty
    # (no commit tracked for the file), the fallback must be epoch=0 → drift.
    # We use a fresh temp git repo with no commits touching variants.yaml so
    # that 'git log -1 -- <file>' returns nothing.

    local root="${TEST_TEMP_DIR}/no-commit-project-$$"
    local cdir="${root}/mycontainer"
    mkdir -p "$cdir"

    cat > "${cdir}/variants.yaml" <<'YAML'
build:
  version_retention: 3
versions:
  - tag: "5.0.0"
YAML

    cat > "${root}/make" <<MAKE_EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "list" ]]; then
    echo "mycontainer"
fi
MAKE_EOF
    chmod +x "${root}/make"

    # Initialize an empty git repo (no commits → git log returns empty for any file).
    git -C "$root" init -q
    git -C "$root" config user.email "test@test.com"
    git -C "$root" config user.name "Test"
    # Do NOT commit variants.yaml → git log -1 -- mycontainer/variants.yaml returns ""

    local probe
    probe=$(_make_probe_stub "__default__" "absent")

    # Do NOT set _VDRIFT_BUMP_EPOCH_OVERRIDE → the script calls git log
    run --separate-stderr env \
        PROJECT_ROOT="$root" \
        _VDRIFT_CONTAINERS_OVERRIDE="mycontainer" \
        _VDRIFT_GHCR_OWNER_OVERRIDE="testowner" \
        _VDRIFT_PROBE_OVERRIDE="$probe" \
        bash "$DRIFT_SCRIPT" --mode sweep --json --grace-hours 6

    # Undeterminable epoch → epoch=0 → elapsed=now >> grace → drift, exit 1
    [ "$status" -eq 1 ]

    printf '%s' "$output" | jq '.' >/dev/null

    local drift_count
    drift_count=$(printf '%s' "$output" | jq '[.[] | select(.status=="drift")] | length')
    [ "$drift_count" -ge 1 ]

    # Must NOT be in_flight
    local in_flight_count
    in_flight_count=$(printf '%s' "$output" | jq '[.[] | select(.status=="in_flight")] | length')
    [ "$in_flight_count" -eq 0 ]
}

@test "NEW-FIX3-workflow: summary job checkout uses fetch-depth: 0 (full git history)" {
    [ -f "$AUTO_BUILD_YAML" ]

    # The summary job checkout must use fetch-depth: 0 so git log
    # can find the actual bump commit regardless of shallow-clone depth.
    # Extract the summary job's checkout step and verify fetch-depth: 0.
    local summary_checkout_block
    summary_checkout_block=$(awk '
        /^  summary:/ { in_summary=1 }
        in_summary && /Checkout repository/ { capture=1; next }
        capture && /^      - name:/ { capture=0 }
        capture && /^  [a-z][a-z]/ { capture=0 }
        capture { print }
    ' "$AUTO_BUILD_YAML" || true)

    [ -n "$summary_checkout_block" ]

    local fetch_depth_val
    fetch_depth_val=$(printf '%s' "$summary_checkout_block" | grep 'fetch-depth:' | awk '{print $2}')
    [ "$fetch_depth_val" = "0" ]
}

# ---------------------------------------------------------------------------
# NARROW-ABSENT-1 — credential helper error → error (not absent)
#
# stderr = "error: getting credentials: credential helper not found"
# skopeo exits non-zero.  The old broad matcher ('not found') mapped this to
# absent → false drift alert.  The narrow matcher must return error → exit 2.
# ---------------------------------------------------------------------------
@test "NARROW-ABSENT-1: skopeo fails with 'credential helper not found' → error → exit 2 (not absent/drift)" {
    local root
    root=$(_make_temp_project "foo" "9.9.9")

    local fake_bin
    fake_bin=$(_make_fake_skopeo 1 "error: getting credentials: credential helper not found")

    run --separate-stderr env \
        PATH="${fake_bin}:${PATH}" \
        PROJECT_ROOT="$root" \
        _VDRIFT_CONTAINERS_OVERRIDE="foo" \
        _VDRIFT_GHCR_OWNER_OVERRIDE="testowner" \
        _VDRIFT_BUMP_EPOCH_OVERRIDE="1" \
        bash "$DRIFT_SCRIPT" --mode sweep --json

    # Must be error (exit 2), not absent/drift (exit 1)
    [ "$status" -eq 2 ]

    printf '%s' "$output" | jq '.' >/dev/null

    local error_count
    error_count=$(printf '%s' "$output" | jq '[.[] | select(.status=="error")] | length')
    [ "$error_count" -eq 1 ]

    # Must NOT have produced a drift row
    local drift_count
    drift_count=$(printf '%s' "$output" | jq '[.[] | select(.status=="drift")] | length')
    [ "$drift_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# NARROW-ABSENT-2 — "command not found" → error (not absent)
#
# Simulates a PATH/tooling failure on the registry side (the client binary
# itself is not found, or a helper binary is missing).
# ---------------------------------------------------------------------------
@test "NARROW-ABSENT-2: skopeo fails with 'command not found' stderr → error → exit 2 (not absent/drift)" {
    local root
    root=$(_make_temp_project "foo" "9.9.9")

    local fake_bin
    fake_bin=$(_make_fake_skopeo 1 "skopeo: command not found")

    run --separate-stderr env \
        PATH="${fake_bin}:${PATH}" \
        PROJECT_ROOT="$root" \
        _VDRIFT_CONTAINERS_OVERRIDE="foo" \
        _VDRIFT_GHCR_OWNER_OVERRIDE="testowner" \
        _VDRIFT_BUMP_EPOCH_OVERRIDE="1" \
        bash "$DRIFT_SCRIPT" --mode sweep --json

    [ "$status" -eq 2 ]

    printf '%s' "$output" | jq '.' >/dev/null

    local error_count
    error_count=$(printf '%s' "$output" | jq '[.[] | select(.status=="error")] | length')
    [ "$error_count" -eq 1 ]

    local drift_count
    drift_count=$(printf '%s' "$output" | jq '[.[] | select(.status=="drift")] | length')
    [ "$drift_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# NARROW-ABSENT-3 — auth-endpoint 404 (not a manifest-unknown) → error
#
# "unexpected http status 404" appears when skopeo hits the auth endpoint
# (e.g. /token) and gets a 404, NOT when the manifest itself is missing.
# The old broad '404' alternative misclassified this as absent.
# ---------------------------------------------------------------------------
@test "NARROW-ABSENT-3: skopeo fails with auth-endpoint 'unexpected http status 404' → error → exit 2 (not absent/drift)" {
    local root
    root=$(_make_temp_project "foo" "9.9.9")

    local fake_bin
    fake_bin=$(_make_fake_skopeo 1 "Error: reading manifest: unexpected http status 404 on auth endpoint")

    run --separate-stderr env \
        PATH="${fake_bin}:${PATH}" \
        PROJECT_ROOT="$root" \
        _VDRIFT_CONTAINERS_OVERRIDE="foo" \
        _VDRIFT_GHCR_OWNER_OVERRIDE="testowner" \
        _VDRIFT_BUMP_EPOCH_OVERRIDE="1" \
        bash "$DRIFT_SCRIPT" --mode sweep --json

    [ "$status" -eq 2 ]

    printf '%s' "$output" | jq '.' >/dev/null

    local error_count
    error_count=$(printf '%s' "$output" | jq '[.[] | select(.status=="error")] | length')
    [ "$error_count" -eq 1 ]

    local drift_count
    drift_count=$(printf '%s' "$output" | jq '[.[] | select(.status=="drift")] | length')
    [ "$drift_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# NARROW-ABSENT-4 (regression) — "manifest unknown" → absent → drift (no change)
# ---------------------------------------------------------------------------
@test "NARROW-ABSENT-4: skopeo fails with 'manifest unknown' stderr → absent → drift + exit 1 (unchanged)" {
    local root
    root=$(_make_temp_project "foo" "9.9.9")

    local fake_bin
    fake_bin=$(_make_fake_skopeo 1 "Error: manifest unknown")

    run --separate-stderr env \
        PATH="${fake_bin}:${PATH}" \
        PROJECT_ROOT="$root" \
        _VDRIFT_CONTAINERS_OVERRIDE="foo" \
        _VDRIFT_GHCR_OWNER_OVERRIDE="testowner" \
        _VDRIFT_BUMP_EPOCH_OVERRIDE="1" \
        bash "$DRIFT_SCRIPT" --mode sweep --json

    [ "$status" -eq 1 ]

    printf '%s' "$output" | jq '.' >/dev/null

    local drift_count
    drift_count=$(printf '%s' "$output" | jq '[.[] | select(.status=="drift")] | length')
    [ "$drift_count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# NARROW-ABSENT-5 (regression) — "was deleted or has expired" → absent → drift
# ---------------------------------------------------------------------------
@test "NARROW-ABSENT-5: skopeo fails with 'was deleted or has expired' stderr → absent → drift + exit 1 (unchanged)" {
    local root
    root=$(_make_temp_project "foo" "9.9.9")

    local fake_bin
    fake_bin=$(_make_fake_skopeo 1 "Error: tag was deleted or has expired")

    run --separate-stderr env \
        PATH="${fake_bin}:${PATH}" \
        PROJECT_ROOT="$root" \
        _VDRIFT_CONTAINERS_OVERRIDE="foo" \
        _VDRIFT_GHCR_OWNER_OVERRIDE="testowner" \
        _VDRIFT_BUMP_EPOCH_OVERRIDE="1" \
        bash "$DRIFT_SCRIPT" --mode sweep --json

    [ "$status" -eq 1 ]

    printf '%s' "$output" | jq '.' >/dev/null

    local drift_count
    drift_count=$(printf '%s' "$output" | jq '[.[] | select(.status=="drift")] | length')
    [ "$drift_count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# DRIFT-JSON-VALID-1 — malformed drift_json → open_version_drift_issue returns 1
#
# A non-empty but unparseable drift_json must return non-zero (fail loudly),
# not silently no-op as if there were no drift rows.
# ---------------------------------------------------------------------------
@test "DRIFT-JSON-VALID-1: open_version_drift_issue with malformed drift_json returns non-zero" {
    local fake_bin="${TEST_TEMP_DIR}/fake-gh-json-valid-$$"
    mkdir -p "$fake_bin"

    # gh stub (must NOT be called — the json guard fires before gh is invoked)
    cat > "${fake_bin}/gh" <<'GH_EOF'
#!/usr/bin/env bash
printf 'gh called unexpectedly\n' >&2
exit 1
GH_EOF
    chmod +x "${fake_bin}/gh"

    run --separate-stderr env \
        PATH="${fake_bin}:${PATH}" \
        GH_TOKEN="fake-token" \
        GITHUB_REPOSITORY="test/repo" \
        GITHUB_RUN_ID="12345" \
        GITHUB_SERVER_URL="https://github.com" \
        GITHUB_SHA="abcdef01" \
        GITHUB_EVENT_NAME="push" \
        GITHUB_REF_NAME="master" \
        COMMIT_SUBJECT="test" \
        DRY_RUN="false" \
        bash -c "
            source '${REPO_ROOT}/helpers/logging.sh'
            source '${REPO_ROOT}/helpers/retry.sh'
            source '${REPO_ROOT}/scripts/open-dep-failure-issue.sh'
            open_version_drift_issue '{not json' 'foo'
        "

    # Must return non-zero — malformed JSON must not silently no-op
    [ "$status" -ne 0 ]

    # Must NOT have created or commented on any issue
    [[ "$output" != *"created #"* ]]
    [[ "$output" != *"commented #"* ]]
}

# ---------------------------------------------------------------------------
# DRIFT-JSON-VALID-2 — empty drift_json → open_version_drift_issue returns 0 (no-op)
#
# An empty/whitespace drift_json is a legitimate no-op and must still return 0.
# ---------------------------------------------------------------------------
@test "DRIFT-JSON-VALID-2: open_version_drift_issue with empty drift_json returns 0 (no-op)" {
    local fake_bin="${TEST_TEMP_DIR}/fake-gh-empty-json-$$"
    mkdir -p "$fake_bin"

    cat > "${fake_bin}/gh" <<'GH_EOF'
#!/usr/bin/env bash
printf 'gh called unexpectedly\n' >&2
exit 1
GH_EOF
    chmod +x "${fake_bin}/gh"

    run --separate-stderr env \
        PATH="${fake_bin}:${PATH}" \
        GH_TOKEN="fake-token" \
        GITHUB_REPOSITORY="test/repo" \
        GITHUB_RUN_ID="12345" \
        GITHUB_SERVER_URL="https://github.com" \
        GITHUB_SHA="abcdef01" \
        GITHUB_EVENT_NAME="push" \
        GITHUB_REF_NAME="master" \
        COMMIT_SUBJECT="test" \
        DRY_RUN="false" \
        bash -c "
            source '${REPO_ROOT}/helpers/logging.sh'
            source '${REPO_ROOT}/helpers/retry.sh'
            source '${REPO_ROOT}/scripts/open-dep-failure-issue.sh'
            open_version_drift_issue '' 'foo'
        "

    # Empty drift_json → no-op → must return 0
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# DRIFT-JSON-VALID-3 — "[]" drift_json → open_version_drift_issue returns 0 (no-op)
# ---------------------------------------------------------------------------
@test "DRIFT-JSON-VALID-3: open_version_drift_issue with '[]' drift_json returns 0 (no-op)" {
    local fake_bin="${TEST_TEMP_DIR}/fake-gh-empty-array-$$"
    mkdir -p "$fake_bin"

    cat > "${fake_bin}/gh" <<'GH_EOF'
#!/usr/bin/env bash
printf 'gh called unexpectedly\n' >&2
exit 1
GH_EOF
    chmod +x "${fake_bin}/gh"

    run --separate-stderr env \
        PATH="${fake_bin}:${PATH}" \
        GH_TOKEN="fake-token" \
        GITHUB_REPOSITORY="test/repo" \
        GITHUB_RUN_ID="12345" \
        GITHUB_SERVER_URL="https://github.com" \
        GITHUB_SHA="abcdef01" \
        GITHUB_EVENT_NAME="push" \
        GITHUB_REF_NAME="master" \
        COMMIT_SUBJECT="test" \
        DRY_RUN="false" \
        bash -c "
            source '${REPO_ROOT}/helpers/logging.sh'
            source '${REPO_ROOT}/helpers/retry.sh'
            source '${REPO_ROOT}/scripts/open-dep-failure-issue.sh'
            open_version_drift_issue '[]' 'foo'
        "

    # Empty array → no drift rows → must return 0
    [ "$status" -eq 0 ]
}
