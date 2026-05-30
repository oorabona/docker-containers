#!/bin/bash
# Shared utilities for extension building and management
# Used by scripts/build-extensions.sh
# Works both locally and in GitHub Actions
#
# New approach: Build and push extension images to registry
# Main Dockerfile uses COPY --from=ghcr.io/... to get extensions

set -euo pipefail

# Source shared logging utilities (provides log_info, log_success, log_warning, log_error)
HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F log_info &>/dev/null; then
    source "$HELPERS_DIR/logging.sh"
fi

# Source generic template utilities (provides expand_template, has_template_markers)
if ! declare -F expand_template &>/dev/null; then
    source "$HELPERS_DIR/template-utils.sh"
fi

# Source version-set resolver (provides resolve_version_set for generate_dockerfile self-heal)
if ! declare -F resolve_version_set &>/dev/null; then
    source "$HELPERS_DIR/version-set-resolver.sh"
fi


# Get repository owner from git remote or environment
get_repo_owner() {
    if [[ -n "${GITHUB_REPOSITORY_OWNER:-}" ]]; then
        echo "$GITHUB_REPOSITORY_OWNER"
    elif [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
        echo "${GITHUB_REPOSITORY%%/*}"
    else
        git remote get-url origin 2>/dev/null | sed -E 's#.*github.com[:/]([^/]+)/.*#\1#'
    fi
}

# Get registry URL (default to ghcr.io)
get_registry() {
    echo "${EXTENSION_REGISTRY:-ghcr.io}"
}

# Generate extension image name
# Format: ghcr.io/<owner>/ext-<name>:pg<version>-<ext_version>
ext_image_name() {
    local ext_name="$1"
    local ext_version="$2"
    local pg_major="$3"
    local registry="${4:-$(get_registry)}"
    local owner="${5:-$(get_repo_owner)}"

    echo "${registry}/${owner}/ext-${ext_name}:pg${pg_major}-${ext_version}"
}

# Generate local image name (for building)
ext_local_image_name() {
    local ext_name="$1"
    local pg_major="$2"

    echo "localhost/ext-builder-${ext_name}:pg${pg_major}"
}

# Check if gh CLI is available and authenticated
check_gh_auth() {
    if ! command -v gh &>/dev/null; then
        log_error "GitHub CLI (gh) not found. Install with: brew install gh"
        return 1
    fi

    if ! gh auth status &>/dev/null; then
        log_error "GitHub CLI not authenticated. Run: gh auth login"
        return 1
    fi

    return 0
}

# Check if docker/podman is logged into registry
check_registry_auth() {
    local registry="${1:-$(get_registry)}"

    # In CI, authentication is handled by workflow
    if [[ -n "${CI:-}" ]]; then
        return 0
    fi

    # Check if we can access the registry
    if docker login --get-login "$registry" &>/dev/null; then
        return 0
    fi

    log_warning "Not logged into $registry. Run: docker login $registry"
    return 1
}

# Check if an image exists in the registry
image_exists_in_registry() {
    local image="$1"

    # Use docker manifest inspect (works with both Docker and Podman)
    if docker manifest inspect "$image" &>/dev/null; then
        return 0
    fi

    # Fallback: try skopeo if available
    if command -v skopeo &>/dev/null; then
        if skopeo inspect "docker://${image}" &>/dev/null; then
            return 0
        fi
    fi

    return 1
}

# Parse extension config using yq
ext_config() {
    local ext_name="$1"
    local key="$2"
    local config_file="$3"

    if ! command -v yq &>/dev/null; then
        log_error "yq not found"
        return 1
    fi

    yq -r ".extensions.${ext_name}.${key} // \"\"" "$config_file"
}

# List extensions from config, sorted by priority
# Excludes disabled extensions (disabled: true)
# If pg_version is provided, also excludes extensions with max_pg_version < pg_version
list_extensions_by_priority() {
    local config_file="$1"
    local pg_version="${2:-}"

    if [[ -n "$pg_version" ]]; then
        pgver="$pg_version" yq -r '
            [.extensions | to_entries[]
             | select(.value.disabled == true | not)
             | select((.value.max_pg_version // 999) >= env(pgver))]
            | sort_by(.value.priority // 99)
            | .[].key
        ' "$config_file"
    else
        yq -r '.extensions | to_entries | map(select(.value.disabled == true | not)) | sort_by(.value.priority // 99) | .[].key' "$config_file"
    fi
}

# Get PostgreSQL major version from full version string
pg_major_version() {
    local full_version="$1"
    echo "$full_version" | cut -d. -f1
}

# Build extension image
build_ext_image() {
    local ext_name="$1"
    local ext_version="$2"
    local ext_repo="$3"
    local pg_major="$4"
    local dockerfile="$5"
    local context_dir="$6"

    local local_tag
    local_tag=$(ext_local_image_name "$ext_name" "$pg_major")

    log_info "Building $ext_name $ext_version for PostgreSQL $pg_major"

    if ! $DOCKER build \
        -f "$dockerfile" \
        -t "$local_tag" \
        --build-arg MAJOR_VERSION="$pg_major" \
        --build-arg EXT_VERSION="$ext_version" \
        --build-arg EXT_REPO="$ext_repo" \
        "$context_dir"; then
        log_error "Docker build failed for $ext_name $ext_version (pg${pg_major})"
        return 1
    fi

    log_success "Built: $local_tag"
}

# Tag extension image with registry name (for COPY --from= to find it)
tag_ext_image() {
    local ext_name="$1"
    local ext_version="$2"
    local pg_major="$3"

    local local_tag
    local_tag=$(ext_local_image_name "$ext_name" "$pg_major")

    local remote_tag
    remote_tag=$(ext_image_name "$ext_name" "$ext_version" "$pg_major")

    log_info "Tagging $local_tag -> $remote_tag"
    if ! $DOCKER tag "$local_tag" "$remote_tag"; then
        log_error "Failed to tag $local_tag -> $remote_tag"
        return 1
    fi

    log_success "Tagged: $remote_tag"
}

# Push extension image to registry (assumes already tagged)
push_ext_image() {
    local ext_name="$1"
    local ext_version="$2"
    local pg_major="$3"

    local remote_tag
    remote_tag=$(ext_image_name "$ext_name" "$ext_version" "$pg_major")

    log_info "Pushing $remote_tag"
    if ! $DOCKER push "$remote_tag"; then
        log_error "Failed to push $remote_tag"
        return 1
    fi

    log_success "Pushed: $remote_tag"
}

# ============================================================================
# Flavor-aware Dockerfile generation
# Instead of building N bundle images, we template the main Dockerfile
# to only include FROM/COPY for extensions relevant to each flavor+PG version
# ============================================================================

# Get list of extensions for a flavor, filtered by PG version compatibility
# Excludes disabled extensions and those exceeding max_pg_version
get_flavor_extensions() {
    local config_file="$1"
    local flavor="$2"
    local pg_major="$3"

    pgver="$pg_major" flav="$flavor" yq -r '
        . as $root |
        .flavors[env(flav)] // [] | .[] | . as $ext |
        select(
            ($root.extensions[$ext].disabled == true | not) and
            (($root.extensions[$ext].max_pg_version // 999) >= env(pgver))
        )
    ' "$config_file"
}

# Generate a Dockerfile from a template by injecting extension FROM/COPY blocks
# Template must contain markers:
#   # @@EXTENSION_STAGES@@   → replaced by FROM ext-* AS ext-* lines
#   # @@EXTENSION_COPIES@@   → replaced by COPY --from=ext-* lines
#
# Usage: generate_dockerfile <config_file> <template> <flavor> <pg_major> [registry] [owner]
generate_dockerfile() {
    local config_file="$1"
    local template="$2"
    local flavor="$3"
    local pg_major="$4"
    local registry="${5:-$(get_registry)}"
    local owner="${6:-$(get_repo_owner)}"

    # Get filtered extension list for this flavor + PG version
    local extensions
    extensions=$(get_flavor_extensions "$config_file" "$flavor" "$pg_major")

    # Build the FROM stages block
    local stages_block=""
    local copies_block=""
    local all_runtime_deps=""

    if [[ -n "$extensions" ]]; then
        while IFS= read -r ext_name; do
            [[ -z "$ext_name" ]] && continue

            local ext_version
            ext_version=$(ext_config "$ext_name" "version" "$config_file")

            # Determine whether this extension is resolver-backed.
            # An extension is resolver-backed when its config has a non-empty
            # version_set.resolver path — this means build-extensions.sh ran a
            # resolver script to produce a multi-version set, and the resulting
            # versionset artifact may be present in .build-lineage/.
            # When the artifact is absent or malformed, the code below self-heals
            # by re-invoking the resolver and probing the registry for available
            # versions — see the SELF-HEAL block below.
            local _resolver_path
            _resolver_path=$(ext_config "$ext_name" "version_set.resolver" "$config_file")

            # Check for a versionset artifact emitted by build-extensions.
            # When present, emit one FROM+COPY pair per available version in
            # ascending order so the ceiling version (highest) is COPIED LAST —
            # its timescaledb.control (default_version=<ceiling>) wins at
            # install time without needing an explicit override step.
            # Resolve the lineage root robustly.
            # Precedence: ROOT_DIR (build-extensions.sh sets it) → PROJECT_ROOT
            # (build-container.sh sets it in the same shell scope) → git toplevel
            # → pwd fallback.  This ensures the artifact is found when cwd is a
            # container subdirectory (make pushd's into it) and ROOT_DIR is unset.
            local _lineage_root="${ROOT_DIR:-${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
            local versionset_file="${_lineage_root}/.build-lineage/ext-${ext_name}-pg${pg_major}-versionset.json"

            # Resolver-backed extension with NO versionset artifact (or MALFORMED one):
            # SELF-HEAL.
            # The versionset artifact is an optimisation produced by build-extensions.sh.
            # Legitimate callers (skip_extensions CI runs, `./make build postgres`) do not
            # run build-extensions first, so no artifact is present even though the ext
            # images are already in the registry.
            #
            # A malformed/unreadable artifact (truncated JSON, non-JSON garbage, missing
            # .available key) is treated as ABSENT and triggers the same self-heal path.
            # This is NOT silent degradation: if the self-heal resolver also fails, we
            # fail closed — we never silently produce a single-version image for a
            # resolver-backed extension.
            #
            # Self-heal algorithm (when artifact absent OR malformed, AND resolver-backed):
            #   1. Call resolve_version_set to obtain the retained version set.
            #      On resolver failure → fail closed (cannot determine retained set).
            #   2. For each resolved version, probe the registry via image_exists_in_registry.
            #      available = versions whose image is present in the registry.
            #   3. Apply the same strict-semver + <=ceiling + ceiling-present validations
            #      as the artifact-present fast path.
            #   4. If available is empty or ceiling is absent → fail closed.
            #
            # Malformedness check: artifact must be parseable JSON with an .available array.
            # jq -e exits non-zero on parse error OR when the expression evaluates to false.
            local _artifact_valid=0
            if [[ -f "$versionset_file" ]] && command -v jq &>/dev/null; then
                jq -e 'type == "object" and has("available") and (.available | type) == "array"' \
                    "$versionset_file" > /dev/null 2>&1 && _artifact_valid=1
            fi

            if [[ -n "$_resolver_path" ]] && { [[ ! -f "$versionset_file" ]] || [[ "$_artifact_valid" -eq 0 ]]; }; then
                if [[ "$_artifact_valid" -eq 0 ]] && [[ -f "$versionset_file" ]]; then
                    log_error "generate_dockerfile: versionset artifact for $ext_name pg${pg_major} is malformed or missing .available array — treating as absent, triggering self-heal"
                fi
                local _sh_resolved_json
                if ! _sh_resolved_json=$(resolve_version_set "$ext_name" "$pg_major"); then
                    log_error "generate_dockerfile: self-heal resolver failed for $ext_name pg${pg_major} (resolver: $_resolver_path) — cannot determine retained version set"
                    return 1
                fi

                # Validate: must be a non-empty JSON array
                if ! echo "$_sh_resolved_json" | jq -e 'type == "array" and length > 0' > /dev/null 2>&1; then
                    log_error "generate_dockerfile: self-heal resolver for $ext_name returned invalid set: $_sh_resolved_json"
                    return 1
                fi

                # Probe registry presence for each resolved version
                local _sh_available=()
                local _sh_ver
                while IFS= read -r _sh_ver; do
                    [[ -z "$_sh_ver" ]] && continue
                    local _sh_image
                    _sh_image=$(ext_image_name "$ext_name" "$_sh_ver" "$pg_major" "$registry" "$owner")
                    if image_exists_in_registry "$_sh_image" 2>/dev/null; then
                        _sh_available+=("$_sh_ver")
                    fi
                done < <(echo "$_sh_resolved_json" | jq -r '.[]' 2>/dev/null || true)

                if [[ ${#_sh_available[@]} -eq 0 ]]; then
                    log_error "generate_dockerfile: self-heal for $ext_name pg${pg_major}: no resolved images are present in registry — cannot emit multi-version stages"
                    return 1
                fi

                # Build the on-the-fly versionset JSON and write to versionset_file variable
                # so the existing artifact-present path below handles it transparently.
                local _sh_avail_json
                _sh_avail_json=$(printf '%s\n' "${_sh_available[@]}" | jq -Rsc 'split("\n") | map(select(. != ""))')
                # Write to a temp variable consumed by injecting into versionset_file path logic.
                # We construct a synthetic artifact in a temp file and point versionset_file at it.
                local _sh_tmp_artifact
                _sh_tmp_artifact=$(mktemp)
                jq -nc \
                    --arg ext "$ext_name" \
                    --arg pg_major "$pg_major" \
                    --arg ceiling "$ext_version" \
                    --argjson resolved "$_sh_resolved_json" \
                    --argjson available "$_sh_avail_json" \
                    '{ext:$ext, pg_major:$pg_major, ceiling:$ceiling, resolved:$resolved, available:$available, excluded:[]}' \
                    > "$_sh_tmp_artifact"
                versionset_file="$_sh_tmp_artifact"
            fi

            if [[ -f "$versionset_file" ]] && command -v jq &>/dev/null; then
                local available_count
                available_count=$(jq '.available | length' "$versionset_file" 2>/dev/null || echo 0)

                if [[ "$available_count" -gt 0 ]]; then
                    # Fail-closed: the configured ceiling version must be present in
                    # available[].  If it is absent (e.g. build-side probe missed it
                    # due to a ceiling-fatal error), shipping an older-only image
                    # would silently violate the pinned version — abort instead.
                    local ceiling_in_available
                    ceiling_in_available=$(jq --arg ceiling "$ext_version" \
                        '[.available[] | select(. == $ceiling)] | length' \
                        "$versionset_file" 2>/dev/null || echo 0)
                    if [[ "$ceiling_in_available" -eq 0 ]]; then
                        log_error "generate_dockerfile: ceiling $ext_version for $ext_name is absent from available[] in $versionset_file — refusing to emit below-pin image"
                        return 1
                    fi

                    # Validate every available[] entry before emitting Dockerfile stages.
                    # Each entry must:
                    #   1. Match strict semver (^[0-9]+\.[0-9]+\.[0-9]+$)
                    #   2. Be <= the configured ceiling (sort -V: ceiling must be last or equal)
                    # Reject the artifact (fail closed) if any entry is malformed or
                    # above the ceiling — do not silently emit bad/injection-unsafe stages.
                    local _val_ver
                    while IFS= read -r _val_ver; do
                        [[ -z "$_val_ver" ]] && continue
                        if ! [[ "$_val_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                            log_error "generate_dockerfile: available[] entry '${_val_ver}' for $ext_name is not strict semver — refusing to emit unsafe stage"
                            return 1
                        fi
                        # above-ceiling check: if sort -V puts _val_ver AFTER ext_version,
                        # then _val_ver > ext_version → reject.
                        local _highest
                        _highest=$(printf '%s\n%s\n' "$_val_ver" "$ext_version" | sort -V | tail -1)
                        if [[ "$_highest" != "$ext_version" && "$_highest" == "$_val_ver" ]]; then
                            log_error "generate_dockerfile: available[] entry '${_val_ver}' for $ext_name exceeds ceiling ${ext_version} — refusing to emit above-pin stage"
                            return 1
                        fi
                    done < <(jq -r '.available[]' "$versionset_file" 2>/dev/null || true)

                    # Multi-version path: emit one FROM+COPY pair per available version.
                    local raw_versions
                    raw_versions=$(jq -r '.available[]' "$versionset_file" 2>/dev/null || true)

                    if [[ -n "$raw_versions" ]]; then
                        # Sort ascending (sort -V handles semver ordering)
                        local sorted_versions
                        sorted_versions=$(echo "$raw_versions" | sort -V)

                        while IFS= read -r ver; do
                            [[ -z "$ver" ]] && continue
                            # Docker stage names must not contain dots — replace with underscores
                            local ver_alias="${ver//./_}"
                            local image="${registry}/${owner}/ext-${ext_name}:pg${pg_major}-${ver}"
                            stages_block+="FROM ${image} AS ext-${ext_name}-${ver_alias}"$'\n'
                            copies_block+="COPY --from=ext-${ext_name}-${ver_alias} /output/extension/ /tmp/ext/${ext_name}/${ver}/extension/"$'\n'
                            copies_block+="COPY --from=ext-${ext_name}-${ver_alias} /output/lib/ /tmp/ext/${ext_name}/${ver}/lib/"$'\n'
                        done <<< "$sorted_versions"

                        # Collect runtime_deps (if any) — unchanged from single-version path
                        local deps
                        deps=$(ext="$ext_name" yq -r '(.extensions[strenv(ext)].runtime_deps // [])[]' "$config_file" 2>/dev/null || true)
                        if [[ -n "$deps" ]]; then
                            all_runtime_deps+="${deps}"$'\n'
                        fi
                        continue
                    fi
                fi
                # Artifact exists but available=[] — fall through to single-version path
                # using the pinned ceiling (ext_version) which is guaranteed built
                # (ceiling-fatal).  Do NOT fall back to .resolved[] as that may
                # include versions that were never built (musl-failed / absent).
            fi

            # Single-version path (no versionset artifact, or jq unavailable):
            # keep the original behavior — one stage, flat COPY paths.
            local image="${registry}/${owner}/ext-${ext_name}:pg${pg_major}-${ext_version}"
            stages_block+="FROM ${image} AS ext-${ext_name}"$'\n'
            copies_block+="COPY --from=ext-${ext_name} /output/extension/ /tmp/ext/${ext_name}/extension/"$'\n'
            copies_block+="COPY --from=ext-${ext_name} /output/lib/ /tmp/ext/${ext_name}/lib/"$'\n'

            # Collect runtime_deps (if any)
            local deps
            deps=$(ext="$ext_name" yq -r '(.extensions[strenv(ext)].runtime_deps // [])[]' "$config_file" 2>/dev/null || true)
            if [[ -n "$deps" ]]; then
                all_runtime_deps+="${deps}"$'\n'
            fi
        done <<< "$extensions"
    fi

    # Build runtime_deps block (deduplicated)
    local runtime_deps_block=""
    if [[ -n "$all_runtime_deps" ]]; then
        local unique_deps
        unique_deps=$(printf '%s' "$all_runtime_deps" | sort -u | tr '\n' ' ' | sed 's/ $//')
        runtime_deps_block="# Runtime dependencies for extensions (auto-generated from config.yaml)"$'\n'
        runtime_deps_block+="RUN apk add --no-cache ${unique_deps}"$'\n'
    fi

    # Expand template using generic template engine.
    # expand_template returns 0 on success, non-zero on genuine errors
    # (missing template file, no markers provided). Let the exit status
    # propagate so callers see real failures instead of always succeeding.
    expand_template "$template" \
        "EXTENSION_STAGES" "$stages_block" \
        "EXTENSION_COPIES" "$copies_block" \
        "RUNTIME_DEPS" "$runtime_deps_block"
}

# Compute which flavors are affected by a set of changed extensions
# Uses the flavors section from config.yaml to determine which flavors
# include any of the changed extensions.
#
# Usage: compute_affected_flavors <config_file> <comma_separated_extensions> [pg_major]
# Example: compute_affected_flavors postgres/extensions/config.yaml "citus" "18"
#   → "distributed,full"
# Example: compute_affected_flavors postgres/extensions/config.yaml "pgvector,citus"
#   → "distributed,full,vector"
#
# If pg_major is provided, extensions are filtered by max_pg_version and disabled status.
# This prevents including flavors whose only matching extension is incompatible with
# the given PG version (e.g., citus with max_pg_version < pg_major).
#
# Output: comma-separated list of affected flavors (sorted, deduplicated)
# Returns empty string if no flavors are affected
compute_affected_flavors() {
    local config_file="$1"
    local changed_extensions="$2"
    local pg_major="${3:-}"

    if [[ -z "$changed_extensions" ]]; then
        echo ""
        return 0
    fi

    if ! command -v yq &>/dev/null; then
        log_error "yq not found"
        return 1
    fi

    # Get list of flavors
    local flavors
    flavors=$(yq -r '.flavors | keys[]' "$config_file")

    local affected=()

    while IFS= read -r flavor; do
        [[ -z "$flavor" ]] && continue

        # Get extensions in this flavor
        local flavor_exts
        flavor_exts=$(flav="$flavor" yq -r '.flavors[strenv(flav)][]' "$config_file" 2>/dev/null || true)
        [[ -z "$flavor_exts" ]] && continue

        # Check if any changed extension is in this flavor and eligible
        local matched=false
        IFS=',' read -ra ext_array <<< "$changed_extensions"
        for changed_ext in "${ext_array[@]}"; do
            [[ -z "$changed_ext" ]] && continue

            # Check if this extension is in the flavor
            if ! echo "$flavor_exts" | grep -qFx "$changed_ext"; then
                continue
            fi

            # Check if extension is disabled
            local disabled
            disabled=$(ext="$changed_ext" yq -r '.extensions[strenv(ext)].disabled // false' "$config_file")
            [[ "$disabled" == "true" ]] && continue

            # Check max_pg_version compatibility
            if [[ -n "$pg_major" ]]; then
                local max_pg
                max_pg=$(ext="$changed_ext" yq -r '.extensions[strenv(ext)].max_pg_version // 999' "$config_file")
                if (( max_pg < pg_major )); then
                    continue
                fi
            fi

            matched=true
            break
        done

        if [[ "$matched" == "true" ]]; then
            affected+=("$flavor")
        fi
    done <<< "$flavors"

    # Output sorted, comma-separated
    local result=""
    if [[ ${#affected[@]} -gt 0 ]]; then
        result=$(printf '%s\n' "${affected[@]}" | sort -u | paste -sd ',' -)
    fi

    echo "$result"
}

# Pull extension image from registry
pull_ext_image() {
    local ext_name="$1"
    local ext_version="$2"
    local pg_major="$3"

    local remote_tag
    remote_tag=$(ext_image_name "$ext_name" "$ext_version" "$pg_major")

    log_info "Pulling $remote_tag"
    if ! $DOCKER pull "$remote_tag"; then
        log_error "Docker pull failed for $remote_tag"
        return 1
    fi

    log_success "Pulled: $remote_tag"
}

# ============================================================================
# Dashboard helpers: flavor extension list (reads postgres/flavors/*.yaml)
# Used by generate-dashboard.sh to surface per-variant extension metadata.
# These are separate from the build-time helpers above.
# ============================================================================

# get_flavor_extensions_yaml <flavor_name>
# Returns a JSON array of compiled extension names for the given postgres flavor.
# Reads from postgres/flavors/<flavor>.yaml (.extensions key).
# Must be called from the project root directory.
# Returns "[]" (empty array) when the file is missing, the key is absent, or yq fails.
get_flavor_extensions_yaml() {
    local flavor="$1"
    local file="postgres/flavors/${flavor}.yaml"

    if [[ ! -f "$file" ]]; then
        log_warning "extension-utils: flavor file not found: ${file}"
        echo "[]"
        return 0
    fi

    local result
    result=$(yq -o=json '.extensions // []' "$file" 2>/dev/null) || {
        log_warning "extension-utils: failed to read .extensions from ${file}"
        echo "[]"
        return 0
    }

    # yq may return "null" for an absent key — normalise to empty array
    if [[ "$result" == "null" || -z "$result" ]]; then
        echo "[]"
        return 0
    fi

    echo "$result"
}

