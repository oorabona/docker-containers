#!/usr/bin/env bash

# Check 3rd party dependency versions across all containers
# Compares pinned versions in config.yaml with latest upstream releases
#
# Usage:
#   check-dependency-versions.sh [container-name]   # Check specific container
#   check-dependency-versions.sh --all               # Check all containers
#   check-dependency-versions.sh --dry-run [target]  # Show planned updates without modifying
#
# Output modes:
#   --json      Machine-readable JSON (default for CI / piped output)
#   --summary   Human-readable table (default for terminal)
#
# Exit code: always 0 (errors collected in output, not fatal)
#
# lifecycle: field dispatch:
#   untracked   → skip silently (declared, not silent boolean)
#   eol-migrate → LOUD surfaced signal every run (never continue-skipped)
#   stable-pin  → resolve latest within pin + date escalation via STABLE_PIN_WARN_DAYS
#   tracked     → resolve normally (open update PRs)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../helpers/logging.sh
# shellcheck disable=SC1091
source "$PROJECT_ROOT/helpers/logging.sh"

# Named constant: days before supported_until to emit a ::warning:: countdown
# Configurable via env; named so it is never a magic number.
STABLE_PIN_WARN_DAYS="${STABLE_PIN_WARN_DAYS:-90}"

# Escape dynamic strings for GHA workflow-commands (::warning::/::error::).
# Per GHA spec: % → %25, CR → %0D, LF → %0A.
# Must be applied to ALL dynamic ${var} interpolations in annotation messages.
_gha_escape() {
    local s="$1"
    s="${s//%/%25}"
    s="${s//$'\r'/%0D}"
    s="${s//$'\n'/%0A}"
    printf '%s' "$s"
}

normalize_gitlab_host() {
    local host="$1"

    host="${host#https://}"
    host="${host#http://}"
    host="${host%/}"

    [[ "$host" =~ ^[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || return 1
    printf '%s' "$host"
}

gitlab_api_url_from_host() {
    local host

    host=$(normalize_gitlab_host "$1") || return 1
    printf 'https://%s/api/v4' "$host"
}

# Classify semver change type between two versions
# Returns: major, minor, patch, or unknown
classify_version_change() {
    local current="$1"
    local latest="$2"

    # Split on dots
    IFS='.' read -ra cur_parts <<< "$current"
    IFS='.' read -ra new_parts <<< "$latest"

    local cur_major="${cur_parts[0]:-0}"
    local cur_minor="${cur_parts[1]:-0}"
    local new_major="${new_parts[0]:-0}"
    local new_minor="${new_parts[1]:-0}"

    if [[ "$cur_major" != "$new_major" ]]; then
        echo "major"
    elif [[ "$cur_minor" != "$new_minor" ]]; then
        echo "minor"
    else
        echo "patch"
    fi
}

# Build source URL for a dependency update
# Args: type source version [raw_tag]
#   raw_tag: optional 4th argument for github-tag type.
#     For github-release: raw_tag unused; v${version} path is always correct.
#     For github-tag: use /tree/${raw_tag} (the git ref always resolves; no
#       dependence on a release being published). Falls back to v${version}
#       when raw_tag is empty.
#     Assumption: raw_tag values from the upstream API are simple [-.\w]+ shaped
#       (e.g. "openssl-3.5.6", "pcre2-10.47") — no URL-special chars in practice.
build_source_url() {
    local type="$1"
    local source="$2"
    local version="$3"
    local raw_tag="${4:-}"
    local source_host="${5:-}"

    case "$type" in
        github-release)
            echo "https://github.com/${source}/releases/tag/v${version}"
            ;;
        github-tag)
            # Use /tree/ ref path — works for any git tag without requiring a
            # published GitHub Release. Falls back to v${version} when raw_tag
            # is empty (e.g. caller could not fetch raw tag).
            if [[ -n "$raw_tag" ]]; then
                echo "https://github.com/${source}/tree/${raw_tag}"
            else
                echo "https://github.com/${source}/tree/v${version}"
            fi
            ;;
        gitlab-tags)
            local project_path_web
            local web_host
            web_host=$(normalize_gitlab_host "${source_host:-gitlab.torproject.org}") || {
                echo ""
                return
            }
            project_path_web="${source//%2F/\/}"
            project_path_web="${project_path_web//%2f/\/}"
            if [[ -n "$raw_tag" ]]; then
                echo "https://${web_host}/${project_path_web}/-/tags/${raw_tag}"
            else
                echo "https://${web_host}/${project_path_web}/-/tags/v${version}"
            fi
            ;;
        pypi)
            echo "https://pypi.org/project/${source}/${version}/"
            ;;
        rubygems)
            echo "https://rubygems.org/gems/${source}/versions/${version}"
            ;;
        *)
            echo ""
            ;;
    esac
}

