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

# Sanitize an untrusted string for safe inclusion in a log message.
# Neutralizes GHA workflow-command injection: a raw newline followed by '::command::'
# is interpreted as a workflow command by the Actions runner.  Stripping/encoding CR
# and LF prevents any injected text from starting a new line and being parsed as a
# command.  '::' at the start of a line is the trigger; removing newlines defangs it.
# Also escapes '%' first (mirrors the _esc ordering in timescaledb-ha.sh resolver)
# so that %0A / %0D sequences in the source data are not re-expanded by the runner.
#
# Backslash neutralisation (FIRST transformation):
# The loggers use 'echo -e', which expands backslash sequences in the string it
# receives.  A value containing the two-char literal sequence \n (backslash + n)
# passes the CR/LF check (no actual control byte present) but echo -e expands it
# into a real newline, recreating a '::command::' line from \x3a\x3a sequences.
# Escaping every '\' -> '\\' as the very first step means echo -e renders '\n' as
# the literal two characters \n (not a newline) and '\x3a' as the four characters
# \x3a (not ':'), so no downstream expansion can reconstruct a workflow command.
# Legitimate version strings and OCI digests contain no backslashes, so this
# transformation is always safe on real data.
#
# Usage: _sanitize_for_log <string>  (prints sanitized form to stdout)
_sanitize_for_log() {
    local s="$1"
    # Backslash must be escaped FIRST so later encodings don't double-process.
    s="${s//\\/\\\\}"
    s="${s//\%/%25}"
    s="${s//$'\r'/%0D}"
    s="${s//$'\n'/%0A}"
    # Defang remaining '::' sequences that could be interpreted as workflow commands.
    s="${s//::/%3A%3A}"
    printf '%s' "$s"
}

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

