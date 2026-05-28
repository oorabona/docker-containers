#!/usr/bin/env bash

# Shared registry API utilities for Docker Hub and GHCR
# Eliminates duplication across ./make and generate-dashboard.sh
# Requires: curl, jq
# Optional: gh (for authenticated GHCR access)

# ---------------------------------------------------------------------------
# GHCR file-based memo cache
#
# WHY FILE-BASED: generate-dashboard.sh calls GHCR helpers via $(...)
# command substitution.  Bash forks a child process for every $(...);
# declare -gA writes in that child do NOT propagate back to the parent, so
# in-memory associative arrays are repopulated-then-discarded on every call
# (zero real HTTP reduction).  A file on the shared filesystem IS visible
# across all subshells produced by the same parent process.
#
# WHY $$ IS SAFE HERE: In bash, $$ inside a $(...) expansion still expands
# to the PID of the PARENT shell, not the fork.  The default cache dir
# therefore names the same directory from every subshell of a single run.
# ---------------------------------------------------------------------------

# Allow override for testing; default is a per-run tmpdir.
GHCR_CACHE_DIR="${GHCR_CACHE_DIR:-${TMPDIR:-/tmp}/ghcr-cache-$$}"

# Token TTL in seconds (GHCR pull tokens live ~5 min; 240 s leaves margin).
_GHCR_TOKEN_TTL=240

# Global out-vars populated by _ghcr_fetch_index (avoids subshell trailing-
# newline stripping that would corrupt binary-safe JSON via $(...) returns).
_GHCR_IDX_BODY=""
_GHCR_IDX_HDRS=""

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# Returns 0 iff the cache is enabled and usable: GHCR_CACHE_DIR is set to a
# non-empty string, the path exists as a real directory, and is writable.
# All cache read/write/invalidate sites MUST call this guard before building
# any "${GHCR_CACHE_DIR}/..." path.  When disabled (e.g. mktemp fallback
# failed and _ghcr_ensure_cachedir cleared GHCR_CACHE_DIR to ""), callers
# skip the cache entirely: reads return miss (forcing network), writes and
# invalidates are silent no-ops.  The functional API (token fetch, manifest
# fetch) still operates end-to-end in degraded mode.
_ghcr_cache_enabled() {
    [[ -n "${GHCR_CACHE_DIR:-}" ]] && [[ -d "${GHCR_CACHE_DIR}" ]] && [[ -w "${GHCR_CACHE_DIR}" ]]
}

# Validate that a cache directory is safe to trust: must be a real directory
# (not a symlink to an attacker-controlled path), owned by the current UID,
# AND have mode 0700 (no loose permissions).
# A dir with loose permissions — even one we own — must be treated as untrusted:
# a prior loose mode may have let an attacker plant body+hdrs files with a
# matching digest before we arrived. Silent chmod-to-700 only closes future
# writes; it cannot purge pre-existing poisoned content.  Reject and switch to a
# fresh mktemp dir instead — same response as symlink/foreign-owner.
# A dir owned by another UID is unrecoverable: an attacker controls the content.
# A symlink is unrecoverable: the target could point to hostile storage.
# Returns:
#   0 — safe (exists as a real dir, owned by us, mode 0700)
#   1 — symlink, wrong owner, or loose mode — caller MUST switch to fresh mktemp
_ghcr_validate_cachedir() {
    local d="$1"
    # Must exist as a directory.
    [[ -d "$d" ]] || return 1
    # Reject symlinks: the target could be a hostile location.
    [[ ! -L "$d" ]] || return 1
    # Owner must be the current process UID.
    local owner
    owner=$(stat -c '%u' "$d" 2>/dev/null) || return 1
    [[ "$owner" == "$(id -u)" ]] || return 1
    # Mode must be exactly 0700. A looser mode (e.g. 0755) signals that an older
    # code path or test fixture created this dir; its pre-existing content cannot
    # be trusted (attacker could have planted files before we chmod'd).  Reject
    # so the caller switches to a fresh mktemp dir with no prior content.
    local mode
    mode=$(stat -c '%a' "$d" 2>/dev/null) || return 1
    [[ "$mode" == "700" ]] || return 1
    return 0
}

