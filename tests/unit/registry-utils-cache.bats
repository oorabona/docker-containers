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
    # Per-arch now uses curl -o <file>; write body to OFILE when present,
    # else stdout (for tests that don't pass -o).
    # Use printf '%s' (no trailing newline) so the body bytes match the
    # sha256 digests declared in the fixture constants above.
    local _pa_body
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
    # Production uses `curl -o $pa_tmp`, so write to $OFILE when present.
    if [[ -n "$OFILE" ]]; then
        printf '%s' "$_TAMPERED" > "$OFILE"
    else
        printf '%s' "$_TAMPERED"
    fi
    exit 0
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
    _hdrs="$(printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: sha256:idx\r\n\r\n')"
    _body="$(printf '%s\n' "$_OCI_INDEX")"
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
    ! echo "$out" | grep -q 'unknown'
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

    # The shim writes the real index body (printf '%s\n') so the sha256 is:
    #   eecd94bb8a87c4ce52dca17a203c8516909a4c4939d5878915d077c1757937c2
    # Pre-seed the cache with a tampered body whose sha256 does NOT match.
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

    # The re-cached body file must NOT contain the tampered bytes.
    [ -f "$body_file" ]
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
    ! grep -q 'CURL_CALLED_UNEXPECTEDLY' "$CALLS"
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
    _hdrs="$(printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: sha256:idx\r\n\r\n')"
    _body="$(printf '%s\n' "$_OCI_INDEX")"
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
    ! grep -q 'PERARCH_FETCHED_UNEXPECTEDLY' "$CALLS"
}

# ---------------------------------------------------------------------------
# r6-test-1 (Defect A): _ghcr_fetch_index with digestless header cache file
# must return 0 (trust cache) rather than aborting under set -euo pipefail.
#
# Regression guard: the grep|sed|tr|head pipeline on Docker-Content-Digest was
# not guarded with || true.  Under set -euo pipefail an older cache file that
# lacked the header caused grep to exit 1, aborting the function before the
# "no verifiable digest → trust the cache" guard could run.
# ---------------------------------------------------------------------------

