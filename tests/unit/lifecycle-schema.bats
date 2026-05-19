#!/usr/bin/env bats

# Unit tests: lifecycle schema validation across all container config.yaml files
#
# AC-1  every dependency_sources entry has a valid lifecycle:
# AC-2  schema test green (valid lifecycle + required fields per lifecycle)
# AC-14 lifecycle: REQUIRED on every entry; no implicit default
# AC-17 type: github-tag requires both tag_filter: and version_extract:
# AC-18 tracked/stable-pin/eol-migrate require type: + per-type locator
# AC-19 every stable-pin entry declares supported_until_source:
#
# Valid lifecycle values: tracked | stable-pin | eol-migrate | untracked

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

# All config.yaml files to validate (including postgres/extensions which has no
# dependency_sources — we skip it gracefully)
CONFIGS=()
setup_configs() {
    while IFS= read -r -d '' f; do
        CONFIGS+=("$f")
    done < <(find "$REPO_ROOT" -maxdepth 2 -name "config.yaml" \
        -not -path "*/postgres/extensions/config.yaml" \
        -not -path "*/bats-*" \
        -print0 | sort -z)
}

setup() {
    setup_configs
}

# Valid lifecycle values (documented here for reference; schema tests check inline)
# shellcheck disable=SC2034
VALID_LIFECYCLES="tracked stable-pin eol-migrate untracked"

# ---------------------------------------------------------------------------
# T1 AC-1: every entry has a lifecycle: field
# ---------------------------------------------------------------------------

@test "every dependency_sources entry has a lifecycle field" {
    local missing=0
    local missing_list=""

    for config in "${CONFIGS[@]}"; do
        # Skip configs with no dependency_sources
        if ! yq -e '.dependency_sources' "$config" &>/dev/null; then
            continue
        fi

        local dep_names
        dep_names=$(yq -r '.dependency_sources // {} | keys | .[]' "$config")
        local container
        container=$(basename "$(dirname "$config")")

        while IFS= read -r dep; do
            [[ -z "$dep" ]] && continue
            local lc
            lc=$(yq -r ".dependency_sources.${dep}.lifecycle // \"\"" "$config")
            if [[ -z "$lc" || "$lc" == "null" ]]; then
                missing=$((missing + 1))
                missing_list="${missing_list}\n  ${container}/${dep}"
            fi
        done <<< "$dep_names"
    done

    if [[ "$missing" -gt 0 ]]; then
        echo "FAIL: $missing entries missing lifecycle: field:${missing_list}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# T1 AC-2: lifecycle value is in the valid enum
# ---------------------------------------------------------------------------

@test "every lifecycle value is in the valid enum {tracked,stable-pin,eol-migrate,untracked}" {
    local bad=0
    local bad_list=""

    for config in "${CONFIGS[@]}"; do
        if ! yq -e '.dependency_sources' "$config" &>/dev/null; then
            continue
        fi

        local dep_names
        dep_names=$(yq -r '.dependency_sources // {} | keys | .[]' "$config")
        local container
        container=$(basename "$(dirname "$config")")

        while IFS= read -r dep; do
            [[ -z "$dep" ]] && continue
            local lc
            lc=$(yq -r ".dependency_sources.${dep}.lifecycle // \"\"" "$config")
            case "$lc" in
                tracked|stable-pin|eol-migrate|untracked) ;;
                *)
                    bad=$((bad + 1))
                    bad_list="${bad_list}\n  ${container}/${dep}: '${lc}'"
                    ;;
            esac
        done <<< "$dep_names"
    done

    if [[ "$bad" -gt 0 ]]; then
        echo "FAIL: $bad entries with invalid lifecycle:${bad_list}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# T1 AC-2: stable-pin and eol-migrate entries require liveness_url:
# ---------------------------------------------------------------------------

