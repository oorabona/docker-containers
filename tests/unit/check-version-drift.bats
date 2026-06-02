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

    # window_empty counts as drift (exit 1)... unless probe would make it in_sync.
    # window_empty is its own status; check it appears correctly.
    printf '%s' "$output" | jq '.' >/dev/null

    local window_empty_count
    window_empty_count=$(printf '%s' "$output" | jq '[.[] | select(.status=="window_empty")] | length')
    [ "$window_empty_count" -eq 1 ]

    local row_name
    row_name=$(printf '%s' "$output" | jq -r '.[0].name')
    [ "$row_name" = "ext-timescaledb:pg17" ]
}
