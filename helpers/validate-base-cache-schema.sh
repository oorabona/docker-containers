#!/bin/bash
# validate-base-cache-schema.sh
# Static schema-validation guard for base_image_cache entries in config.yaml files.
#
# Enforces the dual-schema invariants to prevent malformed or ambiguous configs
# from merging. Called by validate-version-scripts.sh and directly in CI.
#
# Rules enforced:
#   R2. New-style source without slash → REJECT (would collide with a single-segment name)
#   R3. New-style source with registry prefix (dot or colon before first /) → REJECT
#   R4. New-style source with tag (:) or digest (@) → REJECT
#   R5. New-style source with uppercase letters → REJECT
#   R6. New-style source with empty path component (leading/, trailing/, //) → REJECT
#   R7. REMOTE_CR in build_args → REJECT (trust-boundary: must only come from CI override)
#   R8. Old-style entry with absent/empty arg → REJECT
#
# Discriminator: BINARY on ghcr_repo key — present and non-empty ⇒ OLD-style,
# absent / null / empty ⇒ NEW-style. A slash in source is a valid Docker Hub
# namespace separator for either style (e.g. hashicorp/terraform in old-style).
# This matches base-cache-utils.sh exactly:
#   [[ "$ghcr_repo" == "null" || -z "$ghcr_repo" ]]
#
# Deferred (not validated here):
#   - Dockerfile FROM implicit docker.io registry prefix check
#     (migrated-Dockerfile check is a later step in the validation pipeline)
#
# Usage:
#   source helpers/validate-base-cache-schema.sh
#   validate_container_base_cache_schema <container_dir>  # → 0 = ok, non-0 = error
#   validate_all_containers_base_cache_schema <root_dir>  # → 0 = all ok, 1 = any error
#
# Note: intentionally does NOT set -euo pipefail — this file is sourced into
# validate-version-scripts.sh which manages its own error-handling mode.

# ---------------------------------------------------------------------------
# _vbc_error <container> <entry_index> <message>
# Prints a structured error to stderr and returns non-zero.
# ---------------------------------------------------------------------------
_vbc_error() {
    local container="$1"
    local idx="$2"
    local msg="$3"
    printf 'ERROR [%s] base_image_cache[%s]: %s\n' "$container" "$idx" "$msg" >&2
}

# ---------------------------------------------------------------------------
# _vbc_is_new_style <ghcr_repo_value>
# Returns 0 (true) if the value indicates NEW-style (absent / null / empty).
# Mirrors the discriminator in base-cache-utils.sh exactly.
# ---------------------------------------------------------------------------
_vbc_is_new_style() {
    local ghcr_repo="$1"
    [[ "$ghcr_repo" == "null" || -z "$ghcr_repo" ]]
}

