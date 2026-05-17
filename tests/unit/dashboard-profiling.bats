#!/usr/bin/env bats

# Tests for DASHBOARD_PROFILE instrumentation in generate-dashboard.sh
#
# Verifies four contracts:
#  1. Profiling-ON: all 7 PROFILE keys emitted to stderr
#  2. Profiling-ON: PROFILE key=value lines are parseable
#  3. Profiling-OFF: no PROFILE lines on stderr, byte-identical yml to profiling-ON
#  4. STRUCTURAL: set-e-safe || _rc=$? idiom present on all three shims (no bare form)
#  5. Profiling data does NOT appear in containers.yml
#  6. STRUCTURAL: curl shim stdout passthrough -- no pipe/redirect/capture on wrapped call

setup() {
    TEST_DIR=$(mktemp -d)
    ORIG_DIR="$PWD"
    cd "$TEST_DIR" || exit 1

    # Source in same pattern as dashboard-helpers.bats.
    # IMPORTANT: generate-dashboard.sh runs `trap '...' EXIT` at the top level,
    # which replaces bats' own EXIT trap (bats_teardown_trap as-exit-trap).
    # Without the trap, failing tests exit without writing the "not ok N" TAP line
    # (0 tests executed).  We save and restore bats' trap around the source call.
    local _saved_exit_trap
    _saved_exit_trap=$(trap -p EXIT 2>/dev/null) || true
    source "$ORIG_DIR/helpers/logging.sh" 2>/dev/null || true
    source "$ORIG_DIR/helpers/variant-utils.sh" 2>/dev/null || true
    source "$ORIG_DIR/generate-dashboard.sh" 2>/dev/null || true
    # Capture the trivy cache file created by generate-dashboard.sh at source-time
    # (line: TRIVY_CACHE_FILE=$(mktemp ...)).  setup() will overwrite TRIVY_CACHE_FILE
    # below with its own tmpfile; the file created at source-time would orphan in /tmp
    # unless we save and clean it.  The source-time EXIT trap that would have cleaned
    # it is about to be replaced, so we own this cleanup.
    _SOURCED_TRIVY_CACHE="${TRIVY_CACHE_FILE:-}"
    # Restore bats' EXIT trap, which generate-dashboard.sh just replaced.
    if [[ -n "$_saved_exit_trap" ]]; then
        eval "$_saved_exit_trap" 2>/dev/null || true
    else
        trap - EXIT 2>/dev/null || true
    fi

    # Override SCRIPT_DIR after sourcing
    export SCRIPT_DIR="$TEST_DIR"

    # ---- Fixture: minimal non-variant container dir + lineage ----
    mkdir -p "$TEST_DIR/myprof"
    printf '#!/bin/bash\necho "2.0.0"\n' > "$TEST_DIR/myprof/version.sh"
    chmod +x "$TEST_DIR/myprof/version.sh"
    printf 'FROM alpine:3.19\n' > "$TEST_DIR/myprof/Dockerfile"

    mkdir -p "$TEST_DIR/.build-lineage"
    cat > "$TEST_DIR/.build-lineage/myprof-2.0.0.json" <<'EOF'
{
  "container": "myprof",
  "version": "2.0.0",
  "build_digest": "sha256:prof123abc",
  "oci_subject_digest": "sha256:subjdigest456",
  "base_image_ref": "alpine:3.19",
  "built_at": "2026-05-17T00:00:00+00:00"
}
EOF

    # Output dirs expected by generate_data
    mkdir -p "$TEST_DIR/docs/site/_data"
    mkdir -p "$TEST_DIR/docs/site/_containers"

    DATA_FILE="$TEST_DIR/docs/site/_data/containers.yml"
    CONTAINERS_DIR="$TEST_DIR/docs/site/_containers"
    STATS_FILE="$TEST_DIR/docs/site/_data/stats.yml"
    TRIVY_CACHE_FILE=$(mktemp)
    export DATA_FILE CONTAINERS_DIR STATS_FILE TRIVY_CACHE_FILE

    # ---- Mock external helpers (same pattern as dashboard-helpers.bats) ----
    get_current_published_version() { echo "2.0.0"; }
    get_container_build_status()     { echo "success"; }
    populate_container_build_status_cache() { :; }
    get_dockerhub_stats()            { echo "pulls:10 stars:2"; }
    get_ghcr_sizes()                 { echo ""; }
    ghcr_get_manifest_sizes()        { echo ""; }
    get_sbom_summary()               { echo "{}"; }
    get_sbom_packages()              { echo "{}"; }
    get_changelog()                  { echo "{}"; }
    get_build_history()              { echo "[]"; }
    build_trivy_category()           { echo "myprof:2.0.0"; }
    get_attestation_id()             { echo "att-prof-id"; }
    get_attestation_url()            { echo "https://example.com/att/att-prof-id"; }
    get_trivy_summary()              { echo '{"last_scan":"2026-05-17T12:00:00Z","counts":{"critical":0,"high":0,"medium":0,"low":1,"info":0},"top_advisories":[]}'; }
    generate_container_page()        { :; }
    fetch_recent_activity()          { echo "[]"; }
    calculate_build_success_rate()   { echo "3:3:100"; }
    write_stats_file()               { :; }
    export -f get_current_published_version get_container_build_status \
              populate_container_build_status_cache get_dockerhub_stats \
              get_ghcr_sizes ghcr_get_manifest_sizes get_sbom_summary \
              get_sbom_packages get_changelog get_build_history \
              build_trivy_category get_attestation_id get_attestation_url \
              get_trivy_summary generate_container_page fetch_recent_activity \
              calculate_build_success_rate write_stats_file
}

