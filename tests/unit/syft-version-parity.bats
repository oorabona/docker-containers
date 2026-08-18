#!/usr/bin/env bats

# Guarantees that local SBOM generation and every download-syft workflow step
# use one explicit release. The structural workflow query finds every action use,
# so moved steps still participate and a new call site cannot be silently skipped.
load "../test_helper"

syft_workflow_sites() {
    local workflow_file="$1"

    yq -r '
        .jobs
        | to_entries[]
        | .key as $job
        | .value.steps[]?
        | select((.uses // "" | downcase) | test("^anchore/sbom-action/download-syft@"))
        | [$job, (.name // "unnamed step"), (.with."syft-version" // "")]
        | @tsv
    ' "$workflow_file"
}

@test "syft helper and every download-syft workflow site pin the same explicit release" {
    local helper_version expected_workflow_version site version workflow_file workflow_output job step
    local workflows_dir="${SYFT_WORKFLOWS_DIR:-$PROJECT_ROOT/.github/workflows}"
    local nullglob_was_set=false discovered_sites
    local -a workflow_files workflow_sites

    helper_version="$(sed -nE 's/^[[:space:]]*local syft_version="([^"]+)"$/\1/p' "$PROJECT_ROOT/helpers/sbom-utils.sh")"
    if [ -z "$helper_version" ]; then
        printf 'helpers/sbom-utils.sh does not declare local syft_version\n' >&2
        return 1
    fi
    if [ "$(printf '%s\n' "$helper_version" | wc -l)" -ne 1 ]; then
        printf 'helpers/sbom-utils.sh declares multiple local syft_version values\n' >&2
        return 1
    fi
    expected_workflow_version="v${helper_version}"

    if [ ! -d "$workflows_dir" ]; then
        printf 'syft workflow discovery failed: %s is not a directory\n' "$workflows_dir" >&2
        return 1
    fi

    if shopt -q nullglob; then
        nullglob_was_set=true
    fi
    shopt -s nullglob
    workflow_files=("$workflows_dir"/*.yaml "$workflows_dir"/*.yml)
    if [ "$nullglob_was_set" = false ]; then
        shopt -u nullglob
    fi
    if [ "${#workflow_files[@]}" -eq 0 ]; then
        printf 'syft workflow discovery failed: no workflow files found in %s\n' "$workflows_dir" >&2
        return 1
    fi

    for workflow_file in "${workflow_files[@]}"; do
        if ! workflow_output="$(syft_workflow_sites "$workflow_file")"; then
            printf 'syft workflow discovery failed: yq could not query %s\n' "$workflow_file" >&2
            return 1
        fi
        while IFS=$'\t' read -r job step version; do
            [ -n "$job" ] || continue
            workflow_sites+=("$(basename "$workflow_file"):$job:$step"$'\t'"$version")
        done <<< "$workflow_output"
    done

    if [ "${#workflow_sites[@]}" -ne 4 ]; then
        if [ "${#workflow_sites[@]}" -eq 0 ]; then
            discovered_sites='none'
        else
            discovered_sites=''
            for site in "${workflow_sites[@]}"; do
                discovered_sites+="${discovered_sites:+, }${site%%$'\t'*}"
            done
        fi
        printf 'expected exactly four download-syft workflow sites, found %s; discovered: %s\n' \
            "${#workflow_sites[@]}" "$discovered_sites" >&2
        return 1
    fi
    for site in "${workflow_sites[@]}"; do
        version="${site##*$'\t'}"
        if [ -z "$version" ]; then
            printf 'syft version parity mismatch at %s: missing syft-version; expected %s\n' "${site%%$'\t'*}" "$expected_workflow_version" >&2
            return 1
        fi
        if [ "$version" != "$expected_workflow_version" ]; then
            printf 'syft version parity mismatch at %s: expected %s, got %s\n' "${site%%$'\t'*}" "$expected_workflow_version" "$version" >&2
            return 1
        fi
    done
}