# Discover containers that have dependency_sources in config.yaml
discover_containers() {
    local containers=()

    for config in "$PROJECT_ROOT"/*/config.yaml; do
        local container_dir
        container_dir=$(dirname "$config")
        local container_name
        container_name=$(basename "$container_dir")

        # Check if config has dependency_sources section
        if yq -e '.dependency_sources' "$config" &>/dev/null; then
            containers+=("$container_name")
        fi
    done

    # Always include postgres (uses extensions/config.yaml, not dependency_sources)
    if [[ -f "$PROJECT_ROOT/postgres/version-extension.sh" ]]; then
        containers+=("postgres")
    fi

    printf '%s\n' "${containers[@]}" | sort -u
}

# Pre-flight: validate that all build_args have dependency_sources entries (INV-05)
preflight_check() {
    local container="$1"
    local config="$PROJECT_ROOT/${container}/config.yaml"

    [[ -f "$config" ]] || return 0

    # Get all build_args keys
    local build_args
    build_args=$(yq -r '.build_args // {} | keys | .[]' "$config" 2>/dev/null) || return 0

    # Get all dependency_sources keys
    local dep_sources
    dep_sources=$(yq -r '.dependency_sources // {} | keys | .[]' "$config" 2>/dev/null) || true

    # Check each build_arg has a dependency_sources entry
    local missing=0
    while IFS= read -r arg; do
        [[ -z "$arg" ]] && continue
        if ! grep -qx "$arg" <<< "$dep_sources"; then
            log_error "[${container}] build_arg '${arg}' has no dependency_sources entry (INV-05)"
            missing=$((missing + 1))
        fi
    done <<< "$build_args"

    if [[ "$missing" -gt 0 ]]; then
        log_error "[${container}] ${missing} build_arg(s) missing from dependency_sources — aborting"
        return 1
    fi
}

# Check dependencies for a container using dependency_sources config
check_container_deps() {
    local container="$1"
    local config="$PROJECT_ROOT/${container}/config.yaml"

    local updates_json="[]"
    local errors_json="[]"

    # Read dependency_sources entries
    local dep_names
    dep_names=$(yq -r '.dependency_sources // {} | keys | .[]' "$config" 2>/dev/null) || {
        errors_json=$(echo "$errors_json" | jq --arg msg "Failed to read dependency_sources from ${container}/config.yaml" '. + [$msg]')
        _emit_container_result "$container" "$updates_json" "$errors_json"
        return
    }

    while IFS= read -r dep_name; do
        [[ -z "$dep_name" ]] && continue

        # Read lifecycle (required field — schema test gates this)
        local lifecycle
        lifecycle=$(YQ_DEP="$dep_name" yq -r '.dependency_sources[strenv(YQ_DEP)].lifecycle // ""' "$config")

        # Lifecycle dispatch — replaces the binary monitor:false blanket continue.
        # AC-3: eol-migrate MUST NOT be silently skipped.
        case "$lifecycle" in
            untracked)
                # Declared skip: genuinely nothing to track (base-image fallback,
                # build parallelism, "always latest" CLI). Skip is now explicit.
                continue
                ;;
            eol-migrate)
                # LOUD surfaced signal every run — the honest replacement for silent monitor:false.
                # This is the #448 root-cause inversion fix: never continue-skip an eol-migrate.
                local reason
                reason=$(YQ_DEP="$dep_name" yq -r '.dependency_sources[strenv(YQ_DEP)].reason // "pinned to EOL line"' "$config")
                echo "::warning::$(_gha_escape "${container}/${dep_name}"): lifecycle=eol-migrate — manual migration required. $(_gha_escape "${reason}")" >&2
                log_error "[${container}] ${dep_name}: EOL dependency — manual migration required: ${reason}" >&2
                errors_json=$(echo "$errors_json" | jq \
                    --arg msg "${dep_name}: EOL dependency (eol-migrate) — manual migration required: ${reason}" \
                    '. + [$msg]')
                # continue: do NOT fall through to version resolution.
                # An eol-migrate dep must NEVER enter updates_json and trigger an
                # auto-PR — the intent is "manual migration required", not
                # "auto-bump to latest". The downstream create-update-prs job has
                # no lifecycle filter, so the single point of enforcement is here.
                # Contract: create-update-prs reads only what enters updates_json;
                # eol-migrate entries are excluded at this dispatch site.
                continue
                ;;
            stable-pin)
                # Deliberately pinned to a supported branch/LTS.
                # T10: Date escalation — compare today vs supported_until.
                local supported_until
                supported_until=$(YQ_DEP="$dep_name" yq -r '.dependency_sources[strenv(YQ_DEP)].supported_until // ""' "$config")
                if [[ -n "$supported_until" && "$supported_until" != "null" ]]; then
                    local today_epoch until_epoch days_left
                    today_epoch=$(date +%s)
                    until_epoch=$(date -d "$supported_until" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$supported_until" +%s 2>/dev/null || echo "0")
                    days_left=$(( (until_epoch - today_epoch) / 86400 ))

                    if [[ "$days_left" -le 0 ]]; then
                        # Past EOL: treat as eol-migrate-equivalent — loud every run.
                        # STOP here: do NOT fall through to version resolution.
                        # An EOL-passed stable-pin must never enter updates_json and
                        # trigger an auto-PR — the intent is "manual migration required".
                        # Contract mirrors eol-migrate: surface-only, then continue.
                        echo "::warning::$(_gha_escape "${container}/${dep_name}"): lifecycle=stable-pin has PASSED supported_until=$(_gha_escape "${supported_until}") — treat as eol-migrate. Manual migration required." >&2
                        log_error "[${container}] ${dep_name}: stable-pin EOL date passed (${supported_until}) — migration required" >&2
                        errors_json=$(echo "$errors_json" | jq \
                            --arg msg "${dep_name}: stable-pin EOL date passed (${supported_until}) — migration required" \
                            '. + [$msg]')
                        continue
                    elif [[ "$days_left" -le "$STABLE_PIN_WARN_DAYS" ]]; then
                        # Within countdown window: emit warning
                        echo "::warning::$(_gha_escape "${container}/${dep_name}"): lifecycle=stable-pin EOL approaching — $(_gha_escape "${days_left}") days until $(_gha_escape "${supported_until}") (STABLE_PIN_WARN_DAYS=${STABLE_PIN_WARN_DAYS})" >&2
                        log_info "[${container}] ${dep_name}: stable-pin countdown: ${days_left} days until EOL ${supported_until}" >&2
                    fi
                    # If days_left > STABLE_PIN_WARN_DAYS: silent OK (no warning yet)
                fi
                # Fall through to version resolution ONLY when still within support window.
                # (Past-EOL branch above issues continue before reaching here.)
                ;;
            tracked|"")
                # tracked: actively follow latest upstream.
                # "" (empty): backward-compat for entries that lack lifecycle: yet;
                # only reached if schema test is not gating CI.
                ;;
            *)
                errors_json=$(echo "$errors_json" | jq \
                    --arg msg "${dep_name}: unknown lifecycle '${lifecycle}'" \
                    '. + [$msg]')
                continue
                ;;
        esac

        # eol-migrate has already exited the loop iteration above (via continue).
        # For stable-pin/tracked: resolve normally.

        local dep_type
        dep_type=$(YQ_DEP="$dep_name" yq -r '.dependency_sources[strenv(YQ_DEP)].type // ""' "$config")

        # Get current version from build_args
        local current_version
        current_version=$(YQ_DEP="$dep_name" yq -r '.build_args[strenv(YQ_DEP)] // ""' "$config")

        if [[ -z "$current_version" || "$current_version" == "null" ]]; then
            # Dead-code-by-defense-in-depth: untracked continues early above, so
            # this branch is only reachable for tracked/stable-pin with no build_args
            # entry — a schema/config error, not a normal lifecycle path.
            if [[ "$lifecycle" != "eol-migrate" ]]; then
                errors_json=$(echo "$errors_json" | jq --arg msg "${dep_name}: no current version in build_args" '. + [$msg]')
            fi
            continue
        fi

        # Query latest version based on type
        local latest_version=""
        local source_ref=""
        local latest_raw_tag=""  # raw tag for github-tag type (used in URL builder)
        local source_web_host=""

        case "$dep_type" in
            github-release)
                local repo strip_v tag_pattern
                repo=$(YQ_DEP="$dep_name" yq -r '.dependency_sources[strenv(YQ_DEP)].repo // ""' "$config")
                strip_v=$(YQ_DEP="$dep_name" yq -r '.dependency_sources[strenv(YQ_DEP)].strip_v // false' "$config")
                tag_pattern=$(YQ_DEP="$dep_name" yq -r '.dependency_sources[strenv(YQ_DEP)].tag_pattern // ""' "$config")
                source_ref="$repo"

                local helper_args=("$repo")
                [[ "$strip_v" == "true" ]] && helper_args+=("--strip-v")
                [[ -n "$tag_pattern" && "$tag_pattern" != "null" ]] && helper_args+=("--tag-pattern" "$tag_pattern")

                latest_version=$("$PROJECT_ROOT/helpers/latest-github-release" "${helper_args[@]}" 2>/dev/null) || {
                    errors_json=$(echo "$errors_json" | jq --arg msg "${dep_name}: GitHub API error for ${repo}" '. + [$msg]')
                    continue
                }
                ;;
            github-tag)
                # Real github-tag branch: calls latest-github-tag with tag_filter/version_extract.
                # Previously aliased to latest-github-release (wrong — openssl/pcre2 ship tags).
                local repo tag_filter version_extract
                repo=$(YQ_DEP="$dep_name" yq -r '.dependency_sources[strenv(YQ_DEP)].repo // ""' "$config")
                tag_filter=$(YQ_DEP="$dep_name" yq -r '.dependency_sources[strenv(YQ_DEP)].tag_filter // ""' "$config")
                version_extract=$(YQ_DEP="$dep_name" yq -r '.dependency_sources[strenv(YQ_DEP)].version_extract // ""' "$config")
                source_ref="$repo"

                if [[ -z "$repo" ]]; then
                    errors_json=$(echo "$errors_json" | jq --arg msg "${dep_name}: github-tag type missing repo:" '. + [$msg]')
                    continue
                fi
                if [[ -z "$tag_filter" || -z "$version_extract" ]]; then
                    errors_json=$(echo "$errors_json" | jq --arg msg "${dep_name}: github-tag type requires tag_filter and version_extract" '. + [$msg]')
                    continue
                fi

                # Single atomic call returning both version and raw tag. A two-call
                # form (--output version then --output raw) could pick different
                # tags if upstream changed between the two invocations, and would
                # silently desync source_url from the version reported in the PR.
                _gh_both=$("$PROJECT_ROOT/helpers/latest-github-tag" "$repo" \
                    --tag-filter "$tag_filter" \
                    --version-extract "$version_extract" \
                    --output both 2>/dev/null) || {
                    errors_json=$(echo "$errors_json" | jq --arg msg "${dep_name}: GitHub tag API error for ${repo}" '. + [$msg]')
                    continue
                }
                # Tab-separated: VERSION<TAB>RAW_TAG (e.g. "10.47\tpcre2-10.47")
                latest_version="${_gh_both%%$'\t'*}"
                latest_raw_tag="${_gh_both##*$'\t'}"
                unset _gh_both
                ;;
            gitlab-tags)
                local project_path tag_filter version_extract web_host api_host gitlab_api_url
                project_path=$(YQ_DEP="$dep_name" yq -r '.dependency_sources[strenv(YQ_DEP)].project_path // ""' "$config")
                tag_filter=$(YQ_DEP="$dep_name" yq -r '.dependency_sources[strenv(YQ_DEP)].tag_filter // ""' "$config")
                version_extract=$(YQ_DEP="$dep_name" yq -r '.dependency_sources[strenv(YQ_DEP)].version_extract // ""' "$config")
                web_host=$(YQ_DEP="$dep_name" yq -r '.dependency_sources[strenv(YQ_DEP)].web_host // "gitlab.torproject.org"' "$config")
                api_host=$(YQ_DEP="$dep_name" yq -r '.dependency_sources[strenv(YQ_DEP)].api_host // "gitlab.torproject.org"' "$config")
                source_ref="$project_path"

                if [[ -z "$project_path" ]]; then
                    errors_json=$(echo "$errors_json" | jq --arg msg "${dep_name}: gitlab-tags type missing project_path:" '. + [$msg]')
                    continue
                fi
                if [[ -z "$tag_filter" || -z "$version_extract" ]]; then
                    errors_json=$(echo "$errors_json" | jq --arg msg "${dep_name}: gitlab-tags type requires tag_filter and version_extract" '. + [$msg]')
                    continue
                fi
                source_web_host=$(normalize_gitlab_host "$web_host") || {
                    errors_json=$(echo "$errors_json" | jq --arg msg "${dep_name}: gitlab-tags web_host is invalid: ${web_host}" '. + [$msg]')
                    continue
                }
                gitlab_api_url=$(gitlab_api_url_from_host "$api_host") || {
                    errors_json=$(echo "$errors_json" | jq --arg msg "${dep_name}: gitlab-tags api_host is invalid: ${api_host}" '. + [$msg]')
                    continue
                }

                _gl_both=$(GITLAB_API_URL="$gitlab_api_url" "$PROJECT_ROOT/helpers/latest-gitlab-tag" "$project_path" \
                    --tag-filter "$tag_filter" \
                    --version-extract "$version_extract" \
                    --output both 2>/dev/null) || {
                    errors_json=$(echo "$errors_json" | jq --arg msg "${dep_name}: GitLab tag API error for ${project_path}" '. + [$msg]')
                    continue
                }
                latest_version="${_gl_both%%$'\t'*}"
                latest_raw_tag="${_gl_both##*$'\t'}"
                unset _gl_both
                ;;
            pypi)
                local package
                package=$(YQ_DEP="$dep_name" yq -r '.dependency_sources[strenv(YQ_DEP)].package // ""' "$config")
                source_ref="$package"

                latest_version=$("$PROJECT_ROOT/helpers/latest-pypi-version" "$package" 2>/dev/null) || {
                    errors_json=$(echo "$errors_json" | jq --arg msg "${dep_name}: PyPI API error for ${package}" '. + [$msg]')
                    continue
                }
                ;;
            rubygems)
                local gem
                gem=$(YQ_DEP="$dep_name" yq -r '.dependency_sources[strenv(YQ_DEP)].gem // ""' "$config")
                source_ref="$gem"

                latest_version=$("$PROJECT_ROOT/helpers/latest-rubygems-version" "$gem" 2>/dev/null) || {
                    errors_json=$(echo "$errors_json" | jq --arg msg "${dep_name}: RubyGems API error for ${gem}" '. + [$msg]')
                    continue
                }
                ;;
            "")
                # Empty type: only valid for untracked entries (already continue'd above).
                # If we reach here it means a tracked/stable-pin/eol-migrate entry is missing type.
                if [[ "$lifecycle" != "untracked" ]]; then
                    errors_json=$(echo "$errors_json" | jq --arg msg "${dep_name}: missing type field for lifecycle=${lifecycle}" '. + [$msg]')
                fi
                continue
                ;;
            *)
                errors_json=$(echo "$errors_json" | jq --arg msg "${dep_name}: unknown source type '${dep_type}'" '. + [$msg]')
                continue
                ;;
        esac

        # Compare versions
        if [[ -z "$latest_version" ]]; then
            errors_json=$(echo "$errors_json" | jq --arg msg "${dep_name}: empty version returned" '. + [$msg]')
            continue
        fi

        if [[ "$current_version" != "$latest_version" ]]; then
            local change_type
            change_type=$(classify_version_change "$current_version" "$latest_version")
            local source_url
            source_url=$(build_source_url "$dep_type" "$source_ref" "$latest_version" "$latest_raw_tag" "$source_web_host")

            updates_json=$(echo "$updates_json" | jq \
                --arg name "$dep_name" \
                --arg current "$current_version" \
                --arg latest "$latest_version" \
                --arg source_url "$source_url" \
                --arg change_type "$change_type" \
                '. + [{"name": $name, "current": $current, "latest": $latest, "source_url": $source_url, "change_type": $change_type}]')
        fi
    done <<< "$dep_names"

    _emit_container_result "$container" "$updates_json" "$errors_json"
}

# Check postgres extensions via version-extension.sh
check_postgres_deps() {
    local updates_json="[]"
    local errors_json="[]"

    local ext_output
    if ! ext_output=$("$PROJECT_ROOT/postgres/version-extension.sh" --all --json 2>/dev/null); then
        errors_json=$(echo "$errors_json" | jq '. + ["version-extension.sh --all --json failed"]')
        _emit_container_result "postgres" "$updates_json" "$errors_json"
        return
    fi

    # Parse the JSON array from version-extension.sh
    local count
    count=$(echo "$ext_output" | jq 'length' 2>/dev/null) || {
        errors_json=$(echo "$errors_json" | jq '. + ["Failed to parse version-extension.sh JSON output"]')
        _emit_container_result "postgres" "$updates_json" "$errors_json"
        return
    }

    for ((i = 0; i < count; i++)); do
        local ext_name configured latest needs_update repo
        ext_name=$(echo "$ext_output" | jq -r ".[$i].extension")
        configured=$(echo "$ext_output" | jq -r ".[$i].configured")
        latest=$(echo "$ext_output" | jq -r ".[$i].latest")
        needs_update=$(echo "$ext_output" | jq -r ".[$i].needs_update")
        repo=$(echo "$ext_output" | jq -r ".[$i].repo")

        if [[ "$needs_update" == "true" && -n "$latest" && "$latest" != "unknown" ]]; then
            local change_type
            change_type=$(classify_version_change "$configured" "$latest")
            local source_url="https://github.com/${repo}/releases/tag/v${latest}"

            updates_json=$(echo "$updates_json" | jq \
                --arg name "$ext_name" \
                --arg current "$configured" \
                --arg latest "$latest" \
                --arg source_url "$source_url" \
                --arg change_type "$change_type" \
                '. + [{"name": $name, "current": $current, "latest": $latest, "source_url": $source_url, "change_type": $change_type}]')
        elif [[ "$latest" == "unknown" || -z "$latest" ]]; then
            errors_json=$(echo "$errors_json" | jq --arg msg "${ext_name}: failed to fetch latest version" '. + [$msg]')
        fi
    done

    _emit_container_result "postgres" "$updates_json" "$errors_json"
}

# Emit a container result JSON object
_emit_container_result() {
    local container="$1"
    local updates="$2"
    local errors="$3"
    local update_count
    update_count=$(echo "$updates" | jq 'length')

    jq -n \
        --arg container "$container" \
        --argjson updates "$updates" \
        --argjson errors "$errors" \
        --argjson update_count "$update_count" \
        '{container: $container, updates: $updates, errors: $errors, update_count: $update_count}'
}

# Format results as human-readable summary table
format_summary() {
    local results="$1"
    local total_updates total_errors

    total_updates=$(echo "$results" | jq '[.[].update_count] | add // 0')
    total_errors=$(echo "$results" | jq '[.[].errors | length] | add // 0')

    echo ""
    echo "=== Dependency Version Check ==="
    echo ""

    echo "$results" | jq -r '.[] | select(.update_count > 0 or (.errors | length) > 0) |
        "Container: \(.container)",
        "  Updates: \(.update_count)",
        (.updates[] | "    \(.name): \(.current) → \(.latest) (\(.change_type))"),
        (if (.errors | length) > 0 then
            "  Errors:",
            (.errors[] | "    ⚠ \(.)")
        else empty end),
        ""'

    # Summary line
    if [[ "$total_updates" -eq 0 && "$total_errors" -eq 0 ]]; then
        echo "✅ All dependencies are up to date."
    else
        echo "Summary: ${total_updates} update(s) available, ${total_errors} error(s)"
    fi
    echo ""
}

# Main
main() {
    local target=""
    local check_all=false
    local dry_run=false
    local output_mode=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)
                check_all=true
                shift
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            --json)
                output_mode="json"
                shift
                ;;
            --summary)
                output_mode="summary"
                shift
                ;;
            -h|--help)
                echo "Usage: $(basename "$0") [OPTIONS] [container-name]"
                echo ""
                echo "Check 3rd party dependency versions across containers."
                echo ""
                echo "Options:"
                echo "  --all       Check all containers with dependency monitoring"
                echo "  --dry-run   Show planned updates without modifying files"
                echo "  --json      Output machine-readable JSON"
                echo "  --summary   Output human-readable summary table"
                echo "  -h, --help  Show this help"
                echo ""
                echo "Examples:"
                echo "  $(basename "$0") terraform      # Check terraform deps"
                echo "  $(basename "$0") --all          # Check all containers"
                echo "  $(basename "$0") --all --json   # JSON output for CI"
                exit 0
                ;;
            -*)
                log_error "Unknown option: $1"
                exit 1
                ;;
            *)
                target="$1"
                shift
                ;;
        esac
    done

    # Default output mode: JSON if piped, summary if terminal
    if [[ -z "$output_mode" ]]; then
        if [[ -t 1 ]]; then
            output_mode="summary"
        else
            output_mode="json"
        fi
    fi

    # Determine containers to check
    local containers=()
    if [[ "$check_all" == "true" ]]; then
        mapfile -t containers < <(discover_containers)
    elif [[ -n "$target" ]]; then
        containers=("$target")
    else
        log_error "Specify a container name or use --all"
        echo "Run '$(basename "$0") --help' for usage information."
        exit 1
    fi

    # Collect results
    local results="[]"

    if [[ "$dry_run" == "true" ]]; then
        log_info "Dry-run mode — no files will be modified" >&2
    fi

    for container in "${containers[@]}"; do
        log_info "Checking dependencies for ${container}..." >&2

        # Pre-flight validation (non-postgres only)
        if [[ "$container" != "postgres" ]]; then
            preflight_check "$container"
        fi

        # Check dependencies
        local result
        if [[ "$container" == "postgres" ]]; then
            result=$(check_postgres_deps)
        else
            result=$(check_container_deps "$container")
        fi

        results=$(echo "$results" | jq --argjson r "$result" '. + [$r]')
    done

    # Output
    if [[ "$output_mode" == "json" ]]; then
        echo "$results" | jq .
    else
        format_summary "$results"
    fi

    # Always exit 0 — errors are in the output
    exit 0
}

main "$@"
