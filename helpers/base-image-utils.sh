#!/usr/bin/env bash

# Base-image lineage helpers.
#
# v1 deliberately records only the external material that defines the final
# runnable Dockerfile stage.  It does not try to report build-stage materials:
# those are not part of this contract.  This is a fleet rule, not a general
# Dockerfile rule.  A final `FROM <internal-stage>` would require ancestry
# tracing; no tracked Dockerfile currently has one.

# resolve_final_runnable_base <dockerfile-content> <effective-args-json>
#
# Print one JSON object:
#   {"kind":"external","ref":"registry/image:tag"}
#   {"kind":"no_external_base"}       # final stage is scratch
#   {"kind":"unresolved","ref":"${ARG}/image"}
#
# The function is intentionally pure: no cwd, globals, labels, registry I/O,
# or Docker invocation.  Effective build args take precedence over Dockerfile
# ARG defaults; expansion is bounded so a cyclic value remains unresolved
# rather than guessed.  The caller supplies the already-materialized content
# for inline Dockerfiles (before Bake's $${...} HCL escaping).
resolve_final_runnable_base() {
    local dockerfile_content="$1"
    local effective_args_json="${2-}"
    [[ -n "$effective_args_json" ]] || effective_args_json='{}'
    local from_line="" line

    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*FROM[[:space:]]+ ]] && from_line="$line"
    done <<< "$dockerfile_content"

    [[ -n "$from_line" ]] || {
        jq -cn '{kind:"unresolved", ref:""}'
        return 0
    }

    # Docker permits flags before the image (`FROM --platform=$BUILDPLATFORM …`).
    local rest raw_ref token
    rest="${from_line#${from_line%%[![:space:]]*}}"
    rest="${rest#FROM}"
    rest="${rest#${rest%%[![:space:]]*}}"
    raw_ref=""
    for token in $rest; do
        [[ "$token" == --* ]] && continue
        raw_ref="$token"
        break
    done

    [[ -n "$raw_ref" ]] || {
        jq -cn '{kind:"unresolved", ref:""}'
        return 0
    }
    [[ "$raw_ref" == "scratch" ]] && {
        jq -cn '{kind:"no_external_base"}'
        return 0
    }

    # Effective args win.  Dockerfile defaults fill only values the build did
    # not supply.  Use JSON as the map boundary so the helper has no globals.
    local args_json
    if ! jq -e 'type == "object"' >/dev/null 2>&1 <<< "$effective_args_json"; then
        args_json='{}'
    else
        args_json="$effective_args_json"
    fi

    local defaults='{}' arg_name arg_value
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*ARG[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            arg_name="${BASH_REMATCH[1]}"
            arg_value="${BASH_REMATCH[2]}"
            arg_value="${arg_value%\"}"; arg_value="${arg_value#\"}"
            arg_value="${arg_value%\'}"; arg_value="${arg_value#\'}"
            defaults=$(jq -cn --argjson base "$defaults" --arg k "$arg_name" --arg v "$arg_value" '$base + {($k): $v}')
        fi
    done <<< "$dockerfile_content"
    args_json=$(jq -cn --argjson defaults "$defaults" --argjson effective "$args_json" '$defaults + $effective')

    local resolved="$raw_ref" previous pass=0 key value
    while [[ "$resolved" == *'$'* && $pass -lt 10 ]]; do
        previous="$resolved"
        while IFS=$'\t' read -r key value; do
            [[ -n "$key" ]] || continue
            resolved="${resolved//\$\{$key\}/$value}"
            resolved="${resolved//\$$key/$value}"
        done < <(jq -r 'to_entries[] | [.key, (.value | tostring)] | @tsv' <<< "$args_json")
        [[ "$resolved" == "$previous" ]] && break
        ((pass++)) || true
    done

    if [[ "$resolved" == *'$'* ]]; then
        jq -cn --arg ref "$resolved" '{kind:"unresolved", ref:$ref}'
    else
        jq -cn --arg ref "$resolved" '{kind:"external", ref:$ref}'
    fi
}

# lineage_base_fields_from_provenance <base-identity-json> <target-metadata-json>
#
# Extract the digest of the selected final-stage base from Buildx's *per target*
# `buildx.build.provenance` material list.  This is build-resolved evidence; it
# never inspects a mutable tag after the build.  The source accepts the current
# SLSA v0.2 (`predicate.materials`) and v1 (`resolvedDependencies`) layouts.
# A no-external-base result omits both coupled fields and carries an explicit
# marker for the drift consumer.
lineage_base_fields_from_provenance() {
    local base_identity="$1"
    local target_metadata="$2"
    local kind ref digest
    kind=$(jq -r '.kind // "unresolved"' <<< "$base_identity")
    if [[ "$kind" == "no_external_base" ]]; then
        jq -cn '{base_image_kind:"no_external_base"}'
        return 0
    fi
    [[ "$kind" == "external" ]] || return 1
    ref=$(jq -r '.ref // empty' <<< "$base_identity")
    [[ -n "$ref" ]] || return 1

    # BuildKit represents Docker bases as package URLs, for example
    # pkg:docker/docker.io/library/alpine@3.21?platform=linux%2Famd64.
    # Match both the literal image reference and the purl's name@version form;
    # the latter accommodates BuildKit's Docker Hub canonicalization.
    digest=$(jq -r --arg ref "$ref" '
      def materials:
        (."buildx.build.provenance" // {}) as $p
        | ($p.predicate.materials // $p.predicate.buildDefinition.resolvedDependencies // $p.predicate.runDetails.builderDependencies // []);
      def purl_ref:
        sub("^pkg:docker/"; "") | split("?")[0] | sub("@"; ":");
      [ materials[]?
        | select((.uri // "") as $uri | ($uri == $ref or ($uri | purl_ref) == $ref))
        | (.digest.sha256? // empty
           | if startswith("sha256:") then . else "sha256:" + . end)
      ][0] // empty
    ' <<< "$target_metadata")
    [[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]] || return 1
    jq -cn --arg ref "$ref" --arg digest "$digest" \
        '{base_image_ref:$ref, base_image_digest:$digest}'
}
