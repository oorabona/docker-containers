#!/bin/bash
# Base image cache utilities
# Reads base_image_cache from config.yaml and provides helpers for:
# - Caching Docker Hub base images to GHCR (CI cache job)
# - Resolving cached base image build args (build action)
#
# Config schema supports TWO entry styles (discriminated by ghcr_repo presence):
#
# OLD style (ghcr_repo PRESENT — default for all current containers):
#   base_image_cache:
#     - arg: BASE_IMAGE           # Dockerfile ARG name to override
#       source: ubuntu             # Docker Hub image name (informational)
#       ghcr_repo: ubuntu-base     # GHCR cache repo name
#       tags: ["latest"]           # Tags to cache
#     - arg: BASE_IMAGE
#       source: postgres
#       ghcr_repo: postgres-base
#       tags_from_versions: true   # Derive tags from variants.yaml versions + base_suffix
#
# NEW style (ghcr_repo ABSENT — path-preserving mirror, e.g. postgres):
#   base_image_cache:
#     - source: library/postgres   # FULL upstream path (used as GHCR dest path)
#       tags_from_versions: true   # or tags: ["..."]
#   → get_cache_build_args emits --build-arg REMOTE_CR=ghcr.io/<owner> (once per container)
#   → collect_all_cache_images dest: ghcr.io/<owner>/library/postgres:<tag>
#
# Discriminator: ghcr_repo key ABSENT ⇒ NEW style. PRESENT ⇒ OLD style (takes precedence).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source variant utils for tags_from_versions resolution
source "$SCRIPT_DIR/variant-utils.sh"

# Resolve a tag template by substituting placeholders:
#   ${VERSION}          → detected build version (e.g., "1.14.5-alpine")
#   ${UPSTREAM_VERSION} → raw upstream version via version.sh --upstream (e.g., "1.14.5")
#   ${KEY}              → value from build_args in config.yaml
# Usage: _resolve_tag_template <template> <build_version> <config_file> [container_dir]
# Output: resolved tag string
_resolve_tag_template() {
    local tag_template="$1"
    local build_version="$2"
    local config_file="$3"
    local container_dir="${4:-$(dirname "$config_file")}"

    # Resolve ${VERSION} → detected build version
    local tag="${tag_template//\$\{VERSION\}/$build_version}"

    # Resolve ${UPSTREAM_VERSION} → raw upstream version (without suffix)
    if [[ "$tag" == *'${UPSTREAM_VERSION}'* ]]; then
        local upstream_ver=""
        if [[ -x "$container_dir/version.sh" ]]; then
            upstream_ver=$("$container_dir/version.sh" --upstream 2>/dev/null || true)
        fi
        # Fallback: strip tag suffix from build_version
        if [[ -z "$upstream_ver" ]]; then
            local suffix
            suffix=$("$container_dir/version.sh" --tag-suffix 2>/dev/null || true)
            if [[ -n "$suffix" ]]; then
                upstream_ver="${build_version%"$suffix"}"
            else
                upstream_ver="$build_version"
            fi
        fi
        tag="${tag//\$\{UPSTREAM_VERSION\}/$upstream_ver}"
    fi

    # Resolve ${KEY} → value from build_args in config.yaml
    while [[ "$tag" =~ \$\{([A-Z_]+)\} ]]; do
        local key="${BASH_REMATCH[1]}"
        local val
        val=$(yq -r ".build_args.$key // \"\"" "$config_file")
        tag="${tag//\$\{$key\}/$val}"
    done

    echo "$tag"
}

