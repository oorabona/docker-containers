#!/usr/bin/env bash
# Remove offline self-hosted runners from a GitHub repository or organization.
#
# Usage:
#   cleanup-offline-runners.sh                    # uses GITHUB_REPOSITORY or GITHUB_ORG from env
#   cleanup-offline-runners.sh owner/repo         # explicit repo
#   cleanup-offline-runners.sh --org myorg        # explicit org
#
# Requires: GITHUB_TOKEN with admin:org or repo scope, or gh CLI authenticated.
#
# Dry-run by default — pass --force to actually remove runners.

set -euo pipefail

# --- argument parsing ---

SCOPE_TYPE=""   # "repo" or "org"
SCOPE_VALUE=""  # owner/repo or orgname
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org)
      SCOPE_TYPE="org"
      SCOPE_VALUE="${2:?'--org requires a value'}"
      shift 2
      ;;
    --force)
      FORCE=true
      shift
      ;;
    --*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      SCOPE_TYPE="repo"
      SCOPE_VALUE="$1"
      shift
      ;;
  esac
done

# Fall back to environment variables
if [[ -z "$SCOPE_TYPE" ]]; then
  if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
    SCOPE_TYPE="repo"
    SCOPE_VALUE="$GITHUB_REPOSITORY"
  elif [[ -n "${GITHUB_ORG:-}" ]]; then
    SCOPE_TYPE="org"
    SCOPE_VALUE="$GITHUB_ORG"
  else
    echo "Error: no target specified. Pass owner/repo, --org myorg, or set GITHUB_REPOSITORY / GITHUB_ORG." >&2
    exit 1
  fi
fi

# --- build API paths ---

if [[ "$SCOPE_TYPE" == "repo" ]]; then
  LIST_PATH="repos/${SCOPE_VALUE}/actions/runners"
  DELETE_PATH_PREFIX="repos/${SCOPE_VALUE}/actions/runners"
else
  LIST_PATH="orgs/${SCOPE_VALUE}/actions/runners"
  DELETE_PATH_PREFIX="orgs/${SCOPE_VALUE}/actions/runners"
fi

# --- list offline runners ---

echo "Fetching runners from ${SCOPE_TYPE}: ${SCOPE_VALUE} ..."

runners_json=$(gh api "${LIST_PATH}?per_page=100" --paginate)

mapfile -t offline_ids   < <(echo "$runners_json" | jq -r '.runners[] | select(.status=="offline") | .id')
mapfile -t offline_names < <(echo "$runners_json" | jq -r '.runners[] | select(.status=="offline") | .name')
mapfile -t offline_dates < <(echo "$runners_json" | jq -r '.runners[] | select(.status=="offline") | (.runner_group_name // "—")')

total="${#offline_ids[@]}"

if [[ "$total" -eq 0 ]]; then
  echo "No offline runners found."
  exit 0
fi

echo ""
echo "Offline runners found: ${total}"
echo ""
printf "  %-6s  %-40s  %s\n" "ID" "Name" "Group"
printf "  %-6s  %-40s  %s\n" "------" "----------------------------------------" "-----"
for i in "${!offline_ids[@]}"; do
  printf "  %-6s  %-40s  %s\n" "${offline_ids[$i]}" "${offline_names[$i]}" "${offline_dates[$i]}"
done
echo ""

if [[ "$FORCE" != true ]]; then
  echo "Dry-run mode — no runners removed. Pass --force to delete them."
  exit 0
fi

# --- remove each offline runner ---

removed=0
failed=0
for i in "${!offline_ids[@]}"; do
  id="${offline_ids[$i]}"
  name="${offline_names[$i]}"
  if gh api --method DELETE "${DELETE_PATH_PREFIX}/${id}" > /dev/null 2>&1; then
    echo "  Removed: ${name} (${id})"
    (( removed++ )) || true
  else
    echo "  Failed:  ${name} (${id})" >&2
    (( failed++ )) || true
  fi
done

echo ""
echo "Summary: ${total} offline found, ${removed} removed, ${failed} failed."
[[ "$failed" -eq 0 ]]
