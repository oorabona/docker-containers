#!/usr/bin/env bash
# Helpers for auto-build container_scopes workflow input.
#
# Library usage expects helpers/variant-utils.sh to be sourced first when calling
# expand_variants_for_containers, because that function delegates to
# list_container_builds.

normalize_container_scopes() {
    local container_scopes="${1:-}"

    if [[ -z "$container_scopes" ]]; then
        printf ''
        return 0
    fi

    local normalized
    if ! normalized=$(printf '%s' "$container_scopes" | jq -c '
        if type == "object" and
           all(.[]; type == "object" and
             (.versions == null or (.versions | type == "string")) and
             (.flavors == null or (.flavors | type == "string")) and
             (.extensions == null or (.extensions | type == "string")))
        then .
        else error("container_scopes must be a JSON object whose values are scope objects")
        end
    ' 2>/dev/null); then
        echo "::error::container_scopes must be a valid JSON object whose values are objects with optional string versions/flavors/extensions fields" >&2
        return 1
    fi

    if jq -e 'keys | length == 0' <<< "$normalized" >/dev/null; then
        printf ''
        return 0
    fi

    printf '%s\n' "$normalized"
}

container_scope_keys() {
    local container_scopes="${1:-}"
    [[ -z "$container_scopes" ]] && return 0

    printf '%s' "$container_scopes" | jq -r 'keys[]'
}

validate_container_scope_keys() {
    local container_scopes="${1:-}"
    local valid_containers="${2:-}"
    local valid_json
    local bad
    local bad_keys

    [[ -z "$container_scopes" ]] && return 0

    valid_json=$(printf '%s\n' "$valid_containers" | jq -R . | jq -s -c 'map(select(length > 0))')
    bad=$(printf '%s' "$container_scopes" | jq -c --argjson valid "$valid_json" '(keys - $valid)')

    if [[ "$bad" != "[]" ]]; then
        bad_keys=$(printf '%s' "$bad" | jq -r '.[] | @json')
        bad_keys=${bad_keys//$'\n'/, }
        echo "::error::container_scopes key(s) $bad_keys are not valid containers" >&2
        return 1
    fi
}

container_scope_field() {
    local container_scopes="${1:-}"
    local container="${2:-}"
    local field="${3:-}"

    [[ -z "$container_scopes" || -z "$container" || -z "$field" ]] && return 0
    printf '%s' "$container_scopes" | jq -r --arg c "$container" --arg f "$field" '.[$c][$f] // ""'
}

# Classify extension build inputs in a changed-files list.  The result is either
# an empty string (no compilation required), a comma-separated list of known
# extension names, or the literal "all".  "all" is deliberately fail-closed:
# callers must compile every extension when the config cannot be safely
# attributed to individual extension version fields.
extension_scope_for_changes() {
    local changed_files="${1:-}"
    local previous_config="${2:-}"
    local current_config="${3:-postgres/extensions/config.yaml}"
    local config_changed=false
    local shared_input_changed=false
    local file ext
    local -a recipe_extensions=()

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        case "$file" in
            postgres/extensions/build/*.Dockerfile)
                ext="${file#postgres/extensions/build/}"
                ext="${ext%.Dockerfile}"
                recipe_extensions+=("$ext")
                ;;
            postgres/extensions/config.yaml)
                config_changed=true
                ;;
            scripts/resolvers/*|helpers/extension-*.sh)
                shared_input_changed=true
                ;;
        esac
    done <<< "$changed_files"

    if [[ "$shared_input_changed" == "true" ]]; then
        printf 'all\n'
        return 0
    fi

    if [[ ${#recipe_extensions[@]} -eq 0 && "$config_changed" != "true" ]]; then
        printf ''
        return 0
    fi

    local current_json previous_json known_extensions
    if ! current_json=$(yq -o=json '.' "$current_config" 2>/dev/null) ||
       ! jq -e '
         type == "object" and
         (.extensions | type == "object") and
         (.extensions | length > 0) and
         all(.extensions[];
           type == "object" and
           (.version | type == "string") and
           (.rust_version == null or (.rust_version | type == "string")))
       ' <<< "$current_json" >/dev/null 2>&1; then
        printf 'all\n'
        return 0
    fi

    known_extensions=$(jq -r '.extensions | keys[]' <<< "$current_json")
    for ext in "${recipe_extensions[@]}"; do
        if [[ -z "$ext" ]] || ! grep -Fxq "$ext" <<< "$known_extensions"; then
            printf 'all\n'
            return 0
        fi
    done

    local -a scoped_extensions=("${recipe_extensions[@]}")
    if [[ "$config_changed" == "true" ]]; then
        if [[ -z "$previous_config" ]] ||
           ! previous_json=$(yq -o=json '.' "$previous_config" 2>/dev/null) ||
           ! jq -e '
             type == "object" and
             (.extensions | type == "object") and
             (.extensions | length > 0) and
             all(.extensions[];
               type == "object" and
               (.version | type == "string") and
               (.rust_version == null or (.rust_version | type == "string")))
           ' <<< "$previous_json" >/dev/null 2>&1; then
            printf 'all\n'
            return 0
        fi

        # Adding/removing/renaming extensions, changing any shared config, or
        # changing an extension field other than version/rust_version cannot be
        # attributed safely.  Flavor composition is intentionally excluded: it
        # changes final images but does not require recompiling extensions.
        if ! jq -e --argjson previous "$previous_json" '
          (.extensions | keys) == ($previous.extensions | keys) and
          del(.extensions, .flavors) == ($previous | del(.extensions, .flavors)) and
          (.extensions | with_entries(.value |= del(.version, .rust_version))) ==
            ($previous.extensions | with_entries(.value |= del(.version, .rust_version)))
        ' <<< "$current_json" >/dev/null 2>&1; then
            printf 'all\n'
            return 0
        fi

        while IFS= read -r ext; do
            [[ -z "$ext" ]] && continue
            scoped_extensions+=("$ext")
        done < <(jq -r --argjson previous "$previous_json" '
          .extensions | keys[] as $name |
          select(
            (.[$name].version // null) != ($previous.extensions[$name].version // null) or
            (.[$name].rust_version // null) != ($previous.extensions[$name].rust_version // null)
          ) | $name
        ' <<< "$current_json")
    fi

    if [[ ${#scoped_extensions[@]} -eq 0 ]]; then
        printf ''
        return 0
    fi

    printf '%s\n' "${scoped_extensions[@]}" | sort -u | paste -sd, -
}

filter_builds_by_version_flavor_scope() {
    local container_builds="$1"
    local scope_versions="${2:-}"
    local scope_flavors="${3:-}"

    # Convert comma-separated values to JSON arrays for jq. Keep this logic
    # byte-equivalent to the legacy inline action filter.
    local versions_filter="[]"
    if [[ -n "$scope_versions" ]]; then
        versions_filter=$(echo "$scope_versions" | tr ',' '\n' | jq -R . | jq -s -c .)
    fi
    local flavors_filter="[]"
    if [[ -n "$scope_flavors" ]]; then
        flavors_filter=$(echo "$scope_flavors" | tr ',' '\n' | jq -R . | jq -s -c .)
    fi

    echo "$container_builds" | jq -c \
      --argjson sv "$versions_filter" --argjson sf "$flavors_filter" \
      '[.[] | select(
        (($sv | length) == 0 or (.version as $v | $sv | any(. as $s | $v == $s or ($v | startswith($s + ".")) or ($v | startswith($s + "-"))))) and
        (($sf | length) == 0 or (.flavor as $f | $sf | any(. == $f)))
      )]'
}

expand_variants_for_containers() {
    local containers_json="$1"
    local versions_json="$2"
    local expand_retained_map="$3"
    local container_scopes="${4:-}"
    local global_scope_versions="${5:-}"
    local global_scope_flavors="${6:-}"
    local build_scope="${7:-}"

    local builds_json="[]"
    local container

    for container in $(echo "$containers_json" | jq -r '.[]'); do
        local version
        version=$(echo "$versions_json" | jq -r --arg c "$container" '.[$c]')
        echo "Expanding builds for $container (version: $version)..." >&2

        local scope_versions="$global_scope_versions"
        local scope_flavors="$global_scope_flavors"
        if [[ -n "$container_scopes" ]]; then
            scope_versions=$(container_scope_field "$container_scopes" "$container" "versions")
            scope_flavors=$(container_scope_field "$container_scopes" "$container" "flavors")
        fi

        local expand_for_container
        expand_for_container=$(echo "$expand_retained_map" | jq -r --arg c "$container" '.[$c] // "false"')
        # scope_versions is an explicit user request for specific versions. Pre-filtering
        # to latest-only would defeat it. Bypass the filter when scope_versions is set.
        if [[ -n "$scope_versions" ]]; then
            expand_for_container="true"
        fi
        local container_builds
        container_builds=$(list_container_builds "$container" "$version" "$expand_for_container")

        # Apply scope_versions / scope_flavors filters (legacy inputs, or per-container map)
        if [[ -n "$scope_versions" || -n "$scope_flavors" ]]; then
            local before_count
            before_count=$(echo "$container_builds" | jq 'length')
            container_builds=$(filter_builds_by_version_flavor_scope "$container_builds" "$scope_versions" "$scope_flavors")
            local after_count
            after_count=$(echo "$container_builds" | jq 'length')

            if [[ "$before_count" != "$after_count" ]]; then
                echo "  Scope filter: $before_count -> $after_count builds (versions=${scope_versions:-all}, flavors=${scope_flavors:-all})" >&2
            fi
        fi

        # Apply BUILD_SCOPE filter (new unified scope input)
        # Matches against variant, os, build_flavor, or flavor.
        if [[ -n "$build_scope" ]]; then
            local before_count
            before_count=$(echo "$container_builds" | jq 'length')
            container_builds=$(echo "$container_builds" | jq -c \
              --arg s "$build_scope" \
              '[.[] | select(
                (.variant // "" | contains($s)) or
                (.os // "" | contains($s)) or
                (.build_flavor // "" | contains($s)) or
                (.flavor // "" | contains($s))
              )]')
            local after_count
            after_count=$(echo "$container_builds" | jq 'length')
            echo "  BUILD_SCOPE \"$build_scope\" filter: $before_count -> $after_count builds" >&2
        fi

        local count
        count=$(echo "$container_builds" | jq 'length')

        builds_json=$(echo "$builds_json" | jq -c ". + $container_builds")
        echo "  -> $count build(s)" >&2
        echo "$container_builds" | jq -c '.[]' >&2
    done

    echo "$builds_json"
}

export -f normalize_container_scopes container_scope_keys validate_container_scope_keys
export -f container_scope_field extension_scope_for_changes
export -f filter_builds_by_version_flavor_scope expand_variants_for_containers