# Collect tags for a single cache entry, returns JSON array of image objects
# Usage: _collect_entry_tags <container_dir> <config_file> <entry_index> <build_version> <owner>
_collect_entry_tags() {
    local container_dir="$1"
    local config_file="$2"
    local entry_index="$3"
    local build_version="$4"
    local owner="$5"

    local source ghcr_repo
    source=$(yq -r ".base_image_cache[$entry_index].source" "$config_file")
    ghcr_repo=$(yq -r ".base_image_cache[$entry_index].ghcr_repo" "$config_file")

    local tags_from_versions
    tags_from_versions=$(yq -r ".base_image_cache[$entry_index].tags_from_versions // false" "$config_file")

    local images="[]"

    # Discriminate entry style: ghcr_repo PRESENT (non-empty, non-null) → OLD style (unchanged dest).
    # ghcr_repo ABSENT ("null"), explicit nil (yq renders as "null"), or empty string ("") → NEW style:
    # dest path is source (path-preserving mirror).
    local dest_path
    if [[ "$ghcr_repo" == "null" || -z "$ghcr_repo" ]]; then
        # NEW style: source is the full upstream path (e.g. library/postgres)
        # ghcr_image dest: ghcr.io/<owner>/<source>:<tag>
        dest_path="$source"
    else
        # OLD style: dest is the dedicated GHCR repo name
        dest_path="$ghcr_repo"
    fi

    if [[ "$tags_from_versions" == "true" ]]; then
        local base_sfx
        base_sfx=$(base_suffix "$container_dir")

        for major_version in $(list_versions "$container_dir"); do
            local full_tag="${major_version}${base_sfx}"
            images=$(echo "$images" | jq -c \
                --arg source "$source" \
                --arg tag "$full_tag" \
                --arg ghcr_repo "$ghcr_repo" \
                --arg ghcr_image "ghcr.io/$owner/$dest_path:$full_tag" \
                '. + [{source: $source, tag: $tag, ghcr_repo: $ghcr_repo, ghcr_image: $ghcr_image}]')
        done
    else
        local tag_count
        tag_count=$(yq -r ".base_image_cache[$entry_index].tags | length" "$config_file")

        for ((k = 0; k < tag_count; k++)); do
            local tag_template
            tag_template=$(yq -r ".base_image_cache[$entry_index].tags[$k]" "$config_file")
            local tag
            tag=$(_resolve_tag_template "$tag_template" "$build_version" "$config_file" "$container_dir")

            images=$(echo "$images" | jq -c \
                --arg source "$source" \
                --arg tag "$tag" \
                --arg ghcr_repo "$ghcr_repo" \
                --arg ghcr_image "ghcr.io/$owner/$dest_path:$tag" \
                '. + [{source: $source, tag: $tag, ghcr_repo: $ghcr_repo, ghcr_image: $ghcr_image}]')
        done
    fi

    echo "$images"
}

# Check if a container has base_image_cache config
# Usage: has_base_cache <container_dir>
has_base_cache() {
    local container_dir="$1"
    local config_file="$container_dir/config.yaml"

    [[ -f "$config_file" ]] && \
        yq -e '.base_image_cache | length > 0' "$config_file" &>/dev/null
}

# Collect all cache images across all containers, deduplicated
# Usage: collect_all_cache_images <containers_json> <versions_json> <owner>
#   containers_json: JSON array of container names, e.g. '["ansible","postgres"]'
#   versions_json:   JSON object of {container: version}, e.g. '{"ansible":"latest","postgres":"18.1"}'
#   owner:           GHCR owner, e.g. "oorabona"
# Output: JSON array of {source, tag, ghcr_repo, ghcr_image} for each unique image to cache
collect_all_cache_images() {
    local containers_json="$1"
    local versions_json="$2"
    local owner="$3"

    local all_images="[]"

    # Iterate containers from JSON array
    local count
    count=$(echo "$containers_json" | jq -r 'length')

    for ((i = 0; i < count; i++)); do
        local container
        container=$(echo "$containers_json" | jq -r ".[$i]")
        local container_dir="./$container"
        local config_file="$container_dir/config.yaml"

        [[ ! -f "$config_file" ]] && continue
        has_base_cache "$container_dir" || continue

        # Get the detected version for this container
        local build_version
        build_version=$(echo "$versions_json" | jq -r --arg c "$container" '.[$c] // "latest"')

        # Read base_image_cache entries
        local entry_count
        entry_count=$(yq -r '.base_image_cache | length' "$config_file")

        for ((j = 0; j < entry_count; j++)); do
            local entry_images
            entry_images=$(_collect_entry_tags "$container_dir" "$config_file" "$j" "$build_version" "$owner")
            all_images=$(echo "$all_images $entry_images" | jq -c -s 'add')
        done
    done

    # Deduplicate by ghcr_image (same repo+tag cached once)
    echo "$all_images" | jq -c 'unique_by(.ghcr_image)'
}

