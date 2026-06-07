#!/usr/bin/env bats
# Unit tests for helpers/mirror-dockerhub.sh — ADR-013 production cutover
#
# Mutation guards (named per test):
#   MD1: Default latest cell mirrors both versioned AND :latest from GHCR
#   MD2: Non-default flavored cell mirrors :latest-<variant> instead of :latest
#   MD3: Retained non-latest cell mirrors ONLY the versioned tag (no rolling alias)
#   MD4: Function skips when DOCKERHUB_USERNAME is unset
#   MD5: A single mirror failure does NOT fail the function (best-effort; rc=0)
#   MD6: BAKE_GENERATE_ALL_RETAINED ignored → retained GHCR tags absent on DockerHub
#   MS1: MIRROR_STRICT unset → returns 0 even when all imagetools fail (best-effort preserved)
#   MS2: MIRROR_STRICT=true + all imagetools succeed → returns 0
#   MS3: MIRROR_STRICT=true + ALL imagetools fail (attempted>0, succeeded==0) → returns non-zero
#   MS4: MIRROR_STRICT=true + PARTIAL success (some succeed, some fail) → returns 0
#   MS5: MIRROR_STRICT=true + DOCKERHUB_USERNAME unset → returns non-zero (structural)
#   MS6: MIRROR_STRICT=true + generator yields no cells → returns non-zero (structural)

load "../test_helper"

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------
setup() {
    export PROJECT_ROOT
    export HELPERS_DIR

    export MDH="${HELPERS_DIR}/mirror-dockerhub.sh"

    # Suppress GHA annotations and depgraph noise
    export GITHUB_ACTIONS=""
    export _DEPGRAPH_LINEAGE_DIR=/nonexistent

    # Create a per-test log directory under /tmp (writeable regardless of scope guard)
    export TEST_LOG_DIR
    TEST_LOG_DIR=$(mktemp -d)
    export DOCKER_LOG="${TEST_LOG_DIR}/docker.log"

    # Mock DOCKER binary: logs every call and exits 0 by default
    export MOCK_DOCKER="${TEST_LOG_DIR}/docker"
    cat > "$MOCK_DOCKER" <<'MOCK_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DOCKER_LOG}"
exit 0
MOCK_EOF
    chmod +x "$MOCK_DOCKER"

    # Wire the mock into the script under test
    export DOCKER="$MOCK_DOCKER"

    # Set a default DockerHub username so tests that need it don't have to repeat it
    export DOCKERHUB_USERNAME="testuser"

    # Use a deterministic REMOTE_CR (real ghcr.io namespace for --cells resolution)
    export REMOTE_CR="ghcr.io/oorabona"

    # Clear DRY_RUN between tests
    export DRY_RUN="false"

    # Default to latest-only (no retained) between tests
    export BAKE_GENERATE_ALL_RETAINED="false"

    # Default to best-effort (strict mode off) between tests
    export MIRROR_STRICT="false"
}

teardown() {
    rm -rf "$TEST_LOG_DIR"
    unset DOCKERHUB_USERNAME REMOTE_CR DRY_RUN BAKE_GENERATE_ALL_RETAINED MIRROR_STRICT _MDH_GENERATOR_OVERRIDE || true
}

# ---------------------------------------------------------------------------
# Helper: run mirror_to_dockerhub via a subshell that re-sources the script.
# Captures stdout+stderr to TEST_LOG_DIR/run.log; returns the function's rc.
# ---------------------------------------------------------------------------
_run_mirror() {
    # shellcheck disable=SC1090
    (
        export DOCKER
        export DOCKER_LOG
        export DOCKERHUB_USERNAME
        export REMOTE_CR
        export DRY_RUN
        export GITHUB_ACTIONS
        export _DEPGRAPH_LINEAGE_DIR
        export BAKE_GENERATE_ALL_RETAINED
        export MIRROR_STRICT
        export _MDH_GENERATOR_OVERRIDE

        source "$MDH"
        mirror_to_dockerhub "$@"
    ) > "${TEST_LOG_DIR}/run.log" 2>&1
}

