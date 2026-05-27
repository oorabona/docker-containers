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
#   2  — Tooling failure (./make list unavailable or returned empty)

set -euo pipefail

# ---------------------------------------------------------------------------
# _escape_gha_command <value>
#
# Escape a value for safe inclusion in a `::keyword::value` GitHub Actions
# workflow command.  A %0A in the value would terminate the command line and
# inject the remainder as a new command.  Mapping per GitHub's runner spec:
#   %  → %25
#   \n → %0A
#   \r → %0D
#
# Inlined from helpers/base-cache-utils.sh::_escape_gha_command to avoid
# importing the full base-cache helper.
# ---------------------------------------------------------------------------
_escape_gha_command() {
    local s="$1"
    s="${s//\%/%25}"
    s="${s//$'\n'/%0A}"
    s="${s//$'\r'/%0D}"
    printf '%s' "$s"
}

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

# _ULR_PROJECT_ROOT_OVERRIDE: test hook — when set, use this path as PROJECT_ROOT
# instead of deriving it from BASH_SOURCE[0].  Avoids needing the full project
# context in unit tests that invoke update-last-rebuild.sh via bash "$UPDATE_SCRIPT".
# Named with _ULR_ prefix to avoid collision with similarly-named vars in the
# detect-base-digest-drift.sh test suite.
if [[ -n "${_ULR_PROJECT_ROOT_OVERRIDE:-}" ]]; then
    PROJECT_ROOT="$_ULR_PROJECT_ROOT_OVERRIDE"
fi

make_exit=0
# _ULR_VALID_CONTAINERS_OVERRIDE: test hook — when set, use this newline-separated
# list instead of ./make list (avoids needing the full project context in tests).
# Named with _ULR_ prefix to avoid collision with _VALID_CONTAINERS_OVERRIDE used
# by detect-base-digest-drift.sh (which is exported by its bats setup()).
if [[ -n "${_ULR_VALID_CONTAINERS_OVERRIDE:-}" ]]; then
    valid_containers="$_ULR_VALID_CONTAINERS_OVERRIDE"
else
    valid_containers=$(cd "$PROJECT_ROOT" && ./make list) || make_exit=$?
    if [[ "$make_exit" -ne 0 ]]; then
        echo "::error::./make list failed with exit $make_exit" >&2
        exit 2
    fi
    if [[ -z "$valid_containers" ]]; then
        echo "::error::./make list returned empty — canonical container list unavailable" >&2
        exit 2
    fi
fi
if ! grep -qxF -- "$CONTAINER" <<<"$valid_containers"; then
    echo "::warning::container '$(_escape_gha_command "$CONTAINER")' is not a valid container name (not in ./make list) — skipping" >&2
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

# Idempotency: content-hash dedupe (gate r27, Defect C — replaces r25 heading-only dedupe).
# Run-id scope added in gate r29 (Finding 1 — cross-run recoverability).
#
# The r25 fix deduped on the `## base-digest-drift (YYYY-MM-DD)` heading alone.
# False negative: if drift A merges in the morning → rebuild → then drift B
# (different variants) occurs the same UTC day → the heading is already present →
# script skipped → no file change → no PR/rebuild trigger for drift B.
#
# r27 fix: embed a SHA-256 content-hash of the drift section body as an HTML comment
# ABOVE the heading.  Two invocations with identical drift content (same variants,
# same digests) share the same hash → idempotent skip preserved.  Two invocations
# with different content (even on the same day) produce different hashes → both
# sections are appended.
#
# r29 fix (run-id scope): a failed rebuild followed by the same drift in the NEXT
# workflow run would match the r27 hash marker → no new section → no PR → drift
# unrecoverable until lineage changes.  Fix: include GITHUB_RUN_ID in the marker
# so identical content in a different run always appends fresh.
#
# Dedupe semantics:
#   - Same hash AND same run_id → in-run retry → skip (preserves r25 retry invariant)
#   - Same hash but different run_id → new run re-detecting same drift → append
#   - Different hash → different drift content → always append
#
# Hash scope: variant_lines only (the stable, injected-safe content derived from
# drift JSON).  16 hex characters is sufficient; collision probability per
# container per day is negligible.
#
# This script targets GitHub Actions.  When GITHUB_RUN_ID is unset (local
# invocation, unit tests) the literal "local" is used — same-run deduplication
# still applies within a local session, but cross-run recovery requires GHA.
drift_content_hash=$(printf '%s\n' "${variant_lines}" | sha256sum | cut -d' ' -f1 | head -c 16)
run_id="${GITHUB_RUN_ID:-local}"
hash_marker="<!-- drift-content-hash: ${drift_content_hash} run:${run_id} -->"

if grep -qF -- "$hash_marker" "$target_file" 2>/dev/null; then
    echo "::notice::Same drift event already recorded (hash ${drift_content_hash} run:${run_id}), skipping append" >&2
    exit 0
fi

{
    printf '\n'
    printf '%s\n' "$hash_marker"
    printf '%s\n' "$section_header"
    printf '\n'
    printf '%s\n' "$variant_lines"
} >> "$target_file"

echo "::notice::Appended '$section_header' section to $target_file" >&2
