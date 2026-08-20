#!/usr/bin/env bash
# Promote a tested extension candidate from its staging package to canonical tags.
#
# This script is intentionally separate from build-extensions.sh: it consumes
# frozen staging digests and a pre-test canonical baseline, whereas the ordinary
# publish path discovers versions and can reuse tag-based state.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../helpers/extension-utils.sh"

# oci_tag_is_constructible <tag>
#
# OCI tags are capped at 128 characters and must begin with an alphanumeric or
# underscore.  Check every constructed canonical tag before any registry call.
oci_tag_is_constructible() {
    local tag="${1:-}"
    [[ "${#tag}" -le 128 && "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]
}

# canonical_index_has_requested_digests <reference> <amd64-digest> <arm64-digest>
#
# Read the canonical index under the caller-held lock and defer its exactness
# decision to the shared helper used for post-publication validation.
canonical_index_has_requested_digests() {
    local index_ref="${1:-}"
    local amd64_digest="${2:-}"
    local arm64_digest="${3:-}"
    local raw_manifest=""
    local inspect_rc=0

    # Intentionally unquoted: logging.sh represents DRY_RUN commands as the
    # two-word substitution "echo docker".
    # shellcheck disable=SC2086
    raw_manifest=$($DOCKER buildx imagetools inspect "$index_ref" --raw 2>/dev/null) || inspect_rc=$?
    [[ "$inspect_rc" -eq 0 && -n "$raw_manifest" ]] || return 1
    extension_index_has_exact_digests "$raw_manifest" "$amd64_digest" "$arm64_digest"
}

usage() {
    cat <<'EOF'
Usage: rotation-promote.sh --extension NAME --pg-major MAJOR --version VERSION \
  (--baseline-digest DIGEST | --no-canonical-index) \
  --amd64-digest DIGEST --arm64-digest DIGEST

Promote the two tested staging manifests identified by DIGEST to the canonical
extension architecture tags, then publish their canonical multi-arch index.
The caller must declare exactly one pre-test canonical state: the canonical
index digest observed before testing, or --no-canonical-index when it was
confirmed absent. --no-canonical-index is a state flag, never a digest value.

Promotion must be serialized per canonical (extension, pg major, version).
This script does not acquire that lock: the caller must hold it before invoking
the script and retain it through completion. The lock-time read below is a
conflict fence, not a lock.
EOF
}

# read_registry_digest <reference>
#
# Returns 0 and prints a digest when present, 1 when a successful tag listing
# proves a tag reference absent, and 2 when it cannot determine either.
# Callers that need a frozen object must reject both non-zero states; only the
# canonical lock fence can accept the explicit ABSENT state.
read_registry_digest() {
    local ref="${1:-}"
    local output=""
    local inspect_rc=0

    # Intentionally unquoted: logging.sh represents DRY_RUN commands as the
    # two-word substitution "echo skopeo".
    # shellcheck disable=SC2086
    output=$($SKOPEO inspect --format '{{.Digest}}' "docker://${ref}" 2>&1) || inspect_rc=$?
    if [[ "$inspect_rc" -ne 0 ]]; then
        # Match ext_ref_resolve's PRESENT / ABSENT / INDETERMINATE contract:
        # a failed manifest read is never itself evidence of absence. For a
        # tag, a separate successful list-tags operation may prove its absence.
        # Digest references have no tag listing that can establish absence.
        if [[ "$ref" != *@* && "${ref##*/}" == *:* ]]; then
            local repository="${ref%:*}"
            local tag="${ref##*:}"
            local tags_json=""
            local tags_rc=0

            # shellcheck disable=SC2086
            tags_json=$($SKOPEO list-tags "docker://${repository}" 2>&1) || tags_rc=$?
            if [[ "$tags_rc" -eq 0 ]] && jq -e --arg tag "$tag" '
                ((.Tags // .tags) | type == "array") and
                (((.Tags // .tags) | index($tag)) == null)
            ' >/dev/null <<< "$tags_json"; then
                return 1
            fi
        fi
        log_error "Could not determine registry digest for $(_escape_gha_command "$ref") (inspect rc=$inspect_rc)"
        return 2
    fi

    local digest_rc=0
    is_valid_oci_digest "$output" || digest_rc=$?
    if [[ "$digest_rc" -ne 0 ]]; then
        log_error "Registry digest for $(_escape_gha_command "$ref") was malformed"
        return 2
    fi

    printf '%s' "$output"
}

# verify_staging_manifest <reference> <architecture>
#
# Proves the frozen staging source is a single image manifest for linux/<arch>.
# A manifest index is deliberately refused: skopeo copy --all would otherwise
# copy every child beneath an architecture-specific canonical tag.
verify_staging_manifest() {
    local source_ref="${1:-}"
    local architecture="${2:-}"
    local raw_manifest=""
    local config=""
    local raw_rc=0
    local config_rc=0

    # shellcheck disable=SC2086
    raw_manifest=$($SKOPEO inspect --raw "docker://${source_ref}" 2>&1) || raw_rc=$?
    if [[ "$raw_rc" -ne 0 ]] || ! jq -e '
        .schemaVersion == 2 and
        (.mediaType == "application/vnd.oci.image.manifest.v1+json" or
         .mediaType == "application/vnd.docker.distribution.manifest.v2+json") and
        (.manifests | not)
    ' >/dev/null <<< "$raw_manifest"; then
        return 1
    fi

    # shellcheck disable=SC2086
    config=$($SKOPEO inspect --config "docker://${source_ref}" 2>&1) || config_rc=$?
    if [[ "$config_rc" -ne 0 ]] || ! jq -e --arg architecture "$architecture" '
        .os == "linux" and .architecture == $architecture
    ' >/dev/null <<< "$config"; then
        return 1
    fi
}

copy_staging_manifest() {
    local source_ref="${1:-}"
    local destination_ref="${2:-}"
    local copy_rc=0

    # shellcheck disable=SC2086
    $SKOPEO copy --all --preserve-digests "docker://${source_ref}" "docker://${destination_ref}" || copy_rc=$?
    if [[ "$copy_rc" -ne 0 ]]; then
        log_error "Could not copy tested staging manifest $(_escape_gha_command "$source_ref") to $(_escape_gha_command "$destination_ref") (rc=$copy_rc)"
        return 1
    fi
}

# dry_run_command <command> [argument ...]
#
# Render a registry command without consulting the caller-overridable command
# variables. Escape every rendered token so registry- and owner-derived
# references cannot become GitHub Actions workflow commands in the log.
dry_run_command() {
    local argument

    printf 'DRY RUN:'
    for argument in "$@"; do
        printf ' %s' "$(_escape_gha_command "$argument")"
    done
    printf '\n'
}

main() {
    local extension=""
    local pg_major=""
    local version=""
    local baseline_digest=""
    local baseline_mode=""
    local amd64_digest=""
    local arm64_digest=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --extension|--pg-major|--version|--baseline-digest|--amd64-digest|--arm64-digest)
                if [[ $# -lt 2 ]]; then
                    log_error "Missing value for $(_escape_gha_command "$1")"
                    return 1
                fi
                case "$1" in
                    --extension) extension="$2" ;;
                    --pg-major) pg_major="$2" ;;
                    --version) version="$2" ;;
                    --baseline-digest)
                        if [[ -n "$baseline_mode" ]]; then
                            log_error "Specify exactly one of --baseline-digest or --no-canonical-index"
                            return 1
                        fi
                        baseline_digest="$2"
                        baseline_mode="digest"
                        ;;
                    --amd64-digest) amd64_digest="$2" ;;
                    --arm64-digest) arm64_digest="$2" ;;
                esac
                shift 2
                ;;
            --no-canonical-index)
                if [[ -n "$baseline_mode" ]]; then
                    log_error "Specify exactly one of --baseline-digest or --no-canonical-index"
                    return 1
                fi
                baseline_mode="absent"
                shift
                ;;
            -h|--help)
                usage
                return 0
                ;;
            *)
                log_error "Unknown argument: $(_escape_gha_command "$1")"
                usage >&2
                return 1
                ;;
        esac
    done

    if [[ ! "$extension" =~ ^[a-z0-9]+([._-][a-z0-9]+)*$ ]]; then
        log_error "--extension must be a lowercase extension package component"
        return 1
    fi
    if [[ ! "$pg_major" =~ ^[1-9][0-9]*$ ]]; then
        log_error "--pg-major must be a positive integer"
        return 1
    fi
    if [[ ! "$version" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
        log_error "--version must be a safe OCI tag component"
        return 1
    fi

    if [[ -z "$baseline_mode" ]]; then
        log_error "Specify exactly one of --baseline-digest or --no-canonical-index"
        return 1
    fi

    local digest digest_rc=0
    for digest in "$amd64_digest" "$arm64_digest"; do
        digest_rc=0
        is_valid_oci_digest "$digest" || digest_rc=$?
        if [[ "$digest_rc" -ne 0 ]]; then
            log_error "Promotion requires a valid baseline, amd64, and arm64 OCI digest"
            return 1
        fi
    done
    if [[ "$baseline_mode" == "digest" ]]; then
        digest_rc=0
        is_valid_oci_digest "$baseline_digest" || digest_rc=$?
        if [[ "$digest_rc" -ne 0 ]]; then
            log_error "Promotion requires a valid baseline, amd64, and arm64 OCI digest"
            return 1
        fi
    fi
    if [[ "$amd64_digest" == "$arm64_digest" ]]; then
        log_error "Promotion requires distinct amd64 and arm64 OCI digests"
        return 1
    fi

    # Package names are explicit here. EXTENSION_PACKAGE_SUFFIX is a global
    # reference-construction axis, so changing it for this process cannot name
    # the staging source and canonical destination at the same time.
    local registry owner canonical_repo staging_repo registry_rc=0 owner_rc=0
    registry=$(get_registry) || registry_rc=$?
    owner=$(get_repo_owner) || owner_rc=$?
    if [[ "$registry_rc" -ne 0 || "$owner_rc" -ne 0 || -z "$registry" || -z "$owner" ]]; then
        log_error "Could not determine the extension registry and owner"
        return 1
    fi
    canonical_repo="${registry}/${owner}/ext-${extension}"
    staging_repo="${registry}/${owner}/ext-${extension}-staging"

    local canonical_index_ref="${canonical_repo}:pg${pg_major}-${version}"
    local staging_amd64_ref="${staging_repo}@${amd64_digest}"
    local staging_arm64_ref="${staging_repo}@${arm64_digest}"
    local canonical_amd64_tag="${canonical_repo}:pg${pg_major}-${version}-amd64"
    local canonical_arm64_tag="${canonical_repo}:pg${pg_major}-${version}-arm64"

    if ! oci_tag_is_constructible "pg${pg_major}-${version}" ||
        ! oci_tag_is_constructible "pg${pg_major}-${version}-amd64" ||
        ! oci_tag_is_constructible "pg${pg_major}-${version}-arm64"; then
        log_error "Constructed canonical OCI tag exceeds the grammar or 128-character limit"
        return 1
    fi

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        dry_run_command skopeo inspect --format '{{.Digest}}' "docker://${staging_amd64_ref}"
        dry_run_command skopeo inspect --raw "docker://${staging_amd64_ref}"
        dry_run_command skopeo inspect --config "docker://${staging_amd64_ref}"
        dry_run_command skopeo inspect --format '{{.Digest}}' "docker://${staging_arm64_ref}"
        dry_run_command skopeo inspect --raw "docker://${staging_arm64_ref}"
        dry_run_command skopeo inspect --config "docker://${staging_arm64_ref}"
        dry_run_command skopeo inspect --format '{{.Digest}}' "docker://${canonical_index_ref}"
        dry_run_command skopeo copy --all --preserve-digests "docker://${staging_amd64_ref}" "docker://${canonical_amd64_tag}"
        dry_run_command skopeo inspect --format '{{.Digest}}' "docker://${canonical_amd64_tag}"
        dry_run_command skopeo copy --all --preserve-digests "docker://${staging_arm64_ref}" "docker://${canonical_arm64_tag}"
        dry_run_command skopeo inspect --format '{{.Digest}}' "docker://${canonical_arm64_tag}"
        dry_run_command docker buildx imagetools create -t "$canonical_index_ref" "${canonical_repo}@${amd64_digest}" "${canonical_repo}@${arm64_digest}"
        dry_run_command docker buildx imagetools inspect "$canonical_index_ref" --raw
        log_success "Dry run completed promotion of $(_escape_gha_command "$extension") pg$(_escape_gha_command "$pg_major") $(_escape_gha_command "$version")"
        return 0
    fi

    # Prove both frozen sources can be read before changing either canonical tag.
    local source_amd64_digest="" source_arm64_digest="" source_amd64_rc=0 source_arm64_rc=0
    source_amd64_digest=$(read_registry_digest "$staging_amd64_ref") || source_amd64_rc=$?
    if [[ "$source_amd64_rc" -ne 0 ]] || [[ "$source_amd64_digest" != "$amd64_digest" ]]; then
        log_error "Could not verify the frozen staging amd64 manifest; canonical tags remain unchanged"
        return 1
    fi
    if ! verify_staging_manifest "$staging_amd64_ref" "amd64"; then
        log_error "Frozen staging amd64 source was not a single linux/amd64 manifest; canonical tags remain unchanged"
        return 1
    fi
    source_arm64_digest=$(read_registry_digest "$staging_arm64_ref") || source_arm64_rc=$?
    if [[ "$source_arm64_rc" -ne 0 ]] || [[ "$source_arm64_digest" != "$arm64_digest" ]]; then
        log_error "Could not verify the frozen staging arm64 manifest; canonical tags remain unchanged"
        return 1
    fi
    if ! verify_staging_manifest "$staging_arm64_ref" "arm64"; then
        log_error "Frozen staging arm64 source was not a single linux/arm64 manifest; canonical tags remain unchanged"
        return 1
    fi

    # This is the lock-time conflict fence. A digest baseline must remain
    # unchanged; an absent baseline must remain absent. Either a new index or a
    # changed digest means another publisher acted while testing was in flight.
    local locked_digest="" locked_rc=0
    locked_digest=$(read_registry_digest "$canonical_index_ref") || locked_rc=$?
    case "$locked_rc" in
        0)
            case "$baseline_mode" in
                absent)
                    if canonical_index_has_requested_digests "$canonical_index_ref" "$amd64_digest" "$arm64_digest"; then
                        log_success "Recovered promotion: canonical index already contains the requested digests ($(_escape_gha_command "$locked_digest")); no write was needed"
                        return 0
                    fi
                    log_error "Canonical index appeared since testing (caller declared no canonical index, found $(_escape_gha_command "$locked_digest")); refusing before any canonical copy"
                    return 1
                    ;;
                digest)
                    if [[ "$locked_digest" != "$baseline_digest" ]]; then
                        if canonical_index_has_requested_digests "$canonical_index_ref" "$amd64_digest" "$arm64_digest"; then
                            log_success "Recovered promotion: canonical index already contains the requested digests ($(_escape_gha_command "$locked_digest")); no write was needed"
                            return 0
                        fi
                        log_error "Canonical index changed since testing (expected $(_escape_gha_command "$baseline_digest"), found $(_escape_gha_command "$locked_digest")); refusing before any canonical copy"
                        return 1
                    fi
                    ;;
            esac
            ;;
        1)
            if [[ "$baseline_mode" == "digest" ]]; then
                log_error "Canonical index disappeared since testing (expected $(_escape_gha_command "$baseline_digest")); refusing before any canonical copy"
                return 1
            fi
            ;;
        *)
            log_error "Could not read the canonical index under the promotion lock; refusing to write"
            return 1
            ;;
    esac

    local copy_rc=0
    copy_staging_manifest "$staging_amd64_ref" "$canonical_amd64_tag" || copy_rc=$?
    if [[ "$copy_rc" -ne 0 ]]; then
        return 1
    fi

    # This is an integrity tripwire for our own reference construction, not a
    # security boundary: a party able to substitute this digest can write the
    # canonical package directly and can rewrite the tag after this check.
    local destination_amd64_digest="" destination_rc=0
    destination_amd64_digest=$(read_registry_digest "$canonical_amd64_tag") || destination_rc=$?
    if [[ "$destination_rc" -ne 0 ]] || [[ "$destination_amd64_digest" != "$amd64_digest" ]]; then
        log_error "Canonical amd64 destination digest did not match the tested source (integrity tripwire); stopping before index publication"
        return 1
    fi

    copy_rc=0
    copy_staging_manifest "$staging_arm64_ref" "$canonical_arm64_tag" || copy_rc=$?
    if [[ "$copy_rc" -ne 0 ]]; then
        return 1
    fi

    local destination_arm64_digest=""
    destination_rc=0
    destination_arm64_digest=$(read_registry_digest "$canonical_arm64_tag") || destination_rc=$?
    if [[ "$destination_rc" -ne 0 ]] || [[ "$destination_arm64_digest" != "$arm64_digest" ]]; then
        log_error "Canonical arm64 destination digest did not match the tested source (integrity tripwire); stopping before index publication"
        return 1
    fi

    local published_digest="" publish_rc=0
    published_digest=$(publish_extension_index_from_digests \
        "$canonical_index_ref" \
        "${canonical_repo}@${destination_amd64_digest}" \
        "${canonical_repo}@${destination_arm64_digest}") || publish_rc=$?
    case "$publish_rc" in
        0) ;;
        2)
            log_error "Canonical extension index was published but could not be verified"
            return 1
            ;;
        3)
            log_error "Canonical extension index publication outcome is unknown; canonical state may have changed"
            return 1
            ;;
        *)
            log_error "Canonical extension index was not published"
            return 1
            ;;
    esac

    # This is deliberately post-publication. An equal digest is not rolled
    # back: the canonical tags already describe the same bytes. An absent
    # baseline has no bytes to compare, so this check applies only to a digest
    # baseline.
    if [[ "$baseline_mode" == "digest" && "$published_digest" == "$baseline_digest" ]]; then
        log_error "Promotion published an index identical to the pre-test baseline; reporting failed rotation without rollback"
        return 1
    fi

    log_success "Promoted $(_escape_gha_command "$extension") pg$(_escape_gha_command "$pg_major") $(_escape_gha_command "$version"): $(_escape_gha_command "$published_digest")"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
