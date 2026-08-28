#!/usr/bin/env bats

# Contract tests for final-runnable-stage base lineage (#1523).

load "../test_helper"

setup() {
    source "${PROJECT_ROOT}/helpers/base-image-utils.sh"
}

@test "single-stage external FROM resolves through effective args" {
    local result
    result=$(resolve_final_runnable_base $'ARG REGISTRY=docker.io\nFROM ${REGISTRY}/library/debian:trixie\n' \
        '{"REGISTRY":"ghcr.io/oorabona"}')
    [ "$(jq -r '.kind' <<< "$result")" = "external" ]
    [ "$(jq -r '.ref' <<< "$result")" = "ghcr.io/oorabona/library/debian:trixie" ]
}

@test "five-stage Dockerfile resolves its final external FROM, not the first build stage" {
    local result
    result=$(resolve_final_runnable_base $'FROM hashicorp/terraform:1 AS terraform\nFROM alpine:3 AS tools\nFROM python:3 AS cloud\nFROM alpine:3 AS more-tools\nFROM ${REMOTE_CR}/library/alpine:latest\n' \
        '{"REMOTE_CR":"ghcr.io/oorabona"}')
    [ "$(jq -r '.ref' <<< "$result")" = "ghcr.io/oorabona/library/alpine:latest" ]
}

@test "final scratch has an explicit no-external-base identity" {
    local result
    result=$(resolve_final_runnable_base $'FROM alpine:3 AS build\nFROM scratch\n' '{}')
    [ "$(jq -r '.kind' <<< "$result")" = "no_external_base" ]
    [ "$(jq 'has("ref")' <<< "$result")" = "false" ]
}

@test "HCL-escaped inline content is resolved after unescaping and effective args override defaults" {
    local result
    # This reproduces Bake's emitted $${...}; its HCL reader restores ${...}
    # before Dockerfile parsing, so the resolver must be called with that content.
    result=$(resolve_final_runnable_base $'ARG REMOTE_CR=docker.io\nFROM ${REMOTE_CR}/library/ubuntu:24.04\n' \
        '{"REMOTE_CR":"ghcr.io/oorabona"}')
    [ "$(jq -r '.ref' <<< "$result")" = "ghcr.io/oorabona/library/ubuntu:24.04" ]
}

@test "Bake cells resolve the unescaped inline template with target-effective args" {
    run bash "${PROJECT_ROOT}/scripts/generate-bake-hcl.sh" --cells github-runner
    [ "$status" -eq 0 ]
    # github-runner's template defaults REMOTE_CR, while the target passes it
    # explicitly. The returned ref proves the target-effective value won.
    [ "$(jq -r '[.[] | .runtime_base.ref] | all(startswith("ghcr.io/oorabona/"))' <<< "$output")" = "true" ]

    run bash "${PROJECT_ROOT}/scripts/generate-bake-hcl.sh" github-runner
    [ "$status" -eq 0 ]
    # Bake's JSON contains the HCL-escaped spelling; resolution above occurred
    # before this transformation, on the Dockerfile text BuildKit receives.
    [ "$(jq -r '[.target[] | .["dockerfile-inline"]? | select(. != null) | contains("$${REMOTE_CR}")] | any' <<< "$output")" = "true" ]
}

@test "provenance emitter fields couple reference and build-resolved digest" {
    local digest="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    local identity metadata result
    identity='{"kind":"external","ref":"ghcr.io/oorabona/library/alpine:latest"}'
    # Buildx's metadata decoder base64-decodes the exporter response and
    # unmarshals the provenance predicate directly. The wrapper is absent.
    metadata=$(jq -cn --arg d "$digest" '{"buildx.build.provenance": {materials: [{uri: "pkg:docker/ghcr.io/oorabona/library/alpine@latest?platform=linux%2Famd64", digest: {sha256: $d}}]}}')
    result=$(lineage_base_fields_from_provenance "$identity" "$metadata")
    [ "$(jq -r '.base_image_ref' <<< "$result")" = "ghcr.io/oorabona/library/alpine:latest" ]
    [ "$(jq -r '.base_image_digest' <<< "$result")" = "sha256:${digest}" ]
    [ "$(jq 'has("base_image_ref") and has("base_image_digest")' <<< "$result")" = "true" ]
}

