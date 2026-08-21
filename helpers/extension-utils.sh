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
# shellcheck source=helpers/gha.sh
source "$HELPERS_DIR/gha.sh"

# shellcheck source=helpers/validate-extensions-schema.sh
source "$HELPERS_DIR/validate-extensions-schema.sh"

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

# validate_extension_package_suffix
#
# EXTENSION_PACKAGE_SUFFIX selects a separate GHCR package for an extension
# build. It is deliberately a package-name component, not a tag suffix: a
# value of -staging sends pg18-1.2.3 to ext-<name>-staging:pg18-1.2.3.
#
# An unset variable preserves the canonical production package. A set empty
# value is rejected so a caller cannot accidentally request staging and fall
# back to production. The accepted shape is a leading hyphen followed by
# lowercase OCI repository-name components; it cannot introduce a path, tag,
# digest, or whitespace separator into the assembled reference.
validate_extension_package_suffix() {
    # `${parameter+x}` is available on Bash 4.0; `[[ -v name ]]` is not
    # available until Bash 4.2.
    if [[ -z "${EXTENSION_PACKAGE_SUFFIX+x}" ]]; then
        return 0
    fi

    local suffix="$EXTENSION_PACKAGE_SUFFIX"
    if [[ "$suffix" =~ ^-[a-z0-9]+([._-][a-z0-9]+)*$ ]]; then
        return 0
    fi

    log_error "EXTENSION_PACKAGE_SUFFIX must be unset or match ^-[a-z0-9]+([._-][a-z0-9]+)*$"
    return 1
}

# ext_package_name <extension>
#
# Generate the GHCR package component before any tag or buildcache qualifier.
ext_package_name() {
    local ext_name="$1"
    validate_extension_package_suffix || return 1
    printf 'ext-%s%s' "$ext_name" "${EXTENSION_PACKAGE_SUFFIX:-}"
}

# ext_image_repository <extension> [registry] [owner]
#
# Generate the repository portion of an extension image reference. Keep the
# package suffix here so tag and digest consumers cannot accidentally bypass it.
ext_image_repository() {
    local ext_name="$1"
    local registry="${2:-$(get_registry)}"
    local owner="${3:-$(get_repo_owner)}"
    local package

    package=$(ext_package_name "$ext_name") || return 1
    printf '%s/%s/%s' "$registry" "$owner" "$package"
}

# ext_canonical_image_repository <extension> [registry] [owner]
#
# Return the repository that legacy artifacts necessarily describe.  Before the
# package-suffix axis existed, every digest was observed in this canonical,
# unsuffixed package.
ext_canonical_image_repository() {
    local ext_name="$1"
    local registry="${2:-$(get_registry)}"
    local owner="${3:-$(get_repo_owner)}"

    printf '%s/%s/ext-%s' "$registry" "$owner" "$ext_name"
}

# ext_buildcache_repository <extension> [registry] [owner]
#
# Cache is a sibling package of the selected extension package: the package
# suffix belongs before its existing -buildcache qualifier.
ext_buildcache_repository() {
    local ext_name="$1"
    local registry="${2:-$(get_registry)}"
    local owner="${3:-$(get_repo_owner)}"
    local package

    package=$(ext_package_name "$ext_name") || return 1
    printf '%s/%s/%s-buildcache' "$registry" "$owner" "$package"
}

