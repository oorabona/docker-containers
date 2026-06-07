#!/usr/bin/env bats
# Unit tests for _compute_cell_build_args — UPSTREAM_VERSION derivation (step 4).
#
# These tests verify the deterministic tag-suffix stripping logic introduced to
# prevent silent wrong-version builds (a live --upstream call can drift past the
# pinned cell tag).
#
# Strategy: write a thin driver script to $TEST_TEMP_DIR that:
#   1. Creates a minimal fake container dir with a controlled version.sh stub
#   2. Sources the generator's internal functions (skipping main())
#   3. Calls _compute_cell_build_args directly with controlled inputs
#   4. Prints the resulting JSON to stdout
# This avoids the ./make list container validation entirely.
#
# Mutation each test catches:
#   MU1: suffix strip reverted to live --upstream call → live drift possible
#   MU2: v-prefix stripped from upstream → sslh-like containers build wrong source
#   MU3: empty suffix short-circuit removed → upstream==version, still emits UPSTREAM_VERSION
#   MU4: garbage-suffix guard removed → mis-strip on containers without --tag-suffix support
#   MU4b: guard's end-match check removed → mis-strip when suffix present but non-matching
#   MU5: determinism broken — UPSTREAM_VERSION comes from live query, differs per run
#   MU6: declared-ARG gate removed → unused UPSTREAM_VERSION emitted for jekyll/wordpress/php

bats_require_minimum_version 1.5.0

load "../test_helper"

# ---------------------------------------------------------------------------
# Helper: write the driver script and run _compute_cell_build_args in isolation.
#
# Args:
#   $1  tag_suffix         — what version.sh --tag-suffix should echo
#                            (use "" for empty, a non-'-' string for garbage)
#   $2  cell_tag           — the version/tag passed as $version argument
#   $3  container          — container name (determines stub directory path)
#   $4  declares_upstream  — 1 (default) to include "ARG UPSTREAM_VERSION" in the
#                            stub Dockerfile; 0 to omit it (MU6 undeclared-ARG gate)
#
# Stdout: compact JSON from _compute_cell_build_args, or empty on error.
# Sets $status (0 = driver exited 0, 1 = driver exited non-zero).
# ---------------------------------------------------------------------------
_run_build_args_driver() {
    local tag_suffix="$1"
    local cell_tag="$2"
    local container="${3:-fakecontainer}"
    local declares_upstream="${4:-1}"

    local fake_root="$TEST_TEMP_DIR/fakeroot"
    mkdir -p "$fake_root/$container"

    # Minimal Dockerfile (no ARG NPROC so that step 7 is skipped cleanly).
    # ARG UPSTREAM_VERSION is included by default so emit-cases still pass;
    # pass declares_upstream=0 to omit it (MU6 undeclared-ARG gate test).
    if [[ "$declares_upstream" == "1" ]]; then
        printf 'FROM debian:stable-slim\nARG VERSION\nARG UPSTREAM_VERSION\n' \
            > "$fake_root/$container/Dockerfile"
    else
        printf 'FROM debian:stable-slim\nARG VERSION\n' \
            > "$fake_root/$container/Dockerfile"
    fi

    # version.sh stub — returns $tag_suffix for --tag-suffix, ignores everything else
    printf '#!/bin/bash\n' > "$fake_root/$container/version.sh"
    printf 'case "${1:-}" in\n' >> "$fake_root/$container/version.sh"
    printf '    --tag-suffix) echo %q; exit 0;;\n' "$tag_suffix" \
        >> "$fake_root/$container/version.sh"
    printf '    *) echo %q; exit 0;;\n' "$cell_tag" \
        >> "$fake_root/$container/version.sh"
    printf 'esac\n' >> "$fake_root/$container/version.sh"
    chmod +x "$fake_root/$container/version.sh"

    # config.yaml (empty build_args — avoids REMOTE_CR validator noise)
    printf 'image: %s\nbuild_args: {}\n' "$container" \
        > "$fake_root/$container/config.yaml"

    # Driver script: sources generator internals, calls _compute_cell_build_args
    local driver="$TEST_TEMP_DIR/driver_${RANDOM}.sh"
    printf '#!/usr/bin/env bash\n' > "$driver"
    printf 'set -euo pipefail\n' >> "$driver"
    printf 'export REMOTE_CR=ghcr.io/testowner\n' >> "$driver"
    printf 'export GITHUB_ACTIONS=""\n' >> "$driver"
    printf 'export _DEPGRAPH_LINEAGE_DIR=/nonexistent\n' >> "$driver"
    # Pre-define main() as a no-op so it is already defined when the generator
    # sources its own functions; bash will NOT override an already-defined function
    # when sourcing a file that also defines it ... unless the source file explicitly
    # redefines it.  The generator ends with `main "$@"` at the bottom level (not
    # inside a function), so we suppress execution by overriding with a wrapper that
    # sources in a subshell first:
    # Strategy: source the generator with set +e and a trap that ignores the
    # `main "$@"` call.  Cleanest: source only the function definitions by
    # commenting out the `main "$@"` call at the last line — we do this by
    # feeding the generator through grep -v to strip the `^main ` call line.
    # Strip the `main "$@"` call and the generator's own PROJECT_ROOT assignment
    # (line: PROJECT_ROOT="$(cd ...)") then prepend the correct PROJECT_ROOT.
    # This lets us place the stripped script in any temp directory without
    # needing SCRIPT_DIR to resolve to the real scripts/ dir.
    local gen_stripped="$TEST_TEMP_DIR/gen_stripped_${RANDOM}.sh"
    {
        printf '#!/usr/bin/env bash\n'
        printf '# Auto-generated by bake-generator-upstream-version.bats\n'
        printf 'PROJECT_ROOT=%q\n' "$PROJECT_ROOT"
        printf 'SCRIPT_DIR=%q\n' "$PROJECT_ROOT/scripts"
        grep -v '^main ' "$PROJECT_ROOT/scripts/generate-bake-hcl.sh" \
            | grep -v '^PROJECT_ROOT=' \
            | grep -v '^SCRIPT_DIR=' \
            | grep -v '^cd "\${PROJECT_ROOT}"'
    } > "$gen_stripped"

    printf 'source %q\n' "$gen_stripped" >> "$driver"
    # After sourcing, PROJECT_ROOT is the real project root (we injected it).
    # Override it now to point to our fake container tree so
    # _compute_cell_build_args resolves version.sh from the stub.
    printf 'PROJECT_ROOT=%q\n' "$fake_root" >> "$driver"
    # _compute_cell_build_args is now available; call it with controlled args.
    # Args: container version flavor build_flavor config_args_json df_path is_inline
    printf '_compute_cell_build_args %q %q "" "" "{}" %q 0\n' \
        "$container" "$cell_tag" "$fake_root/$container/Dockerfile" >> "$driver"
    chmod +x "$driver"

    run bash "$driver"
}

