#!/usr/bin/env bats
# Deterministic bake/matrix build-arg parity harness.
#
# Mutation guards:
#   BMP1: reverting _compute_cell_build_args to live version.sh --upstream would
#         let retained cells build a newer source under an older matrix tag.
#   BMP2: dropping tag-suffix validation would mis-strip containers without a
#         real --tag-suffix branch.
#   BMP3: drifting hook-side strip logic would make matrix and bake builds use
#         different source versions.
#   BMP4: reintroducing openresty RESTY_VERSION would recreate the latent source
#         tarball 404 regression.
#   BMP5: adding a default to source-version ARG declarations would weaken the
#         required-arg contract.
#   BMP6: removing the _df_declares_arg gate from STEP 4 would emit UPSTREAM_VERSION
#         for jekyll/wordpress/php (no ARG UPSTREAM_VERSION) — unused build-arg
#         warnings and matrix divergence.

bats_require_minimum_version 1.5.0

load "../test_helper"

setup() {
    setup_temp_dir
    export ORIGINAL_PROJECT_ROOT="$PROJECT_ROOT"
    export ORIGINAL_PATH="$PATH"
    export GITHUB_ACTIONS=""
    export _DEPGRAPH_LINEAGE_DIR=/nonexistent

    _snapshot_config_files
    _source_bake_generator_functions
    # shellcheck source=../../helpers/bake-managed.sh
    source "$PROJECT_ROOT/helpers/bake-managed.sh"
}

teardown() {
    export PROJECT_ROOT="$ORIGINAL_PROJECT_ROOT"
    export PATH="$ORIGINAL_PATH"
    unset VERSION CUSTOM_BUILD_ARGS
    teardown_temp_dir
}

_source_bake_generator_functions() {
    local gen_stripped="$TEST_TEMP_DIR/generate-bake-hcl-functions.sh"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'PROJECT_ROOT=%q\n' "$PROJECT_ROOT"
        printf 'SCRIPT_DIR=%q\n' "$PROJECT_ROOT/scripts"
        grep -v '^main ' "$PROJECT_ROOT/scripts/generate-bake-hcl.sh" \
            | grep -v '^PROJECT_ROOT=' \
            | grep -v '^SCRIPT_DIR=' \
            | grep -v '^cd "\${PROJECT_ROOT}"'
    } > "$gen_stripped"

    # shellcheck source=/dev/null
    source "$gen_stripped"
}

_snapshot_config_files() {
    find "$PROJECT_ROOT" -mindepth 2 -maxdepth 2 -name config.yaml -print0 \
        | sort -z \
        | xargs -0 sha256sum > "$TEST_TEMP_DIR/config-files.sha256"
}

_assert_config_files_unchanged() {
    sha256sum -c "$TEST_TEMP_DIR/config-files.sha256" >/dev/null
}

_latest_tag() {
    local container="$1"
    local variants="$PROJECT_ROOT/$container/variants.yaml"
    [[ -f "$variants" ]] || {
        echo "missing variants.yaml for $container" >&2
        return 1
    }

    local tag
    tag=$(yq -r '.versions[0].tag // ""' "$variants")
    [[ -n "$tag" && "$tag" != "null" ]] || {
        echo "missing .versions[0].tag for $container" >&2
        return 1
    }
    printf '%s' "$tag"
}

_supports_tag_suffix() {
    local container="$1"
    grep -q -- '--tag-suffix' "$PROJECT_ROOT/$container/version.sh"
}

_raw_tag_suffix() {
    local container="$1"
    local tag="$2"
    local version_sh="$PROJECT_ROOT/$container/version.sh"
    [[ -x "$version_sh" ]] || {
        echo "missing executable version.sh for $container" >&2
        return 1
    }

    if _supports_tag_suffix "$container"; then
        (cd "$PROJECT_ROOT/$container" && ./version.sh --tag-suffix 2>/dev/null || true)
    else
        # Unsupported --tag-suffix scripts fall through to their live lookup path.
        # Keep the harness offline by modeling that fallback as a garbage suffix;
        # the generator's robustness guard must treat it as no suffix.
        printf '%s' "$tag"
    fi
}

_expected_upstream() {
    local container="$1"
    local tag="$2"
    local suffix
    suffix=$(_raw_tag_suffix "$container" "$tag")

    if [[ -n "$suffix" && ( "${suffix:0:1}" != "-" || "${tag%"$suffix"}" == "$tag" ) ]]; then
        suffix=""
    fi

    if [[ -n "$suffix" ]]; then
        printf '%s' "${tag%"$suffix"}"
    else
        printf '%s' "$tag"
    fi
}

_emits_upstream() {
    local tag="$1"
    local expected="$2"
    [[ -n "$expected" && "$expected" != "$tag" ]]
}

