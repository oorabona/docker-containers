#!/usr/bin/env bats

# Unit tests for helpers/artifact-utils.sh and its wiring into the three
# consumers of `artifact_url` (monitor, matrix prepare_build_args, bake).
#
# Mutation guards:
#   dropping the ${RELEASE_VERSION} "v" strip would probe/download
#         openvpn-v2.7.8.tar.gz instead of openvpn-2.7.8.tar.gz.
#   probing with `curl -f` instead of checking the final status would accept a
#         terminal 3xx as "available".
#   deriving the version from a live `version.sh --upstream` instead of the
#         frozen tag would fetch a different version than the Docker tag
#         announces (the retained-version case).
#   making a configuration error return "pending" (1) would let a broken
#         declaration silently disable the gate.
#   ignoring the signature URL would let a tarball without its .asc pass.

load "../test_helper"

setup() {
    setup_temp_dir
    ORIG_DIR="$PWD"
    cd "$TEST_TEMP_DIR" || exit 1
    mkdir -p bin app
    cp "$ORIG_DIR/tests/fixtures/artifact-curl-stub.sh" bin/curl
    export CURL_LOG="$TEST_TEMP_DIR/curl.log"
    : > "$CURL_LOG"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    unset CURL_RULES
    source "$ORIG_DIR/helpers/logging.sh"
    source "$ORIG_DIR/helpers/artifact-utils.sh"
}

teardown() {
    cd "$ORIG_DIR" || true
    teardown_temp_dir
}

# config.yaml with a valid declaration (+ one ordinary build_args entry, which
# the build-args validator requires to be a non-empty map)
write_config() {
    cat > app/config.yaml <<'YAML'
artifact_url: "https://example.org/rel/${UPSTREAM_VERSION}/tool-${RELEASE_VERSION}.tar.gz"
artifact_signature_suffix: ".asc"
build_args:
  FOO: "bar"
YAML
}

# version.sh stub: --tag-suffix is "-alpine"; --upstream deliberately lies
# (v9.9.9) and every call is logged so tests can prove it is never consulted.
write_version_sh() {
    cat > app/version.sh <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$VERSION_SH_LOG"
case "$1" in
    --tag-suffix) echo "-alpine" ;;
    --upstream)   echo "v9.9.9" ;;
    *)            echo "v9.9.9-alpine" ;;
esac
SH
    chmod +x app/version.sh
    export VERSION_SH_LOG="$TEST_TEMP_DIR/version-sh.log"
    : > "$VERSION_SH_LOG"
}

# ─── resolution ──────────────────────────────────────────────────────────────

@test "resolve_artifact_url substitutes raw and v-stripped versions" {
    run resolve_artifact_url 'https://x.org/${UPSTREAM_VERSION}/t-${RELEASE_VERSION}.tgz' "v2.7.8"
    [ "$status" -eq 0 ]
    [ "$output" = "https://x.org/v2.7.8/t-2.7.8.tgz" ]
}

