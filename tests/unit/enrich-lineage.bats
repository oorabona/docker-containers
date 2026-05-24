#!/usr/bin/env bats

# Unit tests for scripts/enrich-lineage.sh
#
# The enrichment script adds multi-arch manifest data, sizes, platforms, and
# attestation links to .build-lineage/*.json files at build time, eliminating
# the per-dashboard-regen network calls that caused 70+ min runtimes.
#
# Tests use stubs for gh and curl so no network access or auth is required.

load "../test_helper"

# --- helpers -----------------------------------------------------------

SCRIPT_DIR=""
PROJECT_ROOT_OVERRIDE=""

setup() {
  setup_temp_dir
  export ORIGINAL_PATH="$PATH"

  SCRIPT_DIR="$(cd "$BATS_TEST_DIRNAME/../../scripts" && pwd)"
  export SCRIPT_DIR

  PROJECT_ROOT_OVERRIDE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export PROJECT_ROOT_OVERRIDE

  # Lineage dir under $TEST_TEMP_DIR for isolation
  export LINEAGE_DIR="$TEST_TEMP_DIR/.build-lineage"
  mkdir -p "$LINEAGE_DIR"

  # Stub bin dir on PATH
  mkdir -p "$TEST_TEMP_DIR/bin"
  export PATH="$TEST_TEMP_DIR/bin:$PATH"

  # Default stubs that return empty/null (no network needed)
  _write_stub_gh_no_attestation
  _write_stub_curl_empty
}

teardown() {
  teardown_temp_dir
  export PATH="$ORIGINAL_PATH"
}

# Write a stub gh that returns no attestations
_write_stub_gh_no_attestation() {
  cat > "$TEST_TEMP_DIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo '{"attestations":[]}'
STUB
  chmod +x "$TEST_TEMP_DIR/bin/gh"
}

# Write a stub gh that returns a valid attestation
_write_stub_gh_with_attestation() {
  cat > "$TEST_TEMP_DIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo '{"attestations":[{"bundle_url":"https://storage.example.com/attestations/68518664/2026/01/01/99887766.json.sn?sig=x"}]}'
STUB
  chmod +x "$TEST_TEMP_DIR/bin/gh"
}

# Write a stub curl that returns nothing (simulates GHCR unavailability)
_write_stub_curl_empty() {
  cat > "$TEST_TEMP_DIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$TEST_TEMP_DIR/bin/curl"
}

# Create a minimal lineage file in LINEAGE_DIR
_write_lineage() {
  local filename="$1"
  local container="${2:-testcontainer}"
  local tag="${3:-1.0.0}"
  local oci_digest="${4:-}"
  cat > "$LINEAGE_DIR/$filename" <<JSON
{
  "container": "$container",
  "version": "$tag",
  "tag": "$tag",
  "flavor": "",
  "build_digest": "abc123",
  "oci_subject_digest": "$oci_digest",
  "built_at": "2026-01-01T00:00:00Z"
}
JSON
}

# Run enrich-lineage.sh with the test's lineage dir
_run_enrich() {
  run bash "$SCRIPT_DIR/enrich-lineage.sh" \
    --owner "testowner" \
    --lineage-dir "$LINEAGE_DIR"
}

# -----------------------------------------------------------------------
# 1. Empty lineage directory exits 0 with notice saying 0 enriched
# -----------------------------------------------------------------------
@test "empty lineage dir: exits 0 and emits ::notice:: with 0 enriched" {
  rm -rf "$LINEAGE_DIR"
  mkdir -p "$LINEAGE_DIR"

  _run_enrich

  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::"* ]]
  [[ "$output" == *"Enriched 0"* ]]
}

# -----------------------------------------------------------------------
# 2. Non-existent lineage directory exits 0 with notice
# -----------------------------------------------------------------------
@test "non-existent lineage dir: exits 0 with notice" {
  rm -rf "$LINEAGE_DIR"

  _run_enrich

  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::"* ]]
}

