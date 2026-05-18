#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Unit tests for jq timeout backstop in generate-dashboard.sh (SBOM processing)
#
# Context: the 25 MiB size-cutoff guard was removed (issue #470). The original
# CI stall was a transient GitHub-API condition, not unbounded jq. The 37 MB
# github-runner SBOM processes in ~0.6s; the old guard silently dropped real
# per-ecosystem provenance for windows-ltsc2022-dev. Only the `timeout 60 jq`
# backstop remains as protection against truly pathological inputs.
#
# Covers:
#   - get_sbom_summary: normal SBOM returns full parsed JSON (grouping + total)
#   - get_sbom_summary: SBOM larger than 25 MiB is processed (not short-circuited to {})
#   - get_sbom_summary: missing file returns {}
#   - get_sbom_summary: shimmed-timeout partial-output returns {} (jq output discarded)
#   - get_sbom_packages: normal SBOM returns parsed JSON with package names+versions
#   - get_sbom_packages: SBOM larger than 25 MiB is processed (not short-circuited to {})
#   - get_sbom_packages: missing file returns {}
#   - get_sbom_packages: shimmed-timeout partial-output returns {} (jq output discarded)
#
# Mutation each test catches (Test Validity Gate):
#   - "full shape" tests: breaking get_sbom_summary jq grouping → "deb":2 disappears;
#     asserting only .total would miss a regression that collapses grouping but keeps total
#   - "package names+versions" tests: breaking jq .name/.versionInfo extraction → missing
#     field; catches any field-name regression (e.g. .name→.pkgName)
#   - "larger than 25 MiB processed" tests: re-introducing the old SBOM_MAX_BYTES size-cutoff
#     would return {} for the large fixture instead of the real package summary
#   - "missing file" tests: removing [[ -f ]] guard → error/non-zero instead of {}
#   - "shimmed-timeout" tests: removing `if ! result=$(timeout 60 jq ...)` discard logic
#     → partial stdout leaks into result instead of {} being returned

# ---------------------------------------------------------------------------
# Helper: generate a large VALID SPDX-ish JSON file exceeding 25 MiB.
# Used to verify that large SBOMs are now PROCESSED by jq (no size cutoff).
# The file is valid JSON so jq succeeds — proves no regression to the old
# size-cutoff guard (invalid JSON would make jq fail regardless of any guard).
# ---------------------------------------------------------------------------
_create_large_valid_sbom() {
    local path="$1"
    # Build a valid SPDX JSON with a large padding field so the file > 26MB.
    # 8192 packages × ~220 bytes each ≈ 1.8MB base; pad with a 25MB-sized
    # "filler" field on the root to guarantee we exceed the guard.
    python3 - "$path" <<'PYEOF'
import json, sys, os

path = sys.argv[1]

# Build 2 real packages (deb type) that the guard tests won't reach
packages = []
for i in range(2):
    packages.append({
        "SPDXID": f"SPDXRef-pkg-real-{i}",
        "name": f"real-pkg-{i}",
        "versionInfo": f"1.{i}.0",
        "externalRefs": [
            {
                "referenceCategory": "PACKAGE-MANAGER",
                "referenceType": "purl",
                "referenceLocator": f"pkg:deb/debian/real-pkg-{i}@1.{i}.0",
            }
        ],
    })

# Add 50000 more packages to bulk up the file
for i in range(50000):
    packages.append({
        "SPDXID": f"SPDXRef-pkg-{i}",
        "name": f"pkg-{i}",
        "versionInfo": f"1.{i % 100}.{i % 10}",
        "externalRefs": [
            {
                "referenceCategory": "PACKAGE-MANAGER",
                "referenceType": "purl",
                "referenceLocator": f"pkg:apk/alpine/pkg-{i}@1.{i % 100}.{i % 10}",
            }
        ],
    })

doc = {
    "SPDXID": "SPDXRef-DOCUMENT",
    "spdxVersion": "SPDX-2.3",
    "name": "large-test-sbom",
    "packages": packages,
}

with open(path, "w") as f:
    json.dump(doc, f)

size = os.path.getsize(path)
# Pad the document with a large string field to ensure > 26214400 bytes
if size < 27000000:
    pad_needed = 27000001 - size
    doc["_padding"] = "P" * pad_needed
    with open(path, "w") as f:
        json.dump(doc, f)
PYEOF
}