# Create the cache directory lazily (idempotent; silent under set -e).
# 700 so token files are not world-readable on multi-user systems.
# umask 077 subshell ensures the dir is born 0700 even if the trailing chmod
# no-ops (exotic FS, restricted env).
#
# Security: if GHCR_CACHE_DIR already exists in any untrusted state (symlink,
# wrong owner, or loose mode != 0700), a warning is emitted and GHCR_CACHE_DIR
# is overridden to a fresh per-process mktemp directory.  This covers all three
# attack vectors uniformly: a loose-mode dir may already contain attacker-planted
# body+hdrs files; silent chmod-to-700 does not purge that content.
#
# If the private mktemp allocation itself fails, GHCR_CACHE_DIR is set to empty
# so the hostile original path is structurally unreachable; _ghcr_temp_file's
# TMPDIR-fallback handles transient files in degraded mode.
_ghcr_ensure_cachedir() {
    # If the directory already exists, validate it before trusting it.
    if [[ -e "${GHCR_CACHE_DIR}" ]]; then
        if ! _ghcr_validate_cachedir "${GHCR_CACHE_DIR}"; then
            # Symlink, wrong owner, or loose mode — untrusted; switch to fresh mktemp.
            if [[ -z "${_GHCR_CACHE_DIR_WARNED:-}" ]]; then
                echo "::warning::GHCR cache dir ${GHCR_CACHE_DIR} owner/mode untrusted; switching to private mktemp dir" >&2
                export _GHCR_CACHE_DIR_WARNED=1
            fi
            if ! GHCR_CACHE_DIR=$(mktemp -d -t ghcr-cache-private.XXXXXX 2>/dev/null); then
                # mktemp failed — clear GHCR_CACHE_DIR so the hostile path is never used;
                # _ghcr_temp_file's TMPDIR-fallback handles transient files in degraded mode.
                echo "::warning::Cannot allocate private cache dir; running fully uncached" >&2
                export GHCR_CACHE_DIR=""
                export _GHCR_CACHE_DIR_WARNED=1
                return 0
            fi
            chmod 700 "${GHCR_CACHE_DIR}" 2>/dev/null || true
            return 0
        fi
        return 0
    fi
    # Directory does not exist yet — create with safe mode.
    # TOCTOU fix: after mkdir -p succeeds, re-validate (owner/symlink/mode)
    # before trusting the result.  Between the [[ -e ]] check above and mkdir,
    # an attacker with write to the parent could race and plant an attacker-
    # controlled directory; mkdir -p would succeed on that hostile dir.
    # Post-validation detects the race and falls back to a private mktemp dir.
    if ( umask 077; mkdir -p "${GHCR_CACHE_DIR}" ) 2>/dev/null; then
        chmod 700 "${GHCR_CACHE_DIR}" 2>/dev/null || true
        # Post-validate: did we end up with a trusted dir (owner + mode + no symlink)?
        if _ghcr_validate_cachedir "${GHCR_CACHE_DIR}"; then
            return 0
        fi
        # Race condition detected — created dir is not fully trusted; switch to mktemp.
        if [[ -z "${_GHCR_CACHE_DIR_WARNED:-}" ]]; then
            echo "::warning::GHCR cache dir ${GHCR_CACHE_DIR} post-mkdir validation failed (TOCTOU?); switching to private mktemp dir" >&2
            export _GHCR_CACHE_DIR_WARNED=1
        fi
        if GHCR_CACHE_DIR=$(mktemp -d -t ghcr-cache-private.XXXXXX 2>/dev/null); then
            chmod 700 "${GHCR_CACHE_DIR}" 2>/dev/null || true
            return 0
        fi
        echo "::warning::Cannot allocate private cache dir after TOCTOU; running fully uncached" >&2
        export GHCR_CACHE_DIR=""
        export _GHCR_CACHE_DIR_WARNED=1
        return 0
    fi
    # Cache directory creation failed → run in degraded (uncached) mode.
    # Emit a one-time ::warning:: for CI diagnostics, then return success
    # so callers do not interpret this as a fatal error.  The actual cache
    # writes will fail benignly downstream (best-effort) and force fresh
    # network fetches each call.
    #
    # Child→parent: `export` does NOT propagate from a $() subshell back to
    # the parent process (empirically verified: each $() is a fork; env changes
    # in the child are invisible to the parent).  Use a TMPDIR-keyed sentinel
    # file so the "warn once" dedup works when _ghcr_ensure_cachedir is called
    # from both a $() subshell (e.g. ghcr_get_token) AND the parent directly.
    #
    # Sentinel hygiene: the file is cleaned up via a best-effort find sweep of
    # sentinels older than 24 h on first call, preventing accumulation from
    # prior runs whose PIDs have been recycled.
    local _sentinel="${TMPDIR:-/tmp}/.ghcr_cache_warned.$$"
    if [[ ! -f "$_sentinel" ]]; then
        echo "::warning::Cannot create GHCR cache dir ${GHCR_CACHE_DIR}; running in degraded (uncached, slow) mode" >&2
        touch "$_sentinel" 2>/dev/null || true
        # Best-effort cleanup of stale sentinels from previous runs (>24h old).
        find "${TMPDIR:-/tmp}" -maxdepth 1 -name '.ghcr_cache_warned.*' -mmin +1440 \
            -delete 2>/dev/null || true
    fi
    export _GHCR_CACHE_DIR_WARNED=1
    return 0
}

# Sanitize a string into a filesystem-safe filename component.
# Replaces every char not in [A-Za-z0-9._-] with _.
# Usage: _ghcr_keyfile <string>   (prints result)
_ghcr_keyfile() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

# Verify that a cached file's sha256 matches an expected digest hex.
# Usage: _ghcr_verify_content_digest <file> <expected_sha256_hex>
# Returns 0 on match, 1 on mismatch or invalid input.
# expected_sha256_hex must be the bare 64-char lowercase hex — NOT prefixed
# with "sha256:". Callers strip the prefix from registry-provided digests.
_ghcr_verify_content_digest() {
    local file="$1" expected="$2"
    [[ -f "$file" && -n "$expected" ]] || return 1
    local actual
    actual=$(sha256sum -- "$file" 2>/dev/null | cut -d' ' -f1)
    [[ -n "$actual" && "$actual" == "$expected" ]]
}

# Return a path to a writable temp file.
# Prefers ${GHCR_CACHE_DIR} (same filesystem → atomic mv into cache is cheap).
# Falls back to system TMPDIR when the cache dir is unwritable, enabling
# degraded (uncached) mode to complete the fetch and return data to callers.
# Usage: _ghcr_temp_file <suffix>   (prints path on stdout)
# Returns 0 on success, 1 only when neither cache dir nor system TMPDIR is writable.
_ghcr_temp_file() {
    local suffix="${1:-tmp}"
    local f
    # Prefer cache dir (same FS → atomic mv works cheaply)
    if [[ -d "${GHCR_CACHE_DIR}" && -w "${GHCR_CACHE_DIR}" ]]; then
        f=$(mktemp "${GHCR_CACHE_DIR}/${suffix}.XXXXXX" 2>/dev/null) && { printf '%s\n' "$f"; return 0; }
    fi
    # Fallback: system TMPDIR
    f=$(mktemp -t "ghcr-${suffix}.XXXXXX" 2>/dev/null) && { printf '%s\n' "$f"; return 0; }
    return 1
}

