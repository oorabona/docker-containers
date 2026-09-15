#!/usr/bin/env bats

load "../test_helper"

setup() {
    source "${PROJECT_ROOT}/helpers/base-image-utils.sh"
}

valid_digest='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
valid_image_id='sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

valid_external_record() {
    jq -cn --arg digest "$valid_digest" --arg image_id "$valid_image_id" '
      {
        lineage_schema_version: 3, container: "foo", version: "1.2.3",
        tag: "1.2.3-alpine", flavor: "alpine", dockerfile: "Dockerfile",
        platform: "linux/amd64", runtime: "docker", image_id: $image_id,
        build_digest: "sha256:build", oci_subject_digest: $digest,
        base_image_ref: "alpine:3.21", base_image_digest: $digest,
        built_at: "2026-09-01T00:00:00Z", duration_seconds: 1,
        github_actions: false,
        images: {dockerhub: "oorabona/foo:1.2.3-alpine", ghcr: "ghcr.io/oorabona/foo:1.2.3-alpine"},
        build_args: {}
      }'
}

@test "external fields require a recognised ref and an OCI index descriptor" {
    local descriptor result
    descriptor=$(jq -cn --arg digest "$valid_digest" \
        '{digest:$digest,mediaType:"application/vnd.oci.image.index.v1+json"}')
    result=$(lineage_base_fields_from_external_identity_with_index_descriptor \
        '{"kind":"external","ref":"alpine:3.21"}' "$descriptor")
    [ "$(jq -r '.base_image_digest' <<< "$result")" = "$valid_digest" ]

    run lineage_base_fields_from_external_identity_with_index_descriptor \
        '{"kind":"external","ref":"scratch"}' "$descriptor"
    [ "$status" -ne 0 ]
    run lineage_base_fields_from_external_identity_with_index_descriptor \
        '{"kind":"external","ref":"alpine:3.21"}' \
        "{\"digest\":\"$valid_digest\",\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\"}"
    [ "$status" -ne 0 ]
}

@test "marker field conversion rejects ambiguous identities" {
    [ "$(lineage_base_fields_from_marker_identity '{"kind":"no_external_base"}')" = '{"base_image_kind":"no_external_base"}' ]
    [ "$(lineage_base_fields_from_marker_identity '{"kind":"unresolved","ref":"unknown"}')" = '{"base_image_kind":"unresolved_external_base"}' ]
    run lineage_base_fields_from_marker_identity '{"kind":"no_external_base","ref":"alpine:3"}'
    [ "$status" -ne 0 ]
}

@test "schema decision rejects malformed and unsupported schema versions" {
    local record
    for record in \
        "{\"lineage_schema_version\":\"3\",\"base_image_ref\":\"alpine:3\",\"base_image_digest\":\"$valid_digest\"}" \
        "{\"lineage_schema_version\":null,\"base_image_ref\":\"alpine:3\",\"base_image_digest\":\"$valid_digest\"}" \
        "{\"lineage_schema_version\":4,\"base_image_ref\":\"alpine:3\",\"base_image_digest\":\"$valid_digest\"}"; do
        run lineage_schema_decision "$record"
        [ "$status" -ne 0 ]
        [ "$(jq -r '.reason' <<< "$output")" = "unsupported_lineage_schema_version" ]
    done
}

@test "schema decision rejects impossible external identities" {
    local record
    for record in \
        "{\"lineage_schema_version\":3,\"base_image_ref\":\"scratch\",\"base_image_digest\":\"$valid_digest\"}" \
        "{\"lineage_schema_version\":3,\"base_image_ref\":\"bad ref:tag\",\"base_image_digest\":\"$valid_digest\"}" \
        "{\"lineage_schema_version\":3,\"base_image_ref\":\"\${BASE}\",\"base_image_digest\":\"$valid_digest\"}"; do
        run lineage_schema_decision "$record"
        [ "$status" -ne 0 ]
        [ "$(jq -r '.reason' <<< "$output")" = "invalid_external_base_image_ref" ]
    done
}

