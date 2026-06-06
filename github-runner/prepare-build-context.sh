#!/usr/bin/env bash
# Download the GitHub Actions runner agent into the build context.
# Called by build-container.sh before docker build.
#
# Usage: prepare-build-context.sh <version> <arch>
#   arch: amd64 or arm64 (Docker platform arch)
#
# Downloads runner tarball + SHA256 checksum into the container directory
# so the Dockerfile can COPY them instead of downloading inside BuildKit.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../helpers/logging.sh"

VERSION="${1:?Usage: prepare-build-context.sh <version> <arch>}"
ARCH_DOCKER="${2:-amd64}"

# Map Docker arch to GitHub runner arch
case "$ARCH_DOCKER" in
    arm64) ARCH=arm64 ;;
    *)     ARCH=x64 ;;
esac

PLATFORM="${3:-linux}"
case "$PLATFORM" in
    windows) EXT=zip; OS=win ;;
    *)       EXT=tar.gz; OS=linux ;;
esac

FILE="actions-runner-${OS}-${ARCH}-${VERSION}.${EXT}"
URL="https://github.com/actions/runner/releases/download/v${VERSION}/${FILE}"
SHA_URL="${URL}.sha256"

TARGET_DIR="$SCRIPT_DIR"
TARGET_FILE="$TARGET_DIR/runner.${EXT}"
TARGET_SHA="$TARGET_DIR/runner.sha256"

# Validate cached archive against the requested version before skipping.
# A stale archive from a different version (e.g. restored from a broad cache
# fallback) must be discarded so the download path always runs for that case.
if [[ -f "$TARGET_FILE" && -f "$TARGET_SHA" ]]; then
    _skip=false
    if command -v sha256sum &>/dev/null; then
        _actual_sha=$(sha256sum "$TARGET_FILE" | awk '{print $1}')
    elif command -v shasum &>/dev/null; then
        _actual_sha=$(shasum -a 256 "$TARGET_FILE" | awk '{print $1}')
    else
        _actual_sha=""
    fi

    if [[ -n "$_actual_sha" ]]; then
        # Fetch the expected checksum for v$VERSION from the GitHub release asset
        # (published as <file>.sha256 alongside the tarball).
        _tmp_dir=$(mktemp -d)
        _expected_raw=""
        if command -v gh &>/dev/null && [[ -n "${GITHUB_TOKEN:-}" ]]; then
            if gh release download "v${VERSION}" \
                --repo actions/runner \
                --pattern "${FILE}.sha256" \
                --dir "$_tmp_dir" \
                --clobber 2>/dev/null; then
                _expected_raw=$(cat "$_tmp_dir/${FILE}.sha256" 2>/dev/null || true)
            fi
        else
            _expected_raw=$(curl -fsSL "${SHA_URL}" 2>/dev/null || true)
        fi
        rm -rf "$_tmp_dir"

        # The GitHub SHA file format is "<hex>  <filename>" — extract just the hex.
        _expected_sha=$(printf '%s' "$_expected_raw" | awk '{print $1}' | tr -cd '0-9a-fA-F' | head -c 64)

        if [[ -n "$_expected_sha" && "$_actual_sha" == "$_expected_sha" ]]; then
            _skip=true
        elif [[ -z "$_expected_sha" ]]; then
            # Network check failed entirely — prefer re-download (fail-closed toward
            # correctness) rather than trusting a possibly-stale cached archive.
            log_warning "Could not fetch expected SHA for v${VERSION} — re-downloading to be safe"
        else
            log_warning "Cached runner.${EXT} SHA mismatch for v${VERSION} (expected ${_expected_sha:0:12}… got ${_actual_sha:0:12}…) — re-downloading"
            rm -f "$TARGET_FILE" "$TARGET_SHA"
        fi
    fi

    if [[ "$_skip" == "true" ]]; then
        log_info "Runner agent already in build context and version-validated: $FILE"
        exit 0
    fi
fi

log_info "Downloading runner agent: $FILE"

# Prefer gh CLI (authenticated, avoids CDN 404 issues) over curl
if command -v gh &>/dev/null && [[ -n "${GITHUB_TOKEN:-}" ]]; then
    gh release download "v${VERSION}" \
        --repo actions/runner \
        --pattern "$FILE" \
        --dir "$TARGET_DIR" \
        --clobber
    mv "$TARGET_DIR/$FILE" "$TARGET_FILE"
else
    curl -fsSL "$URL" -o "$TARGET_FILE"
fi

# Generate SHA256 checksum file (GitHub doesn't publish .sha256 as release assets)
if command -v sha256sum &>/dev/null; then
    sha256sum "$TARGET_FILE" | awk '{print $1}' > "$TARGET_SHA"
elif command -v shasum &>/dev/null; then
    shasum -a 256 "$TARGET_FILE" | awk '{print $1}' > "$TARGET_SHA"
else
    log_warning "No sha256sum available — skipping checksum file"
    echo "no-checksum" > "$TARGET_SHA"
fi

HASH=$(cat "$TARGET_SHA")
log_info "Runner agent ready: $FILE (SHA256: ${HASH:0:12}...)"
