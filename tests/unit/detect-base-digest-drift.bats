#!/usr/bin/env bats

# Unit tests for scripts/detect-base-digest-drift.sh
#
# BDD scenarios from spec §4. All registry calls are stubbed via PROBE_CMD.
# PROBE_CMD is a function exported from setup() that reads pre-captured
# JSON responses from tests/fixtures/digest-drift/*/responses/.
#
# Mutation guards documented per spec §6:
#   MG1: Remove digest comparison → debian reports drift (false positive)
#   MG2: Remove sidecar filter → foo's variants array has 3 entries
#   MG3: Remove per-container grouping → result has 2 records instead of 1
#   MG4: Remove digest shape validation → invalid digest accepted
#
# BDD scenario covered explicitly: "Per-container grouping (2×2 mutation guard)"
# per spec §4 Scenario 6 — this test directly implements the 2×2 grouping assertion.

load "../test_helper"

DETECTOR_SCRIPT=""
FIXTURES_DIR_DRIFT=""

setup() {
    setup_temp_dir

    DETECTOR_SCRIPT="${SCRIPTS_DIR}/detect-base-digest-drift.sh"
    FIXTURES_DIR_DRIFT="${FIXTURES_DIR}/digest-drift"

    export TEST_TEMP_DIR
    export DETECTOR_SCRIPT
    export FIXTURES_DIR_DRIFT
}

teardown() {
    teardown_temp_dir
}

# ---------------------------------------------------------------------------
# Helper: create a probe stub that serves fixture responses by image ref.
# The stub maps image refs to JSON files in the given responses/ dir.
# Mapping table (image_ref → filename stem, : and / replaced with -):
#   alpine:3.21         → alpine-3.21.json
#   debian:trixie-slim  → debian-trixie-slim.json
#   ubuntu:24.04        → ubuntu-24.04.json
#   rockylinux:9        → rockylinux-9.json
# ---------------------------------------------------------------------------
_make_probe_stub() {
    local responses_dir="$1"
    local stub_path="$TEST_TEMP_DIR/bin/probe-stub"
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$stub_path" <<STUB_EOF
#!/usr/bin/env bash
# Fixture probe stub — maps image ref to a JSON file in responses/
image_ref="\$1"
responses_dir="${responses_dir}"

# Normalize: replace : and / with - (matching fixture filename convention)
key="\$(printf '%s' "\$image_ref" | tr ':/' '--')"
response_file="\${responses_dir}/\${key}.json"

if [[ -f "\$response_file" ]]; then
    cat "\$response_file"
    exit 0
else
    echo "stub: no fixture for '\$image_ref' (expected \$response_file)" >&2
    exit 1
fi
STUB_EOF
    chmod +x "$stub_path"
    printf '%s' "$stub_path"
}

# ---------------------------------------------------------------------------
# Helper: create a probe stub that always fails (simulates registry error)
# ---------------------------------------------------------------------------
_make_failing_probe_stub() {
    local stub_path="$TEST_TEMP_DIR/bin/probe-fail"
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$stub_path" <<'STUB_EOF'
#!/usr/bin/env bash
echo "stub: simulated registry failure for '$1'" >&2
exit 1
STUB_EOF
    chmod +x "$stub_path"
    printf '%s' "$stub_path"
}

# ---------------------------------------------------------------------------
# Helper: create a probe stub returning a specific digest for all refs
# ---------------------------------------------------------------------------
_make_digest_probe_stub() {
    local digest="$1"
    local stub_path="$TEST_TEMP_DIR/bin/probe-digest-$$"
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$stub_path" <<STUB_EOF
#!/usr/bin/env bash
printf '{"digest":"%s"}' "${digest}"
exit 0
STUB_EOF
    chmod +x "$stub_path"
    printf '%s' "$stub_path"
}

