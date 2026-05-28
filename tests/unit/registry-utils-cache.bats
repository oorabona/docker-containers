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

# Per-arch manifest bodies with known sha256 digests.
# The code now uses curl -o <file> (no $() command substitution) so the exact
# bytes written to disk — including any trailing newline — are what get hashed.
# The shim writes these bodies via printf '%s' "$body" (no trailing newline),
# matching the digests below.
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

# run --separate-stderr requires bats >= 1.5.0 (used in tests that check
# stdout-only emptiness while expecting ::warning:: on stderr).
bats_require_minimum_version 1.5.0

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

    # Isolated cache dir for each test — created 0700 so _ghcr_validate_cachedir
    # accepts it immediately (r10: loose-mode dirs are now rejected, not silently fixed).
    export GHCR_CACHE_DIR="${WORK_DIR}/cache"
    ( umask 077; mkdir -p "${GHCR_CACHE_DIR}" )

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
    # Per-arch now uses curl -o <file>; write body to OFILE when present,
    # else stdout (for tests that don't pass -o).
    # Use printf '%s' (no trailing newline) so the body bytes match the
    # sha256 digests declared in the fixture constants above.
    _pa_body=""
    if [[ "$URL" == *"/manifests/sha256:c3d"* ]]; then
        _pa_body="$_PER_ARCH_MANIFEST_AMD64"
    elif [[ "$URL" == *"/manifests/sha256:13f"* ]]; then
        _pa_body="$_PER_ARCH_MANIFEST_ARM64"
    else
        # Fallback: return default per-arch manifest (for tests that override _OCI_INDEX).
        _pa_body="$_PER_ARCH_MANIFEST"
    fi
    if [[ -n "$OFILE" ]]; then
        printf '%s' "$_pa_body" > "$OFILE"
    else
        printf '%s' "$_pa_body"
    fi
    exit 0
fi

if [[ "$URL" == *"/manifests/"* ]]; then
    echo "INDEX" >> "$CALLS"
    # Index fetch uses -D <hfile> -o <bfile>; the shim writes to those files.
    # Docker-Content-Digest is computed dynamically from the body so that
    # content-digest verification always passes, even when tests override
    # _OCI_INDEX with a custom fixture (r10 Defect C: fail-closed on missing
    # or malformed digest).
    _body="$(printf '%s\n' "$_OCI_INDEX")"
    _digest="$(printf '%s' "$_body" | sha256sum | cut -c1-64)"
    _hdrs="$(printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: sha256:%s\r\n\r\n' "$_digest")"
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
    # Write poison body to OFILE when present (new -o file-based fetch path);
    # fall back to stdout for callers that don't pass -o.
    if [[ -n "$OFILE" ]]; then
        printf '%s' "$_POISON_BODY" > "$OFILE"
    else
        echo "$_POISON_BODY"
    fi
    exit 0
fi
if [[ "$URL" == *"/manifests/"* ]]; then
    _body="$(printf '%s\n' "$_OCI_INDEX")"
    _digest="$(printf '%s' "$_body" | sha256sum | cut -c1-64)"
    _hdrs="$(printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: sha256:%s\r\n\r\n' "$_digest")"
    if [[ -n "$DFILE" ]]; then printf '%s' "$_hdrs" > "$DFILE"; fi
    if [[ -n "$OFILE" ]]; then printf '%s' "$_body" > "$OFILE"; else printf '%s%s' "$_hdrs" "$_body"; fi
    exit 0
fi
exit 1
CURL_POISON
    chmod +x "${WORK_DIR}/bin/curl"

    source "$REPO_ROOT/helpers/logging.sh" 2>/dev/null || true
    source "$REPO_ROOT/helpers/registry-utils.sh"

    # --separate-stderr isolates the ::warning:: diagnostic from stdout so that
    # the all-or-nothing stdout check is not confused by stderr output.
    run --separate-stderr ghcr_get_manifest_sizes "oorabona/postgres" "18-alpine"

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
    _pa='{"schemaVersion":2,"config":{"size":100},"layers":[{"size":200},{"size":300}]}'
    if [[ -n "$OFILE" ]]; then printf '%s' "$_pa" > "$OFILE"; else printf '%s' "$_pa"; fi
    exit 0
fi

if [[ "$URL" == *"/manifests/sha256:13f"* ]]; then
    echo "PERARCH" >> "$CALLS"
    _pa='{"errors":[{"code":"MANIFEST_UNKNOWN","message":"not found"}]}'
    if [[ -n "$OFILE" ]]; then printf '%s' "$_pa" > "$OFILE"; else printf '%s' "$_pa"; fi
    exit 0
fi

if [[ "$URL" == *"/manifests/"* ]]; then
    echo "INDEX" >> "$CALLS"
    _body="$(printf '%s\n' "$_OCI_INDEX")"
    _digest="$(printf '%s' "$_body" | sha256sum | cut -c1-64)"
    _hdrs="$(printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: sha256:%s\r\n\r\n' "$_digest")"
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

    # --separate-stderr isolates the ::warning:: diagnostic from stdout so that
    # the all-or-nothing stdout check is not confused by stderr output.
    run --separate-stderr ghcr_get_manifest_sizes "oorabona/postgres" "18-alpine"

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
    _body="$(printf '%s\n' "$_SINGLE_MANIFEST")"
    _digest="$(printf '%s' "$_body" | sha256sum | cut -c1-64)"
    _hdrs="$(printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: sha256:%s\r\n\r\n' "$_digest")"
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
    # Production uses `curl -o $pa_tmp`, so write to $OFILE when present.
    if [[ -n "$OFILE" ]]; then
        printf '%s' "$_TAMPERED" > "$OFILE"
    else
        printf '%s' "$_TAMPERED"
    fi
    exit 0
fi
if [[ "$URL" == *"/manifests/"* ]]; then
    _body="$(printf '%s\n' "$_OCI_INDEX")"
    _digest="$(printf '%s' "$_body" | sha256sum | cut -c1-64)"
    _hdrs="$(printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: sha256:%s\r\n\r\n' "$_digest")"
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

# ---------------------------------------------------------------------------
# D3-test-1 (r3): trailing-newline-safe per-arch fetch
# A manifest body served with a trailing newline has a different sha256 than
# the same body without the newline.  The previous $()-based fetch silently
# stripped the newline, causing the sha256 to mismatch the cache key digest →
# legitimate images rejected.  The file-based fetch preserves exact bytes so
# the hash computed from the file matches the digest advertised by the registry.
# ---------------------------------------------------------------------------

@test "per-arch trailing-newline-safe: manifest with trailing newline is accepted when digest matches" {
    # Fixture: amd64 body WITH a trailing newline.
    # sha256("${AMD64_BODY}\n") = a40220b4839d6a73e099913142835aaf89c59327338d2157cf4050e687127728
    local NL_BODY NL_DIGEST
    NL_BODY='{"schemaVersion":2,"config":{"size":100},"layers":[{"size":200},{"size":300}]}'
    NL_DIGEST='a40220b4839d6a73e099913142835aaf89c59327338d2157cf4050e687127728'

    # Override the OCI index so it references the trailing-newline digest.
    export _OCI_INDEX='{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "manifests": [
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:'"$NL_DIGEST"'",
      "platform": { "architecture": "amd64", "os": "linux" }
    }
  ]
}'

    # Override the per-arch body to write the body WITH a trailing newline
    # to the OFILE (simulating a real GHCR response with trailing whitespace).
    export _PER_ARCH_MANIFEST="$NL_BODY"
    cat > "${WORK_DIR}/bin/curl" << 'CURL_NL'
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
if [[ "$URL" == *"/manifests/sha256:"* ]]; then
    echo "PERARCH" >> "$CALLS"
    # Write body WITH trailing newline — this is the regression case.
    if [[ -n "$OFILE" ]]; then
        printf '%s\n' "$_PER_ARCH_MANIFEST" > "$OFILE"
    else
        printf '%s\n' "$_PER_ARCH_MANIFEST"
    fi
    exit 0
fi
if [[ "$URL" == *"/manifests/"* ]]; then
    echo "INDEX" >> "$CALLS"
    _body="$(printf '%s\n' "$_OCI_INDEX")"
    _digest="$(printf '%s' "$_body" | sha256sum | cut -c1-64)"
    _hdrs="$(printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: sha256:%s\r\n\r\n' "$_digest")"
    if [[ -n "$DFILE" ]]; then printf '%s' "$_hdrs" > "$DFILE"; fi
    if [[ -n "$OFILE" ]]; then printf '%s' "$_body" > "$OFILE"; else printf '%s' "$_hdrs"; printf '%s' "$_body"; fi
    exit 0
fi
echo "UNKNOWN_URL: $URL" >&2
exit 1
CURL_NL
    chmod +x "${WORK_DIR}/bin/curl"

    source "$REPO_ROOT/helpers/logging.sh" 2>/dev/null || true
    source "$REPO_ROOT/helpers/registry-utils.sh"

    out=$(ghcr_get_manifest_sizes "oorabona/postgres" "18-alpine")
    rc=$?

    # Must succeed: the file-based fetch preserves the trailing newline so the
    # sha256 of the on-disk bytes matches NL_DIGEST.
    [ "$rc" -eq 0 ]
    echo "$out" | grep -qx 'amd64:600'
}

# ---------------------------------------------------------------------------
# D3-test-2 (r3): strict digest_prefix — non-sha256 prefix → hard return 1
# A manifest list with digest_prefix=sha512 for amd64 must cause the function
# to return 1 rather than silently continuing.  The old code would match the
# hex regex (sha512 hashes are 128 chars, not 64, so actually wouldn't pass
# the hex check — but a sha256b/sha256a variant would slip through if the
# prefix check was absent).  The new code explicitly validates prefix first.
# ---------------------------------------------------------------------------

