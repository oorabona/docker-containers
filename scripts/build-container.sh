#!/usr/bin/env bash

# Container build utility - focused on building containers only
# Part of make script decomposition for better Single Responsibility
# Supports multi-variant containers via variants.yaml

# Source shared logging utilities
# Use BASH_SOURCE[0] instead of $0 to work correctly when sourced
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PROJECT_ROOT/helpers/logging.sh"
source "$PROJECT_ROOT/helpers/variant-utils.sh"
source "$PROJECT_ROOT/helpers/build-cache-utils.sh"
source "$PROJECT_ROOT/helpers/build-args-utils.sh"
source "$PROJECT_ROOT/helpers/template-utils.sh"
source "$PROJECT_ROOT/helpers/extension-utils.sh"
# shellcheck source=../helpers/extension-duration-utils.sh
[[ -f "$PROJECT_ROOT/helpers/extension-duration-utils.sh" ]] && source "$PROJECT_ROOT/helpers/extension-duration-utils.sh"

# ---------------------------------------------------------------------------
# _escape_gha_command <value>
#
# Escape a value for safe inclusion in a `::keyword::value` GitHub Actions
# workflow command.  Without this, a %0A/%0D in the value could terminate
# the command early and inject another workflow command.  Mapping per GitHub's
# runner spec:  %→%25  \n→%0A  \r→%0D
#
# Pattern sourced from helpers/base-cache-utils.sh::_escape_gha_command;
# inlined here to avoid importing the full base-cache helper.
# ---------------------------------------------------------------------------
_escape_gha_command() {
    local s="$1"
    s="${s//\%/%25}"
    s="${s//$'\n'/%0A}"
    s="${s//$'\r'/%0D}"
    printf '%s' "$s"
}

# Function to check if multi-platform builds are supported (QEMU emulation)
check_multiplatform_support() {
    # Cache the result to avoid repeated checks
    if [[ -n "${MULTIPLATFORM_SUPPORTED:-}" ]]; then
        [[ "$MULTIPLATFORM_SUPPORTED" = "true" ]] && return 0 || return 1
    fi
    
    # Method 1: Check for QEMU ARM64 emulation via binfmt_misc
    if [[ -f "/proc/sys/fs/binfmt_misc/qemu-aarch64" ]] || 
       [[ -f "/proc/sys/fs/binfmt_misc/qemu-arm64" ]]; then
        MULTIPLATFORM_SUPPORTED="true"
        return 0
    fi
    
    # Method 2: Check docker buildx supported platforms  
    if command -v docker >/dev/null 2>&1; then
        local platforms
        if platforms=$(docker buildx inspect --bootstrap 2>/dev/null | grep -i "platforms:" 2>/dev/null); then
            if echo "$platforms" | grep -q "linux/arm64"; then
                MULTIPLATFORM_SUPPORTED="true"
                return 0
            fi
        fi
    fi
    
    # No multi-platform support found
    MULTIPLATFORM_SUPPORTED="false"
    return 1
}

# Resolve build platforms based on environment and capabilities
# Sets: _PLATFORMS
# When running on Windows (RUNNER_OS=Windows or MINGW/MSYS uname), clears _PLATFORMS
# so the caller switches to plain `docker build` without --platform.
_resolve_platforms() {
    # Windows detection: GitHub Actions sets RUNNER_OS=Windows; Git Bash exposes MINGW/MSYS via uname
    if [[ "${RUNNER_OS:-}" == "Windows" ]] || [[ "$(uname -s 2>/dev/null)" =~ MINGW|MSYS ]]; then
        _PLATFORMS=""
        log_info "Windows runner detected — skipping --platform flag"
        return
    fi

    if [[ -n "${BUILD_PLATFORM:-}" ]]; then
        _PLATFORMS="$BUILD_PLATFORM"
        log_success "Using native platform: $_PLATFORMS"
    elif check_multiplatform_support; then
        _PLATFORMS="linux/amd64,linux/arm64"
    else
        _PLATFORMS="linux/amd64"
    fi
}

# Configure build cache based on runtime environment
# Sets: _CACHE_ARGS, _RUNTIME_INFO
_configure_cache() {
    local cache_image="$1"

    _CACHE_ARGS=""
    _RUNTIME_INFO=""

    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        _CACHE_ARGS="--cache-from type=registry,ref=$cache_image --cache-to type=registry,ref=$cache_image,mode=max"
        _RUNTIME_INFO="GitHub Actions (registry cache)"
        log_success "Using registry cache: $cache_image"
    elif docker version 2>/dev/null | grep -q "Docker Engine"; then
        if docker pull "$cache_image" 2>/dev/null; then
            _CACHE_ARGS="--cache-from type=registry,ref=$cache_image"
            _RUNTIME_INFO="Docker Engine (registry cache)"
        else
            _RUNTIME_INFO="Docker Engine (no cache - login to GHCR for cache)"
        fi
    elif command -v podman >/dev/null 2>&1; then
        _RUNTIME_INFO="Podman"
        log_success "Using Podman with built-in layer caching"
    else
        _RUNTIME_INFO="Unknown (no cache)"
        log_warning "No cache support detected"
    fi
}