# ---------------------------------------------------------------------------
# No EXIT trap registered here.
# Cache dir is ${TMPDIR:-/tmp}/ghcr-cache-$$, intentionally left in place:
#   (1) CI runners are ephemeral — /tmp is wiped between runs automatically.
#   (2) A sourced-file EXIT trap is non-composable: it clobbers the host
#       script's own EXIT trap (generate-dashboard.sh registers one after
#       sourcing this file), so cleanup would never run anyway.
# GHCR_CACHE_DIR env override is still honoured (e.g. for tests).
# ---------------------------------------------------------------------------

# --- GHCR (GitHub Container Registry) ---

# Get a GHCR registry token (file-memoized: TTL 240 s).
# Tries authenticated (gh auth) first, falls back to anonymous.
# Usage: ghcr_get_token "owner/repo"
# Output: bearer token string or ""
#
# Note: tokens have no content-addressable digest (they are opaque bearer
# tokens). The cache safety bound is the existing TTL guard — verified by
# the token's embedded expiry, not by content hashing. This tier is
# explicitly EXEMPT from the content-digest verification applied to the
# index and per-arch tiers.
ghcr_get_token() {
    local image_path="$1"  # owner/repo (without ghcr.io/ prefix)

    _ghcr_ensure_cachedir

    local keyfile=""

    # Cache read: only when cache is enabled (GHCR_CACHE_DIR set, dir exists, writable).
    # When disabled (empty GHCR_CACHE_DIR), skip to network fetch directly.
    if _ghcr_cache_enabled; then
        keyfile="${GHCR_CACHE_DIR}/token-$(_ghcr_keyfile "${image_path}")"

        # HIT: file exists, non-empty, AND modified < TTL seconds ago.
        # find -mmin -<N> uses minutes; 240 s = 4 min.
        # We use find to avoid GNU-stat dependency.
        if [[ -s "$keyfile" ]]; then
            local fresh
            fresh=$(find "$keyfile" -mmin "-4" -print -quit 2>/dev/null)
            if [[ -n "$fresh" ]]; then
                cat "$keyfile"
                return 0
            fi
        fi
    fi

    local token=""

    # Try authenticated token via gh CLI
    local gh_token
    if gh_token=$(gh auth token 2>/dev/null) && [[ -n "$gh_token" ]]; then
        local owner
        owner=$(echo "$image_path" | cut -d'/' -f1)
        token=$(curl -s --connect-timeout 5 --max-time 10 \
            "https://ghcr.io/token?service=ghcr.io&scope=repository:${image_path}:pull" \
            -u "${owner}:${gh_token}" 2>/dev/null | jq -r '.token // empty' 2>/dev/null)
    fi

    # Fall back to anonymous token
    if [[ -z "$token" ]]; then
        token=$(curl -s --connect-timeout 5 --max-time 10 \
            "https://ghcr.io/token?scope=repository:${image_path}:pull" 2>/dev/null | \
            jq -r '.token // empty' 2>/dev/null)
    fi

    # Cache write: only non-empty tokens and only when cache is enabled.
    # When cache is disabled, token is returned but not persisted (degraded mode).
    # (atomic write to avoid torn reads; umask 077 subshell ensures tmp is born
    # 0600 even if chmod fails; chmod kept as belt-and-suspenders; mv preserves mode.)
    if [[ -n "$token" && -n "$keyfile" ]] && _ghcr_cache_enabled; then
        ( umask 077; printf '%s' "$token" > "${keyfile}.tmp.$$" ) 2>/dev/null && chmod 600 "${keyfile}.tmp.$$" 2>/dev/null && mv -f "${keyfile}.tmp.$$" "$keyfile" 2>/dev/null || true
    fi

    echo "$token"
}

# Invalidate the cached token for an image_path (call after auth-failure detected).
# No-op when cache is disabled (_ghcr_cache_enabled returns false).
# Usage: ghcr_invalidate_token "owner/repo"
ghcr_invalidate_token() {
    local ip="$1"
    _ghcr_cache_enabled || return 0
    local keyfile
    keyfile="${GHCR_CACHE_DIR}/token-$(_ghcr_keyfile "${ip}")"
    rm -f "$keyfile" 2>/dev/null || true
}

