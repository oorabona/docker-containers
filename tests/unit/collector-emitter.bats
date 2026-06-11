#!/usr/bin/env bats

# Unit tests for the _emit_collector_stage helper and the two call sites
# (artifact-present with version_digests, self-heal) in generate_dockerfile.
#
# Tests:
#   (a) artifact-present digest-pinned emission
#   (b) self-heal tag-resolved emission
#   (c) single-version unchanged (no collector)
#   (d) empty/ceiling-absent → fail-closed
#   (e) version in available but missing from version_digests → fail-closed
#   (f) depth: a synthetic 30-version set yields exactly ONE final-stage COPY

bats_require_minimum_version 1.5.0

load "../test_helper"

_source_extension_utils() {
    # shellcheck disable=SC1091
    source "$HELPERS_DIR/extension-utils.sh"
}

setup() {
    setup_temp_dir
    export ROOT_DIR="$TEST_TEMP_DIR"
    mkdir -p "$TEST_TEMP_DIR/.build-lineage"

    # Config: timescaledb (resolver-backed) + pgvector (single-version)
    mkdir -p "$TEST_TEMP_DIR/extensions"
    cat > "$TEST_TEMP_DIR/extensions/config.yaml" <<'EOF'
extensions:
  timescaledb:
    version: "2.27.1"
    repo: "timescale/timescaledb"
    priority: 1
    version_set:
      resolver: "scripts/resolvers/timescaledb-ha.sh"
  pgvector:
    version: "0.8.2"
    repo: "pgvector/pgvector"
    priority: 2

flavors:
  timeseries:
    - timescaledb
  multi_mixed:
    - timescaledb
    - pgvector
  vector:
    - pgvector
EOF

    # Minimal Dockerfile template
    cat > "$TEST_TEMP_DIR/Dockerfile.template" <<'EOF'
ARG VERSION
# @@EXTENSION_STAGES@@
FROM postgres:${VERSION}
# @@EXTENSION_COPIES@@
# @@RUNTIME_DEPS@@
EOF

    _source_extension_utils

    get_registry()   { echo "ghcr.io"; }
    get_repo_owner() { echo "testowner"; }
    export -f get_registry get_repo_owner
}

teardown() {
    teardown_temp_dir
    unset ROOT_DIR
}

# ---------------------------------------------------------------------------
# Helper: write versionset WITH version_digests (CI/publish path)
# ---------------------------------------------------------------------------
_write_versionset_with_digests() {
    local ext="$1" pg_major="$2"
    shift 2
    local -a available_arr=("$@")

    local arr_json="["
    local first=1
    for v in "${available_arr[@]}"; do
        [[ "$first" -eq 0 ]] && arr_json+=","
        arr_json+="\"$v\""
        first=0
    done
    arr_json+="]"

    local vd_json="{"
    local idx=1
    local vd_first=1
    for v in "${available_arr[@]}"; do
        [[ "$vd_first" -eq 0 ]] && vd_json+=","
        local hex_idx
        hex_idx=$(printf '%064x' "$idx")
        vd_json+="\"${v}\":\"sha256:${hex_idx}\""
        vd_first=0
        idx=$((idx + 1))
    done
    vd_json+="}"

    cat > "$TEST_TEMP_DIR/.build-lineage/ext-${ext}-pg${pg_major}-versionset.json" <<EOF
{"ext":"${ext}","pg_major":"${pg_major}","ceiling":"${available_arr[-1]}","resolved":${arr_json},"available":${arr_json},"excluded":[],"version_digests":${vd_json}}
EOF
}

