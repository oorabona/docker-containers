#!/usr/bin/env bats

# Tests for the per-arch manifest file-cache tier in ghcr_get_manifest_sizes
# (helpers/registry-utils.sh).
#
# All tests run offline: curl and gh are intercepted via a PATH shim that
# emits canned bodies and appends a classification line to a CALLS counter
# file per request.
#
# Classification lines written to $CALLS:
#   TOKEN   — request to */token* (auth token fetch)
#   INDEX   — request to */manifests/<non-sha256-ref>* (index/tag fetch)
#   PERARCH — request to */manifests/sha256:*           (per-arch sub-manifest)
#
# Per-arch cache files live under ${GHCR_CACHE_DIR}/perarch/ (dedicated subdir,
# provably disjoint from the flat idx-* files managed by _ghcr_invalidate_index).

# ---------------------------------------------------------------------------
# Fixture constants
# ---------------------------------------------------------------------------

# OCI index body: two arches, two deterministic digests.
# NOTE: the loop splits on ':' so the digest is read as
#   arch=amd64, digest_prefix=sha256, digest_hash=aaa...
_OCI_INDEX='{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "manifests": [
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:aaa000000000000000000000000000000000000000000000000000000000",
      "platform": { "architecture": "amd64", "os": "linux" }
    },
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:bbb000000000000000000000000000000000000000000000000000000000",
      "platform": { "architecture": "arm64", "os": "linux" }
    }
  ]
}'

# Per-arch manifest body: config 100 + layers 200+300 = total 600.
_PER_ARCH_MANIFEST='{"schemaVersion":2,"config":{"size":100},"layers":[{"size":200},{"size":300}]}'

# ---------------------------------------------------------------------------
# setup / teardown
# ---------------------------------------------------------------------------

setup() {
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"

    # Fresh temp dir for each test.
    WORK_DIR="$(mktemp -d)"

    # Per-URL-class call counter file.
    CALLS="${WORK_DIR}/calls"
    touch "$CALLS"
    export CALLS

    # Per-arch manifest bodies (keyed by digest suffix for the shim).
    export _OCI_INDEX _PER_ARCH_MANIFEST

    # Wire up the PATH shim directory.
    mkdir -p "${WORK_DIR}/bin"
    _install_shims

    export PATH="${WORK_DIR}/bin:$PATH"

    # Isolated cache dir for each test.
    export GHCR_CACHE_DIR="${WORK_DIR}/cache"

    # gh must fail fast so ghcr_get_token falls through to anonymous path.
    # The anonymous token path issues a curl call to */token*, which the shim
    # handles.  We also provide a gh shim for belt-and-suspenders.
}

teardown() {
    rm -rf "$WORK_DIR"
}

# ---------------------------------------------------------------------------
# Shim installer
# ---------------------------------------------------------------------------

_install_shims() {
    # ---- curl shim ----
    cat > "${WORK_DIR}/bin/curl" << 'CURL_SHIM'
#!/usr/bin/env bash
# Classify the request URL, append to $CALLS, return canned body.
URL="${!#}"   # last argument

if [[ "$URL" == *"/token"* ]]; then
    echo "TOKEN" >> "$CALLS"
    echo '{"token":"x"}'
    exit 0
fi

if [[ "$URL" == *"/manifests/sha256:"* ]]; then
    echo "PERARCH" >> "$CALLS"
    # -D - path: if -D is present output fake headers then body.
    if printf '%s\n' "$@" | grep -qx -- '-D'; then
        printf 'HTTP/2 200\r\nDocker-Content-Digest: sha256:perarch\r\n\r\n'
    fi
    echo "$_PER_ARCH_MANIFEST"
    exit 0
fi

if [[ "$URL" == *"/manifests/"* ]]; then
    echo "INDEX" >> "$CALLS"
    # -D - path: output headers + body together.
    if printf '%s\n' "$@" | grep -qx -- '-D'; then
        printf 'HTTP/2 200\r\nDocker-Content-Digest: sha256:idx\r\n\r\n'
    fi
    echo "$_OCI_INDEX"
    exit 0
fi

# Unknown — fail loudly.
echo "UNKNOWN_URL: $URL" >&2
exit 1
CURL_SHIM
    chmod +x "${WORK_DIR}/bin/curl"

    # ---- gh shim: always fails so token falls to anonymous path ----
    cat > "${WORK_DIR}/bin/gh" << 'GH_SHIM'
#!/usr/bin/env bash
exit 1
GH_SHIM
    chmod +x "${WORK_DIR}/bin/gh"
}

# ---------------------------------------------------------------------------
# D2-test-1: cache_hit_no_refetch — the Observable Success proof
# ---------------------------------------------------------------------------

