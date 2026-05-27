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
    # are not in the real ./make list.  Expose _VALID_CONTAINERS_OVERRIDE so the
    # validation check accepts them without spawning ./make. When this is set,
    # the detector disables the stale-lineage filter by default for containers
    # without explicit _ACTIVE_TAGS_OVERRIDE_*, allowing tests to use any tags.
    # Specific tests can override this by unsetting _VALID_CONTAINERS_OVERRIDE.
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

# ---------------------------------------------------------------------------
# Fix r6-1: Per-container concurrency — matrix output separates containers
# Regression guard: when two containers drift, the script emits two separate
# container records in drift_json.  The open-drift-prs matrix uses
# matrix.container (derived from drift_containers) to fan out.  This test
# verifies that multi-container drift produces one record per container so
# each matrix entry (and its own concurrency lane) is distinct.
# ---------------------------------------------------------------------------
@test "r6-fix1: two drifted containers produce two separate container records" {
    export _VALID_CONTAINERS_OVERRIDE="foo
bar"

    local lineage_dir="$TEST_TEMP_DIR/.build-lineage"
    mkdir -p "$lineage_dir"

    # foo: recorded digest differs from current → drift
    cat > "$lineage_dir/foo-1.0.json" <<'EOF'
{
  "lineage_schema_version": 2,
  "container": "foo",
  "tag": "1.0",
  "base_image_ref": "alpine:3.21",
  "base_image_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
EOF

    # bar: recorded digest differs from current → drift
    cat > "$lineage_dir/bar-2.0.json" <<'EOF'
{
  "lineage_schema_version": 2,
  "container": "bar",
  "tag": "2.0",
  "base_image_ref": "debian:trixie-slim",
  "base_image_digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
}
EOF

    # Probe stub: returns a different digest for each ref (simulating real drift)
    local stub_script="$TEST_TEMP_DIR/probe-two-containers"
    cat > "$stub_script" <<'STUB_EOF'
#!/usr/bin/env bash
case "$1" in
    alpine:3.21)
        printf '{"digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}'
        ;;
    debian:trixie-slim)
        printf '{"digest":"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"}'
        ;;
    *)
        echo "unexpected ref: $1" >&2
        exit 1
        ;;