# _prepare_build_args: thin wrapper; also populates _BUILD_ARGS_RESOLVED global.
# _BUILD_ARGS_RESOLVED maps ARG_NAME → value for every --build-arg in _BUILD_ARGS.
# _resolve_base_image reads this global as its Fix-A1 substitution source (Step 2.5).
_prepare_build_args() {
    # Reset the resolved map unconditionally so a failed call never contaminates
    # the next call with stale values from the previous successful invocation.
    declare -gA _BUILD_ARGS_RESOLVED=()
    prepare_build_args "$1" "$2" || return $?
    # Populate _BUILD_ARGS_RESOLVED from the assembled _BUILD_ARGS string.
    # Each --build-arg NAME=VALUE token is extracted; the map is consumed by
    # _resolve_base_image to substitute ARGs whose values come from config.yaml
    # build_args or version params (not visible via Dockerfile ARG defaults).
    local _ba_token
    while IFS= read -r _ba_token; do
        local _ba_name="${_ba_token%%=*}"
        local _ba_value="${_ba_token#*=}"
        [[ -n "$_ba_name" && "$_ba_name" != "$_ba_token" ]] && _BUILD_ARGS_RESOLVED["$_ba_name"]="$_ba_value"
    done < <(echo "${_BUILD_ARGS:-}" | grep -oE -- '--build-arg [^ ]+' | sed 's/--build-arg //' || true)
}