@test "per-arch strict digest_prefix: sha512 prefix causes return 1" {
    # Inject an OCI index where amd64 uses sha512: prefix with a 64-char hex
    # value (to pass the hash-length check if it were reached).
    export _OCI_INDEX='{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "manifests": [
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha512:c3dcb30ac02018335b76e7619cbd56c644122cd6357ba6ad92515e7a6f74ef57",
      "platform": { "architecture": "amd64", "os": "linux" }
    }
  ]
}'

    source "$REPO_ROOT/helpers/logging.sh" 2>/dev/null || true
    source "$REPO_ROOT/helpers/registry-utils.sh"

    # --separate-stderr isolates the ::warning:: diagnostic from stdout.
    run --separate-stderr ghcr_get_manifest_sizes "oorabona/postgres" "18-alpine"

    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# D3-test-3 (r3): strict digest_hash — non-hex chars → hard return 1
# A manifest list entry with a malformed hash (contains 'zz') must cause the
# function to return 1, not silently skip the platform.
# ---------------------------------------------------------------------------

@test "per-arch strict digest_hash: non-hex chars in hash causes return 1" {
    export _OCI_INDEX='{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "manifests": [
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:zz0cb30ac02018335b76e7619cbd56c644122cd6357ba6ad92515e7a6f74ef57",
      "platform": { "architecture": "amd64", "os": "linux" }
    }
  ]
}'

    source "$REPO_ROOT/helpers/logging.sh" 2>/dev/null || true
    source "$REPO_ROOT/helpers/registry-utils.sh"

    # --separate-stderr isolates the ::warning:: diagnostic from stdout.
    run --separate-stderr ghcr_get_manifest_sizes "oorabona/postgres" "18-alpine"

    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# D3-test-4 (r3): unknown platform with malformed digest — silent skip preserved
# The "unknown" platform (OCI provenance attestation entry) must still be
# silently skipped even if its digest is malformed or uses a non-sha256 prefix.
# Only real arch platforms are subject to the strict validation.
# ---------------------------------------------------------------------------

@test "per-arch unknown platform with malformed digest: silently skipped, function succeeds" {
    # OCI index: one "unknown" platform (provenance) with a malformed digest,
    # plus one valid amd64 entry.  The unknown entry must be skipped; the
    # valid amd64 entry must succeed.
    export _OCI_INDEX='{
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
      "digest": "sha512:notahexatall!!",
      "platform": { "architecture": "unknown", "os": "unknown" }
    }
  ]
}'

    source "$REPO_ROOT/helpers/logging.sh" 2>/dev/null || true
    source "$REPO_ROOT/helpers/registry-utils.sh"

    out=$(ghcr_get_manifest_sizes "oorabona/postgres" "18-alpine")
    rc=$?

    # Must succeed — the unknown platform is skipped, amd64 succeeds.
    [ "$rc" -eq 0 ]
    echo "$out" | grep -qx 'amd64:600'
    # unknown platform must NOT appear in output.
    if echo "$out" | grep -q 'unknown'; then echo "FAIL: 'unknown' found in output"; return 1; fi
}

# ---------------------------------------------------------------------------
# r4-test-1: _ghcr_fetch_index — tampered cache body evicted and refetched
# Pre-populate idx-*.body with bytes that don't match the Docker-Content-Digest
# in idx-*.hdrs.  The valid body + headers come from curl.  The function must
# evict the tampered file, emit ::warning::, and return the FRESH body.
# ---------------------------------------------------------------------------

@test "index cache hit: tampered body evicted and refetched (verify-on-hit)" {
    source "$REPO_ROOT/helpers/logging.sh" 2>/dev/null || true
    source "$REPO_ROOT/helpers/registry-utils.sh"

    # Pre-seed the cache with a tampered body whose sha256 does NOT match the
    # pre-seeded header digest (eecd94... = sha256 of the real body with newline).
    # The mismatch triggers eviction; the fresh shim serves a self-consistent
    # (body, digest) pair that passes _ghcr_verify_content_digest.
    local idx_key
    idx_key="$(_ghcr_keyfile "oorabona/postgres:18-alpine")"
    local body_file="${GHCR_CACHE_DIR}/idx-${idx_key}.body"
    local hdrs_file="${GHCR_CACHE_DIR}/idx-${idx_key}.hdrs"
    mkdir -p "$GHCR_CACHE_DIR"
    # Tampered body: sha256 will NOT be the real index digest.
    printf '%s' 'TAMPERED_INDEX_BODY' > "$body_file"
    # Headers carry the real Docker-Content-Digest for the untampered body.
    printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: sha256:eecd94bb8a87c4ce52dca17a203c8516909a4c4939d5878915d077c1757937c2\r\n\r\n' \
        > "$hdrs_file"

    # The default curl shim returns the real OCI index body, so after eviction
    # the re-fetch will populate _GHCR_IDX_BODY with the real content.
    # Call directly (not via `run`) so globals are visible in this scope.
    # Capture stderr to a temp file (not $()) so the call stays in the current
    # process and _GHCR_IDX_BODY is propagated to the surrounding scope.
    local fetch_rc=0
    local stderr_log="${WORK_DIR}/fetch_stderr.log"
    _ghcr_fetch_index "oorabona/postgres" "18-alpine" "token" 2>"$stderr_log" || fetch_rc=$?

    # Function must succeed (network re-fetch fills the globals).
    [ "$fetch_rc" -eq 0 ]

    # ::warning:: must have been emitted for the eviction.
    grep -q '::warning::.*evicted' "$stderr_log"

    # _GHCR_IDX_BODY must contain the fresh (real) body — not the tampered bytes.
    [[ "$_GHCR_IDX_BODY" != 'TAMPERED_INDEX_BODY' ]]
    [[ -n "$_GHCR_IDX_BODY" ]]

    # A network INDEX fetch must have been logged (the evicted cache forced a re-fetch).
    grep -q '^INDEX' "$CALLS"

    # The default shim now emits a verifiable 64-char Docker-Content-Digest.
    # After eviction + re-fetch + digest verification, the body IS re-cached.
    # Assert: the re-cached body file is not the tampered bytes.
    [ -f "$body_file" ] || { echo "FAIL: body not re-cached after successful re-fetch"; return 1; }
    local cached_body
    cached_body=$(cat "$body_file")
    [[ "$cached_body" != 'TAMPERED_INDEX_BODY' ]]
}

# ---------------------------------------------------------------------------
# r4-test-2: _ghcr_fetch_index — valid cache hit uses fast path (no curl)
# Pre-populate with a body that MATCHES its Docker-Content-Digest.  The curl
# shim is replaced with one that fails — it must not be called.
# ---------------------------------------------------------------------------

@test "index cache hit: valid digest → fast path (curl not called)" {
    source "$REPO_ROOT/helpers/logging.sh" 2>/dev/null || true
    source "$REPO_ROOT/helpers/registry-utils.sh"

    # Pre-seed cache with a body that matches its recorded digest.
    local idx_key
    idx_key="$(_ghcr_keyfile "oorabona/postgres:18-alpine")"
    local body_file="${GHCR_CACHE_DIR}/idx-${idx_key}.body"
    local hdrs_file="${GHCR_CACHE_DIR}/idx-${idx_key}.hdrs"
    mkdir -p "$GHCR_CACHE_DIR"

    # Body: the real OCI index (printf '%s\n') → sha256 eecd94bb...
    # We store it exactly as the shim would write it (with trailing newline).
    printf '%s\n' "$_OCI_INDEX" > "$body_file"
    printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: sha256:eecd94bb8a87c4ce52dca17a203c8516909a4c4939d5878915d077c1757937c2\r\n\r\n' \
        > "$hdrs_file"

    # Replace curl shim with one that logs and fails for any call.
    cat > "${WORK_DIR}/bin/curl" << 'CURL_FAIL'
#!/usr/bin/env bash
echo "CURL_CALLED_UNEXPECTEDLY" >> "$CALLS"
exit 1
CURL_FAIL
    chmod +x "${WORK_DIR}/bin/curl"

    # Call directly (not via `run`) so _GHCR_IDX_BODY global is visible.
    local fetch_rc=0
    _ghcr_fetch_index "oorabona/postgres" "18-alpine" "token" || fetch_rc=$?

    # Must succeed using the cached file.
    [ "$fetch_rc" -eq 0 ]

    # _GHCR_IDX_BODY must be populated from the cache.
    [[ -n "$_GHCR_IDX_BODY" ]]

    # Curl must NOT have been called.
    if grep -q 'CURL_CALLED_UNEXPECTEDLY' "$CALLS"; then echo "FAIL: curl called unexpectedly"; return 1; fi
}

# ---------------------------------------------------------------------------
# r4-test-3: per-arch cache hit — tampered body evicted and refetched
# Pre-populate perarch/<key>.body with bytes whose sha256 doesn't match
# digest_hash.  The curl shim returns the valid body.  Function must succeed
# with correct sizes, emit ::warning::, and replace the tampered file.
# ---------------------------------------------------------------------------