# _image_registry_probe_3state <image>
# 3-state presence probe for versionset availability computation.
# Returns:
#   0  PRESENT  — image confirmed present in registry or local daemon
#   1  ABSENT   — definitively absent (explicit not-found signal or local inspect returned 1)
#   2  ERROR    — probe failed ambiguously (network blip, 429, auth, timeout, etc.)
#
# Mode-aware routing (mirrors _image_present in build-extensions.sh):
#   LOCAL_ONLY=true  OR  PULL_ONLY=true  → probe local daemon (docker image inspect).
#     Local inspect is 2-state: present (0) or absent (1). A missing local image
#     is always definitively absent — no ERROR state in local mode.
#   else (push/CI path) → registry probe (fast-path + stderr-capturing fallback).
#
# Registry fast-path: calls image_exists_in_registry first; if it returns 0
# (PRESENT), returns immediately without a second probe.  This preserves the
# established mock surface for unit tests (image_exists_in_registry is the
# PRESENT oracle in all existing self-heal tests).
#
# Only when image_exists_in_registry returns non-zero does the stderr-capturing
# direct probe run to classify the failure as ABSENT vs transient ERROR.
#
# POLARITY (registry path): fail-closed (default ERROR).
# ABSENT requires an explicit not-found signal; everything else → ERROR (rc=2).
#
# Does NOT replace image_exists_in_registry for any other callers.
_image_registry_probe_3state() {
    local image="$1"

    # Local-store path: docker image inspect is 2-state (present / not present).
    # A missing local image is always definitively absent, not an error.
    if [[ "${LOCAL_ONLY:-false}" == "true" || "${PULL_ONLY:-false}" == "true" ]]; then
        if docker image inspect "$image" &>/dev/null; then
            return 0  # PRESENT
        fi
        return 1      # ABSENT (definitively — local store is authoritative)
    fi

    # Fast-path: if image_exists_in_registry confirms present, return PRESENT.
    if image_exists_in_registry "$image" 2>/dev/null; then
        return 0  # PRESENT
    fi

    # image_exists_in_registry returned non-zero (not confirmed present).
    # Run a stderr-capturing probe to distinguish ABSENT from transient ERROR.
    #
    # POLARITY: fail-closed (default ERROR).
    # ABSENT requires a POSITIVE explicit not-found signal in stderr.
    # Everything else non-zero (including empty stderr, toomanyrequests, denied,
    # unauthorized, no such host, network unreachable, EOF, context deadline,
    # daemon errors) → ERROR (rc=2, fail-closed).
    local _probe_stderr
    local _probe_rc=0

    _probe_stderr=$(docker manifest inspect "$image" 2>&1 >/dev/null) || _probe_rc=$?
    if [[ "$_probe_rc" -eq 0 ]]; then
        return 0  # PRESENT (image_exists_in_registry was a false negative)
    fi

    # Explicit not-found allow-list: only REGISTRY-MANIFEST-SPECIFIC signals confirm
    # definitive absence. These are the exact strings docker/skopeo emit for a
    # genuinely-missing tag as returned by the registry manifest API.
    # Bare "not found", "no such image" (Docker local-store), and bare "404" are
    # intentionally excluded: they also appear in infra errors like
    # "docker: command not found" or "docker-credential-desktop: executable file
    # not found in PATH", which would mis-classify an infra failure as ABSENT and
    # silently drop retained versions from the artifact.
    if echo "$_probe_stderr" | grep -qiE \
        'manifest unknown|name unknown|repository name not known|no such manifest'; then
        if command -v skopeo &>/dev/null; then
            local _skopeo_stderr
            local _skopeo_rc=0
            _skopeo_stderr=$(skopeo inspect "docker://${image}" 2>&1 >/dev/null) || _skopeo_rc=$?
            if [[ "$_skopeo_rc" -eq 0 ]]; then
                return 0  # PRESENT (skopeo confirms presence despite docker not-found)
            fi
            # skopeo also non-zero; if skopeo's error is NOT a definitive not-found,
            # escalate to ERROR to avoid discarding the version on ambiguous signal.
            if ! echo "$_skopeo_stderr" | grep -qiE \
                'manifest unknown|name unknown|repository name not known|no such manifest|MANIFEST_UNKNOWN'; then
                return 2  # ERROR (docker said not-found but skopeo is ambiguous)
            fi
        fi
        return 1  # ABSENT (definitive not-found confirmed)
    fi

    # No explicit not-found signal → ambiguous/transient error (fail-closed).
    # Covers: toomanyrequests, denied, unauthorized, no such host, network unreachable,
    # EOF, context deadline exceeded, empty stderr, daemon errors, command not found,
    # missing cred helpers, and anything else non-specific to the registry manifest API.
    return 2  # ERROR
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
# Version validation
# ============================================================================

# is_strict_semver <version>
# Returns 0 when <version> matches strict semver (^[0-9]+\.[0-9]+\.[0-9]+$),
# non-zero otherwise. No pre-release or build-metadata suffixes are accepted.
# Used as the single source-of-truth validator for both the Dockerfile generation
# path (generate_dockerfile available[] entries) and the build/tag/push path
# (build_tag_push_extensions resolved set entries).
is_strict_semver() {
    [[ "${1:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# is_valid_oci_digest <digest>
# Returns 0 when <digest> is a valid OCI content digest: EXACTLY the string
# "sha256:" followed by EXACTLY 64 lowercase hexadecimal characters, and
# NOTHING else (no trailing whitespace, no embedded newlines, no extra tokens).
#
# Uses printf '%s' piped to grep -Eqx (whole-line match) rather than a bare
# bash =~ so that embedded newlines — which cause bash $ in =~ to match before
# the newline, not at the true end of the string — are safely rejected.
#
# This is the single shared validator used by BOTH:
#   - The producer (finalize_multiarch_manifests in build-extensions.sh) — after
#     _capture_index_digest, before writing version_digests in the artifact.
#   - The consumer (generate_dockerfile in extension-utils.sh) — after reading
#     version_digests from the artifact, before inserting into COPY --from=.
#
# Any value that does not satisfy the whole-string pattern is treated as
# malformed/poisoned, regardless of whether it has the sha256: prefix.
is_valid_oci_digest() {
    local _d="${1:-}"
    # Reject immediately if the value contains a newline — grep -x would only
    # match the first line, silently accepting multi-line injections otherwise.
    [[ "$_d" == *$'\n'* ]] && return 1
    printf '%s' "$_d" | grep -Eqx 'sha256:[0-9a-f]{64}'
}

# validate_semver_set_json <json_array> <ceiling>
# Validates a JSON array of version strings at the array level (NOT after jq -r).
# This prevents the embedded-newline bypass where jq -r '.[]' splits a single
# element "2.27.1\n9.9.9" into two lines that each pass a per-line check.
#
# Checks (operating on the JSON array before any jq -r iteration):
#   1. Input is a non-empty JSON array where EVERY element is a STRING matching
#      strict semver with WHOLE-STRING anchors: \A[0-9]+\.[0-9]+\.[0-9]+\z
#      (\A/\z are whole-string, not per-line — jq/Oniguruma uses these).
#   2. Every element is <= ceiling (highest element must not exceed ceiling under
#      sort -V; this is the ceiling clamp / belt-and-suspenders guard).
#
# Returns 0 (valid) or 1 (invalid/malformed/above-ceiling).
# Does NOT log — callers emit appropriate error messages.
#
# Only applies to RESOLVER-BACKED extensions (caller's responsibility to gate).
# Non-resolver single-version extensions (e.g. pg_ivm "1.14") bypass validation
# at the caller level.
validate_semver_set_json() {
    local json_array="$1"
    local ceiling="$2"

    # 1. Every element must be a string matching strict semver with whole-string anchors.
    #    \A and \z are Oniguruma whole-string anchors (not per-line like ^ and $).
    if ! echo "$json_array" | jq -e \
        'type == "array" and length > 0 and
         all(.[]; type == "string" and test("\\A[0-9]+\\.[0-9]+\\.[0-9]+\\z"))' \
        > /dev/null 2>&1; then
        return 1
    fi

    # 2. Ceiling clamp: reject if any element is above the ceiling.
    #    Sort all elements + ceiling; if the last element is not the ceiling,
    #    some element exceeds the ceiling.
    local _highest
    _highest=$(echo "$json_array" | jq -r '.[]' | { cat; printf '%s\n' "$ceiling"; } | sort -V | tail -1)
    if [[ "$_highest" != "$ceiling" ]]; then
        return 1
    fi

    return 0
}

# ============================================================================
# Flavor-aware Dockerfile generation
# Templates the main Dockerfile to only include FROM/COPY stages relevant
# to each flavor+PG version. Multi-version extensions use a collector stage
# (FROM scratch AS ext_collect_<ext>) to absorb per-version COPYs, exposing
# exactly one final-stage COPY regardless of the retained version count.
# ============================================================================

# _scoped_ext_ref <base_ref>
# Appends ${PR_TAG_SUFFIX} to <base_ref> when PR_TAG_SUFFIX is non-empty;
# returns <base_ref> unchanged when PR_TAG_SUFFIX is empty (push/dispatch path).
#
# Low-level string helper used internally by ext_ref_resolve and generate_dockerfile.
# Examples (PR_TAG_SUFFIX=-pr42):
#   _scoped_ext_ref "ghcr.io/owner/ext-pgvector:pg18-0.8.2"  => "ghcr.io/owner/ext-pgvector:pg18-0.8.2-pr42"
# Examples (PR_TAG_SUFFIX empty — push/dispatch):
#   _scoped_ext_ref "ghcr.io/owner/ext-pgvector:pg18-0.8.2"  => "ghcr.io/owner/ext-pgvector:pg18-0.8.2"
_scoped_ext_ref() {
    local base="$1"
    if [[ -n "${PR_TAG_SUFFIX:-}" ]]; then
        printf '%s%s' "$base" "$PR_TAG_SUFFIX"
    else
        printf '%s' "$base"
    fi
}

# ext_ref_resolve <ext> <version> <major> <arch>
#
# SINGLE SOURCE OF TRUTH for per-version extension image reference resolution.
# Encapsulates all five axes: canonical-vs-PR-scoped, arch suffix, FORCE,
# 3-state fail-closed, PR suffix.
#
# Parameters:
#   <ext>     extension name (e.g. timescaledb)
#   <version> version string (e.g. 2.27.1)
#   <major>   PG major version (e.g. 18)
#   <arch>    arch suffix: "" for the plain multi-arch tag,
#             "amd64" or "arm64" for per-arch suffixed tags.
#
# Reads env:
#   PR_TAG_SUFFIX  (PR scoping, may be empty)
#   FORCE          (true|false, defaults false)
#
# Ref construction (registry/owner from get_registry/get_repo_owner):
#   canonical  = ext_image_name(ext,ver,major)[+"-"<arch>]
#   pr-scoped  = canonical + PR_TAG_SUFFIX
#
# Probing uses _image_registry_probe_3state (PRESENT/ABSENT/ERROR).
#
# Resolution order:
#   FORCE=true AND PR_TAG_SUFFIX set:
#     → prefer PR-scoped (freshly rebuilt this run); do NOT reuse canonical.
#     Probe PR-scoped only (canonical is stale for this version).
#   else (not FORCE, or no PR_TAG_SUFFIX):
#     → prefer canonical when PRESENT (read-only reuse for unchanged versions).
#     If canonical ABSENT and PR_TAG_SUFFIX set → probe PR-scoped.
#
# Output / return codes:
#   rc 0  → prints the ref to use (canonical or pr-scoped).
#   rc 1  → neither ref exists definitively (needs build or exclude).
#           prints nothing.
#   rc 2  → a probe returned transient ERROR → fail closed.
#           prints nothing.
#
# On push/dispatch (PR_TAG_SUFFIX empty): only canonical is considered;
# behavior is identical to the current canonical path.
ext_ref_resolve() {
    local ext="$1" version="$2" major="$3" arch="${4:-}"
    local registry owner canonical_ref pr_ref
    registry=$(get_registry)
    owner=$(get_repo_owner)

    # Build canonical base: ext_image_name gives registry/owner/ext-<name>:pg<major>-<ver>
    # Append arch suffix when arch is non-empty.
    canonical_ref=$(ext_image_name "$ext" "$version" "$major" "$registry" "$owner")
    if [[ -n "$arch" ]]; then
        canonical_ref="${canonical_ref}-${arch}"
    fi

    # PR-scoped ref = canonical + PR_TAG_SUFFIX (empty when not on PR).
    if [[ -n "${PR_TAG_SUFFIX:-}" ]]; then
        pr_ref="${canonical_ref}${PR_TAG_SUFFIX}"
    else
        pr_ref="$canonical_ref"
    fi

    # On push/dispatch (PR_TAG_SUFFIX empty), pr_ref == canonical_ref.
    # Handle FORCE + PR: prefer pr-scoped (do not reuse canonical stale ref).
    if [[ "${FORCE:-false}" == "true" ]] && [[ -n "${PR_TAG_SUFFIX:-}" ]]; then
        # Probe the PR-scoped ref only.
        local _rc=0
        _image_registry_probe_3state "$pr_ref" || _rc=$?
        case "$_rc" in
            0) printf '%s' "$pr_ref"; return 0 ;;
            1) return 1 ;;  # absent — needs build
            *) return 2 ;;  # transient error — fail closed
        esac
    fi

    # Normal path (not FORCE+PR, or push/dispatch):
    # Probe canonical first (read-only reuse for unchanged versions).
    local _can_rc=0
    _image_registry_probe_3state "$canonical_ref" || _can_rc=$?
    case "$_can_rc" in
        0)
            # Canonical present: use it.
            printf '%s' "$canonical_ref"
            return 0
            ;;
        2)
            # Transient error on canonical — fail closed regardless of PR-scoped state.
            return 2
            ;;
        1)
            # Canonical absent: if we have a PR suffix, try the PR-scoped ref.
            if [[ -n "${PR_TAG_SUFFIX:-}" ]]; then
                local _pr_rc=0
                _image_registry_probe_3state "$pr_ref" || _pr_rc=$?
                case "$_pr_rc" in
                    0) printf '%s' "$pr_ref"; return 0 ;;
                    1) return 1 ;;  # neither ref exists
                    *) return 2 ;;  # transient error — fail closed
                esac
            fi
            # Push/dispatch (no PR suffix): canonical absent = needs build.
            return 1
            ;;
    esac
}

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

