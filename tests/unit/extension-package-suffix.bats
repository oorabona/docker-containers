#!/usr/bin/env bats

# Contract tests for EXTENSION_PACKAGE_SUFFIX, the package-name axis used by
# rotation candidates. It is intentionally independent of PR_TAG_SUFFIX.

load "../test_helper"

_source_build_extensions() {
    pushd "$SCRIPTS_DIR" > /dev/null 2>&1
    # shellcheck disable=SC1091
    source "./build-extensions.sh"
    popd > /dev/null 2>&1
}

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
    setup_temp_dir
    [[ -n "${TEST_TEMP_DIR:-}" && -d "$TEST_TEMP_DIR" ]] || {
        echo "FAIL: setup_temp_dir did not create TEST_TEMP_DIR" >&2
        return 1
    }
    export TMPDIR="$TEST_TEMP_DIR"
    export EXTENSION_REGISTRY="ghcr.io"
    export GITHUB_REPOSITORY_OWNER="testowner"
    export FORCE=false LOCAL_ONLY=false NO_CACHE=false
    unset EXTENSION_PACKAGE_SUFFIX PR_TAG_SUFFIX ARCH_SUFFIX BUILD_PLATFORM
    _source_build_extensions
}

teardown() {
    teardown_temp_dir
    unset EXTENSION_REGISTRY GITHUB_REPOSITORY_OWNER EXTENSION_PACKAGE_SUFFIX
    unset PR_TAG_SUFFIX ARCH_SUFFIX BUILD_PLATFORM FORCE LOCAL_ONLY NO_CACHE
}

@test "unset package suffix preserves origin/master literal constructor refs" {
    local expected image cache
    expected="ghcr.io/testowner/ext-pgvector:pg18-0.8.2"

    image=$(ext_image_name "pgvector" "0.8.2" "18")
    [ "$image" = "$expected" ] || {
        echo "ASSERTION: unset package suffix must preserve ghcr.io/testowner/ext-pgvector:pg18-0.8.2"
        false
    }

    cache=$(ext_buildcache_repository "pgvector" "ghcr.io" "testowner")
    [ "$cache" = "ghcr.io/testowner/ext-pgvector-buildcache" ] || {
        echo "ASSERTION: unset package suffix must preserve ghcr.io/testowner/ext-pgvector-buildcache"
        false
    }
}

@test "staging package suffix applies to per-arch, multi-arch, and buildcache refs with tag suffix" {
    local docker_calls="$TEST_TEMP_DIR/docker-calls.log"
    export EXTENSION_PACKAGE_SUFFIX="-staging"
    export PR_TAG_SUFFIX="-rotation42"
    export BUILD_PLATFORM="linux/amd64"
    export ARCH_SUFFIX="amd64"
    export REPO_OWNER="testowner"
    export docker_calls

    docker() {
        printf 'DOCKER' >> "$docker_calls"
        printf ' %s' "$@" >> "$docker_calls"
        printf '\n' >> "$docker_calls"
        return 0
    }
    export -f docker

    run build_ext_image "pgvector" "0.8.2" "https://example.invalid/pgvector" "18" "/tmp/unused.Dockerfile" "/tmp"
    [ "$status" -eq 0 ]

    grep -Fxq \
        "DOCKER buildx build --platform linux/amd64 -f /tmp/unused.Dockerfile -t ghcr.io/testowner/ext-pgvector-staging:pg18-0.8.2-amd64-rotation42 --load --cache-from type=registry,ref=ghcr.io/testowner/ext-pgvector-staging-buildcache:pg18-amd64 --cache-from type=registry,ref=ghcr.io/testowner/ext-pgvector-staging-buildcache:pg18-amd64-rotation42 --cache-to type=registry,ref=ghcr.io/testowner/ext-pgvector-staging-buildcache:pg18-amd64-rotation42,mode=max,ignore-error=true --build-arg REMOTE_CR=ghcr.io/oorabona --build-arg MAJOR_VERSION=18 --build-arg EXT_VERSION=0.8.2 --build-arg EXT_REPO=https://example.invalid/pgvector /tmp" \
        "$docker_calls"
    grep -Fxq "DOCKER push ghcr.io/testowner/ext-pgvector-staging:pg18-0.8.2-amd64-rotation42" "$docker_calls"

    # FORCE retains the established preference for the run-scoped tag; the
    # package suffix composes with that resolution rather than replacing it.
    export FORCE=true
    _image_registry_probe_3state() { return 0; }
    export -f _image_registry_probe_3state

    run ext_ref_resolve "pgvector" "0.8.2" "18" ""
    [ "$status" -eq 0 ]
    [ "$output" = "ghcr.io/testowner/ext-pgvector-staging:pg18-0.8.2-rotation42" ] || {
        echo "ASSERTION: multi-arch ref must carry the staging package and its independent tag suffix"
        false
    }
}