# Internal helper: fetch the index manifest for image:tag, with file-based caching.
# Populates globals: _GHCR_IDX_BODY _GHCR_IDX_HDRS
# Returns 0 on success (non-empty body), 1 on failure.
# Usage: _ghcr_fetch_index "owner/repo" "tag" "token"
_ghcr_fetch_index() {
    local image_path="$1"
    local tag="$2"
    local token="$3"

    _ghcr_ensure_cachedir

    local key_safe
    key_safe="$(_ghcr_keyfile "${image_path}:${tag}")"
    local body_file="" hdrs_file=""
    if _ghcr_cache_enabled; then
        body_file="${GHCR_CACHE_DIR}/idx-${key_safe}.body"
        hdrs_file="${GHCR_CACHE_DIR}/idx-${key_safe}.hdrs"
    fi

    # HIT: both files present and body non-empty (no TTL — runs are short,
    # tags don't change mid-run).
    # Verify content-digest on hit to catch post-admit corruption (disk error,
    # PID-reuse conflict, OOM mid-write, manual tampering).  A mismatch evicts
    # both cache files and falls through to the network fetch branch below.
    if [[ -s "$body_file" && -f "$hdrs_file" ]]; then
        local cached_expected hdr_line
        hdr_line=$(grep -i '^Docker-Content-Digest:' "$hdrs_file" 2>/dev/null || true)
        cached_expected=""
        if [[ -n "$hdr_line" ]]; then
            # Strict single-token extraction: reject headers with multiple sha256:
            # tokens (e.g. sha256:<good>sha256:<bad>) which greedy patterns would
            # silently parse to the last token, bypassing digest verification.
            local _hdr_norm
            _hdr_norm=$(printf '%s' "$hdr_line" | tr -d '\r\n')
            if [[ "$_hdr_norm" =~ ^[Dd]ocker-[Cc]ontent-[Dd]igest:[[:space:]]*sha256:([a-f0-9]{64})[[:space:]]*$ ]]; then
                cached_expected="${BASH_REMATCH[1]}"
            fi
            # If pattern doesn't match exactly (malformed, multiple tokens, wrong
            # length), cached_expected stays "" → length guard below skips
            # verification → falls through to trust-cache path (same as no header).
        fi
        # Only trust the cache when we have a full 64-char lowercase hex digest to
        # verify against.  A missing, malformed, or short digest (e.g. the default
        # shim's "sha256:idx", or a tampered/truncated hdrs file) means the entry
        # is unverifiable — treat as stale, evict, and fall through to a network
        # refetch.  Self-healing: legacy cache files written before the r4 verify
        # fix refetch once and become verifiable on the next hit.
        if [[ "${#cached_expected}" -eq 64 ]]; then
            if _ghcr_verify_content_digest "$body_file" "$cached_expected"; then
                _GHCR_IDX_BODY="$(cat "$body_file")"
                _GHCR_IDX_HDRS="$(cat "$hdrs_file")"
                return 0
            fi
            # Digest present but mismatch → evict and fall through to network fetch.
            rm -f "$body_file" "$hdrs_file" 2>/dev/null || true
            echo "::warning::Cached index body content-digest mismatch; evicted, refetching ${image_path}:${tag}" >&2
        else
            # No verifiable digest (missing, malformed, or short) → evict and refetch.
            # Trusting an unverifiable entry would let an attacker who can write to
            # GHCR_CACHE_DIR serve poisoned content by simply removing the digest line.
            rm -f "$body_file" "$hdrs_file" 2>/dev/null || true
            echo "::warning::Cached index lacks verifiable Docker-Content-Digest; evicted, refetching ${image_path}:${tag}" >&2
        fi
    fi

    # Full Accept union satisfying both ghcr_get_manifest_sizes (needs body with .manifests)
    # and ghcr_get_multi_arch_digests (needs Docker-Content-Digest header + body).
    local accept="application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"

    # Use _ghcr_temp_file for body/hdrs so curl writes raw bytes directly to
    # file (no command-substitution stripping of trailing newlines, which would
    # break the sha256 content-digest verification added below).
    # _ghcr_temp_file prefers GHCR_CACHE_DIR (same FS → atomic mv is cheap)
    # but falls back to system TMPDIR when the cache dir is unwritable, so
    # degraded (uncached) mode can still complete the fetch and return data.
    # Genuinely fatal only when neither location is writable.
    local body_tmp hdrs_tmp
    body_tmp=$(_ghcr_temp_file ".idx-body") || { _GHCR_IDX_BODY=""; _GHCR_IDX_HDRS=""; return 1; }
    hdrs_tmp=$(_ghcr_temp_file ".idx-hdrs") || { rm -f "$body_tmp" 2>/dev/null || true; _GHCR_IDX_BODY=""; _GHCR_IDX_HDRS=""; return 1; }

    local curl_rc=0
    curl -sS -D "$hdrs_tmp" -o "$body_tmp" --connect-timeout 5 --max-time 10 \
        -H "Authorization: Bearer $token" \
        -H "Accept: $accept" \
        "https://ghcr.io/v2/${image_path}/manifests/${tag}" 2>/dev/null || curl_rc=$?

    if [[ "$curl_rc" -ne 0 || ! -s "$body_tmp" ]]; then
        rm -f "$body_tmp" "$hdrs_tmp" 2>/dev/null || true
        _GHCR_IDX_BODY=""
        _GHCR_IDX_HDRS=""
        return 1
    fi

    # Populate out-vars for callers (read even on partial success below).
    local hdrs body
    hdrs=$(cat "$hdrs_tmp" 2>/dev/null || true)
    body=$(cat "$body_tmp" 2>/dev/null || true)
    _GHCR_IDX_BODY="$body"
    _GHCR_IDX_HDRS="$hdrs"

    # Classify the response before deciding whether to cache.
    local http_status
    http_status=$(printf '%s' "$hdrs" | grep -m1 -oE '^HTTP/[^ ]+ [0-9]+' | grep -oE '[0-9]+$' || true)

    # A "good" response is: body non-empty, HTTP 2xx status, body parses as a
    # JSON object, AND body is NOT a JSON .errors envelope.
    # Requiring 2xx prevents cache-poisoning from 404/429/3xx responses that
    # carry a JSON body without a registry .errors envelope (e.g.
    # {"message":"Not Found"} or a rate-limiter JSON).
    # Non-JSON bodies (HTML error pages, truncated responses, proxy text) must
    # NOT be cached — they would poison every subsequent lookup for this tag.
    # ${http_status:-200}: if status-line parsing yields nothing (HTTP/2 edge
    # where grep already handles "HTTP/2 200"), default to 200 so a genuine
    # 200 whose status wasn't captured is still eligible for caching.
    local is_good=0
    if [[ -n "$body" ]]; then
        case "${http_status:-200}" in
            2[0-9][0-9])
                # Require body to be a JSON object first (reject non-JSON
                # bodies such as HTML error pages or truncated proxy responses).
                if ! printf '%s' "$body" | jq -e 'type=="object"' >/dev/null 2>&1; then
                    is_good=0
                # Body might still be a registry error JSON (e.g. {errors:[...]})
                elif printf '%s' "$body" | jq -e 'has("errors")' >/dev/null 2>&1; then
                    is_good=0
                else
                    is_good=1
                fi
                ;;
            *) is_good=0 ;;
        esac
    fi

    # Only cache genuinely good responses.
    if [[ "$is_good" -eq 1 ]]; then
        # Content-digest verification: extract Docker-Content-Digest from response
        # headers and verify the stored body bytes hash to the same value.
        # On mismatch: warn, clean up temps, and return 1.
        # The caller already has data in _GHCR_IDX_BODY/_GHCR_IDX_HDRS but a
        # digest mismatch signals a corrupt or tampered response — do not use it.
        local idx_digest_header idx_digest_hex
        idx_digest_header=$(printf '%s' "$hdrs" | grep -iE '^docker-content-digest:' 2>/dev/null | head -1 | tr -d '\r' || true)
        if [[ -z "$idx_digest_header" ]]; then
            # Fresh response carries no Docker-Content-Digest header.  GHCR is
            # documented to always send this header on manifest responses; its
            # absence signals a stripped/tampered response or a non-compliant
            # registry path.  Fail-closed: do not return unverified data to the
            # caller, as that would allow a digest-stripping bypass for the
            # current run even without cache admission.
            echo "::warning::Fresh GHCR response for ${image_path}:${tag} lacks Docker-Content-Digest; refusing" >&2
            rm -f "$body_tmp" "$hdrs_tmp" 2>/dev/null || true
            return 1
        fi
        # Strict single-token extraction: anchored regex rejects headers with
        # multiple sha256: tokens (e.g. sha256:<good>sha256:<bad>) that greedy
        # ##*sha256: would silently parse to the last token.
        if [[ "$idx_digest_header" =~ ^[Dd]ocker-[Cc]ontent-[Dd]igest:[[:space:]]*sha256:([a-f0-9]{64})[[:space:]]*$ ]]; then
            idx_digest_hex="${BASH_REMATCH[1]}"
        else
            idx_digest_hex=""
        fi
        if [[ "${#idx_digest_hex}" -ne 64 ]]; then
            # Header present but malformed (wrong length, non-hex, multiple tokens).
            # Same fail-closed treatment as missing: refuse unverified body.
            echo "::warning::Fresh GHCR response for ${image_path}:${tag} has malformed Docker-Content-Digest; refusing" >&2
            rm -f "$body_tmp" "$hdrs_tmp" 2>/dev/null || true
            return 1
        fi
        if ! _ghcr_verify_content_digest "$body_tmp" "$idx_digest_hex"; then
            echo "::warning::GHCR index cache content-digest mismatch for ${image_path}:${tag}; body not cached" >&2
            rm -f "$body_tmp" "$hdrs_tmp" 2>/dev/null || true
            return 1
        fi

        # Best-effort cache write: move verified tmp files into place.
        # Only when cache is enabled (body_file/hdrs_file are non-empty paths).
        # When body_tmp/hdrs_tmp are in GHCR_CACHE_DIR (normal path), mv is
        # atomic on the same filesystem.  When they are in system TMPDIR
        # (degraded path), mv may cross filesystems and fail — that is fine:
        # data has already been returned via out-vars above; caching is
        # opportunistic.  chmod 600 belt-and-suspenders.
        chmod 600 "$body_tmp" "$hdrs_tmp" 2>/dev/null || true
        if [[ -n "$body_file" ]] && _ghcr_cache_enabled; then
            mv -f "$body_tmp" "$body_file" 2>/dev/null || rm -f "$body_tmp" 2>/dev/null || true
            mv -f "$hdrs_tmp" "$hdrs_file" 2>/dev/null || rm -f "$hdrs_tmp" 2>/dev/null || true
        else
            rm -f "$body_tmp" "$hdrs_tmp" 2>/dev/null || true
        fi
        return 0
    fi

    rm -f "$body_tmp" "$hdrs_tmp" 2>/dev/null || true
    return 1
}

