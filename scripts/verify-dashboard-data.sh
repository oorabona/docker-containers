#!/usr/bin/env bash
# Verify generated containers.yml has the trust-strip data fields populated.
# Advisory mode (default): emits ::warning:: lines + exits 0.
# Strict mode (STRICT=1): exits 1 on any gap.
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

  # Read the default variant (versions[0].variants[0]) as a YAML fragment
  default_variant=$(yq ".[] | select(.name == \"$container\") | .versions[0].variants[0]" "$YAML" 2>/dev/null || true)

  if [[ -z "$default_variant" ]]; then
    echo "::warning file=$YAML::No default variant found for $container"
    gaps=$((gaps + 1))
    continue
  fi

  for field in attestation_url trivy_summary sbom_summary multi_arch_platforms; do
    value=$(printf '%s' "$default_variant" | yq ".$field // \"\"" - 2>/dev/null || true)

    # Treat empty, "null", "{}", "[]" as missing
    if [[ -z "$value" ]] \
        || [[ "$value" == "null" ]] \
        || [[ "$value" == "{}" ]] \
        || [[ "$value" == "[]" ]]; then
      echo "::warning file=$YAML::Missing $field for $container default_variant"
      gaps=$((gaps + 1))
    fi
  done
done

if (( gaps == 0 )); then
  echo "::notice::All containers have complete trust-strip data."
  exit 0
fi

echo "::warning::$gaps data gap(s) found in $YAML (advisory mode — run update-dashboard.yaml in CI to hydrate)."
[[ "$STRICT" == "1" ]] && exit 1 || exit 0
