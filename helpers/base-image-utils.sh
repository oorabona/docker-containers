#!/usr/bin/env bash

# Base-image lineage helpers.

_is_fleet_external_ref() {
    local ref="$1"
    [[ "$ref" =~ ^[a-z0-9]+([._-][a-z0-9]+)*(\/[a-z0-9]+([._-][a-z0-9]+)*)*:[A-Za-z0-9_][A-Za-z0-9_.-]*(@sha256:[a-f0-9]{64})?$ ]]
}

# lineage_base_fields_from_marker_identity <base-identity-json>
lineage_base_fields_from_marker_identity() {
    local base_identity="$1" kind
    kind=$(jq -er 'if type == "object" and (.kind | type) == "string" then .kind else empty end' \
        <<< "$base_identity") || return 1
    case "$kind" in
        no_external_base)
            jq -e '(has("ref") | not) and (has("supplier") | not)' >/dev/null <<< "$base_identity" || return 1
            jq -cn '{base_image_kind:"no_external_base"}'
            ;;
        unresolved)
            jq -e '(.ref | type) == "string" and (.ref | length) > 0 and (has("supplier") | not)' \
                >/dev/null <<< "$base_identity" || return 1
            jq -cn '{base_image_kind:"unresolved_external_base"}'
            ;;
        sibling_target)
            jq -e '
              .supplier as $supplier
              | ($supplier | type == "object") and
                ([$supplier.container, $supplier.version, $supplier.platform,
                  $supplier.textual_ref, $supplier.bake_target_id] | all(type == "string" and length > 0)) and
                ($supplier.flavor | type == "string") and (has("ref") | not)
            ' >/dev/null <<< "$base_identity" || return 1
            jq -cn --argjson supplier "$(jq -c '.supplier' <<< "$base_identity")" \
                '{base_image_kind:"sibling_target",base_image_sibling:$supplier}'
            ;;
        *) return 1 ;;
    esac
}

# lineage_base_fields_from_external_identity_with_index_descriptor
#     <base-identity-json> <inspected-oci-descriptor-json>
#
# Digest shape alone does not establish descriptor level. A v3 writer must
# supply the inspected OCI descriptor so only an image index or manifest list
# can become base_image_digest.
lineage_base_fields_from_external_identity_with_index_descriptor() {
    local base_identity="$1" descriptor="$2" kind ref digest media_type
    kind=$(jq -er 'if type == "object" and (.kind | type) == "string" then .kind else empty end' \
        <<< "$base_identity") || return 1
    [[ "$kind" == external ]] || return 1
    ref=$(jq -er 'if (.ref | type) == "string" then .ref else empty end' <<< "$base_identity") || return 1
    _is_fleet_external_ref "$ref" || return 1
    jq -es 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1 <<< "$descriptor" || return 1
    digest=$(jq -er '.digest | strings' <<< "$descriptor") || return 1
    media_type=$(jq -er '.mediaType | strings' <<< "$descriptor") || return 1
    [[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]] || return 1
    case "$media_type" in
        application/vnd.oci.image.index.v1+json|application/vnd.docker.distribution.manifest.list.v2+json) ;;
        *) return 1 ;;
    esac
    jq -cn --arg ref "$ref" --arg digest "$digest" \
        '{base_image_ref:$ref,base_image_digest:$digest}'
}