@test "per-arch manifest served from cache on 2nd call (no re-fetch)" {
    source "$REPO_ROOT/helpers/logging.sh" 2>/dev/null || true
    source "$REPO_ROOT/helpers/registry-utils.sh"

    # First call: fetches token + index + 2 per-arch manifests.
    out1=$(ghcr_get_manifest_sizes "oorabona/postgres" "18-alpine")
    st1=$?

    # Second call in same session: index served from cache,
    # per-arch manifests served from perarch/<key>.body files → PERARCH=2 total.
    out2=$(ghcr_get_manifest_sizes "oorabona/postgres" "18-alpine")
    st2=$?

    # Both calls must succeed.
    [ "$st1" -eq 0 ]
    [ "$st2" -eq 0 ]

    # Outputs must be byte-identical.
    [ "$out1" = "$out2" ]

    # Output must contain correct arch:size lines.
    echo "$out1" | grep -qx 'amd64:600'
    echo "$out1" | grep -qx 'arm64:600'

    # PROOF: only 2 PERARCH lines in the call log (first call only).
    # A value of 4 here means the cache was not used on the 2nd call.
    local perarch
    perarch=$(grep -c '^PERARCH' "$CALLS" || true)
    [ "$perarch" -eq 2 ]
}

# ---------------------------------------------------------------------------
# D2-test-2: poisoned per-arch body (.errors envelope) → return 1, no cache file
# ---------------------------------------------------------------------------