# Invalidate the cached index for an image_path:tag (call before retrying after
# an auth failure, to force a genuine network re-fetch instead of a cached-401 hit).
# No-op when cache is disabled (_ghcr_cache_enabled returns false).
# Usage: _ghcr_invalidate_index "owner/repo" "tag"
_ghcr_invalidate_index() {
    _ghcr_cache_enabled || return 0
    local k
    k="$(_ghcr_keyfile "${1}:${2}")"
    rm -f "${GHCR_CACHE_DIR}/idx-${k}.body" "${GHCR_CACHE_DIR}/idx-${k}.hdrs" 2>/dev/null || true
}

# Get manifest sizes for a GHCR image (all architectures)
# Output: one line per arch, format "arch:total_bytes"
# Usage: ghcr_get_manifest_sizes "owner/repo" "tag"
ghcr_get_manifest_sizes() {
    local image_path="$1"  # owner/repo (without ghcr.io/ prefix)
    local tag="${2:-latest}"

    local token
    token=$(ghcr_get_token "$image_path")
    [[ -z "$token" ]] && return 1

    # Fetch index via shared file-memoized helper.
    if ! _ghcr_fetch_index "$image_path" "$tag" "$token"; then
        # Auth failure or empty body — retry once with a fresh token.
        ghcr_invalidate_token "$image_path"
        _ghcr_invalidate_index "$image_path" "$tag"
        token=$(ghcr_get_token "$image_path")
        [[ -z "$token" ]] && return 1
        _ghcr_fetch_index "$image_path" "$tag" "$token" || return 1
    fi

    local manifest="$_GHCR_IDX_BODY"

    # Check for UNAUTHORIZED error in body and retry once.
    if printf '%s' "$manifest" | jq -e '.errors[]?.code == "UNAUTHORIZED"' >/dev/null 2>&1; then
        ghcr_invalidate_token "$image_path"
        _ghcr_invalidate_index "$image_path" "$tag"
        token=$(ghcr_get_token "$image_path")
        [[ -z "$token" ]] && return 1
        _ghcr_fetch_index "$image_path" "$tag" "$token" || return 1
        manifest="$_GHCR_IDX_BODY"
    fi

    # Any .errors envelope → failure.
    if printf '%s' "$manifest" | jq -e 'type=="object" and has("errors")' >/dev/null 2>&1; then
        return 1
    fi

    # Body must be valid JSON to proceed.
    if ! printf '%s' "$manifest" | jq -e 'type=="object"' >/dev/null 2>&1; then
        return 1
    fi

    # Multi-platform manifest list
    if printf '%s' "$manifest" | jq -e 'has("manifests")' >/dev/null 2>&1; then
        local manifests_data
        manifests_data=$(printf '%s' "$manifest" | jq -r '.manifests[] | "\(.platform.architecture):\(.digest)"' 2>/dev/null)

        # Finding 1 fix: accumulate validated arch:size lines into a buffer.
        # Do NOT emit per-arch lines incrementally — if ANY sub-manifest fetch
        # returns an invalid/non-JSON/error body, abort with return 1 and zero
        # stdout (all-or-nothing contract).  Only print the buffer when ALL
        # per-arch sub-manifests have been validated and sized successfully.
        # Per-arch cache tier: keyed by immutable content digest → no TTL.
        # Dedicated perarch/ subdir is provably disjoint from the flat idx-* files
        # removed by _ghcr_invalidate_index (different directory depth; exact-path
        # rm -f "${GHCR_CACHE_DIR}/idx-${k}.body" can never reach a subdir entry).
        # Create cache root + subdir once before the loop (not per-iteration).
        # Only when cache is enabled — skip mkdir/chmod when GHCR_CACHE_DIR is empty.
        _ghcr_ensure_cachedir
        if _ghcr_cache_enabled; then
            ( umask 077; mkdir -p "${GHCR_CACHE_DIR}/perarch" ) 2>/dev/null || true
            chmod 700 "${GHCR_CACHE_DIR}/perarch" 2>/dev/null || true
        fi
        local size_buffer=""
        while IFS=':' read -r arch digest_prefix digest_hash; do
            [[ -z "$arch" || -z "$digest_hash" ]] && continue
            [[ "$arch" == "unknown" ]] && continue
            # Strict digest validation BEFORE any network attempt.
            # digest_prefix must be "sha256" — non-sha256 algorithms (sha512, etc.)
            # are not supported and a malformed/unexpected prefix is a hard error,
            # not a silent skip, to preserve the all-or-nothing contract.
            # digest_hash must be exactly 64 lowercase hex chars.
            # Both checks apply to all non-"unknown" platforms; a partially-valid
            # manifest list (valid arm64, malformed amd64) must fail hard.
            if [[ "$digest_prefix" != "sha256" ]]; then
                echo "::warning::GHCR per-arch refusing non-sha256 digest prefix '${digest_prefix}' for platform '${arch}' (${image_path})" >&2
                return 1
            fi
            if ! [[ "$digest_hash" =~ ^[a-f0-9]{64}$ ]]; then
                echo "::warning::GHCR per-arch malformed digest hash for platform '${arch}' (${image_path}): ${digest_hash}" >&2
                return 1
            fi

            local pa_file pa_hit
            # Build pa_file path only when cache is enabled; empty string disables
            # the cache hit branch below ([[ -s "" ]] is false) and prevents writing
            # a path rooted at / when GHCR_CACHE_DIR is empty.
            if _ghcr_cache_enabled; then
                pa_file="${GHCR_CACHE_DIR}/perarch/$(_ghcr_keyfile "${image_path}@${digest_prefix}:${digest_hash}").body"
            else
                pa_file=""
            fi
            pa_hit=0

            # pa_src is the file whose bytes are used for validation AND jq parsing.
            # For cache hits, pa_src=pa_file (existing body on disk).
            # For cache misses, pa_src=pa_tmp (curl writes raw bytes directly here).
            # Using a file as the source of truth for both verification and parsing
            # avoids $() command-substitution, which strips trailing newlines.
            # OCI/Docker digests are over EXACT raw bytes — a valid manifest served
            # with a trailing newline would hash differently after $() stripping,
            # causing legitimate images to be rejected as "tampered".
            local pa_src pa_tmp
            pa_src=""
            pa_tmp=""
            if [[ -s "$pa_file" ]]; then
                # Cache HIT: verify content-digest before trusting the file.
                # Evict on mismatch to catch post-admit corruption (disk error,
                # PID-reuse conflict, OOM mid-write, manual tampering), then
                # fall through to the network-fetch branch below (pa_hit stays 0).
                if _ghcr_verify_content_digest "$pa_file" "$digest_hash"; then
                    pa_src="$pa_file"
                    pa_hit=1
                else
                    rm -f "$pa_file" 2>/dev/null || true
                    echo "::warning::Cached per-arch body content-digest mismatch; evicted ${image_path}@sha256:${digest_hash}" >&2
                fi
            fi
            if [[ "$pa_hit" -eq 0 ]]; then
                # Cache MISS (or eviction above): allocate temp file and fetch.
                # _ghcr_temp_file is race-proof (mktemp, mode 0600).
                # When cache dir is unwritable it falls back to system TMPDIR.
                pa_tmp=$(_ghcr_temp_file "perarch-.tmp" 2>/dev/null) || {
                    echo "::warning::GHCR per-arch cannot allocate temp file for ${image_path}@${digest_prefix}:${digest_hash}" >&2
                    return 1
                }
                # curl -o writes raw network bytes directly to file — no $() stripping.
                if ! curl -sS -fL --connect-timeout 5 --max-time "${CURL_MAX_TIME:-30}" \
                        -H "Authorization: Bearer $token" \
                        -H "Accept: application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json" \
                        -o "$pa_tmp" \
                        "https://ghcr.io/v2/${image_path}/manifests/${digest_prefix}:${digest_hash}" 2>/dev/null; then
                    rm -f "$pa_tmp" 2>/dev/null || true
                    echo "::warning::GHCR per-arch fetch failed for ${image_path}@${digest_prefix}:${digest_hash}" >&2
                    return 1
                fi
                # Content-digest verification on raw bytes BEFORE any parsing.
                # The cache key digest_hash is the registry's sha256 of the manifest
                # bytes. A mismatch means corruption or tampered response — abort.
                if ! _ghcr_verify_content_digest "$pa_tmp" "$digest_hash"; then
                    echo "::warning::GHCR per-arch content-digest mismatch for ${image_path}@${digest_prefix}:${digest_hash}; rejecting body" >&2
                    rm -f "$pa_tmp" 2>/dev/null || true
                    return 1
                fi
                pa_src="$pa_tmp"
            fi

            # Validate: body must be non-empty, parse as a JSON object, not an
            # .errors envelope, and carry size-bearing structure (config or layers).
            # An invalid body → abort the whole function (return 1, zero stdout).
            # These gates also defensively re-validate cached bodies (free, no network).
            # All jq reads come from $pa_src (file), not from a $()-captured string.
            if [[ ! -s "$pa_src" ]]; then
                rm -f "$pa_tmp" 2>/dev/null || true
                return 1
            fi
            if ! jq -e 'type=="object"' < "$pa_src" >/dev/null 2>&1; then
                rm -f "$pa_tmp" 2>/dev/null || true
                return 1
            fi
            if jq -e 'type=="object" and has("errors")' < "$pa_src" >/dev/null 2>&1; then
                rm -f "$pa_tmp" 2>/dev/null || true
                return 1
            fi
            if ! jq -e 'has("config") or has("layers")' < "$pa_src" >/dev/null 2>&1; then
                rm -f "$pa_tmp" 2>/dev/null || true
                return 1
            fi

            # Admission: promote pa_tmp → pa_file after all 4 gates pass.
            # Cache hits (pa_hit=1) already live at pa_file; no mv needed.
            if [[ "$pa_hit" -eq 0 && -n "$pa_tmp" ]]; then
                chmod 600 "$pa_tmp" 2>/dev/null || true
                if mv -f "$pa_tmp" "$pa_file" 2>/dev/null; then
                    pa_src="$pa_file"
                fi
                # mv failed (cross-FS fallback) — pa_src stays as pa_tmp;
                # data is returned but not persisted; temp cleaned up below.
            fi

            local total_size
            total_size=$(jq '[.config.size // 0] + [.layers[]?.size // 0] | add // 0' < "$pa_src" 2>/dev/null)
            # Clean up pa_tmp if mv failed (pa_src still points to it).
            [[ "$pa_src" == "$pa_tmp" && -n "$pa_tmp" ]] && rm -f "$pa_tmp" 2>/dev/null || true
            # Append to buffer (valid parse → emit even if arithmetic yields 0).
            size_buffer="${size_buffer}${arch}:${total_size:-0}"$'\n'
        done <<< "$manifests_data"

        # All platforms validated — emit the accumulated buffer.
        printf '%s' "$size_buffer"
    else
        # Single manifest (no manifest list): only emit if it looks like a real
        # manifest (has .config, .layers, or .mediaType). Anything else is not
        # a manifest body — return 1 rather than emitting a bogus amd64:0.
        if ! printf '%s' "$manifest" | jq -e 'has("config") or has("layers") or has("mediaType")' >/dev/null 2>&1; then
            return 1
        fi
        local total_size
        total_size=$(printf '%s' "$manifest" | jq '[.config.size // 0] + [.layers[]?.size // 0] | add // 0' 2>/dev/null)
        echo "amd64:${total_size:-0}"
    fi
}

