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
    metadata=$(jq -cn --arg d "$digest" '{"buildx.build.provenance": {predicate: {materials: [{uri: "pkg:docker/ghcr.io/oorabona/library/alpine@latest?platform=linux%2Famd64", digest: {sha256: $d}}]}}}')
    result=$(lineage_base_fields_from_provenance "$identity" "$metadata")
    [ "$(jq -r '.base_image_ref' <<< "$result")" = "ghcr.io/oorabona/library/alpine:latest" ]
    [ "$(jq -r '.base_image_digest' <<< "$result")" = "sha256:${digest}" ]
    [ "$(jq 'has("base_image_ref") and has("base_image_digest")' <<< "$result")" = "true" ]
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