# Generate extension image name
# Format: ghcr.io/<owner>/ext-<name><package_suffix>:pg<version>-<ext_version>
ext_image_name() {
    local ext_name="$1"
    local ext_version="$2"
    local pg_major="$3"
    local registry="${4:-$(get_registry)}"
    local owner="${5:-$(get_repo_owner)}"
    local repository

    repository=$(ext_image_repository "$ext_name" "$registry" "$owner") || return 1
    printf '%s:pg%s-%s' "$repository" "$pg_major" "$ext_version"
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
    if grep -qiE \
        'manifest unknown|name unknown|repository name not known|no such manifest' <<< "$_probe_stderr"; then
        if command -v skopeo &>/dev/null; then
            local _skopeo_stderr
            local _skopeo_rc=0
            _skopeo_stderr=$(skopeo inspect "docker://${image}" 2>&1 >/dev/null) || _skopeo_rc=$?
            if [[ "$_skopeo_rc" -eq 0 ]]; then
                return 0  # PRESENT (skopeo confirms presence despite docker not-found)
            fi
            # skopeo also non-zero; if skopeo's error is NOT a definitive not-found,
            # escalate to ERROR to avoid discarding the version on ambiguous signal.
            if ! grep -qiE \
                'manifest unknown|name unknown|repository name not known|no such manifest|MANIFEST_UNKNOWN' <<< "$_skopeo_stderr"; then
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

    ext="$ext_name" yq -o=json '.extensions[strenv(ext)] // {}' "$config_file" | \
        jq -r --arg config_key "$key" 'getpath($config_key | split(".")) // ""'
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
             | select((.value.max_pg_version // 999) >= (strenv(pgver) | tonumber))]
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
    remote_tag=$(ext_image_name "$ext_name" "$ext_version" "$pg_major") || return 1

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
    remote_tag=$(ext_image_name "$ext_name" "$ext_version" "$pg_major") || return 1

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

# extension_index_has_exact_digests <raw-index-json> <amd64-digest> <arm64-digest>
#
# Return success only for an index containing exactly one requested linux/amd64
# descriptor and exactly one requested linux/arm64 descriptor.  The promotion
# read-back and retry-recovery paths intentionally share this one predicate.
extension_index_has_exact_digests() {
    local raw_manifest="${1:-}"
    local amd64_digest="${2:-}"
    local arm64_digest="${3:-}"

    jq -e --arg amd64_digest "$amd64_digest" --arg arm64_digest "$arm64_digest" '
        .schemaVersion == 2 and
        (.mediaType == "application/vnd.oci.image.index.v1+json" or
         .mediaType == "application/vnd.docker.distribution.manifest.list.v2+json") and
        (.manifests | type == "array" and length == 2) and
        ([.manifests[] |
            select(.platform.os == "linux" and
                   .platform.architecture == "amd64" and
                   .digest == $amd64_digest)] | length == 1) and
        ([.manifests[] |
            select(.platform.os == "linux" and
                   .platform.architecture == "arm64" and
                   .digest == $arm64_digest)] | length == 1)
    ' >/dev/null <<< "$raw_manifest"
}

# publish_extension_index_from_digests <target-tag-ref> <amd64-digest-ref> <arm64-digest-ref>
#
# Publish one extension multi-architecture index from two explicit, immutable
# per-architecture digest references.  The target is intentionally a tag: it
# is the canonical index consumers resolve.  Its children must be digest refs,
# never mutable architecture tags.  On success, print the digest read back from
# the published index. Returns 1 if creation itself failed and 2 if creation
# succeeded but read-back verification failed, so callers do not claim the tag
# was not written after a successful create.
#
# This is deliberately narrow so callers keep their own state-machine rules
# (copying, conflict fences, and post-publication comparisons) while sharing
# the one registry operation whose inputs must remain digest-pinned.
publish_extension_index_from_digests() {
    local target_ref="${1:-}"
    local amd64_ref="${2:-}"
    local arm64_ref="${3:-}"
    local amd64_digest="${amd64_ref##*@}"
    local arm64_digest="${arm64_ref##*@}"
    local create_rc=0
    local inspect_rc=0
    local hash_rc=0
    local raw_manifest
    local raw_hash
    local published_digest

    if [[ -z "$target_ref" || "$amd64_ref" != *@* || "$arm64_ref" != *@* ]]; then
        log_error "publish_extension_index_from_digests requires one target tag and two digest references"
        return 1
    fi

    is_valid_oci_digest "$amd64_digest" || create_rc=$?
    if [[ "$create_rc" -ne 0 ]]; then
        log_error "Refusing to create extension index: amd64 source is not an explicit valid OCI digest reference"
        return 1
    fi

    create_rc=0
    is_valid_oci_digest "$arm64_digest" || create_rc=$?
    if [[ "$create_rc" -ne 0 ]]; then
        log_error "Refusing to create extension index: arm64 source is not an explicit valid OCI digest reference"
        return 1
    fi

    create_rc=0
    # Intentionally unquoted: logging.sh represents DRY_RUN commands as the
    # two-word substitution "echo docker".
    # shellcheck disable=SC2086
    $DOCKER buildx imagetools create \
        -t "$target_ref" \
        "$amd64_ref" \
        "$arm64_ref" || create_rc=$?
    if [[ "$create_rc" -ne 0 ]]; then
        log_error "Extension index creation outcome is unknown for $(_escape_gha_command "$target_ref") (rc=$create_rc); canonical state may have changed"
        return 3
    fi

    raw_manifest=""
    inspect_rc=0
    # Intentionally unquoted; see the create invocation above.
    # shellcheck disable=SC2086
    raw_manifest=$($DOCKER buildx imagetools inspect "$target_ref" --raw 2>/dev/null) || inspect_rc=$?
    if [[ "$inspect_rc" -ne 0 || -z "$raw_manifest" ]]; then
        log_error "Could not read back the published extension index for $(_escape_gha_command "$target_ref")"
        return 2
    fi

    if ! extension_index_has_exact_digests "$raw_manifest" "$amd64_digest" "$arm64_digest"; then
        log_error "Published extension index for $(_escape_gha_command "$target_ref") did not contain exactly the requested linux/amd64 and linux/arm64 digests"
        return 2
    fi

    raw_hash=""
    raw_hash=$(printf '%s' "$raw_manifest" | sha256sum | awk '{print $1}') || hash_rc=$?
    if [[ "$hash_rc" -ne 0 || -z "$raw_hash" ]]; then
        log_error "Could not calculate the read-back digest for $(_escape_gha_command "$target_ref")"
        return 2
    fi
    published_digest="sha256:${raw_hash}"
    inspect_rc=0
    is_valid_oci_digest "$published_digest" || inspect_rc=$?
    if [[ "$inspect_rc" -ne 0 ]]; then
        log_error "Read-back digest for $(_escape_gha_command "$target_ref") was malformed"
        return 2
    fi

    printf '%s' "$published_digest"
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
# Encapsulates all six axes: canonical-vs-PR-scoped, arch suffix, FORCE,
# FORCE_SCOPED_EXTENSION_REFS scope membership, 3-state fail-closed, PR suffix.
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
#   FORCE_SCOPED_EXTENSION_REFS
#                  (comma-separated extension names, "*" for all, or empty;
#                  a run-scoped contract set only after this run published the
#                  named extension images. Only a named extension uses its
#                  freshly-published PR-scoped ref. Empty values force nothing;
#                  malformed non-empty values fail closed.)
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
#   FORCE_SCOPED_EXTENSION_REFS names ext AND PR_TAG_SUFFIX set:
#     → prefer PR-scoped (freshly rebuilt this run); do NOT reuse canonical.
#     Probe PR-scoped only (canonical is stale for this version).
#   else (neither force signal, or no PR_TAG_SUFFIX):
#     → prefer canonical when PRESENT (read-only reuse for unchanged versions).
#     If canonical ABSENT and PR_TAG_SUFFIX set → probe PR-scoped.
#
# Output / return codes:
#   rc 0  → prints the ref to use (canonical or pr-scoped).
#   rc 1  → neither ref exists definitively (needs build or exclude).
#           prints nothing.
#   rc 2  → a probe returned transient ERROR, the run scope is malformed, or
#           reference construction failed
#           → fail closed.
#           prints nothing.
#
# On push/dispatch (PR_TAG_SUFFIX empty): only canonical is considered;
# behavior is identical to the current canonical path.
_force_scoped_extension_ref() {
    local ext="$1" scope="${FORCE_SCOPED_EXTENSION_REFS:-}" scoped_ext
    local -a scoped_exts

    # "*" is the explicit all-extensions scope. Every other non-empty value
    # must be a complete comma-separated extension-name list. This mirrors the
    # schema validator's name_shaped rule, ^[A-Za-z0-9_-]+$, so a schema-valid
    # extension name has the same meaning in this run-scoped contract.
    case "$scope" in
        '*') return 0 ;;
        '') return 1 ;;
    esac
    [[ "$scope" =~ ^[A-Za-z0-9_-]+(,[A-Za-z0-9_-]+)*$ ]] || return 2

    IFS=',' read -ra scoped_exts <<< "$scope"
    for scoped_ext in "${scoped_exts[@]}"; do
        [[ "$ext" == "$scoped_ext" ]] && return 0
    done
    return 1
}

# _parse_rotation_candidate_ref
#
# Parse ROTATION_CANDIDATE_REF's shared selector grammar.  The fixed
# _rotation_candidate_ref_* globals are this function's deliberate multi-value
# return channel: a caller-supplied output variable (and therefore a nameref)
# could silently collide with a variable in a script that sources this file.
#
# Returns:
#   0  ROTATION_CANDIDATE_REF is set, non-empty, and has a valid selector;
#      _rotation_candidate_ref_extension, _rotation_candidate_ref_pg_major,
#      _rotation_candidate_ref_version, and _rotation_candidate_ref_value are
#      available to the caller.
#   1  ROTATION_CANDIDATE_REF is unset or empty.
#   2  ROTATION_CANDIDATE_REF is set and malformed.
#
# This helper owns only the left/right split and selector shape.  Its callers
# retain validation of the pinned reference and its applicability.
_parse_rotation_candidate_ref() {
    local LC_ALL=C
    local candidate candidate_left candidate_ref

    _rotation_candidate_ref_extension=""
    _rotation_candidate_ref_pg_major=""
    _rotation_candidate_ref_version=""
    _rotation_candidate_ref_value=""

    if [[ -z "${ROTATION_CANDIDATE_REF+x}" ]]; then
        return 1
    fi
    candidate="$ROTATION_CANDIDATE_REF"
    [[ -n "$candidate" ]] || return 1

    if [[ "$candidate" != *=* ]]; then
        return 2
    fi
    candidate_left="${candidate%%=*}"
    candidate_ref="${candidate#*=}"
    if [[ "$candidate_ref" == *=* ]] || ! [[ "$candidate_left" =~ ^([A-Za-z0-9_-]+):([0-9]+):([^:=]+)$ ]]; then
        return 2
    fi

    _rotation_candidate_ref_extension="${BASH_REMATCH[1]}"
    _rotation_candidate_ref_pg_major="${BASH_REMATCH[2]}"
    _rotation_candidate_ref_version="${BASH_REMATCH[3]}"
    _rotation_candidate_ref_value="$candidate_ref"
    return 0
}

ext_ref_resolve() {
    local ext="$1" version="$2" major="$3" arch="${4:-}"
    local registry owner canonical_ref pr_ref scope_rc=0

    # The run scope can only affect a PR-scoped reference.  On push/dispatch,
    # leave it completely unconsulted so this remains the canonical-only path.
    if [[ -n "${PR_TAG_SUFFIX:-}" ]]; then
        # A corrupt non-empty run scope must not silently select canonical images.
        # Keep rc 2 for this fail-closed resolution error, matching probe failures.
        _force_scoped_extension_ref "$ext" || scope_rc=$?
        case "$scope_rc" in
            0|1) ;;
            *)
                printf 'ERROR [ext_ref_resolve]: invalid FORCE_SCOPED_EXTENSION_REFS scope\n' >&2
                return 2
                ;;
        esac
    fi

    registry=$(get_registry)
    owner=$(get_repo_owner)

    # Build canonical base: ext_image_name gives registry/owner/ext-<name>:pg<major>-<ver>
    # Append arch suffix when arch is non-empty.
    if ! canonical_ref=$(ext_image_name "$ext" "$version" "$major" "$registry" "$owner"); then
        printf 'ERROR [ext_ref_resolve]: failed to construct reference\n' >&2
        return 2
    fi
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
    # A forced rebuild, or a scope that names this extension, must prefer the
    # PR-scoped ref and never reuse the canonical stale ref.
    if { [[ "${FORCE:-false}" == "true" ]] || [[ "$scope_rc" -eq 0 ]]; } && [[ -n "${PR_TAG_SUFFIX:-}" ]]; then
        # Probe the PR-scoped ref only.
        local _rc=0
        _image_registry_probe_3state "$pr_ref" || _rc=$?
        case "$_rc" in
            0) printf '%s' "$pr_ref"; return 0 ;;
            1) return 1 ;;  # absent — needs build
            *) return 2 ;;  # transient error — fail closed
        esac
    fi

    # Normal path (neither force signal + PR, or push/dispatch):
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

