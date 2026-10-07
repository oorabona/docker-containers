#!/usr/bin/env bats

# Unit tests for helpers/artifact-utils.sh and its wiring into
# prepare_build_args (--build-arg ARTIFACT_URL).
#
# Mutation guards:
#   dropping the ${RELEASE_VERSION} "v" strip would probe/download
#         openvpn-v2.7.8.tar.gz instead of openvpn-2.7.8.tar.gz.
#   making artifact_ready ignore the signature suffix would let a tarball
#         without its .asc pass the gate and fail the build at the gpg step.
#   making an undeclared artifact_url fail the gate would block every
#         container that has not opted in.

load "../test_helper"

setup() {
    setup_temp_dir
    ORIG_DIR="$PWD"
    cd "$TEST_TEMP_DIR" || exit 1
    mkdir -p bin app
    # curl stub: succeeds unless the URL matches a line of $CURL_404_PATTERNS
    cat > bin/curl <<'STUB'
#!/usr/bin/env bash
url="${*: -1}"
printf '%s\n' "$url" >> "$CURL_LOG"
while IFS= read -r pat; do
    [[ -n "$pat" && "$url" == *"$pat"* ]] && exit 22
done <<< "${CURL_404_PATTERNS:-}"
exit 0
STUB
    chmod +x bin/curl
    export CURL_LOG="$TEST_TEMP_DIR/curl.log"
    : > "$CURL_LOG"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    source "$ORIG_DIR/helpers/logging.sh"
    source "$ORIG_DIR/helpers/artifact-utils.sh"
}

teardown() {
    cd "$ORIG_DIR" || true
    teardown_temp_dir
}

write_config() {
    cat > app/config.yaml <<'YAML'
artifact_url: "https://example.org/rel/${UPSTREAM_VERSION}/tool-${RELEASE_VERSION}.tar.gz"
artifact_signature_suffix: ".asc"
build_args:
  FOO: "bar"
YAML
}

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

@test "artifact_ready is a no-op when the container declares no artifact_url" {
    printf 'build_args: {}\n' > app/config.yaml
    run artifact_ready app "v1.0.0"
    [ "$status" -eq 0 ]
    [ ! -s "$CURL_LOG" ]
}

@test "artifact_ready succeeds when artifact and signature answer" {
    write_config
    run artifact_ready app "v1.2.3"
    [ "$status" -eq 0 ]
    grep -q 'https://example.org/rel/v1.2.3/tool-1.2.3.tar.gz$' "$CURL_LOG"
    grep -q 'tool-1.2.3.tar.gz.asc$' "$CURL_LOG"
}

@test "artifact_ready fails while the artifact is missing (404)" {
    write_config
    CURL_404_PATTERNS=$'tool-1.2.3.tar.gz' run artifact_ready app "v1.2.3"
    [ "$status" -ne 0 ]
}

@test "artifact_ready fails when only the signature is missing" {
    write_config
    CURL_404_PATTERNS=$'.asc' run artifact_ready app "v1.2.3"
    [ "$status" -ne 0 ]
}

@test "artifact_ready fails closed when the declaration cannot be resolved" {
    write_config
    run artifact_ready app ""
    [ "$status" -ne 0 ]
}

@test "prepare_build_args emits ARTIFACT_URL resolved from the upstream version" {
    source "$ORIG_DIR/helpers/build-args-utils.sh"
    write_config
    cat > app/version.sh <<'SH'
#!/usr/bin/env bash
[[ "$1" == "--upstream" ]] && echo "v1.2.3" && exit 0
echo "v1.2.3-alpine"
SH
    chmod +x app/version.sh
    cd app
    prepare_build_args "v1.2.3-alpine"
    [[ "$_BUILD_ARGS" == *"--build-arg ARTIFACT_URL=https://example.org/rel/v1.2.3/tool-1.2.3.tar.gz"* ]]
}

@test "prepare_build_args emits no ARTIFACT_URL without a declaration" {
    source "$ORIG_DIR/helpers/build-args-utils.sh"
    printf 'build_args:\n  FOO: "bar"\n' > app/config.yaml
    cd app
    prepare_build_args "1.0.0"
    [[ "$_BUILD_ARGS" != *ARTIFACT_URL* ]]
}

# Bake and matrix paths must hand the Dockerfile the same ARTIFACT_URL.
@test "bake _compute_cell_build_args emits the ARTIFACT_URL for the cell's upstream version" {
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

    cd "$ORIG_DIR"
    local args
    args=$(_compute_cell_build_args openvpn "v2.7.7-alpine" "" "" "{}" "$ORIG_DIR/openvpn/Dockerfile" 0)
    [ "$(jq -r '.ARTIFACT_URL' <<< "$args")" = \
      "https://github.com/OpenVPN/openvpn/releases/download/v2.7.7/openvpn-2.7.7.tar.gz" ]
}
