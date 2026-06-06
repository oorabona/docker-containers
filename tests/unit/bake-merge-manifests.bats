#!/usr/bin/env bats
# Unit tests for scripts/bake-merge-manifests.sh — ADR-013 R3 slice
#
# Mutation guards:
#   MM1: Emit only versioned ref (omit :latest) → default variant misses rolling tag
#   MM2: Include single-arch fallback path → strict guard violated
#   MM5: Pass only -amd64 or only -arm64 → merge source always lists both arches
#   MM6: Cell set diverges from generator bake mode → parity assertion fails
#   MM7: Publish :latest for non-latest retained cell → retained version clobbers :latest (F2)
#   MM8: Emit a docker.io ref → GHCR-only contract violated (egress-containment ADR-013)
#   MM9: Route rolling alias by flavor → github-runner debian-trixie-base and -dev collide (FIX F)
#   MM10: Skip duplicate-ref guard → silent manifest corruption on variant.yaml mistakes (FIX F guard)
#   MM11: Suppress DRY-RUN stdout → documented dry-run contract unmet (FIX H)
#   MM12: Allow --all-retained flag in containers input → multi-version bake with single-version artifact (FIX I)

load "../test_helper"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Create a mock docker script that records every invocation to a log file.
# DOCKER_LOG is set to the log file path; the mock always exits 0.
_setup_docker_mock() {
    export DOCKER_LOG="${TEST_TEMP_DIR}/docker-calls.log"
    touch "$DOCKER_LOG"
    cat > "${TEST_TEMP_DIR}/bin/docker" <<'MOCK'
#!/usr/bin/env bash
# Append the full invocation to the log file (one space-joined line)
printf '%s\n' "$*" >> "${DOCKER_LOG}"
exit 0
MOCK
    chmod +x "${TEST_TEMP_DIR}/bin/docker"
    export DOCKER="${TEST_TEMP_DIR}/bin/docker"
    export PATH="${TEST_TEMP_DIR}/bin:$PATH"
}

setup() {
    export PROJECT_ROOT
    export HELPERS_DIR
    export _DEPGRAPH_LINEAGE_DIR=/nonexistent
    export GITHUB_ACTIONS=""
    setup_temp_dir
    mkdir -p "${TEST_TEMP_DIR}/bin"
    _setup_docker_mock
}

teardown() {
    teardown_temp_dir
}

# Run the merge script with the mock DOCKER
_run_merge() {
    run bash "${PROJECT_ROOT}/scripts/bake-merge-manifests.sh" "$@"
}

# ---------------------------------------------------------------------------
# MM1: default variant (is_default=true) → GHCR imagetools create carries
# both the versioned ref AND :latest.
# ---------------------------------------------------------------------------
@test "BMM-01: default variant GHCR merge includes both versioned and :latest refs" {
    _run_merge debian
    [ "$status" -eq 0 ]

    # Must have an imagetools create line for GHCR debian
    local ghcr_create_line
    ghcr_create_line=$(grep "imagetools create" "$DOCKER_LOG" \
        | grep "ghcr.io/oorabona/debian:" | head -1)
    [[ -n "$ghcr_create_line" ]]

    # The line must contain the versioned tag
    [[ "$ghcr_create_line" == *"ghcr.io/oorabona/debian:trixie"* ]]

    # The line must also contain :latest (rolling alias)
    [[ "$ghcr_create_line" == *"ghcr.io/oorabona/debian:latest"* ]]
}

