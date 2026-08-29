#!/usr/bin/env bats

load "../test_helper"

setup() {
    setup_temp_dir
    RESOLVER="$PROJECT_ROOT/test-harness/image-identity.sh"
}

teardown() {
    teardown_temp_dir
}

@test "image-identity enables strict mode before using helpers" {
    run bash -c '
        source "$1"
        false
        printf "continued\\n"
    ' _ "$RESOLVER"

    [ "$status" -ne 0 ]
    [[ "$output" != *"continued"* ]]
}

resolve() {
    run bash -c 'source "$1"; image_identity_resolve "$2" "$3"' _ \
        "$RESOLVER" "$1" "$2"
}

make_container() {
    local name="$1" yaml="$2" suffix="$3"
    local dir="$TEST_TEMP_DIR/$name"
    mkdir -p "$dir"
    printf '%s\n' "$yaml" > "$dir/variants.yaml"
    printf '#!/usr/bin/env bash\nif [[ "${1:-}" == "--tag-suffix" ]]; then printf %%s %q; exit 0; fi\nexit 1\n' "$suffix" > "$dir/version.sh"
    chmod +x "$dir/version.sh"
    printf '%s\n' "$dir"
}

assert_reported_component_version() {
    local actual="$1" expected="$2"
    local record
    record=$(jq -cn --arg version "$expected" \
        '{reference: "image:tag", tag: "tag", component_version: $version, kind: "single", variant: null, flavor: null}')

    run bash -c '
        source "$1/test-harness/test-harness.sh"
        source "$1/test-harness/image-identity.sh"
        E2E_IMAGE_IDENTITY="$3"
        th_init --name "identity assertion" --report tap --no-color
        e2e_assert_reported_component_version "$2"
        th_summary
    ' _ "$PROJECT_ROOT" "$actual" "$record"
}

@test "accepts numeric-dotted component releases with omitted zero segments" {
    local actual expected
    for actual in 7.1 7.1.0; do
        if [[ "$actual" == "7.1" ]]; then
            expected=7.1.0
        else
            expected=7.1
        fi
        assert_reported_component_version "$actual" "$expected"
        [ "$status" -eq 0 ]
        [[ "$output" == *"ok 1 - the reported component version matches the resolved image release"* ]]
    done
}

@test "refuses different numeric-dotted component releases" {
    local expected
    for expected in 7.2.0 7.11.0; do
        assert_reported_component_version 7.1 "$expected"
        [ "$status" -ne 0 ]
        [[ "$output" == *"not ok 1 - the reported component version matches the resolved image release"* ]]
    done
}

@test "keeps suffix-bearing component versions byte-for-byte exact" {
    assert_reported_component_version 7.1.0-beta 7.1.0
    [ "$status" -ne 0 ]
    [[ "$output" == *"not ok 1 - the reported component version matches the resolved image release"* ]]
}

@test "fails closed for an unparseable component release" {
    assert_reported_component_version release-candidate 7.1.0
    [ "$status" -ne 0 ]
    [[ "$output" == *"not ok 1 - the reported component version matches the resolved image release"* ]]
}

@test "uses its private numeric comparator despite a caller stub" {
    local record
    record=$(jq -cn --arg version 7.2.0 \
        '{reference: "image:tag", tag: "tag", component_version: $version, kind: "single", variant: null, flavor: null}')

    run bash -c '
        source "$1/test-harness/test-harness.sh"
        version_is_greater() { return 1; }
        declare -F version_is_greater >/dev/null || exit 97
        source "$1/test-harness/image-identity.sh"
        declare -F version_is_greater >/dev/null || exit 98
        E2E_IMAGE_IDENTITY="$2"
        th_init --name "identity assertion" --report tap --no-color
        e2e_assert_reported_component_version 7.1
        if th_summary; then
            summary_status=0
        else
            summary_status=$?
        fi
        printf "caller-stub-defined\n"
        exit "$summary_status"
    ' _ "$PROJECT_ROOT" "$record"

    [ "$status" -ne 0 ]
    [[ "$output" == *"caller-stub-defined"* ]]
    [[ "$output" == *"not ok 1 - the reported component version matches the resolved image release"* ]]
}