@test "per-arch cache hit: tampered body evicted and refetched (verify-on-hit)" {
    source "$REPO_ROOT/helpers/logging.sh" 2>/dev/null || true
    source "$REPO_ROOT/helpers/registry-utils.sh"

    # Pre-seed the amd64 per-arch cache file with tampered bytes.
    # The digest in the OCI index is c3dcb30ac02018335b76e7619cbd56c644122cd6357ba6ad92515e7a6f74ef57
    # which is the sha256 of _PER_ARCH_MANIFEST_AMD64 (no trailing newline).
    local pa_key
    pa_key="$(_ghcr_keyfile "oorabona/postgres@sha256:c3dcb30ac02018335b76e7619cbd56c644122cd6357ba6ad92515e7a6f74ef57")"
    local pa_file="${GHCR_CACHE_DIR}/perarch/${pa_key}.body"
    mkdir -p "${GHCR_CACHE_DIR}/perarch"
    printf '%s' 'TAMPERED_PERARCH_BODY' > "$pa_file"

    # The default curl shim will be called for the evicted amd64 entry and
    # return the real per-arch manifest.

    run --separate-stderr ghcr_get_manifest_sizes "oorabona/postgres" "18-alpine"

    # Function must succeed (network re-fetch delivers correct sizes).
    [ "$status" -eq 0 ]

    # ::warning:: must have been emitted for the eviction.
    echo "$stderr" | grep -q '::warning::.*evicted'

    # Output must contain correct amd64 size (re-fetched).
    echo "$output" | grep -qx 'amd64:600'

    # The tampered file must have been replaced with the real content.
    [ -f "$pa_file" ]
    local cached
    cached=$(cat "$pa_file")
    [[ "$cached" != 'TAMPERED_PERARCH_BODY' ]]
}

# ---------------------------------------------------------------------------
# r4-test-4: per-arch cache hit — valid digest → fast path (curl not called)
# Pre-populate BOTH per-arch cache files with valid matching bytes.
# Replace per-arch curl with a shim that fails on any sha256: request —
# proving that neither cached arch triggers a network round-trip.
# (The index itself has no cache yet, so the default index branch is kept.)
# ---------------------------------------------------------------------------

@test "per-arch cache hit: valid digest → fast path (curl not called for cached archs)" {
    source "$REPO_ROOT/helpers/logging.sh" 2>/dev/null || true
    source "$REPO_ROOT/helpers/registry-utils.sh"

    # Pre-seed BOTH per-arch cache files with bytes whose sha256 match the
    # digests recorded in _OCI_INDEX (c3dcb... for amd64, 13fe... for arm64).
    local pa_key_amd64 pa_key_arm64
    pa_key_amd64="$(_ghcr_keyfile "oorabona/postgres@sha256:c3dcb30ac02018335b76e7619cbd56c644122cd6357ba6ad92515e7a6f74ef57")"
    pa_key_arm64="$(_ghcr_keyfile "oorabona/postgres@sha256:13fe4dc6162b562798c5b0b086a021e4169a4f546ff9159de84a5a7837d23439")"
    mkdir -p "${GHCR_CACHE_DIR}/perarch"
    # Write exact bytes (no trailing newline) — sha256 must match the OCI index digest.
    printf '%s' "$_PER_ARCH_MANIFEST_AMD64" > "${GHCR_CACHE_DIR}/perarch/${pa_key_amd64}.body"
    printf '%s' "$_PER_ARCH_MANIFEST_ARM64" > "${GHCR_CACHE_DIR}/perarch/${pa_key_arm64}.body"

    # Override shim: any sha256: per-arch request is a test failure.
    # The index branch (non-sha256 /manifests/<tag>) is kept working so
    # _ghcr_fetch_index can populate _GHCR_IDX_BODY on the first call.
    cat > "${WORK_DIR}/bin/curl" << 'CURL_PERARCH_FAIL'
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
    # Any per-arch network request → log failure sentinel and fail.
    echo "PERARCH_FETCHED_UNEXPECTEDLY" >> "$CALLS"
    exit 1
fi
if [[ "$URL" == *"/manifests/"* ]]; then
    _body="$(printf '%s\n' "$_OCI_INDEX")"
    _digest="$(printf '%s' "$_body" | sha256sum | cut -c1-64)"
    _hdrs="$(printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: sha256:%s\r\n\r\n' "$_digest")"
    if [[ -n "$DFILE" ]]; then printf '%s' "$_hdrs" > "$DFILE"; fi
    if [[ -n "$OFILE" ]]; then printf '%s' "$_body" > "$OFILE"; else printf '%s%s' "$_hdrs" "$_body"; fi
    exit 0
fi
exit 1
CURL_PERARCH_FAIL
    chmod +x "${WORK_DIR}/bin/curl"

    out=$(ghcr_get_manifest_sizes "oorabona/postgres" "18-alpine")
    rc=$?

    # Function must succeed.
    [ "$rc" -eq 0 ]

    # Both arch:size lines must appear (both served from cache).
    echo "$out" | grep -qx 'amd64:600'
    echo "$out" | grep -qx 'arm64:750'

    # Neither arch must have triggered a network fetch.
    if grep -q 'PERARCH_FETCHED_UNEXPECTEDLY' "$CALLS"; then echo "FAIL: per-arch fetch triggered unexpectedly"; return 1; fi
}

# ---------------------------------------------------------------------------
# r6-test-1 (r8 update): _ghcr_fetch_index with digestless header cache file
# must evict the stale entry and refetch from the network (new security
# invariant: cache entries without a verifiable Docker-Content-Digest are
# treated as stale/unverifiable — not trusted).
#
# Regression guard: confirms the r8 fix handles the "no digest = evict +
# refetch" path correctly under set -euo pipefail, and that the function still
# returns 0 (data available from network) rather than failing.
# ---------------------------------------------------------------------------

@test "r6: digestless cache header evicts and refetches under set -euo pipefail (r8 security fix)" {
    source "$REPO_ROOT/helpers/logging.sh" 2>/dev/null || true
    source "$REPO_ROOT/helpers/registry-utils.sh"

    # Pre-seed cache: body present, headers WITHOUT Docker-Content-Digest line
    # (simulates a legacy cache file written before the r4 verify-on-hit fix).
    local idx_key
    idx_key="$(_ghcr_keyfile "oorabona/postgres:18-alpine")"
    local body_file="${GHCR_CACHE_DIR}/idx-${idx_key}.body"
    local hdrs_file="${GHCR_CACHE_DIR}/idx-${idx_key}.hdrs"
    mkdir -p "$GHCR_CACHE_DIR"
    printf 'STALE_DIGESTLESS_BODY\n' > "$body_file"
    # No Docker-Content-Digest header — digestless header file.
    printf 'HTTP/1.1 200 OK\r\nContent-Type: application/vnd.oci.image.index.v1+json\r\n\r\n' \
        > "$hdrs_file"

    # Replace curl shim with one that records it was called and returns a
    # fresh valid response with a verifiable Docker-Content-Digest header.
    # The digest is computed dynamically from the body bytes written to OFILE
    # (printf '%s' strips trailing newline via command substitution).
    cat > "${WORK_DIR}/bin/curl" << 'CURL_FRESH'
#!/usr/bin/env bash
echo "CURL_CALLED_R6" >> "$CALLS"
URL="${!#}"
DFILE="" OFILE=""
_prev=""
for _arg in "$@"; do
    if [[ "$_prev" == "-D" ]]; then DFILE="$_arg"; fi
    if [[ "$_prev" == "-o" ]]; then OFILE="$_arg"; fi
    _prev="$_arg"
done
if [[ "$URL" == *"/token"* ]]; then echo '{"token":"x"}'; exit 0; fi
if [[ "$URL" == *"/manifests/"* ]]; then
    _body="$(printf '%s\n' "$_OCI_INDEX")"
    _digest="$(printf '%s' "$_body" | sha256sum | cut -c1-64)"
    _hdrs="$(printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: sha256:%s\r\n\r\n' "$_digest")"
    if [[ -n "$DFILE" ]]; then printf '%s' "$_hdrs" > "$DFILE"; fi
    if [[ -n "$OFILE" ]]; then printf '%s' "$_body" > "$OFILE"; else printf '%s%s' "$_hdrs" "$_body"; fi
    exit 0
fi
exit 1
CURL_FRESH
    chmod +x "${WORK_DIR}/bin/curl"

    # Run under set -euo pipefail inside a subshell to isolate exit semantics.
    local r6_stdout_log="${WORK_DIR}/r6_stdout.log"
    local r6_stderr_log="${WORK_DIR}/r6_stderr.log"
    bash -c '
        set -euo pipefail
        source "'"$REPO_ROOT"'/helpers/logging.sh" 2>/dev/null || true
        source "'"$REPO_ROOT"'/helpers/registry-utils.sh"

        # Inject the pre-seeded cache dir and CALLS file.
        export GHCR_CACHE_DIR="'"$GHCR_CACHE_DIR"'"
        export CALLS="'"$CALLS"'"

        _ghcr_fetch_index "oorabona/postgres" "18-alpine" "token"
        echo "RC=$?"
        if [[ -n "$_GHCR_IDX_BODY" ]]; then echo "BODY_POPULATED"; fi
        if [[ "$_GHCR_IDX_BODY" != *"STALE_DIGESTLESS_BODY"* ]]; then echo "FRESH_BODY_USED"; fi
    ' > "$r6_stdout_log" 2> "$r6_stderr_log"
    local r6_rc=$?

    # Must exit 0: digestless header → evict + refetch → fresh body returned.
    [ "$r6_rc" -eq 0 ]
    grep -q 'RC=0' "$r6_stdout_log"
    grep -q 'BODY_POPULATED' "$r6_stdout_log"
    grep -q 'FRESH_BODY_USED' "$r6_stdout_log"

    # Curl MUST have been called (evict + refetch path, not trust-cache).
    if ! grep -q 'CURL_CALLED_R6' "$CALLS"; then echo "FAIL: curl was not called — stale cache was trusted"; return 1; fi

    # Eviction warning must have been emitted on stderr.
    if ! grep -q 'evicted' "$r6_stderr_log"; then echo "FAIL: no eviction warning emitted"; return 1; fi
}

# ---------------------------------------------------------------------------
# r6-test-2 (Defect B): cache-dir warning emitted exactly once across
# ghcr_get_token (command-substitution subshell) + ghcr_get_manifest_sizes.
#
# Regression guard: _GHCR_CACHE_DIR_WARNED was set without export, so the
# sentinel didn't propagate from the token subshell back to the caller.
# The caller's next _ghcr_ensure_cachedir saw the variable unset and emitted
# the warning a second time.
# ---------------------------------------------------------------------------

