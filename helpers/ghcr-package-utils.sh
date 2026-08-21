#!/usr/bin/env bash
# Shared read-only helpers for GHCR extension packages.
#
# This deliberately covers only ext-<name> package version records. The
# container-wide readers in cleanup-outdated-tags.sh and cleanup-old-versions.sh
# are deletion-path code with different reshapes, so keeping them separate
# avoids widening this read helper into those destructive workflows.

# List GHCR package version records for an extension package.
# Output: compact JSON array of {version_id,name,tags,tags_observed,updated_at}
# records. `tags` is always an array of strings. `tags_observed` is true only
# when GitHub returned the tags array (including an authoritative empty array);
# it is false when tag metadata was absent or null, so callers can distinguish
# an observed empty set from an incomplete observation.
# Returns 1 when the API request fails; propagates jq's non-zero status when
# the response cannot be normalized as a sequence of arrays.
_list_ghcr_ext_version_records() {
    local package_name="$1"   # e.g. ext-timescaledb
    local owner="${OWNER:?OWNER is required}"

    local raw_versions
    raw_versions=$(gh api \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "/users/${owner}/packages/container/${package_name}/versions" \
        --paginate 2>/dev/null) || return 1

    jq -ce -s '
      # A successful transport with no JSON document is incomplete, not an
      # authoritative empty registry. A literal JSON [] remains one empty
      # array in the slurped input and is therefore accepted below.
      select(length > 0)
      | def record_tags:
        if ((.metadata? | type) == "object"
            and (.metadata.container? | type) == "object"
            and (.metadata.container | has("tags") and .tags != null)) then
          .metadata.container.tags
          | if type == "array" and all(.[]; type == "string") then .
            else error("GHCR version record tags must be an array of strings")
            end
          | { tags: ., tags_observed: true }
        else { tags: [], tags_observed: false }
        end;
      if all(.[]; type == "array") then
        [.[][] | ({
          version_id: (if .id == null then error("GHCR version record has no id") else (.id | tostring) end),
          name: (if ((.name // "") | type) == "string" then (.name // "") else "" end)
        } + record_tags + {
          updated_at: (if .updated_at == null then "" elif (.updated_at | type) == "string" then .updated_at else "" end)
        })]
      else
        error("GHCR package-versions response must contain JSON arrays")
      end
    ' <<< "$raw_versions"
}
