#!/bin/bash
# Base image cache utilities
# Reads base_image_cache from config.yaml and provides helpers for:
# - Syncing Docker Hub base images to GHCR (CI sync job — sync_base_images_to_ghcr)
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
#   → emit_reachable_cache_args emits --build-arg REMOTE_CR=ghcr.io/<owner> (once per container)
#   → collect_all_cache_images sync_image: ghcr.io/<owner>/library/postgres:<tag>
#
# CHAINED-ON-OWN-BUILD marker (leading-slash source):
#   base_image_cache:
#     - source: /php               # Leading slash = chained-on-own-build semantic marker.
#       tags: ["latest"]           # Declares the container consumes a project-produced image
#   → sync_image: ghcr.io/<owner>/library/php:<tag>  (mirror path, shared with upstream cache)
#   → probe_image: ghcr.io/<owner>/php:<tag>          (project's own published custom container)
#   Sync writes to the library/ path (idempotent with upstream mirror). Probe checks the
#   project-published leaf path to determine REMOTE_CR applicability.
#
# Discriminator: ghcr_repo present and non-empty ⇒ OLD style; absent / null / empty ⇒ NEW style.
# Build-arg emission: emit_reachable_cache_args is the SOLE emitter (per-entry probe-gated,
# validated). Do not add a second emitter.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source logging if not already loaded
if ! declare -F log_error &>/dev/null; then
    source "$SCRIPT_DIR/logging.sh"
fi

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
    #
    # Leading-slash source (e.g. source: /php) is the "chained-on-own-build" marker.
    # For such entries the two image paths diverge:
    #   sync_image  → ghcr.io/<owner>/library/<leaf>:<tag>  (mirror dest, shared with upstream cache)
    #   probe_image → ghcr.io/<owner>/<leaf>:<tag>          (project's published custom container)
    # For all other NEW-style entries: sync_image == probe_image == ghcr.io/<owner>/<source>:<tag>
    # For OLD-style entries: sync_image == probe_image == ghcr.io/<owner>/<ghcr_repo>:<tag>
    local sync_dest_path probe_dest_path
    if [[ "$ghcr_repo" == "null" || -z "$ghcr_repo" ]]; then
        if [[ "$source" == /* ]]; then
            # Leading-slash: chained-on-own-build marker
            local leaf="${source#/}"
            # Normalize any residual double slash (defensive: //foo → /foo → foo)
            leaf="${leaf//\/\//\/}"
            # Only prepend library/ when the leaf is a single-segment path (e.g. "php").
            # Multi-segment leaves (e.g. "library/postgres" from source="/library/postgres")
            # must use the leaf as-is to avoid the double-library path "library/library/postgres".
            if [[ "$leaf" == */* ]]; then
                sync_dest_path="$leaf"
            else
                sync_dest_path="library/${leaf}"
            fi
            probe_dest_path="${leaf}"
        else
            # Normal NEW style: path-preserving mirror
            sync_dest_path="$source"
            probe_dest_path="$source"
        fi
    else
        # OLD style: dedicated GHCR repo name
        sync_dest_path="$ghcr_repo"
        probe_dest_path="$ghcr_repo"
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
                --arg sync_image "ghcr.io/$owner/$sync_dest_path:$full_tag" \
                --arg probe_image "ghcr.io/$owner/$probe_dest_path:$full_tag" \
                '. + [{source: $source, tag: $tag, ghcr_repo: $ghcr_repo, sync_image: $sync_image, probe_image: $probe_image}]')
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
                --arg sync_image "ghcr.io/$owner/$sync_dest_path:$tag" \
                --arg probe_image "ghcr.io/$owner/$probe_dest_path:$tag" \
                '. + [{source: $source, tag: $tag, ghcr_repo: $ghcr_repo, sync_image: $sync_image, probe_image: $probe_image}]')
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
# Output: JSON array of {source, tag, ghcr_repo, sync_image, probe_image} for each unique image to cache.
#   sync_image:  GHCR dest used by sync_base_images_to_ghcr (copy target)
#   probe_image: GHCR ref used for reachability probing (differs for chained-on-own-build sources)
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

    # Deduplicate by sync_image (same repo+tag synced once)
    echo "$all_images" | jq -c 'unique_by(.sync_image)'
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
#   build_version: version string (accepted for API symmetry; unused for arg value construction)
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