@test "schema decision file entry point matches the document entry point and refuses unreadable files" {
    local record_file unreadable_file record from_document from_file
    record=$(valid_external_record)
    record_file="$BATS_TEST_TMPDIR/lineage.json"
    unreadable_file="$BATS_TEST_TMPDIR/unreadable-lineage.json"
    printf '%s\n' "$record" > "$record_file"
    printf '%s\n' "$record" > "$unreadable_file"

    from_document=$(lineage_schema_decision "$record")
    from_file=$(lineage_schema_decision_file "$record_file")
    [ "$from_file" = "$from_document" ]

    chmod a-r "$unreadable_file"
    run lineage_schema_decision_file "$unreadable_file"
    chmod u+r "$unreadable_file"
    [ "$status" -ne 0 ]
    [[ "$output" == *"could not read lineage record file"* ]]
}

@test "external reference grammar has one authority across schema and descriptor paths" {
    local ref record descriptor result invalid_ref
    ref="ghcr.io/owner/image:tag@$valid_digest"
    record=$(jq -cn --arg ref "$ref" --arg digest "$valid_digest" \
        '{lineage_schema_version:3,base_image_ref:$ref,base_image_digest:$digest}')
    descriptor=$(jq -cn --arg digest "$valid_digest" \
        '{digest:$digest,mediaType:"application/vnd.oci.image.index.v1+json"}')

    _is_fleet_external_ref "$ref"
    result=$(lineage_schema_decision "$record")
    [ "$(jq -r '.class' <<< "$result")" = "External" ]
    [ "$(jq -r '.ref' <<< "$result")" = "$ref" ]
    result=$(lineage_base_fields_from_external_identity_with_index_descriptor \
        "{\"kind\":\"external\",\"ref\":\"$ref\"}" "$descriptor")
    [ "$(jq -r '.base_image_ref' <<< "$result")" = "$ref" ]

    for invalid_ref in \
        "ghcr.io/owner/image:tag@sha256:$(printf 'a%.0s' {1..63})" \
        'ghcr.io/owner/image:tag@sha512:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
        'ghcr.io/owner/image@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; do
        ! _is_fleet_external_ref "$invalid_ref"
        run lineage_schema_decision "{\"lineage_schema_version\":3,\"base_image_ref\":\"$invalid_ref\",\"base_image_digest\":\"$valid_digest\"}"
        [ "$status" -ne 0 ]
        [ "$(jq -r '.reason' <<< "$output")" = "invalid_external_base_image_ref" ]
    done
}

@test "schema decision preserves a digest-less v1 external record by default" {
    local result
    result=$(lineage_schema_decision '{"container":"foo","base_image_ref":"alpine:3.21"}')
    [ "$(jq -r '.class' <<< "$result")" = "LegacyExternal" ]
    [ "$(jq -r '.schema' <<< "$result")" = "1" ]
}

@test "schema decision distinguishes identity validation from writer completeness" {
    local fragment
    fragment=$(jq -cn --arg digest "$valid_digest" \
        '{lineage_schema_version:3,base_image_ref:"alpine:3.21",base_image_digest:$digest}')
    [ "$(jq -r '.class' <<< "$(lineage_schema_decision "$fragment")")" = "External" ]
    run lineage_complete_record_valid "$fragment"
    [ "$status" -ne 0 ]
}

@test "complete record validation permits an empty flavor but requires its key" {
    local empty_flavor missing_flavor
    empty_flavor=$(valid_external_record | jq '.flavor = ""')
    missing_flavor=$(valid_external_record | jq 'del(.flavor)')

    run lineage_complete_record_valid "$empty_flavor"
    [ "$status" -eq 0 ]

    run lineage_complete_record_valid "$missing_flavor"
    [ "$status" -ne 0 ]
}

@test "complete record validation permits an absent publication subject digest" {
    local record
    record=$(valid_external_record | jq 'del(.oci_subject_digest)')

    run lineage_complete_record_valid "$record"
    [ "$status" -eq 0 ]
}

@test "complete record validation permits an absent locally loaded image ID" {
    local record
    record=$(valid_external_record | jq 'del(.image_id)')

    run lineage_complete_record_valid "$record"
    [ "$status" -eq 0 ]
}

@test "complete record validation rejects placeholder and malformed image IDs" {
    local image_id record
    for image_id in \
        'unknown' \
        '' \
        "${valid_image_id#sha256:}" \
        "${valid_image_id}"$'\n'; do
        record=$(valid_external_record | jq --arg image_id "$image_id" '.image_id = $image_id')
        run lineage_complete_record_valid "$record"
        [ "$status" -ne 0 ]
    done
}

