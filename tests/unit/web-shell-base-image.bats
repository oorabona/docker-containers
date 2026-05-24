#!/usr/bin/env bats
#
# web-shell base-image generation: guards against tag and pattern regressions
# after the Slice 3a migration (alpine/ubuntu/rocky → ${REMOTE_CR}/library/<distro>
# pattern). Debian is unchanged (ghcr.io/oorabona/debian fixed FROM).

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    GEN="$REPO_ROOT/web-shell/generate-dockerfile.sh"
    CONFIG="$REPO_ROOT/web-shell/config.yaml"
    # The generator reads the template path relative to CWD; pass it absolute so
    # the test is location-independent.
    TEMPLATE="$REPO_ROOT/web-shell/Dockerfile"
}

@test "web-shell: alpine/ubuntu/rocky FROM uses \${REMOTE_CR}/library/<distro>:\${TAG} pattern" {
    for distro in alpine ubuntu rocky; do
        local from_line
        from_line=$(bash "$GEN" "$TEMPLATE" "$distro" 2>/dev/null | grep -E '^FROM ' | head -1)
        case "$distro" in
            alpine) [[ "$from_line" == 'FROM ${REMOTE_CR}/library/alpine:${ALPINE_TAG}' ]]     || { echo "alpine FROM wrong: $from_line"; return 1; } ;;
            ubuntu) [[ "$from_line" == 'FROM ${REMOTE_CR}/library/ubuntu:${UBUNTU_TAG}' ]]     || { echo "ubuntu FROM wrong: $from_line"; return 1; } ;;
            rocky)  [[ "$from_line" == 'FROM ${REMOTE_CR}/library/rockylinux:${ROCKY_TAG}' ]]  || { echo "rocky FROM wrong: $from_line";  return 1; } ;;
        esac
    done
}

@test "web-shell: generated default tag equals base_image_cache[].source tags[0] (no hardcode, no drift)" {
    # Mutation trace: hardcode a tag literal in generate-dockerfile.sh that
    # differs from config → this test goes RED. Proves the tag is sourced from
    # config, the single source of truth shared with the cache-population job.
    # Uses .source (new schema) instead of .arg (old Two-ARG schema).
    for source in library/alpine library/ubuntu library/rockylinux; do
        local distro tag_arg cfg_tag gen_tag
        case "$source" in
            library/alpine)     distro=alpine; tag_arg=ALPINE_TAG ;;
            library/ubuntu)     distro=ubuntu; tag_arg=UBUNTU_TAG ;;
            library/rockylinux) distro=rocky;  tag_arg=ROCKY_TAG  ;;
        esac
        cfg_tag=$(YQ_SOURCE="$source" yq -r '.base_image_cache[] | select(.source == strenv(YQ_SOURCE)) | .tags[0]' "$CONFIG")
        gen_tag=$(bash "$GEN" "$TEMPLATE" "$distro" 2>/dev/null | grep -E "^ARG ${tag_arg}=" | head -1 | cut -d= -f2)
        [[ "$gen_tag" == "$cfg_tag" ]] || { echo "$distro: generated ${tag_arg}=$gen_tag != config tags[0]=$cfg_tag"; return 1; }
    done
}

@test "web-shell: ARG REMOTE_CR present in generator output for alpine/ubuntu/rocky (regression lock)" {
    # Regression lock: Slice 3a requires REMOTE_CR ARG in migrated distros so
    # CI can inject the GHCR mirror URL at build time. If the generator stops
    # emitting it, the FROM line becomes unresolvable in CI.
    for distro in alpine ubuntu rocky; do
        local has_remote_cr
        has_remote_cr=$(bash "$GEN" "$TEMPLATE" "$distro" 2>/dev/null | grep -cE '^ARG REMOTE_CR' || true)
        [[ "$has_remote_cr" -ge 1 ]] || { echo "$distro: ARG REMOTE_CR missing from generated Dockerfile"; return 1; }
    done
}

@test "web-shell: rocky ROCKY_TAG is non-empty and not 'latest' (cache-miss guard)" {
    # Guards against the rocky cache-miss regression: a tag-less or :latest FROM
    # would bypass the GHCR cache and hit docker.io rate limits.
    local cfg_tag gen_tag
    cfg_tag=$(YQ_SOURCE=library/rockylinux yq -r '.base_image_cache[] | select(.source == strenv(YQ_SOURCE)) | .tags[0]' "$CONFIG")
    gen_tag=$(bash "$GEN" "$TEMPLATE" rocky 2>/dev/null | grep -E '^ARG ROCKY_TAG=' | head -1 | cut -d= -f2)
    [[ "$gen_tag" == "$cfg_tag" ]] || { echo "ROCKY_TAG=$gen_tag != cached $cfg_tag"; return 1; }
    [[ -n "$gen_tag" && "$gen_tag" != "latest" ]] || { echo "ROCKY_TAG resolved to empty/latest — cache miss risk"; return 1; }
}

@test "web-shell: debian FROM unchanged — uses ghcr.io/oorabona/debian:\${DEBIAN_TAG}" {
    local from_line
    from_line=$(bash "$GEN" "$TEMPLATE" debian 2>/dev/null | grep -E '^FROM ' | head -1)
    [[ "$from_line" == 'FROM ghcr.io/oorabona/debian:${DEBIAN_TAG}' ]] || { echo "debian FROM wrong: $from_line"; return 1; }
}
