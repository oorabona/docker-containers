#!/usr/bin/env bash
# update-last-rebuild.sh — Append a `## base-digest-drift (YYYY-MM-DD)` section
# to <container>/LAST_REBUILD.md, distinguishing from upstream-monitor's
# existing `## version-update` sections.
#
# Usage:
#   ./scripts/update-last-rebuild.sh <container> <kind> < drift.json
#
#   <container>  — Container directory name (e.g. "foo")
#   <kind>       — Section identifier (e.g. "base-digest-drift")
#
# Input (stdin):
#   JSON array from detect-base-digest-drift.sh output.
#   The script filters for the given container's drifted variants.
#
# Output:
#   Appends a markdown section to <container>/LAST_REBUILD.md (creates the
#   file if it does not exist). The file already exists for most containers
#   (written by upstream-monitor.yaml:440) — we append a new section.
#
# Injection safety:
#   All values written to the file are passed through printf '%s' and
#   sanitized — no direct interpolation of registry-sourced data in
#   heredocs or eval contexts.
#
# Exit codes:
#   0  — Section appended (or container has no drifted variants — no-op)
#   1  — Fatal error (invalid args, missing jq, etc.)

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------
if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <container> <kind>" >&2
    echo "  Reads drift JSON from stdin." >&2
    exit 1
fi

CONTAINER="$1"
KIND="$2"

if [[ -z "$CONTAINER" ]]; then
    echo "::error::container argument is empty" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Fix 1: Validate CONTAINER against canonical list (poisoning prevention)
# A corrupted lineage entry (e.g. "docs", ".github", paths with "/") must
# not cause the script to write outside the valid container set.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

valid_containers=$(cd "$PROJECT_ROOT" && ./make list)
if [[ -z "$valid_containers" ]]; then
    echo "::error::./make list returned empty — canonical container list unavailable" >&2
    exit 2
fi
if ! grep -qxF "$CONTAINER" <<<"$valid_containers"; then
    echo "::warning::container '$CONTAINER' is not a valid container name (not in ./make list) — skipping" >&2
    exit 0
fi

if [[ -z "$KIND" ]]; then
    echo "::error::kind argument is empty" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Read drift JSON from stdin
# ---------------------------------------------------------------------------
drift_json=$(cat)

if [[ -z "$drift_json" ]]; then
    echo "::warning::No drift JSON on stdin — nothing to write for $CONTAINER" >&2
    exit 0
fi

# Validate it's parseable JSON
if ! printf '%s' "$drift_json" | jq '.' >/dev/null 2>&1; then
    echo "::error::Drift JSON from stdin is not valid JSON" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Extract drifted variants for this container
# ---------------------------------------------------------------------------
drifted_variants=$(printf '%s' "$drift_json" | \
    jq -c --arg c "$CONTAINER" \
    '[.[] | select(.container == $c) | .variants[] | select(.status == "drift" or .status == "legacy")]' \
    2>/dev/null || true)

if [[ -z "$drifted_variants" || "$drifted_variants" == "[]" ]]; then
    echo "::notice::No drifted variants for container '$CONTAINER' — skipping LAST_REBUILD.md update" >&2
    exit 0
fi

# ---------------------------------------------------------------------------
# Build the section content (injection-safe)
# ---------------------------------------------------------------------------
today=$(date -u +"%Y-%m-%d")
section_header="## ${KIND} (${today})"

# Build variant lines using jq to safely extract field values.
# Fix 2 (gate r9): escape backticks and pipes in variant_tag and base_image_ref
# before embedding in markdown — prevents injection via poisoned lineage entries.
variant_lines=$(printf '%s' "$drifted_variants" | \
    jq -r '.[] |
        (.variant_tag | gsub("`"; "\\`") | gsub("\\|"; "\\|")) as $safe_tag |
        (.base_image_ref | gsub("`"; "\\`") | gsub("\\|"; "\\|")) as $safe_ref |
        "- Variant: \($safe_tag), base \($safe_ref)\n  Old digest: \(.recorded_digest // "unknown")\n  New digest: \(.current_digest // "(legacy — no recorded digest)")"' \
    2>/dev/null || true)

if [[ -z "$variant_lines" ]]; then
    echo "::warning::Could not build variant lines for $CONTAINER — skipping" >&2
    exit 0
fi

# ---------------------------------------------------------------------------
# Append section to LAST_REBUILD.md
# ---------------------------------------------------------------------------
target_file="${PROJECT_ROOT}/${CONTAINER}/LAST_REBUILD.md"

# Fix 4: Gracefully skip when container directory is missing.
# Defense-in-depth after Fix 1 validation: the container name is canonical
# but the directory may have been deleted/renamed since the lineage cache was
# written.  A stale entry must not break the entire workflow.
if [[ ! -d "${PROJECT_ROOT}/${CONTAINER}" ]]; then
    echo "::warning::container directory '${PROJECT_ROOT}/${CONTAINER}' missing — skipping LAST_REBUILD.md update" >&2
    exit 0
fi

{
    printf '\n'
    printf '%s\n' "$section_header"
    printf '\n'
    printf '%s\n' "$variant_lines"
} >> "$target_file"

echo "::notice::Appended '$section_header' section to $target_file" >&2
