#!/usr/bin/env bats

# Tests for the per-arch manifest file-cache tier in ghcr_get_manifest_sizes
# and the content-digest verification layer in helpers/registry-utils.sh.
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

# Per-arch manifest bodies with known sha256 digests (no trailing newline
# since the code captures via $() and writes via printf '%s').
#   amd64: config 100 + layers 200+300 = total 600
#     sha256: c3dcb30ac02018335b76e7619cbd56c644122cd6357ba6ad92515e7a6f74ef57
#   arm64: config 150 + layers 250+350 = total 750
#     sha256: 13fe4dc6162b562798c5b0b086a021e4169a4f546ff9159de84a5a7837d23439
_PER_ARCH_MANIFEST_AMD64='{"schemaVersion":2,"config":{"size":100},"layers":[{"size":200},{"size":300}]}'
_PER_ARCH_MANIFEST_ARM64='{"schemaVersion":2,"config":{"size":150},"layers":[{"size":250},{"size":350}]}'

# Keep _PER_ARCH_MANIFEST as the amd64 body for backward compat with existing tests
# that override it to inject a poison body.
_PER_ARCH_MANIFEST="$_PER_ARCH_MANIFEST_AMD64"

# OCI index body: two arches with 64-char hex digests matching the sha256 of
# each per-arch manifest body above (required by content-digest verification).
# NOTE: the per-arch loop splits on ':' so the digest is read as
#   arch=amd64, digest_prefix=sha256, digest_hash=c3dcb...
_OCI_INDEX='{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "manifests": [
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:c3dcb30ac02018335b76e7619cbd56c644122cd6357ba6ad92515e7a6f74ef57",
      "platform": { "architecture": "amd64", "os": "linux" }
    },
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:13fe4dc6162b562798c5b0b086a021e4169a4f546ff9159de84a5a7837d23439",
      "platform": { "architecture": "arm64", "os": "linux" }
    }
  ]
}'

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
    export _OCI_INDEX _PER_ARCH_MANIFEST _PER_ARCH_MANIFEST_AMD64 _PER_ARCH_MANIFEST_ARM64

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
    # Handles three URL classes:
    #   TOKEN   — /token (auth, writes JSON to stdout)
    #   INDEX   — /manifests/<tag> (index fetch; may use -D <hfile> -o <bfile>)
    #   PERARCH — /manifests/sha256:<hex> (per-arch; always stdout, no -D/-o)
    #
    # The INDEX endpoint is now called with "-D <hdrs_file> -o <body_file>" by
    # _ghcr_fetch_index. The shim parses these flags and writes to the supplied
    # files, falling back to stdout if they are absent (for callers that don't
    # use the file-based form).
    cat > "${WORK_DIR}/bin/curl" << 'CURL_SHIM'
#!/usr/bin/env bash
# Classify the request URL, append to $CALLS, return canned body.
URL="${!#}"   # last argument

# Parse -D <file> and -o <file> from the argument list.
DFILE="" OFILE=""
_prev=""
for _arg in "$@"; do
    if [[ "$_prev" == "-D" ]]; then DFILE="$_arg"; fi
    if [[ "$_prev" == "-o" ]]; then OFILE="$_arg"; fi
    _prev="$_arg"
done

# Helper: write headers to DFILE (or stdout) and body to OFILE (or stdout).
_write_response() {
    local _hdrs="$1" _body="$2"
    if [[ -n "$DFILE" ]]; then
        printf '%s' "$_hdrs" > "$DFILE"
    fi
    if [[ -n "$OFILE" ]]; then
        printf '%s' "$_body" > "$OFILE"
    else
        printf '%s' "$_hdrs"
        printf '%s' "$_body"
    fi
}

if [[ "$URL" == *"/token"* ]]; then
    echo "TOKEN" >> "$CALLS"
    echo '{"token":"x"}'
    exit 0
fi