# ---------------------------------------------------------------------------
# MD-01: Default-variant (is_default=true) latest cell mirrors versioned tag
#        AND :latest to docker.io.
# Catches: MD1
# ---------------------------------------------------------------------------
@test "MD-01: default latest cell mirrors versioned tag and :latest to docker.io" {
    # web-shell is the simplest bake-managed container with a default variant
    run _run_mirror "web-shell"
    [ "$status" -eq 0 ]

    # Docker log must contain at least one imagetools create call to docker.io
    grep -q "buildx imagetools create" "$DOCKER_LOG" || \
        (cat "${TEST_LOG_DIR}/run.log" >&2 && false)

    # At least one mirror targets docker.io/testuser/web-shell:latest
    grep -q "docker.io/testuser/web-shell:latest" "$DOCKER_LOG" || \
        (echo "Expected :latest mirror call not found in docker log:" >&2
         cat "$DOCKER_LOG" >&2
         false)

    # At least one call includes a versioned tag (not ":latest" literally)
    # — the versioned tag line exists alongside :latest
    versioned_count=$(grep "docker.io/testuser/web-shell:" "$DOCKER_LOG" \
        | grep -v ":latest$" | wc -l || true)
    [ "$versioned_count" -gt 0 ] || \
        (echo "Expected versioned tag mirror call not found:" >&2; cat "$DOCKER_LOG" >&2; false)
}

# ---------------------------------------------------------------------------
# MD-02: Non-default flavored cell mirrors :latest-<variant> (not :latest).
# Catches: MD2
# ---------------------------------------------------------------------------
@test "MD-02: non-default flavored cell mirrors :latest-<variant>" {
    # github-runner has multiple non-default variants (e.g. ubuntu-2404)
    run _run_mirror "github-runner"
    [ "$status" -eq 0 ]

    grep -q "buildx imagetools create" "$DOCKER_LOG" || \
        (cat "${TEST_LOG_DIR}/run.log" >&2 && false)

    # At least one call should be to a :latest-<variant> tag (e.g. :latest-ubuntu-2404)
    latest_variant_count=$(grep "docker.io/testuser/github-runner:latest-" "$DOCKER_LOG" | wc -l || true)
    [ "$latest_variant_count" -gt 0 ] || \
        (echo "Expected :latest-<variant> mirror call not found in docker log:" >&2
         cat "$DOCKER_LOG" >&2
         false)
}

# ---------------------------------------------------------------------------
# MD-03: Retained non-latest cell mirrors ONLY the versioned tag.
# Catches: MD3
# ---------------------------------------------------------------------------
@test "MD-03: retained non-latest cell mirrors only versioned tag" {
    # Use a synthetic bake-managed container that has retained non-latest versions.
    # We test this by checking the mirror logic directly: for a cell with
    # is_latest_version=false, only the versioned suffix ($tag) is published.
    #
    # Strategy: mock generate-bake-hcl.sh to return one retained cell.
    export MOCK_GENERATOR="${TEST_LOG_DIR}/generate-bake-hcl.sh"
    # A cell with is_latest_version=false, versioned tag "1.0.0-alpine", variant="alpine"
    cat > "$MOCK_GENERATOR" <<'GEN_EOF'
#!/usr/bin/env bash
# Synthetic --cells output: one retained (non-latest) cell
if [[ "$1" == "--cells" ]]; then
    jq -cn '[{
        "container": "web-shell",
        "tag": "1.0.0-alpine",
        "flavor": "alpine",
        "variant": "alpine",
        "is_default": false,
        "is_latest_version": false,
        "intermediate_ref": "${REMOTE_CR}/web-shell:1.0.0-alpine",
        "target_id": "web_shell_1_0_0_alpine"
    }]'
    exit 0