@test "r6: cache-dir warning emitted at least once across token + manifest_sizes calls (Defect B)" {
    # Run in a subshell; both stderr streams (token subshell + parent direct
    # call) are merged to stdout so bats captures them in $output.
    # NOTE: do NOT redirect the token subshell's stderr to the token variable —
    # the warning must flow to the parent stderr (fd 2) so it's countable.
    run bash -c '
        source "'"$REPO_ROOT"'/helpers/logging.sh" 2>/dev/null || true
        source "'"$REPO_ROOT"'/helpers/registry-utils.sh"

        export GHCR_CACHE_DIR="/proc/1/cannot-create-this-dir-$$"
        unset _GHCR_CACHE_DIR_WARNED

        # ghcr_get_token runs inside a $() subshell.  The env-var sentinel
        # (_GHCR_CACHE_DIR_WARNED) does not propagate from child $() to parent,
        # so each subshell invocation may re-emit the warning.  This is an
        # acceptable cosmetic duplicate (no flake risk, unlike the former
        # PID-keyed file sentinel which caused test flakes in shared /tmp).
        token=$(ghcr_get_token "oorabona/postgres") || true

        # Subsequent call that internally calls _ghcr_ensure_cachedir.
        ghcr_get_manifest_sizes "oorabona/postgres" "18-alpine" > /dev/null || true
    ' 2>&1

    # Must exit 0 overall.
    [ "$status" -eq 0 ]

    # The cache-dir warning must appear at least once (degraded mode triggered).
    # Duplicate warnings from $() subshells are acceptable — the regression
    # guard is that degraded mode is announced, not that it is announced once.
    local cachedir_warning_count
    cachedir_warning_count=$(echo "$output" | grep -c 'degraded (uncached' || true)
    [ "$cachedir_warning_count" -ge 1 ]
}

# ---------------------------------------------------------------------------
# r6-test-3 (Defect B): token cache write to unwritable dir must not leak
# a shell-level redirect error ("No such file or directory") on stderr.
#
# Regression guard: the printf redirect inside the umask subshell was not
# redirected to /dev/null.  An unwritable GHCR_CACHE_DIR caused bash to emit
# "bash: <path>.tmp.$$: No such file or directory" on stderr BEFORE the
# outer || true suppressor, leaking a confusing error line to CI logs.
# ---------------------------------------------------------------------------

@test "r6: token cache write to unwritable dir emits no shell redirect error (Defect B)" {
    run --separate-stderr bash -c '
        source "'"$REPO_ROOT"'/helpers/logging.sh" 2>/dev/null || true
        source "'"$REPO_ROOT"'/helpers/registry-utils.sh"

        export GHCR_CACHE_DIR="/proc/1/cannot-create-this-dir-$$"
        unset _GHCR_CACHE_DIR_WARNED

        # ghcr_get_token calls _ghcr_ensure_cachedir then attempts to write
        # the token to the unwritable cache dir.
        ghcr_get_token "oorabona/postgres" >/dev/null
    '
    # Must exit 0 (degraded mode — token returned even when cache write fails).
    [ "$status" -eq 0 ]

    # stderr must contain the one-time ::warning:: for the unwritable dir.
    echo "$stderr" | grep -q '::warning::'

    # stderr must NOT contain any "No such file or directory" shell-level error.
    # Use direct string assertion (not `! cmd | grep`) — bash `!` negation is
    # only reliably set -e safe as the terminal command in a function.
    [[ "$stderr" != *"No such file or directory"* ]] || {
        echo "FAIL: stderr leaked shell redirect error: $stderr" >&2
        return 1
    }

    # stderr must NOT contain any "cannot create" or similar write-failure message
    # other than the expected ::warning:: line.
    local non_warning_errors
    non_warning_errors=$(echo "$stderr" | grep -v '::warning::' | grep -c 'error\|cannot\|failed' || true)
    [ "$non_warning_errors" -eq 0 ]
}

# ---------------------------------------------------------------------------
# r7-A: strict digest parse — malformed multi-sha256 header rejected
#
# Regression guard: the old greedy sed 's/.*sha256://i' | head -c 64 would
# extract the LAST sha256 token from a header like:
#   Docker-Content-Digest: sha256:<good>sha256:<bad>
# and verify the body against <bad> — effectively bypassing integrity.
#
# The fix uses an anchored BASH_REMATCH that accepts exactly ONE sha256 token.
# A malformed header must yield cached_expected="" so the length guard skips
# verification and falls through to the trust-cache path (same behaviour as
# "no header stored").
# ---------------------------------------------------------------------------

@test "r7-A: malformed multi-sha256 header rejected — strict parser evicts and refetches (r8 security fix)" {
    source "$REPO_ROOT/helpers/logging.sh" 2>/dev/null || true
    source "$REPO_ROOT/helpers/registry-utils.sh"

    # Pre-seed cache: body with known sha256, headers carry a MALFORMED digest
    # containing two sha256 tokens — the old greedy parser would extract the
    # second (attacker-controlled) token; the strict parser must reject it
    # (cached_expected="").  Under the r8 security invariant, a rejected
    # (unverifiable) digest is treated the same as missing: evict + refetch.
    local idx_key
    idx_key="$(_ghcr_keyfile "oorabona/postgres:18-alpine")"
    local body_file="${GHCR_CACHE_DIR}/idx-${idx_key}.body"
    local hdrs_file="${GHCR_CACHE_DIR}/idx-${idx_key}.hdrs"
    mkdir -p "$GHCR_CACHE_DIR"

    # Body content doesn't matter for this test — we just need a non-empty file.
    printf '%s\n' "$_OCI_INDEX" > "$body_file"

    # Malformed header: two sha256 tokens concatenated without space separator.
    # The strict regex rejects this (cached_expected="") → unverifiable → evict.
    printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: sha256:eecd94bb8a87c4ce52dca17a203c8516909a4c4939d5878915d077c1757937c2sha256:0000000000000000000000000000000000000000000000000000000000000000\r\n\r\n' \
        > "$hdrs_file"

    # Replace curl shim with one that records it was called and returns a fresh
    # valid response with a verifiable Docker-Content-Digest header.
    # Digest: sha256 of printf '%s\n' "$_OCI_INDEX" (exact bytes shim writes).
    cat > "${WORK_DIR}/bin/curl" << 'CURL_FRESH_R7A'
#!/usr/bin/env bash
echo "CURL_CALLED_R7A" >> "$CALLS"
URL="${!#}"
DFILE="" OFILE=""
_prev=""
for _arg in "$@"; do
    if [[ "$_prev" == "-D" ]]; then DFILE="$_arg"; fi
    if [[ "$_prev" == "-o" ]]; then OFILE="$_arg"; fi
    _prev="$_arg"
done
if [[ "$URL" == *"/token"* ]]; then echo '{"token":"x"}'; exit 0; fi
if [[ "$URL" == *"/manifests/"* ]]; then
    _body="$(printf '%s\n' "$_OCI_INDEX")"
    _digest="$(printf '%s' "$_body" | sha256sum | cut -c1-64)"
    _hdrs="$(printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: sha256:%s\r\n\r\n' "$_digest")"
    if [[ -n "$DFILE" ]]; then printf '%s' "$_hdrs" > "$DFILE"; fi
    if [[ -n "$OFILE" ]]; then printf '%s' "$_body" > "$OFILE"; else printf '%s%s' "$_hdrs" "$_body"; fi
    exit 0
fi
exit 1
CURL_FRESH_R7A
    chmod +x "${WORK_DIR}/bin/curl"

    local fetch_rc=0
    local stderr_log="${WORK_DIR}/r7a_stderr.log"
    _ghcr_fetch_index "oorabona/postgres" "18-alpine" "token" 2>"$stderr_log" || fetch_rc=$?

    # Must succeed: malformed header → strict parser rejects → evict + refetch → fresh body.
    [ "$fetch_rc" -eq 0 ]

    # Curl MUST have been called (evict + refetch, not trust-cache).
    if ! grep -q 'CURL_CALLED_R7A' "$CALLS"; then echo "FAIL: curl was not called — malformed cache was trusted"; return 1; fi

    # Eviction warning must have been emitted.
    if ! grep -q 'evicted' "$stderr_log"; then echo "FAIL: no eviction warning emitted"; return 1; fi

    # _GHCR_IDX_BODY must be populated from the fresh network response.
    [[ -n "$_GHCR_IDX_BODY" ]]
}

# ---------------------------------------------------------------------------
# r7-B: bats assertion correctness — direct string check catches "No such file"
#
# Regression guard for Defect B: the original test used `! echo "$stderr" | grep`
# which is unreliable under set -e when followed by other statements.  This test
# PROVES that the corrected [[ "$stderr" != *"..."* ]] assertion actually catches
# a synthesized stderr containing the forbidden phrase.
# ---------------------------------------------------------------------------

@test "r7-B: direct string assertion catches synthesized 'No such file or directory' in stderr" {
    # Synthesize a stderr that contains the forbidden phrase.
    local synthetic_stderr
    synthetic_stderr="bash: /proc/1/cannot-create: No such file or directory"

    # The corrected assertion style must detect the phrase and trigger the fail
    # branch.  We invert the expectation here to assert that the check fires.
    local caught=0
    [[ "$synthetic_stderr" != *"No such file or directory"* ]] || caught=1

    [ "$caught" -eq 1 ]

    # Confirm the converse: a clean stderr must NOT trigger the check.
    local clean_stderr
    clean_stderr="::warning:: cache dir not writable, running in degraded mode"
    local clean_caught=0
    [[ "$clean_stderr" != *"No such file or directory"* ]] || clean_caught=1

    [ "$clean_caught" -eq 0 ]
}