# ---------------------------------------------------------------------------
# Scenario 1 (spec §4): Drift detected for a single variant (real registry shape)
# Observable Success fixture: scenario-1
# Alpine recorded=aaa...→current=ccc... (drift), Debian recorded==current (unchanged)
# Sidecar foo-1.0-alpine.sbom.json must be excluded
# ---------------------------------------------------------------------------
@test "scenario-1: alpine reports drift, debian reports unchanged, sidecar excluded" {
    local fixture_dir="${FIXTURES_DIR_DRIFT}/scenario-1"
    local probe_stub
    probe_stub=$(_make_probe_stub "${fixture_dir}/responses")

    result=$(PROBE_CMD="$probe_stub" \
        bash "${DETECTOR_SCRIPT}" "${fixture_dir}/.build-lineage")

    # Output must be valid JSON
    printf '%s' "$result" | jq '.' >/dev/null

    # Length: 1 container (foo)
    length=$(printf '%s' "$result" | jq 'length')
    [ "$length" -eq 1 ]

    # Container name is foo
    container=$(printf '%s' "$result" | jq -r '.[0].container')
    [ "$container" = "foo" ]

    # foo has 2 variants (alpine drift + debian unchanged)
    foo_variants=$(printf '%s' "$result" | jq '.[0].variants | length')
    [ "$foo_variants" -eq 2 ]

    # Alpine variant: status=drift
    alpine_status=$(printf '%s' "$result" | \
        jq -r '.[0].variants[] | select(.variant_tag == "1.0-alpine") | .status')
    [ "$alpine_status" = "drift" ]

    # Alpine variant: recorded_digest is the old one (aaaa...)
    alpine_recorded=$(printf '%s' "$result" | \
        jq -r '.[0].variants[] | select(.variant_tag == "1.0-alpine") | .recorded_digest')
    [[ "$alpine_recorded" =~ ^sha256:[a-f0-9]{64}$ ]]

    # Alpine variant: current_digest is different (cccc...)
    alpine_current=$(printf '%s' "$result" | \
        jq -r '.[0].variants[] | select(.variant_tag == "1.0-alpine") | .current_digest')
    [[ "$alpine_current" =~ ^sha256:[a-f0-9]{64}$ ]]
    [ "$alpine_current" != "$alpine_recorded" ]

    # Debian variant: status=unchanged
    debian_status=$(printf '%s' "$result" | \
        jq -r '.[0].variants[] | select(.variant_tag == "1.0-debian") | .status')
    [ "$debian_status" = "unchanged" ]

    # Sidecar excluded: no sbom reference in output
    [[ "$result" != *"sbom"* ]]
}

# MG3: Per-container grouping — removing it would produce 2 records instead of 1
# This test directly guards against that regression.
@test "scenario-1: output length is 1 (per-container grouping guard MG3)" {
    local fixture_dir="${FIXTURES_DIR_DRIFT}/scenario-1"
    local probe_stub
    probe_stub=$(_make_probe_stub "${fixture_dir}/responses")

    result=$(PROBE_CMD="$probe_stub" \
        bash "${DETECTOR_SCRIPT}" "${fixture_dir}/.build-lineage")

    length=$(printf '%s' "$result" | jq 'length')
    [ "$length" -eq 1 ]
}

# MG1: Digest comparison — if comparison were removed, debian would also report drift
@test "scenario-1: debian status is unchanged (digest comparison guard MG1)" {
    local fixture_dir="${FIXTURES_DIR_DRIFT}/scenario-1"
    local probe_stub
    probe_stub=$(_make_probe_stub "${fixture_dir}/responses")

    result=$(PROBE_CMD="$probe_stub" \
        bash "${DETECTOR_SCRIPT}" "${fixture_dir}/.build-lineage")

    debian_status=$(printf '%s' "$result" | \
        jq -r '.[0].variants[] | select(.variant_tag == "1.0-debian") | .status')
    [ "$debian_status" = "unchanged" ]
}