@test "does not export version utility names when sourced" {
    run bash -c '
        for name in version_is_greater DEFAULT_VERSION_PATTERN _version_numeric_tuple _version_normalize_numeric_component get_registry_pattern get_current_published_version; do
            unset "$name"
            unset -f "$name"
        done
        source "$1"
        for name in version_is_greater DEFAULT_VERSION_PATTERN _version_numeric_tuple _version_normalize_numeric_component get_registry_pattern get_current_published_version; do
            if declare -F "$name" >/dev/null || declare -p "$name" >/dev/null 2>&1; then
                printf "%s is present\n" "$name"
                exit 1
            fi
        done
        printf "version utility names absent\n"
    ' _ "$RESOLVER"

    [ "$status" -eq 0 ]
    [ "$output" = "version utility names absent" ]
}

@test "preserves a caller's BASH_REMATCH through numeric comparison" {
    local record
    record=$(jq -cn --arg version 7.1.0 \
        '{reference: "image:tag", tag: "tag", component_version: $version, kind: "single", variant: null, flavor: null}')

    run bash -c '
        source "$1/test-harness/test-harness.sh"
        source "$1/test-harness/image-identity.sh"
        [[ alpha42 =~ ^([a-z]+)([0-9]+)$ ]]
        E2E_IMAGE_IDENTITY="$2"
        th_init --name "identity assertion" --report tap --no-color
        e2e_assert_reported_component_version 7.1
        th_summary
        printf "captures=%s,%s\n" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    ' _ "$PROJECT_ROOT" "$record"

    [ "$status" -eq 0 ]
    [[ "$output" == *"captures=alpha,42"* ]]
}

@test "leaves BASH_REMATCH unset when the caller had none" {
    local record
    record=$(jq -cn --arg version 7.1.0 \
        '{reference: "image:tag", tag: "tag", component_version: $version, kind: "single", variant: null, flavor: null}')

    run bash -c '
        source "$1/test-harness/test-harness.sh"
        source "$1/test-harness/image-identity.sh"
        unset BASH_REMATCH
        E2E_IMAGE_IDENTITY="$2"
        th_init --name "identity assertion" --report tap --no-color
        e2e_assert_reported_component_version 7.1
        declare -p BASH_REMATCH >/dev/null 2>&1 && exit 1
        th_summary
    ' _ "$PROJECT_ROOT" "$record"

    [ "$status" -eq 0 ]
}

@test "reports a missing version helper without aborting while sourced" {
    local fixture_root fixture_resolver record
    fixture_root="$TEST_TEMP_DIR/missing-helper"
    fixture_resolver="$fixture_root/test-harness/image-identity.sh"
    mkdir -p "$fixture_root/test-harness"
    cp "$RESOLVER" "$fixture_resolver"
    record=$(jq -cn --arg version 7.1.0 \
        '{reference: "image:tag", tag: "tag", component_version: $version, kind: "single", variant: null, flavor: null}')

    run bash -c '
        set -e
        source "$1/test-harness/test-harness.sh"
        source "$2"
        E2E_IMAGE_IDENTITY="$3"
        th_init --name "identity assertion" --report tap --no-color
        e2e_assert_reported_component_version 7.1
        th_summary
    ' _ "$PROJECT_ROOT" "$fixture_resolver" "$record"

    [ "$status" -ne 0 ]
    [[ "$output" == *"required helper version-utils.sh is unavailable"* ]]
    [[ "$output" != *"expected: '7.1.0', got: '7.1'"* ]]
}

@test "reports a version helper that supplies no comparator without aborting while sourced" {
    local fixture_root fixture_resolver record
    fixture_root="$TEST_TEMP_DIR/no-comparator-helper"
    fixture_resolver="$fixture_root/test-harness/image-identity.sh"
    mkdir -p "$fixture_root/test-harness" "$fixture_root/helpers"
    cp "$RESOLVER" "$fixture_resolver"
    : > "$fixture_root/helpers/version-utils.sh"
    record=$(jq -cn --arg version 7.1.0 \
        '{reference: "image:tag", tag: "tag", component_version: $version, kind: "single", variant: null, flavor: null}')

    run bash -c '
        set -e
        source "$1/test-harness/test-harness.sh"
        source "$2"
        E2E_IMAGE_IDENTITY="$3"
        th_init --name "identity assertion" --report tap --no-color
        e2e_assert_reported_component_version 7.1
        th_summary
    ' _ "$PROJECT_ROOT" "$fixture_resolver" "$record"

    [ "$status" -ne 0 ]
    [[ "$output" == *"required helper version-utils.sh is unavailable"* ]]
    [[ "$output" != *"expected: '7.1.0', got: '7.1'"* ]]
}