# -----------------------------------------------------------------------
# 3. Skip-list: .sbom.json, .changelog.json, .history.json, ext-*.json
# -----------------------------------------------------------------------
@test "skip-list: sbom, changelog, history, ext- files are not processed" {
  echo '{}' > "$LINEAGE_DIR/mycontainer-1.0.0.sbom.json"
  echo '{}' > "$LINEAGE_DIR/mycontainer-1.0.0.changelog.json"
  echo '{}' > "$LINEAGE_DIR/mycontainer-1.0.0.history.json"
  echo '{}' > "$LINEAGE_DIR/ext-citus-pg18-14.0.0.json"

  _run_enrich

  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::"* ]]
  [[ "$output" == *"Enriched 0"* ]]
}

# -----------------------------------------------------------------------
# 4. Malformed JSON / missing container field: logged as ::warning::, batch continues
# -----------------------------------------------------------------------
@test "malformed JSON: logged as warning, batch continues" {
  echo 'this is not json' > "$LINEAGE_DIR/bad-notjson-1.0.0.json"
  echo '{"tag":"1.0.0","build_digest":"abc"}' > "$LINEAGE_DIR/no-container-1.0.0.json"
  _write_lineage "good-1.0.0.json" "good" "1.0.0"

  _run_enrich

  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
  [[ "$output" == *"::notice::"* ]]
}

# -----------------------------------------------------------------------
# 5. Missing oci_subject_digest: attestation fields are null, no error
# -----------------------------------------------------------------------
@test "missing oci_subject_digest: attestation_id and attestation_url set to null" {
  _write_lineage "nodigest-1.0.0.json" "nodigest" "1.0.0" ""

  _run_enrich

  [ "$status" -eq 0 ]

  local att_id
  att_id=$(jq -r '.attestation_id' "$LINEAGE_DIR/nodigest-1.0.0.json")
  [ "$att_id" = "null" ]

  local att_url
  att_url=$(jq -r '.attestation_url' "$LINEAGE_DIR/nodigest-1.0.0.json")
  [ "$att_url" = "null" ]
}

# -----------------------------------------------------------------------
# 6. GHCR call failure (curl returns empty): null fields, no error
# -----------------------------------------------------------------------
@test "GHCR call failure: lineage gets null multi-arch fields, no error" {
  _write_stub_curl_empty
  _write_lineage "ghcrfail-1.0.0.json" "ghcrfail" "1.0.0"

  _run_enrich

  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::"* ]]

  local idx_digest
  idx_digest=$(jq -r '.multi_arch_index_digest' "$LINEAGE_DIR/ghcrfail-1.0.0.json")
  [ "$idx_digest" = "null" ]
}

# -----------------------------------------------------------------------
# 7. Idempotency: already-enriched file (non-null multi_arch_index_digest) is skipped
# -----------------------------------------------------------------------
@test "idempotency: already-enriched file is skipped without modification" {
  cat > "$LINEAGE_DIR/enriched-1.0.0.json" <<'JSON'
{
  "container": "enriched",
  "tag": "1.0.0",
  "build_digest": "abc123",
  "oci_subject_digest": "",
  "multi_arch_index_digest": "sha256:deadbeef",
  "manifest_digest_amd64": "sha256:aaa",
  "manifest_digest_arm64": "sha256:bbb",
  "multi_arch_platforms": ["amd64","arm64"],
  "size_amd64_bytes": 104857600,
  "size_arm64_bytes": 209715200,
  "attestation_id": "42",
  "attestation_url": "https://github.com/example/attestations/42"
}
JSON

  local before_md5
  before_md5=$(md5sum "$LINEAGE_DIR/enriched-1.0.0.json" | awk '{print $1}')

  _run_enrich

  [ "$status" -eq 0 ]

  local after_md5
  after_md5=$(md5sum "$LINEAGE_DIR/enriched-1.0.0.json" | awk '{print $1}')
  [ "$before_md5" = "$after_md5" ]

  [[ "$output" == *"Enriched 0"* ]]
}