teardown() {
    cd "$ORIG_DIR" || true
    # Clean both the setup()-assigned trivy cache file AND the one created by
    # generate-dashboard.sh at source-time (saved in _SOURCED_TRIVY_CACHE).
    # The source-time EXIT trap is replaced in setup() so we must clean it here.
    rm -f "${TRIVY_CACHE_FILE:-}" 2>/dev/null || true
    rm -f "${_SOURCED_TRIVY_CACHE:-}" 2>/dev/null || true
    rm -rf "$TEST_DIR"
}

# ===================================================================
# @test 1: profiling-ON emits all 7 PROFILE keys on stderr
# ===================================================================

@test "profiling-ON: all 7 PROFILE keys present in stderr" {
    # Mutation caught: deleting or renaming any of the 7 printf 'PROFILE X' lines
    # in the profiling summary block of generate-dashboard.sh makes one grep fail.
    # Capture stderr separately; stdout is suppressed (yml written to file)
    DASHBOARD_PROFILE=1 generate_data 2>"$TEST_DIR/prof_stderr.txt"

    prof_out="$TEST_DIR/prof_stderr.txt"

    # All 7 required PROFILE lines
    grep -q '^PROFILE step_wall_s=' "$prof_out"
    grep -q '^PROFILE curl '       "$prof_out"
    grep -q '^PROFILE curl_lat '   "$prof_out"
    grep -q '^PROFILE forks '      "$prof_out"
    grep -q '^PROFILE phase '      "$prof_out"
    grep -q '^PROFILE top_containers' "$prof_out"
    grep -q '^PROFILE END$'        "$prof_out"
}

# ===================================================================
# @test 2: profiling-ON emits parseable key=value lines
# ===================================================================

@test "profiling-ON: PROFILE lines have correct key=value format" {
    # Mutation caught: changing any key name (e.g. calls= -> count=, jq_calls= -> jq=)
    # in the printf statements of the profiling summary block makes a grep fail.
    DASHBOARD_PROFILE=1 generate_data 2>"$TEST_DIR/prof_stderr2.txt"

    prof_out="$TEST_DIR/prof_stderr2.txt"

    # step_wall_s must be an integer
    step_val=$(grep '^PROFILE step_wall_s=' "$prof_out" | sed 's/PROFILE step_wall_s=//')
    [[ "$step_val" =~ ^[0-9]+$ ]]

    # curl line has calls= key
    grep -q 'PROFILE curl calls=' "$prof_out"

    # curl_lat line has lt1= key
    grep -q 'PROFILE curl_lat lt1=' "$prof_out"

    # forks line has jq_calls= and yq_calls= keys
    grep -q 'PROFILE forks jq_calls=' "$prof_out"
    grep -q 'yq_calls=' "$prof_out"

    # phase line has setup_s= loop_s= finalize_s= keys
    grep -q 'PROFILE phase setup_s=' "$prof_out"
    grep -q 'loop_s=' "$prof_out"
    grep -q 'finalize_s=' "$prof_out"
}

# ===================================================================
# @test 3: profiling-OFF: no PROFILE lines; yml byte-identical to profiling-ON
# ===================================================================

