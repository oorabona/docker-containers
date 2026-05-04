#!/usr/bin/env bash
# Verify generated containers.yml has the trust-strip data fields populated.
# Advisory mode (default): emits ::warning:: lines + exits 0.
# Strict mode (STRICT=1): exits 1 on any gap.
#
# Coverage: ALL versions × ALL variants per container (not just the default).
# Dashboard detail pages render trust-strip data for whichever version+variant
# the user selects, so non-default variants must be checked too.
#
# Implementation: one yq call (YAML→JSON) + one jq call (gap detection).
# Total process count is constant in container/variant count, so wall-time
# stays under a second even at hundreds of variants.
#
# Local dev note: when running without a prior update-dashboard.yaml execution,
# containers.yml is regenerated without SBOM artifact hydration — almost all
# trust-strip fields will be missing. That is expected pre-CI; this script
# surfaces those gaps so you know what the CI pipeline will fill in.
#
# Usage:
#   scripts/verify-dashboard-data.sh [containers_yml]
#   STRICT=1 scripts/verify-dashboard-data.sh [containers_yml]
set -euo pipefail

YAML="${1:-docs/site/_data/containers.yml}"
STRICT="${STRICT:-0}"

if ! command -v yq >/dev/null 2>&1; then
  echo "::error::yq required (install: https://github.com/mikefarah/yq)" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "::error::jq required" >&2
  exit 2
fi

if [[ ! -f "$YAML" ]]; then
  echo "::error::$YAML not found — run generate-dashboard.sh first" >&2
  exit 2
fi

# Convert the entire YAML to JSON once. yq's -o=json flag is fast and avoids
# bash word-splitting hazards on nested structures.
yaml_json=$(yq -o=json '.' "$YAML" 2>/dev/null || true)

if [[ -z "$yaml_json" || "$yaml_json" == "null" ]]; then
  echo "::warning::$YAML contains no parseable container data — nothing to verify"
  exit 0
fi

container_count=$(jq 'length' <<<"$yaml_json")
if [[ "$container_count" -eq 0 ]]; then
  echo "::warning::$YAML contains no containers — nothing to verify"
  exit 0
fi

# One jq pipeline emits TSV: container<TAB>v_idx<TAB>i_idx<TAB>tag<TAB>field
# - Containers with zero versions emit a single row with field="<no-versions>".
# - Each (container, version, variant, missing-field) tuple emits one row.
# - Empty/null/{}/[] all count as missing.
gaps_tsv=$(jq -r '
  .[] | .name as $c |
  if (.versions // []) | length == 0 then
    "\($c)\t-\t-\t-\t<no-versions>"
  else
    (.versions // []) | to_entries[] |
    .key as $v | (.value.variants // []) | to_entries[] |
    .key as $i | .value as $variant |
    ($variant.tag // "unknown") as $tag |
    {
      attestation_url: ($variant.attestation_url // null),
      trivy_summary: ($variant.trivy_summary // null),
      sbom_summary: ($variant.sbom_summary // null),
      multi_arch_platforms: ($variant.multi_arch_platforms // null)
    } | to_entries[] |
    select(
      .value == null or
      .value == "" or
      (.value | type == "object" and length == 0) or
      (.value | type == "array" and length == 0)
    ) |
    "\($c)\t\($v)\t\($i)\t\($tag)\t\(.key)"
  end
' <<<"$yaml_json")

if [[ -z "$gaps_tsv" ]]; then
  echo "::notice::All containers have complete trust-strip data."
  exit 0
fi

gaps=0
while IFS=$'\t' read -r c v i tag field; do
  [[ -z "$c" ]] && continue
  if [[ "$field" == "<no-versions>" ]]; then
    echo "::warning file=$YAML::No versions found for $c"
  else
    echo "::warning file=$YAML::Missing $field for $c variant $tag (versions[$v].variants[$i])"
  fi
  gaps=$((gaps + 1))
done <<< "$gaps_tsv"

echo "::warning::$gaps data gap(s) found in $YAML (advisory mode — run update-dashboard.yaml in CI to hydrate)."
[[ "$STRICT" == "1" ]] && exit 1 || exit 0
