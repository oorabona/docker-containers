#!/usr/bin/env bash
# Non-blocking audit: report which FROM images in container Dockerfiles
# are covered by their config.yaml base_image_cache declarations.
#
# Designed as a debugging/diagnostic aid. Always exits 0.
# Run manually or as a CI step that writes to $GITHUB_STEP_SUMMARY.
#
# Usage: ./scripts/audit-base-image-cache.sh [--summary] [container...]
#   --summary       Emit a markdown table (default: plain text)
#   container...    Restrict audit to listed containers (default: all)
#
# Environment:
#   AUDIT_ROOT      Override the repo root (for testing); defaults to the
#                   directory above the scripts/ directory.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${AUDIT_ROOT:-$(dirname "$SCRIPT_DIR")}"
cd "$ROOT_DIR" || exit 1
# shellcheck source=../helpers/logging.sh
source helpers/logging.sh

# Intentional uncached images (legal/DRY).
# Add new entries here when adopting a new pattern.
EXPECTED_UNCACHED_PATTERNS=(
  "mcr.microsoft.com/*"     # Microsoft licensing — redistribution restricted
  "ghcr.io/oorabona/*"      # Self-reference to our own pipeline output (DRY)
)

is_expected_uncached() {
  local img=$1 pattern
  for pattern in "${EXPECTED_UNCACHED_PATTERNS[@]}"; do
    # shellcheck disable=SC2053
    [[ "$img" == $pattern ]] && return 0
  done
  return 1
}

# extract FROM image references from a Dockerfile (skip stage names, scratch, comments).
extract_froms() {
  local dockerfile=$1
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*FROM[[:space:]]+/ {
      img = $2
      if (img == "scratch" || img ~ /^@@/) next
      print img
    }
  ' "$dockerfile" | sort -u
}