@test "poisoned per-arch body (.errors) returns 1 and writes no cache file" {
    # Override _PER_ARCH_MANIFEST to an .errors envelope.
    export _PER_ARCH_MANIFEST='{"errors":[{"code":"NAME_UNKNOWN","message":"poison"}]}'

    source "$REPO_ROOT/helpers/logging.sh" 2>/dev/null || true
    source "$REPO_ROOT/helpers/registry-utils.sh"

    run ghcr_get_manifest_sizes "oorabona/postgres" "18-alpine"

    # Must fail (return 1).
    [ "$status" -eq 1 ]

    # Zero stdout (all-or-nothing).
    [ -z "$output" ]

    # No perarch/*.body cache file must have been written.
    local count
    count=$(find "${GHCR_CACHE_DIR}/perarch" -name '*.body' 2>/dev/null | wc -l || echo 0)
    [ "$count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# D2-test-3: all-or-nothing — 1st arch valid, 2nd arch returns .errors → return 1 + zero stdout
# ---------------------------------------------------------------------------

@test "all-or-nothing: valid 1st arch + errored 2nd arch returns 1 with zero stdout" {
    # Override the curl shim: aaa digest returns good manifest, bbb returns .errors.
    cat > "${WORK_DIR}/bin/curl" << 'CURL_MIXED'
#!/usr/bin/env bash
URL="${!#}"

if [[ "$URL" == *"/token"* ]]; then
    echo "TOKEN" >> "$CALLS"
    echo '{"token":"x"}'
    exit 0
fi

if [[ "$URL" == *"/manifests/sha256:aaa"* ]]; then
    echo "PERARCH" >> "$CALLS"
    echo '{"schemaVersion":2,"config":{"size":100},"layers":[{"size":200},{"size":300}]}'
    exit 0
fi

if [[ "$URL" == *"/manifests/sha256:bbb"* ]]; then
    echo "PERARCH" >> "$CALLS"
    echo '{"errors":[{"code":"MANIFEST_UNKNOWN","message":"not found"}]}'
    exit 0
fi

if [[ "$URL" == *"/manifests/"* ]]; then
    echo "INDEX" >> "$CALLS"
    if printf '%s\n' "$@" | grep -qx -- '-D'; then
        printf 'HTTP/2 200\r\nDocker-Content-Digest: sha256:idx\r\n\r\n'
    fi
    echo "$_OCI_INDEX"
    exit 0
fi

echo "UNKNOWN_URL: $URL" >&2
exit 1
CURL_MIXED
    chmod +x "${WORK_DIR}/bin/curl"

    source "$REPO_ROOT/helpers/logging.sh" 2>/dev/null || true
    source "$REPO_ROOT/helpers/registry-utils.sh"

    run ghcr_get_manifest_sizes "oorabona/postgres" "18-alpine"

    # Must fail.
    [ "$status" -eq 1 ]

    # Zero stdout — no partial output emitted.
    [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# D2-test-4: single-manifest image (no .manifests) — still emits amd64:<size>
#            and writes no perarch/*.body file (no per-arch loop executed)
# ---------------------------------------------------------------------------

@test "single-manifest image emits amd64:size and writes no per-arch cache file" {
    # Override the curl shim: index endpoint returns a single (non-list) manifest.
    local single_manifest='{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"size":50},"layers":[{"size":150}]}'
    export _SINGLE_MANIFEST="$single_manifest"

    cat > "${WORK_DIR}/bin/curl" << 'CURL_SINGLE'
#!/usr/bin/env bash
URL="${!#}"

if [[ "$URL" == *"/token"* ]]; then
    echo "TOKEN" >> "$CALLS"
    echo '{"token":"x"}'
    exit 0
fi

if [[ "$URL" == *"/manifests/"* ]]; then
    echo "INDEX" >> "$CALLS"
    if printf '%s\n' "$@" | grep -qx -- '-D'; then
        printf 'HTTP/2 200\r\nDocker-Content-Digest: sha256:single\r\n\r\n'
    fi
    echo "$_SINGLE_MANIFEST"
    exit 0
fi

echo "UNKNOWN_URL: $URL" >&2
exit 1
CURL_SINGLE
    chmod +x "${WORK_DIR}/bin/curl"

    source "$REPO_ROOT/helpers/logging.sh" 2>/dev/null || true
    source "$REPO_ROOT/helpers/registry-utils.sh"

    run ghcr_get_manifest_sizes "oorabona/postgres" "18-alpine-single"

    [ "$status" -eq 0 ]
    echo "$output" | grep -qx 'amd64:200'

    # No per-arch fetch should have occurred.
    local perarch
    perarch=$(grep -c '^PERARCH' "$CALLS" || true)
    [ "$perarch" -eq 0 ]

    # No perarch/*.body file written (no per-arch loop).
    local count
    count=$(find "${GHCR_CACHE_DIR}/perarch" -name '*.body' 2>/dev/null | wc -l || echo 0)
    [ "$count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# D2-test-5: atomic-write correctness — cache bodies in perarch/ subdir,
#            no leftover .tmp.* files after successful write
# ---------------------------------------------------------------------------

@test "cache-miss write: bodies in perarch/ subdir, no .tmp leftover" {
    source "$REPO_ROOT/helpers/logging.sh" 2>/dev/null || true
    source "$REPO_ROOT/helpers/registry-utils.sh"

    # Single call: populates 2 perarch/*.body files (one per arch).
    run ghcr_get_manifest_sizes "oorabona/postgres" "18-alpine"
    [ "$status" -eq 0 ]

    # Exactly 2 final cache files written under perarch/ (amd64 + arm64 digests).
    local body_count
    body_count=$(find "${GHCR_CACHE_DIR}/perarch" -name '*.body' 2>/dev/null | wc -l || echo 0)
    [ "$body_count" -eq 2 ]

    # No flat idx-perarch-* files in the cache root (old naming scheme gone).
    local flat_count
    flat_count=$(find "${GHCR_CACHE_DIR}" -maxdepth 1 -name 'idx-perarch-*' 2>/dev/null | wc -l || echo 0)
    [ "$flat_count" -eq 0 ]

    # No .tmp.* leftovers anywhere (mktemp + mv completed; cleanup on failure covered).
    local tmp_count
    tmp_count=$(find "${GHCR_CACHE_DIR}/perarch" -name '.tmp.*' 2>/dev/null | wc -l || echo 0)
    [ "$tmp_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# D2-test-6 (FIX S): perarch/ subdir is disjoint from _ghcr_invalidate_index
#   — calling _ghcr_invalidate_index does NOT delete any file under perarch/
# ---------------------------------------------------------------------------

@test "namespace disjoint: _ghcr_invalidate_index does not delete perarch/ entries" {
    source "$REPO_ROOT/helpers/logging.sh" 2>/dev/null || true
    source "$REPO_ROOT/helpers/registry-utils.sh"

    # Populate the cache with a real call (writes idx-*.body + perarch/*.body).
    ghcr_get_manifest_sizes "oorabona/postgres" "18-alpine" >/dev/null
    local st=$?
    [ "$st" -eq 0 ]

    # Confirm 2 perarch bodies exist before invalidation.
    local before
    before=$(find "${GHCR_CACHE_DIR}/perarch" -name '*.body' 2>/dev/null | wc -l || echo 0)
    [ "$before" -eq 2 ]

    # Invalidate the index entry for the same image/tag.
    # _ghcr_invalidate_index removes only flat idx-${k}.body / idx-${k}.hdrs files.
    _ghcr_invalidate_index "oorabona/postgres" "18-alpine"

    # Per-arch bodies must be untouched.
    local after
    after=$(find "${GHCR_CACHE_DIR}/perarch" -name '*.body' 2>/dev/null | wc -l || echo 0)
    [ "$after" -eq 2 ]

    # Confirm the index body file itself is gone (invalidation worked).
    local idx_key
    idx_key="$(_ghcr_keyfile "oorabona/postgres:18-alpine")"
    [ ! -f "${GHCR_CACHE_DIR}/idx-${idx_key}.body" ]
}