# ---------------------------------------------------------------------------
# (a) Artifact-present digest-pinned emission
# ---------------------------------------------------------------------------
@test "(a) artifact with version_digests → collector stage with digest-pinned per-version COPYs" {
    _write_versionset_with_digests "timescaledb" "18" "2.23.0" "2.25.0" "2.27.1"

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # Collector stage must be declared
    echo "$output" | grep -Eqx '^FROM scratch AS ext_collect_timescaledb$'

    # Per-version COPYs inside collector must use repo@digest format
    local pinned_count
    pinned_count=$(echo "$output" | grep -cE "COPY --from=ghcr\.io/testowner/ext-timescaledb@sha256:" || true)
    [ "$pinned_count" -eq 3 ]

    # Each per-version COPY must land at /<ver>/ inside the collector
    echo "$output" | grep -Eqx '^COPY --from=ghcr\.io/testowner/ext-timescaledb@sha256:[a-f0-9]+ /output/ /2\.23\.0/$'
    echo "$output" | grep -Eqx '^COPY --from=ghcr\.io/testowner/ext-timescaledb@sha256:[a-f0-9]+ /output/ /2\.27\.1/$'

    # Exactly ONE final-stage COPY from the collector
    local final_count
    final_count=$(echo "$output" | grep -c "COPY --from=ext_collect_timescaledb / /tmp/ext/timescaledb/" || true)
    [ "$final_count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# (b) Self-heal tag-resolved emission
# ---------------------------------------------------------------------------
@test "(b) self-heal (no artifact) → collector stage with tag-based per-version COPYs" {
    # No artifact on disk → self-heal triggers

    resolve_version_set() {
        echo '["2.23.0","2.25.0","2.27.1"]'
    }
    export -f resolve_version_set

    image_exists_in_registry() { return 0; }
    export -f image_exists_in_registry

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # Collector stage present
    echo "$output" | grep -Eqx '^FROM scratch AS ext_collect_timescaledb$'

    # Per-version COPYs inside collector use tag-based refs (no @digest)
    local per_ver_count
    per_ver_count=$(echo "$output" | grep -cE "COPY --from=ghcr\.io/testowner/ext-timescaledb:pg18-[0-9]+\.[0-9]+\.[0-9]+ /output/ /" || true)
    [ "$per_ver_count" -eq 3 ]

    # Exactly ONE final-stage COPY
    local final_count
    final_count=$(echo "$output" | grep -c "COPY --from=ext_collect_timescaledb / /tmp/ext/timescaledb/" || true)
    [ "$final_count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# (c) Single-version unchanged — no collector emitted
# ---------------------------------------------------------------------------
@test "(c) single available version → single-version FROM path, no collector" {
    # Artifact with exactly one version (ceiling only)
    cat > "$TEST_TEMP_DIR/.build-lineage/ext-timescaledb-pg18-versionset.json" <<'EOF'
{"ext":"timescaledb","pg_major":"18","ceiling":"2.27.1","resolved":["2.27.1"],"available":["2.27.1"],"excluded":[]}
EOF

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # No collector stage
    local collector_count
    collector_count=$(echo "$output" | grep -c "^FROM scratch AS ext_collect_timescaledb" || true)
    [ "$collector_count" -eq 0 ]

    # Single-version FROM stage present
    local from_count
    from_count=$(echo "$output" | grep -c "FROM ghcr.io/testowner/ext-timescaledb:pg18-2.27.1 AS ext-timescaledb" || true)
    [ "$from_count" -eq 1 ]

    # Flat COPY paths (no /<ver>/ subdirectory)
    echo "$output" | grep -Eqx '^COPY --from=ext-timescaledb /output/extension/ /tmp/ext/timescaledb/extension/$'
}

# ---------------------------------------------------------------------------
# (d) Empty available → fail-closed
# ---------------------------------------------------------------------------
@test "(d) empty available[] → generate_dockerfile fails closed" {
    cat > "$TEST_TEMP_DIR/.build-lineage/ext-timescaledb-pg18-versionset.json" <<'EOF'
{"ext":"timescaledb","pg_major":"18","ceiling":"2.27.1","resolved":["2.23.0","2.27.1"],"available":[],"excluded":[]}
EOF

    resolve_version_set() {
        echo "::error::simulated resolver failure" >&2
        return 1
    }
    export -f resolve_version_set

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    # Fail closed: empty available + resolver fails → non-zero
    [ "$status" -ne 0 ]
}

# (d-2) ceiling absent from available → fail-closed
@test "(d-2) ceiling absent from non-empty available[] → fail-closed" {
    cat > "$TEST_TEMP_DIR/.build-lineage/ext-timescaledb-pg18-versionset.json" <<'EOF'
{"ext":"timescaledb","pg_major":"18","ceiling":"2.27.1","resolved":["2.23.0","2.25.0","2.27.1"],"available":["2.23.0","2.25.0"],"excluded":[{"version":"2.27.1","reason":"not available"}]}
EOF

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# (e) Version in available but missing from version_digests → fail-closed
# ---------------------------------------------------------------------------
@test "(e) version in available[] absent from version_digests → fail-closed" {
    # Artifact: 3 versions in available but version_digests only has 2
    cat > "$TEST_TEMP_DIR/.build-lineage/ext-timescaledb-pg18-versionset.json" <<'EOF'
{"ext":"timescaledb","pg_major":"18","ceiling":"2.27.1","resolved":["2.23.0","2.25.0","2.27.1"],"available":["2.23.0","2.25.0","2.27.1"],"excluded":[],"version_digests":{"2.25.0":"sha256:0000000000000000000000000000000000000000000000000000000000000001","2.27.1":"sha256:0000000000000000000000000000000000000000000000000000000000000002"}}
EOF

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    # 2.23.0 is in available but absent from version_digests → fail closed
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# (f) Depth: 30 synthetic versions → exactly ONE final-stage COPY
# ---------------------------------------------------------------------------
@test "(f) 30-version set → exactly ONE final-stage COPY (count-independent)" {
    # Generate artifact with 30 versions
    local arr_json="["
    local vd_json="{"
    local ceiling_ver=""
    local first=1
    for i in $(seq 1 30); do
        local v="2.${i}.0"
        [[ "$first" -eq 0 ]] && arr_json+="," && vd_json+=","
        arr_json+="\"$v\""
        local hex_idx
        hex_idx=$(printf '%064x' "$i")
        vd_json+="\"${v}\":\"sha256:${hex_idx}\""
        ceiling_ver="$v"
        first=0
    done
    arr_json+="]"
    vd_json+="}"

    cat > "$TEST_TEMP_DIR/.build-lineage/ext-timescaledb-pg18-versionset.json" <<EOF
{"ext":"timescaledb","pg_major":"18","ceiling":"${ceiling_ver}","resolved":${arr_json},"available":${arr_json},"excluded":[],"version_digests":${vd_json}}
EOF

    # Update config to have ceiling matching our last version
    cat > "$TEST_TEMP_DIR/extensions/config.yaml" <<EOF
extensions:
  timescaledb:
    version: "${ceiling_ver}"
    repo: "timescale/timescaledb"
    priority: 1
    version_set:
      resolver: "scripts/resolvers/timescaledb-ha.sh"

flavors:
  timeseries:
    - timescaledb
EOF

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # Collector stage declared exactly once
    local collector_count
    collector_count=$(echo "$output" | grep -c "^FROM scratch AS ext_collect_timescaledb" || true)
    [ "$collector_count" -eq 1 ]

    # 30 per-version COPYs inside the collector
    local per_ver_count
    per_ver_count=$(echo "$output" | grep -cE "COPY --from=ghcr\.io/testowner/ext-timescaledb@sha256: /output/ /" || true)
    # They may appear with hex digest refs; count by /output/ / pattern
    per_ver_count=$(echo "$output" | grep -c "COPY --from=ghcr.io/testowner/ext-timescaledb@sha256:" || true)
    [ "$per_ver_count" -eq 30 ]

    # Exactly ONE final-stage COPY — count-independent regardless of version count
    local final_count
    final_count=$(echo "$output" | grep -c "COPY --from=ext_collect_timescaledb / /tmp/ext/timescaledb/" || true)
    [ "$final_count" -eq 1 ]
}