@test "malformed package suffix is refused before any build step" {
    local suffix marker
    marker="$TEST_TEMP_DIR/build-ran"

    for suffix in '-/' '-:' '-@' '-has space' ''; do
        rm -f "$marker"
        run env EXTENSION_PACKAGE_SUFFIX="$suffix" BUILD_MARKER="$marker" \
            bash -c '
                source "'"$SCRIPTS_DIR"'/build-extensions.sh"
                validate_prerequisites() { return 0; }
                check_registry_auth() { return 0; }
                list_extensions_by_priority() { echo pgvector; }
                _should_build_extension() { return 0; }
                build_tag_push_extensions() { touch "$BUILD_MARKER"; return 0; }
                _emit_final_versionset_pass() { return 0; }
                main postgres --major-version 18
            '

        [ ! -e "$marker" ] || {
            echo "ASSERTION: malformed package suffix '$suffix' must stop before any build step"
            false
        }
        [ "$status" -ne 0 ] || {
            echo "ASSERTION: malformed package suffix '$suffix' must fail"
            false
        }
        [[ "$output" == *"EXTENSION_PACKAGE_SUFFIX must be unset or match"* ]] || {
            echo "ASSERTION: malformed package suffix '$suffix' must report the package-suffix boundary"
            false
        }
    done
}

@test "invalid package suffix stops main when its caller uses ||" {
    run env EXTENSION_PACKAGE_SUFFIX='' bash -c '
        source "'"$SCRIPTS_DIR"'/build-extensions.sh"
        validate_prerequisites() { echo PREREQUISITES_REACHED; }
        list_extensions_by_priority() { echo LIST_REACHED; }
        main postgres --list || true
    '

    [[ "$output" == *"EXTENSION_PACKAGE_SUFFIX must be unset or match"* ]] || {
        echo "FAIL: invalid suffix must report the package-suffix boundary"
        false
    }
    [[ "$output" != *"PREREQUISITES_REACHED"* ]] || {
        echo "FAIL: invalid suffix must not reach prerequisites when main is called through ||"
        false
    }
    [[ "$output" != *"LIST_REACHED"* ]] || {
        echo "FAIL: invalid suffix must not reach listing when main is called through ||"
        false
    }
}

@test "failed package reference construction returns from ext_ref_resolve without a probe" {
    local marker="$TEST_TEMP_DIR/probe-called"
    export EXTENSION_PACKAGE_SUFFIX=''
    export marker

    _image_registry_probe_3state() {
        touch "$marker"
        return 0
    }
    export -f _image_registry_probe_3state

    run ext_ref_resolve "pgvector" "0.8.2" "18" ""

    [ "$status" -eq 2 ] || {
        echo "FAIL: failed reference construction must return ext_ref_resolve's documented error status"
        false
    }
    [ ! -e "$marker" ] || {
        echo "FAIL: failed reference construction must not reach _image_registry_probe_3state"
        false
    }
    [[ "$output" == *"ERROR [ext_ref_resolve]: failed to construct reference"* ]] || {
        echo "FAIL: failed reference construction must name ext_ref_resolve"
        false
    }
}