# lineage_schema_decision <json-record>
#
# This is base-identity validation only. It is neither a complete writer-record
# validator nor registry authorization; network consumers apply trust policy
# separately before probing an admitted ref.
lineage_schema_decision() {
    local record="${1-}" decision ref jq_filter
    read -r -d '' jq_filter <<'JQ' || true
      def bad($reason): {class:"Invalid",reason:$reason};
      def digest: type == "string" and test("^sha256:[a-f0-9]{64}$");
      def supplier_valid:
        (.base_image_sibling | type == "object") and
        ([.base_image_sibling.container, .base_image_sibling.version,
          .base_image_sibling.platform, .base_image_sibling.textual_ref,
          .base_image_sibling.bake_target_id] | all(type == "string" and length > 0)) and
        (.base_image_sibling.flavor | type == "string");
      def external_fields: has("base_image_ref") or has("base_image_digest");
      def marker($schema):
        if (.base_image_kind | type) != "string" then bad("invalid_base_image_kind")
        elif .base_image_kind == "no_external_base" or .base_image_kind == "unresolved_external_base" then
          if external_fields or has("base_image_sibling") then bad("marker_carries_external_base_fields")
          else {class:(if .base_image_kind == "no_external_base" then "NoExternal" else "Unresolved" end),schema:$schema} end
        elif .base_image_kind == "sibling_target" then
          if external_fields then bad("marker_carries_external_base_fields")
          elif supplier_valid then {class:"Sibling",schema:$schema,supplier:.base_image_sibling}
          else bad("malformed_sibling_target") end
        else bad("unrecognised_base_image_kind") end;
      def external($schema; $legacy):
        if has("base_image_sibling") then bad("external_carries_sibling_base_fields")
        elif ((.base_image_ref | type) != "string" or (.base_image_ref | length) == 0) then bad("missing_base_image_ref")
        elif ((.base_image_digest | type) != "string" or (.base_image_digest | length) == 0) then
          if $legacy then {class:"LegacyExternal",schema:$schema,ref:.base_image_ref}
          else bad("missing_external_index_digest") end
        elif (.base_image_digest | digest | not) then bad("malformed_recorded_digest")
        else {class:"External",schema:$schema,ref:.base_image_ref,index_digest:.base_image_digest} end;
      def decide:
        if type != "object" then bad("lineage_not_object")
        elif has("lineage_schema_version") | not then
          if has("base_image_kind") then marker("1") else external("1"; true) end
        elif .lineage_schema_version == 1 then
          if has("base_image_kind") then marker("1") else external("1"; true) end
        elif .lineage_schema_version == 2 then
          if has("base_image_kind") then marker("2") else external("2"; false) end
        elif .lineage_schema_version == 3 then
          if has("base_image_kind") then marker("3") else external("3"; false) end
        else bad("unsupported_lineage_schema_version") end;
      if length != 1 then bad("lineage_document_count") else .[0] | decide end
JQ
    if (( $# == 0 )); then
        decision=$(jq -cse "$jq_filter") || return 1
    elif (( $# == 1 )); then
        decision=$(jq -cse "$jq_filter" <<< "$record") || return 1
    else
        return 1
    fi
    case "$(jq -r '.class' <<< "$decision")" in
        External|LegacyExternal)
            ref=$(jq -er '.ref' <<< "$decision") || return 1
            if ! _is_fleet_external_ref "$ref"; then
                decision='{"class":"Invalid","reason":"invalid_external_base_image_ref"}'
            fi
            ;;
    esac
    printf '%s\n' "$decision"
    [[ "$(jq -r '.class' <<< "$decision")" != Invalid ]]
}

# lineage_schema_decision_file <json-record-file>
#
# Keep a lineage document in jq's input stream rather than reading it through a
# shell variable.  The document entry point above remains available to callers
# that already have a small record in hand.
lineage_schema_decision_file() {
    local record_file="${1-}"
    if (( $# != 1 )) || [[ ! -f "$record_file" || ! -r "$record_file" ]]; then
        printf 'could not read lineage record file: %s\n' "$record_file" >&2
        return 1
    fi
    lineage_schema_decision < "$record_file"
}

# lineage_complete_record_valid <json-record>
#
# Older documents may be structurally useful to readers. A v3 writer is
# stricter: it cannot publish a base-identity fragment without variant and
# build attribution.
lineage_complete_record_valid() {
    local record="$1"
    lineage_schema_decision "$record" >/dev/null || return 1
    jq -es '
      length == 1 and (.[0] |
      .lineage_schema_version == 3 and
      ([.container, .version, .tag, .flavor, .dockerfile, .platform, .runtime,
        .image_id, .build_digest, .oci_subject_digest, .built_at]
       | all(type == "string" and length > 0)) and
      (.duration_seconds | type == "number" or type == "null") and
      (.github_actions | type == "boolean") and
      (.images | type == "object") and
      ([.images.dockerhub, .images.ghcr] | all(type == "string" and length > 0)) and
      (.build_args | type == "object"))
    ' >/dev/null 2>&1 <<< "$record"
}

# write_lineage_record_atomically <destination> <json-record>
write_lineage_record_atomically() (
    local destination="$1" record="$2" directory basename tmp_file=""
    cleanup_lineage_temp() {
        if [[ -n "$tmp_file" && -e "$tmp_file" ]] && ! rm -f -- "$tmp_file"; then
            printf 'could not remove lineage temporary file: %s\n' "$tmp_file" >&2
            return 1
        fi
    }
    trap cleanup_lineage_temp EXIT
    trap 'exit 128' HUP INT TERM

    # An invalid record must not even create its parent directory.
    lineage_complete_record_valid "$record" || return 1
    directory=$(dirname "$destination") || return 1
    basename=$(basename "$destination") || return 1
    mkdir -p -- "$directory" || return 1
    tmp_file=$(mktemp "${directory}/.${basename}.tmp.XXXXXX") || return 1
    printf '%s\n' "$record" > "$tmp_file" || return 1
    mv -fT -- "$tmp_file" "$destination" || return 1
    tmp_file=""
)