# Get multi-arch index digest + per-platform manifest digests for a GHCR image.
# Usage: ghcr_get_multi_arch_digests "<owner>/<image>" "<tag>"
# Output (JSON to stdout):
#   {
#     "index_digest": "sha256:...",          // index manifest digest
#     "manifest_digest_amd64": "sha256:...", // null if not present in index
#     "manifest_digest_arm64": "sha256:..."  // null if not present in index
#   }
# For single-arch images (no .manifests array), emits:
#   {"index_digest": "<digest>", "manifest_digest_amd64": null, "manifest_digest_arm64": null}
# On API failure: emits all-null JSON. Never exits non-zero. Always emits valid JSON.
ghcr_get_multi_arch_digests() {
    local image="$1"  # e.g. "oorabona/postgres"
    local tag="$2"    # e.g. "18-alpine"

    local token
    token=$(ghcr_get_token "$image" 2>/dev/null)

    if [[ -z "$token" ]]; then
        echo '{"index_digest":null,"manifest_digest_amd64":null,"manifest_digest_arm64":null}'
        return 0
    fi

    # Fetch the index manifest via shared file-memoized helper.
    # _ghcr_fetch_index populates _GHCR_IDX_BODY and _GHCR_IDX_HDRS.
    # On failure (auth error, network error): one-shot recovery — invalidate token+cache,
    # re-fetch token, retry once.  Mirrors ghcr_get_manifest_sizes recovery sequence.
    if ! _ghcr_fetch_index "$image" "$tag" "$token" 2>/dev/null; then
        ghcr_invalidate_token "$image"
        _ghcr_invalidate_index "$image" "$tag"
        token=$(ghcr_get_token "$image" 2>/dev/null)
        if [[ -z "$token" ]] || ! _ghcr_fetch_index "$image" "$tag" "$token" 2>/dev/null; then
            echo '{"index_digest":null,"manifest_digest_amd64":null,"manifest_digest_arm64":null}'
            return 0
        fi
    fi

    local body="$_GHCR_IDX_BODY"
    local headers="$_GHCR_IDX_HDRS"

    if [[ -z "$body" ]]; then
        echo '{"index_digest":null,"manifest_digest_amd64":null,"manifest_digest_arm64":null}'
        return 0
    fi

    # Validate body is a JSON object before deriving any field.
    # A non-JSON body (truncated/error text) or a registry .errors envelope
    # must produce the all-null result — never derive header or body fields
    # from an invalid payload.
    if ! printf '%s' "$body" | jq -e 'type=="object"' >/dev/null 2>&1; then
        echo '{"index_digest":null,"manifest_digest_amd64":null,"manifest_digest_arm64":null}'
        return 0
    fi
    if printf '%s' "$body" | jq -e 'has("errors")' >/dev/null 2>&1; then
        echo '{"index_digest":null,"manifest_digest_amd64":null,"manifest_digest_arm64":null}'
        return 0
    fi

    # Index digest from the Docker-Content-Digest header.
    # || true guards against grep returning 1 (no match) under set -euo pipefail.
    local index_digest
    index_digest=$(printf '%s' "$headers" | grep -iE '^docker-content-digest:' 2>/dev/null | awk '{print $2}' | tr -d '\r' | head -1 || true)
    [[ -z "$index_digest" ]] && index_digest="null"

    # Per-arch manifest digests from the body (.manifests[].{platform.architecture, digest}).
    # jq returns empty output (not "null") when the key is absent, so we test with [[ -z ]].
    # For single-manifest images (no .manifests, but a real manifest with .config/.layers/.mediaType),
    # per-arch digests are null — only index_digest is emitted (from the header above).
    local amd64_digest arm64_digest
    amd64_digest=$(printf '%s' "$body" | jq -r 'if .manifests then (.manifests[] | select(.platform.architecture == "amd64" and .platform.os == "linux") | .digest) else empty end' 2>/dev/null | head -1 || true)
    arm64_digest=$(printf '%s' "$body" | jq -r 'if .manifests then (.manifests[] | select(.platform.architecture == "arm64" and .platform.os == "linux") | .digest) else empty end' 2>/dev/null | head -1 || true)
    [[ -z "$amd64_digest" ]] && amd64_digest="null"
    [[ -z "$arm64_digest" ]] && arm64_digest="null"

    # Emit compact JSON. jq maps the sentinel "null" string → JSON null.
    jq -nc \
        --arg idx "$index_digest" \
        --arg amd "$amd64_digest" \
        --arg arm "$arm64_digest" \
        '{
            index_digest: (if $idx == "null" then null else $idx end),
            manifest_digest_amd64: (if $amd == "null" then null else $amd end),
            manifest_digest_arm64: (if $arm == "null" then null else $arm end)
        }' 2>/dev/null || echo '{"index_digest":null,"manifest_digest_amd64":null,"manifest_digest_arm64":null}'
}