@test "provenance emitter refuses the statement wrapper Buildx does not write" {
    local digest metadata
    digest="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    metadata=$(jq -cn --arg d "$digest" '{"buildx.build.provenance": {predicate: {materials: [{uri: "pkg:docker/ghcr.io/oorabona/library/alpine@latest?platform=linux%2Famd64", digest: {sha256: $d}}]}}}')
    run lineage_base_fields_from_provenance \
        '{"kind":"external","ref":"ghcr.io/oorabona/library/alpine:latest"}' "$metadata"
    [ "$status" -ne 0 ]
}

@test "argument expansion resolves the complete identifier, never a prefix" {
    local result
    result=$(resolve_final_runnable_base \
        $'ARG RESTY_CONFIG_OPTIONS=wrong\nARG RESTY_CONFIG_OPTIONS_MORE=right\nFROM $RESTY_CONFIG_OPTIONS/library/alpine:latest\n' \
        '{}')
    [ "$(jq -r '.ref' <<< "$result")" = "wrong/library/alpine:latest" ]
}

@test "malformed effective build arguments are refused" {
    run resolve_final_runnable_base 'FROM alpine:latest' '{not-json'
    [ "$status" -ne 0 ]
    [[ "$output" == *"effective build arguments must be a valid JSON object"* ]]
}

@test "non-object effective build arguments are refused" {
    run resolve_final_runnable_base 'FROM alpine:latest' '[]'
    [ "$status" -ne 0 ]
    [[ "$output" == *"effective build arguments must be a valid JSON object"* ]]
}

@test "unsupported final FROM syntax is refused" {
    run resolve_final_runnable_base 'FROM --platform=$TARGETPLATFORM alpine:latest' '{}'
    [ "$status" -ne 0 ]
    [[ "$output" == *"unsupported final FROM syntax"* ]]
}