# MG2: Sidecar filter — removing it would produce 3 variants instead of 2
@test "scenario-1: foo has exactly 2 variants (sidecar exclusion guard MG2)" {
    local fixture_dir="${FIXTURES_DIR_DRIFT}/scenario-1"
    local probe_stub
    probe_stub=$(_make_probe_stub "${fixture_dir}/responses")

    result=$(PROBE_CMD="$probe_stub" \
        bash "${DETECTOR_SCRIPT}" "${fixture_dir}/.build-lineage")

    foo_variants=$(printf '%s' "$result" | jq '.[0].variants | length')
    [ "$foo_variants" -eq 2 ]
}

# MG4: Digest shape validation — valid digests must match ^sha256:[a-f0-9]{64}$
@test "scenario-1: all digests in output match sha256:[a-f0-9]{64} (shape guard MG4)" {
    local fixture_dir="${FIXTURES_DIR_DRIFT}/scenario-1"
    local probe_stub
    probe_stub=$(_make_probe_stub "${fixture_dir}/responses")

    result=$(PROBE_CMD="$probe_stub" \
        bash "${DETECTOR_SCRIPT}" "${fixture_dir}/.build-lineage")

    # Extract all digest fields and verify shape
    while IFS= read -r dgst; do
        [[ -z "$dgst" ]] && continue
        [[ "$dgst" =~ ^sha256:[a-f0-9]{64}$ ]] || \
            { echo "FAIL: malformed digest '$dgst'"; return 1; }
    done < <(printf '%s' "$result" | \
        jq -r '.[].variants[] | .current_digest // empty, .recorded_digest // empty')
}

# ---------------------------------------------------------------------------
# Scenario 6 (spec §4): Per-container grouping (2×2 mutation guard)
# foo: 2 variants (alpine + debian), bar: 2 variants (ubuntu + rocky) — all drifted
# Output must have length 2 (grouped by container, NOT by variant)
# ---------------------------------------------------------------------------
@test "scenario-2: 2x2 grouping — output length is 2 (one per container)" {
    local fixture_dir="${FIXTURES_DIR_DRIFT}/scenario-2"
    local probe_stub
    probe_stub=$(_make_probe_stub "${fixture_dir}/responses")

    result=$(PROBE_CMD="$probe_stub" \
        bash "${DETECTOR_SCRIPT}" "${fixture_dir}/.build-lineage")

    printf '%s' "$result" | jq '.' >/dev/null

    length=$(printf '%s' "$result" | jq 'length')
    [ "$length" -eq 2 ]
}

@test "scenario-2: foo record contains 2 variants" {
    local fixture_dir="${FIXTURES_DIR_DRIFT}/scenario-2"
    local probe_stub
    probe_stub=$(_make_probe_stub "${fixture_dir}/responses")

    result=$(PROBE_CMD="$probe_stub" \
        bash "${DETECTOR_SCRIPT}" "${fixture_dir}/.build-lineage")

    foo_count=$(printf '%s' "$result" | \
        jq '[.[] | select(.container == "foo")] | .[0].variants | length')
    [ "$foo_count" -eq 2 ]
}