setup() {
    setup_temp_dir
    export ORIGINAL_PROJECT_ROOT="$PROJECT_ROOT"
}

teardown() {
    # TEST_TEMP_DIR cleanup (includes gen_stripped and driver scripts)
    teardown_temp_dir
    export PROJECT_ROOT="$ORIGINAL_PROJECT_ROOT"
}

# ---------------------------------------------------------------------------
# MU1 / MU5 — clean suffix strip: openresty-like 1.31.1.1-alpine → 1.31.1.1
# Catches: live --upstream call (MU1), non-determinism (MU5).
# ---------------------------------------------------------------------------
@test "MU1/MU5: clean suffix strip — 1.31.1.1-alpine with -alpine → UPSTREAM_VERSION=1.31.1.1" {
    _run_build_args_driver "-alpine" "1.31.1.1-alpine"
    [ "$status" -eq 0 ]

    local upstream
    upstream=$(echo "$output" | jq -r '.UPSTREAM_VERSION // empty')
    [ -n "$upstream" ]
    [ "$upstream" = "1.31.1.1" ]
}

# ---------------------------------------------------------------------------
# MU2 — v-prefix preserved: sslh-like v2.3.1-alpine → v2.3.1 (NOT 2.3.1)
# Catches: any code that strips the leading 'v' before or after suffix removal.
# ---------------------------------------------------------------------------
@test "MU2: v-prefix preserved — v2.3.1-alpine with -alpine → UPSTREAM_VERSION=v2.3.1" {
    _run_build_args_driver "-alpine" "v2.3.1-alpine"
    [ "$status" -eq 0 ]

    local upstream
    upstream=$(echo "$output" | jq -r '.UPSTREAM_VERSION // empty')
    [ -n "$upstream" ]
    [ "$upstream" = "v2.3.1" ]
}

# ---------------------------------------------------------------------------
# MU3 — empty suffix → upstream==version → UPSTREAM_VERSION omitted
# Catches: removing the upstream==version short-circuit check.
# web-shell style: version "1.7.7", --tag-suffix returns "".
# ---------------------------------------------------------------------------
@test "MU3: empty suffix — UPSTREAM_VERSION absent when version has no suffix" {
    _run_build_args_driver "" "1.7.7"
    [ "$status" -eq 0 ]

    local upstream
    upstream=$(echo "$output" | jq -r '.UPSTREAM_VERSION // empty')
    [ -z "$upstream" ]
}