setup() {
    TEST_DIR=$(mktemp -d)
    ORIG_DIR="$PWD"
    cd "$TEST_DIR" || exit 1

    # Save bats' EXIT trap before sourcing generate-dashboard.sh.
    # generate-dashboard.sh sets its own EXIT trap (TRIVY_CACHE_FILE cleanup);
    # if we let it replace bats' trap, failing tests exit silently.
    local _saved_exit_trap
    _saved_exit_trap=$(trap -p EXIT 2>/dev/null) || true

    source "$ORIG_DIR/helpers/logging.sh" 2>/dev/null || true
    source "$ORIG_DIR/helpers/variant-utils.sh" 2>/dev/null || true
    source "$ORIG_DIR/generate-dashboard.sh" 2>/dev/null || true

    # Capture the trivy cache file created at source-time for teardown cleanup.
    _SOURCED_TRIVY_CACHE="${TRIVY_CACHE_FILE:-}"
    export _SOURCED_TRIVY_CACHE

    # Restore bats' EXIT trap.
    if [[ -n "$_saved_exit_trap" ]]; then
        eval "$_saved_exit_trap" 2>/dev/null || true
    else
        trap - EXIT 2>/dev/null || true
    fi

    # Override SCRIPT_DIR to point at our test temp dir (where we place .build-lineage/).
    export SCRIPT_DIR="$TEST_DIR"

    # Create a minimal valid SPDX SBOM fixture (< 1KB — well under the 25MB guard).
    # Two packages, both deb type → expected summary: {"deb":2,"total":2}
    # Expected packages: {"deb":[{"n":"curl","v":"7.88.1"},{"n":"openssl","v":"3.0.9"}]}
    mkdir -p "$TEST_DIR/.build-lineage"
    cat > "$TEST_DIR/.build-lineage/mycontainer-1.0.sbom.json" <<'EOF'
{
  "SPDXID": "SPDXRef-DOCUMENT",
  "spdxVersion": "SPDX-2.3",
  "name": "test-sbom",
  "packages": [
    {
      "SPDXID": "SPDXRef-pkg-curl",
      "name": "curl",
      "versionInfo": "7.88.1",
      "externalRefs": [
        {
          "referenceCategory": "PACKAGE-MANAGER",
          "referenceType": "purl",
          "referenceLocator": "pkg:deb/debian/curl@7.88.1"
        }
      ]
    },
    {
      "SPDXID": "SPDXRef-pkg-openssl",
      "name": "openssl",
      "versionInfo": "3.0.9",
      "externalRefs": [
        {
          "referenceCategory": "PACKAGE-MANAGER",
          "referenceType": "purl",
          "referenceLocator": "pkg:deb/debian/openssl@3.0.9"
        }
      ]
    }
  ]
}
EOF
}

teardown() {
    cd "$ORIG_DIR" || true
    rm -f "${_SOURCED_TRIVY_CACHE:-}" 2>/dev/null || true
    rm -rf "$TEST_DIR"
}

# =============================================================================
# get_sbom_summary
# =============================================================================

@test "get_sbom_summary: normal SBOM returns full JSON shape with grouping and total" {
    # Mutation caught: breaking the jq grouping expression in get_sbom_summary
    # (e.g. removing group_by or from_entries) → "deb":2 disappears from output.
    # Asserting ONLY .total==2 would miss a regression that collapses grouping
    # but keeps the total; this test locks the full shape.
    run get_sbom_summary "mycontainer" "1.0"
    [ "$status" -eq 0 ]
    # Full shape: must have total==2 AND deb==2 (both packages are pkg:deb/...)
    total=$(echo "$output" | jq -r '.total // empty')
    [ "$total" = "2" ]
    deb_count=$(echo "$output" | jq -r '.deb // empty')
    [ "$deb_count" = "2" ]
    # Must NOT contain keys other than "deb" and "total" for this fixture
    key_count=$(echo "$output" | jq 'keys | length')
    [ "$key_count" = "2" ]
}

@test "get_sbom_summary: missing SBOM file returns empty object {}" {
    # Mutation caught: removing the [[ -f ]] guard would attempt to stat/parse
    # a non-existent file rather than returning {} cleanly.
    run get_sbom_summary "nonexistent" "9.9"
    [ "$status" -eq 0 ]
    [ "$output" = "{}" ]
}