# _emit_collector_stage <ext> <ver_ref_list>
#
# Emit a consume-time collector build stage for a multi-version resolver-backed
# extension.  The collector stage absorbs all per-version COPYs; its layers are
# NOT exported because it is an intermediate stage.  The final stage does ONE
# COPY from the collector → exactly one exported layer regardless of version count.
#
# Output to stdout (two sections separated by the delimiter line "---ECS-COPIES---"):
#   <stages_block>     — FROM scratch AS ext_collect_<ext> + COPY --from per version
#   ---ECS-COPIES---
#   <copies_block>     — COPY --from=ext_collect_<ext> / /tmp/ext/<ext>/
#
# Caller captures stdout and splits on the delimiter to obtain stages_block and copies_block.
#
# Portable bash-4.0 pattern (no local -n namerefs, which require bash 4.3+):
#   <ver_ref_list> is a newline-delimited list of "<version>\t<ref>" pairs.
#   Caller serializes its version→ref map as "<ver>\t<ref>\n..." and passes it.
#
# Args:
#   $1  ext          extension name (e.g. "timescaledb")
#   $2  ver_ref_list newline-delimited "<version>\t<ref>" pairs
#
# Returns 0 on success (output on stdout), 1 on validation failure (logged, no output).
_emit_collector_stage() {
    local _ecs_ext="$1"
    local _ecs_ver_ref_list="$2"

    if [[ -z "$_ecs_ver_ref_list" ]]; then
        log_error "_emit_collector_stage: empty ref list for ${_ecs_ext} — fail closed"
        return 1
    fi

    # Sanitize extension name for the stage alias (Docker stage names: [a-zA-Z0-9_-]).
    local _ecs_stage_name="ext_collect_${_ecs_ext//[^a-zA-Z0-9_]/_}"

    local _ecs_stage_block="FROM scratch AS ${_ecs_stage_name}"$'\n'
    local _ecs_line
    while IFS= read -r _ecs_line; do
        [[ -z "$_ecs_line" ]] && continue
        local _ecs_ver="${_ecs_line%%	*}"
        local _ecs_ref="${_ecs_line#*	}"
        if [[ -z "$_ecs_ver" ]] || [[ -z "$_ecs_ref" ]] || [[ "$_ecs_ver" == "$_ecs_ref" ]]; then
            log_error "_emit_collector_stage: malformed or empty ref for ${_ecs_ext} — fail closed"
            return 1
        fi
        # Sanitize version for use as a path component.
        local _ecs_ver_safe="${_ecs_ver//[^a-zA-Z0-9._-]/_}"
        _ecs_stage_block+="COPY --from=${_ecs_ref} /output/ /${_ecs_ver_safe}/"$'\n'
    done <<< "$_ecs_ver_ref_list"

    # Print stage block, delimiter, then copy line.
    printf '%s' "${_ecs_stage_block}"
    printf '%s\n' "---ECS-COPIES---"
    printf 'COPY --from=%s / /tmp/ext/%s/\n' "${_ecs_stage_name}" "${_ecs_ext}"
    return 0
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

    # Derive FORCE from REBUILD env so a forced PR run prefers freshly-rebuilt
    # PR-scoped refs over stale canonical refs for non-resolver/single-version
    # extensions.  This mirrors the --force logic in build-extensions.sh and
    # merge-extension-manifests.  ext_ref_resolve reads FORCE from env; the
    # build-and-push job exports REBUILD from env.REBUILD_MODE.
    # Pre-existing FORCE=true is preserved (e.g. LOCAL_ONLY builds).
    if [[ "${REBUILD:-}" == "force" || "${REBUILD:-}" == "all" ]]; then
        export FORCE=true
    fi

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

            # Resolver-backed extension: require jq before attempting any artifact
            # parse, self-heal, or validation step. Without jq, _artifact_valid would
            # silently stay 0 (artifact treated as absent), triggering self-heal which
            # also needs jq — producing an opaque error unrelated to the root cause.
            # Fail fast here with a clear actionable message instead.
            if [[ -n "$_resolver_path" ]] && ! command -v jq &>/dev/null; then
                log_error "generate_dockerfile: jq is required to resolve the ${ext_name} version set but was not found on PATH"
                return 1
            fi

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
            # Malformedness check: artifact must be parseable JSON with a non-empty
            # .available array.  jq -e exits non-zero on parse error OR when the
            # expression evaluates to false/null.
            # An artifact with available:[] is treated as malformed (stale/foreign):
            # build-extensions never writes an empty-available artifact, so an on-disk
            # available:[] is necessarily stale → route to self-heal just like a
            # missing or truncated artifact.
            local _artifact_valid=0
            if [[ -f "$versionset_file" ]] && command -v jq &>/dev/null; then
                jq -e 'type == "object" and has("available") and (.available | type) == "array" and (.available | length) > 0' \
                    "$versionset_file" > /dev/null 2>&1 && _artifact_valid=1
            fi

            # _versionset_json holds the JSON source for the multi-version emission
            # logic below.  It is populated either by the self-heal path (shell
            # variable, no temp file) or by reading the on-disk artifact.  The
            # downstream block reads exclusively from this variable — no temp files
            # are created or left behind.
            # _versionset_from_selfheal tracks whether _versionset_json came from
            # the self-heal path (artifact absent/malformed) vs the on-disk artifact.
            # Both paths feed the same collector emitter; the data source controls
            # whether digest-pinned refs (artifact with version_digests) or tag-based
            # refs (self-heal, no digest map) are used.
            local _versionset_json=""
            local _versionset_from_selfheal=false

            if [[ -n "$_resolver_path" ]] && { [[ ! -f "$versionset_file" ]] || [[ "$_artifact_valid" -eq 0 ]]; }; then
                if [[ "$_artifact_valid" -eq 0 ]] && [[ -f "$versionset_file" ]]; then
                    log_error "generate_dockerfile: versionset artifact for $ext_name pg${pg_major} is malformed, missing .available array, or has empty available[] — treating as absent, triggering self-heal"
                fi
                # skopeo is required by resolve_version_set (list-tags probe).
                # It is installed in CI but may be absent on a local dev machine.
                # Fail fast here with a clear, actionable message — before the
                # resolver is invoked — so the operator sees what to install rather
                # than an opaque "skopeo: command not found" deep in the resolver.
                # This check fires ONLY on the self-heal/resolve branch; the valid-
                # artifact path above does not use skopeo and is not affected.
                if ! command -v skopeo &>/dev/null; then
                    log_error "generate_dockerfile: skopeo is required to resolve the ${ext_name} version set when no version-set artifact is present; install skopeo (see postgres/README.md) or supply the artifact manually"
                    return 1
                fi
                local _sh_resolved_json
                if ! _sh_resolved_json=$(resolve_version_set "$ext_name" "$pg_major" "$config_file"); then
                    log_error "generate_dockerfile: self-heal resolver failed for $ext_name pg${pg_major} (resolver: $_resolver_path) — cannot determine retained version set"
                    return 1
                fi

                # Validate the resolver output at the JSON-array level using whole-string
                # semver anchors (\A...\z) before any jq -r iteration.
                # This prevents the embedded-newline bypass where jq -r '.[]' splits a
                # single element "2.25.0\n2.26.0" into two apparently-valid lines.
                if ! validate_semver_set_json "$_sh_resolved_json" "$ext_version"; then
                    log_error "generate_dockerfile: self-heal resolver for $ext_name returned invalid or above-ceiling set: $(_sanitize_for_log "$_sh_resolved_json")"
                    return 1
                fi

                # Probe registry presence for each resolved version via ext_ref_resolve.
                # ext_ref_resolve encapsulates canonical-first, PR-scoped fallback,
                # FORCE, and 3-state fail-closed in one call (arch="" = multi-arch tag).
                # rc 0 → PRESENT (ref printed); rc 1 → ABSENT; rc 2 → transient ERROR (fail-closed).
                local _sh_available=()
                local -A _sh_emit_ref_map=()  # version → resolved emit ref (for lookup in emit loop)
                local _sh_probe_error=false
                local _sh_ver
                while IFS= read -r _sh_ver; do
                    [[ -z "$_sh_ver" ]] && continue
                    local _sh_resolved_ref _sh_rc=0
                    _sh_resolved_ref=$(ext_ref_resolve "$ext_name" "$_sh_ver" "$pg_major" "") || _sh_rc=$?
                    case "$_sh_rc" in
                        0)
                            _sh_available+=("$_sh_ver")
                            _sh_emit_ref_map["$_sh_ver"]="$_sh_resolved_ref"
                            ;;
                        1)  ;;   # ABSENT — musl-failed / never-built / not yet pushed
                        *)
                            log_error "generate_dockerfile: self-heal probe for $ext_name $pg_major $ext_version — registry probe for $_sh_ver returned an ambiguous error; cannot determine availability (fail-closed)"
                            _sh_probe_error=true
                            ;;
                    esac
                done < <(echo "$_sh_resolved_json" | jq -r '.[]' 2>/dev/null || true)

                if [[ "$_sh_probe_error" == "true" ]]; then
                    return 1
                fi

                if [[ ${#_sh_available[@]} -eq 0 ]]; then
                    log_error "generate_dockerfile: self-heal for $ext_name pg${pg_major}: no resolved images are present in registry — cannot emit multi-version stages"
                    return 1
                fi

                # Warn when the confirmed-available set is smaller than the resolved set.
                # This happens when some retained versions are absent from the registry
                # (e.g. a fork/PR that didn't push, or registry lag).  The build still
                # proceeds with the available subset — the ceiling-presence check is the
                # hard gate.  Emit a named warning so the reduction is visible, not silent.
                local _sh_resolved_count
                _sh_resolved_count=$(echo "$_sh_resolved_json" | jq 'length' 2>/dev/null || echo 0)
                if [[ "${#_sh_available[@]}" -lt "$_sh_resolved_count" ]]; then
                    # Compute the dropped versions for the warning message.
                    local _sh_dropped=()
                    local _sh_rv
                    while IFS= read -r _sh_rv; do
                        [[ -z "$_sh_rv" ]] && continue
                        local _sh_found=false
                        local _sh_av
                        for _sh_av in "${_sh_available[@]}"; do
                            [[ "$_sh_av" == "$_sh_rv" ]] && _sh_found=true && break
                        done
                        [[ "$_sh_found" == "false" ]] && _sh_dropped+=("$(_sanitize_for_log "$_sh_rv")")
                    done < <(echo "$_sh_resolved_json" | jq -r '.[]' 2>/dev/null || true)
                    local _sh_dropped_list
                    _sh_dropped_list=$(printf '%s, ' "${_sh_dropped[@]}" | sed 's/, $//')
                    log_warning "generate_dockerfile: ${ext_name} pg${pg_major}: retention reduced — ${#_sh_available[@]} of ${_sh_resolved_count} resolved versions available; image will NOT retain ${_sh_dropped_list} (versions absent from the registry; expected in a no-push/fork-PR or registry-lag context)"
                fi

                # Synthesise the versionset JSON into a shell variable — no temp file.
                # The downstream emission block reads _versionset_json directly.
                local _sh_avail_json
                _sh_avail_json=$(printf '%s\n' "${_sh_available[@]}" | jq -Rsc 'split("\n") | map(select(. != ""))')
                _versionset_json=$(jq -nc \
                    --arg ext "$ext_name" \
                    --arg pg_major "$pg_major" \
                    --arg ceiling "$ext_version" \
                    --argjson resolved "$_sh_resolved_json" \
                    --argjson available "$_sh_avail_json" \
                    '{ext:$ext, pg_major:$pg_major, ceiling:$ceiling, resolved:$resolved, available:$available, excluded:[]}')
                # Mark that this came from the self-heal path so the downstream
                # emission block uses tag-based refs (no digest map available).
                _versionset_from_selfheal=true
            elif [[ -f "$versionset_file" ]] && [[ "$_artifact_valid" -eq 1 ]] && command -v jq &>/dev/null; then
                _versionset_json=$(< "$versionset_file")
            fi

            if [[ -n "$_versionset_json" ]] && command -v jq &>/dev/null; then
                local available_count
                available_count=$(echo "$_versionset_json" | jq '.available | length' 2>/dev/null || echo 0)

                # AO-4: whenever available has exactly ONE entry, that entry MUST
                # equal the configured ceiling.  This applies to BOTH the self-heal
                # path (_versionset_from_selfheal=true) AND the on-disk artifact path.
                # A stale or corrupt artifact with available:["<older>"] (single entry
                # != ceiling) would otherwise fall through to the single-version path
                # emitting FROM <ext>:pg<major>-<ceiling> — a manifest that may be
                # absent (corrupt artifact) or a silently wrong package set.
                # Fail closed when single-entry != ceiling regardless of source.
                # When available == [ceiling], the single-version fallthrough is safe.
                if [[ "$available_count" -le 1 ]]; then
                    local _single_avail
                    _single_avail=$(echo "$_versionset_json" | jq -r '.available[0] // empty' 2>/dev/null || true)
                    if [[ "$_single_avail" != "$ext_version" ]]; then
                        log_error "generate_dockerfile: $ext_name pg${pg_major}: single available version '$(_sanitize_for_log "${_single_avail:-<none>}")' is not the ceiling ${ext_version} — ceiling image is absent or artifact is corrupt, fail closed"
                        return 1
                    fi
                    # available == [ceiling]: single-version path is safe; fall through.
                fi

                # Use the collector emitter when more than one version is available.
                # When available_count == 1 (the ceiling only), no collector is needed
                # (_bundle_and_write_artifact early-returns for set_size<=1).
                # Fall through to the single-version path which works for set_size==1.
                if [[ "$available_count" -gt 1 ]]; then
                    # Validate the available[] array at the JSON level BEFORE any jq -r
                    # iteration. This prevents the embedded-newline bypass where a single
                    # element "2.25.0\n2.26.0" would be split into two apparent versions
                    # by jq -r, each passing the per-line is_strict_semver check.
                    # validate_semver_set_json uses whole-string anchors (\A...\z) and
                    # the ceiling clamp, operating on the JSON array directly.
                    local _available_json
                    _available_json=$(echo "$_versionset_json" | jq '.available' 2>/dev/null || echo 'null')
                    if ! validate_semver_set_json "$_available_json" "$ext_version"; then
                        log_error "generate_dockerfile: available[] for $ext_name contains invalid, malformed, or above-ceiling entry — refusing to emit stages (poisoned or malformed artifact)"
                        return 1
                    fi

                    # Fail-closed: the configured ceiling version must be present in
                    # available[].  If it is absent (e.g. build-side probe missed it
                    # due to a ceiling-fatal error), shipping an older-only image
                    # would silently violate the pinned version — abort instead.
                    local ceiling_in_available
                    ceiling_in_available=$(echo "$_versionset_json" | jq --arg ceiling "$ext_version" \
                        '[.available[] | select(. == $ceiling)] | length' \
                        2>/dev/null || echo 0)
                    if [[ "$ceiling_in_available" -eq 0 ]]; then
                        log_error "generate_dockerfile: ceiling $ext_version for $ext_name is absent from available[] — refusing to emit below-pin image"
                        return 1
                    fi

                    # Per-element validation (now redundant for semver/ceiling, retained as
                    # defense-in-depth for any value that passes validate_semver_set_json
                    # but would still be unsafe as a Docker stage name).
                    local _val_ver
                    while IFS= read -r _val_ver; do
                        [[ -z "$_val_ver" ]] && continue
                        if ! is_strict_semver "$_val_ver"; then
                            log_error "generate_dockerfile: available[] entry '$(_sanitize_for_log "${_val_ver}")' for $ext_name is not strict semver — refusing to emit unsafe stage"
                            return 1
                        fi
                        # above-ceiling check: if sort -V puts _val_ver AFTER ext_version,
                        # then _val_ver > ext_version → reject.
                        local _highest
                        _highest=$(printf '%s\n%s\n' "$_val_ver" "$ext_version" | sort -V | tail -1)
                        if [[ "$_highest" != "$ext_version" && "$_highest" == "$_val_ver" ]]; then
                            log_error "generate_dockerfile: available[] entry '$(_sanitize_for_log "${_val_ver}")' for $ext_name exceeds ceiling ${ext_version} — refusing to emit above-pin stage"
                            return 1
                        fi
                    done < <(echo "$_versionset_json" | jq -r '.available[]' 2>/dev/null || true)

                    # Multi-version path: build a {version → ref} map, then call
                    # _emit_collector_stage to emit:
                    #   INTO stages_block: FROM scratch AS ext_collect_<ext>
                    #                      COPY --from=<ref> /output/ /<ver>/   (one per version)
                    #   INTO copies_block: COPY --from=ext_collect_<ext> / /tmp/ext/<ext>/
                    #
                    # Two data sources feed the same emitter:
                    #   Artifact-present: use <registry>/<owner>/ext-<ext>@<version_digests[ver]>
                    #     (fail-closed if any version in available[] is missing from version_digests
                    #     or its digest is malformed).
                    #   Self-heal (artifact absent): use _sh_emit_ref_map[ver] from ext_ref_resolve
                    #     (the degraded path — no digest map without the artifact; tag resolution
                    #     is the accepted fallback).

                    local raw_versions
                    raw_versions=$(echo "$_versionset_json" | jq -r '.available[]' 2>/dev/null || true)

                    if [[ -n "$raw_versions" ]]; then
                        # Build version→ref map for the emitter.
                        # Use the global _ECS_REF_MAP (bash-4.0 portable; no local -n namerefs
                        # which require bash 4.3+).  Reset before population to avoid stale
                        # entries from a previous extension in the same generate_dockerfile call.
                        # Build a serialized version→ref list (tab-delimited "<ver>\t<ref>" lines).
                        # Portable bash-4.0 pattern: no local -n namerefs (require bash 4.3+);
                        # no global associative arrays (unreliable across forked subshells when
                        # sourced inside a function scope). Serializing as a string passes cleanly.
                        local _ecs_ver_ref_list=""
                        if [[ "$_versionset_from_selfheal" == "true" ]]; then
                            # Self-heal path: refs already resolved by ext_ref_resolve above.
                            local _sh_mv
                            while IFS= read -r _sh_mv; do
                                [[ -z "$_sh_mv" ]] && continue
                                local _sh_mv_ref="${_sh_emit_ref_map[$_sh_mv]:-}"
                                if [[ -z "$_sh_mv_ref" ]]; then
                                    log_error "generate_dockerfile: self-heal emit: no resolved ref for $ext_name $_sh_mv pg${pg_major} — fail closed"
                                    return 1
                                fi
                                _ecs_ver_ref_list+="${_sh_mv}	${_sh_mv_ref}"$'\n'
                            done <<< "$raw_versions"
                        else
                            # Artifact-present path: use version_digests for digest-pinned refs.
                            local _vd_field_present
                            _vd_field_present=$(echo "$_versionset_json" | jq -r 'if has("version_digests") then "yes" else "no" end' 2>/dev/null || echo "no")

                            # Guard: a legacy pushed artifact carries bundle_digest but no
                            # version_digests.  Silently falling back to mutable tag refs for
                            # such an artifact would regress the digest-pinned guarantee.
                            # Fail closed so the operator rebuilds under the new schema.
                            # The tag-fallback path is valid ONLY when neither key is present
                            # (genuine local/no-push build — producer invariant).
                            if [[ "$_vd_field_present" == "no" ]]; then
                                local _bd_field_present
                                _bd_field_present=$(echo "$_versionset_json" | jq -r 'if has("bundle_digest") then "yes" else "no" end' 2>/dev/null || echo "no")
                                if [[ "$_bd_field_present" == "yes" ]]; then
                                    log_error "generate_dockerfile: $ext_name pg${pg_major} artifact has bundle_digest but no version_digests — this is a legacy pre-collector artifact; rebuild under the new schema to restore digest-pinned refs"
                                    return 1
                                fi
                            fi

                            local _art_ver
                            while IFS= read -r _art_ver; do
                                [[ -z "$_art_ver" ]] && continue
                                if [[ "$_vd_field_present" == "yes" ]]; then
                                    # Artifact has version_digests: require a valid digest per version.
                                    local _art_digest
                                    _art_digest=$(echo "$_versionset_json" | jq -r --arg v "$_art_ver" '.version_digests[$v] // empty' 2>/dev/null || true)
                                    if ! is_valid_oci_digest "$_art_digest"; then
                                        log_error "generate_dockerfile: version_digests[$_art_ver] for $ext_name pg${pg_major} is absent or malformed ('$(_sanitize_for_log "$(printf '%s' "${_art_digest:-}" | head -c 80)")') — fail closed"
                                        return 1
                                    fi
                                    _ecs_ver_ref_list+="${_art_ver}	${registry}/${owner}/ext-${ext_name}@${_art_digest}"$'\n'
                                else
                                    # Artifact lacks version_digests (LOCAL_ONLY / no-push build path):
                                    # construct a tag-based ref using the caller's explicit registry/owner
                                    # so the ref targets the correct repo even when the caller passed
                                    # registry/owner overrides.
                                    # This tag-fallback is correct ONLY for the not-pushed (local) case;
                                    # a pushed artifact always has version_digests (producer invariant:
                                    # version_digests absent ⟺ artifact was not pushed).
                                    local _art_plain_ref
                                    _art_plain_ref=$(ext_image_name "$ext_name" "$_art_ver" "$pg_major" "$registry" "$owner")
                                    _ecs_ver_ref_list+="${_art_ver}	${_art_plain_ref}"$'\n'
                                fi
                            done <<< "$raw_versions"
                        fi

                        # Emit the collector stage and single final-stage COPY.
                        # _emit_collector_stage outputs stages and copies separated by ---ECS-COPIES---
                        local _ecs_output
                        if ! _ecs_output=$(_emit_collector_stage "$ext_name" "$_ecs_ver_ref_list"); then
                            return 1
                        fi
                        stages_block+="${_ecs_output%%---ECS-COPIES---*}"
                        # Command substitution strips the trailing newline, so the copies
                        # part would be appended without a newline terminator, causing the
                        # next extension's COPY to concatenate onto the same line.
                        copies_block+="${_ecs_output##*---ECS-COPIES---$'\n'}"$'\n'

                        # Collect runtime_deps (if any) — unchanged from single-version path
                        local deps
                        deps=$(ext="$ext_name" yq -r '(.extensions[strenv(ext)].runtime_deps // [])[]' "$config_file" 2>/dev/null || true)
                        if [[ -n "$deps" ]]; then
                            all_runtime_deps+="${deps}"$'\n'
                        fi
                        continue
                    fi
                fi
            fi

            # Single-version path (no versionset artifact, or jq unavailable):
            # Route through ext_ref_resolve when in PR context (PR_TAG_SUFFIX set):
            #   canonical-first reuse (unchanged version) or PR-scoped (built this PR).
            #   rc 2 → fail closed; rc 1 → ceiling absent on both → fail closed.
            # On push/dispatch (PR_TAG_SUFFIX empty):
            #   emit canonical ref directly — no probe (image availability checked at docker build time).
            local _sv_ref
            if [[ -n "${PR_TAG_SUFFIX:-}" ]]; then
                local _sv_rc=0
                _sv_ref=$(ext_ref_resolve "$ext_name" "$ext_version" "$pg_major" "") || _sv_rc=$?
                if [[ "$_sv_rc" -eq 2 ]]; then
                    log_error "generate_dockerfile: transient registry probe error resolving $ext_name $ext_version pg${pg_major} — fail closed"
                    return 1
                fi
                if [[ "$_sv_rc" -ne 0 ]] || [[ -z "$_sv_ref" ]]; then
                    log_error "generate_dockerfile: ceiling ref for $ext_name $ext_version pg${pg_major} is absent — fail closed"
                    return 1
                fi
            else
                # Push/dispatch: always emit canonical ref (unchanged from pre-consolidation behavior).
                _sv_ref="${registry}/${owner}/ext-${ext_name}:pg${pg_major}-${ext_version}"
            fi
            stages_block+="FROM ${_sv_ref} AS ext-${ext_name}"$'\n'
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