# Resolve base image reference from config.yaml or Dockerfile, substitute variables
# Sets: _BASE_IMAGE_REF, _BASE_DIGEST, adds to label_args
# Args: <dockerfile> <version> <label_args_var> [<from_generated>]
#   from_generated: 1 = use the concrete FROM line in the generated Dockerfile as the
#     authoritative base-image source (Fix A2); 0 = use config.yaml::base_image (default).
#     Pass this explicitly from every call site — callers that forget default to monolithic
#     semantics (0), which is safe but may miss the per-flavor fix for template containers.
_resolve_base_image() {
    local dockerfile="$1"
    local version="$2"
    local label_args_var="$3"  # name of the label_args variable to append to
    local from_generated="${4:-0}"  # Fix A2 positional param (replaces _RESOLVE_FROM_GENERATED env)

    # Fix A2: when called with a generated Dockerfile (post-template-generation),
    # the concrete FROM line is the authoritative source.  In that case, skip
    # config.yaml::base_image — it contains the default-distro template value and
    # would override the per-flavor FROM already baked into the generated file.
    local _use_from_only="$from_generated"

    # Fix A1: _BUILD_ARGS_RESOLVED is populated by _prepare_build_args (wrapper).
    # When _resolve_base_image is called directly in tests (without the wrapper),
    # declare the array as empty so ${#_BUILD_ARGS_RESOLVED[@]} doesn't trigger
    # "unbound variable" under set -u.
    if ! declare -p _BUILD_ARGS_RESOLVED &>/dev/null; then
        declare -gA _BUILD_ARGS_RESOLVED=()
    fi

    _BASE_IMAGE_REF=""
    if [[ "$_use_from_only" != "1" && -f "./config.yaml" ]]; then
        _BASE_IMAGE_REF=$(yq -r '.base_image // ""' ./config.yaml 2>/dev/null || true)
    fi
    # Always pre-compute the FROM line; used as fallback and as the authoritative
    # source when _use_from_only=1.
    local _dockerfile_from=""
    _dockerfile_from=$(grep -E '^FROM ' "$dockerfile" | grep -v ' AS ' | tail -1 | awk '{print $2}' 2>/dev/null || true)
    [[ -z "$_dockerfile_from" ]] && _dockerfile_from=$(grep -E '^FROM ' "$dockerfile" | tail -1 | awk '{print $2}' 2>/dev/null || true)
    if [[ -z "$_BASE_IMAGE_REF" ]]; then
        _BASE_IMAGE_REF="$_dockerfile_from"
    fi

    # Substitute known variables into the base image template.
    #
    # Ordering rationale: CUSTOM_BUILD_ARGS overrides must be parsed and applied
    # BEFORE the standard VERSION/UPSTREAM_VERSION substitutions so that a build
    # script's explicit --build-arg UPSTREAM_VERSION=<retained> wins over the
    # helper-resolved _UPSTREAM_VERSION (which always reflects the latest upstream).
    # Without this order, retained-version builds (e.g. terraform) would record the
    # wrong base_image_ref in the lineage file because _UPSTREAM_VERSION (latest)
    # would be substituted first, and the CUSTOM_BUILD_ARGS override would arrive
    # too late to correct an already-expanded placeholder.
    # Order: (1) parse CUSTOM_BUILD_ARGS, (2) apply overrides, (2.5) build_args
    # resolved set from _prepare_build_args [Fix A1], (3) standard substitutions
    # (no-ops for placeholders already consumed in steps 1-2.5), (4) Dockerfile
    # ARG defaults.
    if [[ "$_BASE_IMAGE_REF" =~ \$ ]]; then
        # Step 1 + 2: Parse CUSTOM_BUILD_ARGS and apply overrides first so they win
        # over all subsequent substitutions. Docker semantics: last --build-arg wins.
        declare -A _custom_arg_overrides=()
        if [[ -n "${CUSTOM_BUILD_ARGS:-}" ]]; then
            while read -r arg_val; do
                local _ov_name="${arg_val%%=*}"
                local _ov_value="${arg_val#*=}"
                [[ -n "$_ov_name" ]] && _custom_arg_overrides["$_ov_name"]="$_ov_value"
            done < <(echo "$CUSTOM_BUILD_ARGS" | grep -oE '\-\-build-arg [^ ]+' | sed 's/--build-arg //' || true)
        fi

        # Apply CUSTOM_BUILD_ARGS overrides before standard substitutions.
        for _ov_name in "${!_custom_arg_overrides[@]}"; do
            local _ov_value="${_custom_arg_overrides[$_ov_name]}"
            _BASE_IMAGE_REF="${_BASE_IMAGE_REF//\$\{$_ov_name\}/$_ov_value}"
            _BASE_IMAGE_REF="${_BASE_IMAGE_REF//\$$_ov_name/$_ov_value}"
        done

        # Step 2.5 [Fix A1]: Apply build_args resolved set from _prepare_build_args.
        # This covers ARGs whose values come from config.yaml build_args or version
        # params — invisible to both CUSTOM_BUILD_ARGS and Dockerfile ARG defaults.
        # Iterates up to 10 times to resolve cross-arg chains (A→B→C).  On cap-hit,
        # remaining placeholders survive to sanitize-at-read in the dashboard.
        if [[ ${#_BUILD_ARGS_RESOLVED[@]} -gt 0 ]]; then
            local _pass=0
            while [[ "$_BASE_IMAGE_REF" =~ \$ && $_pass -lt 10 ]]; do
                local _prev="$_BASE_IMAGE_REF"
                for _ba_name in "${!_BUILD_ARGS_RESOLVED[@]}"; do
                    # Skip args already handled by CUSTOM_BUILD_ARGS
                    [[ -v _custom_arg_overrides["$_ba_name"] ]] && continue
                    local _ba_val="${_BUILD_ARGS_RESOLVED[$_ba_name]}"
                    _BASE_IMAGE_REF="${_BASE_IMAGE_REF//\$\{$_ba_name\}/$_ba_val}"
                    _BASE_IMAGE_REF="${_BASE_IMAGE_REF//\$$_ba_name/$_ba_val}"
                done
                # Converged: no more substitutions possible
                [[ "$_BASE_IMAGE_REF" == "$_prev" ]] && break
                (( _pass++ )) || true
            done
            if [[ "$_BASE_IMAGE_REF" =~ \$ && $_pass -ge 10 ]]; then
                log_warning "base_image_ref cross-arg expansion capped at 10 passes: $_BASE_IMAGE_REF"
                # On cap-hit, _BASE_IMAGE_REF is cleared to empty string.
                # Sanitize-at-read in the dashboard displays "unknown" downstream.
                _BASE_IMAGE_REF=""
            fi
        fi

        # Step 3: Standard substitutions. These are no-ops for any placeholder
        # already consumed by a CUSTOM_BUILD_ARGS override above.
        _BASE_IMAGE_REF="${_BASE_IMAGE_REF//\$\{VERSION\}/$version}"
        _BASE_IMAGE_REF="${_BASE_IMAGE_REF//\$VERSION/$version}"
        [[ -n "${_MAJOR_VERSION:-}" ]] && _BASE_IMAGE_REF="${_BASE_IMAGE_REF//\$\{MAJOR_VERSION\}/$_MAJOR_VERSION}"
        [[ -n "${_UPSTREAM_VERSION:-}" ]] && _BASE_IMAGE_REF="${_BASE_IMAGE_REF//\$\{UPSTREAM_VERSION\}/$_UPSTREAM_VERSION}"

        # Step 4: Resolve Dockerfile ARG defaults (e.g. ARG REMOTE_CR=docker.io) for any
        # variables not already substituted by a CUSTOM_BUILD_ARGS override above.
        while IFS= read -r arg_line; do
            local arg_name="${arg_line%%=*}"
            local arg_default="${arg_line#*=}"
            arg_default="${arg_default%\"}"
            arg_default="${arg_default#\"}"
            arg_default="${arg_default%\'}"
            arg_default="${arg_default#\'}"
            [[ -z "$arg_name" || "$arg_name" == "$arg_line" ]] && continue
            # Skip if this arg was already applied via CUSTOM_BUILD_ARGS override
            [[ -v _custom_arg_overrides["$arg_name"] ]] && continue
            if [[ "$_BASE_IMAGE_REF" == *"\${$arg_name}"* || "$_BASE_IMAGE_REF" == *"\$$arg_name"* ]]; then
                _BASE_IMAGE_REF="${_BASE_IMAGE_REF//\$\{$arg_name\}/$arg_default}"
                _BASE_IMAGE_REF="${_BASE_IMAGE_REF//\$$arg_name/$arg_default}"
            fi
        done < <(grep -E '^ARG [A-Za-z_][A-Za-z0-9_]*=' "$dockerfile" | sed 's/^ARG //' || true)

        unset _custom_arg_overrides

        # Post-substitution fallback: if config.yaml base_image had a template
        # expression that still contains ${ after all passes, fall back to the concrete
        # FROM line in the Dockerfile — but ONLY when the 4th positional parameter
        # from_generated=1 (the caller has already expanded the template, so the
        # generated Dockerfile's FROM is the authoritative per-flavor base image).
        #
        # For monolithic containers (no template generation), config.yaml::base_image is
        # the source of truth. If its placeholders remain unresolved, that is a build-time
        # configuration error — substituting an unrelated concrete FROM line (e.g. a
        # multi-stage final-stage "FROM scratch") would write false lineage silently.
        # Instead, leave the unresolved literal so sanitize-at-read displays "unknown".
        if [[ "$_BASE_IMAGE_REF" =~ \$\{ && "$_use_from_only" == "1" && -n "$_dockerfile_from" && ! "$_dockerfile_from" =~ \$\{ ]]; then
            _BASE_IMAGE_REF="$_dockerfile_from"
        fi

        # Emit warning when a placeholder survives all substitution passes
        if [[ "$_BASE_IMAGE_REF" =~ \$\{ ]]; then
            log_warning "base_image_ref left un-resolved: $_BASE_IMAGE_REF"
        fi
    fi

    # Resolve digest if we have a concrete image reference
    # Use `docker buildx imagetools inspect --format '{{json .Manifest}}'` to obtain
    # the IMAGE-INDEX (manifest-list) digest.  This is the same digest that
    # detect-base-digest-drift.sh probes, so writer and probe always agree on
    # multi-arch images.  The previous `docker manifest inspect | grep sha256 | head -1`
    # pattern was order-dependent and could return a per-arch child digest instead
    # of the index digest — causing a perpetual drift-PR loop.
    _BASE_DIGEST=""
    if [[ -n "$_BASE_IMAGE_REF" && ! "$_BASE_IMAGE_REF" =~ \$ ]]; then
        _BASE_DIGEST=$(docker buildx imagetools inspect --format '{{json .Manifest}}' "$_BASE_IMAGE_REF" 2>/dev/null | jq -r '.digest // empty' 2>/dev/null || true)
        if [[ -n "$_BASE_DIGEST" ]]; then
            # Fix r7-1: validate digest shape before embedding in label_args.
            # A malformed value (spaces, shell metacharacters, injected flags)
            # must never reach --label or --build-arg.
            if [[ "$_BASE_DIGEST" =~ ^sha256:[a-f0-9]{64}$ ]]; then
                # Fix D: printf -v replaces eval; no shell-metacharacter injection vector
                printf -v "$label_args_var" '%s --label org.opencontainers.image.base.digest=%s' "${!label_args_var}" "$_BASE_DIGEST"
                log_info "Base image $_BASE_IMAGE_REF pinned: ${_BASE_DIGEST:0:19}..."
            else
                # Fix r23: explicitly clear _BASE_DIGEST on shape-validation failure so
                # _emit_build_lineage writes "unresolved" (treated as legacy by the
                # detector) rather than a malformed value that poisons comparisons.
                # Fix r28: route through _escape_gha_command to prevent %0A/%0D in the
                # malformed value from injecting additional GHA workflow commands.
                printf '::warning::Malformed base digest '\''%s'\'' from manifest probe; discarding\n' "$(_escape_gha_command "$_BASE_DIGEST")" >&2
                _BASE_DIGEST=""
            fi
        fi
    fi
}

# Emit build lineage JSON for traceability
_emit_build_lineage() {
    local container="$1" version="$2" tag="$3" flavor="$4" dockerfile="$5"
    local platforms="$6" runtime_info="$7" dockerhub_image="$8" ghcr_image="$9"
    local extensions_build_seconds="${10:-null}"

    local lineage_dir="${PROJECT_ROOT:-.}/.build-lineage"
    mkdir -p "$lineage_dir"
    local lineage_file="$lineage_dir/${container}-${tag}.json"
    local build_ts
    build_ts=$(date -Iseconds)
    local image_id
    image_id=$(docker images --no-trunc -q "$dockerhub_image:$tag" 2>/dev/null | head -1 || true)

    # Use shared build-args-utils.sh function (already sourced at top)
    local build_args_data
    build_args_data=$(build_args_json ".")

    # Fix C: use jq -n --arg so values with '"' or backslash are safely escaped.
    # Fix E: include lineage_schema_version=2 for downstream schema detection.
    jq -n \
        --arg     container        "$container" \
        --arg     version          "$version" \
        --arg     tag              "$tag" \
        --arg     flavor           "${flavor:-}" \
        --arg     dockerfile       "$dockerfile" \
        --arg     platform         "$platforms" \
        --arg     runtime          "$runtime_info" \
        --arg     image_id         "${image_id:-unknown}" \
        --arg     build_digest     "${BUILD_DIGEST:-unknown}" \
        --arg     oci_subject_digest "${OCI_SUBJECT_DIGEST:-}" \
        --arg     base_image_ref   "${_BASE_IMAGE_REF:-unknown}" \
        --arg     base_image_digest "${_BASE_DIGEST:-unresolved}" \
        --arg     built_at         "$build_ts" \
        --argjson duration_seconds "${_BUILD_DURATION_SECONDS:-null}" \
        --argjson github_actions   "${GITHUB_ACTIONS:-false}" \
        --arg     dockerhub_image  "$dockerhub_image:$tag" \
        --arg     ghcr_image       "$ghcr_image:$tag" \
        --argjson build_args       "$build_args_data" \
        '{
          lineage_schema_version: 2,
          container:              $container,
          version:                $version,
          tag:                    $tag,
          flavor:                 $flavor,
          dockerfile:             $dockerfile,
          platform:               $platform,
          runtime:                $runtime,
          image_id:               $image_id,
          build_digest:           $build_digest,
          oci_subject_digest:     $oci_subject_digest,
          base_image_ref:         $base_image_ref,
          base_image_digest:      $base_image_digest,
          built_at:               $built_at,
          duration_seconds:       $duration_seconds,
          github_actions:         $github_actions,
          images: {
            dockerhub: $dockerhub_image,
            ghcr:      $ghcr_image
          },
          build_args: $build_args
        }' > "$lineage_file"

    # Conditionally merge extensions_build_seconds when the caller actually
    # measured it. The field's PRESENCE (not its value) is the signal that
    # downstream consumers (sbom-utils.sh::append_build_history, the dashboard
    # frontend) use to detect "container has extensions concept". Containers
    # without extensions/config.yaml pass the literal string "null" as the
    # 10th arg — for those we omit the field entirely so the signal stays
    # honest.
    if [[ "$extensions_build_seconds" != "null" ]]; then
        local _lineage_tmp="${lineage_file}.tmp"
        if jq --argjson ext "$extensions_build_seconds" \
            '. + {extensions_build_seconds: $ext}' "$lineage_file" > "$_lineage_tmp" 2>/dev/null; then
            mv "$_lineage_tmp" "$lineage_file"
        else
            rm -f "$_lineage_tmp"
            log_warning "Failed to merge extensions_build_seconds=$extensions_build_seconds into $lineage_file"
        fi
    fi
    log_info "Build lineage: $lineage_file"
}

# Build container function
# Usage: build_container <container> <version> <tag> [flavor] [dockerfile] [build_flavor] [is_default]
# flavor:       distro name from variants.yaml (e.g. ubuntu-2404) — used for tag logic
# build_flavor: the value passed as --build-arg FLAVOR (e.g. base, dev)
#               falls back to flavor when not provided (backward-compatible)
# is_default:   "true" if this variant is the default (gets bare :latest); defaults to "false"
#               Caller computes via variant_property <dir> <variant_name> "default"
# If dockerfile is provided, uses -f <dockerfile> instead of default Dockerfile
build_container() {
    local container="$1"
    local version="$2"
    local tag="$3"
    local flavor="${4:-}"
    local dockerfile="${5:-Dockerfile}"
    local build_flavor="${6:-$flavor}"
    local is_default="${7:-}"
    # Self-heal (best-effort legacy-parity fallback for direct/6-arg callers):
    # When is_default is omitted — e.g. `./make build github-runner <v> --flavor ubuntu-2404`
    # without --is-default — derive it from variant config keyed by FLAVOR, matching
    # the pre-refactor behaviour.
    #
    # Edge case — name != flavor: for containers where the variant NAME differs from its
    # flavor (e.g. github-runner: variant name "ubuntu-2404-base", flavor "ubuntu-2404"),
    # this lookup finds NO variant named "ubuntu-2404", returns empty, and is_default falls
    # back to "false" → the rolling tag becomes :latest-ubuntu-2404 instead of :latest.
    # This is intentional: a flavor→variant-name reverse lookup is ambiguous when multiple
    # variants share a flavor, so we preserve the pre-refactor behaviour rather than guess.
    #
    # Authoritative callers are unaffected: build_container_variants passes the variant
    # name explicitly, and the CI composite action resolves is_default via
    # `variant_property … <variant_name>` before calling `make --is-default`. Published
    # (CI) tags are always correct; only a direct local single-flavor build of a
    # name-differs-from-flavor container is affected by this limitation.
    # No-flavor callers are also unaffected (compute_cell_tags ignores is_default when
    # flavor is empty).
    if [[ -z "$is_default" && -n "$flavor" ]]; then
        is_default=$(variant_property "$PROJECT_ROOT/$container" "$flavor" "default" 2>/dev/null || echo "false")
    fi
    [[ -z "$is_default" ]] && is_default="false"

    local github_username="${GITHUB_REPOSITORY_OWNER:-oorabona}"
    local dockerhub_image="docker.io/$github_username/$container"
    local ghcr_image="ghcr.io/$github_username/$container"

    # Reset BUILD_DIGEST so each variant computes its own
    unset BUILD_DIGEST

    # Smart rebuild detection: skip if image exists with matching digest
    # SKIP_EXISTING_BUILDS is set by the build-container action based on rebuild_mode
    if [[ "${SKIP_EXISTING_BUILDS:-false}" == "true" ]]; then
        if should_skip_build "$ghcr_image:$tag" "$dockerfile" "$flavor" "false"; then
            log_success "⏭️  Skipping $container:$tag - image exists with matching digest"
            return 0
        fi
        log_info "Build digest: $BUILD_DIGEST"
    fi

    _resolve_platforms
    _configure_cache "ghcr.io/$github_username/$container:buildcache"
    _prepare_build_args "$version" "$build_flavor" || {
        log_error "build arg preparation failed (invalid build_args/cache config); aborting build"
        return 1
    }

    # Prepare tags — versioned tag always included, plus rolling latest tags.
    # compute_cell_tags (helpers/variant-utils.sh) is the single source of truth;
    # see that function for the full rule-set.
    local _cell_refs _ref
    mapfile -t _cell_refs < <(compute_cell_tags "$tag" "$flavor" "$is_default" "$dockerhub_image" "$ghcr_image")
    local tag_args=""
    for _ref in "${_cell_refs[@]}"; do
        tag_args="$tag_args -t $_ref"
    done
    tag_args="${tag_args# }"  # strip leading space

    local label_args=""

    # Generate Dockerfile from template if it contains @@MARKER@@ patterns.
    # Fix A2: _resolve_base_image is called AFTER this block so that template-driven
    # containers (web-shell, github-runner) have their per-flavor Dockerfile generated
    # before the base-image resolution reads the concrete FROM line.
    local _generated_dockerfile=""
    if has_template_markers "$dockerfile"; then
        _generated_dockerfile=$(mktemp "${TMPDIR:-/tmp}/Dockerfile.${container}.XXXXXX") || {
            log_error "Failed to create temp file for generated Dockerfile"
            return 1
        }

        # Dispatch to the appropriate generator based on container type
        local _gen_ok=false
        if [[ -f "$PROJECT_ROOT/$container/extensions/config.yaml" ]]; then
            # Postgres extension template
            local ext_config="$PROJECT_ROOT/$container/extensions/config.yaml"
            if generate_dockerfile "$ext_config" "$dockerfile" "${flavor:-base}" "$_MAJOR_VERSION" > "$_generated_dockerfile"; then
                _gen_ok=true
                log_info "Generated Dockerfile for flavor=${flavor:-base} pg=$_MAJOR_VERSION"
            else
                log_error "Failed to generate Dockerfile for flavor=${flavor:-base} pg=$_MAJOR_VERSION"
            fi
        elif [[ -x "$PROJECT_ROOT/$container/generate-dockerfile.sh" ]]; then
            # Container-specific generator script (convention)
            # Args: <template> <flavor> <version> [<build_flavor>]
            # build_flavor is passed when the variant declares it (e.g. github-runner distro+build_flavor split)
            if "$PROJECT_ROOT/$container/generate-dockerfile.sh" "$dockerfile" "${flavor:-}" "$version" "${build_flavor:-}" > "$_generated_dockerfile"; then
                _gen_ok=true
                log_info "Generated Dockerfile via $container/generate-dockerfile.sh"
            else
                log_error "Failed to generate Dockerfile via $container/generate-dockerfile.sh"
            fi
        else
            log_error "Dockerfile has template markers but no generator found for $container"
        fi

        if [[ "$_gen_ok" != "true" ]]; then
            rm -f "$_generated_dockerfile"
            return 1
        fi
        dockerfile="$_generated_dockerfile"
    fi

    # Fix A2: resolve base image AFTER template generation so the correct per-flavor
    # FROM line (from the generated Dockerfile) is visible.  For monolithic containers
    # _generated_dockerfile is empty and from_generated=0 so config.yaml::base_image
    # is still read — no behavior change for monolithic path.
    local _rbi_generated=0
    [[ -n "$_generated_dockerfile" ]] && _rbi_generated=1
    _resolve_base_image "$dockerfile" "$version" "label_args" "$_rbi_generated"

    # Pre-build context hook: download external artifacts needed by the Dockerfile
    # (e.g., github-runner downloads the runner agent tarball via gh CLI)
    if [[ -x "$PROJECT_ROOT/$container/prepare-build-context.sh" ]]; then
        local _ctx_arch="${BUILD_PLATFORM##*/}"  # linux/amd64 → amd64
        [[ -z "$_ctx_arch" ]] && _ctx_arch="amd64"
        local _ctx_os="linux"
        [[ -z "${_PLATFORMS:-}" ]] && _ctx_os="windows"
        log_info "Preparing build context via $container/prepare-build-context.sh ($version $_ctx_arch $_ctx_os)"
        "$PROJECT_ROOT/$container/prepare-build-context.sh" "$version" "$_ctx_arch" "$_ctx_os" || {
            log_error "prepare-build-context.sh failed for $container"
            return 1
        }
    fi

    # Compute build digest AFTER template expansion so the digest captures
    # all config.yaml data (packages, install commands) embedded in the generated Dockerfile
    if [[ -z "${BUILD_DIGEST:-}" ]]; then
        BUILD_DIGEST=$(compute_build_digest "$dockerfile" "$flavor")
    fi
    label_args+=" --label $BUILD_DIGEST_LABEL=$BUILD_DIGEST"

    # Capture build timing
    local _build_start=$SECONDS

    # --no-cache flag: activated by rebuild=force mode
    local _no_cache=""
    [[ "${DOCKER_NO_CACHE:-false}" == "true" ]] && _no_cache="--no-cache"

    # Execute docker build
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        log_success "GitHub Actions detected - building locally for validation..."
        log_success "Runtime: $_RUNTIME_INFO | Platform: ${_PLATFORMS:-native} | Dockerfile: $dockerfile"

        # Multi-stage target: if the Dockerfile has FROM...AS stages matching build_flavor
        local _target_arg=""
        if [[ -n "$build_flavor" ]] && grep -qE "^FROM .* AS ${build_flavor}\b" "$dockerfile" 2>/dev/null; then
            _target_arg="--target $build_flavor"
        fi

        if [[ -z "${_PLATFORMS:-}" ]]; then
            # Windows runner: plain docker build (no buildx, no --platform, no --load needed)
            $DOCKER build \
                -f "$dockerfile" \
                ${_target_arg} \
                ${_no_cache} \
                $_BUILD_ARGS \
                $label_args \
                $tag_args \
                . || {
                log_error "Build failed for $container:$tag"
                [[ -n "$_generated_dockerfile" ]] && rm -f "$_generated_dockerfile"
                return 1
            }
        else
            $DOCKER buildx build \
                -f "$dockerfile" \
                ${_target_arg} \
                --platform "$_PLATFORMS" \
                --load \
                ${_no_cache} \
                $_CACHE_ARGS \
                $_BUILD_ARGS \
                $label_args \
                $tag_args \
                . || {
                log_error "Build failed for $container:$tag"
                [[ -n "$_generated_dockerfile" ]] && rm -f "$_generated_dockerfile"
                return 1
            }
        fi

        log_success "✅ Build completed - image loaded locally (no push)"
    else
        log_success "Building $container:$tag locally (Dockerfile: $dockerfile)..."
        log_success "Runtime: $_RUNTIME_INFO | Platform: $_PLATFORMS"

        $DOCKER buildx build \
            -f "$dockerfile" \
            --platform "$_PLATFORMS" \
            --load \
            --pull=never \
            ${_no_cache} \
            $_CACHE_ARGS \
            $_BUILD_ARGS \
            $label_args \
            $tag_args \
            . || {
            log_error "Build failed for $container:$tag"
            [[ -n "$_generated_dockerfile" ]] && rm -f "$_generated_dockerfile"
            return 1
        }

        log_success "✅ Local build completed - layered image available in Docker daemon"
    fi

    _BUILD_DURATION_SECONDS=$(( SECONDS - _build_start ))

    # Sum extension build times for this flavor (only for containers with extensions/)
    local _ext_seconds="null"
    if [[ -d "$PROJECT_ROOT/$container/extensions" ]]; then
        _ext_seconds=$(sum_flavor_extension_durations "$container" "${flavor:-}" "$_MAJOR_VERSION" 2>/dev/null || echo "null")
        [[ -z "${_ext_seconds:-}" ]] && _ext_seconds="null"
    fi

    if [[ "${DRY_RUN:-false}" != "true" ]]; then
        _emit_build_lineage "$container" "$version" "$tag" "$flavor" "$dockerfile" \
            "$_PLATFORMS" "$_RUNTIME_INFO" "$dockerhub_image" "$ghcr_image" "$_ext_seconds"
    else
        log_info "[DRY-RUN] Would write lineage: .build-lineage/${container}-${tag}.json"
    fi

    # Cleanup generated Dockerfile
    # NOTE: Using if/fi instead of [[ ]] && to avoid non-zero exit code when variable is empty
    # (same fix as CUSTOM_BUILD_ARGS - last statement in function affects return value under set -e)
    if [[ -n "$_generated_dockerfile" ]]; then
        rm -f "$_generated_dockerfile"
    fi
}

# Build all variants for a container
# Usage: build_container_variants <container> <major_version> [specific_variant]
# If specific_variant is provided, only that variant is built
# Returns JSON array of built variants for CI consumption
#
# Flow:
#   1. major_version = "17" (passed directly, no extraction needed)
#   2. base_image = "<container>:17-alpine" (major_version + base_suffix)
#   3. output_tag = "17-full-alpine" (major_version + variant_suffix + base_suffix)
build_container_variants() {
    local container="$1"
    local major_version="$2"
    local specific_variant="${3:-}"
    local container_dir="$PROJECT_ROOT/$container"

    # Check if container has variants
    if ! has_variants "$container_dir"; then
        log_info "$container has no variants, building single image..."
        local rc=0
        build_container "$container" "$major_version" "$major_version" || rc=$?
        echo "[{\"name\":\"default\",\"tag\":\"$major_version\",\"flavor\":\"\",\"status\":\"built\"}]"
        return $rc
    fi

    # Get base suffix from variants.yaml (e.g., "-alpine")
    local base_sfx
    base_sfx=$(base_suffix "$container_dir")

    # Get version-level dockerfile fallback (if any)
    local version_df
    version_df=$(version_dockerfile "$container_dir" "$major_version")

    # Construct the base image version for FROM statement (e.g., "17-alpine")
    local base_image_version="${major_version}${base_sfx}"

    # Check if this version actually has variants (versions-only containers
    # have variants.yaml for version_retention but no .variants entries)
    local variant_list
    variant_list=$(list_variants "$container_dir" "$major_version")
    if [[ -z "$variant_list" ]]; then
        log_info "$container has no variants for version $major_version, building single image..."
        local dockerfile="${version_df:-Dockerfile}"
        local rc=0
        build_container "$container" "$base_image_version" "$base_image_version" "" "$dockerfile" || rc=$?
        echo "[{\"name\":\"default\",\"tag\":\"$base_image_version\",\"flavor\":\"\",\"status\":\"built\"}]"
        return $rc
    fi

    log_info "$container has variants, building multiple images..."
    log_info "Major version: $major_version | Base version: $base_image_version"

    local results="["
    local first=true
    local failed=false

    # Iterate through variants for this major version
    while IFS= read -r variant_name; do
        [[ -z "$variant_name" ]] && continue

        # Skip if specific variant requested and this isn't it
        if [[ -n "$specific_variant" && "$variant_name" != "$specific_variant" ]]; then
            continue
        fi

        local variant_tag
        variant_tag=$(variant_image_tag "$major_version" "$variant_name" "$container_dir")
        local flavor
        flavor=$(variant_property "$container_dir" "$variant_name" "flavor" "$major_version")
        local build_flavor
        build_flavor=$(variant_property "$container_dir" "$variant_name" "build_flavor" "$major_version")
        local description
        description=$(variant_property "$container_dir" "$variant_name" "description" "$major_version")
        # Compute is_default from the VARIANT NAME (not the flavor) so that containers
        # where variant name != flavor (e.g. github-runner: name=ubuntu-2404-base,
        # flavor=ubuntu-2404) resolve correctly.
        local is_default
        is_default=$(variant_property "$container_dir" "$variant_name" "default" "$major_version" 2>/dev/null || echo "false")
        [[ -z "$is_default" ]] && is_default="false"

        # Resolve dockerfile: variant-level > version-level > default
        local dockerfile
        dockerfile=$(variant_property "$container_dir" "$variant_name" "dockerfile" "$major_version")
        [[ -z "$dockerfile" ]] && dockerfile="${version_df:-Dockerfile}"

        log_info "Building variant: $variant_name (tag: $variant_tag, flavor: $flavor, build_flavor: ${build_flavor:-$flavor}, is_default: $is_default, dockerfile: $dockerfile)"

        # Build the variant - pass base_image_version (e.g., "17-alpine") and dockerfile
        # build_flavor (e.g. base/dev) is passed as --build-arg FLAVOR; flavor (distro) is kept for tag logic
        # is_default is passed so compute_cell_tags uses the correct variant-name-based value
        local status="built"
        if ! build_container "$container" "$base_image_version" "$variant_tag" "$flavor" "$dockerfile" "$build_flavor" "$is_default"; then
            log_error "Failed to build variant: $variant_name"
            status="failed"
            failed=true
        else
            log_success "Built variant: $variant_name -> $container:$variant_tag"
        fi

        # Add to results
        if [[ "$first" != "true" ]]; then
            results+=","
        fi
        first=false

        results+="{\"name\":\"$variant_name\",\"tag\":\"$variant_tag\",\"flavor\":\"$flavor\",\"description\":\"$description\",\"status\":\"$status\"}"
    done <<< "$variant_list"

    results+="]"
    echo "$results"

    if [[ "$failed" == "true" ]]; then
        return 1
    fi
    return 0
}

# Check if a container has variants (wrapper for external use)
container_has_variants() {
    local container="$1"
    has_variants "$PROJECT_ROOT/$container"
}

# Get variant tags for a container (wrapper for external use)
get_container_variant_tags() {
    local container="$1"
    local base_version="$2"
    list_variant_tags "$PROJECT_ROOT/$container" "$base_version"
}

# Export functions for use by make script
export -f check_multiplatform_support
export -f build_container
export -f build_container_variants
export -f container_has_variants
export -f get_container_variant_tags