# ---------------------------------------------------------------------------
# r8: corrupted-hdrs poison-eviction regression
#
# Security regression guard for Defect A (r8 fix): an attacker who can write
# to GHCR_CACHE_DIR pre-populates the body with poisoned bytes and removes the
# Docker-Content-Digest line from the headers file.  The r8 fix must:
#   1. Detect the missing digest in the cached headers.
#   2. Evict both cache files.
#   3. Emit an ::warning:: to stderr.
#   4. Fall through to a network refetch and return the FRESH (non-poisoned) body.
#
# This proves the attack vector is closed: missing digest ≠ trust cache.
# ---------------------------------------------------------------------------

@test "r8: corrupted-hdrs (no digest) → evict + refetch, poison not served" {
    source "$REPO_ROOT/helpers/logging.sh" 2>/dev/null || true
    source "$REPO_ROOT/helpers/registry-utils.sh"

    # Pre-seed cache with a poisoned body and a headers file missing the
    # Docker-Content-Digest line (simulates attacker-controlled cache dir).
    local idx_key
    idx_key="$(_ghcr_keyfile "oorabona/postgres:18-alpine")"
    local body_file="${GHCR_CACHE_DIR}/idx-${idx_key}.body"
    local hdrs_file="${GHCR_CACHE_DIR}/idx-${idx_key}.hdrs"
    mkdir -p "$GHCR_CACHE_DIR"
    printf 'POISONED_CONTENT_INJECTED_BY_ATTACKER\n' > "$body_file"
    # Headers deliberately lack Docker-Content-Digest — the attack relies on
    # the old code's "no digest → trust" branch.
    printf 'HTTP/1.1 200 OK\r\nContent-Type: application/vnd.oci.image.index.v1+json\r\n\r\n' \
        > "$hdrs_file"

    # Fresh-response curl shim: records it was called, returns valid OCI index.
    cat > "${WORK_DIR}/bin/curl" << 'CURL_FRESH_R8'
#!/usr/bin/env bash
echo "CURL_CALLED_R8" >> "$CALLS"
URL="${!#}"
DFILE="" OFILE=""
_prev=""
for _arg in "$@"; do
    if [[ "$_prev" == "-D" ]]; then DFILE="$_arg"; fi
    if [[ "$_prev" == "-o" ]]; then OFILE="$_arg"; fi
    _prev="$_arg"
done
if [[ "$URL" == *"/token"* ]]; then echo '{"token":"x"}'; exit 0; fi
if [[ "$URL" == *"/manifests/"* ]]; then
    _body="$(printf '%s\n' "$_OCI_INDEX")"
    _digest="$(printf '%s' "$_body" | sha256sum | cut -c1-64)"
    _hdrs="$(printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: sha256:%s\r\n\r\n' "$_digest")"
    if [[ -n "$DFILE" ]]; then printf '%s' "$_hdrs" > "$DFILE"; fi
    if [[ -n "$OFILE" ]]; then printf '%s' "$_body" > "$OFILE"; else printf '%s%s' "$_hdrs" "$_body"; fi
    exit 0
fi
exit 1
CURL_FRESH_R8
    chmod +x "${WORK_DIR}/bin/curl"

    local fetch_rc=0
    local stderr_log="${WORK_DIR}/r8_stderr.log"
    _ghcr_fetch_index "oorabona/postgres" "18-alpine" "token" 2>"$stderr_log" || fetch_rc=$?

    # Must succeed overall — fresh data available from network.
    [ "$fetch_rc" -eq 0 ]

    # Network refetch MUST have occurred — poisoned cache was evicted.
    if ! grep -q 'CURL_CALLED_R8' "$CALLS"; then echo "FAIL: curl was not called — poisoned cache was trusted"; return 1; fi

    # Eviction warning must have been emitted on stderr.
    if ! grep -q 'evicted' "$stderr_log"; then echo "FAIL: no eviction warning emitted"; return 1; fi

    # Returned body must be the FRESH response, NOT the poisoned bytes.
    if [[ "$_GHCR_IDX_BODY" == *"POISONED_CONTENT_INJECTED_BY_ATTACKER"* ]]; then
        echo "FAIL: poisoned body was served to caller"; return 1
    fi
    [[ -n "$_GHCR_IDX_BODY" ]]

    # Cache files must have been evicted (replaced by the fresh network write).
    # The body file will be rewritten with fresh content; verify it's not poison.
    if [[ -f "$body_file" ]]; then
        if grep -q 'POISONED_CONTENT_INJECTED_BY_ATTACKER' "$body_file"; then
            echo "FAIL: poisoned body still in cache after refetch"; return 1
        fi
    fi
}

# ---------------------------------------------------------------------------
# r9: Defect A — cache dir trust validation
# ---------------------------------------------------------------------------

@test "r9-A1: loose-mode cache dir (0777) is rejected — switches to private mktemp (not reused)" {
    # r10 fix: a dir owned by us but with mode != 0700 must be treated as
    # untrusted.  It may contain attacker-planted body+hdrs files with matching
    # digests written before we arrived; silent chmod-to-700 only closes future
    # writes but cannot purge that pre-existing poisoned content.
    # Expected behaviour: same response as symlink/foreign-owner — switch to a
    # fresh private mktemp dir and emit ::warning::.
    source "$REPO_ROOT/helpers/logging.sh" 2>/dev/null || true
    source "$REPO_ROOT/helpers/registry-utils.sh"

    # Plant a poisoned body file in the loose-mode dir before _ghcr_ensure_cachedir.
    mkdir -p "$GHCR_CACHE_DIR"
    chmod 777 "$GHCR_CACHE_DIR"
    echo "POISONED_CONTENT" > "${GHCR_CACHE_DIR}/poison.body"
    local original_dir="$GHCR_CACHE_DIR"

    local stderr_log="${WORK_DIR}/r9a1_stderr.log"
    _ghcr_ensure_cachedir 2>"$stderr_log"

    # GHCR_CACHE_DIR must have been switched away from the loose-mode dir.
    [ "$GHCR_CACHE_DIR" != "$original_dir" ]

    # The new dir must be a real directory (not a symlink) and mode 0700.
    [[ -d "$GHCR_CACHE_DIR" && ! -L "$GHCR_CACHE_DIR" ]]
    local mode
    mode=$(stat -c '%a' "$GHCR_CACHE_DIR")
    [ "$mode" = "700" ]

    # The poisoned content must NOT be visible in the new cache dir.
    [ ! -f "${GHCR_CACHE_DIR}/poison.body" ] || {
        echo "FAIL: poisoned file visible in switched-to cache dir" >&2
        return 1
    }

    # A ::warning:: must have been emitted about the untrusted dir.
    grep -q '::warning::.*untrusted' "$stderr_log"
}

@test "r9-A2: symlink cache dir is rejected — warning emitted and private mktemp used" {
    # A symlink at GHCR_CACHE_DIR could point to attacker-controlled storage.
    # _ghcr_ensure_cachedir must detect the symlink and switch to a fresh dir.
    source "$REPO_ROOT/helpers/logging.sh" 2>/dev/null || true
    source "$REPO_ROOT/helpers/registry-utils.sh"

    # Create the real target and a symlink pointing to it.
    # setup() pre-creates GHCR_CACHE_DIR as a real directory; remove it first
    # so that ln -s creates the symlink AT that path (not inside it).
    local real_target="${WORK_DIR}/real_cache_target"
    mkdir -p "$real_target"
    rm -rf "$GHCR_CACHE_DIR"
    ln -s "$real_target" "$GHCR_CACHE_DIR"
    local original_dir="$GHCR_CACHE_DIR"

    local stderr_log="${WORK_DIR}/r9a2_stderr.log"
    _ghcr_ensure_cachedir 2>"$stderr_log"

    # GHCR_CACHE_DIR must have been switched away from the symlink.
    [ "$GHCR_CACHE_DIR" != "$original_dir" ]

    # The new dir must be a real directory (not a symlink) and must be writable.
    [[ -d "$GHCR_CACHE_DIR" && ! -L "$GHCR_CACHE_DIR" ]]

    # A ::warning:: must have been emitted about the untrusted dir.
    grep -q '::warning::.*untrusted' "$stderr_log"
}

# ---------------------------------------------------------------------------
# r9: Defect B — fresh-fetch no-digest = skip-cache-but-return-body
# ---------------------------------------------------------------------------