# ext_consumed_source_ref <extension> <version> <pg_major> <registry> <owner> <mode> [artifact_digest]
#
# Return the immutable or tag-based source reference a generated Dockerfile
# consumes.  Keeping the candidate selector here means every generated FROM and
# COPY --from reference has the same narrow, frozen-rotation escape hatch.
ext_consumed_source_ref() {
    local extension="${1:-}"
    local version="${2:-}"
    local pg_major="${3:-}"
    local registry="${4:-}"
    local owner="${5:-}"
    local mode="${6:-}"
    local artifact_digest="${7:-}"
    local LC_ALL=C
    local candidate_rc=0
    local candidate_ref candidate_extension candidate_pg_major candidate_version
    local candidate_repository candidate_digest candidate_suffix expected_repository
    local repository candidate_prefix

    if [[ -z "$extension" || -z "$version" || -z "$pg_major" || -z "$registry" || -z "$owner" || -z "$mode" ]]; then
        log_error "ext_consumed_source_ref: extension, version, pg_major, registry, owner, and mode are required"
        return 1
    fi

    # Keep the mode set closed even when a matching candidate would otherwise
    # return before the fallback switch below.
    case "$mode" in
        pinned-digest|probe|direct) ;;
        *)
            log_error "ext_consumed_source_ref: unsupported mode '$mode'"
            return 1
            ;;
    esac

    # A requested frozen candidate must be completely understood before any
    # fallback can run; otherwise a malformed rotation could test canonical bytes.
    _parse_rotation_candidate_ref || candidate_rc=$?
    case "$candidate_rc" in
        0)
            candidate_extension="$_rotation_candidate_ref_extension"
            candidate_pg_major="$_rotation_candidate_ref_pg_major"
            candidate_version="$_rotation_candidate_ref_version"
            candidate_ref="$_rotation_candidate_ref_value"

            # The producer uses this package axis to write a staging package. A
            # consumer with a frozen candidate must not inherit it: its
            # non-candidate versions would otherwise be redirected to that
            # staging package.
            if [[ -n "${EXTENSION_PACKAGE_SUFFIX+x}" && -n "$EXTENSION_PACKAGE_SUFFIX" ]]; then
                log_error "ROTATION_CANDIDATE_REF cannot be consumed while EXTENSION_PACKAGE_SUFFIX is set"
                return 2
            fi
            ;;
        1) ;;
        2)
            log_error "ROTATION_CANDIDATE_REF must match <extension>:<pg_major>:<version>=<repository>@<digest>"
            return 2
            ;;
        *)
            log_error "ROTATION_CANDIDATE_REF could not be parsed"
            return 2
            ;;
    esac

    if [[ "$candidate_rc" -eq 0 ]]; then
        if ! [[ "$candidate_ref" =~ ^(.+)@([^@]+)$ ]]; then
            log_error "ROTATION_CANDIDATE_REF must contain one pinned repository@sha256 digest reference"
            return 2
        fi
        candidate_repository="${BASH_REMATCH[1]}"
        candidate_digest="${BASH_REMATCH[2]}"
        if ! is_valid_oci_digest "$candidate_digest"; then
            log_error "ROTATION_CANDIDATE_REF must contain a valid pinned sha256 digest"
            return 2
        fi

        candidate_prefix="${registry}/${owner}/ext-${candidate_extension}"
        case "$candidate_repository" in
            "$candidate_prefix"-*) candidate_suffix="${candidate_repository#"$candidate_prefix"}" ;;
            *)
                log_error "ROTATION_CANDIDATE_REF repository must be a suffixed package belonging to this invocation's registry, owner, and extension"
                return 2
                ;;
        esac

        # A suffixed package prevents a rotation from testing bytes already in
        # the canonical package. It does not establish that the suffix belongs
        # to this rotation: an arbitrary ext-<name>-something is still accepted
        # from the actor who supplies the workflow candidate.
        if ! EXTENSION_PACKAGE_SUFFIX="$candidate_suffix" validate_extension_package_suffix; then
            log_error "ROTATION_CANDIDATE_REF repository has an invalid package suffix"
            return 2
        fi
        expected_repository=$(EXTENSION_PACKAGE_SUFFIX="$candidate_suffix" ext_image_repository "$candidate_extension" "$registry" "$owner") || return 2
        if [[ "$candidate_repository" != "$expected_repository" ]]; then
            log_error "ROTATION_CANDIDATE_REF repository does not match the frozen candidate package"
            return 2
        fi

        if [[ "$extension" == "$candidate_extension" && "$pg_major" == "$candidate_pg_major" && "$version" == "$candidate_version" ]]; then
            printf '%s' "$candidate_ref"
            return 0
        fi
    fi

    case "$mode" in
        pinned-digest)
            if ! is_valid_oci_digest "$artifact_digest"; then
                log_error "ext_consumed_source_ref: artifact digest for $extension $version pg${pg_major} is absent or malformed — fail closed"
                return 1
            fi
            repository=$(ext_image_repository "$extension" "$registry" "$owner") || return 1
            printf '%s@%s' "$repository" "$artifact_digest"
            ;;
        probe)
            # ext_ref_resolve resolves registry and owner internally, unlike the
            # other modes; forward this invocation's explicit identity once here.
            EXTENSION_REGISTRY="$registry" GITHUB_REPOSITORY_OWNER="$owner" \
                ext_ref_resolve "$extension" "$version" "$pg_major" ""
            ;;
        direct)
            ext_image_name "$extension" "$version" "$pg_major" "$registry" "$owner"
            ;;
    esac
}