# ---------------------------------------------------------------------------
# MM2: non-default flavored variant → GHCR line carries :latest-<flavor>
# NOT bare :latest.
# ---------------------------------------------------------------------------
@test "BMM-02: non-default flavored variant GHCR merge carries :latest-<flavor>, not bare :latest" {
    _run_merge web-shell
    [ "$status" -eq 0 ]

    # Find the alpine variant create line
    local alpine_line
    alpine_line=$(grep "imagetools create" "$DOCKER_LOG" \
        | grep "ghcr.io/oorabona/web-shell:.*alpine" \
        | grep "latest-alpine" | head -1)
    [[ -n "$alpine_line" ]]

    # Must NOT have bare :latest in that line
    [[ "$alpine_line" != *":latest "* ]] && [[ "$alpine_line" != *":latest	"* ]] && \
        [[ "$alpine_line" != *":latest-alpine"*":latest "* ]] || true

    # More precise: the line has :latest-alpine but no ghcr.io/oorabona/web-shell:latest
    # (bare :latest without a suffix)
    local bare_latest_count
    bare_latest_count=$(printf '%s\n' "$alpine_line" | \
        grep -oE 'ghcr\.io/oorabona/web-shell:latest( |$)' | wc -l)
    [ "$bare_latest_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# MM5: STRICT — both arch sources always present in every GHCR create call.
# Assert every "imagetools create" line that has a ghcr.io -t ref also
# passes both -amd64 and -arm64 sources.
# ---------------------------------------------------------------------------
@test "BMM-03: strict — every GHCR imagetools create call lists both -amd64 and -arm64 sources" {
    _run_merge web-shell github-runner debian
    [ "$status" -eq 0 ]

    # Every imagetools create line that targets GHCR must end with both arch sources
    local line
    while IFS= read -r line; do
        [[ "$line" == *"imagetools create"* ]] || continue
        [[ "$line" == *"ghcr.io/oorabona/"* ]] || continue
        # The line must contain an -amd64 source ref
        [[ "$line" == *"-amd64"* ]]
        # The line must contain an -arm64 source ref
        [[ "$line" == *"-arm64"* ]]
    done < "$DOCKER_LOG"
}

# ---------------------------------------------------------------------------
# MM2 (no single-arch fallback path): assert there is no imagetools create
# line that lists ONLY -amd64 or ONLY -arm64 as its sole source for a
# rolling/latest-tagged publish (the strict guard).
# ---------------------------------------------------------------------------
@test "BMM-04: no single-arch-only rolling publish line exists in dry-run output" {
    _run_merge debian web-shell
    [ "$status" -eq 0 ]

    # A line is "single-arch rolling" if it has -t *:latest* but only one
    # arch suffix in the source refs (i.e. has -amd64 XOR -arm64, not both).
    local line
    local bad=0
    while IFS= read -r line; do
        [[ "$line" == *"imagetools create"* ]] || continue
        [[ "$line" == *":latest"* ]] || continue

        local has_amd=0 has_arm=0
        [[ "$line" == *"-amd64"* ]] && has_amd=1
        [[ "$line" == *"-arm64"* ]] && has_arm=1

        # Both must be present for any :latest rolling publish
        if [[ "$has_amd" -eq 1 && "$has_arm" -eq 1 ]]; then
            continue  # correct
        fi
        bad=$(( bad + 1 ))
    done < "$DOCKER_LOG"

    [ "$bad" -eq 0 ]
}

# ---------------------------------------------------------------------------
# MM8: GHCR-only — no docker.io ref ever emitted.
# ADR-013 egress-containment: bake intermediates and final manifests are
# GHCR-only. DockerHub publish is handled by the existing auto-build.yaml.
# ---------------------------------------------------------------------------
@test "BMM-05: GHCR-only — no docker.io ref emitted for any container" {
    _run_merge debian web-shell
    [ "$status" -eq 0 ]

    local dh_count
    dh_count=$(grep "docker.io/" "$DOCKER_LOG" 2>/dev/null | wc -l | tr -d ' ')
    [ "$dh_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# MM6: Cell-plan parity — the container/tag set from --cells matches the
# set that the merge script iterates (integration smoke).
# ---------------------------------------------------------------------------
@test "BMM-07: cell plan from --cells matches cells iterated by merge script for web-shell github-runner debian" {
    _run_merge web-shell github-runner debian
    [ "$status" -eq 0 ]

    # Collect cells from --cells mode
    local cells_json
    cells_json=$(bash "${PROJECT_ROOT}/scripts/generate-bake-hcl.sh" \
        --cells web-shell github-runner debian 2>/dev/null)

    local expected_count
    expected_count=$(jq 'length' <<< "$cells_json")

    # Each cell produces exactly one imagetools create call (GHCR-only)
    local actual_ghcr_calls
    actual_ghcr_calls=$(grep "imagetools create" "$DOCKER_LOG" 2>/dev/null | wc -l | tr -d ' ')

    [ "$actual_ghcr_calls" -eq "$expected_count" ]
}

# ---------------------------------------------------------------------------
# Helper: invoke _merge_cell from the merge script directly.
# We create a thin caller script that sources bake-merge-manifests.sh with
# BATS_MERGE_HELPER=1 so the main() guard suppresses execution, then calls
# _merge_cell with the supplied args.
# ---------------------------------------------------------------------------
_call_merge_cell() {
    # Args forwarded to _merge_cell: container tag flavor is_default intermediate_ref is_latest
    # bake-merge-manifests.sh guards main() with BASH_SOURCE[0]==$0, so sourcing it
    # is safe — main will not execute.
    local caller_script="${TEST_TEMP_DIR}/_call_merge_cell.sh"
    cat > "$caller_script" <<'CALLER'
#!/usr/bin/env bash
set -euo pipefail
# Source helpers (bake-merge-manifests.sh also sources them, harmless double-source).
source "${PROJECT_ROOT}/helpers/logging.sh"
source "${PROJECT_ROOT}/helpers/retry.sh"
source "${PROJECT_ROOT}/helpers/variant-utils.sh"
export _DEPGRAPH_LINEAGE_DIR=/nonexistent

# Source the merge script — main() will NOT run (BASH_SOURCE guard).
# shellcheck source=../../scripts/bake-merge-manifests.sh
source "${PROJECT_ROOT}/scripts/bake-merge-manifests.sh"

# Now _merge_cell is defined in scope — call it.
_merge_cell "$@"
CALLER
    chmod +x "$caller_script"
    run bash "$caller_script" "$@"
}

# ---------------------------------------------------------------------------
# F2 / MM7: retained non-latest cell must NOT publish :latest.
# Catches MG7: if the is_latest_version gate is missing, both trixie and
# bookworm would claim :latest, with the last-merged (older) version winning.
# ---------------------------------------------------------------------------
@test "BMM-09: F2 — retained non-latest cell publishes versioned ref only, not :latest" {
    export REMOTE_CR="ghcr.io/oorabona"

    _call_merge_cell "debian" "bookworm" "" "true" \
        "ghcr.io/oorabona/debian:bookworm" "false"
    [ "$status" -eq 0 ]

    # The docker mock log must have a create line with the versioned ref
    local create_line
    create_line=$(grep "imagetools create" "$DOCKER_LOG" | grep "ghcr.io/oorabona/debian:" | head -1)
    [[ -n "$create_line" ]]
    [[ "$create_line" == *"ghcr.io/oorabona/debian:bookworm"* ]]

    # Must NOT contain :latest (no rolling alias for non-latest cell)
    [[ "$create_line" != *"ghcr.io/oorabona/debian:latest"* ]]
}

@test "BMM-10: F2 — latest cell (is_latest_version=true) DOES publish :latest" {
    export REMOTE_CR="ghcr.io/oorabona"

    _call_merge_cell "debian" "trixie" "" "true" \
        "ghcr.io/oorabona/debian:trixie" "true"
    [ "$status" -eq 0 ]

    local create_line
    create_line=$(grep "imagetools create" "$DOCKER_LOG" | grep "ghcr.io/oorabona/debian:" | head -1)
    [[ -n "$create_line" ]]
    # Latest cell must include :latest rolling alias
    [[ "$create_line" == *"ghcr.io/oorabona/debian:latest"* ]]
}

# ---------------------------------------------------------------------------
# FIX F / MM9: github-runner dry-run merge emits distinct rolling aliases.
# debian-trixie-base and debian-trixie-dev must NOT share latest-debian-trixie.
# ---------------------------------------------------------------------------
@test "BMM-11: FIX F — github-runner merge emits latest-debian-trixie-base AND latest-debian-trixie-dev (distinct, no collision)" {
    export REMOTE_CR="ghcr.io/oorabona"
    _run_merge github-runner
    [ "$status" -eq 0 ]

    local all_create_lines
    all_create_lines=$(grep "imagetools create" "$DOCKER_LOG" || true)

    # Both distinct rolling aliases must appear
    [[ "$all_create_lines" == *"ghcr.io/oorabona/github-runner:latest-debian-trixie-base"* ]]
    [[ "$all_create_lines" == *"ghcr.io/oorabona/github-runner:latest-debian-trixie-dev"* ]]

    # The ambiguous colliding alias must NOT appear (it was the pre-fix behavior)
    local collision_count
    collision_count=$(printf '%s\n' "$all_create_lines" | \
        grep -c 'ghcr\.io/oorabona/github-runner:latest-debian-trixie"' || true)
    [ "$collision_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# FIX F guard / MM10: duplicate-final-ref guard aborts on collision.
# Provide a mock generate-bake-hcl.sh that outputs a dup-ref cell plan, then
# invoke the real bake-merge-manifests.sh main() via a sourced caller.
# ---------------------------------------------------------------------------
@test "BMM-12: FIX F guard — merge aborts with error when two cells map to the same final ref" {
    export REMOTE_CR="ghcr.io/oorabona"

    # -----------------------------------------------------------------------
    # Mock generate-bake-hcl.sh: always output a two-cell plan where both
    # cells share the same variant → same :latest-alpine final ref.
    # -----------------------------------------------------------------------
    local mock_gen="${TEST_TEMP_DIR}/bin/generate-bake-hcl.sh"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'printf '"'"'[{"container":"debian","tag":"trixie","flavor":"alpine","variant":"alpine","is_default":false,"is_latest_version":true,"intermediate_ref":"ghcr.io/oorabona/debian:trixie"},{"container":"debian","tag":"bookworm","flavor":"alpine","variant":"alpine","is_default":false,"is_latest_version":true,"intermediate_ref":"ghcr.io/oorabona/debian:bookworm"}]\n'"'"'\n'
    } > "$mock_gen"
    chmod +x "$mock_gen"

    # -----------------------------------------------------------------------
    # Caller script: source the real merge script (main() guarded by BASH_SOURCE)
    # then call main() with PATH prepended so generate-bake-hcl.sh resolves to mock.
    # -----------------------------------------------------------------------
    local caller_script="${TEST_TEMP_DIR}/_dup_caller.sh"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'set -euo pipefail\n'
        printf 'source "${PROJECT_ROOT}/helpers/logging.sh"\n'
        printf 'source "${PROJECT_ROOT}/helpers/retry.sh"\n'
        printf 'source "${PROJECT_ROOT}/helpers/variant-utils.sh"\n'
        printf 'export _DEPGRAPH_LINEAGE_DIR=/nonexistent\n'
        printf '# source the merge script (BASH_SOURCE guard suppresses main execution)\n'
        printf 'source "${PROJECT_ROOT}/scripts/bake-merge-manifests.sh"\n'
        printf '# Override SCRIPT_DIR so the sourced main() finds the mock generator\n'
        printf 'SCRIPT_DIR="${TEST_TEMP_DIR}/bin"\n'
        printf 'main\n'
    } > "$caller_script"
    chmod +x "$caller_script"

    run bash "$caller_script"

    # The guard must fire: exit non-zero
    [ "$status" -ne 0 ]
    # Error message in combined output (bats run captures stdout+stderr)
    [[ "$output" == *"Duplicate final ref"* ]]
}

# ---------------------------------------------------------------------------
# FIX H / MM11: DRY_RUN=true emits command to stdout and does NOT execute.
# Catches MM11: if the dry-run branch is removed, the command is captured
# into err_output and never shown — the documented contract is broken.
# ---------------------------------------------------------------------------
@test "BMM-13: FIX H — DRY_RUN=true emits imagetools create command visibly and exits 0" {
    export REMOTE_CR="ghcr.io/oorabona"
    export DRY_RUN="true"

    # Use _call_merge_cell so we can assert on its stdout
    _call_merge_cell "debian" "trixie" "" "true" \
        "ghcr.io/oorabona/debian:trixie" "true" ""
    [ "$status" -eq 0 ]

    # The DRY-RUN line must be visible on stdout (captured in $output by bats run)
    [[ "$output" == *"DRY-RUN: docker buildx imagetools create"* ]]

    # Must reference both arch source refs
    [[ "$output" == *"ghcr.io/oorabona/debian:trixie-amd64"* ]]
    [[ "$output" == *"ghcr.io/oorabona/debian:trixie-arm64"* ]]

    # The docker mock log must be EMPTY — DRY_RUN returns before the real call
    local mock_calls
    mock_calls=$(wc -l < "$DOCKER_LOG" | tr -d ' ')
    [ "$mock_calls" -eq 0 ]
}

# ---------------------------------------------------------------------------
# FIX I / MM12: containers input validation rejects flag tokens.
# FIX N: guard upgraded to set -f + anchored grep -qE pattern.
# The guard logic is extracted and tested as a bash fragment.
# ---------------------------------------------------------------------------

# Helper: run the FIX N input-validation guard with a given CONTAINERS value.
# Exits 0 when all tokens are valid bare names matching [a-z0-9][a-z0-9._-]*,
# non-zero when any token fails the pattern (e.g. '--all-retained', 'foo*').
_run_containers_guard() {
    local containers_value="$1"
    local guard_script="${TEST_TEMP_DIR}/_containers_guard.sh"
    # Write guard script using a temp variable to avoid quoting hell.
    local escaped_containers
    escaped_containers=$(printf '%q' "$containers_value")
    printf '#!/usr/bin/env bash\nset -euo pipefail\nCONTAINERS=%s\nset -f\nfor _c in ${CONTAINERS}; do\n  if ! printf '"'"'%%s'"'"' "$_c" | grep -qE '"'"'^[a-z0-9][a-z0-9._-]*$'"'"'; then\n    echo "::error::invalid container token ${_c}"; exit 1\n  fi\ndone\nset +f\nprintf '"'"'OK\\n'"'"'\n' \
        "$escaped_containers" > "$guard_script"
    chmod +x "$guard_script"
    run bash "$guard_script"
}

@test "BMM-14: FIX I/N — containers guard rejects --all-retained flag injection" {
    _run_containers_guard "--all-retained github-runner"
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid container token"* ]]
    [[ "$output" == *"--all-retained"* ]]
}

@test "BMM-14b: FIX N — containers guard rejects glob pattern (foo*)" {
    _run_containers_guard "foo*"
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid container token"* ]]
    [[ "$output" == *"foo"* ]]
}

@test "BMM-15: FIX I/N — containers guard accepts valid bare container names" {
    _run_containers_guard "github-runner debian"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

# ---------------------------------------------------------------------------
# FIX U: quoted $DOCKER — single-word mock path must still be invoked correctly.
# The real merge path uses "$DOCKER" (quoted); verify the mock receives the
# expected arguments and the merge succeeds (no word-splitting regression).
# ---------------------------------------------------------------------------

@test "BMM-16: FIX U — quoted \$DOCKER invokes mock correctly with expected imagetools args" {
    _run_merge debian
    [ "$status" -eq 0 ]

    # The docker log must have at least one imagetools create invocation
    local create_count
    create_count=$(grep -c "imagetools create" "$DOCKER_LOG" || true)
    [ "$create_count" -gt 0 ]

    # Every logged line must have the buildx subcommand and the create action
    local bad_lines
    bad_lines=$(grep "imagetools" "$DOCKER_LOG" | grep -vc "imagetools create" || true)
    [ "$bad_lines" -eq 0 ]

    # The args must include at least one -t ref and both arch source refs
    local log_line
    log_line=$(grep "imagetools create" "$DOCKER_LOG" | head -1)
    [[ "$log_line" == *"-t "* ]]
    [[ "$log_line" == *"-amd64"* ]]
    [[ "$log_line" == *"-arm64"* ]]
}