@test "complete record validation accepts a well-formed image ID" {
    run lineage_complete_record_valid "$(valid_external_record)"
    [ "$status" -eq 0 ]
}

@test "complete record validation rejects empty and malformed publication subject digests" {
    local digest record
    for digest in \
        '' \
        'sha256:zzz' \
        "${valid_digest#sha256:}" \
        "${valid_digest}"$'\n'; do
        record=$(valid_external_record | jq --arg digest "$digest" '.oci_subject_digest = $digest')
        run lineage_complete_record_valid "$record"
        [ "$status" -ne 0 ]
    done
}

@test "complete record validation accepts a well-formed publication subject digest" {
    local record
    record=$(valid_external_record | jq --arg digest "$valid_digest" '.oci_subject_digest = $digest')

    run lineage_complete_record_valid "$record"
    [ "$status" -eq 0 ]
}

@test "complete record validation keeps other build-completion fields non-empty" {
    local field record
    for field in container build_digest; do
        record=$(valid_external_record | jq --arg field "$field" '.[$field] = ""')
        run lineage_complete_record_valid "$record"
        [ "$status" -ne 0 ]
    done
}

@test "build lineage writer omits image_id without a locally loaded image" {
    local work="$BATS_TEST_TMPDIR/no-local-image"
    local lineage_file
    mkdir -p "$work"

    (
        cd "$work"
        source "$PROJECT_ROOT/scripts/build-container.sh"
        export PROJECT_ROOT="$work"
        docker() { :; }
        BUILD_DIGEST='sha256:build'
        _BASE_IMAGE_REF='alpine:3.21'
        _BASE_DIGEST="$valid_digest"
        _emit_build_lineage \
            'foo' '1.2.3' '1.2.3-alpine' 'alpine' 'Dockerfile' \
            'linux/amd64' 'docker' 'docker.io/oorabona/foo' 'ghcr.io/oorabona/foo'
    )

    lineage_file="$work/.build-lineage/foo-1.2.3-alpine.json"
    [ -f "$lineage_file" ]
    run jq -e 'has("image_id") | not' "$lineage_file"
    [ "$status" -eq 0 ]
    [ "$output" = 'true' ]
}

@test "atomic writer rejects fragments before creating a destination directory" {
    local destination="$BATS_TEST_TMPDIR/new-parent/lineage.json"
    run write_lineage_record_atomically "$destination" '{"lineage_schema_version":3}'
    [ "$status" -ne 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/new-parent" ]
}

@test "atomic writer refuses an existing directory at the requested pathname" {
    local destination="$BATS_TEST_TMPDIR/lineage.json" record
    record=$(valid_external_record)
    mkdir "$destination"
    run write_lineage_record_atomically "$destination" "$record"
    [ "$status" -ne 0 ]
    [ -d "$destination" ]
    [ -z "$(find "$destination" -mindepth 1 -print -quit)" ]
}

@test "atomic writer preserves the old complete record until its final rename" {
    local destination="$BATS_TEST_TMPDIR/lineage.json" old_record new_record marker
    old_record=$(valid_external_record)
    new_record=$(valid_external_record | jq --arg digest 'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
        '.base_image_digest = $digest')
    marker="$BATS_TEST_TMPDIR/reader-observed"
    printf '%s\n' "$old_record" > "$destination"

    mv() {
        local final_path="${!#}"
        jq -e '.base_image_digest == "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' \
            "$final_path" >/dev/null || return 1
        : > "$marker"
        command mv "$@"
    }

    write_lineage_record_atomically "$destination" "$new_record"
    [ -f "$marker" ]
    [ "$(jq -r '.base_image_digest' "$destination")" = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ]
}

@test "atomic writer cleans its adjacent temporary file after a failed rename" {
    local destination="$BATS_TEST_TMPDIR/lineage.json" record
    record=$(valid_external_record)
    mv() { return 1; }

    run write_lineage_record_atomically "$destination" "$record"
    [ "$status" -ne 0 ]
    [ ! -e "$destination" ]
    [ -z "$(find "$BATS_TEST_TMPDIR" -name '.lineage.json.tmp.*' -print -quit)" ]
}