# resolve ${VAR} placeholders against a container config.yaml's build_args.
resolve_image_ref() {
  local img=$1 config=$2
  local guard=0
  while [[ "$img" =~ \$\{([A-Z_][A-Z_0-9]*)\} ]] && (( guard++ < 5 )); do
    local var=${BASH_REMATCH[1]}
    local val
    val=$(yq -r ".build_args.$var // \"\"" "$config" 2>/dev/null || true)
    [[ -z "$val" || "$val" == "null" ]] && val="<unresolved:$var>"
    img=${img//\$\{$var\}/$val}
  done
  echo "$img"
}

# Normalize an image source path for comparison against base_image_cache[].source.
#
# The config.yaml source field uses the bare upstream path without a registry prefix:
#   new-style: "library/postgres"   (Docker Hub official namespace)
#   old-style:  "ubuntu"            (bare Docker Hub name)
#
# Resolved FROM lines may carry extra prefixes that must be stripped:
#   - "<unresolved:VARNAME>/" — a ${VARNAME} placeholder for a registry override
#     (e.g. ${REMOTE_CR}) that was not declared in build_args; treated as the
#     docker.io default registry and removed.
#   - "docker.io/" — explicit Docker Hub hostname prefix.
#
# After stripping the registry prefix, "library/<x>" and bare "<x>" compare equal
# for official Docker Hub images (Docker treats them as the same pull path).
#
# Returns two candidates via stdout (one per line): the normalized path and, when
# it starts with "library/", also the bare name without the "library/" prefix so
# that a source of "ubuntu" matches a FROM of "library/ubuntu" and vice-versa.
normalize_image_source() {
  local raw=$1

  # 1. Strip <unresolved:VARNAME>/ prefix (unresolvable CI registry variable).
  local norm="$raw"
  if [[ "$norm" =~ ^"<unresolved:"[A-Z_][A-Z_0-9]*">/" ]]; then
    norm="${norm#*>/}"
  fi

  # 2. Strip explicit docker.io/ prefix.
  norm="${norm#docker.io/}"

  echo "$norm"

  # 3. Emit the library-stripped alias so "ubuntu" matches "library/ubuntu".
  if [[ "$norm" == library/* ]]; then
    echo "${norm#library/}"
  fi
}

# Check whether image_ref is covered by any base_image_cache entry in container config.
is_cached() {
  local img=$1 config=$2
  [[ ! -f "$config" ]] && return 1

  # Normalize the registry prefix BEFORE stripping the tag.  This is required
  # because <unresolved:VARNAME> markers contain a colon, so the naive
  # ${img%%:*} would truncate the string at the wrong colon.
  # Example: "<unresolved:REMOTE_CR>/library/postgres:<unresolved:VERSION>"
  #   → after normalize: "library/postgres:<unresolved:VERSION>"
  #   → after tag strip:  "library/postgres"
  local norm_first
  norm_first=$(normalize_image_source "$img" | head -1)

  # Strip tag (everything from first ':' onward).  After normalization the
  # string no longer starts with <unresolved:…>, so the first colon is the
  # tag separator (if any).
  local img_source="${norm_first%%:*}"

  # Compute the full set of normalized candidates (includes library/ alias).
  local -a candidates
  mapfile -t candidates < <(normalize_image_source "$img_source")

  local count
  count=$(yq -r '.base_image_cache | length // 0' "$config" 2>/dev/null || echo 0)
  local i
  for ((i = 0; i < count; i++)); do
    local cache_source
    cache_source=$(yq -r ".base_image_cache[$i].source" "$config")
    local cand
    for cand in "${candidates[@]}"; do
      if [[ "$cache_source" == "$cand" ]]; then
        return 0
      fi
    done
  done
  return 1
}

# Generate report rows and tally counts.
audit_one() {
  local container=$1
  local config="./$container/config.yaml"
  local dockerfiles
  dockerfiles=$(find "./$container" -maxdepth 1 \( -name "Dockerfile" -o -name "Dockerfile.*" \) 2>/dev/null)
  [[ -z "$dockerfiles" ]] && return 0

  local df raw resolved
  while IFS= read -r df; do
    while IFS= read -r raw; do
      [[ -z "$raw" ]] && continue
      resolved=$(resolve_image_ref "$raw" "$config")
      total=$((total + 1))
      if is_cached "$resolved" "$config"; then
        covered=$((covered + 1))
        printf '%s\t%s\t%s\t%s\n' "$container" "$resolved" "cached" ""
      elif is_expected_uncached "$resolved"; then
        expected_gap=$((expected_gap + 1))
        printf '%s\t%s\t%s\t%s\n' "$container" "$resolved" "uncached-expected" "legal/DRY exception"
      else
        gap=$((gap + 1))
        printf '%s\t%s\t%s\t%s\n' "$container" "$resolved" "GAP" "not declared in base_image_cache"
      fi
    done < <(extract_froms "$df")
  done <<< "$dockerfiles"
}

# Guard: allow sourcing for unit tests without executing the main block.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then

  format=plain
  declare -a only_containers=()
  for arg in "$@"; do
    case $arg in
      --summary) format=summary ;;
      *) only_containers+=("$arg") ;;
    esac
  done

  total=0
  covered=0
  expected_gap=0
  gap=0

  # Capture rows; counters incremented in audit_one would be lost across the
  # subshell, so tally from the captured output instead.
  rows=$(
    while IFS= read -r container; do
      [[ -z "$container" ]] && continue
      if (( ${#only_containers[@]} > 0 )); then
        keep=false
        for c in "${only_containers[@]}"; do
          [[ "$c" == "$container" ]] && keep=true && break
        done
        $keep || continue
      fi
      audit_one "$container"
    done < <(list_containers)
  )
  total=$(awk -F'\t' 'NF{c++} END{print c+0}' <<< "$rows")
  covered=$(awk -F'\t' '$3=="cached"{c++} END{print c+0}' <<< "$rows")
  expected_gap=$(awk -F'\t' '$3=="uncached-expected"{c++} END{print c+0}' <<< "$rows")
  gap=$(awk -F'\t' '$3=="GAP"{c++} END{print c+0}' <<< "$rows")

  if [[ "$format" == "summary" ]]; then
    echo "## Base Image Cache Audit"
    echo
    echo "| Container | Image | Status | Notes |"
    echo "|-----------|-------|--------|-------|"
    while IFS=$'\t' read -r c img status notes; do
      case $status in
        cached)            icon='✅' ;;
        uncached-expected) icon='⚠️' ;;
        GAP)               icon='❌' ;;
        *)                 icon='❓' ;;
      esac
      echo "| $c | \`$img\` | $icon $status | $notes |"
    done <<< "$rows"
    echo
    echo "**Summary:** $covered/$total cached, $expected_gap expected uncached, $gap unexpected gap(s)"
  else
    echo "$rows" | column -t -s $'\t'
    echo
    echo "Summary: $covered/$total cached, $expected_gap expected uncached, $gap unexpected gap(s)"
  fi

  exit 0  # always non-blocking

fi
