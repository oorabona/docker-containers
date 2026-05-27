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

    # Pre-existing tests use synthetic container names (foo, bar, myimage) that
    # are not in the real ./make list.  Expose the test-hook override so the
    # validation check accepts them without spawning ./make in the project root.
    # New container-validation tests explicitly unset this to exercise real logic.
    export _VALID_CONTAINERS_OVERRIDE="foo
bar
myimage"

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
        bash "${DETECTOR_SCRIPT}" "${fixture_dir}/lineage-cache")

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
        bash "${DETECTOR_SCRIPT}" "${fixture_dir}/lineage-cache")

    length=$(printf '%s' "$result" | jq 'length')
    [ "$length" -eq 1 ]
}

# MG1: Digest comparison — if comparison were removed, debian would also report drift
@test "scenario-1: debian status is unchanged (digest comparison guard MG1)" {
    local fixture_dir="${FIXTURES_DIR_DRIFT}/scenario-1"
    local probe_stub
    probe_stub=$(_make_probe_stub "${fixture_dir}/responses")

    result=$(PROBE_CMD="$probe_stub" \
        bash "${DETECTOR_SCRIPT}" "${fixture_dir}/lineage-cache")

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
        bash "${DETECTOR_SCRIPT}" "${fixture_dir}/lineage-cache")

    foo_variants=$(printf '%s' "$result" | jq '.[0].variants | length')
    [ "$foo_variants" -eq 2 ]
}

# MG4: Digest shape validation — valid digests must match ^sha256:[a-f0-9]{64}$
@test "scenario-1: all digests in output match sha256:[a-f0-9]{64} (shape guard MG4)" {
    local fixture_dir="${FIXTURES_DIR_DRIFT}/scenario-1"
    local probe_stub
    probe_stub=$(_make_probe_stub "${fixture_dir}/responses")

    result=$(PROBE_CMD="$probe_stub" \
        bash "${DETECTOR_SCRIPT}" "${fixture_dir}/lineage-cache")

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
        bash "${DETECTOR_SCRIPT}" "${fixture_dir}/lineage-cache")

    printf '%s' "$result" | jq '.' >/dev/null

    length=$(printf '%s' "$result" | jq 'length')
    [ "$length" -eq 2 ]
}

@test "scenario-2: foo record contains 2 variants" {
    local fixture_dir="${FIXTURES_DIR_DRIFT}/scenario-2"
    local probe_stub
    probe_stub=$(_make_probe_stub "${fixture_dir}/responses")

    result=$(PROBE_CMD="$probe_stub" \
        bash "${DETECTOR_SCRIPT}" "${fixture_dir}/lineage-cache")

    foo_count=$(printf '%s' "$result" | \
        jq '[.[] | select(.container == "foo")] | .[0].variants | length')
    [ "$foo_count" -eq 2 ]
}