# ---------------------------------------------------------------------------
# _vbc_validate_new_style_source <container> <entry_index> <source>
# Validates a NEW-style source value against all format rules.
# Returns 0 on success, 1 on any violation (error already printed to stderr).
# ---------------------------------------------------------------------------
_vbc_validate_new_style_source() {
    local container="$1"
    local idx="$2"
    local source="$3"
    local ok=0

    # R2: must contain a slash (at least one path component separator)
    if [[ "$source" != */* ]]; then
        _vbc_error "$container" "$idx" \
            "new-style source '${source}' has no slash — must be a full path (e.g. library/postgres). Without a slash it would collide with a single-segment image name."
        ok=1
    fi

    # R3: registry prefix — a dot or colon appearing before the first slash
    #     e.g. docker.io/... ghcr.io/... localhost:5000/...
    local prefix_segment="${source%%/*}"
    if [[ "$prefix_segment" == *"."* || "$prefix_segment" == *":"* ]]; then
        _vbc_error "$container" "$idx" \
            "new-style source '${source}' contains a registry prefix ('${prefix_segment}') before the first slash. The source must be a bare path without a registry host."
        ok=1
    fi

    # R4: tag (colon anywhere in source)
    if [[ "$source" == *:* ]]; then
        _vbc_error "$container" "$idx" \
            "new-style source '${source}' contains a colon — tags must not be embedded in source. Use the tags[] or tags_from_versions field instead."
        ok=1
    fi

    # R4b: digest (@ anywhere in source)
    if [[ "$source" == *@* ]]; then
        _vbc_error "$container" "$idx" \
            "new-style source '${source}' contains '@' — digests must not be embedded in source."
        ok=1
    fi

    # R5: uppercase letters
    if [[ "$source" =~ [A-Z] ]]; then
        _vbc_error "$container" "$idx" \
            "new-style source '${source}' contains uppercase letters — OCI image names must be lowercase."
        ok=1
    fi

    # R6: empty path components — leading slash, trailing slash, or double slash
    if [[ "$source" == /* || "$source" == */ || "$source" == *//* ]]; then
        _vbc_error "$container" "$idx" \
            "new-style source '${source}' has an empty path component (leading slash, trailing slash, or '//'). Each path component must be non-empty."
        ok=1
    fi

    # R6b: whitespace in source — a space/tab/newline/CR would break cache probing
    # and imagetools refs. yq -r already strips surrounding quotes but does not
    # validate inner content; check the raw string value here.
    if [[ "$source" =~ [[:space:]] ]]; then
        _vbc_error "$container" "$idx" \
            "new-style source '${source}' contains whitespace (space/tab/newline/CR). Image reference paths must be whitespace-free."
        ok=1
    fi

    # R6c: source must be a non-empty string scalar (not null, not an object/array).
    # yq -r emits "null" for a missing or explicit null value, and emits the object
    # representation for mappings. Both are unusable as an OCI image reference.
    if [[ "$source" == "null" || -z "$source" ]]; then
        _vbc_error "$container" "$idx" \
            "new-style source is null or empty — a concrete Docker Hub path is required (e.g. library/postgres)."
        ok=1
    fi

    return $ok
}

# ---------------------------------------------------------------------------
# _vbc_validate_build_args_config <container_label> <config_file>
# Validates the build_args section of a config.yaml file.
# Enforces:
#   R7  — REMOTE_CR key forbidden (trust boundary: injected by CI only)
#   R7b — all keys must be valid Docker ARG identifiers (^[A-Za-z_][A-Za-z0-9_]*$)
#   R7c — all values must be scalar (string/number/boolean) with no whitespace
#
# Reads build_args as a single JSON object via `yq -o=json -I=0` so that
# embedded newlines in values are caught atomically (line-by-line reads miss them).
# Fail-closed: any yq or jq parse error returns 1 immediately.
# Empty build_args (null or {}) passes all checks (all(…) on empty is true).
#
# Used by: validate_container_base_cache_schema (schema lint)
#          build_args_flags (point-of-use enforcement before docker flags are emitted)
#
# Returns 0 if clean, 1 on any violation.
# ---------------------------------------------------------------------------
_vbc_validate_build_args_config() {
    local container="$1"
    local config_file="$2"
    local errors=0

    # Fail closed: yq and jq are both required.
    command -v yq >/dev/null 2>&1 || {
        printf 'ERROR: yq is required for build_args validation but was not found in PATH.\n' >&2
        return 1
    }
    command -v jq >/dev/null 2>&1 || {
        printf 'ERROR: jq is required for build_args validation but was not found in PATH.\n' >&2
        return 1
    }

    # R7: REMOTE_CR must not appear as a KEY in build_args (trust boundary).
    # Check key presence — not value — so that `REMOTE_CR: null` (or `REMOTE_CR:`
    # with no value, which yq returns as "null") is still rejected.
    local remote_cr_present
    if ! remote_cr_present=$(yq -r '.build_args | has("REMOTE_CR")' "$config_file" 2>/dev/null); then
        printf 'ERROR [%s]: yq failed to parse build_args from config.yaml — treating as validation failure.\n' \
            "$container" >&2
        return 1
    fi
    if [[ "$remote_cr_present" == "true" ]]; then
        printf 'ERROR [%s]: REMOTE_CR found in build_args — this key must never appear in config.yaml. It is injected exclusively by the CI pipeline as a trusted override and must not be controllable via PR-committed config.\n' \
            "$container" >&2
        errors=1
    fi

    # R7b + R7c: validate keys and values using a single JSON read.
    # WHY JSON-based (not line-by-line yq reads):
    # A value containing embedded newlines is emitted as multiple lines by yq;
    # each line appears clean so a loop-based check passes it. Reading the whole
    # build_args map as JSON and running jq on raw bytes catches newlines before
    # any shell line-splitting occurs. \s in jq regex covers space/tab/newline/CR.
    local bargs_json
    if ! bargs_json=$(yq -o=json -I=0 '.build_args // {}' "$config_file" 2>/dev/null); then
        printf 'ERROR [%s]: yq failed to parse build_args as JSON from config.yaml — treating as validation failure.\n' \
            "$container" >&2
        return 1
    fi

    # R7b: every key must match ^[A-Za-z_][A-Za-z0-9_]*$
    local keys_ok
    if ! keys_ok=$(printf '%s' "$bargs_json" | \
            jq -r 'keys | all(test("^[A-Za-z_][A-Za-z0-9_]*$"))' 2>/dev/null); then
        printf 'ERROR [%s]: jq failed to validate build_args keys — treating as validation failure.\n' \
            "$container" >&2
        return 1
    fi
    if [[ "$keys_ok" != "true" ]]; then
        local bad_keys
        bad_keys=$(printf '%s' "$bargs_json" | \
            jq -r 'keys[] | select(test("^[A-Za-z_][A-Za-z0-9_]*$") | not)' 2>/dev/null)
        printf 'ERROR [%s]: build_args contains key(s) that are not valid Docker ARG identifiers: %s\n' \
            "$container" "$bad_keys" >&2
        printf '  Keys must match ^[A-Za-z_][A-Za-z0-9_]*$ (letters, digits, underscores only).\n' >&2
        printf '  A key containing whitespace or CLI flags injects extra docker build-arg tokens.\n' >&2
        errors=1
    fi

    # R7c: every value must be a scalar (string/number/boolean — NOT object/array/null)
    # AND must contain no whitespace (\\s covers space/tab/newline/CR).
    #
    # Two-stage check: object/array values whose tostring has no whitespace would
    # silently pass the whitespace gate alone, so type is checked first.
    local scalars_ok
    if ! scalars_ok=$(printf '%s' "$bargs_json" | \
            jq -r 'to_entries | all(.value | type | . == "string" or . == "number" or . == "boolean")' \
            2>/dev/null); then
        printf 'ERROR [%s]: jq failed to validate build_args value types — treating as validation failure.\n' \
            "$container" >&2
        return 1
    fi
    if [[ "$scalars_ok" != "true" ]]; then
        local bad_types
        bad_types=$(printf '%s' "$bargs_json" | \
            jq -r 'to_entries[] | select(.value | type | . != "string" and . != "number" and . != "boolean") | "\(.key) (type: \(.value|type))"' \
            2>/dev/null)
        printf 'ERROR [%s]: build_args contains value(s) with non-scalar type (object/array/null): %s\n' \
            "$container" "$bad_types" >&2
        printf '  Only string, number, or boolean values are valid Docker --build-arg values.\n' >&2
        errors=1
    fi

    local vals_ok
    if ! vals_ok=$(printf '%s' "$bargs_json" | \
            jq -r 'to_entries | all(.value | tostring | test("\\s") | not)' 2>/dev/null); then
        printf 'ERROR [%s]: jq failed to validate build_args values — treating as validation failure.\n' \
            "$container" >&2
        return 1
    fi
    if [[ "$vals_ok" != "true" ]]; then
        local bad_vals
        bad_vals=$(printf '%s' "$bargs_json" | \
            jq -r 'to_entries[] | select(.value | tostring | test("\\s")) | "\(.key)=\(.value)"' \
            2>/dev/null)
        printf 'ERROR [%s]: build_args contains value(s) with whitespace (space/tab/newline/CR): %s\n' \
            "$container" "$bad_vals" >&2
        printf '  Whitespace in a value injects extra docker CLI tokens when expanded unquoted.\n' >&2
        errors=1
    fi

    return $errors
}

# ---------------------------------------------------------------------------
# validate_container_base_cache_schema <container_dir>
# Validates a single container's config.yaml base_image_cache section.
# Prints errors to stderr; returns 0 if clean, 1 on any violation.
# ---------------------------------------------------------------------------
validate_container_base_cache_schema() {
    local container_dir="$1"

    # Fail closed: yq is required for all schema checks. Without it every yq
    # command substitution silently returns an empty string and exit-0, causing
    # the guard to pass without inspecting anything — a trust-boundary bypass.
    command -v yq >/dev/null 2>&1 || {
        printf 'ERROR: yq is required for base-cache schema validation but was not found in PATH.\n' >&2
        return 1
    }

    # Defensive: container dir name must not contain a slash (repo invariant)
    local container_name
    container_name="$(basename "$container_dir")"
    if [[ "$container_dir" == */* && "$container_name" != "$container_dir" ]]; then
        # Allow paths like "./myapp" or "subdir/myapp" — the name itself must be slash-free
        if [[ "$container_name" == */* ]]; then
            printf 'ERROR [%s]: container dir name contains a slash — repository invariant violated.\n' \
                "$container_dir" >&2
            return 1
        fi
    fi
    # Reject names that are themselves slash-bearing (e.g. "a/b" passed directly)
    if [[ "$container_dir" =~ ^[^/]+/[^/]+ ]] && [[ ! -d "$container_dir" ]]; then
        printf 'ERROR [%s]: container dir does not exist or name is invalid.\n' \
            "$container_dir" >&2
        return 1
    fi
    if [[ ! -d "$container_dir" ]]; then
        printf 'ERROR [%s]: container directory does not exist.\n' "$container_dir" >&2
        return 1
    fi

    local config_file="$container_dir/config.yaml"
    local container
    container="$(basename "$container_dir")"

    # No config.yaml → nothing to validate
    [[ ! -f "$config_file" ]] && return 0

    local errors=0

    if ! _vbc_validate_build_args_config "$container" "$config_file"; then
        errors=1
    fi

    # Count base_image_cache entries — yq error here means we cannot safely validate; fail closed.
    local entry_count
    if ! entry_count=$(yq -r '.base_image_cache | length // 0' "$config_file" 2>/dev/null); then
        printf 'ERROR [%s]: yq failed to read base_image_cache from config.yaml — treating as validation failure.\n' \
            "$container" >&2
        return 1
    fi

    for ((i = 0; i < entry_count; i++)); do
        local source ghcr_repo
        # Fail closed on per-entry yq errors: a parse failure could mask a bad entry.
        if ! source=$(yq -r ".base_image_cache[$i].source" "$config_file" 2>/dev/null); then
            printf 'ERROR [%s]: yq failed to read base_image_cache[%d].source — treating as validation failure.\n' \
                "$container" "$i" >&2
            return 1
        fi
        if ! ghcr_repo=$(yq -r ".base_image_cache[$i].ghcr_repo" "$config_file" 2>/dev/null); then
            printf 'ERROR [%s]: yq failed to read base_image_cache[%d].ghcr_repo — treating as validation failure.\n' \
                "$container" "$i" >&2
            return 1
        fi

        if _vbc_is_new_style "$ghcr_repo"; then
            # NEW-style entry: ghcr_repo absent / null / empty
            if _vbc_validate_new_style_source "$container" "$i" "$source"; then
                : # all checks passed
            else
                errors=1
            fi
        else
            # OLD-style entry: ghcr_repo present and non-empty.
            # A slash in source is valid (Docker Hub namespace, e.g. hashicorp/terraform).
            # No source-format checks apply to old-style — only arg is required (R8).

            # R8: old-style must have a non-empty arg key
            local arg_val
            if ! arg_val=$(yq -r ".base_image_cache[$i].arg // \"\"" "$config_file" 2>/dev/null); then
                printf 'ERROR [%s]: yq failed to read base_image_cache[%d].arg — treating as validation failure.\n' \
                    "$container" "$i" >&2
                return 1
            fi
            if [[ -z "$arg_val" || "$arg_val" == "null" ]]; then
                _vbc_error "$container" "$i" \
                    "old-style entry (ghcr_repo='${ghcr_repo}') has absent or empty 'arg' key. This would produce a malformed --build-arg flag. Add a non-empty arg name (e.g. 'arg: BASE_IMAGE')."
                errors=1
            elif [[ ! "$arg_val" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
                _vbc_error "$container" "$i" \
                    "old-style entry (ghcr_repo='${ghcr_repo}') arg '${arg_val}' is not a valid Docker ARG identifier. Must match ^[A-Za-z_][A-Za-z0-9_]*$ (letters, digits, underscores only — no spaces or special characters). A value like 'FOO BAR' would inject extra docker CLI flags."
                errors=1
            fi
        fi
    done

    return $errors
}

# ---------------------------------------------------------------------------
# validate_all_containers_base_cache_schema <root_dir>
# Scans all container directories under root_dir (directories containing a
# config.yaml) and validates each one.
# Returns 0 if all containers are clean, 1 if any container has violations.
# ---------------------------------------------------------------------------
validate_all_containers_base_cache_schema() {
    local root_dir="${1:-.}"
    local overall=0

    # Find all config.yaml files; derive container dirs from them.
    # Exclude helpers/, archive/, .git/ — same exclusion pattern as validate-version-scripts.sh.
    while IFS= read -r config_file; do
        local container_dir
        container_dir="$(dirname "$config_file")"
        if ! validate_container_base_cache_schema "$container_dir"; then
            overall=1
        fi
    done < <(find "$root_dir" -name "config.yaml" \
        -not -path "*/.git/*" \
        -not -path "*/helpers/*" \
        -not -path "*/archive/*" \
        -not -path "*/extensions/*" \
        | sort)

    return $overall
}

# Export for use by sourcing scripts and subshells
export -f _vbc_error _vbc_is_new_style _vbc_validate_new_style_source \
    _vbc_validate_build_args_config \
    validate_container_base_cache_schema validate_all_containers_base_cache_schema