# -----------------------------------------------------------------------
# 8. Second pass on a freshly-enriched file is a no-op
# -----------------------------------------------------------------------
@test "second pass: re-running on an enriched file leaves it byte-for-byte unchanged" {
  _write_lineage "roundtrip-1.0.0.json" "roundtrip" "1.0.0"

  _run_enrich
  [ "$status" -eq 0 ]

  local md5_pass1
  md5_pass1=$(md5sum "$LINEAGE_DIR/roundtrip-1.0.0.json" | awk '{print $1}')

  _run_enrich
  [ "$status" -eq 0 ]

  local md5_pass2
  md5_pass2=$(md5sum "$LINEAGE_DIR/roundtrip-1.0.0.json" | awk '{print $1}')
  [ "$md5_pass1" = "$md5_pass2" ]
}

# -----------------------------------------------------------------------
# 9. Enriched file has all eight expected new fields
# -----------------------------------------------------------------------
@test "enriched file has all eight expected new fields" {
  _write_lineage "fields-1.0.0.json" "fields" "1.0.0"

  _run_enrich

  [ "$status" -eq 0 ]

  local enriched_file="$LINEAGE_DIR/fields-1.0.0.json"

  for field in multi_arch_index_digest manifest_digest_amd64 manifest_digest_arm64 \
               multi_arch_platforms size_amd64_bytes size_arm64_bytes \
               attestation_id attestation_url; do
    run jq -e "has(\"$field\")" "$enriched_file"
    [ "$status" -eq 0 ] || {
      echo "Missing field: $field in $enriched_file" >&2
      return 1
    }
  done
}

# -----------------------------------------------------------------------
# 10. Original lineage fields are preserved after enrichment
# -----------------------------------------------------------------------
@test "original lineage fields are preserved after enrichment" {
  _write_lineage "preserve-1.0.0.json" "preserve" "1.0.0"

  _run_enrich

  [ "$status" -eq 0 ]

  local f="$LINEAGE_DIR/preserve-1.0.0.json"
  [ "$(jq -r '.container' "$f")" = "preserve" ]
  [ "$(jq -r '.tag' "$f")" = "1.0.0" ]
  [ "$(jq -r '.build_digest' "$f")" = "abc123" ]
}

# -----------------------------------------------------------------------
# 11. Error in one file doesn't abort processing of subsequent files
# -----------------------------------------------------------------------
@test "per-file error does not abort batch: subsequent files are still processed" {
  echo 'not-json-at-all' > "$LINEAGE_DIR/aaa-bad-1.0.0.json"
  _write_lineage "zzz-good-2.0.0.json" "goodcontainer" "2.0.0"

  _run_enrich

  [ "$status" -eq 0 ]
  run jq -e 'has("multi_arch_index_digest")' "$LINEAGE_DIR/zzz-good-2.0.0.json"
  [ "$status" -eq 0 ]
}

# -----------------------------------------------------------------------
# 12. gh attestation lookup: attestation_id written when gh returns valid response
# -----------------------------------------------------------------------
@test "attestation_id is written when gh returns valid bundle_url" {
  _write_stub_gh_with_attestation

  local oci="sha256:c86e34e20b3ca1cef663a969f1f3e6535a670cb96993b2fb3a3affc24f92410b"
  _write_lineage "attok-1.0.0.json" "attok" "1.0.0" "$oci"

  _run_enrich

  [ "$status" -eq 0 ]

  local att_id
  att_id=$(jq -r '.attestation_id' "$LINEAGE_DIR/attok-1.0.0.json")
  [ "$att_id" = "99887766" ]

  local att_url
  att_url=$(jq -r '.attestation_url' "$LINEAGE_DIR/attok-1.0.0.json")
  [[ "$att_url" == *"attestations/99887766"* ]]
}