# _sync_one_with_backoff <source_ref> <ghcr_image>
#
# Run a single `docker buildx imagetools create` with exponential backoff on
# rate-limit (429) errors. Other failures (auth, network, malformed ref) fail
# fast — backoff only burns wall-time when it cannot help.
#
# Backoff schedule: 5s, 10s, 20s (3 retries max, then give up).
# Sleep is performed via the injectable $SLEEP_CMD (defaults to `sleep`); tests
# pass `:` or `true` to skip real sleeps.
#
# stdout: docker stderr from the last attempt (success or final failure)
# stderr: backoff progress messages
# exit:   0 on eventual success, 1 on persistent failure
_sync_one_with_backoff() {
    local source_ref="$1"
    local ghcr_image="$2"
    local sleep_cmd="${SLEEP_CMD:-sleep}"

    local max_retries=3
    local base_delay=5
    local attempt=0
    local output

    while true; do
        if output=$(docker buildx imagetools create \
            --tag "$ghcr_image" \
            "$source_ref" 2>&1); then
            printf '%s' "$output"
            return 0
        fi

        # Only retry rate-limit / 429 — anything else is non-transient.
        # `toomanyrequests` is Docker Hub's literal error code; the broader
        # phrasing variants are matched too for resilience to future wording.
        if [[ "$output" != *"toomanyrequests"* ]] \
            && [[ "$output" != *"rate limit"* ]] \
            && [[ "$output" != *"429"* ]]; then
            printf '%s' "$output"
            return 1
        fi

        attempt=$((attempt + 1))
        if (( attempt > max_retries )); then
            printf '%s' "$output"
            return 1
        fi

        # 5s, 10s, 20s — sublinear total wait (~35s worst case per image)
        local delay=$((base_delay * (1 << (attempt - 1))))
        echo "  ⏳ rate-limited; backing off ${delay}s (retry ${attempt}/${max_retries})" >&2
        ${sleep_cmd} "$delay"
    done
}

# base_cache_canonical_source_ref <source_img> <tag> [source_registry]
#
# Canonicalize the source side of a base_image_cache entry exactly as the
# sync loop does: strip a chained-on-own leading slash, preserve multi-segment
# paths, and add explicit library/ for single-segment Docker Hub names.
base_cache_canonical_source_ref() {
    local source_img="$1"
    local tag="$2"
    local source_registry="${3:-docker.io}"

    if [[ -z "$source_registry" || -z "$source_img" || -z "$tag" ]]; then
        return 1
    fi

    if [[ "$source_registry" =~ [[:cntrl:]] ]] \
        || [[ "$source_img" =~ [[:cntrl:]] ]] \
        || [[ "$tag" =~ [[:cntrl:]] ]]; then
        return 1
    fi

    local src="${source_img#/}"
    if [[ "$src" == */* ]]; then
        printf '%s/%s:%s' "$source_registry" "$src" "$tag"
    else
        printf '%s/library/%s:%s' "$source_registry" "$src" "$tag"
    fi
}

# base_cache_is_docker_io_origin_ref <image_ref>
#
# True for lineage-style refs that resolve to Docker Hub: bare names
# (alpine:3.21), Docker Hub namespaces (hashicorp/terraform:...), and explicit
# docker.io aliases. False for GHCR/MCR/other explicit registries.
base_cache_is_docker_io_origin_ref() {
    local image_ref="$1"
    local ref="${image_ref%%@*}"

    [[ -z "$ref" || "$ref" == -* || "$ref" == /* ]] && return 1
    [[ "$ref" =~ [[:space:][:cntrl:]] ]] && return 1

    if [[ "$ref" != */* ]]; then
        return 0
    fi

    local first_segment="${ref%%/*}"
    case "$first_segment" in
        docker.io | registry-1.docker.io | index.docker.io)
            return 0
            ;;
    esac

    if [[ "$first_segment" != *"."* && "$first_segment" != *":"* ]]; then
        return 0
    fi

    return 1
}

