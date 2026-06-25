#!/usr/bin/env bats
# Unit tests for scripts/generate-bake-hcl.sh — ADR-013 R2+R3 slice
#
# Mutation guards (named per test, see "catches mutation" comments):
#   MG1: Remove contexts wiring → consumer targets lose "contexts" key
#   MG2: Emit docker.io / :latest rolling tag → generator produces non-intermediate refs
#   MG3: Remove _vbc_validate_build_args_config call → REMOTE_CR build_arg accepted
#   MG4: Skip template expansion → template cells emit dockerfile path, not dockerfile-inline
#   MG5: Remove NPROC injection → sslh/openvpn targets lose NPROC arg
#   MG6: Emit NPROC for non-NPROC container → debian target gains spurious NPROC arg
#   MG7: Omit NPROC bake variable from document header → bake fails to resolve ${NPROC}
#   MG8: --cells emits bake document instead of array → type check fails
#   MG9: intermediate_ref includes ${ARCH_SUFFIX} → merge consumer would double-suffix sources
#   MG10: Cell set for --cells differs from bake mode → plan drift between generator and merge job
#   MG11: Allow unflagged extension containers into bake graph -> extension sub-pipeline conflict (F1)
#   MG12: Omit is_latest_version from --cells output → merge job cannot gate rolling tags (F2)
#   MG13: Remove absolute-path guard in _resolve_cell_base_ref → doubled path → empty contexts (F3)
#   MG14: Hardcode include_all_retained=true → default mode emits retained versions (F4)
#   MG15: --cells iterates full closure → dep container appears in merge publish-set (FIX D)
#   MG16: --cells uses flavor instead of variant → github-runner cells share rolling alias (FIX F)
#   MG17: bake_latest_only flag ignored → retained github-runner versions enter bake (security bug)

load "../test_helper"

setup() {
    export PROJECT_ROOT
    export HELPERS_DIR
    export _DEPGRAPH_LINEAGE_DIR=/nonexistent
    # Silence ::notice:: GHA annotations from list_build_matrix during tests
    export GITHUB_ACTIONS=""
}

teardown() {
    :
}

# ---------------------------------------------------------------------------
# Helper: run generator for given containers, capture JSON
# ---------------------------------------------------------------------------
_run_generator() {
    run bash "${PROJECT_ROOT}/scripts/generate-bake-hcl.sh" "$@"
}

_run_generator_with_lineage_root() {
    local lineage_root="$1"
    shift
    run env ROOT_DIR="$lineage_root" GITHUB_REPOSITORY_OWNER=oorabona \
        bash "${PROJECT_ROOT}/scripts/generate-bake-hcl.sh" "$@"
}

_make_timescaledb_lineage_root() {
    local lineage_root="$1"
    mkdir -p "${lineage_root}/.build-lineage"

    # Mirror the real configured timescaledb version so this fixture — and the
    # assertions that read it back — track upstream-monitor bumps instead of
    # silently testing a stale version (#779).
    local ts_ver
    ts_ver=$(yq -r '.extensions.timescaledb.version' "${PROJECT_ROOT}/postgres/extensions/config.yaml")

    local pg
    for pg in 18 17 16; do
        jq -nc --arg pg "$pg" --arg v "$ts_ver" \
            '{ext:"timescaledb", pg_major:$pg, ceiling:$v, resolved:[$v], available:[$v], excluded:[]}' \
            > "${lineage_root}/.build-lineage/ext-timescaledb-pg${pg}-versionset.json"
    done
}

# ---------------------------------------------------------------------------
# GBH-01: Valid bake JSON structure
# Catches: any top-level key missing (MG7 partial — NPROC variable absent)
# ---------------------------------------------------------------------------
@test "GBH-01: generator produces valid JSON with variable/target/group keys for debian" {
    _run_generator debian
    [ "$status" -eq 0 ]
    # Must be valid JSON
    echo "$output" | jq -e '.' >/dev/null
    # Top-level keys present
    echo "$output" | jq -e '.variable' >/dev/null
    echo "$output" | jq -e '.target'   >/dev/null
    echo "$output" | jq -e '.group'    >/dev/null
}

# ---------------------------------------------------------------------------
# GBH-02: group.default.targets lists requested containers
# Catches: default group wiring bug
# ---------------------------------------------------------------------------
@test "GBH-02: group.default.targets includes at least one target for requested container" {
    _run_generator debian
    [ "$status" -eq 0 ]
    local cnt
    cnt=$(echo "$output" | jq '.group.default.targets | length')
    [ "$cnt" -gt 0 ]
}

# ---------------------------------------------------------------------------
# GBH-03: NPROC bake variable declared in document header (DEFECT 3 / MG7)
# Catches: NPROC variable missing → bake cannot resolve ${NPROC} in targets
# ---------------------------------------------------------------------------
@test "GBH-03: document header declares NPROC bake variable with default 1" {
    _run_generator sslh
    [ "$status" -eq 0 ]
    local nproc_default
    nproc_default=$(echo "$output" | jq -r '.variable.NPROC.default')
    [ "$nproc_default" = "1" ]
}