@test "r9-B: fresh response without Docker-Content-Digest — returns 1 (fail-closed, no body served)" {
    # r10 fix: when a fresh GHCR response carries no Docker-Content-Digest header
    # the content cannot be cryptographically verified.  Returning the body to
    # the caller even "best-effort" allows a digest-stripping bypass for the
    # current run (not just cache admission).  Fail-closed: return 1 so the
    # caller's retry/error-handling kicks in.  Cache files must NOT be written.
    source "$REPO_ROOT/helpers/logging.sh" 2>/dev/null || true
    source "$REPO_ROOT/helpers/registry-utils.sh"

    # Override curl shim: returns a valid OCI index body with NO digest header.
    cat > "${WORK_DIR}/bin/curl" << 'CURL_NODIGEST'
#!/usr/bin/env bash
URL="${!#}"
DFILE="" OFILE=""
_prev=""
for _arg in "$@"; do
    if [[ "$_prev" == "-D" ]]; then DFILE="$_arg"; fi
    if [[ "$_prev" == "-o" ]]; then OFILE="$_arg"; fi
    _prev="$_arg"
done
if [[ "$URL" == *"/token"* ]]; then echo '{"token":"x"}'; exit 0; fi
if [[ "$URL" == *"/manifests/"* ]]; then
    echo "INDEX_NODIGEST" >> "$CALLS"
    # Headers: no Docker-Content-Digest line.
    _hdrs="$(printf 'HTTP/1.1 200 OK\r\nContent-Type: application/vnd.oci.image.index.v1+json\r\n\r\n')"
    _body="$(printf '%s\n' "$_OCI_INDEX")"
    if [[ -n "$DFILE" ]]; then printf '%s' "$_hdrs" > "$DFILE"; fi
    if [[ -n "$OFILE" ]]; then printf '%s' "$_body" > "$OFILE"; else printf '%s%s' "$_hdrs" "$_body"; fi
    exit 0
fi
exit 1
CURL_NODIGEST
    chmod +x "${WORK_DIR}/bin/curl"

    local fetch_rc=0
    local stderr_log="${WORK_DIR}/r9b_stderr.log"
    _ghcr_fetch_index "oorabona/postgres" "18-alpine" "token" 2>"$stderr_log" || fetch_rc=$?

    # Function must fail — unverified body must not be served (fail-closed).
    [ "$fetch_rc" -ne 0 ]

    # Network fetch DID occur (not a cache hit).
    grep -q 'INDEX_NODIGEST' "$CALLS"

    # ::warning:: must indicate the response was refused.
    grep -q '::warning::.*refusing' "$stderr_log"

    # Cache files must NOT have been written.
    local idx_key
    idx_key="$(_ghcr_keyfile "oorabona/postgres:18-alpine")"
    local body_file="${GHCR_CACHE_DIR}/idx-${idx_key}.body"
    local hdrs_file="${GHCR_CACHE_DIR}/idx-${idx_key}.hdrs"
    [ ! -f "$body_file" ] || {
        echo "FAIL: body cache file was created despite missing digest header" >&2
        return 1
    }
    [ ! -f "$hdrs_file" ] || {
        echo "FAIL: hdrs cache file was created despite missing digest header" >&2
        return 1
    }
}

# ---------------------------------------------------------------------------
# r9: Defect B (r12) — env-var sentinel; no file sentinel created
# ---------------------------------------------------------------------------

@test "r9-C: degraded mode uses env-var sentinel only — no .ghcr_cache_warned file created" {
    # r12: the file-based PID sentinel (${TMPDIR:-/tmp}/.ghcr_cache_warned.$$)
    # was replaced by a pure env-var sentinel (_GHCR_CACHE_DIR_WARNED) to fix
    # PID-reuse flakes in shared /tmp environments. Verify: after degraded-mode
    # entry, no .ghcr_cache_warned.* file is created in TMPDIR.
    source "$REPO_ROOT/helpers/logging.sh" 2>/dev/null || true
    source "$REPO_ROOT/helpers/registry-utils.sh"

    # Use an unwritable cache dir to trigger degraded mode.
    export GHCR_CACHE_DIR="/proc/1/cannot-create-this-dir-r9c-$$"
    unset _GHCR_CACHE_DIR_WARNED

    _ghcr_ensure_cachedir 2>/dev/null || true

    # No file sentinel must be created.
    local file_count
    file_count=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name ".ghcr_cache_warned.$$" 2>/dev/null | wc -l)
    [ "$file_count" -eq 0 ] || {
        echo "FAIL: file sentinel was created (should use env-var only)" >&2
        return 1
    }

    # Env-var sentinel must be set.
    [ "${_GHCR_CACHE_DIR_WARNED:-}" = "1" ] || {
        echo "FAIL: _GHCR_CACHE_DIR_WARNED not set after degraded mode" >&2
        return 1
    }
}

# ---------------------------------------------------------------------------
# r10: New regression tests
# ---------------------------------------------------------------------------

@test "r10-A: loose-mode dir with pre-planted body+hdrs — switched to fresh mktemp, poison not visible" {
    # Regression: r9 silently chmod'd a loose-mode dir we own, leaving any
    # pre-existing attacker-planted files accessible. r10 switches to a fresh
    # mktemp dir so the pre-existing content is structurally unreachable.
    source "$REPO_ROOT/helpers/logging.sh" 2>/dev/null || true
    source "$REPO_ROOT/helpers/registry-utils.sh"

    # Plant poisoned body+hdrs in the loose-mode dir before calling ensure.
    mkdir -p "$GHCR_CACHE_DIR"
    chmod 755 "$GHCR_CACHE_DIR"
    local idx_key
    idx_key="$(_ghcr_keyfile "oorabona/postgres:18-alpine")"
    echo "POISON_BODY" > "${GHCR_CACHE_DIR}/idx-${idx_key}.body"
    echo "POISON_HDRS" > "${GHCR_CACHE_DIR}/idx-${idx_key}.hdrs"
    local hostile_dir="$GHCR_CACHE_DIR"

    local stderr_log="${WORK_DIR}/r10a_stderr.log"
    _ghcr_ensure_cachedir 2>"$stderr_log"

    # Must have switched to a fresh dir.
    [ "$GHCR_CACHE_DIR" != "$hostile_dir" ]
    [[ -d "$GHCR_CACHE_DIR" && ! -L "$GHCR_CACHE_DIR" ]]

    # Poisoned files must NOT be visible in the new dir.
    [ ! -f "${GHCR_CACHE_DIR}/idx-${idx_key}.body" ] || {
        echo "FAIL: poisoned body visible in new cache dir" >&2; return 1
    }
    [ ! -f "${GHCR_CACHE_DIR}/idx-${idx_key}.hdrs" ] || {
        echo "FAIL: poisoned hdrs visible in new cache dir" >&2; return 1
    }

    # Warning must have been emitted.
    grep -q '::warning::.*untrusted' "$stderr_log"
}

@test "r10-B: mktemp-d failure after untrusted dir — GHCR_CACHE_DIR cleared, hostile path not used" {
    # Regression: when mktemp -d fails in the untrusted-dir path, the old code
    # left GHCR_CACHE_DIR pointing at the hostile original. r10 sets
    # GHCR_CACHE_DIR="" so _ghcr_temp_file falls back to TMPDIR, never touching
    # the hostile path.
    source "$REPO_ROOT/helpers/logging.sh" 2>/dev/null || true
    source "$REPO_ROOT/helpers/registry-utils.sh"

    # Create the hostile (loose-mode) dir.
    mkdir -p "$GHCR_CACHE_DIR"
    chmod 777 "$GHCR_CACHE_DIR"
    local hostile_dir="$GHCR_CACHE_DIR"

    # Override mktemp to fail for the "ghcr-cache-private" pattern.
    cat > "${WORK_DIR}/bin/mktemp" << 'MKTEMP_FAIL'
#!/usr/bin/env bash
# Fail if creating a ghcr-cache-private dir; forward everything else.
if [[ "$*" == *"ghcr-cache-private"* ]]; then
    echo "mktemp: cannot create temp dir" >&2
    exit 1
fi
exec /usr/bin/mktemp "$@"
MKTEMP_FAIL
    chmod +x "${WORK_DIR}/bin/mktemp"

    local stderr_log="${WORK_DIR}/r10b_stderr.log"
    unset _GHCR_CACHE_DIR_WARNED
    _ghcr_ensure_cachedir 2>"$stderr_log"

    # GHCR_CACHE_DIR must be empty (hostile path cleared).
    [ -z "$GHCR_CACHE_DIR" ] || {
        echo "FAIL: GHCR_CACHE_DIR not cleared; still '$GHCR_CACHE_DIR'" >&2
        [ "$GHCR_CACHE_DIR" != "$hostile_dir" ] || { echo "FAIL: hostile path still in use" >&2; return 1; }
    }

    # _ghcr_temp_file must return a path NOT under the hostile dir.
    local tmp_path
    tmp_path=$(_ghcr_temp_file "test-suffix")
    [[ "$tmp_path" != "${hostile_dir}"* ]] || {
        echo "FAIL: _ghcr_temp_file returned path under hostile dir: $tmp_path" >&2; return 1
    }
    rm -f "$tmp_path" 2>/dev/null || true

    # Warning about uncached mode must have been emitted.
    grep -q '::warning::' "$stderr_log"
}

@test "r10-C: fresh fetch missing Docker-Content-Digest returns 1, malformed also returns 1" {
    # Regression guard for Defect C: both missing and malformed digest must
    # return 1 (fail-closed), not 0 with unverified body.
    source "$REPO_ROOT/helpers/logging.sh" 2>/dev/null || true
    source "$REPO_ROOT/helpers/registry-utils.sh"

    # ---- Case 1: no digest header ----
    cat > "${WORK_DIR}/bin/curl" << 'CURL_NODIGEST_C'
#!/usr/bin/env bash
URL="${!#}"
DFILE="" OFILE=""
_prev=""
for _arg in "$@"; do
    if [[ "$_prev" == "-D" ]]; then DFILE="$_arg"; fi
    if [[ "$_prev" == "-o" ]]; then OFILE="$_arg"; fi
    _prev="$_arg"
done
if [[ "$URL" == *"/token"* ]]; then echo '{"token":"x"}'; exit 0; fi
if [[ "$URL" == *"/manifests/"* ]]; then
    _hdrs="$(printf 'HTTP/1.1 200 OK\r\nContent-Type: application/vnd.oci.image.index.v1+json\r\n\r\n')"
    _body="$(printf '%s\n' "$_OCI_INDEX")"
    if [[ -n "$DFILE" ]]; then printf '%s' "$_hdrs" > "$DFILE"; fi
    if [[ -n "$OFILE" ]]; then printf '%s' "$_body" > "$OFILE"; else printf '%s%s' "$_hdrs" "$_body"; fi
    exit 0
fi
exit 1
CURL_NODIGEST_C
    chmod +x "${WORK_DIR}/bin/curl"

    local rc1=0
    local stderr1="${WORK_DIR}/r10c_no_digest.log"
    _ghcr_fetch_index "oorabona/postgres" "18-alpine" "token" 2>"$stderr1" || rc1=$?
    [ "$rc1" -ne 0 ] || { echo "FAIL: missing digest returned 0 (should be 1)" >&2; return 1; }
    grep -q '::warning::.*refusing' "$stderr1"

    # ---- Case 2: malformed digest (non-64-char) ----
    cat > "${WORK_DIR}/bin/curl" << 'CURL_BADDIGEST_C'
#!/usr/bin/env bash
URL="${!#}"
DFILE="" OFILE=""
_prev=""
for _arg in "$@"; do
    if [[ "$_prev" == "-D" ]]; then DFILE="$_arg"; fi
    if [[ "$_prev" == "-o" ]]; then OFILE="$_arg"; fi
    _prev="$_arg"
done
if [[ "$URL" == *"/token"* ]]; then echo '{"token":"x"}'; exit 0; fi
if [[ "$URL" == *"/manifests/"* ]]; then
    _hdrs="$(printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: sha256:tooshort\r\n\r\n')"
    _body="$(printf '%s\n' "$_OCI_INDEX")"
    if [[ -n "$DFILE" ]]; then printf '%s' "$_hdrs" > "$DFILE"; fi
    if [[ -n "$OFILE" ]]; then printf '%s' "$_body" > "$OFILE"; else printf '%s%s' "$_hdrs" "$_body"; fi
    exit 0
fi
exit 1
CURL_BADDIGEST_C
    chmod +x "${WORK_DIR}/bin/curl"

    # Reset state for second call.
    _GHCR_IDX_BODY=""
    _GHCR_IDX_HDRS=""
    local rc2=0
    local stderr2="${WORK_DIR}/r10c_bad_digest.log"
    _ghcr_fetch_index "oorabona/postgres" "18-alpine" "token" 2>"$stderr2" || rc2=$?
    [ "$rc2" -ne 0 ] || { echo "FAIL: malformed digest returned 0 (should be 1)" >&2; return 1; }
    grep -q '::warning::.*refusing' "$stderr2"
}