if [[ "$URL" == *"/manifests/sha256:"* ]]; then
    echo "PERARCH" >> "$CALLS"
    # Per-arch is still captured via $() — just write to stdout.
    # Return per-arch body matching the digest in the URL.
    if [[ "$URL" == *"/manifests/sha256:c3d"* ]]; then
        echo "$_PER_ARCH_MANIFEST_AMD64"
    elif [[ "$URL" == *"/manifests/sha256:13f"* ]]; then
        echo "$_PER_ARCH_MANIFEST_ARM64"
    else
        # Fallback: return default per-arch manifest (for tests that override _OCI_INDEX).
        echo "$_PER_ARCH_MANIFEST"
    fi
    exit 0
fi

if [[ "$URL" == *"/manifests/"* ]]; then
    echo "INDEX" >> "$CALLS"
    # Index fetch now uses -D <hfile> -o <bfile>; the shim must write to those
    # files when present. Docker-Content-Digest uses a short non-64-char value
    # so that content-digest verification is skipped in the default shim (tests
    # that need real sha256 verification install a custom shim).
    _hdrs="$(printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: sha256:idx\r\n\r\n')"
    _body="$(printf '%s\n' "$_OCI_INDEX")"
    _write_response "$_hdrs" "$_body"
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
    echo "$out1" | grep -qx 'arm64:750'

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
    # Install a shim that returns a poison .errors envelope for all per-arch requests.
    local _POISON_BODY='{"errors":[{"code":"NAME_UNKNOWN","message":"poison"}]}'
    export _POISON_BODY
    cat > "${WORK_DIR}/bin/curl" << 'CURL_POISON'
#!/usr/bin/env bash
URL="${!#}"

DFILE="" OFILE=""
_prev=""
for _arg in "$@"; do
    if [[ "$_prev" == "-D" ]]; then DFILE="$_arg"; fi
    if [[ "$_prev" == "-o" ]]; then OFILE="$_arg"; fi
    _prev="$_arg"
done

if [[ "$URL" == *"/token"* ]]; then
    echo '{"token":"x"}'; exit 0
fi
if [[ "$URL" == *"/manifests/sha256:"* ]]; then
    echo "$_POISON_BODY"; exit 0
fi
if [[ "$URL" == *"/manifests/"* ]]; then
    _hdrs="$(printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: sha256:idx\r\n\r\n')"
    _body="$(printf '%s\n' "$_OCI_INDEX")"
    if [[ -n "$DFILE" ]]; then printf '%s' "$_hdrs" > "$DFILE"; fi
    if [[ -n "$OFILE" ]]; then printf '%s' "$_body" > "$OFILE"; else printf '%s%s' "$_hdrs" "$_body"; fi
    exit 0
fi
exit 1
CURL_POISON
    chmod +x "${WORK_DIR}/bin/curl"

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
    # Override the curl shim: amd64 digest (c3d...) returns good manifest,
    # arm64 digest (13f...) returns .errors.
    cat > "${WORK_DIR}/bin/curl" << 'CURL_MIXED'
#!/usr/bin/env bash
URL="${!#}"

DFILE="" OFILE=""
_prev=""
for _arg in "$@"; do
    if [[ "$_prev" == "-D" ]]; then DFILE="$_arg"; fi
    if [[ "$_prev" == "-o" ]]; then OFILE="$_arg"; fi
    _prev="$_arg"
done

if [[ "$URL" == *"/token"* ]]; then
    echo "TOKEN" >> "$CALLS"
    echo '{"token":"x"}'
    exit 0
fi

if [[ "$URL" == *"/manifests/sha256:c3d"* ]]; then
    echo "PERARCH" >> "$CALLS"
    echo '{"schemaVersion":2,"config":{"size":100},"layers":[{"size":200},{"size":300}]}'
    exit 0
fi

if [[ "$URL" == *"/manifests/sha256:13f"* ]]; then
    echo "PERARCH" >> "$CALLS"
    echo '{"errors":[{"code":"MANIFEST_UNKNOWN","message":"not found"}]}'
    exit 0
fi