@test "every tracked production Dockerfile stays within the final FROM grammar" {
    local dockerfile result
    while IFS= read -r dockerfile; do
        case "$dockerfile" in
            examples/*|tests/*) continue ;;
        esac
        # These are generator inputs rather than Dockerfiles BuildKit receives.
        rg -q '@@[A-Za-z_]+@@' "$PROJECT_ROOT/$dockerfile" && continue
        if ! result=$(resolve_final_runnable_base "$(< "$PROJECT_ROOT/$dockerfile")" '{}'); then
            printf 'final FROM is outside the lineage resolver grammar: %s\n' "$dockerfile" >&2
            return 1
        fi
    done < <(git -C "$PROJECT_ROOT" ls-files | rg '(^|/)Dockerfile([._-]|$)')
}

@test "bake lineage is mandatory even when the Syft install is advisory" {
    local workflow steps lineage syft
    workflow="$PROJECT_ROOT/.github/workflows/auto-build.yaml"
    steps=$(yq -o=json '.jobs."bake-build-amd64".steps' "$workflow")
    lineage=$(jq -c '.[] | select(.name == "Emit lineage (bake amd64)")' <<< "$steps")
    syft=$(jq -c '.[] | select(.id == "install-syft-bake")' <<< "$steps")

    [ -n "$lineage" ] || { printf 'mandatory bake lineage step is missing\n' >&2; return 1; }
    [ "$(jq -r '."continue-on-error" // false' <<< "$lineage")" = "false" ] \
        || { printf 'mandatory bake lineage step must not continue on error\n' >&2; return 1; }
    [[ "$(jq -r '.if // ""' <<< "$lineage")" != *"install-syft-bake"* ]] \
        || { printf 'mandatory bake lineage step must not depend on Syft\n' >&2; return 1; }
    [ "$(jq -r '."continue-on-error" // false' <<< "$syft")" = "true" ] \
        || { printf 'Syft install must remain advisory\n' >&2; return 1; }
}

@test "both bake architectures request minimum metadata provenance" {
    local workflow amd64 arm64
    workflow="$PROJECT_ROOT/.github/workflows/auto-build.yaml"
    amd64=$(yq -r '.jobs."bake-build-amd64".steps[] | select(.id == "bake-build") | .env.BUILDX_METADATA_PROVENANCE' "$workflow")
    arm64=$(yq -r '.jobs."bake-build-arm64".steps[] | select(.id == "bake-build") | .env.BUILDX_METADATA_PROVENANCE' "$workflow")
    [ "$amd64" = "min" ] || { printf 'amd64 bake metadata provenance must be min\n' >&2; return 1; }
    [ "$arm64" = "min" ] || { printf 'arm64 bake metadata provenance must be min\n' >&2; return 1; }
}

@test "provenance emitter refuses a reference with no resolved material digest" {
    run lineage_base_fields_from_provenance \
        '{"kind":"external","ref":"ghcr.io/oorabona/library/alpine:latest"}' '{}'
    [ "$status" -ne 0 ]
}

@test "provenance emitter has no post-build registry lookup path" {
    local implementation
    implementation=$(declare -f lineage_base_fields_from_provenance)
    [[ "$implementation" != *"imagetools inspect"* ]]
    [[ "$implementation" != *"docker manifest"* ]]
    [[ "$implementation" != *"skopeo inspect"* ]]
}

@test "scratch lineage emits the explicit no-base marker and neither coupled field" {
    local result
    result=$(lineage_base_fields_from_provenance '{"kind":"no_external_base"}' '{}')
    [ "$(jq -r '.base_image_kind' <<< "$result")" = "no_external_base" ]
    [ "$(jq 'has("base_image_ref") or has("base_image_digest")' <<< "$result")" = "false" ]
}

@test "bake lineage records an unresolved resolver result with the detector marker" {
    local result
    if ! result=$(lineage_base_fields_from_provenance \
        '{"kind":"unresolved","ref":"${MISSING_BASE}/library/alpine:latest"}' '{}'); then
        echo "Bake lineage must emit unresolved_external_base for an unresolved resolver identity"
        return 1
    fi
    [ "$(jq -r '.base_image_kind' <<< "$result")" = "unresolved_external_base" ] || {
        echo "Bake lineage must emit unresolved_external_base for an unresolved resolver identity"
        return 1
    }
    [ "$(jq 'has("base_image_ref")' <<< "$result")" = "false" ] || {
        echo "Bake lineage must not emit an empty base_image_ref for unresolved identity"
        return 1
    }
}

@test "flat lineage records an unresolved resolver result with the shared detector marker" {
    local label_args="" record work="$BATS_TEST_TMPDIR"
    printf 'FROM ${MISSING_BASE}/library/alpine:latest\n' > "$work/Dockerfile"

    # Source before redirecting PROJECT_ROOT so the production helpers load
    # from this checkout while the lineage artifact stays test-local.
    source "$PROJECT_ROOT/scripts/build-container.sh"
    PROJECT_ROOT="$work"
    declare -gA _BUILD_ARGS_RESOLVED=()
    docker() { return 0; }

    _resolve_base_image "$work/Dockerfile" "1.0" "label_args"
    [[ "$_BASE_IMAGE_KIND" == "unresolved" ]] || {
        echo "Flat lineage must preserve the resolver unresolved identity"
        return 1
    }
    [[ -n "$_BASE_IMAGE_REF" ]] || {
        echo "Flat lineage must retain the unresolved reference until shared emission"
        return 1
    }
    _emit_build_lineage "flat-test" "1.0" "1.0" "" "Dockerfile" \
        "linux/amd64" "test" "docker.io/test" "ghcr.io/test"
    record=$(< "$work/.build-lineage/flat-test-1.0.json")
    [ "$(jq -r '.base_image_kind' <<< "$record")" = "unresolved_external_base" ] || {
        echo "Flat lineage must emit unresolved_external_base for an unresolved resolver identity"
        return 1
    }
    [ "$(jq 'has("base_image_ref")' <<< "$record")" = "false" ] || {
        echo "Flat lineage must not emit an empty base_image_ref for unresolved identity"
        return 1
    }
}