# Returns 0 if the container's Dockerfile (or template) declares ARG UPSTREAM_VERSION.
# For templated containers (github-runner, web-shell) the template file is used,
# mirroring what the generator reads at generation time.
_dockerfile_declares_upstream() {
    local container="$1"
    local df_path
    df_path=$(_dockerfile_path_for_compute "$container")
    [[ -n "$df_path" ]] || return 1
    grep -qE '^ARG[[:space:]]+UPSTREAM_VERSION([[:space:]=]|$)' "$df_path" 2>/dev/null
}

_dockerfile_path_for_compute() {
    local container="$1"
    local variants="$PROJECT_ROOT/$container/variants.yaml"
    local dockerfile
    dockerfile=$(yq -r '.versions[0].dockerfile // .versions[0].variants[0].dockerfile // "Dockerfile"' "$variants")
    [[ -n "$dockerfile" && "$dockerfile" != "null" ]] || dockerfile="Dockerfile"

    if [[ -f "$PROJECT_ROOT/$container/$dockerfile" ]]; then
        printf '%s' "$PROJECT_ROOT/$container/$dockerfile"
    elif [[ -f "$PROJECT_ROOT/$container/Dockerfile" ]]; then
        printf '%s' "$PROJECT_ROOT/$container/Dockerfile"
    else
        printf ''
    fi
}

_bake_args_for_container() {
    local container="$1"
    local tag="$2"
    local config_args
    config_args=$(_config_build_args "$container")

    local df_path
    df_path=$(_dockerfile_path_for_compute "$container")

    local compute_project_root="$PROJECT_ROOT"
    if ! _supports_tag_suffix "$container"; then
        compute_project_root="$TEST_TEMP_DIR/no-suffix-project-$container"
        mkdir -p "$compute_project_root/$container"
        cat > "$compute_project_root/$container/version.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$tag"
EOF
        chmod +x "$compute_project_root/$container/version.sh"
    fi

    local saved_project_root="$PROJECT_ROOT"
    local args_json
    PROJECT_ROOT="$compute_project_root"
    args_json=$(_compute_cell_build_args "$container" "$tag" "" "" "$config_args" "$df_path" 0)
    PROJECT_ROOT="$saved_project_root"

    printf '%s' "$args_json"
}

_hook_path_for_container() {
    local container="$1"
    local hook="$PROJECT_ROOT/$container/build"

    if [[ "$container" == "terraform" ]]; then
        local tmp_root="$TEST_TEMP_DIR/terraform-hook-root"
        mkdir -p "$tmp_root"
        cp -a "$PROJECT_ROOT/terraform" "$tmp_root/terraform"
        mkdir -p "$tmp_root/helpers"
        cat > "$tmp_root/helpers/git-tags" <<'EOF'
latest-git-tag() {
    printf 'v0.0.0\n'
}
EOF
        cat > "$tmp_root/helpers/python-tags" <<'EOF'
get_pypi_latest_version() {
    printf '0.0.0\n'
}
EOF
        hook="$tmp_root/terraform/build"
    fi

    printf '%s' "$hook"
}

_hook_upstream_arg() {
    local container="$1"
    local tag="$2"
    local hook
    hook=$(_hook_path_for_container "$container")

    local custom_args
    if ! custom_args=$(VERSION="$tag" CUSTOM_BUILD_ARGS="" bash -c \
        'set -euo pipefail; source "$0" >/dev/null; printf "%s\n" "${CUSTOM_BUILD_ARGS:-}"' \
        "$hook" 2>&1); then
        echo "build hook failed for $container:" >&2
        echo "$custom_args" >&2
        return 1
    fi

    local upstream
    upstream=$(printf '%s\n' "$custom_args" \
        | sed -n 's/.*--build-arg[[:space:]]\+UPSTREAM_VERSION=\([^[:space:]]*\).*/\1/p' \
        | tail -1)
    [[ -n "$upstream" ]] || {
        echo "build hook for $container did not emit --build-arg UPSTREAM_VERSION" >&2
        echo "CUSTOM_BUILD_ARGS=$custom_args" >&2
        return 1
    }
    printf '%s' "$upstream"
}

_assert_bake_parity() {
    local container="$1"
    local tag expected args upstream
    tag=$(_latest_tag "$container")
    expected=$(_expected_upstream "$container" "$tag")
    args=$(_bake_args_for_container "$container" "$tag")
    upstream=$(jq -r '.UPSTREAM_VERSION // empty' <<< "$args")

    # Bake emits UPSTREAM_VERSION only when: the tag-suffix strip yields a value
    # that differs from the tag AND the Dockerfile declares ARG UPSTREAM_VERSION.
    # Containers without the declaration (jekyll, wordpress, php) must omit it to
    # avoid unused build-arg warnings and to match the matrix path (BMP6).
    if _emits_upstream "$tag" "$expected" && _dockerfile_declares_upstream "$container"; then
        assert_equals "$expected" "$upstream" \
            "$container bake UPSTREAM_VERSION for $tag (guards against live --upstream drift)"
    else
        assert_equals "" "$upstream" \
            "$container bake omits UPSTREAM_VERSION when no valid matrix suffix or ARG not declared"
    fi
}