@test "scenario-2: bar record contains 2 variants" {
    local fixture_dir="${FIXTURES_DIR_DRIFT}/scenario-2"
    local probe_stub
    probe_stub=$(_make_probe_stub "${fixture_dir}/responses")

    result=$(PROBE_CMD="$probe_stub" \
        bash "${DETECTOR_SCRIPT}" "${fixture_dir}/.build-lineage")

    bar_count=$(printf '%s' "$result" | \
        jq '[.[] | select(.container == "bar")] | .[0].variants | length')
    [ "$bar_count" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Scenario 3 (spec §4): Probe fails — tri-state error (NOT collapsed to drift)
# ---------------------------------------------------------------------------
@test "probe-failure: status is error, not drift" {
    local fail_stub
    fail_stub=$(_make_failing_probe_stub)

    # Create a minimal lineage dir with one entry
    local lineage_dir="$TEST_TEMP_DIR/.build-lineage"
    mkdir -p "$lineage_dir"
    cat > "$lineage_dir/foo-1.0-alpine.json" <<'EOF'
{
  "lineage_schema_version": 2,
  "container": "foo",
  "tag": "1.0-alpine",
  "base_image_ref": "alpine:3.21",
  "base_image_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
EOF

    result=$(PROBE_CMD="$fail_stub" \
        bash "${DETECTOR_SCRIPT}" "$lineage_dir" 2>/dev/null)

    printf '%s' "$result" | jq '.' >/dev/null

    status_val=$(printf '%s' "$result" | \
        jq -r '.[0].variants[0].status')
    [ "$status_val" = "error" ]
}

@test "probe-failure: error status does not include current_digest field" {
    local fail_stub
    fail_stub=$(_make_failing_probe_stub)

    local lineage_dir="$TEST_TEMP_DIR/.build-lineage"
    mkdir -p "$lineage_dir"
    cat > "$lineage_dir/foo-1.0-alpine.json" <<'EOF'
{
  "lineage_schema_version": 2,
  "container": "foo",
  "tag": "1.0-alpine",
  "base_image_ref": "alpine:3.21",
  "base_image_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
EOF

    result=$(PROBE_CMD="$fail_stub" \
        bash "${DETECTOR_SCRIPT}" "$lineage_dir" 2>/dev/null)

    current_digest=$(printf '%s' "$result" | \
        jq -r '.[0].variants[0].current_digest // "null"')
    [ "$current_digest" = "null" ]
}

# ---------------------------------------------------------------------------
# Scenario 4 (spec §4): Legacy lineage (no base_image_digest field)
# ---------------------------------------------------------------------------
@test "legacy: variant without base_image_digest gets status=legacy" {
    local lineage_dir="$TEST_TEMP_DIR/.build-lineage"
    mkdir -p "$lineage_dir"
    cat > "$lineage_dir/foo-1.0-alpine.json" <<'EOF'
{
  "lineage_schema_version": 1,
  "container": "foo",
  "tag": "1.0-alpine",
  "base_image_ref": "alpine:3.21"
}
EOF

    result=$(PROBE_CMD="/bin/false" \
        bash "${DETECTOR_SCRIPT}" "$lineage_dir" 2>/dev/null)

    printf '%s' "$result" | jq '.' >/dev/null

    status_val=$(printf '%s' "$result" | \
        jq -r '.[0].variants[0].status')
    [ "$status_val" = "legacy" ]
}

@test "legacy: variant with legacy flag set" {
    local lineage_dir="$TEST_TEMP_DIR/.build-lineage"
    mkdir -p "$lineage_dir"
    cat > "$lineage_dir/foo-1.0-alpine.json" <<'EOF'
{
  "lineage_schema_version": 1,
  "container": "foo",
  "tag": "1.0-alpine",
  "base_image_ref": "alpine:3.21"
}
EOF

    result=$(PROBE_CMD="/bin/false" \
        bash "${DETECTOR_SCRIPT}" "$lineage_dir" 2>/dev/null)

    legacy_flag=$(printf '%s' "$result" | \
        jq -r '.[0].variants[0].legacy')
    [ "$legacy_flag" = "true" ]
}

@test "legacy: unresolved base_image_digest also treated as legacy" {
    local lineage_dir="$TEST_TEMP_DIR/.build-lineage"
    mkdir -p "$lineage_dir"
    cat > "$lineage_dir/foo-1.0-alpine.json" <<'EOF'
{
  "lineage_schema_version": 2,
  "container": "foo",
  "tag": "1.0-alpine",
  "base_image_ref": "alpine:3.21",
  "base_image_digest": "unresolved"
}
EOF

    result=$(PROBE_CMD="/bin/false" \
        bash "${DETECTOR_SCRIPT}" "$lineage_dir" 2>/dev/null)

    status_val=$(printf '%s' "$result" | \
        jq -r '.[0].variants[0].status')
    [ "$status_val" = "legacy" ]
}

# ---------------------------------------------------------------------------
# Scenario 4 (spec §4): --baseline-only flag
# Given pre-v2 legacy entries alongside drifted v2 entries:
# --baseline-only emits ONLY legacy records
# ---------------------------------------------------------------------------
@test "baseline-only: suppresses real-drift records, emits only legacy" {
    local lineage_dir="$TEST_TEMP_DIR/.build-lineage"
    mkdir -p "$lineage_dir"

    # Real v2 entry — would drift if probed
    cat > "$lineage_dir/foo-1.0-alpine.json" <<'EOF'
{
  "lineage_schema_version": 2,
  "container": "foo",
  "tag": "1.0-alpine",
  "base_image_ref": "alpine:3.21",
  "base_image_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
EOF

    # Legacy entry — should appear in baseline-only output
    cat > "$lineage_dir/bar-1.0-alpine.json" <<'EOF'
{
  "lineage_schema_version": 1,
  "container": "bar",
  "tag": "1.0-alpine",
  "base_image_ref": "alpine:3.21"
}
EOF

    result=$(PROBE_CMD="/bin/false" \
        bash "${DETECTOR_SCRIPT}" --baseline-only "$lineage_dir" 2>/dev/null)

    printf '%s' "$result" | jq '.' >/dev/null

    # Only bar (legacy) should appear; foo (real drift) suppressed
    length=$(printf '%s' "$result" | jq 'length')
    [ "$length" -eq 1 ]

    container=$(printf '%s' "$result" | jq -r '.[0].container')
    [ "$container" = "bar" ]

    status_val=$(printf '%s' "$result" | jq -r '.[0].variants[0].status')
    [ "$status_val" = "legacy" ]
}

# ---------------------------------------------------------------------------
# Scenario 9 (spec §4): Container with no lineage files at all
# ---------------------------------------------------------------------------
@test "empty lineage dir: emits warning and returns empty array" {
    local lineage_dir="$TEST_TEMP_DIR/.build-lineage-empty"
    mkdir -p "$lineage_dir"

    result=$(bash "${DETECTOR_SCRIPT}" "$lineage_dir" 2>/tmp/detect-stderr-$$.log)
    stderr_out=$(cat /tmp/detect-stderr-$$.log 2>/dev/null || true)
    rm -f /tmp/detect-stderr-$$.log

    # Output is empty array
    [ "$result" = "[]" ]

    # stderr contains warning about empty cache
    [[ "$stderr_out" == *"warning"* ]]
}

@test "nonexistent lineage dir: exits 0 and returns empty array" {
    result=$(bash "${DETECTOR_SCRIPT}" "/nonexistent/lineage/dir/$$" 2>/dev/null)
    [ "$result" = "[]" ]
}

# ---------------------------------------------------------------------------
# Scenario 8 (spec §4): Digest shape validation — security
# ---------------------------------------------------------------------------
@test "digest-shape-validation: malformed digest (short hex) causes exit 1" {
    # The probe stub returns a manifest with a short digest (not 64 hex chars).
    # grep -o '"sha256:[a-f0-9]*"' WILL extract it (the pattern matches any length),
    # but _validate_digest_shape enforces ^sha256:[a-f0-9]{64}$ → refuses → exit 1.
    local malformed_stub_dir="$TEST_TEMP_DIR/malformed-probe"
    mkdir -p "$malformed_stub_dir/responses"

    # Write the fixture response with a short digest (16 chars, not 64)
    printf '%s' '{"mediaType":"application/vnd.docker.distribution.manifest.list.v2+json","digest":"sha256:abcdef1234567890","manifests":[]}' \
        > "$malformed_stub_dir/responses/alpine-3.21.json"

    # Write a probe stub that reads from the malformed fixture dir
    local stub_script="${malformed_stub_dir}/probe.sh"
    printf '%s\n' '#!/usr/bin/env bash' \
        'image_ref="$1"' \
        "responses_dir=\"${malformed_stub_dir}/responses\"" \
        'key="$(printf "%s" "$image_ref" | tr ":/" "--")"' \
        'response_file="${responses_dir}/${key}.json"' \
        '[[ -f "$response_file" ]] && { cat "$response_file"; exit 0; }' \
        'exit 1' \
        > "$stub_script"
    chmod +x "$stub_script"

    local lineage_dir="$TEST_TEMP_DIR/.build-lineage"
    mkdir -p "$lineage_dir"
    printf '%s\n' '{' \
        '"lineage_schema_version": 2,' \
        '"container": "foo",' \
        '"tag": "1.0-alpine",' \
        '"base_image_ref": "alpine:3.21",' \
        '"base_image_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' \
        '}' \
        > "$lineage_dir/foo-1.0-alpine.json"

    # The script must exit non-zero when digest shape validation fails
    run env PROBE_CMD="$stub_script" bash "${DETECTOR_SCRIPT}" "$lineage_dir"
    # Exit code must be non-zero (validation refused the malformed digest)
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Scenario 5 (spec §4): Multi-arch index digest extraction
# The probe returns a multi-arch manifest list. The script must extract the
# INDEX digest (from .digest field at the top level), NOT a per-arch digest.
# ---------------------------------------------------------------------------
@test "multi-arch: script extracts the image-index digest, not per-arch" {
    # Fixture: alpine-3.21.json has .digest = ccc... (index)
    # and .manifests[0].digest = ddd... (amd64)
    # The probe stub reads the whole JSON and the script uses grep-o to find
    # the first sha256 — which is the .digest field in the response body.
    local fixture_dir="${FIXTURES_DIR_DRIFT}/scenario-1"
    local probe_stub
    probe_stub=$(_make_probe_stub "${fixture_dir}/responses")

    local lineage_dir="$TEST_TEMP_DIR/.build-lineage"
    mkdir -p "$lineage_dir"
    cat > "$lineage_dir/foo-1.0-alpine.json" <<'EOF'
{
  "lineage_schema_version": 2,
  "container": "foo",
  "tag": "1.0-alpine",
  "base_image_ref": "alpine:3.21",
  "base_image_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
EOF

    result=$(PROBE_CMD="$probe_stub" \
        bash "${DETECTOR_SCRIPT}" "$lineage_dir")

    current_digest=$(printf '%s' "$result" | \
        jq -r '.[0].variants[0].current_digest')

    # The fixture alpine-3.21.json has .digest = ccc... (64 c's)
    # Per-arch digests are ddd... and eee... — must NOT be one of those
    [ "$current_digest" = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" ]
}

# ---------------------------------------------------------------------------
# Sidecar exclusion: explicit verification that is_lineage_sidecar() is called
# ---------------------------------------------------------------------------
@test "sidecar-exclusion: .sbom.json not processed even if valid JSON" {
    local lineage_dir="$TEST_TEMP_DIR/.build-lineage"
    mkdir -p "$lineage_dir"

    # Valid-looking but is-a-sidecar file
    cat > "$lineage_dir/foo-1.0-alpine.sbom.json" <<'EOF'
{
  "lineage_schema_version": 2,
  "container": "foo",
  "tag": "1.0-alpine-sbom",
  "base_image_ref": "alpine:3.21",
  "base_image_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
EOF

    result=$(PROBE_CMD="/bin/false" \
        bash "${DETECTOR_SCRIPT}" "$lineage_dir" 2>/dev/null)

    # Should be empty — sidecar filtered
    [ "$result" = "[]" ]
}

# ---------------------------------------------------------------------------
# Unresolved placeholder in base_image_ref — skip with warning
# ---------------------------------------------------------------------------
@test "unresolved-ref: entry with \${...} placeholder in base_image_ref is skipped" {
    local lineage_dir="$TEST_TEMP_DIR/.build-lineage"
    mkdir -p "$lineage_dir"
    cat > "$lineage_dir/foo-1.0.json" <<'EOF'
{
  "lineage_schema_version": 2,
  "container": "foo",
  "tag": "1.0",
  "base_image_ref": "${REMOTE_CR}/library/debian:trixie-slim",
  "base_image_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
EOF

    result=$(PROBE_CMD="/bin/false" \
        bash "${DETECTOR_SCRIPT}" "$lineage_dir" 2>/dev/null)

    [ "$result" = "[]" ]
}