if [[ "$URL" == *"/manifests/"* ]]; then
    echo "INDEX" >> "$CALLS"
    _hdrs="$(printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: sha256:idx\r\n\r\n')"
    _body="$(printf '%s\n' "$_OCI_INDEX")"
    if [[ -n "$DFILE" ]]; then printf '%s' "$_hdrs" > "$DFILE"; fi
    if [[ -n "$OFILE" ]]; then printf '%s' "$_body" > "$OFILE"; else printf '%s%s' "$_hdrs" "$_body"; fi
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

DFILE="" OFILE=""
_prev=""
for _arg in "$@"; do
    if [[ "$_prev" == "-D" ]]; then DFILE="$_arg"; fi
    if [[ "$_prev" == "-o" ]]; then OFILE="$_arg"; fi
    _prev="$_arg"
done

if [[ "$URL" == *"/token"* ]]; then
    echo "TOKEN" >> "$CALLS"
    echo '{"token":"x"}'
    exit 0
fi

if [[ "$URL" == *"/manifests/"* ]]; then
    echo "INDEX" >> "$CALLS"
    _hdrs="$(printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: sha256:single\r\n\r\n')"
    _body="$(printf '%s\n' "$_SINGLE_MANIFEST")"
    if [[ -n "$DFILE" ]]; then printf '%s' "$_hdrs" > "$DFILE"; fi
    if [[ -n "$OFILE" ]]; then printf '%s' "$_body" > "$OFILE"; else printf '%s%s' "$_hdrs" "$_body"; fi
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

# ---------------------------------------------------------------------------
# D2-test-7: _ghcr_verify_content_digest — matching sha256 returns 0
# ---------------------------------------------------------------------------