@test "get_sbom_summary: SBOM larger than 25 MiB is processed by jq (not short-circuited)" {
    # Mutation caught: re-introducing the old SBOM_MAX_BYTES size-cutoff would return
    # {} for this fixture instead of the real package summary. The fixture is VALID JSON
    # so jq succeeds — proving jq ran (not a parse-failure fallback).
    # The fixture contains 2 real deb packages + 50000 apk packages. If the size-cutoff
    # were present, {} would be returned and deb/apk counts would be absent.
    _create_large_valid_sbom "$TEST_DIR/.build-lineage/mycontainer-large.sbom.json"
    local size
    size=$(stat -c%s "$TEST_DIR/.build-lineage/mycontainer-large.sbom.json")
    [ "$size" -gt 26214400 ]  # ensure fixture is actually > 25 MiB

    run get_sbom_summary "mycontainer" "large"
    [ "$status" -eq 0 ]
    # Must NOT be empty — jq must have run and produced real package counts
    [ "$output" != "{}" ]
    # The fixture has 2 deb + 50000 apk packages; total must be 50002
    total=$(echo "$output" | jq -r '.total // empty')
    [ "$total" = "50002" ]
    # Both ecosystem types must appear in the summary
    echo "$output" | jq -e '.deb' > /dev/null
    echo "$output" | jq -e '.apk' > /dev/null
}

@test "get_sbom_summary: shimmed-timeout partial-output returns {} (jq output discarded)" {
    # Mutation caught: removing the `if ! result=$(timeout 60 jq ...)` discard
    # guard (i.e. unconditionally assigning result=<jq output>) would cause
    # partial stdout from the timed-out jq to leak into result instead of {}.
    # This shim simulates timeout killing jq mid-output (exit 124 + partial JSON).
    local shim_dir
    shim_dir=$(mktemp -d)
    # Fake timeout: prints a partial JSON fragment to stdout then exits 124
    cat > "$shim_dir/timeout" <<'SHEOF'
#!/bin/bash
# Shim: ignore the timeout value and jq args; print partial output then exit 124
echo '{"partial": "output_that_must_not_leak"'
exit 124
SHEOF
    chmod +x "$shim_dir/timeout"

    PATH="$shim_dir:$PATH" run --separate-stderr get_sbom_summary "mycontainer" "1.0"
    [ "$status" -eq 0 ]
    [ "$output" = "{}" ]
    # Confirm the warning was emitted (jq timed out path)
    echo "$stderr" | grep -q "timed out"
}

# =============================================================================
# get_sbom_packages
# =============================================================================

@test "get_sbom_packages: normal SBOM returns parsed JSON with package names and versions" {
    # Mutation caught: breaking jq .name or .versionInfo field extraction in
    # get_sbom_packages → missing names/versions in output (test catches any
    # field-name regression e.g. .name→.pkgName or .versionInfo→.version).
    run get_sbom_packages "mycontainer" "1.0"
    [ "$status" -eq 0 ]
    [ "$output" != "{}" ]
    # Must contain "deb" type from our fixture's pkg:deb/... purl
    echo "$output" | grep -q '"deb"'
    # Must contain both package names
    echo "$output" | grep -q '"curl"'
    echo "$output" | grep -q '"openssl"'
    # Must contain both versions
    echo "$output" | grep -q '"7.88.1"'
    echo "$output" | grep -q '"3.0.9"'
    # Structural check: deb array must have exactly 2 entries
    deb_count=$(echo "$output" | jq '.deb | length')
    [ "$deb_count" = "2" ]
    # Both entries must have n and v fields
    curl_v=$(echo "$output" | jq -r '.deb[] | select(.n == "curl") | .v')
    [ "$curl_v" = "7.88.1" ]
    openssl_v=$(echo "$output" | jq -r '.deb[] | select(.n == "openssl") | .v')
    [ "$openssl_v" = "3.0.9" ]
}

@test "get_sbom_packages: missing SBOM file returns empty object {}" {
    # Mutation caught: removing the [[ -f ]] guard would error on missing file.
    run get_sbom_packages "nonexistent" "9.9"
    [ "$status" -eq 0 ]
    [ "$output" = "{}" ]
}