_assert_hook_parity_if_present() {
    local container="$1"
    local hook="$PROJECT_ROOT/$container/build"
    [[ -x "$hook" ]] || return 0

    local tag expected hook_upstream
    tag=$(_latest_tag "$container")
    expected=$(_expected_upstream "$container" "$tag")
    hook_upstream=$(_hook_upstream_arg "$container" "$tag")

    assert_equals "$expected" "$hook_upstream" \
        "$container hook UPSTREAM_VERSION for $tag matches matrix-derived bake expectation"
    _assert_config_files_unchanged
}

_assert_container_parity() {
    local container="$1"
    _assert_bake_parity "$container"
    _assert_hook_parity_if_present "$container"
}

bake_managed_fleet_list_is_expected_parity_surface() { # @test
    local managed
    managed=$(bake_managed_containers)
    assert_equals \
        "github-runner web-shell wordpress debian vector jekyll ansible sslh openvpn php openresty terraform" \
        "$managed" \
        "bake-managed containers"
}

github_runner_parity_no_real_suffix_omits_upstream_version() { # @test
    _assert_container_parity github-runner
}

web_shell_parity_empty_tag_suffix_omits_upstream_version() { # @test
    _assert_container_parity web-shell
}

wordpress_parity_alpine_strip_is_deterministic_and_network_free() { # @test
    _assert_container_parity wordpress
}

debian_parity_unsupported_tag_suffix_is_treated_as_no_suffix() { # @test
    _assert_container_parity debian
}

vector_parity_bake_and_hook_agree_on_alpine_source_version() { # @test
    _assert_container_parity vector
}

jekyll_parity_alpine_strip_is_deterministic_and_network_free() { # @test
    _assert_container_parity jekyll
}

ansible_parity_bake_strips_ubuntu_source_suffix() { # @test
    _assert_container_parity ansible
}

sslh_parity_bake_and_hook_preserve_v_prefix_while_stripping_alpine() { # @test
    _assert_container_parity sslh
}

openvpn_parity_bake_strips_alpine_source_suffix() { # @test
    _assert_container_parity openvpn
}

php_parity_bake_and_hook_agree_on_fpm_alpine_strip() { # @test
    _assert_container_parity php
}

openresty_parity_bake_and_hook_agree_on_alpine_strip() { # @test
    _assert_container_parity openresty
}

terraform_parity_hook_isolation_keeps_working_tree_config_yaml_pristine() { # @test
    _assert_container_parity terraform
}

openresty_regression_lock_bake_emits_raw_source_version_and_no_resty_version() { # @test
    local tag expected args upstream
    tag=$(_latest_tag openresty)
    expected="${tag%-alpine}"
    args=$(_bake_args_for_container openresty "$tag")
    upstream=$(jq -r '.UPSTREAM_VERSION // empty' <<< "$args")

    assert_equals "$expected" "$upstream" \
        "openresty bake source tarball version must be strip(tag, -alpine)"
    grep -q 'openresty-${UPSTREAM_VERSION}.tar.gz' "$PROJECT_ROOT/openresty/Dockerfile"
    ! grep -qE '\bRESTY_VERSION\b' "$PROJECT_ROOT/openresty/Dockerfile"
}

source_critical_dockerfiles_declare_upstream_version_without_defaults_and_required_guards() { # @test
    local container dockerfile arg_count
    for container in openresty vector sslh openvpn terraform ansible; do
        dockerfile="$PROJECT_ROOT/$container/Dockerfile"
        [[ -f "$dockerfile" ]] || {
            echo "missing Dockerfile for $container" >&2
            return 1
        }

        arg_count=$(grep -Ec '^[[:space:]]*ARG[[:space:]]+UPSTREAM_VERSION([[:space:]]*)$' "$dockerfile")
        [[ "$arg_count" -ge 1 ]] || {
            echo "$container must declare ARG UPSTREAM_VERSION with no default" >&2
            return 1
        }
        ! grep -qE '^[[:space:]]*ARG[[:space:]]+UPSTREAM_VERSION[[:space:]]*=' "$dockerfile" || {
            echo "$container declares ARG UPSTREAM_VERSION with a default" >&2
            return 1
        }
        grep -qE '\$\{[A-Za-z_][A-Za-z0-9_]*:\?[^}]*\}' "$dockerfile" || {
            echo "$container Dockerfile has no required-arg guard expression" >&2
            return 1
        }
    done
}