@test "r6: digestless cache header returns 0 under set -euo pipefail (Defect A)" {
    source "$REPO_ROOT/helpers/logging.sh" 2>/dev/null || true
    source "$REPO_ROOT/helpers/registry-utils.sh"

    # Pre-seed cache: body present, headers WITHOUT Docker-Content-Digest line
    # (simulates a cache file written before the r4 verify-on-hit fix landed).
    local idx_key
    idx_key="$(_ghcr_keyfile "oorabona/postgres:18-alpine")"
    local body_file="${GHCR_CACHE_DIR}/idx-${idx_key}.body"
    local hdrs_file="${GHCR_CACHE_DIR}/idx-${idx_key}.hdrs"
    mkdir -p "$GHCR_CACHE_DIR"
    printf '%s\n' "$_OCI_INDEX" > "$body_file"
    # No Docker-Content-Digest header — digestless header file.
    printf 'HTTP/1.1 200 OK\r\nContent-Type: application/vnd.oci.image.index.v1+json\r\n\r\n' \
        > "$hdrs_file"

    # Replace curl shim with a fail-fast one: if the cache hit path aborts and
    # falls through to the network branch, this sentinel fires.
    cat > "${WORK_DIR}/bin/curl" << 'CURL_NOSIG'
#!/usr/bin/env bash
echo "CURL_CALLED_UNEXPECTEDLY" >> "$CALLS"
exit 1
CURL_NOSIG
    chmod +x "${WORK_DIR}/bin/curl"

    # Run under set -euo pipefail inside a subshell to isolate exit semantics.
    run bash -c '
        set -euo pipefail
        source "'"$REPO_ROOT"'/helpers/logging.sh" 2>/dev/null || true
        source "'"$REPO_ROOT"'/helpers/registry-utils.sh"

        # Inject the pre-seeded cache dir.
        export GHCR_CACHE_DIR="'"$GHCR_CACHE_DIR"'"

        _ghcr_fetch_index "oorabona/postgres" "18-alpine" "token"
        echo "RC=$?"
        if [[ -n "$_GHCR_IDX_BODY" ]]; then echo "BODY_POPULATED"; fi
    '

    # Must exit 0: digestless header → trust cache → function returns 0.
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'RC=0'
    echo "$output" | grep -q 'BODY_POPULATED'

    # Curl must NOT have been called (cache hit path served the response).
    ! grep -q 'CURL_CALLED_UNEXPECTEDLY' "$CALLS"
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

@test "r6: cache-dir warning emitted exactly once across token + manifest_sizes calls (Defect B)" {
    # Run in a subshell; both stderr streams (token subshell + parent direct
    # call) are merged to stdout so bats captures them in $output.
    # NOTE: do NOT redirect the token subshell's stderr to the token variable —
    # the warning must flow to the parent stderr (fd 2) so it's countable.
    run bash -c '
        source "'"$REPO_ROOT"'/helpers/logging.sh" 2>/dev/null || true
        source "'"$REPO_ROOT"'/helpers/registry-utils.sh"

        export GHCR_CACHE_DIR="/proc/1/cannot-create-this-dir-$$"
        unset _GHCR_CACHE_DIR_WARNED

        # ghcr_get_token runs inside a $() subshell.  Without the TMPDIR
        # sentinel file, the parent would emit the warning again on the next
        # _ghcr_ensure_cachedir call because env-var exports do not propagate
        # child→parent.
        token=$(ghcr_get_token "oorabona/postgres") || true

        # Subsequent call that internally calls _ghcr_ensure_cachedir in the
        # parent context must NOT emit the warning a second time.
        ghcr_get_manifest_sizes "oorabona/postgres" "18-alpine" > /dev/null || true
    ' 2>&1

    # Must exit 0 overall.
    [ "$status" -eq 0 ]

    # Exactly 1 ::warning:: line must appear across both calls combined.
    local warning_count
    warning_count=$(echo "$output" | grep -c '::warning::' || true)
    [ "$warning_count" -eq 1 ]
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

@test "r7-A: malformed multi-sha256 header rejected — cache hit falls through to trust-cache" {
    source "$REPO_ROOT/helpers/logging.sh" 2>/dev/null || true
    source "$REPO_ROOT/helpers/registry-utils.sh"

    # Pre-seed cache: body with known sha256, headers carry a MALFORMED digest
    # containing two sha256 tokens — the old greedy parser would extract the
    # second (attacker-controlled) token; the strict parser must reject it.
    local idx_key
    idx_key="$(_ghcr_keyfile "oorabona/postgres:18-alpine")"
    local body_file="${GHCR_CACHE_DIR}/idx-${idx_key}.body"
    local hdrs_file="${GHCR_CACHE_DIR}/idx-${idx_key}.hdrs"
    mkdir -p "$GHCR_CACHE_DIR"

    # Body content doesn't matter for this test — we just need a non-empty file.
    printf '%s\n' "$_OCI_INDEX" > "$body_file"

    # Malformed header: two sha256 tokens.  The second token is all-zeros and
    # would NOT match the body's real sha256.  With the old greedy parser this
    # would extract the all-zeros token and the length-64 guard would pass,
    # leading to a mismatch and spurious eviction.  With the strict parser,
    # the whole header is rejected (cached_expected="") and verification is
    # skipped — the file is served directly (trust-cache path).
    printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: sha256:eecd94bb8a87c4ce52dca17a203c8516909a4c4939d5878915d077c1757937c2sha256:0000000000000000000000000000000000000000000000000000000000000000\r\n\r\n' \
        > "$hdrs_file"

    # Replace curl with a shim that fails — it must NOT be called because the
    # strict parser falls through to trust-cache (not to a network re-fetch).
    cat > "${WORK_DIR}/bin/curl" << 'CURL_FAIL_R7A'
#!/usr/bin/env bash
echo "CURL_CALLED_UNEXPECTEDLY_R7A" >> "$CALLS"
exit 1
CURL_FAIL_R7A
    chmod +x "${WORK_DIR}/bin/curl"

    local fetch_rc=0
    local stderr_log="${WORK_DIR}/r7a_stderr.log"
    _ghcr_fetch_index "oorabona/postgres" "18-alpine" "token" 2>"$stderr_log" || fetch_rc=$?

    # Must succeed: malformed header → no verification → trust cache.
    [ "$fetch_rc" -eq 0 ]

    # Curl must NOT have been called (trust-cache path, not network re-fetch).
    ! grep -q 'CURL_CALLED_UNEXPECTEDLY_R7A' "$CALLS"

    # No eviction warning — malformed header means we skip verification entirely.
    ! grep -q 'evicted' "$stderr_log"

    # _GHCR_IDX_BODY must be populated from the cached file.
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