# --- Docker Hub ---

# Get per-tag manifest sizes from Docker Hub
# Output: one line per arch, format "arch:total_bytes"
# Usage: dockerhub_get_tag_sizes "username" "repo" "tag"
dockerhub_get_tag_sizes() {
    local username="$1"
    local repo="$2"
    local tag="$3"

    local response
    response=$(curl -s --connect-timeout 5 --max-time 10 \
        "https://hub.docker.com/v2/repositories/${username}/${repo}/tags/${tag}" 2>/dev/null) || return 1

    if echo "$response" | jq -e '.errinfo' >/dev/null 2>&1; then
        return 1
    fi

    echo "$response" | jq -r '.images[]? | "\(.architecture):\(.size)"' 2>/dev/null
}

# Get repository stats from Docker Hub (pull count, star count)
# Output: "pulls:N stars:M"
# Usage: dockerhub_get_repo_stats "username" "repo"
dockerhub_get_repo_stats() {
    local username="$1"
    local repo="$2"
    local response pulls stars

    response=$(curl -s --connect-timeout 5 --max-time 10 \
        "https://hub.docker.com/v2/repositories/${username}/${repo}" 2>/dev/null)

    if [[ -n "$response" ]]; then
        pulls=$(echo "$response" | jq -r '.pull_count // 0' 2>/dev/null)
        stars=$(echo "$response" | jq -r '.star_count // 0' 2>/dev/null)
    fi

    [[ -z "$pulls" || "$pulls" == "null" ]] && pulls="0"
    [[ -z "$stars" || "$stars" == "null" ]] && stars="0"

    echo "pulls:$pulls stars:$stars"
}