@test "resolve_artifact_url rejects an empty version" {
    run resolve_artifact_url 'https://x.org/${UPSTREAM_VERSION}' ""
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "resolve_artifact_url rejects non-https and argument-injecting values" {
    run resolve_artifact_url 'http://x.org/${UPSTREAM_VERSION}' "1.0"
    [ "$status" -ne 0 ]
    run resolve_artifact_url 'https://x.org/${UPSTREAM_VERSION}' "1.0 --build-arg X=y"
    [ "$status" -ne 0 ]
}

@test "resolve_artifact_url rejects an unknown placeholder instead of passing it through" {
    run resolve_artifact_url 'https://x.org/${FOO}/t-${RELEASE_VERSION}.tgz' "v1.0"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

# ─── deterministic version derivation ───────────────────────────────────────

@test "derive_upstream_version strips the tag suffix and never asks upstream" {
    write_version_sh
    run derive_upstream_version app "v1.2.3-alpine"
    [ "$status" -eq 0 ]
    [ "$output" = "v1.2.3" ]
    [ "$(grep -c -- '--upstream' "$VERSION_SH_LOG" || true)" -eq 0 ]
}

@test "derive_upstream_version keeps the tag when there is no usable suffix" {
    # No version.sh at all
    run derive_upstream_version app "1.2.3"
    [ "$output" = "1.2.3" ]
    # A version.sh without --tag-suffix prints a version, which is not a suffix
    printf '#!/usr/bin/env bash\necho "9.9.9-ubuntu"\n' > app/version.sh
    chmod +x app/version.sh
    run derive_upstream_version app "1.2.3-ubuntu"
    [ "$output" = "1.2.3-ubuntu" ]
}

# ─── configuration validation (fail-closed) ─────────────────────────────────

@test "artifact_validate_config accepts a valid declaration and an absent one" {
    write_config
    run artifact_validate_config app
    [ "$status" -eq 0 ]
    printf 'build_args:\n  FOO: "bar"\n' > app/config.yaml
    run artifact_validate_config app
    [ "$status" -eq 0 ]
}

@test "artifact_validate_config fails explicitly (2) on an unparsable config.yaml" {
    printf 'artifact_url: [unterminated\n  : :\n' > app/config.yaml
    run artifact_validate_config app
    [ "$status" -eq 2 ]
}

@test "artifact_validate_config rejects a non-string artifact_url" {
    printf 'artifact_url:\n  nested: "https://x.org/a"\n' > app/config.yaml
    run artifact_validate_config app
    [ "$status" -eq 2 ]
}

@test "artifact_validate_config rejects unknown placeholders and non-https templates" {
    printf 'artifact_url: "https://x.org/${FOO}/a.tgz"\n' > app/config.yaml
    run artifact_validate_config app
    [ "$status" -eq 2 ]
    printf 'artifact_url: "http://x.org/${UPSTREAM_VERSION}/a.tgz"\n' > app/config.yaml
    run artifact_validate_config app
    [ "$status" -eq 2 ]
    printf 'artifact_url: "https://x.org/$(id)/a.tgz"\n' > app/config.yaml
    run artifact_validate_config app
    [ "$status" -eq 2 ]
}

@test "artifact_validate_config forbids overriding the derived args through build_args" {
    write_config
    printf '  ARTIFACT_URL: "https://evil.example/x.tgz"\n' >> app/config.yaml
    run artifact_validate_config app
    [ "$status" -eq 2 ]
    write_config
    printf '  ARTIFACT_SIGNATURE_URL: "https://evil.example/x.asc"\n' >> app/config.yaml
    run artifact_validate_config app
    [ "$status" -eq 2 ]
}

@test "artifact_validate_config rejects a bad or orphan signature suffix" {
    write_config
    sed -i 's#^artifact_signature_suffix:.*#artifact_signature_suffix: "../x"#' app/config.yaml
    run artifact_validate_config app
    [ "$status" -eq 2 ]
    printf 'artifact_signature_suffix: ".asc"\nbuild_args:\n  FOO: "bar"\n' > app/config.yaml
    run artifact_validate_config app
    [ "$status" -eq 2 ]
}

# ─── availability: HTTP semantics ────────────────────────────────────────────

@test "artifact_ready is a no-op when the container declares no artifact_url" {
    printf 'build_args:\n  FOO: "bar"\n' > app/config.yaml
    run artifact_ready app "v1.0.0"
    [ "$status" -eq 0 ]
    [ ! -s "$CURL_LOG" ]
}

@test "artifact_ready succeeds on 200 for the artifact and its signature (HEAD only)" {
    write_config
    write_version_sh
    run artifact_ready app "v1.2.3-alpine"
    [ "$status" -eq 0 ]
    grep -qx 'HEAD https://example.org/rel/v1.2.3/tool-1.2.3.tar.gz' "$CURL_LOG"
    grep -qx 'HEAD https://example.org/rel/v1.2.3/tool-1.2.3.tar.gz.asc' "$CURL_LOG"
    [ "$(grep -c '^GET' "$CURL_LOG" || true)" -eq 0 ]
}

@test "artifact_ready is pending (1) on 404" {
    write_config
    write_version_sh
    CURL_RULES='tool-1.2.3.tar.gz 404 404' run artifact_ready app "v1.2.3-alpine"
    [ "$status" -eq 1 ]
}

@test "artifact_ready is pending (1) when only the signature is missing" {
    write_config
    write_version_sh
    CURL_RULES='.asc 404 404' run artifact_ready app "v1.2.3-alpine"
    [ "$status" -eq 1 ]
}

@test "artifact_ready treats a terminal 3xx as unavailable" {
    write_config
    write_version_sh
    CURL_RULES='tool-1.2.3.tar.gz 302 302' run artifact_ready app "v1.2.3-alpine"
    [ "$status" -eq 1 ]
}

@test "artifact_ready falls back to a ranged GET when HEAD is refused (405)" {
    write_config
    write_version_sh
    CURL_RULES='tool-1.2.3 405 206' run artifact_ready app "v1.2.3-alpine"
    [ "$status" -eq 0 ]
    grep -qx 'GET https://example.org/rel/v1.2.3/tool-1.2.3.tar.gz' "$CURL_LOG"
}

@test "artifact_ready stays pending when HEAD is refused and the GET is 404" {
    write_config
    write_version_sh
    CURL_RULES='tool-1.2.3.tar.gz 405 404' run artifact_ready app "v1.2.3-alpine"
    [ "$status" -eq 1 ]
}

@test "artifact_ready stays pending on 403 when the fallback is refused too" {
    write_config
    write_version_sh
    CURL_RULES='tool-1.2.3.tar.gz 403 403' run artifact_ready app "v1.2.3-alpine"
    [ "$status" -eq 1 ]
}

@test "artifact_ready is pending (1) on a timeout" {
    write_config
    write_version_sh
    CURL_RULES='tool-1.2.3.tar.gz timeout timeout' run artifact_ready app "v1.2.3-alpine"
    [ "$status" -eq 1 ]
}

@test "artifact_ready distinguishes a configuration error (2) from pending (1)" {
    write_config
    write_version_sh
    printf '  ARTIFACT_URL: "https://evil.example/x"\n' >> app/config.yaml
    run artifact_ready app "v1.2.3-alpine"
    [ "$status" -eq 2 ]
    [ ! -s "$CURL_LOG" ]
}

@test "artifact_ready probes the version of the frozen tag, not a live upstream query" {
    write_config
    write_version_sh
    run artifact_ready app "v1.2.3-alpine"
    [ "$status" -eq 0 ]
    [ "$(grep -c '9\.9\.9' "$CURL_LOG" || true)" -eq 0 ]
    [ "$(grep -c -- '--upstream' "$VERSION_SH_LOG" || true)" -eq 0 ]
}

# ─── matrix path: prepare_build_args ─────────────────────────────────────────

@test "prepare_build_args emits ARTIFACT_URL and ARTIFACT_SIGNATURE_URL from the tag" {
    source "$ORIG_DIR/helpers/build-args-utils.sh"
    write_config
    write_version_sh
    cd app
    prepare_build_args "v1.2.3-alpine"
    [[ "$_BUILD_ARGS" == *"--build-arg ARTIFACT_URL=https://example.org/rel/v1.2.3/tool-1.2.3.tar.gz"* ]]
    [[ "$_BUILD_ARGS" == *"--build-arg ARTIFACT_SIGNATURE_URL=https://example.org/rel/v1.2.3/tool-1.2.3.tar.gz.asc"* ]]
}

@test "prepare_build_args builds a retained tag from that tag's version, not the live latest" {
    source "$ORIG_DIR/helpers/build-args-utils.sh"
    write_config
    write_version_sh      # --upstream would answer v9.9.9
    cd app
    prepare_build_args "v1.2.2-alpine"
    [[ "$_BUILD_ARGS" == *"--build-arg UPSTREAM_VERSION=v1.2.2"* ]]
    [[ "$_BUILD_ARGS" == *"tool-1.2.2.tar.gz"* ]]
    [[ "$_BUILD_ARGS" != *9.9.9* ]]
}

@test "prepare_build_args emits no ARTIFACT_URL without a declaration" {
    source "$ORIG_DIR/helpers/build-args-utils.sh"
    printf 'build_args:\n  FOO: "bar"\n' > app/config.yaml
    cd app
    prepare_build_args "1.0.0"
    [[ "$_BUILD_ARGS" != *ARTIFACT_* ]]
}

@test "prepare_build_args aborts on an invalid declaration or an override" {
    source "$ORIG_DIR/helpers/build-args-utils.sh"
    write_config
    printf '  ARTIFACT_URL: "https://evil.example/x"\n' >> app/config.yaml
    cd app
    run prepare_build_args "v1.2.3-alpine"
    [ "$status" -ne 0 ]
    printf 'artifact_url: "https://x.org/${FOO}"\nbuild_args:\n  FOO: "bar"\n' > config.yaml
    run prepare_build_args "v1.2.3-alpine"
    [ "$status" -ne 0 ]
}

# ─── three-way parity: monitor, matrix, bake ─────────────────────────────────

# Real openvpn declaration, offline (version.sh --tag-suffix is offline).
@test "monitor, matrix and bake hand the same URLs to a retained and a latest tag" {
    source "$ORIG_DIR/helpers/build-args-utils.sh"
    local stripped="$TEST_TEMP_DIR/gen-functions.sh"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'PROJECT_ROOT=%q\n' "$ORIG_DIR"
        printf 'SCRIPT_DIR=%q\n' "$ORIG_DIR/scripts"
        grep -v '^main ' "$ORIG_DIR/scripts/generate-bake-hcl.sh" \
            | grep -v '^PROJECT_ROOT=' | grep -v '^SCRIPT_DIR=' \
            | grep -v '^cd "\${PROJECT_ROOT}"'
    } > "$stripped"
    export GITHUB_ACTIONS="" _DEPGRAPH_LINEAGE_DIR=/nonexistent
    # shellcheck source=/dev/null
    source "$stripped"
    # shellcheck source=../../helpers/bake-managed.sh
    source "$ORIG_DIR/helpers/bake-managed.sh"

    local tag expected
    for tag in v2.7.8-alpine v2.7.7-alpine; do
        local up="${tag%-alpine}"
        expected="https://github.com/OpenVPN/openvpn/releases/download/${up}/openvpn-${up#v}.tar.gz"

        # monitor
        run artifact_build_args "$ORIG_DIR/openvpn" "$tag"
        [ "$status" -eq 0 ]
        [[ "$output" == *"ARTIFACT_URL=${expected}"* ]]
        [[ "$output" == *"ARTIFACT_SIGNATURE_URL=${expected}.asc"* ]]

        # matrix
        ( cd "$ORIG_DIR/openvpn" && prepare_build_args "$tag" && printf '%s' "$_BUILD_ARGS" ) > "$TEST_TEMP_DIR/matrix.out"
        grep -qF -- "--build-arg ARTIFACT_URL=${expected}" "$TEST_TEMP_DIR/matrix.out"
        grep -qF -- "--build-arg ARTIFACT_SIGNATURE_URL=${expected}.asc" "$TEST_TEMP_DIR/matrix.out"
        grep -qF -- "--build-arg UPSTREAM_VERSION=${up}" "$TEST_TEMP_DIR/matrix.out"

        # bake
        local args
        args=$(_compute_cell_build_args openvpn "$tag" "" "" "{}" "$ORIG_DIR/openvpn/Dockerfile" 0)
        [ "$(jq -r '.ARTIFACT_URL' <<< "$args")" = "$expected" ]
        [ "$(jq -r '.ARTIFACT_SIGNATURE_URL' <<< "$args")" = "${expected}.asc" ]
        [ "$(jq -r '.UPSTREAM_VERSION' <<< "$args")" = "$up" ]
    done
}

# ─── fleet: every declaration is valid and actually consumed ─────────────────

@test "every container declaring artifact_url has a valid declaration its Dockerfile consumes" {
    local cfg dir df declared=0
    for cfg in "$ORIG_DIR"/*/config.yaml; do
        dir=$(dirname "$cfg")
        run artifact_validate_config "$dir"
        [ "$status" -eq 0 ]
        [ -n "$(yq -r '.artifact_url // ""' "$cfg")" ] || continue
        declared=$((declared + 1))

        df="$dir/Dockerfile"
        [ -f "$df" ] || df="$dir/Dockerfile.template"
        grep -Eq '^ARG[[:space:]]+ARTIFACT_URL([[:space:]]|$)' "$df"
        grep -q '\${ARTIFACT_URL' "$df"
        if [ -n "$(yq -r '.artifact_signature_suffix // ""' "$cfg")" ]; then
            # the Dockerfile must fetch the signature URL the monitor probes,
            # not a hardcoded suffix
            grep -Eq '^ARG[[:space:]]+ARTIFACT_SIGNATURE_URL([[:space:]]|$)' "$df"
            grep -q '\${ARTIFACT_SIGNATURE_URL' "$df"
            [ "$(grep -c '\${ARTIFACT_URL}\.' "$df" || true)" -eq 0 ]
        fi
    done
    [ "$declared" -ge 1 ]
}