# ---------------------------------------------------------------------------
# MU4 — garbage suffix guard: --tag-suffix returns a non-'-'-prefixed string
# Catches: removing the robustness guard that rejects non-'-'-prefixed suffixes.
# A version.sh without --tag-suffix falls through and returns its full tag.
# ---------------------------------------------------------------------------
@test "MU4: garbage suffix (no leading '-') → UPSTREAM_VERSION absent (no mis-strip)" {
    _run_build_args_driver "8.5.7-fpm-alpine" "8.5.7-fpm-alpine"
    [ "$status" -eq 0 ]

    local upstream
    upstream=$(echo "$output" | jq -r '.UPSTREAM_VERSION // empty')
    [ -z "$upstream" ]
}

# ---------------------------------------------------------------------------
# MU4b — suffix valid format but version does not end with it → guard rejects
# Catches: removing the "version ends with suffix" check from the guard.
# suffix="-fpm" but version="1.2.3-alpine" → no match → treat as no-suffix.
# ---------------------------------------------------------------------------
@test "MU4b: suffix '-fpm' but version '1.2.3-alpine' (no tail match) → UPSTREAM_VERSION absent" {
    _run_build_args_driver "-fpm" "1.2.3-alpine"
    [ "$status" -eq 0 ]

    local upstream
    upstream=$(echo "$output" | jq -r '.UPSTREAM_VERSION // empty')
    [ -z "$upstream" ]
}

# ---------------------------------------------------------------------------
# MU5 — determinism: two runs on same static tag produce identical result
# Catches: live query path that could return different values on different runs.
# ---------------------------------------------------------------------------
@test "MU5: determinism — two runs on same static tag produce identical UPSTREAM_VERSION" {
    _run_build_args_driver "-alpine" "3.5.0-alpine"
    [ "$status" -eq 0 ]
    local first
    first=$(echo "$output" | jq -r '.UPSTREAM_VERSION // empty')
    [ -n "$first" ]

    _run_build_args_driver "-alpine" "3.5.0-alpine"
    [ "$status" -eq 0 ]
    local second
    second=$(echo "$output" | jq -r '.UPSTREAM_VERSION // empty')

    [ "$first" = "$second" ]
    [ "$first" = "3.5.0" ]
}

# ---------------------------------------------------------------------------
# MU6 — undeclared-ARG gate: valid suffix strip but Dockerfile does NOT declare
# ARG UPSTREAM_VERSION → UPSTREAM_VERSION must be OMITTED.
# Catches: removing the _df_declares_arg gate from STEP 4, which would emit an
# unused build-arg for jekyll/wordpress/php-style containers, triggering buildkit
# "unused build-arg" warnings and diverging from the matrix path.
# ---------------------------------------------------------------------------
@test "MU6: undeclared ARG UPSTREAM_VERSION in Dockerfile — UPSTREAM_VERSION omitted even with valid suffix" {
    _run_build_args_driver "-alpine" "1.31.1.1-alpine" "fakecontainer" 0
    [ "$status" -eq 0 ]

    local upstream
    upstream=$(echo "$output" | jq -r '.UPSTREAM_VERSION // empty')
    [ -z "$upstream" ]
}

# ---------------------------------------------------------------------------
# Real version.sh integration: --tag-suffix for php/jekyll/wordpress
# ---------------------------------------------------------------------------
@test "php --tag-suffix integration: real version.sh returns -fpm-alpine" {
    local suffix
    suffix=$(cd "$ORIGINAL_PROJECT_ROOT/php" && ./version.sh --tag-suffix)
    [ "$suffix" = "-fpm-alpine" ]
}

@test "jekyll --tag-suffix integration: real version.sh returns -alpine" {
    local suffix
    suffix=$(cd "$ORIGINAL_PROJECT_ROOT/jekyll" && ./version.sh --tag-suffix)
    [ "$suffix" = "-alpine" ]
}

@test "wordpress --tag-suffix integration: real version.sh returns -alpine" {
    local suffix
    suffix=$(cd "$ORIGINAL_PROJECT_ROOT/wordpress" && ./version.sh --tag-suffix)
    [ "$suffix" = "-alpine" ]
}

# ---------------------------------------------------------------------------
# Real openresty generator run: UPSTREAM_VERSION present and has no '-alpine' suffix
# End-to-end integration with the real project tree and real generator.
# ---------------------------------------------------------------------------
@test "openresty real generator: UPSTREAM_VERSION present and has no -alpine suffix" {
    run env _DEPGRAPH_LINEAGE_DIR=/nonexistent \
        GITHUB_ACTIONS="" \
        bash "$ORIGINAL_PROJECT_ROOT/scripts/generate-bake-hcl.sh" openresty 2>/dev/null
    [ "$status" -eq 0 ]

    local upstream
    upstream=$(echo "$output" | jq -r \
        'first(.target | to_entries[]
         | select(.key | startswith("openresty_"))
         | .value.args.UPSTREAM_VERSION // empty)')

    [ -n "$upstream" ]
    [[ "$upstream" != *"-alpine" ]]
}
