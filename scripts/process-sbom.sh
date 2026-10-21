#!/usr/bin/env bash
# Process one SBOM for the lineage cache: compare with the cached SBOM,
# enrich the changelog, append build history, refresh the cached SBOM.
#
# Usage: process-sbom.sh <sbom_file>
# Env:   SBOM_FAILED_DIR  directory receiving one marker file per SBOM that hit a
#                         processing error (default: not recorded)
# Output is buffered and printed in one piece so parallel runs do not interleave.
set -uo pipefail

sbom_file="${1:?usage: process-sbom.sh <sbom_file>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=helpers/sbom-utils.sh
source "$ROOT/helpers/sbom-utils.sh"
# shellcheck source=helpers/dependency-freshness.sh
source "$ROOT/helpers/dependency-freshness.sh"

basename_file=$(basename "$sbom_file")
container_tag="${basename_file%.sbom.json}"
log_file=$(mktemp)
failed=0

process() {
  echo "::group::Processing SBOM for $container_tag"

  # Validate source SBOM has JSON with an array .packages before comparison.
  # This disambiguates two failure modes that compare_sboms cannot distinguish:
  #   1. Source is malformed  → preserve cache (last-known-good), skip compare.
  #   2. Cache is malformed   → source is valid, replace cache to self-heal.
  local cached_sbom=".build-lineage/${basename_file}"
  local append_history=true
  local replace_cache=true
  if ! jq -e '(.packages // empty | type) == "array"' < "$sbom_file" >/dev/null 2>&1; then
    echo "::warning::Source SBOM for $container_tag is not valid JSON with an array .packages — preserving cached SBOM"
    failed=1
    append_history=false
    replace_cache=false
  elif [[ ! -f "$cached_sbom" ]]; then
    echo "No previous SBOM for $container_tag — first build"
    # Both flags stay true; no compare to run; cp at end will create cache.
  else
    if compare_sboms "$sbom_file" "$cached_sbom" \
          ".build-lineage/${container_tag}.changelog.json"; then
      enrich_changelog ".build-lineage/${container_tag}.changelog.json" "$sbom_file" \
        || echo "::warning::dependency freshness enrichment failed for $container_tag"
    else
      local compare_status=$?
      failed=1
      # Stale changelog from previous build is invalid for this build — remove
      # so append_build_history records a blank changes_summary instead of
      # inheriting the previous build's diff.
      rm -f ".build-lineage/${container_tag}.changelog.json"
      append_history=true
      if [[ "$compare_status" -eq 3 ]]; then
        echo "::warning::compare_sboms found malformed cached SBOM for $container_tag — replacing cached SBOM to self-heal"
        replace_cache=true
      else
        echo "::warning::compare_sboms failed with status $compare_status for $container_tag — preserving cached SBOM"
        replace_cache=false
      fi
    fi
  fi

  # Append history when source processing may use this build's summary.
  if [[ "$append_history" == "true" ]]; then
    local summary
    summary=$(extract_sbom_summary "$sbom_file")
    append_build_history ".build-lineage/${container_tag}.json" "$summary" \
      ".build-lineage/${container_tag}.history.json" \
      || { echo "::warning::Build history append failed for $container_tag"; failed=1; }
  fi

  # Preserve last-known-good cache except for successful comparison or status 3.
  if [[ "$replace_cache" == "true" ]]; then
    cp "$sbom_file" "$cached_sbom"
  fi

  echo "::endgroup::"
}

process >"$log_file" 2>&1
cat "$log_file"
rm -f "$log_file"

if [[ "$failed" -eq 1 && -n "${SBOM_FAILED_DIR:-}" ]]; then
  : > "$SBOM_FAILED_DIR/$container_tag"
fi
exit 0