# base_cache_canonical_docker_io_ref <image_ref>
#
# Convert a lineage base_image_ref that resolves to Docker Hub into the same
# canonical source_ref emitted by sync_base_images_to_ghcr, e.g.
# alpine:3.21 -> docker.io/library/alpine:3.21.
base_cache_canonical_docker_io_ref() {
    local image_ref="$1"
    local ref="${image_ref%%@*}"

    base_cache_is_docker_io_origin_ref "$image_ref" || return 1

    local path_tag="$ref"
    if [[ "$ref" == */* ]]; then
        local first_segment="${ref%%/*}"
        case "$first_segment" in
            docker.io | registry-1.docker.io | index.docker.io)
                path_tag="${ref#*/}"
                ;;
        esac
    fi

    local last_segment="${path_tag##*/}"
    if [[ "$last_segment" != *:* ]]; then
        return 1
    fi

    local source_img="${path_tag%:*}"
    local tag="${path_tag##*:}"
    [[ -z "$source_img" || -z "$tag" ]] && return 1

    base_cache_canonical_source_ref "$source_img" "$tag" "docker.io"
}

# _append_base_sync_manifest_record <source_ref> <sync_image> <digest> <status>
#
# Append a JSONL record when SYNC_MANIFEST_OUT is set. Manifest write failures
# are reported but do not alter sync counters or return code; consumers fail
# closed when a record is absent or digestless.
_append_base_sync_manifest_record() {
    local manifest_out="${SYNC_MANIFEST_OUT:-}"
    [[ -z "$manifest_out" ]] && return 0

    local source_ref="$1"
    local sync_image="$2"
    local digest="$3"
    local status="$4"
    local synced_at
    synced_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local manifest_dir
    manifest_dir="$(dirname "$manifest_out")"
    if [[ "$manifest_dir" != "." ]] && ! mkdir -p "$manifest_dir"; then
        echo "::warning::sync_base_images_to_ghcr: could not create manifest directory ${manifest_dir}"
        return 0
    fi

    if ! jq -cn \
        --arg source_ref "$source_ref" \
        --arg sync_image "$sync_image" \
        --arg digest "$digest" \
        --arg status "$status" \
        --arg synced_at "$synced_at" \
        '{source_ref: $source_ref, sync_image: $sync_image, digest: $digest, status: $status, synced_at: $synced_at}' \
        >> "$manifest_out"; then
        echo "::warning::sync_base_images_to_ghcr: could not append sync manifest record for ${sync_image}"
    fi
}

# _escape_gha_command <value>
#
# Escape a value for safe inclusion in a `::keyword::value` GitHub Actions
# workflow command. Without this, a newline/CR/`%` in the value could
# terminate the command early and inject another (e.g. `::stop-commands::`,
# `::add-mask::`, `::error::`). Mapping per GitHub's runner spec:
#   %  → %25
#   \n → %0A
#   \r → %0D
_escape_gha_command() {
    local s="$1"
    s="${s//\%/%25}"
    s="${s//$'\n'/%0A}"
    s="${s//$'\r'/%0D}"
    printf '%s' "$s"
}

# sync_base_images_to_ghcr <images_json> [source_registry]
#
# Copy each base image from <source_registry> (default: docker.io) to GHCR
# via `docker buildx imagetools create`. Blind copy by default (skip_present=false)
# so the daily upstream-monitor sync always refreshes; per-push builds pass
# skip_present=true to skip GHCR targets that already exist (no docker.io request).
# Per-image failures are logged but non-fatal so a single 429 (or transient
# registry error) does not halt the whole sync run; the outer job's
# `continue-on-error: true` further insulates dependent jobs.
#
# Args:
#   $1 = images_json (output of collect_all_cache_images)
#   $2 = source_registry (optional; default "docker.io")
#   $3 = skip_present (optional; default "false")
#         false = blind copy, no presence check (used by daily upstream-monitor
#                 sync to guarantee a refresh of every base image)
#         true  = probe GHCR target first; skip copy when already present,
#                 avoiding all docker.io requests for up-to-date bases (used by
#                 per-push sync-base-images job to stop Docker Hub 429s)
#
# Output: progress lines printed to stdout, one section per image
# Exit:   0 when all images synced or skipped; 1 when any failed (caller's
#         `continue-on-error: true` keeps dependents unblocked while the
#         non-zero exit surfaces the failure in the Actions UI)
#
# Normalization: docker.io implicitly maps single-segment names (`alpine`) to
# `library/alpine`; for parity with arbitrary registries we always emit the
# explicit `library/` prefix when the source name has no slash.
sync_base_images_to_ghcr() {
    local images_json="$1"
    local source_registry="${2:-docker.io}"
    local skip_present="${3:-false}"

    # Same injection-prevention guard we apply to per-image refs, but at the
    # function boundary so an attacker-influenced source_registry override
    # cannot reach echo/log lines either.
    if [[ "$source_registry" =~ [[:cntrl:]] ]]; then
        echo "::warning::sync_base_images_to_ghcr: refusing source_registry with control characters (possible injection)"
        return 1
    fi

    local count
    count=$(printf '%s' "$images_json" | jq -e 'if type=="array" then length else error("images_json is not an array") end') || {
        log_error "sync_base_images_to_ghcr: images_json is not a JSON array"
        return 1
    }

    if [[ "$count" -eq 0 ]]; then
        echo "ℹ️ No base images to sync"
        return 0
    fi

    echo "📦 Syncing $count unique base images to GHCR (source: $source_registry)"

    local synced=0 skipped=0 failed=0
    while IFS= read -r img; do
        local source_img tag sync_image source_ref output
        source_img=$(echo "$img" | jq -r '.source')
        tag=$(echo "$img" | jq -r '.tag')
        sync_image=$(echo "$img" | jq -r '.sync_image')

        # Reject control characters in any ref. base_image_cache.source is not
        # schema-validated upstream (see top-of-file docstring); a value with
        # a newline / CR would otherwise inject GitHub Actions workflow
        # commands the next time we echo it (e.g. an embedded `::stop-commands::`
        # line). Belt-and-suspenders alongside _escape_gha_command below.
        if [[ "$source_img" =~ [[:cntrl:]] ]] \
            || [[ "$tag" =~ [[:cntrl:]] ]] \
            || [[ "$sync_image" =~ [[:cntrl:]] ]]; then
            echo "::warning::sync_base_images_to_ghcr: refusing image entry with control characters in ref (possible injection)"
            failed=$((failed + 1))
            continue
        fi

        # Keep this canonicalization in one helper so the daily sync manifest and
        # drift consumers share the exact Docker Hub key. The daily sync must keep
        # skip_present=false (blind copy, documented above) so a status=synced
        # manifest digest means GHCR == upstream for this cycle.
        source_ref=$(base_cache_canonical_source_ref "$source_img" "$tag" "$source_registry") || {
            echo "::warning::sync_base_images_to_ghcr: refusing image entry with invalid source ref"
            failed=$((failed + 1))
            continue
        }

        echo ""
        echo "🔄 ${source_ref} → ${sync_image}"

        # Presence gate: when skip_present=true, probe the GHCR target first.
        # `docker manifest inspect` against ghcr.io is read-only and free vs the
        # docker.io pull rate limit — same pattern used in build-container/action.yaml.
        # We use the literal `docker` (not $DOCKER) to match that convention: this is
        # a read-only probe, not a write/build command that dry-run mode should mock.
        if [[ "$skip_present" == "true" ]] && docker manifest inspect "$sync_image" >/dev/null 2>&1; then
            echo "  ⏭️ Already in GHCR, skipping (no docker.io request): ${sync_image}"
            skipped=$((skipped + 1))
            continue
        fi

        if output=$(_sync_one_with_backoff "$source_ref" "$sync_image"); then
            echo "  ✅ Synced"
            if [[ -n "${SYNC_MANIFEST_OUT:-}" ]]; then
                local sync_digest=""
                sync_digest=$(docker buildx imagetools inspect --format '{{json .Manifest}}' "$sync_image" 2>/dev/null | jq -r '.digest // empty' 2>/dev/null || true)
                if [[ -n "$sync_digest" && ! "$sync_digest" =~ ^sha256:[a-f0-9]{64}$ ]]; then
                    echo "::warning::sync_base_images_to_ghcr: GHCR digest for ${sync_image} had unexpected shape; manifest record will fail closed"
                    sync_digest=""
                fi
                _append_base_sync_manifest_record "$source_ref" "$sync_image" "$sync_digest" "synced"
            fi
            synced=$((synced + 1))
        else
            echo "  ⚠️ Failed (continuing; daily sync will retry)"
            # Prefix every line of $output (docker stderr) with "  Error: " so
            # no line can begin at column 0 with `::` and be interpreted as a
            # GitHub Actions workflow command. The upstream registry response
            # is technically attacker-influenced, even if remote. Normalize
            # CR → LF first so a bare carriage return (which GHA also treats
            # as a line terminator) cannot bypass the prefix.
            printf '%s\n' "$output" | tr '\r' '\n' | sed 's/^/  Error: /'
            # Surface in the workflow summary so the maintainer notices that
            # a stale GHCR tag may persist until the next successful sync.
            # Refs come from base_image_cache.source which is not schema-
            # validated (see top-of-file docstring); escape to prevent a
            # newline-bearing value from injecting a second workflow command.
            local safe_source_ref safe_sync_image
            safe_source_ref=$(_escape_gha_command "$source_ref")
            safe_sync_image=$(_escape_gha_command "$sync_image")
            echo "::warning::sync_base_images_to_ghcr: failed to sync ${safe_source_ref} → ${safe_sync_image}"
            _append_base_sync_manifest_record "$source_ref" "$sync_image" "" "failed"
            failed=$((failed + 1))
        fi
    done < <(echo "$images_json" | jq -c '.[]')

    echo ""
    echo "📊 Sync summary: $synced synced, $skipped skipped (already in GHCR), $failed failed"

    # Non-zero exit when any image failed so the GitHub Actions UI surfaces the
    # sync run as red. Dependent jobs are kept unblocked by the caller's
    # `continue-on-error: true`; this signal is for maintainer attention, not
    # for build gating. The daily sync picks up anything missed.
    if (( failed > 0 )); then
        echo "::warning::sync_base_images_to_ghcr: ${failed} image(s) failed to sync; stale GHCR tags may persist until the next successful sync"
        return 1
    fi
    return 0
}

# Export functions
export -f _resolve_tag_template _collect_entry_tags has_base_cache collect_all_cache_images resolve_cache_check_tag remote_cr_applicable emit_reachable_cache_args _sync_one_with_backoff base_cache_canonical_source_ref base_cache_is_docker_io_origin_ref base_cache_canonical_docker_io_ref _append_base_sync_manifest_record _escape_gha_command sync_base_images_to_ghcr