# Get --build-arg flags for a container's cached base images
# Usage: get_cache_build_args <container_dir> <owner> [build_version]
#   container_dir: e.g. "./ansible"
#   owner:         GHCR owner, e.g. "oorabona"
#   build_version: detected version (for resolving ${VERSION} in tags)
# Output: space-separated --build-arg flags, e.g.:
#   --build-arg BASE_IMAGE=ghcr.io/oorabona/ubuntu-base          (tags: ["latest"])
#   --build-arg ALPINE_BASE=ghcr.io/oorabona/alpine-base:3.21    (tags: ["3.21"])
get_cache_build_args() {
    local container_dir="$1"
    local owner="$2"
    local build_version="${3:-latest}"
    local config_file="$container_dir/config.yaml"

    [[ ! -f "$config_file" ]] && return 0
    has_base_cache "$container_dir" || return 0

    local entry_count
    entry_count=$(yq -r '.base_image_cache | length' "$config_file")

    local args=""
    local remote_cr_emitted=false

    for ((i = 0; i < entry_count; i++)); do
        local ghcr_repo
        ghcr_repo=$(yq -r ".base_image_cache[$i].ghcr_repo" "$config_file")

        if [[ "$ghcr_repo" == "null" || -z "$ghcr_repo" ]]; then
            # NEW style (no ghcr_repo): emit a single REMOTE_CR pointing to the registry root.
            # De-duplicate: only emit once per container regardless of how many new-style entries.
            # Never include tag — the Dockerfile resolves the full image ref via REMOTE_CR + source path.
            # Handles: absent key (yq → "null"), explicit nil (yq → "null"), empty string ("").
            if [[ "$remote_cr_emitted" == "false" ]]; then
                args+=" --build-arg REMOTE_CR=ghcr.io/${owner}"
                remote_cr_emitted=true
            fi
        else
            # OLD style (ghcr_repo PRESENT): emit per-arg flag with dedicated repo path.
            # Never include tag — all Dockerfiles use Two-ARG pattern
            # (tag comes from separate ARG or is hardcoded in FROM)
            # The tags[] field in config.yaml is for the cache job, not build-args
            local arg
            arg=$(yq -r ".base_image_cache[$i].arg" "$config_file")
            args+=" --build-arg ${arg}=ghcr.io/${owner}/${ghcr_repo}"
        fi
    done

    echo "$args"
}

# Resolve the tag to use when verifying a GHCR cache entry is accessible.
# For tags_from_versions entries (e.g. postgres), there is no tags[] array —
# the GHCR copy uses the build_version as the tag (e.g. "18-alpine").
# For tags[] entries, resolves tags[0] via _resolve_tag_template.
# Falls back to "latest" if tags[] is absent and tags_from_versions is false.
# Usage: resolve_cache_check_tag <config_file> <entry_index> <build_version>
# Output: the tag string to use in the docker manifest inspect check

# Decide whether REMOTE_CR should be applied, given per-entry reachability results.
#
# Pure function — no I/O, no docker calls, fully bats-testable.
# Called by emit_reachable_cache_args as the single source of truth for the
# REMOTE_CR applicability decision; also directly testable via BCU-16..21.
#
# Rules:
#   - No new-style entries → print "n/a" (REMOTE_CR not relevant).
#   - All new-style entries reachable → print "apply".
#   - Any new-style entry unreachable → print "drop".
#
# Usage: remote_cr_applicable <config_file> [flag0 flag1 ...]
#   flagN: "true" or "false" per base_image_cache entry (index order).
#          OLD-style entries may pass any value — they are ignored.
# Output (stdout): "apply" | "drop" | "n/a"
remote_cr_applicable() {
    local config_file="$1"
    shift
    local -a flags=("$@")

    local entry_count
    entry_count=$(yq -r '.base_image_cache | length' "$config_file")

    local new_style_count=0
    local new_style_reachable=0

    for ((i = 0; i < entry_count; i++)); do
        local ghcr_repo
        ghcr_repo=$(yq -r ".base_image_cache[$i].ghcr_repo" "$config_file")

        if [[ "$ghcr_repo" == "null" || -z "$ghcr_repo" ]]; then
            # NEW-style entry
            new_style_count=$((new_style_count + 1))
            local flag="${flags[$i]:-false}"
            if [[ "$flag" == "true" ]]; then
                new_style_reachable=$((new_style_reachable + 1))
            fi
        fi
        # OLD-style entries: skip — they do not contribute to REMOTE_CR applicability
    done

    if [[ "$new_style_count" -eq 0 ]]; then
        printf 'n/a'
        return 0
    fi

    if [[ "$new_style_reachable" -eq "$new_style_count" ]]; then
        printf 'apply'
    else
        printf 'drop'
    fi
    return 0
}