@test "profiling-OFF: no PROFILE output; yml byte-identical to profiling-ON run" {
    # Mutation caught: any code that writes PROFILE lines unconditionally (outside the
    # _PROF_ENABLED gate) makes the stderr check fail; any stdout side-effect of the
    # shims (writing to DATA_FILE) makes the cmp check fail.  This is the primary
    # differential lock between profiling-ON and profiling-OFF behavior.
    # Run with profiling ON first; capture yml
    DASHBOARD_PROFILE=1 generate_data 2>/dev/null
    cp "$DATA_FILE" "$TEST_DIR/containers_prof_on.yml"

    # Remove yml so next run recreates it cleanly
    rm -f "$DATA_FILE"

    # Run with profiling OFF
    unset DASHBOARD_PROFILE
    generate_data 2>"$TEST_DIR/off_stderr.txt"
    cp "$DATA_FILE" "$TEST_DIR/containers_prof_off.yml"

    # No PROFILE line must appear in stderr of the OFF run
    if grep -q 'PROFILE ' "$TEST_DIR/off_stderr.txt" 2>/dev/null; then
        echo "FAIL: PROFILE line found in stderr when DASHBOARD_PROFILE unset:"
        grep 'PROFILE ' "$TEST_DIR/off_stderr.txt"
        return 1
    fi

    # yml output must be byte-identical (zero behavior change)
    if ! cmp -s "$TEST_DIR/containers_prof_on.yml" "$TEST_DIR/containers_prof_off.yml"; then
        echo "FAIL: containers.yml differs between profiling-ON and profiling-OFF runs"
        diff "$TEST_DIR/containers_prof_on.yml" "$TEST_DIR/containers_prof_off.yml" || true
        return 1
    fi
}

# ===================================================================
# @test 4: STRUCTURAL: curl shim stdout passthrough
# ===================================================================

@test "STRUCTURAL: curl shim stdout passthrough -- no pipe/redirect/capture on wrapped call" {
    # STRUCTURAL lock for stdout fidelity. Behavioral corruption is not catchable
    # through the mocked size path; locked at source: the shim must pass the wrapped
    # command's stdout through verbatim (no pipe/redirect/capture on the
    # `command curl` line).
    local script="$ORIG_DIR/generate-dashboard.sh"

    # The wrapped-call line must be present as an EXECUTABLE line.
    # Anchored to `^[[:space:]]*command[[:space:]]+curl` so comment lines (starting
    # with `#`) are excluded — the comment-hole is closed at the presence check too.
    local safe_line=0
    safe_line=$(grep -cE '^[[:space:]]*command[[:space:]]+curl[[:space:]]+"[$]@"[[:space:]]*\|\|[[:space:]]*_rc=[$][?]' "$script" 2>/dev/null) || true
    if [[ "$safe_line" -lt 1 ]]; then
        echo "FAIL: no executable 'command curl \"\$@\" || _rc=\$?' line found (comment lines excluded)"
        return 1
    fi

    # No stdout pipe on the command curl line (exclude || which is OR, not pipe;
    # pattern \|[^|] matches single pipe followed by non-pipe, e.g. "| sed")
    local piped=0
    piped=$(grep -cE 'command curl "\$@"[[:space:]]*\|[^|]' "$script" 2>/dev/null) || true
    if [[ "$piped" -ne 0 ]]; then
        echo "FAIL: command curl stdout piped ($piped occurrences)"
        return 1
    fi

    # No redirect on the command curl line
    local redirected=0
    redirected=$(grep -cE 'command curl "\$@"[[:space:]]*>' "$script" 2>/dev/null) || true
    if [[ "$redirected" -ne 0 ]]; then
        echo "FAIL: command curl stdout redirected ($redirected occurrences)"
        return 1
    fi

    # No capture (command curl inside $(...))
    local captured=0
    captured=$(grep -cE '\$\(command curl' "$script" 2>/dev/null) || true
    if [[ "$captured" -ne 0 ]]; then
        echo "FAIL: command curl stdout captured in \$() ($captured occurrences)"
        return 1
    fi
}

# ===================================================================
# @test 5: profiling data is NOT written into yml (no PROFILE in data file)
# ===================================================================

@test "profiling-ON: PROFILE telemetry does not appear in containers.yml" {
    # Mutation caught: any code that writes profiling output to stdout (DATA_FILE)
    # instead of stderr makes the `*"PROFILE "* ` check fail.
    DASHBOARD_PROFILE=1 generate_data 2>/dev/null

    yml_content=$(cat "$DATA_FILE")

    # Profiling output must not leak into the data file
    if [[ "$yml_content" == *"PROFILE "* ]]; then
        echo "FAIL: PROFILE string found in containers.yml"
        grep 'PROFILE' "$DATA_FILE" || true
        return 1
    fi
}

# ===================================================================
# @test 6: STRUCTURAL: set-e-safe || _rc=$? idiom on all three shims
# ===================================================================