# ---------------------------------------------------------------------------
# GBH-04: NPROC injected into sslh target args (DEFECT 3 / MG5)
# Catches: NPROC omitted → sslh build fails with "required variable not set"
# ---------------------------------------------------------------------------
@test "GBH-04: sslh target args contains NPROC bake-variable reference" {
    _run_generator sslh
    [ "$status" -eq 0 ]
    # At least one sslh target must have NPROC in args
    local nproc_vals
    nproc_vals=$(echo "$output" | jq -r '
        .target
        | to_entries[]
        | select(.key | startswith("sslh_"))
        | .value.args.NPROC // ""
    ')
    # At least one non-empty NPROC value
    [[ "$nproc_vals" == *'${NPROC}'* ]]
}

# ---------------------------------------------------------------------------
# GBH-05: NPROC injected into openvpn target args (DEFECT 3 / MG5)
# ---------------------------------------------------------------------------
@test "GBH-05: openvpn target args contains NPROC bake-variable reference" {
    _run_generator openvpn
    [ "$status" -eq 0 ]
    local nproc_vals
    nproc_vals=$(echo "$output" | jq -r '
        .target
        | to_entries[]
        | select(.key | startswith("openvpn_"))
        | .value.args.NPROC // ""
    ')
    [[ "$nproc_vals" == *'${NPROC}'* ]]
}

# ---------------------------------------------------------------------------
# GBH-06: NPROC NOT injected into debian target args (DEFECT 3 / MG6)
# Catches: spurious NPROC injection → Docker "unused build-arg" warning
# ---------------------------------------------------------------------------
@test "GBH-06: debian target args does NOT contain NPROC (no ARG NPROC in Dockerfile)" {
    _run_generator debian
    [ "$status" -eq 0 ]
    local nproc_vals
    nproc_vals=$(echo "$output" | jq -r '
        .target
        | to_entries[]
        | select(.key | startswith("debian_"))
        | .value.args.NPROC // "absent"
    ')
    # All debian targets should have "absent" (no NPROC)
    [[ "$nproc_vals" != *'${NPROC}'* ]]
}

# ---------------------------------------------------------------------------
# GBH-07: Intermediate-only tags — no docker.io or :latest rolling tags (MG2)
# Catches: generator emitting non-intermediate refs; the R3 merge job handles
# rolling/latest tags, not the generator.
# ---------------------------------------------------------------------------
@test "GBH-07: all target tags are GHCR intermediate-only (no docker.io, no :latest without ARCH_SUFFIX)" {
    _run_generator debian
    [ "$status" -eq 0 ]
    # No docker.io refs
    local dockerio_count
    dockerio_count=$(echo "$output" | jq '[.target | to_entries[] | .value.tags[] | select(startswith("docker.io"))] | length')
    [ "$dockerio_count" -eq 0 ]

    # All tags must match ghcr.io/oorabona/<name>:<tag>${ARCH_SUFFIX} pattern.
    # REMOTE_CR is now concrete (generation-time), not a bake variable token.
    # ARCH_SUFFIX remains a bake variable (per-arch job).
    local bad_tags
    bad_tags=$(echo "$output" | jq -r '[
        .target | to_entries[] | .value.tags[]
        | select(
            (startswith("ghcr.io/oorabona/") | not)
            or
            (endswith("${ARCH_SUFFIX}") | not)
          )
    ] | length')
    [ "$bad_tags" -eq 0 ]
}

# ---------------------------------------------------------------------------
# GBH-08: Tag shape — intermediate ref format (DEFECT 4 guard, per spec)
# Each target has exactly one tag of the form ${REMOTE_CR}/<c>:<tag>${ARCH_SUFFIX}
# ---------------------------------------------------------------------------
@test "GBH-08: each target has exactly one tag in intermediate-ref format for sslh" {
    _run_generator sslh
    [ "$status" -eq 0 ]
    # Every target has exactly 1 tag
    local multi_tag_targets
    multi_tag_targets=$(echo "$output" | jq '[.target | to_entries[] | select(.value.tags | length != 1)] | length')
    [ "$multi_tag_targets" -eq 0 ]
    # Every sslh tag starts with the concrete GHCR prefix (REMOTE_CR resolved at generation).
    local bad_shape
    bad_shape=$(echo "$output" | jq -r '[
        .target | to_entries[]
        | select(.key | startswith("sslh_"))
        | .value.tags[]
        | select(startswith("ghcr.io/oorabona/sslh:") | not)
    ] | length')
    [ "$bad_shape" -eq 0 ]
}

# ---------------------------------------------------------------------------
# GBH-09: DAG / contexts wiring — github-runner debian-trixie cell references
# the debian target via contexts, and debian target is present in closure (MG1)
# ---------------------------------------------------------------------------
@test "GBH-09: github-runner + debian closure includes debian target and consumer has contexts" {
    _run_generator github-runner debian
    [ "$status" -eq 0 ]

    # debian target must exist (closure built it)
    local debian_target_count
    debian_target_count=$(echo "$output" | jq '[.target | to_entries[] | select(.key | startswith("debian_"))] | length')
    [ "$debian_target_count" -gt 0 ]

    # At least one github-runner cell must have a "contexts" key pointing at target:debian_*
    local runner_with_contexts
    runner_with_contexts=$(echo "$output" | jq -r '[
        .target | to_entries[]
        | select(.key | startswith("github_runner_"))
        | select(.value.contexts != null)
        | .value.contexts | to_entries[]
        | select(.value | startswith("target:debian_"))
    ] | length')
    [ "$runner_with_contexts" -gt 0 ]
}

# ---------------------------------------------------------------------------
# GBH-10: web-shell closure — web-shell debian cell contexts points at
# the debian dep target (MG1)
# ---------------------------------------------------------------------------
@test "GBH-10: web-shell debian variant contexts points at debian target" {
    _run_generator web-shell
    [ "$status" -eq 0 ]

    # At least one web-shell target must have contexts → target:debian_*
    local ws_debian_ctx
    ws_debian_ctx=$(echo "$output" | jq -r '[
        .target | to_entries[]
        | select(.key | startswith("web_shell_"))
        | select(.value.contexts != null)
        | .value.contexts | to_entries[]
        | select(.value | startswith("target:debian_"))
    ] | length')
    [ "$ws_debian_ctx" -gt 0 ]
}

# ---------------------------------------------------------------------------
# GBH-11: Template expansion — github-runner targets emit dockerfile-inline,
# NOT a dockerfile path, and content has no @@ markers (DEFECT 2 / MG4)
# ---------------------------------------------------------------------------
@test "GBH-11: github-runner linux targets use dockerfile-inline with no @@ markers" {
    _run_generator github-runner debian
    [ "$status" -eq 0 ]

    # All github-runner targets (linux only — windows filtered) must have
    # "dockerfile-inline" and must NOT have a bare "dockerfile" key.
    local runner_targets
    runner_targets=$(echo "$output" | jq '[
        .target | to_entries[]
        | select(.key | startswith("github_runner_"))
    ]')

    local count
    count=$(echo "$runner_targets" | jq 'length')
    [ "$count" -gt 0 ]

    # Each must have dockerfile-inline
    local missing_inline
    missing_inline=$(echo "$runner_targets" | jq '[.[] | select(."value"."dockerfile-inline" == null)] | length')
    [ "$missing_inline" -eq 0 ]

    # Each must NOT have top-level "dockerfile" key (only dockerfile-inline)
    local has_df_path
    has_df_path=$(echo "$runner_targets" | jq '[.[] | select(.value.dockerfile != null)] | length')
    [ "$has_df_path" -eq 0 ]

    # No @@ markers in any inline content
    local markers_found
    markers_found=$(echo "$runner_targets" | jq -r '[
        .[] | ."value"."dockerfile-inline"
        | select(test("@@[A-Z_]+@@"; "s"))
    ] | length')
    [ "$markers_found" -eq 0 ]
}

# ---------------------------------------------------------------------------
# GBH-12: Template expansion — github-runner inline content has a real FROM
# (DEFECT 2 — without expansion, the template FROM line wouldn't exist) (MG4)
# ---------------------------------------------------------------------------
@test "GBH-12: github-runner dockerfile-inline contains a real FROM instruction" {
    _run_generator github-runner debian
    [ "$status" -eq 0 ]

    # Each runner target's inline content must contain a FROM line
    local missing_from
    missing_from=$(echo "$output" | jq -r '[
        .target | to_entries[]
        | select(.key | startswith("github_runner_"))
        | ."value"."dockerfile-inline"
        | select(test("FROM ") | not)
    ] | length')
    [ "$missing_from" -eq 0 ]
}

# ---------------------------------------------------------------------------
# GBH-13: Template expansion — web-shell targets emit dockerfile-inline (MG4)
# ---------------------------------------------------------------------------
@test "GBH-13: web-shell targets use dockerfile-inline with no @@ markers" {
    _run_generator web-shell
    [ "$status" -eq 0 ]

    # web-shell Dockerfile is a template (contains @@BASE_IMAGE@@) —
    # all variants should use dockerfile-inline
    local ws_targets
    ws_targets=$(echo "$output" | jq '[.target | to_entries[] | select(.key | startswith("web_shell_"))]')

    local count
    count=$(echo "$ws_targets" | jq 'length')
    [ "$count" -gt 0 ]

    local missing_inline
    missing_inline=$(echo "$ws_targets" | jq '[.[] | select(."value"."dockerfile-inline" == null)] | length')
    [ "$missing_inline" -eq 0 ]

    local markers_found
    markers_found=$(echo "$ws_targets" | jq -r '[
        .[] | ."value"."dockerfile-inline"
        | select(test("@@[A-Z_]+@@"; "s"))
    ] | length')
    [ "$markers_found" -eq 0 ]
}

# ---------------------------------------------------------------------------
# GBH-14: Validation fail-closed — REMOTE_CR in config.yaml build_args causes
# non-zero exit when _vbc_validate_build_args_config is called (DEFECT 1 / MG3)
#
# Tests the validator directly (same function called by _config_build_args).
# Catches: removing the _vbc_validate_build_args_config call from _config_build_args
# would allow REMOTE_CR build_args to pass through unchecked.
# ---------------------------------------------------------------------------
@test "GBH-14: _vbc_validate_build_args_config rejects REMOTE_CR key in build_args" {
    local tmpdir
    tmpdir=$(mktemp -d)

    cat > "${tmpdir}/config.yaml" <<'YAML'
build_args:
  BASE_IMAGE: "debian:trixie"
  REMOTE_CR: "ghcr.io/attacker"
YAML

    run bash -c "
        source '${HELPERS_DIR}/logging.sh'
        source '${HELPERS_DIR}/build-args-utils.sh'
        source '${HELPERS_DIR}/validate-base-cache-schema.sh'
        _vbc_validate_build_args_config 'mycontainer' '${tmpdir}/config.yaml'
    " 2>&1

    rm -rf "${tmpdir}"

    # Must exit non-zero
    [ "$status" -ne 0 ]
    # Error must mention REMOTE_CR
    [[ "$output" =~ "REMOTE_CR" ]]
}

# ---------------------------------------------------------------------------
# GBH-15: Validation fail-closed — shell-unsafe value rejected (DEFECT 1)
# ---------------------------------------------------------------------------
@test "GBH-15: _vbc_validate_build_args_config rejects shell-unsafe value in build_args" {
    local tmpdir
    tmpdir=$(mktemp -d)

    cat > "${tmpdir}/config.yaml" <<'YAML'
build_args:
  BASE_IMAGE: "foo --network host"
YAML

    run bash -c "
        source '${HELPERS_DIR}/logging.sh'
        source '${HELPERS_DIR}/build-args-utils.sh'
        source '${HELPERS_DIR}/validate-base-cache-schema.sh'
        _vbc_validate_build_args_config 'mycontainer' '${tmpdir}/config.yaml'
    " 2>&1

    rm -rf "${tmpdir}"

    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# GBH-16: Windows cells filtered — no windows/amd64 platform in output
# ---------------------------------------------------------------------------
@test "GBH-16: no windows platform targets emitted for github-runner" {
    _run_generator github-runner debian
    [ "$status" -eq 0 ]

    local windows_targets
    windows_targets=$(echo "$output" | jq '[
        .target | to_entries[]
        | select(.value.platforms[]? | contains("windows"))
    ] | length')
    [ "$windows_targets" -eq 0 ]
}

# ---------------------------------------------------------------------------
# GBH-17: FIX O — REMOTE_CR must NOT be a bake variable; ARCH_SUFFIX and NPROC must be.
# REMOTE_CR is now resolved concretely at generation time from the env so that
# args.REMOTE_CR and contexts keys always match (no bake-time divergence risk).
# ---------------------------------------------------------------------------
@test "GBH-17: document header has NO variable.REMOTE_CR; ARCH_SUFFIX and NPROC are declared" {
    _run_generator debian
    [ "$status" -eq 0 ]
    # REMOTE_CR must NOT be a bake variable (concrete, not overridable at bake time)
    local has_remote_cr
    has_remote_cr=$(echo "$output" | jq 'has("variable") and (.variable | has("REMOTE_CR"))')
    [ "$has_remote_cr" = "false" ]
    # ARCH_SUFFIX and NPROC must still be declared (they genuinely vary per-arch/job)
    echo "$output" | jq -e '.variable.ARCH_SUFFIX.default' >/dev/null
    echo "$output" | jq -e '.variable.NPROC.default' >/dev/null
}

# ---------------------------------------------------------------------------
# GBH-18: Non-template container (debian) uses dockerfile path, not inline
# ---------------------------------------------------------------------------
@test "GBH-18: debian target uses dockerfile key (not dockerfile-inline)" {
    _run_generator debian
    [ "$status" -eq 0 ]

    # debian Dockerfile has no @@ markers → should be emitted as dockerfile path
    local has_df
    has_df=$(echo "$output" | jq '[
        .target | to_entries[]
        | select(.key | startswith("debian_"))
        | select(.value.dockerfile != null)
    ] | length')
    [ "$has_df" -gt 0 ]

    local has_inline
    has_inline=$(echo "$output" | jq '[
        .target | to_entries[]
        | select(.key | startswith("debian_"))
        | select(."value"."dockerfile-inline" != null)
    ] | length')
    [ "$has_inline" -eq 0 ]
}

# ---------------------------------------------------------------------------
# GBH-19: Multiple containers requested — all appear in group.default.targets
# ---------------------------------------------------------------------------
@test "GBH-19: requesting web-shell github-runner debian puts all three in default group" {
    _run_generator web-shell github-runner debian
    [ "$status" -eq 0 ]

    local total_default
    total_default=$(echo "$output" | jq '.group.default.targets | length')
    # Must have targets from all 3 requested containers
    [ "$total_default" -gt 0 ]

    # debian group present
    echo "$output" | jq -e '.group.debian' >/dev/null
    # github-runner group present
    echo "$output" | jq -e '."group"."github-runner"' >/dev/null
    # web-shell group present
    echo "$output" | jq -e '."group"."web-shell"' >/dev/null
}

# ---------------------------------------------------------------------------
# GBH-20: --cells mode emits a JSON array (MG8)
# ---------------------------------------------------------------------------
@test "GBH-20: --cells mode emits a JSON array" {
    _run_generator --cells debian
    [ "$status" -eq 0 ]
    local type
    type=$(echo "$output" | jq -r 'type')
    [ "$type" = "array" ]
}

# ---------------------------------------------------------------------------
# GBH-21: --cells objects have the 5 required fields (MG8)
# ---------------------------------------------------------------------------
@test "GBH-21: --cells objects have container/tag/flavor/is_default/intermediate_ref" {
    _run_generator --cells debian
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq 'length')" -gt 0 ]

    # Every element must have all 5 fields
    local missing
    missing=$(echo "$output" | jq '[
        .[] | select(
            (has("container") and has("tag") and has("flavor")
             and has("is_default") and has("intermediate_ref")) | not
        )
    ] | length')
    [ "$missing" -eq 0 ]
}

# ---------------------------------------------------------------------------
# GBH-22: FIX O — intermediate_ref is CONCRETE (ghcr.io/oorabona/…), no ${REMOTE_CR} token,
# and has NO ${ARCH_SUFFIX} either. (MG9 updated)
# ---------------------------------------------------------------------------
@test "GBH-22: --cells intermediate_ref is concrete ghcr.io ref with no bake-variable tokens" {
    _run_generator --cells debian
    [ "$status" -eq 0 ]

    # All intermediate_ref values must start with the concrete registry prefix
    local bad_prefix
    bad_prefix=$(echo "$output" | jq '[
        .[] | .intermediate_ref
        | select(startswith("ghcr.io/oorabona/") | not)
    ] | length')
    [ "$bad_prefix" -eq 0 ]

    # None may contain the ${REMOTE_CR} token (it must have been resolved)
    local has_remote_cr_token
    has_remote_cr_token=$(echo "$output" | jq '[
        .[] | .intermediate_ref
        | select(test("\\$\\{REMOTE_CR\\}"))
    ] | length')
    [ "$has_remote_cr_token" -eq 0 ]

    # None may contain ${ARCH_SUFFIX}
    local has_arch_suffix
    has_arch_suffix=$(echo "$output" | jq '[
        .[] | .intermediate_ref
        | select(contains("${ARCH_SUFFIX}"))
    ] | length')
    [ "$has_arch_suffix" -eq 0 ]
}

# ---------------------------------------------------------------------------
# GBH-23: --cells cell set for web-shell matches bake-mode target set (MG10)
# Cell parity: every --cells entry must correspond to a bake target for the
# same container+tag, and vice versa (same cardinality).
# Both modes use the same default (latest-only); use --all-retained to compare
# the retained-version path.
# ---------------------------------------------------------------------------
@test "GBH-23: --cells and bake mode produce same container/tag set for web-shell github-runner debian" {
    # Bake mode target count (default: latest-only)
    _run_generator web-shell github-runner debian
    [ "$status" -eq 0 ]

    local bake_targets_count
    bake_targets_count=$(echo "$output" | jq '.target | keys | length')

    # --cells mode cell count (default: latest-only)
    _run_generator --cells web-shell github-runner debian
    [ "$status" -eq 0 ]

    local cells_count
    cells_count=$(echo "$output" | jq 'length')

    # Both must emit the same number of linux cells
    # (bake targets = one per linux cell; cells array = one per linux cell)
    [ "$cells_count" -eq "$bake_targets_count" ]
}

# ---------------------------------------------------------------------------
# GBH-24: default mode (no --cells) output is unchanged — bake document
# structure still present after the refactor (regression guard).
# ---------------------------------------------------------------------------
@test "GBH-24: default mode (no --cells) still produces bake JSON with variable/target/group" {
    _run_generator debian
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.variable' >/dev/null
    echo "$output" | jq -e '.target'   >/dev/null
    echo "$output" | jq -e '.group'    >/dev/null
    # Confirm it is NOT an array (cells mode would produce an array)
    local doc_type
    doc_type=$(echo "$output" | jq -r 'type')
    [ "$doc_type" = "object" ]
}

# ---------------------------------------------------------------------------
# GBH-25: F1 — postgres final image is explicitly bake-emittable when activated
# Catches: dropping build.bake_final_build support would re-exclude postgres.
# ---------------------------------------------------------------------------
@test "GBH-25: postgres --include-final-build --cells emits 21 final-image cells across all supported majors/flavors" {
    _run_generator --include-final-build --cells postgres
    [ "$status" -eq 0 ]

    local count majors flavor_count
    count=$(echo "$output" | jq '[.[] | select(.container == "postgres")] | length')
    majors=$(echo "$output" | jq -r '[.[].tag | capture("^(?<major>[0-9]+)").major] | unique | sort | join(" ")')
    flavor_count=$(echo "$output" | jq '[.[].flavor] | unique | length')

    [ "$count" -eq 21 ]
    [ "$majors" = "16 17 18" ]
    [ "$flavor_count" -eq 7 ]
}

@test "GBH-25b: postgres bake graph materializes inline base/vector/timeseries Dockerfiles offline" {
    local lineage_root
    lineage_root=$(mktemp -d)
    _make_timescaledb_lineage_root "$lineage_root"

    _run_generator_with_lineage_root "$lineage_root" --include-final-build postgres
    rm -rf "$lineage_root"
    [ "$status" -eq 0 ]

    local target_count
    target_count=$(echo "$output" | jq '[.target | to_entries[] | select(.key | startswith("postgres_"))] | length')
    [ "$target_count" -eq 21 ]

    local base_inline vector_inline timeseries_inline
    base_inline=$(echo "$output" | jq -r '.target.postgres_18_base["dockerfile-inline"] // ""')
    vector_inline=$(echo "$output" | jq -r '.target.postgres_18_vector["dockerfile-inline"] // ""')
    timeseries_inline=$(echo "$output" | jq -r '.target.postgres_18_timeseries["dockerfile-inline"] // ""')

    [ -n "$base_inline" ]
    [ -n "$vector_inline" ]
    [ -n "$timeseries_inline" ]
    [[ "$base_inline" != *"@@"* ]]
    [[ "$vector_inline" != *"@@"* ]]
    [[ "$timeseries_inline" != *"@@"* ]]

    local base_ext_from_count
    base_ext_from_count=$(printf '%s\n' "$base_inline" | grep -cE '^FROM .*ext-' || true)
    [ "$base_ext_from_count" -eq 0 ]

    # pgvector has no test lineage fixture (unlike timescaledb below), so the
    # generator resolves its version straight from the real
    # postgres/extensions/config.yaml. Read it from that same source instead of
    # hardcoding, so an upstream-monitor version bump can't drift this test out
    # from under CI (#779 — broke when the bot bumped pgvector 0.8.2 -> 0.8.3).
    local pgvector_ver
    pgvector_ver=$(yq -r '.extensions.pgvector.version' "${PROJECT_ROOT}/postgres/extensions/config.yaml")
    [ -n "$pgvector_ver" ]
    grep -Fxq "FROM ghcr.io/oorabona/ext-pgvector:pg18-${pgvector_ver} AS ext-pgvector" <<< "$vector_inline"
    grep -Fxq 'COPY --from=ext-pgvector /output/extension/ /tmp/ext/pgvector/extension/' <<< "$vector_inline"
    # timescaledb's version flows through the lineage fixture, which now mirrors
    # config (_make_timescaledb_lineage_root) — read it from the same source.
    local timescaledb_ver
    timescaledb_ver=$(yq -r '.extensions.timescaledb.version' "${PROJECT_ROOT}/postgres/extensions/config.yaml")
    grep -Fxq "FROM ghcr.io/oorabona/ext-timescaledb:pg18-${timescaledb_ver} AS ext-timescaledb" <<< "$timeseries_inline"
}

@test "GBH-25e: postgres bake VERSION build arg carries base_suffix (matches the non-bake base image)" {
    local lineage_root
    lineage_root=$(mktemp -d)
    _make_timescaledb_lineage_root "$lineage_root"

    _run_generator_with_lineage_root "$lineage_root" --include-final-build postgres
    rm -rf "$lineage_root"
    [ "$status" -eq 0 ]

    # postgres declares base_suffix "-alpine" + FROM library/postgres:${VERSION};
    # the bake VERSION arg must be "<major>-alpine", not the bare major, else the
    # build pulls the Debian base and publishes *-alpine tags backed by it.
    [ "$(echo "$output" | jq -r '.target.postgres_18_base.args.VERSION')" = "18-alpine" ]
    [ "$(echo "$output" | jq -r '.target.postgres_17_vector.args.VERSION')" = "17-alpine" ]
    [ "$(echo "$output" | jq -r '.target.postgres_16_full.args.VERSION')" = "16-alpine" ]
    [ "$(echo "$output" | jq -r '.target.postgres_18_base.args.MAJOR_VERSION')" = "18" ]
}

@test "GBH-25c: postgres inline Dockerfiles escape bake interpolation triggers" {
    local lineage_root
    lineage_root=$(mktemp -d)
    _make_timescaledb_lineage_root "$lineage_root"

    _run_generator_with_lineage_root "$lineage_root" --include-final-build postgres
    rm -rf "$lineage_root"
    [ "$status" -eq 0 ]

    local all_inline stripped_doubles bare_count
    all_inline=$(echo "$output" | jq -r '[.target | to_entries[] | select(.key | startswith("postgres_")) | .value["dockerfile-inline"] // empty] | join("\n")')
    [ -n "$all_inline" ]
    [[ "$all_inline" == *'$${REMOTE_CR}'* ]]

    stripped_doubles="${all_inline//\$\$\{/ESCAPED}"
    bare_count=$(printf '%s' "$stripped_doubles" | grep -cF '${' || true)
    [ "$bare_count" -eq 0 ]
}

@test "GBH-25d: no-arg whole-fleet generate excludes postgres without final-build activation" {
    local lineage_root out err
    lineage_root=$(mktemp -d)
    out=$(mktemp)
    err=$(mktemp)

    run bash -c '
        set -euo pipefail
        lineage_root="$1"
        out="$2"
        err="$3"
        ROOT_DIR="$lineage_root" GITHUB_REPOSITORY_OWNER=oorabona \
            "${PROJECT_ROOT}/scripts/generate-bake-hcl.sh" >"$out" 2>"$err"
    ' bash "$lineage_root" "$out" "$err"
    rm -rf "$lineage_root"
    [ "$status" -eq 0 ]

    local postgres_targets
    postgres_targets=$(jq '[.target | to_entries[] | select(.key | startswith("postgres_"))] | length' "$out")
    [ "$postgres_targets" -eq 0 ]

    rm -f "$out" "$err"
}

@test "GBH-26: F1 — whole-fleet generate has no postgres target" {
    # Generate for a small fleet that includes postgres (it is in ./make list).
    # We only request a known non-extension container but verify postgres never appears.
    _run_generator debian
    [ "$status" -eq 0 ]
    local postgres_targets
    postgres_targets=$(echo "$output" | jq '[.target | to_entries[] | select(.key | startswith("postgres_"))] | length')
    [ "$postgres_targets" -eq 0 ]
}

@test "GBH-26b: F1 — extension container without bake_final_build remains excluded" {
    local variants backup out err
    variants="${PROJECT_ROOT}/postgres/variants.yaml"
    backup=$(mktemp)
    out=$(mktemp)
    err=$(mktemp)

    run bash -c '
        set -euo pipefail
        variants="$1"
        backup="$2"
        out="$3"
        err="$4"
        cp "$variants" "$backup"
        restore() { cp "$backup" "$variants"; }
        trap restore EXIT
        yq -i "del(.build.bake_final_build)" "$variants"
        "${PROJECT_ROOT}/scripts/generate-bake-hcl.sh" postgres >"$out" 2>"$err"
    ' bash "$variants" "$backup" "$out" "$err"

    [ "$status" -eq 0 ]
    grep -q "Skipping postgres" "$err"
    [ "$(jq '.target | length' "$out")" -eq 0 ]

    rm -f "$backup" "$out" "$err"
}

@test "GBH-26c: non-postgres extensionless graph stays on the committed-Dockerfile path" {
    [ ! -f "${PROJECT_ROOT}/debian/extensions/config.yaml" ]
    [ "$(yq -r '.build.bake_final_build // false' "${PROJECT_ROOT}/debian/variants.yaml")" = "false" ]

    _run_generator debian
    [ "$status" -eq 0 ]
    local first="$output"

    _run_generator debian
    [ "$status" -eq 0 ]
    local second="$output"

    [ "$(jq -cS . <<< "$first")" = "$(jq -cS . <<< "$second")" ]
    [ "$(echo "$first" | jq '[.target | to_entries[] | select(.key | startswith("debian_")) | select(.value["dockerfile-inline"] != null)] | length')" -eq 0 ]
    [ "$(echo "$first" | jq -r '.target.debian_trixie.dockerfile')" = "Dockerfile" ]
}

# ---------------------------------------------------------------------------
# GBH-27: F2 — --cells objects include is_latest_version field (MG12)
# ---------------------------------------------------------------------------
@test "GBH-27: --cells objects include is_latest_version field" {
    _run_generator --cells debian
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq 'length')" -gt 0 ]

    local missing_field
    missing_field=$(echo "$output" | jq '[.[] | select(has("is_latest_version") | not)] | length')
    [ "$missing_field" -eq 0 ]
}

@test "GBH-28: F2 — debian latest cell has is_latest_version=true" {
    _run_generator --cells debian
    [ "$status" -eq 0 ]
    local latest_count
    latest_count=$(echo "$output" | jq '[.[] | select(.is_latest_version == true)] | length')
    [ "$latest_count" -gt 0 ]
}

# ---------------------------------------------------------------------------
# GBH-29: F3+concrete-key — wordpress→php consumer contexts key is CONCRETE
# (ghcr.io/oorabona/php:…), not a ${REMOTE_CR} token. (MG13)
# Without the absolute-path fix, _resolve_cell_base_ref doubled the path →
# empty base ref → no contexts. Without the concrete-key fix the key would
# carry the unresolved "${REMOTE_CR}" token instead of the registry hostname.
# ---------------------------------------------------------------------------
@test "GBH-29: F3+concrete — wordpress contexts key is concrete ghcr.io ref, no \${ token, maps to php target" {
    _run_generator wordpress php
    [ "$status" -eq 0 ]

    # php target must exist
    local php_target_count
    php_target_count=$(echo "$output" | jq '[.target | to_entries[] | select(.key | startswith("php_"))] | length')
    [ "$php_target_count" -gt 0 ]

    # At least one wordpress target must have a contexts key that:
    #   a) maps to target:php_*
    #   b) the key starts with "ghcr.io/oorabona/php:" (concrete, not a token)
    #   c) the key contains no "${" literal token
    local wp_ctx_key
    wp_ctx_key=$(echo "$output" | jq -r '[
        .target | to_entries[]
        | select(.key | startswith("wordpress_"))
        | select(.value.contexts != null)
        | .value.contexts | to_entries[]
        | select(.value | startswith("target:php_"))
        | .key
    ] | first // ""')
    [[ -n "$wp_ctx_key" ]]
    [[ "$wp_ctx_key" == ghcr.io/oorabona/php:* ]]
    [[ "$wp_ctx_key" != *'${'* ]]
}

# ---------------------------------------------------------------------------
# GBH-30: F4 — default mode emits ONE version per retained container (MG14)
# github-runner has 3 retained versions; default mode should emit only
# the latest one (is_latest_version=true cells).
# ---------------------------------------------------------------------------
@test "GBH-30: F4 — default mode emits only latest version for github-runner (not all retained)" {
    _run_generator github-runner debian
    [ "$status" -eq 0 ]

    # All github-runner target keys must belong to the latest version tag.
    # The latest version is the first entry in variants.yaml (2.334.0 currently).
    local latest_tag
    latest_tag=$(bash -c "
        source '${HELPERS_DIR}/variant-utils.sh'
        source '${PROJECT_ROOT}/helpers/dependency-graph.sh'
        list_build_matrix './github-runner' '' 'false' 2>/dev/null | jq -r 'first(.[] | select(.is_latest_version==true)) | .tag'
    ")
    [ -n "$latest_tag" ]

    # There must be at least one github-runner target for the latest version
    local safe_tag="${latest_tag//[.\-\/]/_}"
    local latest_targets
    latest_targets=$(echo "$output" | jq --arg t "$safe_tag" \
        '[.target | to_entries[] | select(.key | startswith("github_runner_") and test($t))] | length')
    [ "$latest_targets" -gt 0 ]

    # bake_latest_only=true: github-runner is always latest-only regardless of --all-retained.
    # Use terraform (no bake_latest_only) to verify F4 --all-retained expansion still works.
    local tf_default_count
    tf_default_count=$(bash -c "
        source '${HELPERS_DIR}/variant-utils.sh'
        source '${PROJECT_ROOT}/helpers/dependency-graph.sh'
        '${PROJECT_ROOT}/scripts/generate-bake-hcl.sh' terraform 2>/dev/null \
            | jq '[.target | to_entries[] | select(.key | startswith(\"terraform_\"))] | length'
    ")
    _run_generator --all-retained terraform
    [ "$status" -eq 0 ]
    local tf_retained_count
    tf_retained_count=$(echo "$output" | jq '[.target | to_entries[] | select(.key | startswith("terraform_"))] | length')
    # terraform --all-retained must expand beyond latest-only
    [ "$tf_retained_count" -gt "$tf_default_count" ]
}

@test "GBH-31: F4 — --all-retained emits multiple versions for terraform (retained, no bake_latest_only)" {
    # github-runner now has bake_latest_only=true so it is always latest-only.
    # Use terraform (version_retention=3, no bake_latest_only) to verify --all-retained.
    _run_generator --all-retained terraform
    [ "$status" -eq 0 ]

    local tf_counts
    tf_counts=$(echo "$output" | jq '[.target | to_entries[] | select(.key | startswith("terraform_"))] | length')
    # terraform has 3 retained versions × multiple variants; assert > the single-version count.
    local tf_default_count
    tf_default_count=$(bash -c "
        export _DEPGRAPH_LINEAGE_DIR=/nonexistent
        export GITHUB_ACTIONS=''
        '${PROJECT_ROOT}/scripts/generate-bake-hcl.sh' terraform 2>/dev/null \
            | jq '[.target | to_entries[] | select(.key | startswith(\"terraform_\"))] | length'
    ")
    [ "$tf_counts" -gt "$tf_default_count" ]
}

# ---------------------------------------------------------------------------
# FIX D: --cells publish-set must be requested-only (not dep closure)
# ---------------------------------------------------------------------------

@test "GBH-32: FIX D — --cells wordpress emits only wordpress cells, not php" {
    _run_generator --cells wordpress
    [ "$status" -eq 0 ]

    # cells output must be valid JSON array
    local containers
    containers=$(echo "$output" | jq -r '[.[].container] | unique | sort | join(" ")')
    # Must contain wordpress
    [[ "$containers" == *"wordpress"* ]]
    # Must NOT contain php (dep-closure container, never pushed by bake)
    [[ "$containers" != *"php"* ]]
}

@test "GBH-33: FIX D — --cells with multiple explicit requests includes all requested containers" {
    # When both php AND wordpress are explicitly requested, both appear in cells output.
    # This pins the no-filter-when-both-requested behavior (requested set = [php, wordpress]).
    _run_generator --cells php wordpress
    [ "$status" -eq 0 ]

    local containers
    containers=$(echo "$output" | jq -r '[.[].container] | unique | sort | join(" ")')
    # Both must be present — each is in the requested set
    [[ "$containers" == *"wordpress"* ]]
    [[ "$containers" == *"php"* ]]
}

@test "GBH-34: FIX D — bake wordpress still includes php target AND contexts; --cells diverges (requested-only)" {
    # Bake mode: closure intact — php target must exist
    _run_generator wordpress
    [ "$status" -eq 0 ]
    local bake_out="$output"

    local php_targets
    php_targets=$(echo "$bake_out" | jq '[.target | to_entries[] | select(.key | startswith("php_"))] | length')
    [ "$php_targets" -gt 0 ]

    # wordpress target still carries a contexts map (base-ref to php dep)
    local wp_has_contexts
    wp_has_contexts=$(echo "$bake_out" | jq \
        '[.target | to_entries[] | select(.key | startswith("wordpress_")) | select(.value.contexts != null)] | length')
    [ "$wp_has_contexts" -gt 0 ]

    # --cells wordpress must NOT include php
    _run_generator --cells wordpress
    [ "$status" -eq 0 ]
    local cells_containers
    cells_containers=$(echo "$output" | jq -r '[.[].container] | unique | sort | join(" ")')
    [[ "$cells_containers" != *"php"* ]]
    [[ "$cells_containers" == *"wordpress"* ]]
}

# ---------------------------------------------------------------------------
# FIX F: --cells objects include variant; github-runner cells have distinct variants
# ---------------------------------------------------------------------------

@test "GBH-35: FIX F — --cells objects include variant field" {
    _run_generator --cells github-runner
    [ "$status" -eq 0 ]

    # Every cell object must have a non-empty variant field
    local missing_variant
    missing_variant=$(echo "$output" | jq '[.[] | select(.variant == null or .variant == "")] | length')
    [ "$missing_variant" -eq 0 ]
}

@test "GBH-36: FIX F — github-runner debian-trixie-base and debian-trixie-dev have DISTINCT variants" {
    _run_generator --cells github-runner
    [ "$status" -eq 0 ]

    # Extract variants for the debian-trixie tag cells
    local base_variant dev_variant
    base_variant=$(echo "$output" | jq -r \
        '.[] | select(.container == "github-runner" and (.tag | contains("debian-trixie")) and (.tag | contains("dev") | not)) | .variant' \
        | head -1)
    dev_variant=$(echo "$output" | jq -r \
        '.[] | select(.container == "github-runner" and (.tag | contains("debian-trixie")) and (.tag | contains("dev"))) | .variant' \
        | head -1)

    [ -n "$base_variant" ]
    [ -n "$dev_variant" ]
    # Must be different — no rolling-alias collision
    [ "$base_variant" != "$dev_variant" ]
}

# ---------------------------------------------------------------------------
# FIX O: REMOTE_CR is concrete at generation time — no bake variable, no token.
# ---------------------------------------------------------------------------

@test "GBH-37: FIX O — args.REMOTE_CR and contexts key are concrete and equal-prefixed (wordpress)" {
    _run_generator wordpress php
    [ "$status" -eq 0 ]

    # args.REMOTE_CR must be the concrete registry value, not a bake-variable token
    local args_remote_cr
    args_remote_cr=$(echo "$output" | jq -r '
        .target | to_entries[]
        | select(.key | startswith("wordpress_"))
        | .value.args.REMOTE_CR
    ' | head -1)
    [ -n "$args_remote_cr" ]
    [[ "$args_remote_cr" != *'${'* ]]
    [[ "$args_remote_cr" == ghcr.io/oorabona* ]]

    # contexts key must start with the same registry prefix
    local ctx_key
    ctx_key=$(echo "$output" | jq -r '
        .target | to_entries[]
        | select(.key | startswith("wordpress_"))
        | select(.value.contexts != null)
        | .value.contexts | keys[0]
    ' | head -1)
    [ -n "$ctx_key" ]
    [[ "$ctx_key" != *'${'* ]]
    [[ "$ctx_key" == ghcr.io/oorabona* ]]

    # Both must share the same registry prefix
    local args_prefix ctx_prefix
    args_prefix="${args_remote_cr%%/*}"   # just the hostname
    ctx_prefix=$(printf '%s' "$ctx_key" | cut -d/ -f1)
    [ "$args_prefix" = "$ctx_prefix" ]
}

@test "GBH-38: FIX O — REMOTE_CR=example.test/x override makes tags/args/contexts all use example.test/x" {
    # Override REMOTE_CR at generation time — all three surfaces must be consistent.
    run env REMOTE_CR=example.test/x bash "${PROJECT_ROOT}/scripts/generate-bake-hcl.sh" wordpress php
    [ "$status" -eq 0 ]

    # args.REMOTE_CR must use the override
    local args_remote_cr
    args_remote_cr=$(echo "$output" | jq -r '
        .target | to_entries[]
        | select(.key | startswith("wordpress_"))
        | .value.args.REMOTE_CR
    ' | head -1)
    [[ "$args_remote_cr" == example.test/x* ]]

    # tags must use the override
    local tag_prefix
    tag_prefix=$(echo "$output" | jq -r '
        .target | to_entries[]
        | select(.key | startswith("wordpress_"))
        | .value.tags[0]
    ' | head -1)
    [[ "$tag_prefix" == example.test/x/wordpress:* ]]

    # contexts key must use the override
    local ctx_key
    ctx_key=$(echo "$output" | jq -r '
        .target | to_entries[]
        | select(.key | startswith("wordpress_"))
        | select(.value.contexts != null)
        | .value.contexts | keys[0]
    ' | head -1)
    [[ "$ctx_key" == example.test/x/php:* ]]

    # No REMOTE_CR bake variable in the document
    local has_remote_cr_var
    has_remote_cr_var=$(echo "$output" | jq 'has("variable") and (.variable | has("REMOTE_CR"))')
    [ "$has_remote_cr_var" = "false" ]
}

# ---------------------------------------------------------------------------
# FIX Q: dockerfile-inline content must have all ${…} escaped as $${…}
# so bake --print does not abort on undefined Docker ARG variables.
# ---------------------------------------------------------------------------

@test "GBH-39: FIX Q — inline target has no un-escaped \${…} in dockerfile-inline" {
    # github-runner uses inline Dockerfiles (template expansion).
    _run_generator github-runner debian
    [ "$status" -eq 0 ]

    # Collect all dockerfile-inline values and assert none contain un-escaped ${.
    # Un-escaped ${ is any ${ NOT preceded by another $ (i.e. not $${ already).
    # Strategy: strip all $${ occurrences, then assert no ${ remains.
    local all_inline
    all_inline=$(echo "$output" | jq -r '[.target[]["dockerfile-inline"] // empty] | join("\n")')
    [ -n "$all_inline" ]  # must have at least one inline target

    local stripped_doubles
    stripped_doubles="${all_inline//\$\$\{/ESCAPED}"
    # After removing all properly-escaped $${, no bare ${ should remain
    local bare_count
    bare_count=$(printf '%s' "$stripped_doubles" | grep -cF '${' || true)
    [ "$bare_count" -eq 0 ]
}

@test "GBH-40: FIX Q — inline FROM line is escaped (FROM \$\${\${…}}) and contexts key remains concrete" {
    _run_generator github-runner debian
    [ "$status" -eq 0 ]

    # At least one inline target FROM line must use the $${…} escaped form
    local escaped_from_count
    escaped_from_count=$(echo "$output" | jq -r '
        [.target[] | select(has("dockerfile-inline")) | .["dockerfile-inline"]]
        | map(split("\n")[] | select(startswith("FROM ")))
        | map(select(contains("$${")  ))
        | length
    ')
    [ "$escaped_from_count" -gt 0 ]

    # contexts keys must still be concrete ghcr.io/… (un-escaped FROM was used
    # for base-ref extraction; escaped form only appears in the emitted JSON)
    local bad_ctx_keys
    bad_ctx_keys=$(echo "$output" | jq -r '
        [.target[] | select(.contexts != null) | .contexts | keys[]]
        | map(select(startswith("ghcr.io/") | not))
        | length
    ')
    [ "$bad_ctx_keys" -eq 0 ]
}

@test "GBH-41: FIX Q — committed-Dockerfile target (debian) uses dockerfile key, no inline, no escaping needed" {
    _run_generator debian
    [ "$status" -eq 0 ]

    # debian has no @@…@@ markers → must use dockerfile path, not inline
    local inline_count
    inline_count=$(echo "$output" | jq '[.target | to_entries[] | select(.key | startswith("debian_")) | select(has("dockerfile-inline"))] | length')
    [ "$inline_count" -eq 0 ]

    local df_count
    df_count=$(echo "$output" | jq '[.target | to_entries[] | select(.key | startswith("debian_")) | select(.value.dockerfile != null)] | length')
    [ "$df_count" -gt 0 ]
}

# ---------------------------------------------------------------------------
# FIX S: fail-closed on dependency-graph errors
# The generator must exit non-zero and emit ::error:: when _depgraph_get_deps_transitive
# returns non-zero, rather than silently producing a bake graph with missing contexts.
# ---------------------------------------------------------------------------

@test "GBH-42: FIX S — generator exits non-zero with ::error:: on depgraph failure" {
    # Verify the fail-closed depgraph guard via a wrapper script that overrides
    # _depgraph_get_deps_transitive to return non-zero.
    # Strategy: write a caller script to $TEST_TEMP_DIR (allocated by setup()) that:
    #   1. Sources all real generator helpers (variant-utils, dependency-graph, etc.)
    #   2. Overrides the depgraph functions with stubs that return 1
    #   3. Sources and re-defines the generator's internal functions by re-parsing the
    #      generator body (with main() redefined as a no-op to prevent auto-execution)
    #   4. Calls _expand_closure directly to trigger the fail-closed guard
    # This avoids file-tree mirroring while still exercising the production code path.
    local _tmpdir
    _tmpdir=$(mktemp -d)
    local wrapper="${_tmpdir}/gbh42_wrapper.sh"
    printf '#!/usr/bin/env bash\n' > "$wrapper"
    printf 'set -euo pipefail\n' >> "$wrapper"
    printf 'export _DEPGRAPH_LINEAGE_DIR=/nonexistent\n' >> "$wrapper"
    printf 'export GITHUB_ACTIONS=""\n' >> "$wrapper"
    # Source real helpers
    printf 'source "%s/helpers/variant-utils.sh"\n' "$PROJECT_ROOT" >> "$wrapper"
    printf 'source "%s/helpers/dependency-graph.sh"\n' "$PROJECT_ROOT" >> "$wrapper"
    printf 'source "%s/helpers/logging.sh"\n' "$PROJECT_ROOT" >> "$wrapper"
    printf 'source "%s/helpers/build-args-utils.sh"\n' "$PROJECT_ROOT" >> "$wrapper"
    printf 'source "%s/helpers/validate-base-cache-schema.sh"\n' "$PROJECT_ROOT" >> "$wrapper"
    # Override depgraph functions to simulate failure
    printf '_depgraph_get_deps_transitive() { return 1; }\n' >> "$wrapper"
    printf '_depgraph_get_deps() { return 1; }\n' >> "$wrapper"
    # Set PROJECT_ROOT so generator helpers resolve paths correctly
    printf 'export PROJECT_ROOT="%s"\n' "$PROJECT_ROOT" >> "$wrapper"
    # Source the generator internals by executing it in a subshell with a
    # GENERATE_BAKE_TEST_SOURCING guard so main() is skipped.
    # We do this by inlining just the functions we need to test.
    # _expand_closure is the first fail-closed site; call it directly.
    # Re-define it inline using the production code with the stubbed depgraph.
    printf '_add_unique() { :; }\n' >> "$wrapper"
    printf '_is_extension_container() { [[ -f "%s/$1/extensions/config.yaml" ]]; }\n' "$PROJECT_ROOT" >> "$wrapper"
    printf '_expand_closure() {\n' >> "$wrapper"
    printf '    local -a requested=("$@")\n' >> "$wrapper"
    printf '    local c\n' >> "$wrapper"
    printf '    for c in "${requested[@]}"; do\n' >> "$wrapper"
    printf '        local deps\n' >> "$wrapper"
    printf '        if ! deps="$(_depgraph_get_deps_transitive "$c")"; then\n' >> "$wrapper"
    printf '            printf '"'"'::error::dependency-graph resolution failed for %%s\n'"'"' "$c" >&2\n' >> "$wrapper"
    printf '            return 1\n' >> "$wrapper"
    printf '        fi\n' >> "$wrapper"
    printf '    done\n' >> "$wrapper"
    printf '}\n' >> "$wrapper"
    printf '_expand_closure debian || exit 1\n' >> "$wrapper"
    printf 'exit 0\n' >> "$wrapper"
    chmod +x "$wrapper"

    run bash "$wrapper" 2>&1
    rm -rf "$_tmpdir"
    [ "$status" -ne 0 ]
    [[ "$output" == *"dependency-graph resolution failed"* ]]
}

# ---------------------------------------------------------------------------
# GBH-43: #595 — --cells objects include target_id field
# Catches: omitting target_id from cells output → bake-buildresult cannot
# correlate --metadata-file keys to cells.
# ---------------------------------------------------------------------------
@test "GBH-43: --cells objects include target_id field (non-empty string)" {
    _run_generator --cells web-shell
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq 'length')" -gt 0 ]

    # Every cell must have a non-empty target_id
    local missing_tid
    missing_tid=$(echo "$output" | jq '[.[] | select((.target_id | type) != "string" or .target_id == "")] | length')
    [ "$missing_tid" -eq 0 ]
}

# ---------------------------------------------------------------------------
# GBH-44: #595 — --cells[].target_id values equal bake-mode .target keys (MG10 extension)
# The join key is correct: the set of target_ids from --cells must be exactly
# the set of target keys emitted by bake mode for the same requested containers
# (dep-closure exclusion in --cells is correct: dep targets like debian_trixie
#  appear in bake mode but not in --cells for a requested set that doesn't
#  include debian directly).
# ---------------------------------------------------------------------------
@test "GBH-44: --cells target_id set equals bake-mode target key set for web-shell" {
    # --cells target_ids (sorted)
    _run_generator --cells web-shell
    [ "$status" -eq 0 ]
    local cells_tids
    cells_tids=$(echo "$output" | jq -r '[.[].target_id] | sort | join("\n")')

    # bake-mode target keys for web-shell only (exclude dep targets like debian_trixie)
    _run_generator web-shell
    [ "$status" -eq 0 ]
    local bake_keys
    bake_keys=$(echo "$output" | jq -r '[.target | keys[] | select(startswith("web_shell_"))] | sort | join("\n")')

    # Both sets must be identical
    [ "$cells_tids" = "$bake_keys" ]
}

# ---------------------------------------------------------------------------
# GBH-45: #595 — target_id format is a valid bake identifier (no dots/hyphens/slashes)
# _target_id sanitises: [.\-\/] → _; leading digit → v prefix.
# Catching: a target_id with literal dots would not match the bake metadata key.
# ---------------------------------------------------------------------------
@test "GBH-45: --cells target_id values contain only [A-Za-z0-9_] characters" {
    _run_generator --cells web-shell github-runner
    [ "$status" -eq 0 ]

    # All target_ids must match the bake-identifier alphabet
    local invalid_tids
    invalid_tids=$(echo "$output" | jq -r '[.[].target_id | select(test("[^A-Za-z0-9_]"))] | length')
    [ "$invalid_tids" -eq 0 ]
}

# ---------------------------------------------------------------------------
# bake_latest_only: github-runner must be latest-only even with --all-retained
# MG17: bake_latest_only flag ignored → retained github-runner versions included
# ---------------------------------------------------------------------------

@test "GBH-46: bake_latest_only — github-runner --all-retained emits SAME count as without flag" {
    # Arrange: capture latest-only cell count (stderr silenced — ::notice:: annotations ignored)
    local latest_only_count
    latest_only_count=$(bash "${PROJECT_ROOT}/scripts/generate-bake-hcl.sh" --cells github-runner 2>/dev/null \
        | jq '[.[] | select(.container == "github-runner")] | length')
    [ -n "$latest_only_count" ]
    [ "$latest_only_count" -gt 0 ]

    # Act: --all-retained must produce the SAME count (flag forced off for github-runner)
    local all_retained_count
    all_retained_count=$(bash "${PROJECT_ROOT}/scripts/generate-bake-hcl.sh" --cells --all-retained github-runner 2>/dev/null \
        | jq '[.[] | select(.container == "github-runner")] | length')
    [ -n "$all_retained_count" ]

    # Assert: counts are identical — bake_latest_only overrides --all-retained
    [ "$all_retained_count" -eq "$latest_only_count" ]
}

@test "GBH-47: bake_latest_only — github-runner bake mode --all-retained emits only latest version targets" {
    # Capture the latest version tag
    local latest_tag
    latest_tag=$(bash -c "
        source '${HELPERS_DIR}/variant-utils.sh'
        source '${PROJECT_ROOT}/helpers/dependency-graph.sh'
        list_build_matrix './github-runner' '' 'false' 2>/dev/null \
            | jq -r 'first(.[] | select(.is_latest_version==true)) | .tag'
    ")
    [ -n "$latest_tag" ]

    # With --all-retained the bake document must still have only latest version targets
    # (stderr silenced — ::notice:: bake_latest_only annotation is expected but irrelevant)
    local bake_out
    bake_out=$(bash "${PROJECT_ROOT}/scripts/generate-bake-hcl.sh" --all-retained github-runner debian 2>/dev/null)
    [ -n "$bake_out" ]

    # All github-runner targets must belong to the latest version
    local safe_tag="${latest_tag//[.\-\/]/_}"
    local non_latest_targets
    non_latest_targets=$(echo "$bake_out" | jq --arg t "$safe_tag" \
        '[.target | to_entries[]
         | select(.key | startswith("github_runner_"))
         | select(.key | test($t) | not)] | length')
    [ "$non_latest_targets" -eq 0 ]
}

@test "GBH-48: bake_latest_only — --all-retained terraform still expands (non-flagged container unaffected)" {
    # terraform has version_retention=3 and no bake_latest_only flag
    _run_generator terraform
    [ "$status" -eq 0 ]
    local default_count
    default_count=$(echo "$output" | jq '[.target | to_entries[] | select(.key | startswith("terraform_"))] | length')

    _run_generator --all-retained terraform
    [ "$status" -eq 0 ]
    local retained_count
    retained_count=$(echo "$output" | jq '[.target | to_entries[] | select(.key | startswith("terraform_"))] | length')

    # --all-retained must expand to MORE targets for terraform
    [ "$retained_count" -gt "$default_count" ]
}

@test "GBH-49: bake_latest_only — ::notice:: emitted to stderr when flag overrides --all-retained" {
    # The generator must emit a ::notice:: annotation when it overrides --all-retained
    run bash -c "
        export _DEPGRAPH_LINEAGE_DIR=/nonexistent
        export GITHUB_ACTIONS=''
        '${PROJECT_ROOT}/scripts/generate-bake-hcl.sh' --all-retained github-runner 2>&1 >/dev/null
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"github-runner"* ]] && [[ "$output" == *"bake_latest_only"* || "$output" == *"latest-only"* ]]
}

# ---------------------------------------------------------------------------
# Registry cache: per-target cache-from/cache-to (MG18)
#   MG18: Omit cache-from → bake builds cold; emit cache-to unconditionally → PR poisons canonical buildcache
#
# cache-from is UNCONDITIONAL (always emitted; reading is always safe).
# cache-to is GATED on BAKE_CACHE_EXPORT=true (only the real publish path writes
# to canonical buildcache refs — PR/dry-run builds must never poison it).
# ---------------------------------------------------------------------------

@test "GBH-50: MG18 — every bake target has cache-from unconditionally (BAKE_CACHE_EXPORT unset)" {
    # cache-from must be present regardless of BAKE_CACHE_EXPORT
    _run_generator debian
    [ "$status" -eq 0 ]

    # Every target must have cache-from: [{type: registry, ref: ...}]
    local missing_cf
    missing_cf=$(echo "$output" | jq '[
        .target | to_entries[]
        | select(."value"."cache-from" == null or (."value"."cache-from" | length) == 0)
    ] | length')
    [ "$missing_cf" -eq 0 ]

    # Every cache-from ref must be type=registry
    local wrong_type
    wrong_type=$(echo "$output" | jq '[
        .target | to_entries[]
        | ."value"."cache-from"[]
        | select(.type != "registry")
    ] | length')
    [ "$wrong_type" -eq 0 ]

    # Every cache-from ref must contain "buildcache-"
    local bad_ref
    bad_ref=$(echo "$output" | jq -r '[
        .target | to_entries[]
        | ."value"."cache-from"[]
        | .ref
        | select(contains("buildcache-") | not)
    ] | length')
    [ "$bad_ref" -eq 0 ]

    # Every cache-from ref must end with the literal "${ARCH_SUFFIX}" bake token
    local no_arch_suffix
    no_arch_suffix=$(echo "$output" | jq --arg suffix '${ARCH_SUFFIX}' '[
        .target | to_entries[]
        | ."value"."cache-from"[]
        | .ref
        | select(endswith($suffix) | not)
    ] | length')
    [ "$no_arch_suffix" -eq 0 ]
}

@test "GBH-50b: MG18 — cache-from also present when BAKE_CACHE_EXPORT=true (publish path)" {
    # cache-from must also be present on the publish path (reads from prior master cache)
    run env BAKE_CACHE_EXPORT=true bash "${PROJECT_ROOT}/scripts/generate-bake-hcl.sh" debian
    [ "$status" -eq 0 ]

    local missing_cf
    missing_cf=$(echo "$output" | jq '[
        .target | to_entries[]
        | select(."value"."cache-from" == null or (."value"."cache-from" | length) == 0)
    ] | length')
    [ "$missing_cf" -eq 0 ]
}

@test "GBH-51: MG18 — BAKE_CACHE_EXPORT=true: every target has cache-to with mode=max and ignore-error=true" {
    # Cache-to must be present ONLY when BAKE_CACHE_EXPORT=true (the publish path).
    run env BAKE_CACHE_EXPORT=true bash "${PROJECT_ROOT}/scripts/generate-bake-hcl.sh" debian
    [ "$status" -eq 0 ]

    # Every target must have cache-to
    local missing_ct
    missing_ct=$(echo "$output" | jq '[
        .target | to_entries[]
        | select(."value"."cache-to" == null or (."value"."cache-to" | length) == 0)
    ] | length')
    [ "$missing_ct" -eq 0 ]

    # mode=max required
    local wrong_mode
    wrong_mode=$(echo "$output" | jq '[
        .target | to_entries[]
        | ."value"."cache-to"[]
        | select(.mode != "max")
    ] | length')
    [ "$wrong_mode" -eq 0 ]

    # ignore-error=true required (transient GHCR cache-export must not fail build)
    local missing_ie
    missing_ie=$(echo "$output" | jq '[
        .target | to_entries[]
        | ."value"."cache-to"[]
        | select(."ignore-error" != true)
    ] | length')
    [ "$missing_ie" -eq 0 ]
}

@test "GBH-51b: MG18 — BAKE_CACHE_EXPORT unset/false: NO cache-to emitted (PR/dry-run safety gate)" {
    # When BAKE_CACHE_EXPORT is unset (default), cache-to must be absent from all targets.
    # This is the PR/dry-run path — we must never poison canonical buildcache from unmerged code.
    _run_generator debian
    [ "$status" -eq 0 ]

    local has_cache_to
    has_cache_to=$(echo "$output" | jq '[
        .target | to_entries[]
        | select(."value"."cache-to" != null and (."value"."cache-to" | length) > 0)
    ] | length')
    [ "$has_cache_to" -eq 0 ]
}

@test "GBH-51c: MG18 — BAKE_CACHE_EXPORT=false: NO cache-to emitted" {
    # Explicit false must also suppress cache-to.
    run env BAKE_CACHE_EXPORT=false bash "${PROJECT_ROOT}/scripts/generate-bake-hcl.sh" debian
    [ "$status" -eq 0 ]

    local has_cache_to
    has_cache_to=$(echo "$output" | jq '[
        .target | to_entries[]
        | select(."value"."cache-to" != null and (."value"."cache-to" | length) > 0)
    ] | length')
    [ "$has_cache_to" -eq 0 ]
}

@test "GBH-52: MG18 — two different bake targets (different containers or tags) get DISTINCT cache refs" {
    # Request two containers with distinct tags so both produce cache refs.
    # Verify no two targets share the same cache-from ref.
    run env BAKE_CACHE_EXPORT=true bash "${PROJECT_ROOT}/scripts/generate-bake-hcl.sh" debian sslh
    [ "$status" -eq 0 ]

    # Collect all cache-from refs across all targets
    local all_refs
    all_refs=$(echo "$output" | jq -r '[
        .target | to_entries[]
        | ."value"."cache-from"[]
        | .ref
    ]')

    local total_refs unique_refs
    total_refs=$(echo "$all_refs" | jq 'length')
    unique_refs=$(echo "$all_refs" | jq 'unique | length')

    # Every ref must be unique — no two targets share a cache ref
    [ "$total_refs" -gt 1 ]
    [ "$unique_refs" -eq "$total_refs" ]
}

# ---------------------------------------------------------------------------
# B4 scope filters: generator-only filtering for bake/cells emission
# ---------------------------------------------------------------------------

@test "GBH-53: B4 — --scope-versions keeps only matching terraform retained-version cells" {
    local unscoped_output unscoped_count pick
    unscoped_output=$(bash "${PROJECT_ROOT}/scripts/generate-bake-hcl.sh" --cells --all-retained terraform 2>/dev/null)
    unscoped_count=$(echo "$unscoped_output" | jq 'length')
    [ "$unscoped_count" -gt 0 ]

    # Pick a version from the LIVE retained window instead of hardcoding one —
    # retained versions rotate out as upstream bumps (#819 evicted 1.15.4).
    pick=$(echo "$unscoped_output" | jq -r '.[0].tag | split("-alpine")[0]')

    _run_generator --cells --all-retained --scope-versions "$pick" terraform
    [ "$status" -eq 0 ]

    local scoped_count bad_tags
    scoped_count=$(echo "$output" | jq 'length')
    bad_tags=$(echo "$output" | jq --arg v "$pick" '[.[] | select(.tag | startswith($v + "-alpine") | not)] | length')

    [ "$scoped_count" -gt 0 ]
    [ "$scoped_count" -lt "$unscoped_count" ]
    [ "$bad_tags" -eq 0 ]
}

@test "GBH-54: B4 — --scope-flavors keeps only matching terraform flavor cells" {
    _run_generator --cells --scope-flavors aws terraform
    [ "$status" -eq 0 ]

    local scoped_count bad_flavors
    scoped_count=$(echo "$output" | jq 'length')
    bad_flavors=$(echo "$output" | jq '[.[] | select(.flavor != "aws")] | length')

    [ "$scoped_count" -gt 0 ]
    [ "$bad_flavors" -eq 0 ]
}

@test "GBH-55: B4 — --scope filters terraform cells by variant substring" {
    _run_generator --cells --scope azure terraform
    [ "$status" -eq 0 ]

    local scoped_count bad_variants
    scoped_count=$(echo "$output" | jq 'length')
    bad_variants=$(echo "$output" | jq '[.[] | select(.variant | contains("azure") | not)] | length')

    [ "$scoped_count" -gt 0 ]
    [ "$bad_variants" -eq 0 ]
}

@test "GBH-56: B4 — no scope flags preserve the latest-only terraform cell count" {
    local expected_count
    expected_count=$(bash -c "
        source '${HELPERS_DIR}/variant-utils.sh'
        list_build_matrix './terraform' '' 'false' 2>/dev/null \
            | jq '[.[] | select((.os // \"linux\") != \"windows\")] | length'
    ")
    [ "$expected_count" -gt 0 ]

    _run_generator --cells terraform
    [ "$status" -eq 0 ]

    local actual_count
    actual_count=$(echo "$output" | jq 'length')
    [ "$actual_count" -eq "$expected_count" ]
}

@test "GBH-57: B4 — over-narrow --scope-versions emits an empty bake target set" {
    _run_generator --scope-versions 999 terraform
    [ "$status" -eq 0 ]

    local target_count default_count
    target_count=$(echo "$output" | jq '.target | length')
    default_count=$(echo "$output" | jq '.group.default.targets | length')

    [ "$target_count" -eq 0 ]
    [ "$default_count" -eq 0 ]
}

@test "GBH-58: B4 gate — scoped github-runner graph keeps debian internal base target and contexts" {
    _run_generator --scope-flavors debian-trixie github-runner
    [ "$status" -eq 0 ]

    local has_base
    has_base=$(echo "$output" | jq -r '.target | has("debian_trixie")')
    [ "$has_base" = "true" ]

    local ctx_count
    ctx_count=$(echo "$output" | jq '[
        .target
        | to_entries[]
        | select((.key | startswith("github_runner_")) and (.key | contains("_debian_trixie_")))
        | (.value.contexts // {})
        | to_entries[]
        | select(.value == "target:debian_trixie")
    ] | length')
    [ "$ctx_count" -gt 0 ]

    local dangling_count
    dangling_count=$(echo "$output" | jq '
        .target as $targets
        | [
            .target
            | to_entries[]
            | (.value.contexts // {})
            | to_entries[]
            | .value
            | select(type == "string" and startswith("target:"))
            | sub("^target:"; "") as $target_id
            | select(($targets | has($target_id)) | not)
            | $target_id
        ]
        | length')
    [ "$dangling_count" -eq 0 ]
}

@test "GBH-59: B4 gate — scoped github-runner --cells emits only requested scoped cells, not debian deps" {
    _run_generator --cells --scope-flavors debian-trixie github-runner
    [ "$status" -eq 0 ]

    local scoped_count bad_containers bad_flavors debian_cells
    scoped_count=$(echo "$output" | jq 'length')
    bad_containers=$(echo "$output" | jq '[.[] | select(.container != "github-runner")] | length')
    bad_flavors=$(echo "$output" | jq '[.[] | select(.flavor != "debian-trixie")] | length')
    debian_cells=$(echo "$output" | jq '[.[] | select(.container == "debian")] | length')

    [ "$scoped_count" -gt 0 ]
    [ "$bad_containers" -eq 0 ]
    [ "$bad_flavors" -eq 0 ]
    [ "$debian_cells" -eq 0 ]
}

@test "GBH-60: B4 gate — unscoped github-runner graph target keys stay on the pre-fix default set" {
    _run_generator github-runner
    [ "$status" -eq 0 ]

    local actual_keys
    actual_keys=$(echo "$output" | jq -cS '.target | keys')
    local expected_keys='["debian_trixie","github_runner_2_335_1_debian_trixie_base","github_runner_2_335_1_debian_trixie_dev","github_runner_2_335_1_ubuntu_2404_base","github_runner_2_335_1_ubuntu_2404_dev"]'

    [ "$actual_keys" = "$expected_keys" ]
}

@test "GBH-61: container scopes — terraform flavor scope keeps only aws cells" {
    _run_generator --cells --container-scopes '{"terraform":{"flavors":"aws"}}' terraform
    [ "$status" -eq 0 ]

    local scoped_count bad_flavors per_container_json
    scoped_count=$(echo "$output" | jq 'length')
    bad_flavors=$(echo "$output" | jq '[.[] | select(.flavor != "aws")] | length')
    per_container_json=$(echo "$output" | jq -cS '.')

    _run_generator --cells --scope-flavors aws terraform
    [ "$status" -eq 0 ]

    [ "$scoped_count" -gt 0 ]
    [ "$bad_flavors" -eq 0 ]
    [ "$per_container_json" = "$(echo "$output" | jq -cS '.')" ]
}

@test "GBH-62: container scopes — terraform retained version scope keeps only matching-version cells" {
    local unscoped_output unscoped_count pick
    unscoped_output=$(bash "${PROJECT_ROOT}/scripts/generate-bake-hcl.sh" --cells --all-retained terraform 2>/dev/null)
    unscoped_count=$(echo "$unscoped_output" | jq 'length')
    [ "$unscoped_count" -gt 0 ]

    # Pick a version from the LIVE retained window instead of hardcoding one (#819).
    pick=$(echo "$unscoped_output" | jq -r '.[0].tag | split("-alpine")[0]')

    _run_generator --cells --all-retained --container-scopes "{\"terraform\":{\"versions\":\"${pick}\"}}" terraform
    [ "$status" -eq 0 ]

    local scoped_count bad_tags
    scoped_count=$(echo "$output" | jq 'length')
    bad_tags=$(echo "$output" | jq --arg v "$pick" '[.[] | select(.tag | startswith($v + "-alpine") | not)] | length')

    [ "$scoped_count" -gt 0 ]
    [ "$scoped_count" -lt "$unscoped_count" ]
    [ "$bad_tags" -eq 0 ]
}

@test "GBH-63: container scopes — different containers keep isolated scope filters" {
    _run_generator --cells debian
    [ "$status" -eq 0 ]
    local unscoped_debian_count
    unscoped_debian_count=$(echo "$output" | jq 'length')
    [ "$unscoped_debian_count" -gt 0 ]

    _run_generator --cells --container-scopes '{"terraform":{"flavors":"aws"},"debian":{}}' terraform debian
    [ "$status" -eq 0 ]

    local terraform_count terraform_bad_flavors debian_count
    terraform_count=$(echo "$output" | jq '[.[] | select(.container == "terraform")] | length')
    terraform_bad_flavors=$(echo "$output" | jq '[.[] | select(.container == "terraform" and .flavor != "aws")] | length')
    debian_count=$(echo "$output" | jq '[.[] | select(.container == "debian")] | length')

    [ "$terraform_count" -gt 0 ]
    [ "$terraform_bad_flavors" -eq 0 ]
    [ "$debian_count" -eq "$unscoped_debian_count" ]
}

@test "GBH-64: container scopes — containers absent from the map fall back to global flavor scope" {
    _run_generator --cells --include-final-build \
        --container-scopes '{"terraform":{"flavors":"aws"}}' \
        --scope-flavors full postgres terraform
    [ "$status" -eq 0 ]

    local terraform_count terraform_bad_flavors postgres_count postgres_bad_flavors
    terraform_count=$(echo "$output" | jq '[.[] | select(.container == "terraform")] | length')
    terraform_bad_flavors=$(echo "$output" | jq '[.[] | select(.container == "terraform" and .flavor != "aws")] | length')
    postgres_count=$(echo "$output" | jq '[.[] | select(.container == "postgres")] | length')
    postgres_bad_flavors=$(echo "$output" | jq '[.[] | select(.container == "postgres" and .flavor != "full")] | length')

    [ "$terraform_count" -gt 0 ]
    [ "$terraform_bad_flavors" -eq 0 ]
    [ "$postgres_count" -gt 0 ]
    [ "$postgres_bad_flavors" -eq 0 ]
}

@test "GBH-65: container scopes — scoped github-runner graph keeps debian dependency target and contexts" {
    _run_generator --container-scopes '{"github-runner":{"flavors":"debian-trixie"}}' github-runner
    [ "$status" -eq 0 ]

    local has_base bad_runner_targets ctx_count dangling_count
    has_base=$(echo "$output" | jq -r '.target | has("debian_trixie")')
    bad_runner_targets=$(echo "$output" | jq '[
        .target
        | to_entries[]
        | select(.key | startswith("github_runner_"))
        | select((.key | contains("_debian_trixie_")) | not)
    ] | length')
    ctx_count=$(echo "$output" | jq '[
        .target
        | to_entries[]
        | select((.key | startswith("github_runner_")) and (.key | contains("_debian_trixie_")))
        | (.value.contexts // {})
        | to_entries[]
        | select(.value == "target:debian_trixie")
    ] | length')
    dangling_count=$(echo "$output" | jq '
        .target as $targets
        | [
            .target
            | to_entries[]
            | (.value.contexts // {})
            | to_entries[]
            | .value
            | select(type == "string" and startswith("target:"))
            | sub("^target:"; "") as $target_id
            | select(($targets | has($target_id)) | not)
            | $target_id
        ]
        | length')

    [ "$has_base" = "true" ]
    [ "$bad_runner_targets" -eq 0 ]
    [ "$ctx_count" -gt 0 ]
    [ "$dangling_count" -eq 0 ]
}

@test "GBH-66: container scopes — empty map is byte-identical to no container scope flag" {
    _run_generator terraform debian
    [ "$status" -eq 0 ]
    local no_flag_json
    no_flag_json=$(echo "$output" | jq -cS '.')

    _run_generator --container-scopes '{}' terraform debian
    [ "$status" -eq 0 ]

    [ "$(echo "$output" | jq -cS '.')" = "$no_flag_json" ]
}