@test "content-digest verify: matching sha256 admits cache" {
    source "$REPO_ROOT/helpers/logging.sh" 2>/dev/null || true
    source "$REPO_ROOT/helpers/registry-utils.sh"

    _ghcr_ensure_cachedir
    local f="${GHCR_CACHE_DIR}/test-verify.tmp"
    printf '%s' 'hello world' > "$f"
    # sha256('hello world') = b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9
    run _ghcr_verify_content_digest "$f" "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# D2-test-8: _ghcr_verify_content_digest — mismatched sha256 returns 1
# ---------------------------------------------------------------------------

@test "content-digest verify: mismatched sha256 rejects" {
    source "$REPO_ROOT/helpers/logging.sh" 2>/dev/null || true
    source "$REPO_ROOT/helpers/registry-utils.sh"

    _ghcr_ensure_cachedir
    local f="${GHCR_CACHE_DIR}/test-verify-bad.tmp"
    printf '%s' 'hello world' > "$f"
    # Pass wrong hex — must return 1.
    run _ghcr_verify_content_digest "$f" "0000000000000000000000000000000000000000000000000000000000000000"
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# D2-test-9: _ghcr_verify_content_digest — missing file returns 1
# ---------------------------------------------------------------------------

@test "content-digest verify: missing file returns 1" {
    source "$REPO_ROOT/helpers/logging.sh" 2>/dev/null || true
    source "$REPO_ROOT/helpers/registry-utils.sh"

    run _ghcr_verify_content_digest "/nonexistent/path/file.tmp" "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# D2-test-10: _ghcr_verify_content_digest — trailing-newline-safe
# Verifies that sha256sum operates on exact file bytes (no stripping).
# ---------------------------------------------------------------------------

@test "content-digest verify: trailing-newline-safe (file bytes are exact)" {
    source "$REPO_ROOT/helpers/logging.sh" 2>/dev/null || true
    source "$REPO_ROOT/helpers/registry-utils.sh"

    _ghcr_ensure_cachedir

    # Write bytes WITH trailing newline and verify sha256 of the full content.
    local f="${GHCR_CACHE_DIR}/test-newline.tmp"
    printf '%s\n' 'hello world' > "$f"
    # sha256 of "hello world\n" (12 bytes):
    local expected
    expected=$(sha256sum -- "$f" | cut -d' ' -f1)
    run _ghcr_verify_content_digest "$f" "$expected"
    [ "$status" -eq 0 ]

    # Verify that the no-newline hash does NOT match (they are different files).
    run _ghcr_verify_content_digest "$f" "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# D2-test-11: per-arch cache — tampered body (sha256 mismatch) is rejected
# The OCI index carries the real digest; shim returns a different body.
# ---------------------------------------------------------------------------

@test "per-arch cache: tampered body rejected (content-digest mismatch)" {
    # The OCI index digest for amd64 is the sha256 of _PER_ARCH_MANIFEST_AMD64.
    # Inject a shim that returns a DIFFERENT body for that digest → mismatch → reject.
    local _TAMPERED='{"schemaVersion":2,"config":{"size":99},"layers":[{"size":1}]}'
    export _TAMPERED

    cat > "${WORK_DIR}/bin/curl" << 'CURL_TAMPER'
#!/usr/bin/env bash
URL="${!#}"

DFILE="" OFILE=""
_prev=""
for _arg in "$@"; do
    if [[ "$_prev" == "-D" ]]; then DFILE="$_arg"; fi
    if [[ "$_prev" == "-o" ]]; then OFILE="$_arg"; fi
    _prev="$_arg"
done

if [[ "$URL" == *"/token"* ]]; then
    echo '{"token":"x"}'; exit 0
fi
if [[ "$URL" == *"/manifests/sha256:"* ]]; then
    # Return tampered body — sha256 will NOT match the digest in the OCI index.
    echo "$_TAMPERED"; exit 0
fi
if [[ "$URL" == *"/manifests/"* ]]; then
    _hdrs="$(printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: sha256:idx\r\n\r\n')"
    _body="$(printf '%s\n' "$_OCI_INDEX")"
    if [[ -n "$DFILE" ]]; then printf '%s' "$_hdrs" > "$DFILE"; fi
    if [[ -n "$OFILE" ]]; then printf '%s' "$_body" > "$OFILE"; else printf '%s%s' "$_hdrs" "$_body"; fi
    exit 0
fi
exit 1
CURL_TAMPER
    chmod +x "${WORK_DIR}/bin/curl"

    source "$REPO_ROOT/helpers/logging.sh" 2>/dev/null || true
    source "$REPO_ROOT/helpers/registry-utils.sh"

    run ghcr_get_manifest_sizes "oorabona/postgres" "18-alpine"

    # Must fail: tampered per-arch body rejected → function returns 1.
    [ "$status" -eq 1 ]

    # No per-arch cache file written for the tampered body.
    local count
    count=$(find "${GHCR_CACHE_DIR}/perarch" -name '*.body' 2>/dev/null | wc -l || echo 0)
    [ "$count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# D2-test-12: index cache — Docker-Content-Digest mismatch → body not cached
# ---------------------------------------------------------------------------

@test "index cache: Docker-Content-Digest mismatch body not cached" {
    # Shim returns an index body with a Docker-Content-Digest header that does
    # NOT match the sha256 of the body bytes → cache admission blocked.
    cat > "${WORK_DIR}/bin/curl" << 'CURL_IDX_BAD'
#!/usr/bin/env bash
URL="${!#}"

DFILE="" OFILE=""
_prev=""
for _arg in "$@"; do
    if [[ "$_prev" == "-D" ]]; then DFILE="$_arg"; fi
    if [[ "$_prev" == "-o" ]]; then OFILE="$_arg"; fi
    _prev="$_arg"
done

if [[ "$URL" == *"/token"* ]]; then
    echo '{"token":"x"}'; exit 0
fi
if [[ "$URL" == *"/manifests/"* ]]; then
    # Use a real 64-char hex but one that does NOT match the body sha256.
    _hdrs="$(printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: sha256:0000000000000000000000000000000000000000000000000000000000000000\r\n\r\n')"
    _body="$(printf '%s\n' "$_OCI_INDEX")"
    if [[ -n "$DFILE" ]]; then printf '%s' "$_hdrs" > "$DFILE"; fi
    if [[ -n "$OFILE" ]]; then printf '%s' "$_body" > "$OFILE"; else printf '%s%s' "$_hdrs" "$_body"; fi
    exit 0
fi
exit 1
CURL_IDX_BAD
    chmod +x "${WORK_DIR}/bin/curl"

    source "$REPO_ROOT/helpers/logging.sh" 2>/dev/null || true
    source "$REPO_ROOT/helpers/registry-utils.sh"

    run _ghcr_fetch_index "oorabona/postgres" "18-alpine" "token"

    # Mismatch: function returns 1 (body not admitted to cache).
    [ "$status" -eq 1 ]

    # No idx-*.body file written.
    local idx_key
    idx_key="$(_ghcr_keyfile "oorabona/postgres:18-alpine")"
    [ ! -f "${GHCR_CACHE_DIR}/idx-${idx_key}.body" ]
}

# ---------------------------------------------------------------------------
# D2-test-13: cache-dir warning emitted exactly once per run
# ---------------------------------------------------------------------------

@test "cache-dir warning emitted once when cache dir cannot be created" {
    source "$REPO_ROOT/helpers/logging.sh" 2>/dev/null || true
    source "$REPO_ROOT/helpers/registry-utils.sh"

    # Use an unwritable path as cache dir.
    export GHCR_CACHE_DIR="/proc/1/cannot-create-this-dir-$$"
    unset _GHCR_CACHE_DIR_WARNED

    # Degraded mode: function must return 0 (non-fatal) even when dir creation
    # fails.  Warning must appear exactly once across N calls (sentinel).
    run bash -c '
        source "'"$REPO_ROOT"'/helpers/logging.sh" 2>/dev/null || true
        source "'"$REPO_ROOT"'/helpers/registry-utils.sh"
        export GHCR_CACHE_DIR="/proc/1/cannot-create-this-dir-$$"
        unset _GHCR_CACHE_DIR_WARNED
        _ghcr_ensure_cachedir
        _ghcr_ensure_cachedir
        _ghcr_ensure_cachedir
    '
    # All three calls must return 0 (degraded mode is non-fatal).
    [ "$status" -eq 0 ]

    # Warning must appear in stderr exactly once (sentinel suppresses repeats).
    local warning_count
    warning_count=$(echo "$output" | grep -c '::warning::' || true)
    [ "$warning_count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# D2-test-14: graceful degrade — unwritable cache dir must not prevent
# network fetches in _ghcr_fetch_index
# ---------------------------------------------------------------------------

@test "unwritable cache dir: _ghcr_ensure_cachedir is non-fatal (rc=0, warning once)" {
    # Direct test of the fix: _ghcr_ensure_cachedir must ALWAYS return 0.
    # When the cache dir cannot be created it emits a single ::warning:: and
    # returns 0 so that callers (running under set -e) do not abort.
    # This is the regression guard for the gate r1 finding.
    source "$REPO_ROOT/helpers/logging.sh" 2>/dev/null || true
    source "$REPO_ROOT/helpers/registry-utils.sh"

    run bash -c '
        source "'"$REPO_ROOT"'/helpers/logging.sh" 2>/dev/null || true
        source "'"$REPO_ROOT"'/helpers/registry-utils.sh"
        export GHCR_CACHE_DIR="/proc/1/cannot-create-this-dir-$$"
        unset _GHCR_CACHE_DIR_WARNED
        # Simulate a caller using set -e: if _ghcr_ensure_cachedir returned 1
        # the subshell would exit with rc=1 here.
        set -e
        _ghcr_ensure_cachedir
        _ghcr_ensure_cachedir
        echo "REACHED_AFTER_BOTH_CALLS"
    '
    # Must exit 0: degraded mode is non-fatal even under set -e.
    [ "$status" -eq 0 ]

    # Must have printed the continuation sentinel (not aborted early).
    echo "$output" | grep -q 'REACHED_AFTER_BOTH_CALLS'

    # Warning must appear exactly once (not suppressed, not repeated).
    local warning_count
    warning_count=$(echo "$output" | grep -c '::warning::' || true)
    [ "$warning_count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# D2-test-15 (r2): degraded _ghcr_fetch_index — unwritable cache dir must not
# prevent network fetch from returning data via out-vars.
#
# Root cause (#454 r2): mktemp "${GHCR_CACHE_DIR}/..." fails immediately when
# the cache dir is unwritable, so _ghcr_fetch_index returned 1 BEFORE issuing
# the curl call.  _ghcr_temp_file now falls back to system TMPDIR so the
# fetch completes regardless of cache dir writability.
# ---------------------------------------------------------------------------

@test "degraded _ghcr_fetch_index: returns 0 and populates out-vars when cache dir unwritable" {
    # Run in a subshell to isolate out-var mutation and TMPDIR state.
    run bash -c '
        source "'"$REPO_ROOT"'/helpers/logging.sh" 2>/dev/null || true
        source "'"$REPO_ROOT"'/helpers/registry-utils.sh"

        # Override curl shim is inherited via PATH from setup.
        export GHCR_CACHE_DIR="/proc/1/cannot-create-this-dir-$$"
        unset _GHCR_CACHE_DIR_WARNED

        # Invoke the function under test.
        _ghcr_fetch_index "oorabona/postgres" "18-alpine" "token"
        rc=$?

        # Emit markers readable by the test harness.
        echo "RC=$rc"
        if [[ -n "$_GHCR_IDX_BODY" ]]; then
            echo "BODY_POPULATED"
        else
            echo "BODY_EMPTY"
        fi
        if [[ -n "$_GHCR_IDX_HDRS" ]]; then
            echo "HDRS_POPULATED"
        else
            echo "HDRS_EMPTY"
        fi
    '
    # Must succeed despite unwritable cache dir.
    [ "$status" -eq 0 ]

    # Out-vars must carry the fetched response data.
    echo "$output" | grep -q 'RC=0'
    echo "$output" | grep -q 'BODY_POPULATED'
    echo "$output" | grep -q 'HDRS_POPULATED'

    # Cache-dir warning must have been emitted (sentinel for degraded mode).
    echo "$output" | grep -q '::warning::'
}

# ---------------------------------------------------------------------------
# D2-test-16 (r2): degraded ghcr_get_manifest_sizes — unwritable cache dir
# must not prevent per-arch size computation from returning results.
# ---------------------------------------------------------------------------

@test "degraded ghcr_get_manifest_sizes: returns sizes when cache dir unwritable" {
    run bash -c '
        source "'"$REPO_ROOT"'/helpers/logging.sh" 2>/dev/null || true
        source "'"$REPO_ROOT"'/helpers/registry-utils.sh"

        export GHCR_CACHE_DIR="/proc/1/cannot-create-this-dir-$$"
        unset _GHCR_CACHE_DIR_WARNED

        out=$(ghcr_get_manifest_sizes "oorabona/postgres" "18-alpine")
        rc=$?
        echo "RC=$rc"
        printf "%s\n" "$out"
    '
    # Must succeed and emit correct sizes for both arches.
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'RC=0'
    echo "$output" | grep -qx 'amd64:600'
    echo "$output" | grep -qx 'arm64:750'
}

# ---------------------------------------------------------------------------
# D2-test-17 (r2): fully unwritable (cache dir + system TMPDIR) — _ghcr_temp_file
# returns 1 so _ghcr_fetch_index hard-fails with rc=1.  No writable temp
# location = no safe way to capture curl output; fatal is the correct outcome.
# ---------------------------------------------------------------------------

@test "fully unwritable (cache + TMPDIR): _ghcr_fetch_index returns 1 (fatal as expected)" {
    run bash -c '
        source "'"$REPO_ROOT"'/helpers/logging.sh" 2>/dev/null || true
        source "'"$REPO_ROOT"'/helpers/registry-utils.sh"

        export GHCR_CACHE_DIR="/proc/1/cannot-create-this-dir-$$"
        # TMPDIR=/proc/1 makes mktemp -t fail (directory is unwritable).
        export TMPDIR="/proc/1"
        unset _GHCR_CACHE_DIR_WARNED

        _ghcr_fetch_index "oorabona/postgres" "18-alpine" "token"
        echo "RC=$?"
    '
    # Hard fail expected — no writable temp location available anywhere.
    [ "$status" -eq 0 ]  # the bash -c subshell itself exits 0
    echo "$output" | grep -q 'RC=1'
}
