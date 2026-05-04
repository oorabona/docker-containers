#!/usr/bin/env bash
# Verify generated containers.yml has the trust-strip data fields populated.
# Advisory mode (default): emits ::warning:: lines + exits 0.
# Strict mode (STRICT=1): exits 1 on any gap.
#
# Coverage: ALL versions × ALL variants per container (not just the default).
# Dashboard detail pages render trust-strip data for whichever version+variant
# the user selects, so non-default variants must be checked too.
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
gaps=0

if ! command -v yq >/dev/null 2>&1; then
  echo "::error::yq required (install: https://github.com/mikefarah/yq)" >&2
  exit 2
fi

if [[ ! -f "$YAML" ]]; then
  echo "::error::$YAML not found — run generate-dashboard.sh first" >&2
  exit 2
fi

# Collect container names
mapfile -t containers < <(yq '.[].name' "$YAML" 2>/dev/null)

if [[ "${#containers[@]}" -eq 0 ]]; then
  echo "::warning::$YAML contains no containers — nothing to verify"
  exit 0
fi

for container in "${containers[@]}"; do
  [[ -z "$container" ]] && continue

  # Collect all (version_index, variant_index) pairs for this container.
  # Use a count-based iteration rather than yq tag iteration to keep variant
  # ordering stable.
  version_count=$(yq ".[] | select(.name == \"$container\") | .versions | length // 0" "$YAML" 2>/dev/null)
  if [[ -z "$version_count" || "$version_count" == "0" ]]; then
    echo "::warning file=$YAML::No versions found for $container"
    gaps=$((gaps + 1))
    continue
  fi

  for ((v=0; v<version_count; v++)); do
    variant_count=$(yq ".[] | select(.name == \"$container\") | .versions[$v].variants | length // 0" "$YAML" 2>/dev/null)
    if [[ -z "$variant_count" || "$variant_count" == "0" ]]; then
      continue
    fi

    for ((i=0; i<variant_count; i++)); do
      variant=$(yq ".[] | select(.name == \"$container\") | .versions[$v].variants[$i]" "$YAML" 2>/dev/null || true)
      [[ -z "$variant" ]] && continue
      variant_tag=$(printf '%s' "$variant" | yq '.tag // "unknown"' - 2>/dev/null)

      for field in attestation_url trivy_summary sbom_summary multi_arch_platforms; do
        value=$(printf '%s' "$variant" | yq ".$field // \"\"" - 2>/dev/null || true)
        if [[ -z "$value" ]] || [[ "$value" == "null" ]] || [[ "$value" == "{}" ]] || [[ "$value" == "[]" ]]; then
          echo "::warning file=$YAML::Missing $field for $container variant $variant_tag (versions[$v].variants[$i])"
          gaps=$((gaps + 1))
        fi
      done
    done
  done
done

if (( gaps == 0 )); then
  echo "::notice::All containers have complete trust-strip data."
  exit 0
fi

echo "::warning::$gaps data gap(s) found in $YAML (advisory mode — run update-dashboard.yaml in CI to hydrate)."
[[ "$STRICT" == "1" ]] && exit 1 || exit 0
