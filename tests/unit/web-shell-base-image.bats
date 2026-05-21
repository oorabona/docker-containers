#!/usr/bin/env bats
#
# web-shell base-image generation: Two-ARG pattern with the tag sourced from
# base_image_cache[].tags[0]. Guards against the rocky cache-miss regression
# (tag-less FROM resolving to an implicit :latest that the GHCR cache lacks)
# and against re-hardcoding the tag literal in the generator.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    GEN="$REPO_ROOT/web-shell/generate-dockerfile.sh"
    CONFIG="$REPO_ROOT/web-shell/config.yaml"
    # The generator reads the template path relative to CWD; pass it absolute so
    # the test is location-independent.
    TEMPLATE="$REPO_ROOT/web-shell/Dockerfile"
}

@test "web-shell: alpine/ubuntu/rocky FROM uses Two-ARG \${BASE}:\${TAG} pattern" {
    for distro in alpine ubuntu rocky; do
        local from_line
        from_line=$(bash "$GEN" "$TEMPLATE" "$distro" 2>/dev/null | grep -E '^FROM ' | head -1)
        case "$distro" in
            alpine) [[ "$from_line" == 'FROM ${ALPINE_BASE}:${ALPINE_TAG}' ]] || { echo "alpine FROM wrong: $from_line"; return 1; } ;;
            ubuntu) [[ "$from_line" == 'FROM ${UBUNTU_BASE}:${UBUNTU_TAG}' ]] || { echo "ubuntu FROM wrong: $from_line"; return 1; } ;;
            rocky)  [[ "$from_line" == 'FROM ${ROCKY_BASE}:${ROCKY_TAG}' ]]   || { echo "rocky FROM wrong: $from_line";  return 1; } ;;
        esac
    done
}

@test "web-shell: generated default tag equals base_image_cache[].tags[0] (no hardcode, no drift)" {
    # Mutation trace: hardcode a tag literal in generate-dockerfile.sh that
    # differs from config → this test goes RED. Proves the tag is sourced from
    # config, the single source of truth shared with the cache-population job.
    for arg in ALPINE_BASE UBUNTU_BASE ROCKY_BASE; do
        local distro tag_arg cfg_tag gen_tag
        case "$arg" in
            ALPINE_BASE) distro=alpine; tag_arg=ALPINE_TAG ;;
            UBUNTU_BASE) distro=ubuntu; tag_arg=UBUNTU_TAG ;;
            ROCKY_BASE)  distro=rocky;  tag_arg=ROCKY_TAG ;;
        esac
        cfg_tag=$(YQ_ARG="$arg" yq -r '.base_image_cache[] | select(.arg == strenv(YQ_ARG)) | .tags[0]' "$CONFIG")
        gen_tag=$(bash "$GEN" "$TEMPLATE" "$distro" 2>/dev/null | grep -E "^ARG ${tag_arg}=" | head -1 | cut -d= -f2)
        [[ "$gen_tag" == "$cfg_tag" ]] || { echo "$distro: generated ${tag_arg}=$gen_tag != config tags[0]=$cfg_tag"; return 1; }
    done
}

@test "web-shell: CI tag-less cache override resolves to the cached tag" {
    # Simulate get_cache_build_args (tag-less ROCKY_BASE) + the generated
    # ROCKY_TAG default → the effective FROM must target rocky-base:<cached-tag>,
    # NOT an implicit :latest. This is the exact rocky cache-miss the fix closes.
    local rocky_tag
    rocky_tag=$(YQ_ARG=ROCKY_BASE yq -r '.base_image_cache[] | select(.arg == strenv(YQ_ARG)) | .tags[0]' "$CONFIG")
    # Default ROCKY_BASE in the generated Dockerfile is "rockylinux"; CI overrides
    # it to ghcr.io/owner/rocky-base (tag-less). With Two-ARG, the tag stays.
    local gen_tag
    gen_tag=$(bash "$GEN" "$TEMPLATE" rocky 2>/dev/null | grep -E '^ARG ROCKY_TAG=' | head -1 | cut -d= -f2)
    [[ "$gen_tag" == "$rocky_tag" ]] || { echo "ROCKY_TAG=$gen_tag != cached $rocky_tag"; return 1; }
    [[ -n "$gen_tag" && "$gen_tag" != "latest" ]] || { echo "ROCKY_TAG resolved to empty/latest — cache miss risk"; return 1; }
}
