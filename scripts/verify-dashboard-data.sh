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
# Capture stderr separately so yq parse errors are surfaced (not silently swallowed).
yq_stderr=$(mktemp)
trap 'rm -f "$yq_stderr"' EXIT

if ! yaml_json=$(yq -o=json '.' "$YAML" 2>"$yq_stderr"); then
  echo "::error file=$YAML::yq failed to parse YAML:" >&2
  cat "$yq_stderr" >&2
  exit 2
fi

# Valid parse but empty document — treat as hard error: generation likely failed.
if [[ -z "$yaml_json" || "$yaml_json" == "null" ]]; then
  echo "::error file=$YAML::$YAML parsed but contains no documents — generation likely failed; refusing to deploy blank dashboard" >&2
  exit 2
fi

# Root MUST be a sequence (list of containers). Reject scalars / mappings early
# with a clear error rather than letting jq's iteration error leak out later.
if ! jq -e 'type == "array"' <<<"$yaml_json" >/dev/null 2>&1; then
  root_type=$(jq -r 'type' <<<"$yaml_json" 2>/dev/null || echo "unknown")
  echo "::error file=$YAML::expected top-level YAML sequence (list of containers), got $root_type" >&2
  exit 2
fi

container_count=$(jq 'length' <<<"$yaml_json")
if [[ "$container_count" -eq 0 ]]; then
  echo "::error file=$YAML::$YAML is an empty array — generation likely failed; refusing to deploy blank dashboard" >&2
  exit 2
fi

# One jq pipeline emits TSV: container<TAB>v_idx<TAB>i_idx<TAB>tag<TAB>field
# - Containers with zero versions AND zero top-level variants emit field="<no-versions>".
# - Multi-version path (has .versions[]): v_idx is the numeric version index.
# - Single-version path (top-level .variants[], no .versions): v_idx is "single".
# - has_variants:false path: v_idx is "no-variants"; fields are at container level.
# - Each (container, version, variant, missing-field) tuple emits one row.
# - Empty/null/{}/[] all count as missing.
gaps_tsv=$(jq -r '
  .[] | .name as $c |
  if (.has_variants != null and .has_variants == false) then
    # Container-level fields (generate-dashboard.sh non-variant path)
    {
      attestation_url: (.attestation_url // null),
      trivy_summary: (.trivy_summary // null),
      sbom_summary: (.sbom_summary // null),
      multi_arch_platforms: (.multi_arch_platforms // null)
    } | to_entries[] |
    select(
      .value == null or
      .value == "" or
      (.value | type == "object" and length == 0) or
      (.value | type == "array" and length == 0) or
      # Require last_scan + counts object + counts.critical as number (sentinel for
      # standard severity keys critical/high/medium/low/info; avoids partial badge renders).
      (.key == "trivy_summary" and (.value | type == "object") and (
        (.value.last_scan // null) == null or
        (.value.counts // null | type) != "object" or
        ((.value.counts.critical // null | type) != "number")
      ))
    ) |
    "\($c)\tno-variants\t-\t-\t\(.key)"
  elif (.versions // []) | length > 0 then
    # Multi-version path (current standard schema)
    (.versions // []) | to_entries[] |
    .key as $v | .value as $version_obj |
    ($version_obj.tag // $version_obj.base_tag // "v\($v)") as $vtag |
    ($version_obj.variants // []) as $variants |
    if ($variants | length) == 0 then
      "\($c)\t\($v)\t-\t\($vtag)\t<no-variants>"
    else
      $variants | to_entries[] |
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
        (.value | type == "array" and length == 0) or
        # Require last_scan + counts object + counts.critical as number (sentinel for
        # standard severity keys critical/high/medium/low/info; avoids partial badge renders).
        (.key == "trivy_summary" and (.value | type == "object") and (
          (.value.last_scan // null) == null or
          (.value.counts // null | type) != "object" or
          ((.value.counts.critical // null | type) != "number")
        ))
      ) |
      "\($c)\t\($v)\t\($i)\t\($tag)\t\(.key)"
    end
  elif (.variants != null and (.variants | type == "array")) then
    # Single-version path: top-level .variants key exists (even if empty) with no .versions wrapper.
    # generate-dashboard.sh emits this schema for containers without a version matrix.
    if (.variants | length) == 0 then
      "\($c)\tsingle\t-\t-\t<no-variants>"
    else
      (.variants // []) | to_entries[] |
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
        (.value | type == "array" and length == 0) or
        # Require last_scan + counts object + counts.critical as number (sentinel for
        # standard severity keys critical/high/medium/low/info; avoids partial badge renders).
        (.key == "trivy_summary" and (.value | type == "object") and (
          (.value.last_scan // null) == null or
          (.value.counts // null | type) != "object" or
          ((.value.counts.critical // null | type) != "number")
        ))
      ) |
      "\($c)\tsingle\t\($i)\t\($tag)\t\(.key)"
    end
  else
    "\($c)\t-\t-\t-\t<no-versions>"
  end
' <<<"$yaml_json")

if [[ -z "$gaps_tsv" ]]; then
  echo "::notice::All containers have complete trust-strip data."
  exit 0
fi

gaps=0
while IFS=$'\t' read -r c v i tag field; do
  [[ -z "$c" ]] && continue
  case "$field" in
    "<no-versions>")
      echo "::warning file=$YAML::No versions found for $c"
      ;;
    "<no-variants>")
      if [[ "$v" == "single" ]]; then
        echo "::warning file=$YAML::Container $c (single-version) has no variants — trust-strip data cannot render"
      else
        # $tag holds the version tag extracted by jq (e.g. "1.0-alpine", "v0" fallback).
        # Using the tag rather than the numeric index makes the message actionable
        # without cross-referencing containers.yml.
        echo "::warning file=$YAML::Version $tag of $c has no variants — trust-strip data cannot render (versions[$v])"
      fi
      ;;
    *)
      case "$v" in
        "no-variants")
          echo "::warning file=$YAML::Missing $field for $c (top-level fields, no variants)"
          ;;
        "single")
          echo "::warning file=$YAML::Missing $field for $c variant $tag (single-version, variants[$i])"
          ;;
        *)
          echo "::warning file=$YAML::Missing $field for $c variant $tag (versions[$v].variants[$i])"
          ;;
      esac
      ;;
  esac
  gaps=$((gaps + 1))
done <<< "$gaps_tsv"

if [[ "$STRICT" == "1" ]]; then
  echo "::error file=$YAML::$gaps data gap(s) found in $YAML (STRICT mode — failing the smoke gate)" >&2
  exit 1
else
  echo "::warning file=$YAML::$gaps data gap(s) found in $YAML (advisory mode — run update-dashboard.yaml in CI to hydrate)"
  exit 0
fi
