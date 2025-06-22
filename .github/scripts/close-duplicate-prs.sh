#!/bin/bash
#
# Close Duplicate PRs Script
# This script closes existing PRs for the same container version update to prevent duplicates
#
# Required environment variables:
# - CONTAINER: Container name
# - NEW_VERSION: New version being updated to
# - GH_TOKEN: GitHub token for API access
#

set -e

echo "🔍 Checking for existing PRs for container: $CONTAINER"

# Check if required environment variables are set
if [[ -z "$CONTAINER" ]]; then
  echo "❌ Error: CONTAINER environment variable is required"
  exit 1
fi

if [[ -z "$NEW_VERSION" ]]; then
  echo "❌ Error: NEW_VERSION environment variable is required"
  exit 1
fi

if [[ -z "$GH_TOKEN" ]]; then
  echo "❌ Error: GH_TOKEN environment variable is required"
  exit 1
fi

# Check if GitHub CLI is available
if ! command -v gh &> /dev/null; then
  echo "⚠️  GitHub CLI not available, skipping PR cleanup"
  echo "ℹ️  This would work in GitHub Actions environment"
  echo "existing_pr_found=false" >> $GITHUB_OUTPUT
  exit 0
fi

echo "✅ GitHub CLI available (version: $(gh --version | head -1))"

# Define search patterns for PRs that should be closed
pr_title_patterns=(
  "Update $CONTAINER to version"
  "chore($CONTAINER): update to version"
  "Rebuild $CONTAINER with upstream version"
  "Bump $CONTAINER to"
)

# Get all open PRs
open_prs=$(gh pr list --state open --json number,title,headRefName,body --limit 100)
if [ "$open_prs" = "[]" ]; then
  echo "✅ No open PRs found"
  echo "existing_pr_found=false" >> $GITHUB_OUTPUT
  exit 0
fi

closed_count=0

# Check each PR title pattern
for pattern in "${pr_title_patterns[@]}"; do
  echo "🔍 Searching for PRs matching pattern: '$pattern'"

  # Find PRs matching this pattern
  matching_prs=$(echo "$open_prs" | jq -r --arg pattern "$pattern" \
    '.[] | select(.title | test($pattern; "i")) | .number')
  
  for pr_number in $matching_prs; do
    if [ -n "$pr_number" ]; then
      # Get PR details
      pr_info=$(echo "$open_prs" | jq -r --arg num "$pr_number" \
        '.[] | select(.number == ($num | tonumber))')
      pr_title=$(echo "$pr_info" | jq -r '.title')
      pr_branch=$(echo "$pr_info" | jq -r '.headRefName')
      pr_body=$(echo "$pr_info" | jq -r '.body // ""')
      echo "📋 Found potential duplicate PR #$pr_number: '$pr_title'"

      # Check if this is for the same container
      if echo "$pr_title $pr_body $pr_branch" | grep -qi "$CONTAINER"; then
        # Check if it's for a different version or older
        if ! echo "$pr_title $pr_body $pr_branch" | grep -q "$NEW_VERSION"; then
          echo "🗑️  Closing outdated PR #$pr_number (different version)"

          # Create comment explaining the closure
          comment_body=$(cat <<EOF
🔄 **Automated Closure**

This PR is being automatically closed because a newer version update for \`$CONTAINER\` is available.

**Reason:** Superseded by version \`$NEW_VERSION\`

A new PR will be created with the latest version update.

---
*Closed automatically by the Upstream Version Monitor workflow.*
EOF
)

          # Add the comment and close the PR
          gh pr comment "$pr_number" --body "$comment_body"
          gh pr close "$pr_number" --comment "Superseded by newer version update"

          # Delete the branch if it's an update branch
          if echo "$pr_branch" | grep -q "^update/"; then
            echo "🌿 Deleting branch: $pr_branch"
            git push origin --delete "$pr_branch" 2>/dev/null || echo "⚠️  Branch $pr_branch already deleted or doesn't exist"
          fi
          ((closed_count++))
        else
          echo "⚠️  PR #$pr_number is for the same version ($NEW_VERSION) - skipping closure"
        fi
      else
        echo "ℹ️  PR #$pr_number is for a different container - skipping"
      fi
    fi
  done
done

if [ "$closed_count" -gt 0 ]; then
  echo "✅ Closed $closed_count duplicate/outdated PRs for $CONTAINER"
else
  echo "✅ No duplicate PRs found for $CONTAINER"
fi

# Also check for any PRs that might be using the exact same branch name
target_branch="update/${CONTAINER}-${NEW_VERSION}"
existing_pr=$(gh pr list --head "$target_branch" --state open --json number | jq -r '.[0].number // empty')

if [ -n "$existing_pr" ]; then
  echo "⚠️  Found existing PR #$existing_pr using target branch: $target_branch"
  echo "This suggests the same version update already exists - will skip creating new PR"
  echo "existing_pr_found=true" >> $GITHUB_OUTPUT
else
  echo "existing_pr_found=false" >> $GITHUB_OUTPUT
fi
