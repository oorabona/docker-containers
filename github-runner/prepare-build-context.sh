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

# Skip if already downloaded (same version)
if [[ -f "$TARGET_FILE" && -f "$TARGET_SHA" ]]; then
    log_info "Runner agent already in build context: $FILE"
    exit 0
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