@test "stable-pin and eol-migrate entries declare liveness_url" {
    local missing=0
    local missing_list=""

    for config in "${CONFIGS[@]}"; do
        if ! yq -e '.dependency_sources' "$config" &>/dev/null; then
            continue
        fi

        local dep_names
        dep_names=$(yq -r '.dependency_sources // {} | keys | .[]' "$config")
        local container
        container=$(basename "$(dirname "$config")")

        while IFS= read -r dep; do
            [[ -z "$dep" ]] && continue
            local lc
            lc=$(yq -r ".dependency_sources.${dep}.lifecycle // \"\"" "$config")
            if [[ "$lc" == "stable-pin" || "$lc" == "eol-migrate" ]]; then
                local url
                url=$(yq -r ".dependency_sources.${dep}.liveness_url // \"\"" "$config")
                if [[ -z "$url" || "$url" == "null" ]]; then
                    missing=$((missing + 1))
                    missing_list="${missing_list}\n  ${container}/${dep} (lifecycle: ${lc})"
                fi
            fi
        done <<< "$dep_names"
    done

    if [[ "$missing" -gt 0 ]]; then
        echo "FAIL: $missing stable-pin/eol-migrate entries missing liveness_url:${missing_list}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# T1 AC-2: stable-pin entries require supported_until: (ISO date)
# ---------------------------------------------------------------------------

@test "stable-pin entries declare supported_until" {
    local missing=0
    local missing_list=""

    for config in "${CONFIGS[@]}"; do
        if ! yq -e '.dependency_sources' "$config" &>/dev/null; then
            continue
        fi

        local dep_names
        dep_names=$(yq -r '.dependency_sources // {} | keys | .[]' "$config")
        local container
        container=$(basename "$(dirname "$config")")

        while IFS= read -r dep; do
            [[ -z "$dep" ]] && continue
            local lc
            lc=$(yq -r ".dependency_sources.${dep}.lifecycle // \"\"" "$config")
            if [[ "$lc" == "stable-pin" ]]; then
                local until_date
                until_date=$(yq -r ".dependency_sources.${dep}.supported_until // \"\"" "$config")
                if [[ -z "$until_date" || "$until_date" == "null" ]]; then
                    missing=$((missing + 1))
                    missing_list="${missing_list}\n  ${container}/${dep}"
                fi
            fi
        done <<< "$dep_names"
    done

    if [[ "$missing" -gt 0 ]]; then
        echo "FAIL: $missing stable-pin entries missing supported_until:${missing_list}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# T15 AC-19: stable-pin entries require supported_until_source:
# ---------------------------------------------------------------------------

@test "stable-pin entries declare supported_until_source (URL)" {
    local missing=0
    local missing_list=""

    for config in "${CONFIGS[@]}"; do
        if ! yq -e '.dependency_sources' "$config" &>/dev/null; then
            continue
        fi

        local dep_names
        dep_names=$(yq -r '.dependency_sources // {} | keys | .[]' "$config")
        local container
        container=$(basename "$(dirname "$config")")

        while IFS= read -r dep; do
            [[ -z "$dep" ]] && continue
            local lc
            lc=$(yq -r ".dependency_sources.${dep}.lifecycle // \"\"" "$config")
            if [[ "$lc" == "stable-pin" ]]; then
                local src
                src=$(yq -r ".dependency_sources.${dep}.supported_until_source // \"\"" "$config")
                if [[ -z "$src" || "$src" == "null" ]]; then
                    missing=$((missing + 1))
                    missing_list="${missing_list}\n  ${container}/${dep}"
                fi
            fi
        done <<< "$dep_names"
    done

    if [[ "$missing" -gt 0 ]]; then
        echo "FAIL: $missing stable-pin entries missing supported_until_source:${missing_list}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# T1 AC-18: tracked/stable-pin/eol-migrate entries require type: field
# ---------------------------------------------------------------------------

@test "tracked, stable-pin, eol-migrate entries declare type" {
    local missing=0
    local missing_list=""

    for config in "${CONFIGS[@]}"; do
        if ! yq -e '.dependency_sources' "$config" &>/dev/null; then
            continue
        fi

        local dep_names
        dep_names=$(yq -r '.dependency_sources // {} | keys | .[]' "$config")
        local container
        container=$(basename "$(dirname "$config")")

        while IFS= read -r dep; do
            [[ -z "$dep" ]] && continue
            local lc
            lc=$(yq -r ".dependency_sources.${dep}.lifecycle // \"\"" "$config")
            if [[ "$lc" == "tracked" || "$lc" == "stable-pin" || "$lc" == "eol-migrate" ]]; then
                local t
                t=$(yq -r ".dependency_sources.${dep}.type // \"\"" "$config")
                if [[ -z "$t" || "$t" == "null" ]]; then
                    missing=$((missing + 1))
                    missing_list="${missing_list}\n  ${container}/${dep} (lifecycle: ${lc})"
                fi
            fi
        done <<< "$dep_names"
    done

    if [[ "$missing" -gt 0 ]]; then
        echo "FAIL: $missing entries missing type: field:${missing_list}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# T1 AC-18: per-type locator check (repo/package/gem)
# ---------------------------------------------------------------------------

@test "each type has the required locator (github-tag/release=repo, pypi=package, rubygems=gem)" {
    local bad=0
    local bad_list=""

    for config in "${CONFIGS[@]}"; do
        if ! yq -e '.dependency_sources' "$config" &>/dev/null; then
            continue
        fi

        local dep_names
        dep_names=$(yq -r '.dependency_sources // {} | keys | .[]' "$config")
        local container
        container=$(basename "$(dirname "$config")")

        while IFS= read -r dep; do
            [[ -z "$dep" ]] && continue
            local t
            t=$(yq -r ".dependency_sources.${dep}.type // \"\"" "$config")
            [[ -z "$t" || "$t" == "null" ]] && continue

            case "$t" in
                github-release|github-tag)
                    local repo
                    repo=$(yq -r ".dependency_sources.${dep}.repo // \"\"" "$config")
                    if [[ -z "$repo" || "$repo" == "null" ]]; then
                        bad=$((bad + 1))
                        bad_list="${bad_list}\n  ${container}/${dep}: type=${t} missing repo:"
                    fi
                    ;;
                pypi)
                    local pkg
                    pkg=$(yq -r ".dependency_sources.${dep}.package // \"\"" "$config")
                    if [[ -z "$pkg" || "$pkg" == "null" ]]; then
                        bad=$((bad + 1))
                        bad_list="${bad_list}\n  ${container}/${dep}: type=pypi missing package:"
                    fi
                    ;;
                rubygems)
                    local gem
                    gem=$(yq -r ".dependency_sources.${dep}.gem // \"\"" "$config")
                    if [[ -z "$gem" || "$gem" == "null" ]]; then
                        bad=$((bad + 1))
                        bad_list="${bad_list}\n  ${container}/${dep}: type=rubygems missing gem:"
                    fi
                    ;;
            esac
        done <<< "$dep_names"
    done

    if [[ "$bad" -gt 0 ]]; then
        echo "FAIL: $bad entries with missing type locator:${bad_list}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# T14 AC-17: github-tag type requires tag_filter: and version_extract:
# ---------------------------------------------------------------------------

@test "github-tag entries declare both tag_filter and version_extract" {
    local missing=0
    local missing_list=""

    for config in "${CONFIGS[@]}"; do
        if ! yq -e '.dependency_sources' "$config" &>/dev/null; then
            continue
        fi

        local dep_names
        dep_names=$(yq -r '.dependency_sources // {} | keys | .[]' "$config")
        local container
        container=$(basename "$(dirname "$config")")

        while IFS= read -r dep; do
            [[ -z "$dep" ]] && continue
            local t
            t=$(yq -r ".dependency_sources.${dep}.type // \"\"" "$config")
            if [[ "$t" == "github-tag" ]]; then
                local tf ve
                tf=$(yq -r ".dependency_sources.${dep}.tag_filter // \"\"" "$config")
                ve=$(yq -r ".dependency_sources.${dep}.version_extract // \"\"" "$config")
                if [[ -z "$tf" || "$tf" == "null" ]]; then
                    missing=$((missing + 1))
                    missing_list="${missing_list}\n  ${container}/${dep}: missing tag_filter"
                fi
                if [[ -z "$ve" || "$ve" == "null" ]]; then
                    missing=$((missing + 1))
                    missing_list="${missing_list}\n  ${container}/${dep}: missing version_extract"
                fi
            fi
        done <<< "$dep_names"
    done

    if [[ "$missing" -gt 0 ]]; then
        echo "FAIL: $missing github-tag entries missing tag_filter/version_extract:${missing_list}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Negative test: schema rejects an entry missing lifecycle (fail-closed)
# This test uses a synthetic config in BATS_TEST_TMPDIR.
# AC-14: lifecycle is REQUIRED; no implicit default.
# ---------------------------------------------------------------------------

@test "schema test FAILS for an entry missing lifecycle (fail-closed regression lock)" {
    # Create a synthetic config with a missing lifecycle entry
    local tmpconfig="$BATS_TEST_TMPDIR/bad-config.yaml"
    cat > "$tmpconfig" <<'EOF'
dependency_sources:
  SOME_DEP:
    monitor: false
    reason: "no lifecycle declared — should fail schema"
EOF

    # Run the same check logic as the 'every entry has a lifecycle' test
    local dep_names
    dep_names=$(yq -r '.dependency_sources // {} | keys | .[]' "$tmpconfig")
    local found_missing=0
    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        local lc
        lc=$(yq -r ".dependency_sources.${dep}.lifecycle // \"\"" "$tmpconfig")
        if [[ -z "$lc" || "$lc" == "null" ]]; then
            found_missing=1
        fi
    done <<< "$dep_names"

    # Assert: the schema check DID catch the missing lifecycle
    [ "$found_missing" -eq 1 ]
}