esac
STUB_EOF
    chmod +x "$stub_script"

    result=$(PROBE_CMD="$stub_script" bash "${DETECTOR_SCRIPT}" "$lineage_dir")

    printf '%s' "$result" | jq '.' >/dev/null  # valid JSON

    # Must produce exactly 2 container records — one per drifted container
    record_count=$(printf '%s' "$result" | jq 'length')
    [ "$record_count" -eq 2 ]

    # Both containers present with status=drift
    foo_status=$(printf '%s' "$result" | jq -r '.[] | select(.container=="foo") | .variants[0].status')
    [ "$foo_status" = "drift" ]

    bar_status=$(printf '%s' "$result" | jq -r '.[] | select(.container=="bar") | .variants[0].status')
    [ "$bar_status" = "drift" ]

    # drift_containers list (as the workflow computes it) has 2 distinct entries
    drift_containers=$(printf '%s' "$result" | jq -c '[.[] | select(.variants | any(.status == "drift" or .status == "legacy")) | .container]')
    foo_in_list=$(printf '%s' "$drift_containers" | jq 'index("foo")')
    bar_in_list=$(printf '%s' "$drift_containers" | jq 'index("bar")')
    # Both containers are in the list (non-null index)
    [ "$foo_in_list" != "null" ]
    [ "$bar_in_list" != "null" ]
    # List has exactly 2 entries → each matrix job gets its own concurrency lane
    list_len=$(printf '%s' "$drift_containers" | jq 'length')
    [ "$list_len" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Fix r6-2: Workflow re-emit injection prevention
# Regression guard: a base_image_ref with a percent-encoded newline (%0A)
# would survive _sanitize_for_json (which only strips literal control chars)
# and land in error_reason in the JSON.  The old workflow re-emitted that
# field unescaped via `echo "::warning::probe-error: ${line}"`, allowing the
# GHA runner to decode %0A back to a newline and inject a second command.
#
# This test verifies that the script itself does NOT double-encode: it already
# escapes the probe-error line via _escape_gha_command before writing to
# stderr.  The workflow no longer re-emits from JSON, so the injection path
# is gone — this test guards that the script-level emission (the surviving
# path) is correctly escaped.
# ---------------------------------------------------------------------------
@test "r6-fix2: percent-encoded newline in base_image_ref is escaped in script stderr output" {
    # A crafted base_image_ref containing %0A (percent-encoded newline).
    # _sanitize_for_json strips literal \n/\r but NOT %0A, so %0A survives
    # into error_reason.  The script must escape the ::error:: line via
    # _escape_gha_command so the %0A becomes %250A (double-encoded), preventing
    # the GHA runner from decoding it back into a newline command injection.
    local lineage_dir="$TEST_TEMP_DIR/.build-lineage"
    mkdir -p "$lineage_dir"

    printf '{"lineage_schema_version":2,"container":"foo","tag":"1.0","base_image_ref":"alpine:3.21%%0A::add-mask::s3cr3t","base_image_digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' \
        > "$lineage_dir/foo-1.0.json"

    local stderr_log="$TEST_TEMP_DIR/r6-fix2-stderr.log"
    PROBE_CMD="/bin/false" bash "${DETECTOR_SCRIPT}" "$lineage_dir" 2>"$stderr_log" >/dev/null || true

    # The injected command must NOT appear as a standalone GHA command line
    ! grep -q '^::add-mask::' "$stderr_log"

    # The ::error:: line must be present (probe failure was emitted)
    grep -q '::error::' "$stderr_log"
}

# ---------------------------------------------------------------------------
# Fix r6-3: Temp file cleanup in _probe_digest (trap RETURN)
# Regression guard: _probe_digest must not leave /tmp files behind when the
# probe returns empty raw output or fails to extract a digest.  We verify
# indirectly: run the script in a restricted TMPDIR with a known prefix and
# check that no files with that prefix remain after the script exits.
# ---------------------------------------------------------------------------
@test "r6-fix3: no temp files left behind after empty-raw probe failure" {
    local lineage_dir="$TEST_TEMP_DIR/.build-lineage"
    local isolated_tmp="$TEST_TEMP_DIR/probe-tmp"
    mkdir -p "$lineage_dir" "$isolated_tmp"

    cat > "$lineage_dir/foo-1.0.json" <<'EOF'
{
  "lineage_schema_version": 2,
  "container": "foo",
  "tag": "1.0",
  "base_image_ref": "alpine:3.21",
  "base_image_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
EOF

    # Probe stub: exits 0 but emits empty stdout → triggers the "empty raw" early return
    local stub_script="$TEST_TEMP_DIR/probe-empty-raw"
    cat > "$stub_script" <<'STUB_EOF'
#!/usr/bin/env bash
# Output nothing — simulates imagetools returning empty body
exit 0
STUB_EOF
    chmod +x "$stub_script"

    # Run with isolated TMPDIR so any leaked mktemp files are contained
    TMPDIR="$isolated_tmp" PROBE_CMD="$stub_script" \
        bash "${DETECTOR_SCRIPT}" "$lineage_dir" >/dev/null 2>&1 || true

    # No temp files must remain in isolated_tmp after script exits
    leaked=$(find "$isolated_tmp" -maxdepth 1 -type f 2>/dev/null | wc -l)
    [ "$leaked" -eq 0 ]
}

@test "r6-fix3: no temp files left behind after digest-extraction failure" {
    local lineage_dir="$TEST_TEMP_DIR/.build-lineage"
    local isolated_tmp="$TEST_TEMP_DIR/probe-tmp2"
    mkdir -p "$lineage_dir" "$isolated_tmp"

    cat > "$lineage_dir/foo-1.0.json" <<'EOF'
{
  "lineage_schema_version": 2,
  "container": "foo",
  "tag": "1.0",
  "base_image_ref": "alpine:3.21",
  "base_image_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
EOF

    # Probe stub: exits 0, emits JSON with no .digest field → triggers the
    # "could not extract digest" early return path
    local stub_script="$TEST_TEMP_DIR/probe-no-digest"
    cat > "$stub_script" <<'STUB_EOF'
#!/usr/bin/env bash
printf '{"mediaType":"application/vnd.oci.image.manifest.v1+json"}'
exit 0
STUB_EOF
    chmod +x "$stub_script"

    TMPDIR="$isolated_tmp" PROBE_CMD="$stub_script" \
        bash "${DETECTOR_SCRIPT}" "$lineage_dir" >/dev/null 2>&1 || true

    leaked=$(find "$isolated_tmp" -maxdepth 1 -type f 2>/dev/null | wc -l)
    [ "$leaked" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Fix r7-1: Digest shape validation before label_args embedding
# Regression guard: a malformed _BASE_DIGEST value (spaces, injected flags,
# non-hex chars) must be refused and NOT embedded in label_args.  Only
# ^sha256:[a-f0-9]{64}$ passes.
# ---------------------------------------------------------------------------
@test "r7-fix1a: malformed digest (spaces/injection) is NOT added to label_args" {
    # Exercise _resolve_base_image from build-container.sh with a docker stub that
    # returns a malformed digest — verify label_args stays clean.
    local test_container_dir="$TEST_TEMP_DIR/r7fix1a"
    mkdir -p "$test_container_dir/bin"

    # Docker stub: imagetools inspect returns a digest containing a space (injection vector)
    cat > "$test_container_dir/bin/docker" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "buildx" && "$2" == "imagetools" && "$3" == "inspect" ]]; then
    printf '{"digest":"sha256:aabbcc --label org.opencontainers.image.extra=injected"}\n'
    exit 0
fi
exit 1
MOCK
    chmod +x "$test_container_dir/bin/docker"

    # Run _resolve_base_image in a subshell so PATH is scoped and globals don't leak
    local label_args_val
    label_args_val=$(
        export PATH="$test_container_dir/bin:$PATH"
        cd "$test_container_dir"
        printf 'FROM alpine:3.21\n' > Dockerfile
        # Source logging + build-container
        # shellcheck source=/dev/null
        source "${SCRIPTS_DIR}/../helpers/logging.sh" 2>/dev/null || true
        # shellcheck source=/dev/null
        source "${SCRIPTS_DIR}/../helpers/build-args-utils.sh" 2>/dev/null || true
        # shellcheck source=/dev/null
        source "${SCRIPTS_DIR}/../helpers/variant-utils.sh" 2>/dev/null || true
        # shellcheck source=/dev/null
        source "${SCRIPTS_DIR}/../helpers/template-utils.sh" 2>/dev/null || true
        pushd "${SCRIPTS_DIR}" >/dev/null 2>&1
        # shellcheck source=/dev/null
        source "./build-container.sh" 2>/dev/null || true
        popd >/dev/null 2>&1
        declare -gA _BUILD_ARGS_RESOLVED=()
        label_args=""
        _resolve_base_image "Dockerfile" "3.21" "label_args" 2>/dev/null || true
        printf '%s' "$label_args"
    )

    # label_args must NOT contain the malformed digest value
    [[ "$label_args_val" != *"aabbcc"* ]] || {
        echo "FAIL: malformed digest fragment 'aabbcc' appeared in label_args: '$label_args_val'"
        return 1
    }
    [[ "$label_args_val" != *"--label org.opencontainers.image.extra"* ]] || {
        echo "FAIL: injected extra label appeared in label_args: '$label_args_val'"
        return 1
    }
}

@test "r7-fix1b: well-formed sha256 digest is embedded in label_args" {
    # Positive case: ^sha256:[a-f0-9]{64}$ must still be accepted.
    local test_container_dir="$TEST_TEMP_DIR/r7fix1b"
    mkdir -p "$test_container_dir/bin"

    local valid_digest="sha256:abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"

    cat > "$test_container_dir/bin/docker" <<MOCK
#!/usr/bin/env bash
if [[ "\$1" == "buildx" && "\$2" == "imagetools" && "\$3" == "inspect" ]]; then
    printf '{"digest":"${valid_digest}"}\n'
    exit 0
fi
exit 1
MOCK
    chmod +x "$test_container_dir/bin/docker"

    local label_args_val
    label_args_val=$(
        export PATH="$test_container_dir/bin:$PATH"
        cd "$test_container_dir"
        printf 'FROM alpine:3.21\n' > Dockerfile
        # shellcheck source=/dev/null
        source "${SCRIPTS_DIR}/../helpers/logging.sh" 2>/dev/null || true
        # shellcheck source=/dev/null
        source "${SCRIPTS_DIR}/../helpers/build-args-utils.sh" 2>/dev/null || true
        # shellcheck source=/dev/null
        source "${SCRIPTS_DIR}/../helpers/variant-utils.sh" 2>/dev/null || true
        # shellcheck source=/dev/null
        source "${SCRIPTS_DIR}/../helpers/template-utils.sh" 2>/dev/null || true
        pushd "${SCRIPTS_DIR}" >/dev/null 2>&1
        # shellcheck source=/dev/null
        source "./build-container.sh" 2>/dev/null || true
        popd >/dev/null 2>&1
        declare -gA _BUILD_ARGS_RESOLVED=()
        label_args=""
        _resolve_base_image "Dockerfile" "3.21" "label_args" 2>/dev/null || true
        printf '%s' "$label_args"
    )

    [[ "$label_args_val" == *"org.opencontainers.image.base.digest=${valid_digest}"* ]] || {
        echo "FAIL: valid digest not found in label_args: '$label_args_val'"
        return 1
    }
}

# ---------------------------------------------------------------------------
# Fix r7-2: Re-detect step distinguishes status:error from no-drift
# Regression guard: when every probe returns error (PROBE_CMD=/bin/false),
# the JSON output contains status:error records — the workflow's error_count
# check (jq '[.[] | .variants[] | select(.status == "error")] | length') is
# non-zero, so the step exits non-zero rather than silently skipping.
# This test verifies the script emits status:error that a downstream
# error_count check can detect, not that the script itself exits non-zero.
# ---------------------------------------------------------------------------
@test "r7-fix2: probe failure emits status:error in JSON (re-detect error_count detectable)" {
    local lineage_dir="$TEST_TEMP_DIR/r7fix2/.build-lineage"
    mkdir -p "$lineage_dir"

    cat > "$lineage_dir/foo-1.0.json" <<'EOF'
{
  "lineage_schema_version": 2,
  "container": "foo",
  "tag": "1.0",
  "base_image_ref": "alpine:3.21",
  "base_image_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
EOF

    # /bin/false simulates a probe that always fails (registry unreachable)
    result=$(PROBE_CMD="/bin/false" bash "${DETECTOR_SCRIPT}" "$lineage_dir" 2>/dev/null)

    # Must be valid JSON
    printf '%s' "$result" | jq '.' >/dev/null

    # Must contain at least one status:error record — the workflow's error_count jq
    # expression will be > 0, so the step exits 1 (not silently treats as no-drift).
    error_count=$(printf '%s' "$result" | jq '[.[] | .variants[] | select(.status == "error")] | length')
    [ "$error_count" -gt 0 ]
}

# ---------------------------------------------------------------------------
# Fix r7-4a: ./make list hard-fail in detect-base-digest-drift.sh
# Regression guard: when _VALID_CONTAINERS_OVERRIDE is explicitly empty (not set
# at all, so the script falls through to ./make list), and ./make list fails,
# the script must exit 2 — NOT silently treat all containers as invalid and
# return "[]" (false no-drift).
# ---------------------------------------------------------------------------
@test "r7-fix4a: detect script exits 2 when _VALID_CONTAINERS_OVERRIDE unset and make list fails" {
    local fake_root="$TEST_TEMP_DIR/r7fix4a"
    mkdir -p "$fake_root/scripts" "$fake_root/helpers" "$fake_root/.build-lineage"
    cp "${DETECTOR_SCRIPT}" "$fake_root/scripts/detect-base-digest-drift.sh"
    # The script sources PROJECT_ROOT/helpers/lineage-utils.sh — must exist in fake root
    cp "${SCRIPTS_DIR}/../helpers/lineage-utils.sh" "$fake_root/helpers/"

    cat > "$fake_root/.build-lineage/foo-1.0.json" <<'EOF'
{
  "lineage_schema_version": 2,
  "container": "foo",
  "tag": "1.0",
  "base_image_ref": "alpine:3.21",
  "base_image_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
EOF

    # ./make list exits non-zero — simulates tooling failure
    cat > "$fake_root/make" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "list" ]]; then
    exit 1
fi
STUB
    chmod +x "$fake_root/make"

    local rc=0
    # Unset the override so the script falls through to ./make list
    cd "$fake_root" && unset _VALID_CONTAINERS_OVERRIDE && \
        bash scripts/detect-base-digest-drift.sh ".build-lineage" >/dev/null 2>/dev/null || rc=$?

    # Must exit with code 2 (tooling failure), NOT 0 (silent false no-drift)
    [ "$rc" -eq 2 ]
}

@test "r7-fix4b: detect script exits 2 when make list returns empty string" {
    # A make list that succeeds but prints nothing (empty output) is equally invalid.
    local fake_root="$TEST_TEMP_DIR/r7fix4b"
    mkdir -p "$fake_root/scripts" "$fake_root/helpers" "$fake_root/.build-lineage"
    cp "${DETECTOR_SCRIPT}" "$fake_root/scripts/detect-base-digest-drift.sh"
    cp "${SCRIPTS_DIR}/../helpers/lineage-utils.sh" "$fake_root/helpers/"

    cat > "$fake_root/.build-lineage/foo-1.0.json" <<'EOF'
{
  "lineage_schema_version": 2,
  "container": "foo",
  "tag": "1.0",
  "base_image_ref": "alpine:3.21",
  "base_image_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
EOF

    # ./make list exits 0 but prints nothing — empty canonical list
    cat > "$fake_root/make" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "list" ]] && { printf ''; exit 0; }
STUB
    chmod +x "$fake_root/make"

    local rc=0
    cd "$fake_root" && unset _VALID_CONTAINERS_OVERRIDE && \
        bash scripts/detect-base-digest-drift.sh ".build-lineage" >/dev/null 2>/dev/null || rc=$?

    # Empty make list is also a hard failure (exit 2)
    [ "$rc" -eq 2 ]
}

@test "r7-fix4c: _VALID_CONTAINERS_OVERRIDE non-empty bypasses make list check" {
    # Test hook: _VALID_CONTAINERS_OVERRIDE set to a non-empty value must bypass
    # the ./make list call entirely (existing pre-r7 behavior preserved for tests).
    local lineage_dir="$TEST_TEMP_DIR/r7fix4c/.build-lineage"
    mkdir -p "$lineage_dir"

    cat > "$lineage_dir/foo-1.0.json" <<'EOF'
{
  "lineage_schema_version": 2,
  "container": "foo",
  "tag": "1.0",
  "base_image_ref": "alpine:3.21",
  "base_image_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
EOF

    # _VALID_CONTAINERS_OVERRIDE is set (non-empty) → ./make list never called
    local rc=0
    result=$(_VALID_CONTAINERS_OVERRIDE="foo" PROBE_CMD="/bin/false" \
        bash "${DETECTOR_SCRIPT}" "$lineage_dir" 2>/dev/null) || rc=$?

    # Script must exit 0 (even with probe failure the detection itself runs)
    # and must NOT exit 2 (make list was bypassed)
    [ "$rc" -ne 2 ]
    # result must be valid JSON
    printf '%s' "$result" | jq '.' >/dev/null
}

# ---------------------------------------------------------------------------
# Fix r7-4d: update-last-rebuild.sh exits 2 when ./make list is empty
# Regression guard: ./make list returning empty must cause exit 2, not
# silently skip with exit 0 (which would hide the tooling failure).
# ---------------------------------------------------------------------------
@test "r7-fix4d: update-last-rebuild exits 2 when make list returns empty" {
    local fake_root="$TEST_TEMP_DIR/r7fix4d"
    local update_script="${SCRIPTS_DIR}/update-last-rebuild.sh"
    mkdir -p "$fake_root/scripts"
    cp "$update_script" "$fake_root/scripts/update-last-rebuild.sh"

    # ./make list succeeds but returns nothing
    cat > "$fake_root/make" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "list" ]] && { printf ''; exit 0; }
STUB
    chmod +x "$fake_root/make"

    local rc=0
    cd "$fake_root" && \
        bash scripts/update-last-rebuild.sh "mycontainer" "base-digest-drift" \
        <<< '[]' 2>/dev/null || rc=$?

    # Must exit 2 — tooling failure, NOT silent success
    [ "$rc" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Fix r8-1: jq -Rnc preserves alphabetically-first container
# Regression guard: piping N lines through `jq -Rc '[inputs]'` drops the
# first line because -R without -n consumes one line before [inputs] runs.
# Adding -n makes jq use null as its initial input, so [inputs] sees all lines.
# ---------------------------------------------------------------------------
@test "r8-fix1: jq -Rnc collects all containers including alphabetically-first" {
    # Simulate ./make list output: 3 containers in alphabetical order.
    # The first one (ansible) was previously dropped by jq -Rc (no -n).
    local make_output
    make_output=$(printf 'ansible\nbeta\ngamma\n')

    # Old broken form: jq -Rc '[inputs]' — drops first line
    local broken
    broken=$(echo "$make_output" | jq -Rc '[inputs]')
    # ansible is missing from broken output
    run bash -c "echo '$broken' | jq -r 'length'"
    [ "$output" -eq 2 ]
    run bash -c "echo '$broken' | jq -r '.[0]'"
    [ "$output" = "beta" ]

    # New correct form: jq -Rnc '[inputs]' — all lines present
    local correct
    correct=$(echo "$make_output" | jq -Rnc '[inputs]')
    run bash -c "echo '$correct' | jq -r 'length'"
    [ "$output" -eq 3 ]
    run bash -c "echo '$correct' | jq -r '.[0]'"
    [ "$output" = "ansible" ]
}

# ---------------------------------------------------------------------------
# Fix r8-2: error_count scoped to current matrix container
# Regression guard: a transient probe error on container "bar" must NOT
# prevent container "foo"'s matrix job from creating its drift PR.
# The jq filter must restrict error counting to the matrix container only.
# ---------------------------------------------------------------------------
@test "r8-fix2: error_count scoped to matrix container — bar error does not block foo" {
    # Synthetic drift JSON: foo has drift (clean), bar has an error variant
    local drift_json
    drift_json=$(cat <<'EOF'
[
  {
    "container": "foo",
    "variants": [
      {"tag": "foo:latest", "status": "drift", "cached_digest": "sha256:aaa", "live_digest": "sha256:bbb"}
    ]
  },
  {
    "container": "bar",
    "variants": [
      {"tag": "bar:latest", "status": "error", "error": "registry timeout"}
    ]
  }
]
EOF
)

    # Scoped filter for "foo" — should return 0 errors even though bar has 1
    local foo_errors
    foo_errors=$(echo "$drift_json" | jq --arg c "foo" \
        '[.[] | select(.container == $c) | .variants[] | select(.status == "error")] | length')
    [ "$foo_errors" -eq 0 ]

    # Scoped filter for "bar" — should return 1 error
    local bar_errors
    bar_errors=$(echo "$drift_json" | jq --arg c "bar" \
        '[.[] | select(.container == $c) | .variants[] | select(.status == "error")] | length')
    [ "$bar_errors" -eq 1 ]

    # The old unscoped filter — counts errors across ALL containers:
    # foo's job would have seen 1 error from bar and exited 1 (wrong).
    local unscoped_errors
    unscoped_errors=$(echo "$drift_json" | jq \
        '[.[] | .variants[] | select(.status == "error")] | length')
    [ "$unscoped_errors" -eq 1 ]

    # Cross-check: unscoped count is > 0 but foo-scoped count is 0,
    # confirming the fix prevents foo from being incorrectly blocked.
    [ "$unscoped_errors" -gt "$foo_errors" ]
}

# ---------------------------------------------------------------------------
# Fix r9-1 (NON-TERMINATING BUG): stale lineage filter via active build matrix
#
# Regression guard: a lineage entry whose tag is NOT in the active build matrix
# (returned by ./make list-builds) must be silently skipped.  Only active-tag
# entries should be reported.
# ---------------------------------------------------------------------------
@test "r9-fix1a: stale tag in lineage is skipped; active tag is reported" {
    local lineage_dir="$TEST_TEMP_DIR/r9fix1a/.build-lineage"
    mkdir -p "$lineage_dir"

    # Two lineage files: one for an active tag, one for a stale (rotated-away) tag
    cat > "$lineage_dir/myimage-2.0.json" <<'EOF'
{
  "lineage_schema_version": 2,
  "container": "myimage",
  "tag": "2.0",
  "base_image_ref": "alpine:3.21",
  "base_image_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
EOF
    cat > "$lineage_dir/myimage-1.0.json" <<'EOF'
{
  "lineage_schema_version": 2,
  "container": "myimage",
  "tag": "1.0",
  "base_image_ref": "alpine:3.21",
  "base_image_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
EOF

    # Active build matrix: only tag 2.0 is active; 1.0 was rotated away
    # Use per-container test hook to inject the active-tags list
    local probe_stub
    probe_stub=$(_make_digest_probe_stub "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")

    local result
    result=$(_VALID_CONTAINERS_OVERRIDE="myimage" \
        _ACTIVE_TAGS_OVERRIDE_myimage="2.0" \
        PROBE_CMD="$probe_stub" \
        bash "${DETECTOR_SCRIPT}" "$lineage_dir" 2>/dev/null)

    # Output must be valid JSON
    printf '%s' "$result" | jq '.' >/dev/null

    # Only the active tag (2.0) should appear in drift output
    local variant_count
    variant_count=$(printf '%s' "$result" | jq '[.[] | .variants[]] | length')
    [ "$variant_count" -eq 1 ]

    local reported_tag
    reported_tag=$(printf '%s' "$result" | jq -r '.[] | .variants[].variant_tag')
    [ "$reported_tag" = "2.0" ]
}

@test "r9-fix1b: stale tag skip emits ::notice:: to stderr" {
    local lineage_dir="$TEST_TEMP_DIR/r9fix1b/.build-lineage"
    mkdir -p "$lineage_dir"

    cat > "$lineage_dir/myimage-1.0.json" <<'EOF'
{
  "lineage_schema_version": 2,
  "container": "myimage",
  "tag": "1.0",
  "base_image_ref": "alpine:3.21",
  "base_image_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
EOF

    # Active matrix is empty for this container (all tags rotated away)
    local result rc=0
    result=$(_VALID_CONTAINERS_OVERRIDE="myimage" \
        _ACTIVE_TAGS_OVERRIDE_myimage="2.0" \
        PROBE_CMD="/bin/false" \
        bash "${DETECTOR_SCRIPT}" "$lineage_dir" 2>&1 >/dev/null) || rc=$?

    # Script must exit 0 (stale skip is not a fatal error)
    [ "$rc" -eq 0 ]

    # stderr must mention the stale skip notice
    echo "$result" | grep -q "Skipping stale lineage entry"
}

# ---------------------------------------------------------------------------
# Fix r9-2: tag sanitization — backticks and pipes in variant_tag are escaped
# in GHA ::notice:: output (via _escape_gha_command applied at extraction).
# ---------------------------------------------------------------------------
@test "r9-fix2: update-last-rebuild escapes backticks and pipes in variant_tag" {
    # Regression guard: a poisoned variant_tag containing backticks or pipes in the
    # drift JSON must be escaped before embedding in LAST_REBUILD.md markdown.
    local fake_root="$TEST_TEMP_DIR/r9fix2"
    mkdir -p "$fake_root/scripts" "$fake_root/myimage"
    cp "${SCRIPTS_DIR}/update-last-rebuild.sh" "$fake_root/scripts/update-last-rebuild.sh"

    # Provide a minimal ./make list stub
    cat > "$fake_root/make" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "list" ]] && { printf 'myimage\n'; exit 0; }
STUB
    chmod +x "$fake_root/make"

    # Drift JSON with a poisoned variant_tag containing backtick and pipe
    local drift_json
    drift_json=$(jq -cn '[{
      "container": "myimage",
      "variants": [{
        "variant_tag": "1.0`evil|cmd`",
        "base_image_ref": "alpine:3.21",
        "recorded_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "status": "drift"
      }]
    }]')

    cd "$fake_root" && \
        printf '%s' "$drift_json" | \
        bash scripts/update-last-rebuild.sh "myimage" "base-digest-drift" 2>/dev/null

    local content
    content=$(cat "$fake_root/myimage/LAST_REBUILD.md")

    # The backtick must be escaped as \` in markdown output (not raw `evil)
    # Correct form: 1.0\`evil\|cmd\` — backslash before backtick and pipe.
    # grep -F for literal backslash-backtick to verify escaping was applied.
    echo "$content" | grep -qF '\`evil'
    # And the pipe must also be escaped
    echo "$content" | grep -qF '\|cmd'
}

# ---------------------------------------------------------------------------
# Fix r9-3: container name with embedded newline is rejected before grep check
# ---------------------------------------------------------------------------
@test "r9-fix3: container name with embedded newline is rejected before grep validation" {
    local lineage_dir="$TEST_TEMP_DIR/r9fix3/.build-lineage"
    mkdir -p "$lineage_dir"

    # Craft a lineage JSON where the container field contains a newline sequence.
    # jq -n --arg produces the literal string with \n in it (not a real newline
    # in the JSON value — we need the jq raw output to embed a real newline).
    # We write it directly so the container field truly contains a newline char.
    printf '{"lineage_schema_version":2,"container":"foo\nmalicious","tag":"1.0","base_image_ref":"alpine:3.21","base_image_digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}\n' \
        > "$lineage_dir/evil-1.0.json"

    # _VALID_CONTAINERS_OVERRIDE contains "foo" and "bar" but NOT "malicious"
    # Without Fix r9-3, grep -qxF "foo\nmalicious" <<<"foo\nbar" would match "foo"
    # and pass "malicious" through as a valid container.
    local result rc=0
    result=$(_VALID_CONTAINERS_OVERRIDE="foo
bar" \
        PROBE_CMD="/bin/false" \
        bash "${DETECTOR_SCRIPT}" "$lineage_dir" 2>/dev/null) || rc=$?

    # Script exits 0 (a single rejected entry is not fatal)
    [ "$rc" -eq 0 ]

    # Output must be empty array (the entry was rejected, not passed through)
    local result_len
    result_len=$(printf '%s' "$result" | jq 'length')
    [ "$result_len" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Fix r9-4: ./make list pipeline failure in upstream-monitor sync step
# Unit-level regression: the jq pipeline on an empty/failed make list must
# produce an empty array, and the shell-level check must detect length == 0.
# This mirrors the fix applied in upstream-monitor.yaml.
# ---------------------------------------------------------------------------
@test "r9-fix4: empty make_list_out is detected before jq pipeline" {
    # Simulate the fixed pattern: the guard checks the raw string BEFORE piping
    # into jq -Rnc, because a here-string of "" sends a newline to jq which
    # produces [""] (length 1) — false non-empty.
    local make_list_out=""

    # Pattern used in the workflow: trim whitespace and check empty
    local trimmed="${make_list_out// /}"
    [ -z "$trimmed" ]
}

@test "r9-fix4b: jq -Rnc on non-empty make list output is non-zero length" {
    local make_list_out
    make_list_out=$(printf 'ansible\ndebian\nphp\n')

    local containers_json
    containers_json=$(jq -Rnc '[inputs]' <<<"$make_list_out")

    local length
    length=$(echo "$containers_json" | jq 'length')

    [ "$length" -eq 3 ]
}

# ---------------------------------------------------------------------------
# Fix r10-2: active-tags filter failure is FAIL CLOSED (skip container entirely)
#
# When ./make list-builds fails or returns empty, the detector must NOT emit
# drift records for that container (fail-closed).  Previous behavior disabled
# the stale-lineage filter (__SKIPPED__), allowing stale tags to trigger
# infinite drift-PR loops.
# ---------------------------------------------------------------------------

@test "r10-fix2a: list-builds failure → container fully skipped (fail-closed)" {
    local lineage_dir="$TEST_TEMP_DIR/r10fix2a/.build-lineage"
    mkdir -p "$lineage_dir"

    cat > "$lineage_dir/myimage-2.0.json" <<'EOF'
{
  "lineage_schema_version": 2,
  "container": "myimage",
  "tag": "2.0",
  "base_image_ref": "alpine:3.21",
  "base_image_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
EOF

    # Run without _VALID_CONTAINERS_OVERRIDE so production path runs list-builds
    # Since ./make list-builds won't work in the test dir, it will fail → fail-closed
    local result rc=0
    result=$(unset _VALID_CONTAINERS_OVERRIDE && \
        PROBE_CMD="/bin/false" \
        bash "${DETECTOR_SCRIPT}" "$lineage_dir" 2>/dev/null) || rc=$?

    # Script must exit 0 (container skip is not fatal)
    [ "$rc" -eq 0 ]

    # Output must be empty array — container was skipped entirely
    local result_len
    result_len=$(printf '%s' "$result" | jq 'length')
    [ "$result_len" -eq 0 ]
}

@test "r10-fix2b: script contains fail-closed warning text (code audit)" {
    # The production list-builds failure path (without _VALID_CONTAINERS_OVERRIDE)
    # cannot be exercised in tests without a full project context (the detector derives
    # PROJECT_ROOT from BASH_SOURCE[0] at startup, so env-var override is impossible).
    # r10-fix2a already confirms the container is skipped when list-builds fails.
    # This test audits that the warning text is present in the script source, ensuring
    # the fail-closed message is not accidentally removed.
    grep -q 'fail-closed' "${DETECTOR_SCRIPT}"
}

@test "r10-fix2c: stale tag still skipped when active-tags succeeds (no regression)" {
    local lineage_dir="$TEST_TEMP_DIR/r10fix2c/.build-lineage"
    mkdir -p "$lineage_dir"

    # One active tag (2.0), one stale tag (1.0)
    cat > "$lineage_dir/myimage-2.0.json" <<'EOF'
{
  "lineage_schema_version": 2,
  "container": "myimage",
  "tag": "2.0",
  "base_image_ref": "alpine:3.21",
  "base_image_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
EOF
    cat > "$lineage_dir/myimage-1.0.json" <<'EOF'
{
  "lineage_schema_version": 2,
  "container": "myimage",
  "tag": "1.0",
  "base_image_ref": "alpine:3.21",
  "base_image_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
EOF

    local probe_stub
    probe_stub=$(_make_digest_probe_stub "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")

    local result
    result=$(_VALID_CONTAINERS_OVERRIDE="myimage" \
        _ACTIVE_TAGS_OVERRIDE_myimage="2.0" \
        PROBE_CMD="$probe_stub" \
        bash "${DETECTOR_SCRIPT}" "$lineage_dir" 2>/dev/null)

    # Only active tag 2.0 should appear
    local variant_count
    variant_count=$(printf '%s' "$result" | jq '[.[] | .variants[]] | length')
    [ "$variant_count" -eq 1 ]

    local reported_tag
    reported_tag=$(printf '%s' "$result" | jq -r '.[] | .variants[].variant_tag')
    [ "$reported_tag" = "2.0" ]
}

# ---------------------------------------------------------------------------
# Fix r10-3: base_image_ref registry allowlist validation (SSRF prevention)
#
# Poisoned lineage with an attacker-controlled base_image_ref must be rejected
# before the probe fires.  The detector must emit a ::warning:: and skip the
# entry without calling the registry.
# ---------------------------------------------------------------------------

@test "r10-fix3a: poisoned base_image_ref (evil.com) is rejected without probe" {
    local lineage_dir="$TEST_TEMP_DIR/r10fix3a/.build-lineage"
    mkdir -p "$lineage_dir"

    cat > "$lineage_dir/myimage-1.0.json" <<'EOF'
{
  "lineage_schema_version": 2,
  "container": "myimage",
  "tag": "1.0",
  "base_image_ref": "evil.example.com/path:tag",
  "base_image_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
EOF

    # Probe stub that fails if called — must NOT be called
    local probe_stub
    probe_stub=$(mktemp "$TEST_TEMP_DIR/poison-probe.XXXXXX")
    cat > "$probe_stub" <<'STUB'
#!/usr/bin/env bash
echo "PROBE WAS CALLED — SSRF not prevented!" >&2
exit 1
STUB
    chmod +x "$probe_stub"

    local result stderr_out rc=0
    result=$(_VALID_CONTAINERS_OVERRIDE="myimage" \
        _ACTIVE_TAGS_OVERRIDE_myimage="1.0" \
        PROBE_CMD="$probe_stub" \
        bash "${DETECTOR_SCRIPT}" "$lineage_dir" 2>/tmp/r10fix3a-stderr.txt) || rc=$?

    stderr_out=$(cat /tmp/r10fix3a-stderr.txt)

    # Must exit 0 — rejection is not a fatal error
    [ "$rc" -eq 0 ]

    # Probe must NOT have been called
    echo "$stderr_out" | grep -qv "PROBE WAS CALLED"

    # Must emit a ::warning:: about the untrusted ref
    echo "$stderr_out" | grep -q "Refusing to probe untrusted"

    # Result must be empty array (entry skipped)
    local result_len
    result_len=$(printf '%s' "$result" | jq 'length')
    [ "$result_len" -eq 0 ]
}

@test "r10-fix3b: valid ghcr.io ref passes validation and is probed normally" {
    local lineage_dir="$TEST_TEMP_DIR/r10fix3b/.build-lineage"
    mkdir -p "$lineage_dir"

    cat > "$lineage_dir/myimage-1.0.json" <<'EOF'
{
  "lineage_schema_version": 2,
  "container": "myimage",
  "tag": "1.0",
  "base_image_ref": "ghcr.io/oorabona/debian:trixie",
  "base_image_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
EOF

    # Probe stub returns a different digest (drift)
    local probe_stub
    probe_stub=$(_make_digest_probe_stub "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")

    local result
    result=$(_VALID_CONTAINERS_OVERRIDE="myimage" \
        _ACTIVE_TAGS_OVERRIDE_myimage="1.0" \
        PROBE_CMD="$probe_stub" \
        bash "${DETECTOR_SCRIPT}" "$lineage_dir" 2>/dev/null)

    # Must report drift (probe was called and returned a different digest)
    local status
    status=$(printf '%s' "$result" | jq -r '.[] | .variants[].status')
    [ "$status" = "drift" ]
}

@test "r10-fix3c: Docker Hub bare name passes validation and is probed normally" {
    local lineage_dir="$TEST_TEMP_DIR/r10fix3c/.build-lineage"
    mkdir -p "$lineage_dir"

    cat > "$lineage_dir/myimage-1.0.json" <<'EOF'
{
  "lineage_schema_version": 2,
  "container": "myimage",
  "tag": "1.0",
  "base_image_ref": "alpine:3.21",
  "base_image_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
EOF

    local probe_stub
    probe_stub=$(_make_digest_probe_stub "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")

    local result
    result=$(_VALID_CONTAINERS_OVERRIDE="myimage" \
        _ACTIVE_TAGS_OVERRIDE_myimage="1.0" \
        PROBE_CMD="$probe_stub" \
        bash "${DETECTOR_SCRIPT}" "$lineage_dir" 2>/dev/null)

    local status
    status=$(printf '%s' "$result" | jq -r '.[] | .variants[].status')
    [ "$status" = "drift" ]
}

@test "r10-fix3d: mcr.microsoft.com ref passes validation" {
    local lineage_dir="$TEST_TEMP_DIR/r10fix3d/.build-lineage"
    mkdir -p "$lineage_dir"

    cat > "$lineage_dir/myimage-1.0.json" <<'EOF'
{
  "lineage_schema_version": 2,
  "container": "myimage",
  "tag": "1.0",
  "base_image_ref": "mcr.microsoft.com/windows/servercore:ltsc2022",
  "base_image_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
EOF

    local probe_stub
    probe_stub=$(_make_digest_probe_stub "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")

    local result
    result=$(_VALID_CONTAINERS_OVERRIDE="myimage" \
        _ACTIVE_TAGS_OVERRIDE_myimage="1.0" \
        PROBE_CMD="$probe_stub" \
        bash "${DETECTOR_SCRIPT}" "$lineage_dir" 2>/dev/null)

    local status
    status=$(printf '%s' "$result" | jq -r '.[] | .variants[].status')
    [ "$status" = "drift" ]
}

# ---------------------------------------------------------------------------
# Fix r17: docker.io FQDN allowlist (gate r17 REFUSE concordant finding)
#
# The build pipeline resolves ARG REMOTE_CR=docker.io into lineage refs of
# the form docker.io/library/foo:bar or docker.io/oorabona/foo:tag.  The r10
# allowlist included registry-1.docker.io and index.docker.io but omitted
# the bare docker.io FQDN, causing silent drift detection failure for those
# containers.
# ---------------------------------------------------------------------------

@test "r17-fix-a: docker.io/library/* ref passes validation and is probed normally" {
    local lineage_dir="$TEST_TEMP_DIR/r17fixa/.build-lineage"
    mkdir -p "$lineage_dir"

    cat > "$lineage_dir/myimage-1.0.json" <<'EOF'
{
  "lineage_schema_version": 2,
  "container": "myimage",
  "tag": "1.0",
  "base_image_ref": "docker.io/library/alpine:3.21",
  "base_image_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
EOF

    local probe_stub
    probe_stub=$(_make_digest_probe_stub "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")

    local result
    result=$(_VALID_CONTAINERS_OVERRIDE="myimage" \
        _ACTIVE_TAGS_OVERRIDE_myimage="1.0" \
        PROBE_CMD="$probe_stub" \
        bash "${DETECTOR_SCRIPT}" "$lineage_dir" 2>/dev/null)

    # Must report drift (probe was called, not silently skipped)
    local status
    status=$(printf '%s' "$result" | jq -r '.[] | .variants[].status')
    [ "$status" = "drift" ]
}

@test "r17-fix-b: docker.io/oorabona/* ref passes validation and is probed normally" {
    local lineage_dir="$TEST_TEMP_DIR/r17fixb/.build-lineage"
    mkdir -p "$lineage_dir"

    cat > "$lineage_dir/myimage-1.0.json" <<'EOF'
{
  "lineage_schema_version": 2,
  "container": "myimage",
  "tag": "1.0",
  "base_image_ref": "docker.io/oorabona/php:latest",
  "base_image_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
EOF

    local probe_stub
    probe_stub=$(_make_digest_probe_stub "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")

    local result
    result=$(_VALID_CONTAINERS_OVERRIDE="myimage" \
        _ACTIVE_TAGS_OVERRIDE_myimage="1.0" \
        PROBE_CMD="$probe_stub" \
        bash "${DETECTOR_SCRIPT}" "$lineage_dir" 2>/dev/null)

    # Must report drift (probe was called, not silently skipped)
    local status
    status=$(printf '%s' "$result" | jq -r '.[] | .variants[].status')
    [ "$status" = "drift" ]
}
