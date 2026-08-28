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
# for inline Dockerfiles (before Bake's $${...} HCL escaping).  It implements
# only the final-FROM grammar used by this fleet: a reference (optionally
# argument-derived), an optional AS name, or scratch.  New syntax must fail
# here until the resolver deliberately learns how to interpret it.
resolve_final_runnable_base() {
    local dockerfile_content="$1"
    local effective_args_json="${2-}"
    local from_line="" line

    if [[ -z "$effective_args_json" ]]; then
        effective_args_json='{}'
    elif ! jq -e 'type == "object"' >/dev/null 2>&1 <<< "$effective_args_json"; then
        printf 'effective build arguments must be a valid JSON object\n' >&2
        return 1
    fi

    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*FROM[[:space:]]+ ]] && from_line="$line"
    done <<< "$dockerfile_content"

    [[ -n "$from_line" ]] || {
        printf 'Dockerfile has no final FROM instruction\n' >&2
        return 1
    }

    # Deliberately accept only `<reference> [AS <stage>]`. In particular,
    # `--platform`, continuations, and other Dockerfile forms are not safe to
    # reduce to a base-image identity without extending this resolver.
    local raw_ref
    if [[ "$from_line" =~ ^[[:space:]]*FROM[[:space:]]+([^[:space:]]+)([[:space:]]+[Aa][Ss][[:space:]]+[A-Za-z0-9][A-Za-z0-9_.-]*)?[[:space:]]*$ ]]; then
        raw_ref="${BASH_REMATCH[1]}"
    else
        printf 'unsupported final FROM syntax: %s\n' "$from_line" >&2
        return 1
    fi

    # An argument-derived reference may contain only complete `$NAME` or
    # `${NAME}` tokens. Removing those first makes parameter operators such as
    # `${NAME:-fallback}` a visible unsupported construct rather than a
    # partially resolved identity.
    local syntax_check="$raw_ref"
    while [[ "$syntax_check" =~ (\$\{[A-Za-z_][A-Za-z0-9_]*\}|\$[A-Za-z_][A-Za-z0-9_]*) ]]; do
        syntax_check="${syntax_check/"${BASH_REMATCH[1]}"/}"
    done
    if [[ "$syntax_check" == *'$'* || "$syntax_check" == *'{'* || "$syntax_check" == *'}'* ]]; then
        printf 'unsupported final FROM syntax: %s\n' "$from_line" >&2
        return 1
    fi
    [[ "$raw_ref" == "scratch" ]] && {
        jq -cn '{kind:"no_external_base"}'
        return 0
    }

    # Effective args win.  Dockerfile defaults fill only values the build did
    # not supply.  Use JSON as the map boundary so the helper has no globals.
    local args_json="$effective_args_json"

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

    local resolved="$raw_ref" pass=0 token arg_name value
    while [[ "$resolved" =~ (\$\{[A-Za-z_][A-Za-z0-9_]*\}|\$[A-Za-z_][A-Za-z0-9_]*) && $pass -lt 10 ]]; do
        token="${BASH_REMATCH[1]}"
        if [[ "${token:0:2}" == '${' ]]; then
            arg_name="${token:2:${#token}-3}"
        else
            arg_name="${token:1}"
        fi
        if ! jq -e --arg key "$arg_name" 'has($key)' >/dev/null <<< "$args_json"; then
            break
        fi
        value=$(jq -r --arg key "$arg_name" '.[$key] | tostring' <<< "$args_json")
        resolved="${resolved/"$token"/$value}"
        ((pass++)) || true
    done

    if [[ "$resolved" == *'$'* ]]; then
        jq -cn --arg ref "$resolved" '{kind:"unresolved", ref:$ref}'
    else
        jq -cn --arg ref "$resolved" '{kind:"external", ref:$ref}'
    fi
}

# The resolver's non-external outcomes have no coupled ref/digest fields. Keep
# their lineage spelling here so every writer records them identically.
#
# lineage_base_fields_from_identity <base-identity-json> [<digest>]
lineage_base_fields_from_identity() {
    local base_identity="$1"
    local digest="${2:-}"
    local kind ref
    kind=$(jq -r '.kind // "unresolved"' <<< "$base_identity") || return 1
    case "$kind" in
        no_external_base)
            jq -cn '{base_image_kind:"no_external_base"}'
            return 0
            ;;
        unresolved)
            jq -cn '{base_image_kind:"unresolved_external_base"}'
            return 0
            ;;
        external)
            ;;
        *)
            return 1
            ;;
    esac
    ref=$(jq -r '.ref // empty' <<< "$base_identity")
    [[ -n "$ref" ]] || return 1
    [[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]] || return 1
    jq -cn --arg ref "$ref" --arg digest "$digest" \
        '{base_image_ref:$ref, base_image_digest:$digest}'
}

# lineage_base_fields_from_provenance <base-identity-json> <target-metadata-json>
#
# Extract the digest of the selected final-stage base from Buildx's *per target*
# `buildx.build.provenance` material list. This is build-resolved evidence; it
# never inspects a mutable tag after the build. Buildx decodes the exporter
# response and writes the provenance predicate object itself, so the current
# metadata-file shape has `buildx.build.provenance.materials` (no `predicate`
# wrapper). This is the BuildKit SLSA v0.2 predicate which Buildx emits by
# default; do not add speculative layouts without a producing Buildx version.
lineage_base_fields_from_provenance() {
    local base_identity="$1"
    local target_metadata="$2"
    local kind ref digest
    kind=$(jq -r '.kind // "unresolved"' <<< "$base_identity") || return 1
    if [[ "$kind" != "external" ]]; then
        lineage_base_fields_from_identity "$base_identity"
        return
    fi
    ref=$(jq -r '.ref // empty' <<< "$base_identity")
    [[ -n "$ref" ]] || return 1

    # BuildKit represents Docker bases as package URLs, for example
    # pkg:docker/docker.io/library/alpine@3.21?platform=linux%2Famd64.
    # Match both the literal image reference and the purl's name@version form;
    # the latter accommodates BuildKit's Docker Hub canonicalization.
    digest=$(jq -r --arg ref "$ref" '
      def materials:
        (."buildx.build.provenance" // {}) as $p
        | ($p.materials // []);
      def purl_ref:
        sub("^pkg:docker/"; "") | split("?")[0] | sub("@"; ":");
      [ materials[]?
        | select((.uri // "") as $uri | ($uri == $ref or ($uri | purl_ref) == $ref))
        | (.digest.sha256? // empty
           | if startswith("sha256:") then . else "sha256:" + . end)
      ][0] // empty
    ' <<< "$target_metadata")
    lineage_base_fields_from_identity "$base_identity" "$digest"
}