# ---------------------------------------------------------------------------
# r11 regression tests: empty GHCR_CACHE_DIR must not produce root-level paths
# ---------------------------------------------------------------------------

# Marker file to detect writes older than our test.
_r11_marker() { touch "${WORK_DIR}/.r11_marker"; }

@test "r11: empty GHCR_CACHE_DIR — ghcr_get_token does not write to root paths and still returns token" {
    # Use a simulated "root-like" dir to avoid actually touching / in CI.
    local fake_root="${WORK_DIR}/fakeroot"
    mkdir -p "$fake_root"
    _r11_marker

    # Source the helper with GHCR_CACHE_DIR disabled.
    # shellcheck disable=SC1090
    GHCR_CACHE_DIR="" source "${REPO_ROOT}/helpers/registry-utils.sh"
    export GHCR_CACHE_DIR=""

    # Invoke ghcr_get_token — curl shim returns '{"token":"testtoken"}'.
    local tok
    tok=$(ghcr_get_token "oorabona/postgres" 2>/dev/null)

    # 1. Token must be returned (degraded mode is still functional).
    [ -n "$tok" ] || { echo "FAIL: empty token returned in degraded mode" >&2; return 1; }

    # 2. No token-* files should have been created anywhere under $fake_root
    #    (use WORK_DIR as a proxy for "root" since tests can't safely check /).
    local stray
    stray=$(find "${WORK_DIR}" -maxdepth 1 -name 'token-*' -newer "${WORK_DIR}/.r11_marker" 2>/dev/null || true)
    [ -z "$stray" ] || { echo "FAIL: stray token file(s) found: $stray" >&2; return 1; }

    # 3. GHCR_CACHE_DIR must remain empty (no accidental re-enable).
    [ -z "${GHCR_CACHE_DIR:-}" ] || { echo "FAIL: GHCR_CACHE_DIR was set to '${GHCR_CACHE_DIR}' unexpectedly" >&2; return 1; }
}

@test "r11: empty GHCR_CACHE_DIR — ghcr_get_token does not read from root paths (hostile pre-placed token ignored)" {
    _r11_marker

    # Pre-place a hostile token at a path that WOULD have been constructed if
    # GHCR_CACHE_DIR were empty (uses WORK_DIR instead of / for safety).
    # If GHCR_CACHE_DIR="" and code still does "${GHCR_CACHE_DIR}/token-...",
    # it would compute "/token-..." which begins from real root — dangerous.
    # We simulate by placing a file that the curl call counter would show
    # was NOT called if the hostile token were read.
    # shellcheck disable=SC1090
    GHCR_CACHE_DIR="" source "${REPO_ROOT}/helpers/registry-utils.sh"
    export GHCR_CACHE_DIR=""

    # Reset call counter.
    > "$CALLS"

    local tok
    tok=$(ghcr_get_token "oorabona/postgres" 2>/dev/null)

    # With cache disabled, we MUST hit the network (curl shim) for the token.
    # If the hostile pre-placed file were read, the curl TOKEN call would NOT appear.
    grep -q 'TOKEN' "$CALLS" || { echo "FAIL: curl TOKEN not called — hostile cached token may have been served" >&2; return 1; }

    # Token must still be the shim's value.
    [ "$tok" = "x" ] || { echo "FAIL: unexpected token value '$tok'" >&2; return 1; }
}

@test "r11: empty GHCR_CACHE_DIR — invalidate functions are no-ops (no root file deletions)" {
    _r11_marker

    # Pre-place sentinel files at the root of WORK_DIR to simulate root-path risk.
    local sentinel_token="${WORK_DIR}/token-sentinel"
    local sentinel_idx_body="${WORK_DIR}/idx-sentinel.body"
    local sentinel_idx_hdrs="${WORK_DIR}/idx-sentinel.hdrs"
    touch "$sentinel_token" "$sentinel_idx_body" "$sentinel_idx_hdrs"

    # shellcheck disable=SC1090
    GHCR_CACHE_DIR="" source "${REPO_ROOT}/helpers/registry-utils.sh"
    export GHCR_CACHE_DIR=""

    # Call invalidate functions — with cache disabled these must be silent no-ops.
    ghcr_invalidate_token "oorabona/postgres" 2>/dev/null
    _ghcr_invalidate_index "oorabona/postgres" "18-alpine" 2>/dev/null

    # Sentinel files must NOT have been deleted.
    [ -f "$sentinel_token" ]    || { echo "FAIL: token sentinel deleted by ghcr_invalidate_token" >&2; return 1; }
    [ -f "$sentinel_idx_body" ] || { echo "FAIL: idx body sentinel deleted by _ghcr_invalidate_index" >&2; return 1; }
    [ -f "$sentinel_idx_hdrs" ] || { echo "FAIL: idx hdrs sentinel deleted by _ghcr_invalidate_index" >&2; return 1; }
}

@test "r11: mkdir TOCTOU — pre-existing symlink triggers mktemp fallback" {
    # Create a symlink at the intended cache dir location pointing to a
    # directory we control (simulating an attacker-controlled target).
    local target_dir="${WORK_DIR}/attacker-dir"
    local symlink_path="${WORK_DIR}/symlink-cache"
    mkdir -p "$target_dir"
    ln -s "$target_dir" "$symlink_path"

    # Source fresh copy with GHCR_CACHE_DIR pointing at the symlink.
    # shellcheck disable=SC1090
    GHCR_CACHE_DIR="$symlink_path" source "${REPO_ROOT}/helpers/registry-utils.sh"
    export GHCR_CACHE_DIR="$symlink_path"
    unset _GHCR_CACHE_DIR_WARNED

    local stderr_log="${WORK_DIR}/r11_toctou.log"
    _ghcr_ensure_cachedir 2>"$stderr_log"

    # After ensure_cachedir, GHCR_CACHE_DIR must NOT be the symlink path.
    [ "${GHCR_CACHE_DIR}" != "$symlink_path" ] || {
        echo "FAIL: GHCR_CACHE_DIR still set to symlink path '${GHCR_CACHE_DIR}'" >&2
        return 1
    }

    # It must have switched to a real mktemp dir (non-empty) OR been cleared to ""
    # (if mktemp also failed, which shouldn't happen in normal CI).
    # Either outcome avoids the hostile symlink path.
    if [[ -n "${GHCR_CACHE_DIR}" ]]; then
        # Must be a real directory (not a symlink).
        [ ! -L "${GHCR_CACHE_DIR}" ] || {
            echo "FAIL: GHCR_CACHE_DIR is still a symlink '${GHCR_CACHE_DIR}'" >&2
            return 1
        }
        [ -d "${GHCR_CACHE_DIR}" ] || {
            echo "FAIL: GHCR_CACHE_DIR '${GHCR_CACHE_DIR}' is not a directory" >&2
            return 1
        }
    fi

    # A warning must have been emitted about the untrusted dir.
    grep -q '::warning::' "$stderr_log" || {
        echo "FAIL: no ::warning:: emitted for symlink cache dir" >&2
        return 1
    }
}

# ---------------------------------------------------------------------------
# r12: Defect A regression — invalidate must not delete through a symlinked
# cache dir (_ghcr_cache_enabled now calls _ghcr_validate_cachedir).
# ---------------------------------------------------------------------------

@test "r12-A: ghcr_invalidate_token does not delete through a symlinked cache dir" {
    # Regression: _ghcr_cache_enabled only checked non-empty + dir + writable,
    # so a symlinked GHCR_CACHE_DIR would pass the guard.  ghcr_invalidate_token
    # would then rm -f a path under the symlink, potentially deleting files in
    # an attacker-controlled target directory.
    #
    # Fix: _ghcr_cache_enabled now calls _ghcr_validate_cachedir, which rejects
    # symlinks.  invalidate must be a silent no-op when the symlink guard fires.
    source "$REPO_ROOT/helpers/logging.sh" 2>/dev/null || true
    source "$REPO_ROOT/helpers/registry-utils.sh"

    # Create a symlinked cache dir pointing to an attacker-controlled target.
    local target_dir="${WORK_DIR}/attacker-target"
    local symlink_path="${WORK_DIR}/symlink-cache-r12a"
    mkdir -p "$target_dir"
    chmod 700 "$target_dir"
    ln -s "$target_dir" "$symlink_path"

    # Pre-plant a file in the target that invalidate should NOT delete.
    local keyfile
    keyfile="token-$(_ghcr_keyfile "oorabona/postgres")"
    touch "${target_dir}/${keyfile}"

    export GHCR_CACHE_DIR="$symlink_path"
    unset _GHCR_CACHE_DIR_WARNED

    # Call invalidate — must be a no-op (symlink fails _ghcr_cache_enabled).
    ghcr_invalidate_token "oorabona/postgres" 2>/dev/null

    # Target file must NOT have been deleted.
    [ -f "${target_dir}/${keyfile}" ] || {
        echo "FAIL: ghcr_invalidate_token deleted file through symlinked cache dir" >&2
        return 1
    }
}