@test "STRUCTURAL: set-e-safe || _rc=\$? idiom present on all three shims -- no bare form" {
    # STRUCTURAL lock. The runtime set-e abort this guards is NOT reproducible in the
    # bats harness (errexit is not effective in generate_data's $(...) call path), so
    # a behavioral RED->GREEN test is impossible and would be vacuous. The invariant is
    # therefore locked at SOURCE level: the set-e-safe `|| _rc=$?` idiom must be
    # present on all three shims; the bare `command X; _rc=$?` form is forbidden.
    # Runtime behavior is additionally guarded by code review (Test Validity Gate /
    # codex). Reverting the fix changes this source text -> this test goes RED
    # (empirically verified).
    local script="$ORIG_DIR/generate-dashboard.sh"

    # Each shim must have the safe form on an EXECUTABLE line.
    # Patterns are anchored to `^[[:space:]]*command[[:space:]]+X` so a comment
    # line (which starts with `#`, possibly after spaces) can NEVER satisfy them.
    # This closes the "comment hole": a doc comment containing the idiom text would
    # NOT satisfy these patterns, so the lock cannot be gamed by adding a comment.
    #
    # Safe-idiom pattern: `^[[:space:]]*command[[:space:]]+X[[:space:]]+"$@"[[:space:]]*||[[:space:]]*_rc=$?`
    # (EOL-anchored so "|| _rc=$? # comment" still matches — only leading `#` is excluded)
    #
    # Pattern: `local var=0; var=$(grep ...) || true` -- safe under set -eET:
    # grep exits 1 on no-match; || true absorbs it; var retains grep's "0" output.
    local curl_safe=0 jq_safe=0 yq_safe=0
    curl_safe=$(grep -cE '^[[:space:]]*command[[:space:]]+curl[[:space:]]+"[$]@"[[:space:]]*\|\|[[:space:]]*_rc=[$][?]' "$script" 2>/dev/null) || true
    jq_safe=$(grep -cE   '^[[:space:]]*command[[:space:]]+jq[[:space:]]+"[$]@"[[:space:]]*\|\|[[:space:]]*_rc=[$][?]'   "$script" 2>/dev/null) || true
    yq_safe=$(grep -cE   '^[[:space:]]*command[[:space:]]+yq[[:space:]]+"[$]@"[[:space:]]*\|\|[[:space:]]*_rc=[$][?]'   "$script" 2>/dev/null) || true

    if [[ "$curl_safe" -lt 1 ]]; then
        echo "FAIL: curl shim missing executable || _rc=\$? idiom (comment lines do not count)"
        return 1
    fi
    if [[ "$jq_safe" -lt 1 ]]; then
        echo "FAIL: jq shim missing executable || _rc=\$? idiom (comment lines do not count)"
        return 1
    fi
    if [[ "$yq_safe" -lt 1 ]]; then
        echo "FAIL: yq shim missing executable || _rc=\$? idiom (comment lines do not count)"
        return 1
    fi

    # No bare executable form allowed.
    # Bare pattern: `^[[:space:]]*command[[:space:]]+X[[:space:]]+"$@"[[:space:]]*$`
    # (line-ends immediately after "$@", possibly with trailing spaces — no `||`).
    # A comment mentioning the bare form would start with `#` and cannot match.
    local curl_bare=0 jq_bare=0 yq_bare=0
    curl_bare=$(grep -cE '^[[:space:]]*command[[:space:]]+curl[[:space:]]+"[$]@"[[:space:]]*$' "$script" 2>/dev/null) || true
    jq_bare=$(grep -cE   '^[[:space:]]*command[[:space:]]+jq[[:space:]]+"[$]@"[[:space:]]*$'   "$script" 2>/dev/null) || true
    yq_bare=$(grep -cE   '^[[:space:]]*command[[:space:]]+yq[[:space:]]+"[$]@"[[:space:]]*$'   "$script" 2>/dev/null) || true

    if [[ "$curl_bare" -ne 0 ]]; then
        echo "FAIL: curl has $curl_bare bare executable 'command curl \"\$@\"' line without || _rc=\$?"
        return 1
    fi
    if [[ "$jq_bare" -ne 0 ]]; then
        echo "FAIL: jq has $jq_bare bare executable 'command jq \"\$@\"' line without || _rc=\$?"
        return 1
    fi
    if [[ "$yq_bare" -ne 0 ]]; then
        echo "FAIL: yq has $yq_bare bare executable 'command yq \"\$@\"' line without || _rc=\$?"
        return 1
    fi
}