@test "scenario-2: bar record contains 2 variants" {
    local fixture_dir="${FIXTURES_DIR_DRIFT}/scenario-2"
    local probe_stub
    probe_stub=$(_make_probe_stub "${fixture_dir}/responses")

    result=$(PROBE_CMD="$probe_stub" \
        bash "${DETECTOR_SCRIPT}" "${fixture_dir}/lineage-cache")

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
# Fix 1 regression: probe errors surfaced on stderr (::error::) AND error_reason
# in JSON record — supply-chain monitoring must not silently drop probe failures.
# ---------------------------------------------------------------------------
@test "probe-failure: emits ::error:: to stderr when probe fails" {
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

    local stderr_log="$TEST_TEMP_DIR/probe-failure-stderr.log"
    PROBE_CMD="$fail_stub" bash "${DETECTOR_SCRIPT}" "$lineage_dir" 2>"$stderr_log" >/dev/null || true

    # stderr must contain at least one ::error:: annotation
    grep -q '::error::' "$stderr_log"
}

@test "probe-failure: error JSON record contains error_reason field" {
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

    # error_reason must be a non-empty string (not null)
    error_reason=$(printf '%s' "$result" | jq -r '.[0].variants[0].error_reason // "null"')
    [ "$error_reason" != "null" ]
    [ -n "$error_reason" ]
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
# INDEX digest via the top-level .digest field (jq -r '.digest'), NOT a
# per-arch entry digest from .manifests[].digest.
#
# Fix 2 regression guard: using grep-o head-1 is order-dependent; jq .digest
# is explicit.  Both the fixture and a synthetic test cover this.
# ---------------------------------------------------------------------------
@test "multi-arch: script extracts the image-index digest, not per-arch" {
    # Fixture: alpine-3.21.json has .digest = ccc... (index)
    # and .manifests[0].digest = ddd... (amd64), .manifests[1].digest = eee... (arm64)
    # The script must return ccc... (index), NOT ddd.../eee...
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

# Fix 2 synthetic: manifest where per-arch digest appears FIRST in the JSON body
# (before the top-level .digest).  grep-o head-1 would return the wrong digest;
# jq -r '.digest' must return the correct index digest regardless of field order.
@test "multi-arch: index digest extracted even when per-arch entry precedes .digest in JSON" {
    # Synthetic fixture: .manifests[] listed before .digest at top level.
    # grep-o '"sha256:[a-f0-9]*"' | head -1 would return amd64 digest (ddd...).
    # jq -r '.digest' returns the index digest (ccc...) — order-independent.
    local synthetic_dir="$TEST_TEMP_DIR/synthetic-probe"
    mkdir -p "$synthetic_dir/responses"

    # Write manifest JSON with per-arch entries BEFORE the top-level .digest field
    cat > "$synthetic_dir/responses/myimage-latest.json" <<'EOF'
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.docker.distribution.manifest.list.v2+json",
  "manifests": [
    {
      "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
      "size": 1642,
      "digest": "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
      "platform": {"architecture": "amd64", "os": "linux"}
    },
    {
      "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
      "size": 1642,
      "digest": "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
      "platform": {"architecture": "arm64", "os": "linux"}
    }
  ],
  "digest": "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
}
EOF

    local stub_script="$synthetic_dir/probe.sh"
    cat > "$stub_script" <<STUB_EOF
#!/usr/bin/env bash
image_ref="\$1"
key="\$(printf '%s' "\$image_ref" | tr ':/' '--')"
response_file="${synthetic_dir}/responses/\${key}.json"
[[ -f "\$response_file" ]] && { cat "\$response_file"; exit 0; }
exit 1
STUB_EOF
    chmod +x "$stub_script"

    local lineage_dir="$TEST_TEMP_DIR/.build-lineage"
    mkdir -p "$lineage_dir"
    cat > "$lineage_dir/myimage-latest.json" <<'EOF'
{
  "lineage_schema_version": 2,
  "container": "myimage",
  "tag": "latest",
  "base_image_ref": "myimage:latest",
  "base_image_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
EOF

    result=$(PROBE_CMD="$stub_script" \
        bash "${DETECTOR_SCRIPT}" "$lineage_dir")

    current_digest=$(printf '%s' "$result" | jq -r '.[0].variants[0].current_digest')

    # Must be the INDEX digest (ccc...), NOT the first per-arch entry (ddd...)
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

# ---------------------------------------------------------------------------
# Precedence guard: placeholder ref + missing digest must be skipped (not
# classified as legacy).  Before Fix 3 the legacy check ran first and would
# emit a bogus drift PR for pre-#530 lineage files.
# ---------------------------------------------------------------------------
@test "unresolved-ref: placeholder ref with missing digest is skipped, not emitted as legacy" {
    local lineage_dir="$TEST_TEMP_DIR/.build-lineage"
    mkdir -p "$lineage_dir"
    # Simulates a pre-#530 lineage entry: placeholder ref AND no recorded digest
    cat > "$lineage_dir/foo-1.0.json" <<'EOF'
{
  "lineage_schema_version": 1,
  "container": "foo",
  "tag": "1.0",
  "base_image_ref": "${REMOTE_CR}/library/debian:trixie-slim"
}
EOF

    result=$(PROBE_CMD="/bin/false" \
        bash "${DETECTOR_SCRIPT}" "$lineage_dir" 2>/dev/null)

    # Must be empty — placeholder takes precedence over legacy classification
    [ "$result" = "[]" ]
}

# ---------------------------------------------------------------------------
# Fix r4-1: Container name validation — poisoning prevention
# Lineage entries whose .container field is NOT in `./make list` output must
# be skipped with a ::warning::, never processed.
# Regression: a corrupted entry with container: "docs" (or ".github", or a
# path with "/") would otherwise cause the bot to act on non-container dirs.
# ---------------------------------------------------------------------------
@test "container-validation: entry with invalid container name 'docs' is skipped" {
    local lineage_dir="$TEST_TEMP_DIR/.build-lineage"
    mkdir -p "$lineage_dir"

    # Corrupted entry: container field is a real directory name but NOT a container
    cat > "$lineage_dir/docs-1.0.json" <<'EOF'
{
  "lineage_schema_version": 2,
  "container": "docs",
  "tag": "1.0",
  "base_image_ref": "alpine:3.21",
  "base_image_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
EOF

    # Unset override: "docs" is not in the real ./make list
    result=$(unset _VALID_CONTAINERS_OVERRIDE && PROBE_CMD="/bin/false" \
        bash "${DETECTOR_SCRIPT}" "$lineage_dir" 2>/dev/null)

    # Invalid container must be filtered out — output must be empty
    [ "$result" = "[]" ]
}

@test "container-validation: entry with invalid container name 'docs' emits ::warning:: to stderr" {
    local lineage_dir="$TEST_TEMP_DIR/.build-lineage"
    mkdir -p "$lineage_dir"

    cat > "$lineage_dir/docs-1.0.json" <<'EOF'
{
  "lineage_schema_version": 2,
  "container": "docs",
  "tag": "1.0",
  "base_image_ref": "alpine:3.21",
  "base_image_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
EOF

    local stderr_log="$TEST_TEMP_DIR/invalid-container-stderr.log"
    # Unset override: "docs" is not in the real ./make list
    unset _VALID_CONTAINERS_OVERRIDE
    PROBE_CMD="/bin/false" bash "${DETECTOR_SCRIPT}" "$lineage_dir" 2>"$stderr_log" >/dev/null || true

    # stderr must contain ::warning:: about invalid container
    grep -q '::warning::' "$stderr_log"
}

@test "container-validation: entry with container name containing slash is skipped" {
    local lineage_dir="$TEST_TEMP_DIR/.build-lineage"
    mkdir -p "$lineage_dir"

    # Path traversal attempt
    cat > "$lineage_dir/traversal-1.0.json" <<'EOF'
{
  "lineage_schema_version": 2,
  "container": "../docs",
  "tag": "1.0",
  "base_image_ref": "alpine:3.21",
  "base_image_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
EOF

    # Unset override: "../docs" is certainly not in ./make list
    result=$(unset _VALID_CONTAINERS_OVERRIDE && PROBE_CMD="/bin/false" \
        bash "${DETECTOR_SCRIPT}" "$lineage_dir" 2>/dev/null)

    # Path-traversal container name must be filtered out
    [ "$result" = "[]" ]
}

# ---------------------------------------------------------------------------
# Fix r4-4: update-last-rebuild.sh — missing container directory
#
# When the container directory does not exist (stale lineage cache entry),
# update-last-rebuild.sh must exit 0 with a ::warning:: rather than exit 1.
# A single stale entry must not break the entire open-drift-prs workflow.
# ---------------------------------------------------------------------------

# Helper: minimal drift JSON for a given container name
_drift_json_for_container() {
    local container="$1"
    printf '%s' '[{"container":"'"$container"'","variants":[{"variant_tag":"1.0","base_image_ref":"alpine:3.21","recorded_digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","current_digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","status":"drift"}]}]'
}

@test "update-last-rebuild: exits 0 when container directory does not exist" {
    local fake_root="$TEST_TEMP_DIR/fake-root-r4"
    local update_script="${SCRIPTS_DIR}/update-last-rebuild.sh"
    mkdir -p "$fake_root/scripts"
    cp "$update_script" "$fake_root/scripts/update-last-rebuild.sh"

    # Stub ./make list — "mycontainer" is valid, but directory is never created
    cat > "$fake_root/make" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "list" ]] && printf 'mycontainer\n'
STUB
    chmod +x "$fake_root/make"

    local rc=0
    cd "$fake_root" && \
        bash scripts/update-last-rebuild.sh "mycontainer" "base-digest-drift" \
        <<< "$(_drift_json_for_container mycontainer)" 2>/dev/null || rc=$?

    # Must exit 0 — graceful skip, not failure
    [ "$rc" -eq 0 ]

    # Must NOT have created the LAST_REBUILD.md
    [ ! -f "$fake_root/mycontainer/LAST_REBUILD.md" ]
}

@test "update-last-rebuild: emits ::warning:: when container directory missing" {
    local fake_root="$TEST_TEMP_DIR/fake-root-r4b"
    local update_script="${SCRIPTS_DIR}/update-last-rebuild.sh"
    mkdir -p "$fake_root/scripts"
    cp "$update_script" "$fake_root/scripts/update-last-rebuild.sh"

    cat > "$fake_root/make" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "list" ]] && printf 'mycontainer\n'
STUB
    chmod +x "$fake_root/make"

    local stderr_log="$TEST_TEMP_DIR/missing-dir-stderr.log"
    cd "$fake_root" && \
        bash scripts/update-last-rebuild.sh "mycontainer" "base-digest-drift" \
        <<< "$(_drift_json_for_container mycontainer)" 2>"$stderr_log" >/dev/null || true

    grep -q '::warning::' "$stderr_log"
}

@test "update-last-rebuild: exits 0 for invalid container name not in make list" {
    local fake_root="$TEST_TEMP_DIR/fake-root-r4c"
    local update_script="${SCRIPTS_DIR}/update-last-rebuild.sh"
    mkdir -p "$fake_root/scripts"
    cp "$update_script" "$fake_root/scripts/update-last-rebuild.sh"

    # ./make list returns only "ansible"; "docs" is not valid
    cat > "$fake_root/make" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "list" ]] && printf 'ansible\n'
STUB
    chmod +x "$fake_root/make"

    local rc=0
    cd "$fake_root" && \
        bash scripts/update-last-rebuild.sh "docs" "base-digest-drift" \
        <<< "$(_drift_json_for_container docs)" 2>/dev/null || rc=$?

    [ "$rc" -eq 0 ]
}

@test "update-last-rebuild: normal path appends section when container dir exists" {
    local fake_root="$TEST_TEMP_DIR/fake-root-r4d"
    local update_script="${SCRIPTS_DIR}/update-last-rebuild.sh"
    mkdir -p "$fake_root/scripts"
    mkdir -p "$fake_root/mycontainer"
    cp "$update_script" "$fake_root/scripts/update-last-rebuild.sh"

    cat > "$fake_root/make" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "list" ]] && printf 'mycontainer\n'