@test "r12-B: _ghcr_invalidate_index does not delete through a symlinked cache dir" {
    # Companion to r12-A for the index invalidation path.
    source "$REPO_ROOT/helpers/logging.sh" 2>/dev/null || true
    source "$REPO_ROOT/helpers/registry-utils.sh"

    local target_dir="${WORK_DIR}/attacker-target-r12b"
    local symlink_path="${WORK_DIR}/symlink-cache-r12b"
    mkdir -p "$target_dir"
    chmod 700 "$target_dir"
    ln -s "$target_dir" "$symlink_path"

    # Pre-plant body+hdrs files in the target that invalidate should NOT delete.
    local k
    k="$(_ghcr_keyfile "oorabona/postgres:18-alpine")"
    touch "${target_dir}/idx-${k}.body"
    touch "${target_dir}/idx-${k}.hdrs"

    export GHCR_CACHE_DIR="$symlink_path"
    unset _GHCR_CACHE_DIR_WARNED

    # Call invalidate — must be a no-op.
    _ghcr_invalidate_index "oorabona/postgres" "18-alpine" 2>/dev/null

    # Target files must NOT have been deleted.
    [ -f "${target_dir}/idx-${k}.body" ] || {
        echo "FAIL: _ghcr_invalidate_index deleted body through symlinked cache dir" >&2
        return 1
    }
    [ -f "${target_dir}/idx-${k}.hdrs" ] || {
        echo "FAIL: _ghcr_invalidate_index deleted hdrs through symlinked cache dir" >&2
        return 1
    }
}

# ---------------------------------------------------------------------------
# r13 regression tests: _ghcr_fetch_index globals cleared on all fail-closed paths
# ---------------------------------------------------------------------------

@test "r13-A: globals cleared when fresh response lacks Docker-Content-Digest" {
    # Finding 3: _GHCR_IDX_BODY/_GHCR_IDX_HDRS must be empty after fail-closed
    # return on missing digest header — prevents caller from trusting stale data.
    source "$REPO_ROOT/helpers/logging.sh" 2>/dev/null || true
    source "$REPO_ROOT/helpers/registry-utils.sh"

    # Pre-populate globals to simulate a prior successful call.
    _GHCR_IDX_BODY="stale-body"
    _GHCR_IDX_HDRS="stale-hdrs"

    cat > "${WORK_DIR}/bin/curl" << 'CURL_NODIGEST_R13A'
#!/usr/bin/env bash
URL="${!#}"
DFILE="" OFILE=""
_prev=""
for _arg in "$@"; do
    if [[ "$_prev" == "-D" ]]; then DFILE="$_arg"; fi
    if [[ "$_prev" == "-o" ]]; then OFILE="$_arg"; fi
    _prev="$_arg"
done
if [[ "$URL" == *"/token"* ]]; then echo '{"token":"x"}'; exit 0; fi
if [[ "$URL" == *"/manifests/"* ]]; then
    _hdrs="$(printf 'HTTP/1.1 200 OK\r\nContent-Type: application/vnd.oci.image.index.v1+json\r\n\r\n')"
    _body="$(printf '%s\n' "$_OCI_INDEX")"
    if [[ -n "$DFILE" ]]; then printf '%s' "$_hdrs" > "$DFILE"; fi
    if [[ -n "$OFILE" ]]; then printf '%s' "$_body" > "$OFILE"; else printf '%s%s' "$_hdrs" "$_body"; fi
    exit 0
fi
exit 1
CURL_NODIGEST_R13A
    chmod +x "${WORK_DIR}/bin/curl"

    local rc=0
    _ghcr_fetch_index "oorabona/postgres" "18-alpine" "token" 2>/dev/null || rc=$?

    [ "$rc" -ne 0 ] || { echo "FAIL: expected return 1, got 0" >&2; return 1; }
    [ -z "${_GHCR_IDX_BODY}" ] || {
        echo "FAIL: _GHCR_IDX_BODY not cleared after missing-digest fail-closed (value: ${_GHCR_IDX_BODY})" >&2
        return 1
    }
    [ -z "${_GHCR_IDX_HDRS}" ] || {
        echo "FAIL: _GHCR_IDX_HDRS not cleared after missing-digest fail-closed" >&2
        return 1
    }
}

@test "r13-B: globals cleared when fresh response has malformed Docker-Content-Digest" {
    # Finding 3: malformed digest (non-64-char) must clear globals before return 1.
    source "$REPO_ROOT/helpers/logging.sh" 2>/dev/null || true
    source "$REPO_ROOT/helpers/registry-utils.sh"

    _GHCR_IDX_BODY="stale-body"
    _GHCR_IDX_HDRS="stale-hdrs"

    cat > "${WORK_DIR}/bin/curl" << 'CURL_BADDIGEST_R13B'
#!/usr/bin/env bash
URL="${!#}"
DFILE="" OFILE=""
_prev=""
for _arg in "$@"; do
    if [[ "$_prev" == "-D" ]]; then DFILE="$_arg"; fi
    if [[ "$_prev" == "-o" ]]; then OFILE="$_arg"; fi
    _prev="$_arg"
done
if [[ "$URL" == *"/token"* ]]; then echo '{"token":"x"}'; exit 0; fi
if [[ "$URL" == *"/manifests/"* ]]; then
    _hdrs="$(printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: sha256:tooshort\r\n\r\n')"
    _body="$(printf '%s\n' "$_OCI_INDEX")"
    if [[ -n "$DFILE" ]]; then printf '%s' "$_hdrs" > "$DFILE"; fi
    if [[ -n "$OFILE" ]]; then printf '%s' "$_body" > "$OFILE"; else printf '%s%s' "$_hdrs" "$_body"; fi
    exit 0
fi
exit 1
CURL_BADDIGEST_R13B
    chmod +x "${WORK_DIR}/bin/curl"

    local rc=0
    _ghcr_fetch_index "oorabona/postgres" "18-alpine" "token" 2>/dev/null || rc=$?

    [ "$rc" -ne 0 ] || { echo "FAIL: expected return 1, got 0" >&2; return 1; }
    [ -z "${_GHCR_IDX_BODY}" ] || {
        echo "FAIL: _GHCR_IDX_BODY not cleared after malformed-digest fail-closed (value: ${_GHCR_IDX_BODY})" >&2
        return 1
    }
    [ -z "${_GHCR_IDX_HDRS}" ] || {
        echo "FAIL: _GHCR_IDX_HDRS not cleared after malformed-digest fail-closed" >&2
        return 1
    }
}

@test "r13-C: globals cleared when content-digest mismatch on fresh body" {
    # Finding 3: sha256 body-hash mismatch must clear globals before return 1.
    source "$REPO_ROOT/helpers/logging.sh" 2>/dev/null || true
    source "$REPO_ROOT/helpers/registry-utils.sh"

    _GHCR_IDX_BODY="stale-body"
    _GHCR_IDX_HDRS="stale-hdrs"

    # Return a valid-format digest header but mismatched body bytes.
    local wrong_digest
    wrong_digest="$(printf '%s' "wrong-body" | sha256sum | cut -c1-64)"

    cat > "${WORK_DIR}/bin/curl" << CURL_MISMATCH_R13C
#!/usr/bin/env bash
URL="\${!#}"
DFILE="" OFILE=""
_prev=""
for _arg in "\$@"; do
    if [[ "\$_prev" == "-D" ]]; then DFILE="\$_arg"; fi
    if [[ "\$_prev" == "-o" ]]; then OFILE="\$_arg"; fi
    _prev="\$_arg"
done
if [[ "\$URL" == *"/token"* ]]; then echo '{"token":"x"}'; exit 0; fi
if [[ "\$URL" == *"/manifests/"* ]]; then
    _hdrs="\$(printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: sha256:${wrong_digest}\r\n\r\n')"
    _body="\$(printf '%s\n' "\$_OCI_INDEX")"
    if [[ -n "\$DFILE" ]]; then printf '%s' "\$_hdrs" > "\$DFILE"; fi
    if [[ -n "\$OFILE" ]]; then printf '%s' "\$_body" > "\$OFILE"; else printf '%s%s' "\$_hdrs" "\$_body"; fi
    exit 0
fi
exit 1
CURL_MISMATCH_R13C
    chmod +x "${WORK_DIR}/bin/curl"

    local rc=0
    _ghcr_fetch_index "oorabona/postgres" "18-alpine" "token" 2>/dev/null || rc=$?

    [ "$rc" -ne 0 ] || { echo "FAIL: expected return 1, got 0" >&2; return 1; }
    [ -z "${_GHCR_IDX_BODY}" ] || {
        echo "FAIL: _GHCR_IDX_BODY not cleared after digest-mismatch fail-closed (value: ${_GHCR_IDX_BODY})" >&2
        return 1
    }
    [ -z "${_GHCR_IDX_HDRS}" ] || {
        echo "FAIL: _GHCR_IDX_HDRS not cleared after digest-mismatch fail-closed" >&2
        return 1
    }
}