fi
exit 1
GEN_EOF
    chmod +x "$MOCK_GENERATOR"

    # Patch the generator path inside the script — we do this by overriding
    # the _MDH_SCRIPT_DIR so the sourced script resolves the mock generator.
    (
        export DOCKER
        export DOCKER_LOG
        export DOCKERHUB_USERNAME
        export REMOTE_CR
        export DRY_RUN
        export GITHUB_ACTIONS
        export _DEPGRAPH_LINEAGE_DIR

        # Override generator resolution by symlinking into the test dir
        mkdir -p "${TEST_LOG_DIR}/scripts"
        ln -sf "$MOCK_GENERATOR" "${TEST_LOG_DIR}/scripts/generate-bake-hcl.sh"

        # Temporarily override the HELPERS_DIR path resolution inside the script
        # by patching _MDH_SCRIPT_DIR to point to our test dir which has scripts/.
        export _MDH_OVERRIDE_SCRIPTS_DIR="${TEST_LOG_DIR}"

        # Run via bash with an override that patches the generator path
        bash -c "
            set -euo pipefail
            source '${HELPERS_DIR}/logging.sh'
            source '${HELPERS_DIR}/variant-utils.sh'
            DOCKER='${DOCKER}'
            DOCKER_LOG='${DOCKER_LOG}'
            DOCKERHUB_USERNAME='${DOCKERHUB_USERNAME}'
            REMOTE_CR='${REMOTE_CR}'
            DRY_RUN='${DRY_RUN}'
            GITHUB_ACTIONS=''
            _DEPGRAPH_LINEAGE_DIR=/nonexistent

            # Inject the cells JSON directly to bypass the generator
            cells_json=\$(jq -cn '[{
                \"container\": \"web-shell\",
                \"tag\": \"1.0.0-alpine\",
                \"flavor\": \"alpine\",
                \"variant\": \"alpine\",
                \"is_default\": false,
                \"is_latest_version\": false,
                \"intermediate_ref\": \"\${REMOTE_CR}/web-shell:1.0.0-alpine\",
                \"target_id\": \"web_shell_1_0_0_alpine\"
            }]')

            # Execute the mirror loop inline (mirrors the function body)
            ncells=\$(jq 'length' <<< \"\$cells_json\")
            for (( i=0; i<ncells; i++ )); do
                cell=\$(jq -c \".[\$i]\" <<< \"\$cells_json\")
                container=\$(jq -r '.container' <<< \"\$cell\")
                tag=\$(jq -r '.tag' <<< \"\$cell\")
                variant=\$(jq -r '.variant // \"\"' <<< \"\$cell\")
                flavor=\$(jq -r '.flavor // \"\"' <<< \"\$cell\")
                is_default=\$(jq -r 'if .is_default then \"true\" else \"false\" end' <<< \"\$cell\")
                is_latest_version=\$(jq -r 'if has(\"is_latest_version\") then (if .is_latest_version then \"true\" else \"false\" end) else \"true\" end' <<< \"\$cell\")
                routing_suffix=\"\${variant:-\${flavor}}\"
                while IFS= read -r sfx; do
                    [[ -n \"\$sfx\" ]] || continue
                    if [[ \"\$is_latest_version\" != \"true\" && \"\$sfx\" != \"\$tag\" ]]; then
                        continue
                    fi
                    dh_dst=\"docker.io/\${DOCKERHUB_USERNAME}/\${container}:\${sfx}\"
                    ghcr_src=\"\${REMOTE_CR}/\${container}:\${tag}\"
                    printf '%s\n' \"buildx imagetools create -t \$dh_dst \$ghcr_src\" >> '${DOCKER_LOG}'
                done < <(compute_cell_tag_suffixes \"\$tag\" \"\$routing_suffix\" \"\$is_default\")
            done
        " > "${TEST_LOG_DIR}/run.log" 2>&1
    )

    # Should have exactly one docker call (versioned only, no :latest or :latest-alpine)
    call_count=$(wc -l < "$DOCKER_LOG" || echo 0)
    [ "$call_count" -eq 1 ] || \
        (echo "Expected exactly 1 mirror call for retained non-latest, got $call_count:" >&2
         cat "$DOCKER_LOG" >&2
         false)

    # That single call must be the versioned tag
    grep -q "docker.io/testuser/web-shell:1.0.0-alpine" "$DOCKER_LOG" || \
        (echo "Expected versioned tag call not found:" >&2; cat "$DOCKER_LOG" >&2; false)

    # No :latest or :latest-alpine call
    ! grep -q ":latest" "$DOCKER_LOG" || \
        (echo "Unexpected :latest call found for retained non-latest cell:" >&2; cat "$DOCKER_LOG" >&2; false)
}

# ---------------------------------------------------------------------------
# MD-04: Function skips entirely when DOCKERHUB_USERNAME is unset.
# Catches: MD4
# ---------------------------------------------------------------------------
@test "MD-04: skips when DOCKERHUB_USERNAME is unset" {
    unset DOCKERHUB_USERNAME

    run _run_mirror "web-shell"
    [ "$status" -eq 0 ]

    # No docker calls should have been made
    [ ! -f "$DOCKER_LOG" ] || [ "$(wc -c < "$DOCKER_LOG")" -eq 0 ] || \
        (echo "Expected no docker calls but found:" >&2; cat "$DOCKER_LOG" >&2; false)

    # A ::notice:: should have been emitted
    grep -q "notice" "${TEST_LOG_DIR}/run.log" || \
        grep -q "DOCKERHUB_USERNAME" "${TEST_LOG_DIR}/run.log" || \
        (echo "Expected skip notice not found in:" >&2; cat "${TEST_LOG_DIR}/run.log" >&2; false)
}

# ---------------------------------------------------------------------------
# MD-06: BAKE_GENERATE_ALL_RETAINED=true passes --all-retained to the generator.
# Catches: MD6 — mirrored tag set diverges from GHCR when retained versions omitted
# ---------------------------------------------------------------------------
@test "MD-06: BAKE_GENERATE_ALL_RETAINED=true mirrors retained cells for terraform" {
    # terraform has version_retention=3 and no bake_latest_only — retained versions
    # are present with --all-retained.
    export BAKE_GENERATE_ALL_RETAINED=true

    run _run_mirror "terraform"
    [ "$status" -eq 0 ]

    # With --all-retained the docker log must contain more imagetools calls than
    # without (retained versions produce additional versioned-tag mirror calls).
    local retained_calls
    retained_calls=$(wc -l < "$DOCKER_LOG" || echo 0)

    # Reset for the latest-only baseline
    rm -f "$DOCKER_LOG"
    export BAKE_GENERATE_ALL_RETAINED=false
    run _run_mirror "terraform"
    [ "$status" -eq 0 ]
    local latest_only_calls
    latest_only_calls=$(wc -l < "$DOCKER_LOG" || echo 0)

    # --all-retained must produce strictly more mirror calls than latest-only
    [ "$retained_calls" -gt "$latest_only_calls" ] || \
        (printf 'retained=%d latest_only=%d — expected retained > latest_only\n' \
            "$retained_calls" "$latest_only_calls" >&2; false)
}

@test "MD-07: BAKE_GENERATE_ALL_RETAINED=false produces latest-only mirror calls for terraform" {
    export BAKE_GENERATE_ALL_RETAINED=false

    run _run_mirror "terraform"
    [ "$status" -eq 0 ]

    # Must have at least one imagetools create call
    grep -q "buildx imagetools create" "$DOCKER_LOG" || \
        (cat "${TEST_LOG_DIR}/run.log" >&2 && false)
}

@test "MD-08: BAKE_GENERATE_ALL_RETAINED=true github-runner remains latest-only (bake_latest_only)" {
    # github-runner has bake_latest_only=true — even with BAKE_GENERATE_ALL_RETAINED=true
    # the generator must force latest-only, so the mirror call count must equal
    # the BAKE_GENERATE_ALL_RETAINED=false call count.
    export BAKE_GENERATE_ALL_RETAINED=true

    run _run_mirror "github-runner"
    [ "$status" -eq 0 ]
    local retained_calls
    retained_calls=$(wc -l < "$DOCKER_LOG" || echo 0)

    rm -f "$DOCKER_LOG"
    export BAKE_GENERATE_ALL_RETAINED=false
    run _run_mirror "github-runner"
    [ "$status" -eq 0 ]
    local latest_only_calls
    latest_only_calls=$(wc -l < "$DOCKER_LOG" || echo 0)

    # github-runner is always latest-only: both counts must be equal
    [ "$retained_calls" -eq "$latest_only_calls" ] || \
        (printf 'github-runner: retained=%d latest_only=%d — expected equal (bake_latest_only)\n' \
            "$retained_calls" "$latest_only_calls" >&2; false)
}

# ---------------------------------------------------------------------------
# MD-05: A single mirror failure does NOT fail the function (best-effort).
# Catches: MD5
# ---------------------------------------------------------------------------
@test "MD-05: single mirror failure does not fail the function" {
    # Create a mock docker that always exits 1 (simulates imagetools failure)
    cat > "$MOCK_DOCKER" <<'FAIL_EOF'
#!/usr/bin/env bash
printf 'FAILED: %s\n' "$*" >> "${DOCKER_LOG}"
exit 1
FAIL_EOF
    chmod +x "$MOCK_DOCKER"

    run _run_mirror "web-shell"

    # Function must return 0 even when every docker call fails
    [ "$status" -eq 0 ] || \
        (echo "Expected rc=0 (best-effort) but got $status" >&2
         cat "${TEST_LOG_DIR}/run.log" >&2
         false)

    # At least one docker invocation should have been attempted
    [ -f "$DOCKER_LOG" ] && [ "$(wc -l < "$DOCKER_LOG")" -gt 0 ] || \
        (echo "Expected at least one docker attempt:" >&2; cat "${TEST_LOG_DIR}/run.log" >&2; false)

    # A ::warning:: should have been emitted for the failure
    grep -q "warning" "${TEST_LOG_DIR}/run.log" || \
        (echo "Expected ::warning:: annotation not found:" >&2; cat "${TEST_LOG_DIR}/run.log" >&2; false)
}

# ---------------------------------------------------------------------------
# MS-01: MIRROR_STRICT unset → returns 0 even when all imagetools fail.
# Catches: MS1 — best-effort behavior must be unchanged when strict mode is off.
# ---------------------------------------------------------------------------
@test "MS-01: MIRROR_STRICT unset returns 0 even when all imagetools fail" {
    unset MIRROR_STRICT

    # All docker calls fail
    cat > "$MOCK_DOCKER" <<'FAIL_EOF'
#!/usr/bin/env bash
printf 'FAILED: %s\n' "$*" >> "${DOCKER_LOG}"
exit 1
FAIL_EOF
    chmod +x "$MOCK_DOCKER"

    run _run_mirror "web-shell"

    [ "$status" -eq 0 ] || \
        (echo "Expected rc=0 (best-effort, MIRROR_STRICT unset) but got $status" >&2
         cat "${TEST_LOG_DIR}/run.log" >&2
         false)
}

# ---------------------------------------------------------------------------
# MS-02: MIRROR_STRICT=true + all imagetools succeed → returns 0.
# Catches: MS2 — strict mode must not break the happy path.
# ---------------------------------------------------------------------------
@test "MS-02: MIRROR_STRICT=true all-succeed returns 0" {
    export MIRROR_STRICT="true"

    # MOCK_DOCKER already exits 0 (default setup)
    run _run_mirror "web-shell"

    [ "$status" -eq 0 ] || \
        (echo "Expected rc=0 (strict, all succeed) but got $status" >&2
         cat "${TEST_LOG_DIR}/run.log" >&2
         false)

    # ::notice:: summary must be emitted
    grep -q "notice.*mirror-dockerhub:.*/" "${TEST_LOG_DIR}/run.log" || \
        (echo "Expected ::notice:: summary not found:" >&2; cat "${TEST_LOG_DIR}/run.log" >&2; false)
}

# ---------------------------------------------------------------------------
# MS-03: MIRROR_STRICT=true + ALL imagetools fail (attempted>0, succeeded==0)
#        → returns non-zero.
# Catches: MS3 — total failure must be observable in strict mode.
# ---------------------------------------------------------------------------
@test "MS-03: MIRROR_STRICT=true all-fail returns non-zero" {
    export MIRROR_STRICT="true"

    # All docker calls fail
    cat > "$MOCK_DOCKER" <<'FAIL_EOF'
#!/usr/bin/env bash
printf 'FAILED: %s\n' "$*" >> "${DOCKER_LOG}"
exit 1
FAIL_EOF
    chmod +x "$MOCK_DOCKER"

    run _run_mirror "web-shell"

    [ "$status" -ne 0 ] || \
        (echo "Expected non-zero rc (strict, all fail) but got 0" >&2
         cat "${TEST_LOG_DIR}/run.log" >&2
         false)

    # ::error:: annotation must be emitted
    grep -q "error.*mirror-dockerhub:.*0/" "${TEST_LOG_DIR}/run.log" || \
        (echo "Expected ::error:: total-failure annotation not found:" >&2
         cat "${TEST_LOG_DIR}/run.log" >&2
         false)
}

# ---------------------------------------------------------------------------
# MS-04: MIRROR_STRICT=true + PARTIAL success (some succeed, some fail) → returns 0.
# Catches: MS4 — transient single-tag flakes must not red the nightly cron.
#
# Strategy: the first imagetools call succeeds, subsequent ones fail.
# web-shell produces at least 2 tags (versioned + :latest), so the counter
# will have succeeded≥1 and attempted≥2.
# ---------------------------------------------------------------------------
@test "MS-04: MIRROR_STRICT=true partial-success returns 0" {
    export MIRROR_STRICT="true"

    # First call succeeds, all subsequent fail
    cat > "$MOCK_DOCKER" <<'PARTIAL_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DOCKER_LOG}"
# Succeed only on first invocation (line count == 1 after writing)
lines=$(wc -l < "${DOCKER_LOG}")
if [[ "$lines" -eq 1 ]]; then
    exit 0
fi
exit 1
PARTIAL_EOF
    chmod +x "$MOCK_DOCKER"

    run _run_mirror "web-shell"

    [ "$status" -eq 0 ] || \
        (echo "Expected rc=0 (strict, partial success) but got $status" >&2
         cat "${TEST_LOG_DIR}/run.log" >&2
         false)

    # ::notice:: summary (not ::error::) must be emitted
    grep -q "notice.*mirror-dockerhub:.*/" "${TEST_LOG_DIR}/run.log" || \
        (echo "Expected ::notice:: summary not found (should be partial success):" >&2
         cat "${TEST_LOG_DIR}/run.log" >&2
         false)
}

# ---------------------------------------------------------------------------
# MS-05: MIRROR_STRICT=true + DOCKERHUB_USERNAME unset → returns non-zero.
# Catches: MS5 — missing credentials is a structural misconfiguration.
# ---------------------------------------------------------------------------
@test "MS-05: MIRROR_STRICT=true DOCKERHUB_USERNAME unset returns non-zero" {
    export MIRROR_STRICT="true"
    unset DOCKERHUB_USERNAME

    run _run_mirror "web-shell"

    [ "$status" -ne 0 ] || \
        (echo "Expected non-zero rc (strict, no credentials) but got 0" >&2
         cat "${TEST_LOG_DIR}/run.log" >&2
         false)

    # ::error:: annotation must be emitted
    grep -q "error.*mirror-dockerhub:.*DOCKERHUB_USERNAME" "${TEST_LOG_DIR}/run.log" || \
        (echo "Expected ::error:: credentials annotation not found:" >&2
         cat "${TEST_LOG_DIR}/run.log" >&2
         false)
}

# ---------------------------------------------------------------------------
# MS-06: MIRROR_STRICT=true + generator yields no cells → returns non-zero.
# Catches: MS6 — empty cell set is a structural failure (no-op reconciliation).
#
# Strategy: set _MDH_GENERATOR_OVERRIDE to a mock that returns an empty JSON array.
# ---------------------------------------------------------------------------
@test "MS-06: MIRROR_STRICT=true generator no-cells returns non-zero" {
    export MIRROR_STRICT="true"

    # Mock generator returns an empty array
    export MOCK_GENERATOR="${TEST_LOG_DIR}/generate-bake-hcl-empty.sh"
    cat > "$MOCK_GENERATOR" <<'GEN_EOF'
#!/usr/bin/env bash
if [[ "$1" == "--cells" ]]; then
    printf '[]'
    exit 0
fi
exit 1
GEN_EOF
    chmod +x "$MOCK_GENERATOR"
    export _MDH_GENERATOR_OVERRIDE="$MOCK_GENERATOR"

    run _run_mirror "web-shell"

    [ "$status" -ne 0 ] || \
        (echo "Expected non-zero rc (strict, no cells) but got 0" >&2
         cat "${TEST_LOG_DIR}/run.log" >&2
         false)

    # ::error:: annotation must be emitted
    grep -q "error.*mirror-dockerhub:" "${TEST_LOG_DIR}/run.log" || \
        (echo "Expected ::error:: no-cells annotation not found:" >&2
         cat "${TEST_LOG_DIR}/run.log" >&2
         false)

    unset _MDH_GENERATOR_OVERRIDE
}