@test "get_sbom_packages: SBOM larger than 25 MiB is processed by jq (not short-circuited)" {
    # Mutation caught: re-introducing the old SBOM_MAX_BYTES size-cutoff would return
    # {} for this large VALID fixture instead of real package data. The fixture is valid
    # JSON — if {} were returned it proves the cutoff fired, not a jq parse failure.
    # The fixture has 2 real deb packages + 50000 apk packages; if cutoff were present,
    # neither "deb" nor "apk" keys would appear in the output.
    _create_large_valid_sbom "$TEST_DIR/.build-lineage/mycontainer-large2.sbom.json"
    local size
    size=$(stat -c%s "$TEST_DIR/.build-lineage/mycontainer-large2.sbom.json")
    [ "$size" -gt 26214400 ]  # ensure fixture is actually > 25 MiB

    run get_sbom_packages "mycontainer" "large2"
    [ "$status" -eq 0 ]
    # Must NOT be empty — jq must have run and extracted real package entries
    [ "$output" != "{}" ]
    # Both ecosystem types must be present
    echo "$output" | jq -e '.deb' > /dev/null
    echo "$output" | jq -e '.apk' > /dev/null
    # deb array must have exactly 2 real entries (the 2 deb packages in the fixture)
    deb_count=$(echo "$output" | jq '.deb | length')
    [ "$deb_count" = "2" ]
}

@test "get_sbom_packages: shimmed-timeout partial-output returns {} (jq output discarded)" {
    # Mutation caught: removing the `if ! result=$(timeout 60 jq ...)` discard
    # guard → partial stdout from the timed-out jq leaks into result instead of {}.
    # Shim simulates timeout killing jq mid-run (exit 124 + partial JSON on stdout).
    local shim_dir
    shim_dir=$(mktemp -d)
    cat > "$shim_dir/timeout" <<'SHEOF'
#!/bin/bash
# Shim: print partial JSON fragment then exit 124 (simulates timeout kill)
echo '{"deb": [{"n": "curl", "v": "7.88.1"'
exit 124
SHEOF
    chmod +x "$shim_dir/timeout"

    PATH="$shim_dir:$PATH" run --separate-stderr get_sbom_packages "mycontainer" "1.0"
    [ "$status" -eq 0 ]
    [ "$output" = "{}" ]
    # Confirm the warning was emitted (jq timed out path)
    echo "$stderr" | grep -q "timed out"
}

# =============================================================================
# latest-docker-tag (helpers/docker-tag) — capture-first rc check
# =============================================================================

@test "latest-docker-tag: timeout exit-124 with partial valid JSON returns rc=1 and empty stdout" {
    # Mutation caught: removing the capture-first `rc` check in latest-docker-tag
    # (i.e. dropping `rc=$?; if [ "$rc" -ne 0 ]; then return 1; fi`) would cause
    # `raw` to hold the partial valid tags JSON emitted before the kill, which then
    # passes through jq/.Tags[]/grep/sort/tail and produces a false-success tag on
    # stdout instead of an empty result.
    #
    # This shim replaces `timeout` so that `timeout 120 docker run ...` prints a
    # syntactically-valid tags list to stdout (what a real skopeo would emit) then
    # exits 124 — exactly what happens when skopeo is killed mid-output by a wall-
    # clock timeout.  The function must detect rc=124, return 1, and emit nothing.

    # Source the helper (functions only; execution guard prevents side-effects).
    source "$ORIG_DIR/helpers/docker-tag" 2>/dev/null || true

    local shim_dir
    shim_dir=$(mktemp -d)
    # Fake timeout: ignores the real timeout value and all remaining args;
    # prints a VALID partial skopeo list-tags JSON response then exits 124.
    # The JSON is intentionally complete/valid so that jq would parse it
    # successfully if the rc check were absent — proving it's the rc guard
    # (not a jq parse failure) that prevents the false-success.
    cat > "$shim_dir/timeout" <<'SHEOF'
#!/bin/bash
# Shim: emit valid partial skopeo list-tags JSON, then exit 124
printf '{"Repository":"docker://library/alpine","Tags":["3.18","3.19","3.20","latest"]}\n'
exit 124
SHEOF
    chmod +x "$shim_dir/timeout"

    # Run via bats `run` so non-zero exit is captured as $status, not an error.
    # Export PATH inside a wrapper script so the shim is picked up by the
    # `timeout` call inside the function (prefix-env on a bash function does
    # NOT propagate to child processes; wrapper script with exported PATH does).
    local wrapper
    wrapper="$shim_dir/run-latest-docker-tag.sh"
    cat > "$wrapper" <<WEOF
#!/bin/bash
source "$ORIG_DIR/helpers/docker-tag"
export PATH="$shim_dir:\$PATH"
latest-docker-tag "alpine" "^3\\." 2>/dev/null
WEOF
    chmod +x "$wrapper"

    run "$wrapper"

    # rc must be 1 (failure path) — not 0 (false success).
    [ "$status" -eq 1 ]
    # stdout must be empty — the partial valid JSON must NOT have leaked through
    # the jq/.Tags[]/grep/sort/tail pipeline to produce a tag string.
    [ -z "$output" ]
}