@test "resolves a port-bearing reference" {
    local dir
    dir=$(make_container web-shell '
versions:
  - tag: "1.7.7"
    variants:
      - name: debian
        suffix: ""
        flavor: debian
        default: true
      - name: ubuntu
        suffix: "-ubuntu"
        flavor: ubuntu
' '')

    resolve "$dir" "registry.example:5000/ns/web-shell:1.7.7-ubuntu"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.component_version + ":" + .variant + ":" + .flavor' <<<"$output")" = "1.7.7:ubuntu:ubuntu" ]
}

@test "uses a passed build cell without parsing its image reference" {
    local dir
    dir=$(make_container direct 'versions:
  - tag: v2.3.1-alpine' '-alpine')

    run env E2E_BUILD_TAG=v2.3.1-alpine E2E_BUILD_VERSION=v2.3.1-alpine \
        E2E_BUILD_VARIANT='' E2E_BUILD_FLAVOR='' bash -c \
        'source "$1"; image_identity_resolve "$2" "$3"' _ "$RESOLVER" "$dir" \
        'unrelated:ignored@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'

    [ "$status" -eq 0 ]
    [ "$(jq -r '.tag + ":" + .component_version + ":" + .kind' <<<"$output")" = "v2.3.1-alpine:2.3.1:single" ]
}

@test "constructs tags with build.base_suffix, independently from version.sh's marker" {
    local dir
    dir=$(make_container construction '
versions:
  - tag: 1.2.3
' '-alpine')

    # base_suffix is empty here, even though version.sh identifies -alpine as
    # the component marker.  The generator therefore builds :1.2.3, not
    # :1.2.3-alpine.
    resolve "$dir" "example/construction:1.2.3"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.component_version' <<<"$output")" = "1.2.3" ]
}

@test "rejects a digest-only reference" {
    local dir
    dir=$(make_container single 'versions:
  - tag: 1.2.3-alpine' '-alpine')

    resolve "$dir" "registry.example/ns/single@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    [ "$status" -ne 0 ]
    [[ "$output" == *"has a digest"* ]]
}

@test "resolves a versioned tag from a latest declaration" {
    local dir
    dir=$(make_container moving 'versions:
  - tag: latest' '-alpine')

    # The workflow replaces a latest declaration with this resolved version
    # before generating the matrix; reverse resolution must do the same.
    printf '#!/usr/bin/env bash\ncase "${1:-}" in\n  --tag-suffix) printf "%%s\\n" "-alpine" ;;\n  "") printf "%%s\\n" "1.2.3-alpine" ;;\n  *) exit 1 ;;\nesac\n' > "$dir/version.sh"
    chmod +x "$dir/version.sh"

    resolve "$dir" "example/moving:1.2.3-alpine"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.tag + ":" + .component_version' <<<"$output")" = "1.2.3-alpine:1.2.3" ]
}

@test "fails closed when variants.yaml is unreadable YAML" {
    local dir="$TEST_TEMP_DIR/broken"
    mkdir -p "$dir"
    printf 'versions: [not valid\n' > "$dir/variants.yaml"
    printf '#!/bin/bash\n[[ "${1:-}" == "--tag-suffix" ]] && exit 0\nexit 1\n' > "$dir/version.sh"
    chmod +x "$dir/version.sh"

    resolve "$dir" "example/broken:1.2.3"
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not resolve to one declared cell"* ]]
}

@test "normalises sslh's leading v while preserving a prerelease" {
    local dir
    dir=$(make_container sslh 'versions:
  - tag: v2.3.1-rc1-alpine' '-alpine')

    resolve "$dir" "ghcr.io/example/sslh:v2.3.1-rc1-alpine"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.component_version' <<<"$output")" = "2.3.1-rc1" ]
    [ "$(jq -r '.kind, .variant, .flavor' <<<"$output")" = $'single\nnull\nnull' ]
}

@test "resolves terraform's retained empty-suffix full variant as a variant cell" {
    local terraform_tag terraform_version
    terraform_tag=$(yq -r '[.versions[] | select(([.variants[] | select((.name == "full") and (.suffix == "") and (.flavor == "full"))] | length) > 0) | .tag] | .[0] // ""' \
        "$PROJECT_ROOT/terraform/variants.yaml") || {
        echo "terraform/variants.yaml could not be read to find a full variant with an empty suffix" >&2
        return 1
    }
    if [[ -z "$terraform_tag" || "$terraform_tag" == "null" || "$terraform_tag" != *-alpine ]]; then
        echo "terraform/variants.yaml does not declare an -alpine version with a full variant with an empty suffix" >&2
        return 1
    fi
    terraform_version="${terraform_tag%-alpine}"

    resolve "$PROJECT_ROOT/terraform" "ghcr.io/oorabona/terraform:$terraform_tag"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.component_version + ":" + .kind + ":" + .variant + ":" + .flavor' <<<"$output")" = "$terraform_version:variant:full:full" ]
}

@test "mirrors generator coercions for version, suffix, and empty flavor" {
    local dir
    dir=$(make_container generator-compatible '
versions:
  - tag: 1.2
    variants:
      - name: null-suffix
        suffix: null
        flavor: ""
' '')

    resolve "$dir" "generator-compatible:1.2"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.component_version + ":" + .kind + ":" + .variant + ":" + .flavor' <<<"$output")" = "1.2:variant:null-suffix:" ]

}

@test "rejects a neighbouring version instead of prefix matching" {
    local dir
    dir=$(make_container version-boundary 'versions:
  - tag: 12.2.40-alpine' '-alpine')

    resolve "$dir" "example/version-boundary:2.2.4-alpine"
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not name a declared cell"* ]]
}

@test "resolves web-shell ubuntu but rejects a typo instead of falling back to debian" {
    local web_shell_version
    web_shell_version=$(yq -r '[.versions[] | select(([.variants[] | select((.name == "ubuntu") and (.suffix == "-ubuntu") and (.flavor == "ubuntu"))] | length) > 0) | select(([.variants[] | select((.name == "typo") or (.suffix == "-typo"))] | length) == 0) | .tag] | .[0] // ""' \
        "$PROJECT_ROOT/web-shell/variants.yaml") || {
        echo "web-shell/variants.yaml could not be read to find an ubuntu variant without a typo suffix" >&2
        return 1
    }
    if [[ -z "$web_shell_version" || "$web_shell_version" == "null" ]]; then
        echo "web-shell/variants.yaml does not declare an ubuntu variant without a typo suffix" >&2
        return 1
    fi

    resolve "$PROJECT_ROOT/web-shell" "web-shell:$web_shell_version-ubuntu"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.variant' <<<"$output")" = "ubuntu" ]

    resolve "$PROJECT_ROOT/web-shell" "web-shell:$web_shell_version-typo"
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not name a declared cell"* ]]
}

@test "uses the longest github-runner suffix and preserves the distinct variant name" {
    local github_runner_version
    github_runner_version=$(yq -r '[.versions[] | select(([.variants[] | select((.name == "debian-trixie-dev") and (.suffix == "-debian-trixie-dev") and (.flavor == "debian-trixie"))] | length) > 0) | select(([.variants[] | select((.name == "ubuntu-2404-dev") and (.suffix == "-dev") and (.flavor == "ubuntu-2404"))] | length) > 0) | .tag] | .[0] // ""' \
        "$PROJECT_ROOT/github-runner/variants.yaml") || {
        echo "github-runner/variants.yaml could not be read to find debian-trixie-dev and dev suffixes" >&2
        return 1
    }
    if [[ -z "$github_runner_version" || "$github_runner_version" == "null" ]]; then
        echo "github-runner/variants.yaml does not declare debian-trixie-dev and dev suffixes" >&2
        return 1
    fi

    resolve "$PROJECT_ROOT/github-runner" "github-runner:$github_runner_version-debian-trixie-dev"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.variant + ":" + .flavor' <<<"$output")" = "debian-trixie-dev:debian-trixie" ]

    resolve "$PROJECT_ROOT/github-runner" "github-runner:$github_runner_version-dev"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.variant + ":" + .flavor' <<<"$output")" = "ubuntu-2404-dev:ubuntu-2404" ]
}

@test "accepts only postgres's generated base-before-variant tag order" {
    # 17 is a long-lived major stream (always_all_versions: true), and this
    # assertion requires that major to declare vector. Deriving it would trade
    # this stable pin for a fragile choice among supported majors.
    resolve "$PROJECT_ROOT/postgres" "postgres:17-alpine-vector"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.variant' <<<"$output")" = "vector" ]

    resolve "$PROJECT_ROOT/postgres" "postgres:17-vector-alpine"
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not name a declared cell"* ]]
}

@test "rejects duplicate declared cell tags" {
    local dir
    dir=$(make_container duplicate 'versions:
  - tag: 1.2.3-alpine
    variants:
      - name: first
        suffix: ""
        flavor: first
      - name: second
        suffix: ""
        flavor: second
' '-alpine')

    resolve "$dir" "duplicate:1.2.3-alpine"
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not resolve to one declared cell"* ]]
}

@test "refuses digest references and a repository for another container" {
    local dir reference
    dir=$(make_container refs 'versions:
  - tag: v2.3.1-alpine' '')

    for reference in \
        'refs:v2.3.1-alpine@garbage' \
        'refs:v2.3.1-alpine@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' \
        ':v2.3.1-alpine' \
        'https://host/refs:v2.3.1-alpine' \
        'unrelated:v2.3.1-alpine'; do
        resolve "$dir" "$reference"
        [ "$status" -ne 0 ]
    done
}

@test "rejects incomplete and ill-typed image identity records" {
    local record
    for record in \
        '{"reference":"image:1","tag":"1","component_version":"1","kind":"variant","variant":"","flavor":""}' \
        '{"reference":"image:1","tag":"1","component_version":"1","kind":"variant","variant":7,"flavor":"alpine"}' \
        '{"reference":"","tag":"1","component_version":"1","kind":"single","variant":null,"flavor":null}' \
        '{"reference":"image:1","tag":"","component_version":"1","kind":"single","variant":null,"flavor":null}' \
        '{"reference":"image:1","tag":"1","component_version":"1","kind":"single","variant":"base","flavor":null}'; do
        run bash -c 'source "$1"; E2E_IMAGE_IDENTITY="$2"; _image_identity_record_field component_version' _ \
            "$RESOLVER" "$record"
        [ "$status" -ne 0 ]
    done
}

@test "accepts an empty flavor for a variant identity record" {
    local record='{"reference":"image:1","tag":"1","component_version":"1","kind":"variant","variant":"base","flavor":""}'

    run bash -c 'source "$1"; E2E_IMAGE_IDENTITY="$2"; _image_identity_record_field kind' _ \
        "$RESOLVER" "$record"
    [ "$status" -eq 0 ]
    [ "$output" = "variant" ]
}

@test "resolves every workflow build cell of every e2e-enabled container" {
    local variants_file container_dir matrix cell tag version variant flavor expected_count=0 count=0
    while IFS= read -r variants_file; do
        container_dir="${variants_file%/variants.yaml}"
        if ! yq -e '.tests.e2e.enabled == true' "$variants_file" >/dev/null 2>&1; then
            continue
        fi
        matrix=$(bash -c 'source "$1/helpers/variant-utils.sh"; list_build_matrix "$2" "" true' _ \
            "$PROJECT_ROOT" "$container_dir")
        expected_count=$((expected_count + $(jq 'length' <<<"$matrix")))
        while IFS= read -r cell; do
            tag=$(jq -r '.tag' <<<"$cell")
            version=$(jq -r '.version' <<<"$cell")
            variant=$(jq -r '.variant' <<<"$cell")
            flavor=$(jq -r '.flavor' <<<"$cell")
            run env E2E_BUILD_TAG="$tag" E2E_BUILD_VERSION="$version" \
                E2E_BUILD_VARIANT="$variant" E2E_BUILD_FLAVOR="$flavor" bash -c \
                'source "$1"; image_identity_resolve "$2" "$3"' _ \
                "$RESOLVER" "$container_dir" "${container_dir##*/}:$tag"
            [ "$status" -eq 0 ]
            [ "$(jq -r '.tag' <<<"$output")" = "$tag" ]
            count=$((count + 1))
        done < <(jq -c '.[]' <<<"$matrix")
    done < <(find "$PROJECT_ROOT" -mindepth 2 -maxdepth 2 -name variants.yaml | sort)

    [ "$count" -eq "$expected_count" ]
}