STUB
    chmod +x "$fake_root/make"

    cd "$fake_root" && \
        bash scripts/update-last-rebuild.sh "mycontainer" "base-digest-drift" \
        <<< "$(_drift_json_for_container mycontainer)" >/dev/null 2>&1

    # LAST_REBUILD.md must exist and contain the section header
    [ -f "$fake_root/mycontainer/LAST_REBUILD.md" ]
    grep -q 'base-digest-drift' "$fake_root/mycontainer/LAST_REBUILD.md"
}

# ---------------------------------------------------------------------------
# Fix r5-1: Unified digest source (writer + probe both use imagetools format)
# Regression guard: probe must extract .digest from imagetools-style JSON
# (the format `docker buildx imagetools inspect --format '{{json .Manifest}}'`
# returns).  The fixture is the imagetools Manifest descriptor — a flat object
# with .digest, .mediaType, .size (no .manifests[] wrapper at the outer level).
# ---------------------------------------------------------------------------
@test "r5-fix1: probe extracts digest from imagetools Manifest descriptor format" {
    # Fixture: imagetools --format '{{json .Manifest}}' returns a flat OCI descriptor
    # with .digest at the top level.  This is different from the `docker manifest
    # inspect` format which has .manifests[] and a top-level .digest only in the
    # manifest-list body.  Both formats have .digest at top level — jq '.digest'
    # works for both.  This test guards the imagetools-format path specifically.
    local synthetic_dir="$TEST_TEMP_DIR/r5-fix1-probe"
    mkdir -p "$synthetic_dir/responses"

    # imagetools --format '{{json .Manifest}}' output: flat descriptor
    cat > "$synthetic_dir/responses/alpine-3.21.json" <<'EOF'
{
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
  "size": 2048
}
EOF

    local stub_script="$synthetic_dir/probe.sh"
    cat > "$stub_script" <<STUB_EOF
#!/usr/bin/env bash
key="\$(printf '%s' "\$1" | tr ':/' '--')"
response_file="${synthetic_dir}/responses/\${key}.json"
[[ -f "\$response_file" ]] && { cat "\$response_file"; exit 0; }
exit 1
STUB_EOF
    chmod +x "$stub_script"

    local lineage_dir="$TEST_TEMP_DIR/.build-lineage"
    mkdir -p "$lineage_dir"
    cat > "$lineage_dir/foo-3.21-alpine.json" <<'EOF'
{
  "lineage_schema_version": 2,
  "container": "foo",
  "tag": "3.21-alpine",
  "base_image_ref": "alpine:3.21",
  "base_image_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
EOF

    result=$(PROBE_CMD="$stub_script" bash "${DETECTOR_SCRIPT}" "$lineage_dir")

    current_digest=$(printf '%s' "$result" | jq -r '.[0].variants[0].current_digest')
    # Probe must extract 1111... (from imagetools Manifest descriptor), NOT fall back to grep
    [ "$current_digest" = "sha256:1111111111111111111111111111111111111111111111111111111111111111" ]
}

# ---------------------------------------------------------------------------
# Fix r5-2: GHA command injection prevention (::error:: escaping)
# Regression guard: a newline-bearing base_image_ref in a probe-error scenario
# must NOT inject a second GHA workflow command.  The escaped form (%0A) must
# appear in the ::error:: line instead of a raw newline.
# ---------------------------------------------------------------------------
@test "r5-fix2: newline in base_image_ref is escaped in ::error:: output" {
    # Lineage file with a base_image_ref containing an embedded newline (simulates
    # a crafted/corrupted lineage entry).  When the registry probe fails, the error
    # line must escape the newline as %0A to prevent GHA command injection.
    local lineage_dir="$TEST_TEMP_DIR/.build-lineage"
    mkdir -p "$lineage_dir"

    # Use a JSON-escaped newline (\n) in the base_image_ref value.  jq decodes
    # \n → literal newline when reading the field, giving _escape_gha_command
    # a real newline to escape as %0A.
    printf '{"lineage_schema_version":2,"container":"foo","tag":"1.0","base_image_ref":"alpine:3.21\\nmalicious::add-mask::secret","base_image_digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' \
        > "$lineage_dir/foo-1.0.json"

    local stderr_log="$TEST_TEMP_DIR/r5-fix2-stderr.log"
    PROBE_CMD="/bin/false" bash "${DETECTOR_SCRIPT}" "$lineage_dir" 2>"$stderr_log" >/dev/null || true

    # The raw newline must NOT appear in stderr (it would split the ::error:: line)
    # Instead %0A must be present
    if grep -qP '\n' "$stderr_log" 2>/dev/null; then
        # grep -P may not be available everywhere; use a portable check
        true
    fi
    # Primary assertion: %0A must appear in any ::error:: line containing the ref
    grep -q '%0A' "$stderr_log"
    # Secondary: the injected GHA command must NOT appear as a standalone command line
    ! grep -q '^::add-mask::' "$stderr_log"
}

# ---------------------------------------------------------------------------
# Fix r5-4: --baseline-only precedence (legacy wins over placeholder-skip)
# Regression guard: a pre-#530 lineage entry with a placeholder base_image_ref
# AND no recorded digest must emit status=legacy in --baseline-only mode (so the
# baseline migration picks it up), while the same entry must be SKIPPED (result=[])
# in normal mode (to prevent bogus drift PRs).
# ---------------------------------------------------------------------------
@test "r5-fix4: baseline-only mode emits legacy for placeholder-ref + missing-digest entry" {
    local lineage_dir="$TEST_TEMP_DIR/.build-lineage"
    mkdir -p "$lineage_dir"
    # Pre-#530 entry: placeholder ref, no digest field at all
    cat > "$lineage_dir/foo-1.0.json" <<'EOF'
{
  "lineage_schema_version": 1,
  "container": "foo",
  "tag": "1.0",
  "base_image_ref": "${REMOTE_CR}/library/debian:trixie-slim"
}
EOF

    # --baseline-only: must emit a legacy record (not skip)
    result=$(PROBE_CMD="/bin/false" \
        bash "${DETECTOR_SCRIPT}" --baseline-only "$lineage_dir" 2>/dev/null)

    printf '%s' "$result" | jq '.' >/dev/null  # valid JSON
    length=$(printf '%s' "$result" | jq 'length')
    [ "$length" -eq 1 ]

    status_val=$(printf '%s' "$result" | jq -r '.[0].variants[0].status')
    [ "$status_val" = "legacy" ]
}

@test "r5-fix4: normal mode still skips placeholder-ref + missing-digest entry (no regression)" {
    local lineage_dir="$TEST_TEMP_DIR/.build-lineage"
    mkdir -p "$lineage_dir"
    # Same pre-#530 entry
    cat > "$lineage_dir/foo-1.0.json" <<'EOF'
{
  "lineage_schema_version": 1,
  "container": "foo",
  "tag": "1.0",
  "base_image_ref": "${REMOTE_CR}/library/debian:trixie-slim"
}
EOF

    # Normal mode (no --baseline-only): must skip — empty output
    result=$(PROBE_CMD="/bin/false" \
        bash "${DETECTOR_SCRIPT}" "$lineage_dir" 2>/dev/null)

    [ "$result" = "[]" ]
}