# Emit --build-arg flags for reachable cache entries only (per-entry filtered).
#
# Pure function — no I/O, no docker calls, fully bats-testable.
# Each entry is included ONLY when its corresponding probe flag is "true":
#   OLD-style (ghcr_repo present): emit --build-arg <arg>=ghcr.io/<owner>/<ghcr_repo>
#   NEW-style (ghcr_repo absent):  contribute to REMOTE_CR gate (see below)
#
# REMOTE_CR is emitted ONCE iff ALL new-style entries are reachable (all flags "true").
# If any new-style entry is unreachable, REMOTE_CR is omitted entirely — applying a
# shared registry-root knob when even one new-style mirror is missing would hard-fail
# the FROM that references it (no docker.io fallback for a ghcr.io ref).
#
# Old-style entries are independent: a missing old-style mirror only suppresses its
# own --build-arg; reachable old-style entries are always emitted regardless of
# whether other old-style or new-style entries are reachable.
#
# Usage: emit_reachable_cache_args <config_file> <owner> <build_version> [flag0 flag1 ...]
#   config_file:   path to the container's config.yaml
#   owner:         GHCR owner (e.g. "oorabona")
#   build_version: version string for REMOTE_CR tag resolution (unused for arg emission
#                  itself, kept for signature consistency with get_cache_build_args)
#   flagN:         "true" or "false" per base_image_cache entry, in index order.
#                  If fewer flags than entries are provided, missing flags default to "false".
# Output: space-separated --build-arg flags (empty string if nothing reachable)
emit_reachable_cache_args() {
    local config_file="$1"
    local owner="$2"
    # build_version is accepted for API symmetry but not needed for arg value construction
    local container_dir
    container_dir="$(dirname "$config_file")"
    shift 3
    local -a flags=("$@")

    [[ ! -f "$config_file" ]] && return 0
    has_base_cache "$container_dir" || return 0

    local entry_count
    entry_count=$(yq -r '.base_image_cache | length' "$config_file")

    local args=""

    for ((i = 0; i < entry_count; i++)); do
        local ghcr_repo
        ghcr_repo=$(yq -r ".base_image_cache[$i].ghcr_repo" "$config_file")
        local flag="${flags[$i]:-false}"

        if [[ "$ghcr_repo" == "null" || -z "$ghcr_repo" ]]; then
            # NEW-style entry: never emit a per-arg flag here.
            # REMOTE_CR applicability is decided below via remote_cr_applicable.
            :
        else
            # OLD-style entry: validate arg and ghcr_repo regardless of reachability
            # (config error = hard fail), then emit the flag only when this entry's
            # mirror is reachable.
            local arg
            arg=$(yq -r ".base_image_cache[$i].arg" "$config_file")
            # Validate arg is a safe Docker ARG identifier before interpolating into flags.
            # Reject anything that is not ^[A-Za-z_][A-Za-z0-9_]*$ — spaces, hyphens, or
            # embedded shell tokens would inject extra docker flags (config-injection path).
            if [[ ! "$arg" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
                log_error "base_image_cache[$i].arg '${arg}' is not a valid Docker ARG identifier; aborting to prevent flag injection" >&2
                return 1
            fi
            # Validate ghcr_repo against safe GHCR repo path allowlist ^[a-z0-9._/-]+$.
            # Reject anything that is not a safe repo name — a value like
            # "ubuntu-base --network host" would be interpolated into:
            #   --build-arg ARG=ghcr.io/<owner>/ubuntu-base --network host
            # injecting extra docker flags (config-injection path).
            if [[ ! "$ghcr_repo" =~ ^[a-z0-9._/-]+$ ]]; then
                log_error "base_image_cache[$i].ghcr_repo '${ghcr_repo}' contains shell-unsafe characters; aborting to prevent flag injection" >&2
                return 1
            fi
            if [[ "$flag" == "true" ]]; then
                args+=" --build-arg ${arg}=ghcr.io/${owner}/${ghcr_repo}"
            fi
        fi
    done

    # Delegate the REMOTE_CR decision to remote_cr_applicable — single source of truth.
    # "apply": all new-style entries reachable → emit REMOTE_CR.
    # "drop" / "n/a": any new-style missing, or no new-style entries → omit REMOTE_CR.
    if [[ "$(remote_cr_applicable "$config_file" "${flags[@]}")" == "apply" ]]; then
        args+=" --build-arg REMOTE_CR=ghcr.io/${owner}"
    fi

    printf '%s' "${args# }"
}

resolve_cache_check_tag() {
    local config_file="$1"
    local entry_index="$2"
    local build_version="$3"
    local container_dir
    container_dir="$(dirname "$config_file")"

    local tags_from_versions
    tags_from_versions=$(yq -r ".base_image_cache[$entry_index].tags_from_versions // false" "$config_file")

    if [[ "$tags_from_versions" == "true" ]]; then
        # Tags are derived from versions: the GHCR copy uses build_version as the tag
        printf '%s' "$build_version"
        return
    fi

    local raw_tag
    raw_tag=$(yq -r ".base_image_cache[$entry_index].tags[0] // \"latest\"" "$config_file")
    _resolve_tag_template "$raw_tag" "$build_version" "$config_file" "$container_dir"
}

# Export functions
export -f _resolve_tag_template _collect_entry_tags has_base_cache collect_all_cache_images get_cache_build_args resolve_cache_check_tag remote_cr_applicable emit_reachable_cache_args