# Get list of extensions for a flavor, filtered by PG version compatibility
# Excludes disabled extensions and those exceeding max_pg_version
get_flavor_extensions() {
    local config_file="$1"
    local flavor="$2"
    local pg_major="$3"
    local declared_flavors
    local flavor_exists

    if ! declared_flavors=$(yq -r '.flavors | keys | join(", ")' "$config_file"); then
        log_error "get_flavor_extensions: could not read declared flavors from ${config_file}"
        return 1
    fi

    # The REQUESTED flavour, not only the declared keys. `env()` parses its value
    # as YAML, so `vector # $(id)` reduces to `vector` and membership succeeds
    # while the original text is what reaches the generated ARG, the guard and
    # its echo — executing the substitution before the guard can reject it.
    # `strenv()` takes the value as a string, and the same name shape the keys
    # must satisfy applies here too.
    if [[ ! "$flavor" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "get_flavor_extensions: invalid flavor name requested: $(_sanitize_for_log "$flavor")"
        return 1
    fi

    if ! flavor_exists=$(flav="$flavor" yq -r '.flavors | has(strenv(flav))' "$config_file"); then
        log_error "get_flavor_extensions: could not read declared flavors from ${config_file}"
        return 1
    fi

    if [[ "$flavor_exists" != "true" ]]; then
        log_error "get_flavor_extensions: unknown flavor '${flavor}' (declared flavors: ${declared_flavors})"
        return 1
    fi

    pgver="$pg_major" flav="$flavor" yq -r '
        . as $root |
        .flavors[strenv(flav)] // [] | .[] | . as $ext |
        select(
            ($root.extensions[$ext].disabled == true | not) and
            (($root.extensions[$ext].max_pg_version // 999) >= (strenv(pgver) | tonumber))
        )
    ' "$config_file"
}

# _generate_builtin_initdb_block <config_file>
#
# Render built-in CREATE EXTENSION statements from builtin_extensions.  The
# generated Dockerfile is shared by all supported PostgreSQL majors, so a
# max_major declaration deliberately remains a test of MAJOR_VERSION in the
# emitted RUN block instead of being resolved while this file is generated.
#
# A built-in may be a scalar name or a mapping with name and optional
# How many built-ins the last _generate_builtin_initdb_block call emitted.  The
# rendered block always carries its `RUN` scaffolding, so its size says nothing
# about whether anything was declared, and a second yq read of the config would
# be a second reader of the same field — which the reader invariant forbids and
# this branch exists to avoid.  The function that reads the list reports what it
# saw instead.

# max_major.  Keep validation here: this is the only reader allowed to turn
# those declarations into executable Dockerfile content, and unknown mapping
# keys must fail closed rather than silently changing the resulting image.
_generate_builtin_initdb_block() {
    local config_file="$1"
    local builtin_entries

    if ! builtin_entries=$(yq eval -o=json '.builtin_extensions // []' "$config_file" | jq -r '
        def entry_error($index; $message):
          error("builtin_extensions entry " + ($index | tostring) + " " + $message);
        if type != "array" then
          error("builtin_extensions must be a list")
        else . end
        | . as $declared
        | [ to_entries[]
            | .key as $index
            | .value as $entry
            | if ($entry | type) == "string" then
                {name: $entry, max_major: null}
              elif ($entry | type) == "object" then
                ([$entry | keys[] | select(. != "name" and . != "max_major")]) as $unknown_keys
                | if ($unknown_keys | length) != 0 then
                    entry_error($index; "contains unrecognised key(s): " + ($unknown_keys | join(", ")))
                  elif ($entry | has("name") | not) then
                    entry_error($index; "must declare name")
                  elif ($entry.name | type) != "string" then
                    entry_error($index; "name must be a string")
                  elif ($entry | has("max_major"))
                       and ((($entry.max_major | type) != "number")
                            or ($entry.max_major != ($entry.max_major | floor))
                            or ($entry.max_major < 1)) then
                    entry_error($index; "max_major must be a positive integer")
                  else
                    {name: $entry.name, max_major: ($entry.max_major // null)}
                  end
              else
                entry_error($index; "must be a name string or mapping")
              end
            | if (.name | test("\\A[A-Za-z0-9_-]+\\z")) then .
              else entry_error($index; "name must be name-shaped")
              end ] as $normalized
        | ($declared | '"$(builtin_extension_names_jq)"') as $names
        | $normalized | to_entries[]
        | [$names[.key], (.value.max_major // "")] | @tsv
    ' 2>&1); then
        log_error "_generate_builtin_initdb_block: invalid builtin_extensions in ${config_file}: $(_sanitize_for_log "$builtin_entries")"
        return 1
    fi

    local builtin_name
    local max_major
    local sql_identifier
    local create_line
    local initdb_block="RUN set -eux; \\"$'\n'

    initdb_block+="    { \\"$'\n'
    # Terminated, not continued: every entry below emits its own complete
    # `printf`, so a trailing backslash here would make the header swallow the
    # next one — `printf` and `%s\n` reach the SQL file as bare lines and
    # PostgreSQL rejects the script at first start. It also means an empty list,
    # or a bounded entry first, still produces a valid command.
    initdb_block+="    printf '%s\\n' '-- Built-in PostgreSQL extensions (available in all flavors)'; \\"$'\n'

    while IFS=$'\t' read -r builtin_name max_major; do
        [[ -z "$builtin_name" ]] && continue

        # PostgreSQL accepts this identifier shape without quotes.  Quote every
        # other declared name rather than carrying a list of exceptions, so the
        # next hyphenated built-in cannot become invalid SQL by omission.
        if [[ "$builtin_name" =~ ^[a-z_][a-z0-9_]*$ ]]; then
            sql_identifier="$builtin_name"
        else
            sql_identifier="\"${builtin_name}\""
        fi
        create_line="CREATE EXTENSION IF NOT EXISTS ${sql_identifier};"

        if [[ -n "$max_major" ]]; then
            initdb_block+="    if [ \"\${MAJOR_VERSION}\" -le ${max_major} ] 2>/dev/null; then \\"$'\n'
            initdb_block+="        printf '%s\\n' '${create_line}'; \\"$'\n'
            initdb_block+="    fi; \\"$'\n'
        else
            initdb_block+="    printf '%s\\n' '${create_line}'; \\"$'\n'
        fi
    done <<< "$builtin_entries"

    initdb_block+="    } > /docker-entrypoint-initdb.d/00-init-extensions.sql"$'\n'
    printf '%s' "$initdb_block"
}

# _generate_flavor_initdb_block <config_file> <flavor> <extensions>
#
# Render the one flavor-specific compiled-extension initdb block from the same
# already-filtered extension list used for stages, COPYs, and install_ext calls.
# Every compiled extension must state an explicit policy: create or manual.
# A manual policy emits no SQL; it documents an extension that cannot safely be
# created during the image's first-database initialization.
_generate_flavor_initdb_block() {
    local config_file="$1"
    local flavor="$2"
    local extensions="$3"
    local ext_name
    local mode
    local sql_name
    # Keep the declaration key and its resolved SQL name together. The
    # generated assertion and CREATE statement are deliberately rendered from
    # this one list, so a CREATE cannot be added without its control-file
    # assertion.
    local -a create_sql_names=()
    local initdb_block=""

    # Only selected, compatible extensions can produce flavor SQL.
    while IFS= read -r ext_name; do
        [[ -z "$ext_name" ]] && continue
        mode=$(ext="$ext_name" yq -r '.extensions[strenv(ext)].initdb.mode' "$config_file") || return 1
        [[ "$mode" == "manual" ]] && continue

        sql_name=$(ext="$ext_name" yq -r '.extensions[strenv(ext)].initdb.sql_name // ""' "$config_file") || return 1
        [[ -z "$sql_name" ]] && sql_name="$ext_name"
        create_sql_names+=("${ext_name}"$'\t'"${sql_name}")
    done <<< "$extensions"

    if [[ ${#create_sql_names[@]} -eq 0 ]]; then
        return 0
    fi

    initdb_block+="RUN set -eux; \\"$'\n'
    initdb_block+="    sharedir=\"\$(pg_config --sharedir)\"; \\"$'\n'
    # A zero exit says pg_config ran, not that it answered. An empty result makes
    # every test below read /extension/<name>.control, where an unrelated match
    # is a false pass; a relative one resolves against whatever the build stage's
    # working directory happens to be. Neither is a directory this image installs
    # extensions into, so refuse rather than search one.
    # `${sharedir#/}` removes one leading slash; unchanged means there was none,
    # which also catches the empty answer. Written as `if … fi;` like every other
    # test in this block rather than a `case`: a `;;` inside a Dockerfile line
    # continuation is not something the surrounding tooling reads back reliably.
    initdb_block+="    if test \"\${sharedir#/}\" = \"\$sharedir\"; then \\"$'\n'
    initdb_block+="        echo \"ERROR: pg_config --sharedir returned '\$sharedir', which is not an absolute path; refusing to look for extension control files there.\" >&2; \\"$'\n'
    initdb_block+="        exit 1; \\"$'\n'
    initdb_block+="    fi; \\"$'\n'
    # The build runs as root and PostgreSQL does not, so `test -f` as root is the
    # wrong question. Measured on the shipped image: a control file at 0600
    # root:root passes both `test -f` and `test -r` for root and fails
    # `gosu postgres test -r`, which is the read the server actually performs at
    # first startup. `cp -av` preserves mode from the staging tree, and this
    # repository has already shipped a 0700 onto a PostgreSQL system directory
    # that way, so the mode is not hypothetical.
    #
    # gosu is required rather than optional: without it the check would silently
    # become the root test it is replacing, which is a guard that reports success
    # for the case it exists to catch.
    initdb_block+="    command -v gosu >/dev/null || { echo \"ERROR: gosu is required to verify extension control files as the postgres user, and was not found.\" >&2; exit 1; }; \\"$'\n'
    local create_entry
    local create_ext_name
    local create_sql_lines=""
    for create_entry in "${create_sql_names[@]}"; do
        create_ext_name="${create_entry%%$'\t'*}"
        sql_name="${create_entry#*$'\t'}"
        initdb_block+="    if ! gosu postgres test -r \"\${sharedir}/extension/${sql_name}.control\"; then \\"$'\n'
        initdb_block+="        echo \"ERROR: extension key '${create_ext_name}' resolves to SQL name '${sql_name}', but the postgres user cannot read a control file at \${sharedir}/extension/${sql_name}.control. Either it was never installed, or its mode or a parent directory keeps the server out. The SQL name comes from initdb.sql_name in postgres/extensions/config.yaml (or the extension key when initdb.sql_name is omitted).\" >&2; \\"$'\n'
        initdb_block+="        exit 1; \\"$'\n'
        initdb_block+="    fi; \\"$'\n'
        # Quoted, as the built-in block already quotes "uuid-ossp". Measured on
        # PostgreSQL 18: `CREATE EXTENSION IF NOT EXISTS select;` is a syntax
        # error while the quoted form parses, and for a name the schema already
        # admits — folded lowercase — the two are indistinguishable. So quoting
        # removes the reserved-keyword class outright instead of asking the
        # validator to carry a keyword list that grows with each release.
        create_sql_lines+="        'CREATE EXTENSION IF NOT EXISTS \"${sql_name}\";' \\"$'\n'
    done
    initdb_block+="    printf '%s\\n' \\"$'\n'
    initdb_block+="        '-- ${flavor} flavor: compiled extensions' \\"$'\n'
    initdb_block+="${create_sql_lines}"
    initdb_block+="        > /docker-entrypoint-initdb.d/01-init-flavor.sql"$'\n'
    printf '%s' "$initdb_block"
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
#   # @@BUILTIN_INITDB@@     → replaced by the built-in CREATE EXTENSION block,
#                              and required whenever the config declares any
#                              built-in: without it the image would ship none of
#                              them, silently (#1136)
#
# Usage: generate_dockerfile <config_file> <template> <flavor> <pg_major> [registry] [owner]
generate_dockerfile() {
    local config_file="$1"
    local template="$2"
    local flavor="$3"
    local pg_major="$4"
    local registry="${5:-$(get_registry)}"
    local owner="${6:-$(get_repo_owner)}"
    local LC_ALL=C

    if ! validate_extensions_schema "$config_file"; then
        log_error "generate_dockerfile: extensions schema validation failed for ${config_file}"
        return 1
    fi

    # Derive FORCE from REBUILD env so a forced PR run prefers freshly-rebuilt
    # PR-scoped refs over stale canonical refs for non-resolver/single-version
    # extensions.  This mirrors the --force logic in build-extensions.sh and
    # merge-extension-manifests.  ext_ref_resolve also reads the separate
    # FORCE_SCOPED_EXTENSION_REFS run contract.  The build-and-push job exports
    # REBUILD from env.REBUILD_MODE.
    # Pre-existing FORCE=true is preserved (e.g. LOCAL_ONLY builds).
    if [[ "${REBUILD:-}" == "force" || "${REBUILD:-}" == "all" ]]; then
        export FORCE=true
    fi

    # Get filtered extension list for this flavor + PG version
    local extensions
    if ! extensions=$(get_flavor_extensions "$config_file" "$flavor" "$pg_major"); then
        log_error "generate_dockerfile: cannot determine extensions for flavor '${flavor}'"
        return 1
    fi

    local builtin_initdb_block
    if ! builtin_initdb_block=$(_generate_builtin_initdb_block "$config_file"); then
        return 1
    fi

    local flavor_initdb_block
    if ! flavor_initdb_block=$(_generate_flavor_initdb_block "$config_file" "$flavor" "$extensions"); then
        return 1
    fi

    # FLAVOR is build-time input, but this file is generated for exactly one
    # flavor. Bind it to that flavor so labels, COPY stages, and installations
    # cannot describe different images when a caller passes --build-arg FLAVOR.
    local flavor_arg_block="ARG FLAVOR=${flavor}"$'\n'
    local install_block=""
    install_block+="    # Generated flavor guard and install list for ${flavor}."$'\n'
    install_block+="    if [ \"\${FLAVOR}\" != \"${flavor}\" ]; then \\"$'\n'
    install_block+="        echo \"ERROR: generated Dockerfile is for flavor ${flavor}, got \${FLAVOR}\" >&2; \\"$'\n'
    install_block+="        exit 1; \\"$'\n'
    install_block+="    fi; \\"$'\n'

    if [[ -n "$extensions" ]]; then
        local install_ext_name
        while IFS= read -r install_ext_name; do
            [[ -z "$install_ext_name" ]] && continue
            install_block+="    install_ext ${install_ext_name}; \\"$'\n'
        done <<< "$extensions"
    else
        install_block+="    echo \"Base flavor: no compiled extensions\"; \\"$'\n'
    fi

    # Build the FROM stages block
    local stages_block=""
    local copies_block=""
    local all_runtime_deps=""
    local candidate_rc=0
    local candidate_ref candidate_extension candidate_pg_major
    local candidate_applies=false

    # The source gateway validates every candidate it reaches.  This render
    # scope check covers the distinct valid-but-unconsumed case: only a
    # candidate naming an extension emitted by this flavor and this PG major is
    # required to appear in the assembled stage text.
    _parse_rotation_candidate_ref || candidate_rc=$?
    case "$candidate_rc" in
        0)
            candidate_extension="$_rotation_candidate_ref_extension"
            candidate_pg_major="$_rotation_candidate_ref_pg_major"
            candidate_ref="$_rotation_candidate_ref_value"
            if [[ "$candidate_pg_major" == "$pg_major" ]] && grep -Fxq -- "$candidate_extension" <<< "$extensions"; then
                candidate_applies=true
            fi
            ;;
        1) ;;
        2)
            log_error "generate_dockerfile: ROTATION_CANDIDATE_REF is malformed — fail closed"
            return 1
            ;;
        *)
            log_error "generate_dockerfile: ROTATION_CANDIDATE_REF could not be parsed — fail closed"
            return 1
            ;;
    esac

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
            local _artifact_json=""
            local _artifact_has_version_digests=false
            if [[ -f "$versionset_file" ]]; then
                # mapfile is a Bash builtin.  Unlike an assignment containing only
                # a redirection, its failed file-open status is preserved when
                # generate_dockerfile itself is invoked from an if condition.
                local -a _artifact_lines=()
                if ! mapfile -d '' _artifact_lines < "$versionset_file"; then
                    log_error "generate_dockerfile: cannot read versionset artifact: $versionset_file"
                    return 1
                fi
                _artifact_json="${_artifact_lines[0]-}"

                if command -v jq &>/dev/null; then
                    # Only a valid artifact may declare digest data for consumption.
                    # A malformed artifact follows the existing self-heal/fallback path
                    # and never supplies a digest through a fallback expression.
                    if printf '%s' "$_artifact_json" | jq -e 'type == "object" and has("available") and (.available | type) == "array" and (.available | length) > 0' \
                        > /dev/null 2>&1; then
                        _artifact_valid=1
                        printf '%s' "$_artifact_json" | jq -e 'has("version_digests")' > /dev/null 2>&1 && _artifact_has_version_digests=true
                        # Digest-bearing artifacts record where their index digests
                        # were observed. A missing identity is legacy provenance:
                        # it means the canonical unsuffixed package, never the
                        # package selected by the current caller.
                        if [[ "$_artifact_has_version_digests" == "true" ]]; then
                            local _artifact_digest_repository _expected_digest_repository
                            if printf '%s' "$_artifact_json" | jq -e 'has("version_digests_repository")' > /dev/null 2>&1; then
                                _artifact_digest_repository=$(printf '%s' "$_artifact_json" | jq -r '.version_digests_repository' 2>/dev/null || true)
                            else
                                _artifact_digest_repository=$(ext_canonical_image_repository "$ext_name" "$registry" "$owner") || return 1
                            fi
                            _expected_digest_repository=$(ext_image_repository "$ext_name" "$registry" "$owner") || return 1
                            if [[ "$_artifact_digest_repository" != "$_expected_digest_repository" ]]; then
                                log_warning "generate_dockerfile: version_digests for $ext_name pg${pg_major} belong to $_artifact_digest_repository, not $_expected_digest_repository — treating artifact as absent, triggering self-heal"
                                _artifact_valid=0
                                _artifact_has_version_digests=false
                            fi
                        fi
                    fi
                fi
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

            if [[ -n "$_resolver_path" ]] && [[ "$_artifact_valid" -eq 0 ]]; then
                if [[ -n "$_artifact_json" ]]; then
                    log_error "generate_dockerfile: versionset artifact for $ext_name pg${pg_major} is malformed, missing .available array, or has empty available[] — treating as absent, triggering self-heal"
                fi
                # skopeo is required by the LIVE resolver path (skopeo list-tags docker.io).
                # When the committed version-set file satisfies the SAME acceptance conditions
                # that resolve_version_set uses (ceiling match AND committed_len >= retain_count),
                # resolve_version_set returns the committed slice without invoking skopeo —
                # skip the guard in that case.
                # When the committed file is absent, misses this major, has a stale ceiling, or
                # is under-retained, the live resolver path IS taken and skopeo IS required;
                # fail fast with a clear, actionable message before the resolver is invoked so
                # the operator sees what to install rather than an opaque "skopeo: command not found".
                # This check fires ONLY on the self-heal/resolve branch; the valid-artifact path
                # above does not use skopeo and is not affected.
                # _committed_versionset_satisfies is the SAME predicate used by resolve_version_set
                # so preflight and resolver share one source of truth — no duplication of conditions.
                local _preflight_retain_count
                _preflight_retain_count=$(ext="$ext_name" yq -r \
                    '.extensions[strenv(ext)].version_set.retain_count // ""' \
                    "$config_file" 2>/dev/null || true)
                local _preflight_effective_retain="${_preflight_retain_count:-12}"
                if ! _committed_versionset_satisfies \
                        "$ext_name" "$pg_major" "$ext_version" "${_preflight_effective_retain}"; then
                    if ! command -v skopeo &>/dev/null; then
                        log_error "generate_dockerfile: skopeo is required to resolve the ${ext_name} version set when neither a version-set artifact nor a satisfactory committed version-set covers pg${pg_major}; install skopeo (see postgres/README.md) or supply the artifact manually"
                        return 1
                    fi
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

                # Probe registry presence for each resolved version through the consumed
                # source gateway. It preserves ext_ref_resolve's canonical-first, PR-scoped fallback,
                # both force signals, and 3-state fail-closed in one call
                # (arch="" = multi-arch tag).
                # rc 0 → PRESENT (ref printed); rc 1 → ABSENT; rc 2 → consumed-source resolution failure (fail-closed).
                local _sh_available=()
                local -A _sh_emit_ref_map=()  # version → resolved emit ref (for lookup in emit loop)
                local _sh_ver
                while IFS= read -r _sh_ver; do
                    [[ -z "$_sh_ver" ]] && continue
                    local _sh_resolved_ref _sh_rc=0
                    _sh_resolved_ref=$(ext_consumed_source_ref "$ext_name" "$_sh_ver" "$pg_major" "$registry" "$owner" probe) || _sh_rc=$?
                    case "$_sh_rc" in
                        0)
                            _sh_available+=("$_sh_ver")
                            _sh_emit_ref_map["$_sh_ver"]="$_sh_resolved_ref"
                            ;;
                        1)  ;;   # ABSENT — musl-failed / never-built / not yet pushed
                        *)
                            log_error "generate_dockerfile: consumed-source resolution failure for $ext_name $_sh_ver pg${pg_major} during self-heal — cannot determine availability (fail-closed)"
                            return 1
                            ;;
                    esac
                done < <(echo "$_sh_resolved_json" | jq -r '.[]' 2>/dev/null || true)

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
            elif [[ "$_artifact_valid" -eq 1 ]] && command -v jq &>/dev/null; then
                _versionset_json="$_artifact_json"
            fi

            # A legacy pushed artifact has the old bundle digest but no per-version
            # digest map. Tag fallback is safe only for an artifact that was never
            # pushed: the producer omits version_digests exactly for that case.
            if [[ "$_artifact_valid" -eq 1 ]] && [[ "$_artifact_has_version_digests" == "false" ]]; then
                local _legacy_bundle_digest
                _legacy_bundle_digest=$(printf '%s' "$_artifact_json" | jq -r 'if has("bundle_digest") then "yes" else "no" end' 2>/dev/null || echo "no")
                if [[ "$_legacy_bundle_digest" == "yes" ]]; then
                    log_error "generate_dockerfile: $ext_name pg${pg_major} artifact has bundle_digest but no version_digests — this is a legacy pre-collector artifact; rebuild under the new schema to restore digest-pinned refs"
                    return 1
                fi
            fi

            if [[ -n "$_versionset_json" ]] && command -v jq &>/dev/null; then
                local available_count
                available_count=$(echo "$_versionset_json" | jq '.available | length' 2>/dev/null || echo 0)

                # whenever available has exactly ONE entry, that entry MUST
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
                            # Self-heal path: refs already resolved by the source gateway above.
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
                            # Artifact-present path: the digest lookup is additive. It is
                            # reached only for a valid artifact that declares
                            # version_digests; tag-only artifacts retain the established
                            # tag construction.
                            local _art_ver
                            while IFS= read -r _art_ver; do
                                [[ -z "$_art_ver" ]] && continue
                                local _art_ref
                                if [[ "$_artifact_has_version_digests" == "true" ]]; then
                                    local _art_digest
                                    _art_digest=$(printf '%s' "$_artifact_json" | jq -r --arg v "$_art_ver" '.version_digests[$v] // empty' 2>/dev/null || true)
                                    if ! is_valid_oci_digest "$_art_digest"; then
                                        log_error "generate_dockerfile: version_digests[$_art_ver] for $ext_name pg${pg_major} is absent or malformed ('$(_sanitize_for_log "$(printf '%s' "${_art_digest:-}" | head -c 80)")') — fail closed"
                                        return 1
                                    fi
                                    _art_ref=$(ext_consumed_source_ref "$ext_name" "$_art_ver" "$pg_major" "$registry" "$owner" pinned-digest "$_art_digest") || return 1
                                else
                                    _art_ref=$(ext_consumed_source_ref "$ext_name" "$_art_ver" "$pg_major" "$registry" "$owner" direct) || return 1
                                fi
                                _ecs_ver_ref_list+="${_art_ver}	${_art_ref}"$'\n'
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

            # Single-version path (no multi-version collector needed):
            # only a valid artifact that declares version_digests adds immutable
            # consumption. All other cases retain the established tag resolution.
            # Route through ext_ref_resolve when in PR context (PR_TAG_SUFFIX set):
            #   canonical-first reuse (unchanged version) or PR-scoped (built this PR).
            #   rc 2 → fail closed; rc 1 → ceiling absent on both → fail closed.
            # On push/dispatch (PR_TAG_SUFFIX empty):
            #   emit canonical ref directly — no probe (image availability checked at docker build time).
            local _sv_ref
            if [[ "$_artifact_valid" -eq 1 ]] && [[ "$_artifact_has_version_digests" == "true" ]]; then
                local _sv_digest
                _sv_digest=$(printf '%s' "$_artifact_json" | jq -r --arg v "$ext_version" '.version_digests[$v] // empty' 2>/dev/null || true)
                if ! is_valid_oci_digest "$_sv_digest"; then
                    log_error "generate_dockerfile: version_digests[$ext_version] for $ext_name pg${pg_major} is absent or malformed ('$(_sanitize_for_log "$(printf '%s' "${_sv_digest:-}" | head -c 80)")') — fail closed"
                    return 1
                fi
                _sv_ref=$(ext_consumed_source_ref "$ext_name" "$ext_version" "$pg_major" "$registry" "$owner" pinned-digest "$_sv_digest") || return 1
            elif [[ -n "${PR_TAG_SUFFIX:-}" ]]; then
                local _sv_rc=0
                _sv_ref=$(ext_consumed_source_ref "$ext_name" "$ext_version" "$pg_major" "$registry" "$owner" probe) || _sv_rc=$?
                if [[ "$_sv_rc" -eq 2 ]]; then
                    log_error "generate_dockerfile: consumed-source resolution failure for $ext_name $ext_version pg${pg_major} — fail closed"
                    return 1
                fi
                if [[ "$_sv_rc" -ne 0 ]] || [[ -z "$_sv_ref" ]]; then
                    log_error "generate_dockerfile: ceiling ref for $ext_name $ext_version pg${pg_major} is absent — fail closed"
                    return 1
                fi
            else
                # Push/dispatch remains direct so scheduled builds do not acquire a probe.
                _sv_ref=$(ext_consumed_source_ref "$ext_name" "$ext_version" "$pg_major" "$registry" "$owner" direct) || return 1
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

    # Decide from the exact stage text about to be emitted, not from an
    # intention flag updated inside command substitutions. A candidate scoped
    # to this render must have replaced one emitted source reference.
    if [[ "$candidate_applies" == "true" ]] && ! grep -Fq -- "$candidate_ref" <<< "$stages_block"; then
        log_error "generate_dockerfile: rotation candidate '$ROTATION_CANDIDATE_REF' was not consumed for ${candidate_extension} pg${pg_major} — fail closed"
        return 1
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
    # Some focused generator tests use reduced templates that exercise only
    # extension stages and COPYs.  The real PostgreSQL Dockerfile owns the
    # built-in marker and must receive it; reduced templates predate initdb
    # blocks and deliberately do not model either initdb output.
    local -a template_args=(
        "FLAVOR_ARG" "$flavor_arg_block"
        "EXTENSION_STAGES" "$stages_block"
        "EXTENSION_COPIES" "$copies_block"
        "EXTENSION_INSTALLS" "$install_block"
    )
    # `--` because a template path beginning with a dash would otherwise be read
    # as options, and status 2 kept apart from 1 because "cannot read the
    # template" is not "the marker is absent" — reporting the first as the second
    # would send a reader looking for a marker that is there.
    local marker_status=0
    grep -qF -- '@@BUILTIN_INITDB@@' "$template" || marker_status=$?
    if (( marker_status > 1 )); then
        log_error "generate_dockerfile: cannot read template ${template} (grep status ${marker_status})"
        return 1
    fi
    if (( marker_status == 0 )); then
        template_args+=("BUILTIN_INITDB" "$builtin_initdb_block")
    elif [[ "$(grep -c "CREATE EXTENSION IF NOT EXISTS" <<<"$builtin_initdb_block")" -gt 0 ]]; then
        # Declared built-ins with nowhere to go. Until #1094 they sat in the
        # template literally and could not be dropped; once generated, a template
        # that lost the marker would build an image silently missing every one of
        # them.
        #
        # Counting the statements the block emitted, not its size: it carries its
        # `RUN` scaffolding whatever the list holds — 167 bytes for an empty
        # one — so a non-empty test would refuse a template that legitimately
        # wants no built-ins. Reading the block rather than the config also keeps
        # this off the extension config, which has one sanctioned reader.
        log_error "generate_dockerfile: ${template} declares no @@BUILTIN_INITDB@@ marker while builtin_extensions are configured"
        return 1
    fi
    template_args+=(
        "FLAVOR_INITDB" "$flavor_initdb_block"
        "RUNTIME_DEPS" "$runtime_deps_block"
    )
    expand_template "$template" "${template_args[@]}"
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
            if ! grep -qFx "$changed_ext" <<< "$flavor_exts"; then
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
    remote_tag=$(ext_image_name "$ext_name" "$ext_version" "$pg_major") || return 1

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
