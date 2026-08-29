#!/usr/bin/env bash
# Resolve an image reference to one declared build cell.  The build matrix is
# the source of truth for cells and generated tags; this harness only looks one
# up and derives the component version from that declared value.

set -euo pipefail

# _image_identity_emit_record <reference> <tag> <version> <variant> <flavor> <container-dir>
_image_identity_emit_record() {
    local reference="$1" tag="$2" version="$3" variant="$4" flavor="$5" container_dir="$6"
    local version_suffix component_version kind record

    if [[ ! -x "$container_dir/version.sh" ]]; then
        printf 'image identity: cannot execute %s/version.sh --tag-suffix\n' "$container_dir" >&2
        return 1
    fi
    if ! version_suffix=$("$container_dir/version.sh" --tag-suffix); then
        printf 'image identity: %s/version.sh --tag-suffix failed\n' "$container_dir" >&2
        return 1
    fi
    if [[ "$version_suffix" == *$'\n'* ]]; then
        printf 'image identity: %s/version.sh --tag-suffix returned more than one line\n' "$container_dir" >&2
        return 1
    fi

    component_version="$version"
    if [[ -n "$version_suffix" && "$component_version" == *"$version_suffix" ]]; then
        component_version="${component_version%"$version_suffix"}"
    fi
    component_version="${component_version#v}"
    if [[ -z "$component_version" || "$component_version" == "latest" ]]; then
        printf 'image identity: %s is a moving alias, not a declared version\n' "$version" >&2
        return 1
    fi

    kind="variant"
    if [[ -z "$variant" && -z "$flavor" ]]; then
        kind="single"
    fi
    if ! record=$(jq -c -n -e -r \
        --arg reference "$reference" --arg tag "$tag" --arg component_version "$component_version" \
        --arg kind "$kind" --arg variant "$variant" --arg flavor "$flavor" '
        def nonempty_string: type == "string" and length > 0;
        {reference: $reference, tag: $tag, component_version: $component_version,
         kind: $kind,
         variant: (if $kind == "single" then null else $variant end),
         flavor: (if $kind == "single" then null else $flavor end)} as $record |
        if ($record.reference | nonempty_string) and ($record.tag | nonempty_string) and
           ($record.component_version | nonempty_string) and
           (($record.kind == "single" and $record.variant == null and $record.flavor == null) or
            ($record.kind == "variant" and ($record.variant | nonempty_string) and ($record.flavor | type == "string"))) then
          $record
        else error("invalid declared build cell") end
    '); then
        printf 'image identity: invalid declared build cell\n' >&2
        return 1
    fi
    printf '%s\n' "$record"
}

# image_identity_resolve <container-dir> <image-reference> [selected-cell]
#
# Writes one JSON record on stdout:
#   {reference, tag, component_version, kind, variant, flavor}
#
# The workflow passes E2E_BUILD_{TAG,VERSION,VARIANT,FLAVOR} for its exact build
# cell.  When those are present they are authoritative: do not parse the image
# reference or inspect declarations again. Manual callers fall back to matching
# the reference tag against helpers/variant-utils.sh::list_build_matrix. The e2e
# harness may pass the cell it already selected from that matrix, avoiding a
# second enumeration of the same retained cells.
image_identity_resolve() {
    local container_dir="$1" reference="$2" selected_cell="${3:-}"

    if [[ -n "${E2E_BUILD_TAG+x}${E2E_BUILD_VERSION+x}${E2E_BUILD_VARIANT+x}${E2E_BUILD_FLAVOR+x}" ]]; then
        if [[ -z "${E2E_BUILD_TAG+x}" || -z "${E2E_BUILD_VERSION+x}" || -z "${E2E_BUILD_VARIANT+x}" || -z "${E2E_BUILD_FLAVOR+x}" ]]; then
            printf 'image identity: pass all E2E_BUILD_TAG, E2E_BUILD_VERSION, E2E_BUILD_VARIANT, and E2E_BUILD_FLAVOR\n' >&2
            return 1
        fi
        _image_identity_emit_record "$reference" "$E2E_BUILD_TAG" "$E2E_BUILD_VERSION" \
            "$E2E_BUILD_VARIANT" "$E2E_BUILD_FLAVOR" "$container_dir"
        return
    fi

    if [[ ! -r "$container_dir/variants.yaml" ]]; then
        printf 'image identity: cannot read %s/variants.yaml\n' "$container_dir" >&2
        return 1
    fi

    # This is deliberately a declared-cell parser, not an OCI reference
    # validator. Its bounded job is deciding whether a reference names a
    # declared cell; Docker remains responsible for full reference grammar.
    # A tag plus digest could name a manifest different from the tag's current
    # declaration, so only an explicitly passed build cell can identify it.
    local last_segment tag name_without_tag image_name expected_name
    if [[ "$reference" == *"@"* ]]; then
        printf 'image identity: %s has a digest; pass the build cell explicitly\n' "$reference" >&2
        return 1
    fi
    if [[ -z "$reference" || "$reference" =~ ^[[:alpha:]][[:alnum:].+-]*:// ]]; then
        printf 'image identity: %s has an invalid image name\n' "$reference" >&2
        return 1
    fi
    last_segment="${reference##*/}"
    if [[ "$last_segment" != *:* || "${last_segment##*:}" == "$last_segment" ]]; then
        printf 'image identity: %s has no tag (digest-only references are not declared cells)\n' "$reference" >&2
        return 1
    fi
    tag="${last_segment##*:}"
    name_without_tag="${reference%:*}"
    if [[ -z "$tag" || -z "$name_without_tag" ]]; then
        printf 'image identity: %s has an empty image name or tag\n' "$reference" >&2
        return 1
    fi
    image_name="${name_without_tag##*/}"
    expected_name="${container_dir##*/}"
    if [[ "$image_name" != "$expected_name" ]]; then
        printf 'image identity: %s does not name container %s\n' "$reference" "$expected_name" >&2
        return 1
    fi

    local harness_dir matrix real_version cell version variant flavor
    harness_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -n "$selected_cell" ]]; then
        # This is an internal hand-off from resolve_e2e_image. It still has to
        # name the reference tag exactly, so an unrelated selected cell cannot
        # be attached to this image accidentally.
        if ! cell=$(jq -c -e -r --arg tag "$tag" '
            if type == "object" and .tag == $tag then .
            else error("does not name the reference tag") end
        ' <<<"$selected_cell"); then
            printf 'image identity: %s does not resolve to one declared cell\n' "$reference" >&2
            return 1
        fi
    else
        # Match the workflow's latest declaration handling: it resolves the
        # current version and falls back to the literal latest only if that
        # resolution is unavailable. Pinned declarations need no live lookup.
        real_version=""
        if yq -e '.versions[]? | select(.tag == "latest")' "$container_dir/variants.yaml" >/dev/null 2>&1; then
            if ! real_version=$(cd "$container_dir" && ./version.sh 2>/dev/null); then
                real_version="latest"
            fi
            if [[ -z "$real_version" || "$real_version" == "unknown" ]]; then
                real_version="latest"
            fi
        fi
        # Source the same enumerator the workflow uses. Resolution asks whether
        # this names any declared cell, including retained versions that are
        # still published; the default matrix view is only the latest version.
        # The subshell keeps its shell options out of test suites that source
        # this resolver directly.
        if ! matrix=$(source "$harness_dir/../helpers/variant-utils.sh" && list_build_matrix "$container_dir" "$real_version" true 2>/dev/null); then
            printf 'image identity: list_build_matrix failed for %s\n' "$container_dir" >&2
            return 1
        fi
        if ! cell=$(jq -c -e -r --arg tag "$tag" '
            if type != "array" then error("build matrix is not an array")
            else [.[] | select(.tag == $tag)] as $matches |
              if ($matches | length) == 1 then $matches[0]
              elif ($matches | length) == 0 then error("does not name a declared cell")
              else error("matches more than one declared cell") end
            end
        ' <<<"$matrix"); then
            printf 'image identity: %s does not resolve to one declared cell\n' "$reference" >&2
            return 1
        fi
    fi
    if ! version=$(jq -er '.version | strings' <<<"$cell") || \
        ! variant=$(jq -er '.variant | strings' <<<"$cell") || \
        ! flavor=$(jq -er '.flavor | strings' <<<"$cell"); then
        printf 'image identity: %s has an invalid declared build cell\n' "$reference" >&2
        return 1
    fi
    _image_identity_emit_record "$reference" "$tag" "$version" "$variant" "$flavor" "$container_dir"
}

_image_identity_record_field() {
    local field="$1"
    # E2E_IMAGE_IDENTITY is an internal harness-to-suite channel. This
    # structural check catches a harness bug; it is not a trust boundary for a
    # hand-forged record, so it deliberately does not re-resolve cross-fields.
    jq -er --arg field "$field" '
        def nonempty_string: type == "string" and length > 0;
        if (.reference | nonempty_string) and (.tag | nonempty_string) and
           (.component_version | nonempty_string) and
           ((.kind == "single" and .variant == null and .flavor == null) or
            (.kind == "variant" and (.variant | nonempty_string) and (.flavor | type == "string"))) then
          .[$field]
        else error("invalid image identity record") end
    ' <<<"${E2E_IMAGE_IDENTITY:-}" 2>/dev/null
}

_image_identity_numeric_versions_equivalent() (
    local actual="$1" expected="$2"
    local numeric_dotted_pattern='^[0-9]+([.][0-9]+)*$'
    local harness_dir helper actual_greater_status expected_greater_status

    [[ "$actual" =~ $numeric_dotted_pattern && "$expected" =~ $numeric_dotted_pattern ]] || return 1

    harness_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 2
    helper="$harness_dir/../helpers/version-utils.sh"
    [[ -r "$helper" ]] || return 2
    # shellcheck source=../helpers/version-utils.sh
    if ! source "$helper" >/dev/null 2>&1; then
        return 2
    fi
    # This detects a helper that loaded but supplied no comparator only when no
    # same-name function was already present; it does not establish provenance.
    declare -F version_is_greater >/dev/null || return 2

    if version_is_greater "$actual" "$expected"; then
        actual_greater_status=0
    else
        actual_greater_status=$?
    fi
    if version_is_greater "$expected" "$actual"; then
        expected_greater_status=0
    else
        expected_greater_status=$?
    fi
    (( actual_greater_status == 1 && expected_greater_status == 1 ))
)

# Harness assertions for container suites. Suites pass their observed value;
# they never parse an image reference or the identity record themselves.
e2e_assert_reported_component_version() {
    local actual="$1" expected numeric_comparison_status
    if ! expected=$(_image_identity_record_field component_version); then
        th_fail "the reported component version has resolved image identity" \
            "the harness did not provide a valid resolved image identity"
        return 0
    fi

    if [[ "$actual" == "$expected" ]]; then
        th_pass "the reported component version matches the resolved image release ($expected)"
        return 0
    fi

    if _image_identity_numeric_versions_equivalent "$actual" "$expected"; then
        th_pass "the reported component version matches the resolved image release ($expected)"
        return 0
    else
        numeric_comparison_status=$?
    fi
    if (( numeric_comparison_status == 2 )); then
        th_fail "the reported component version matches the resolved image release ($expected)" \
            "required helper version-utils.sh is unavailable"
        return 0
    fi

    th_fail "the reported component version matches the resolved image release ($expected)" \
        "expected: '$expected', got: '$actual'"
}

e2e_assert_declared_variant() {
    local actual="$1" expected kind
    if ! kind=$(_image_identity_record_field kind) || [[ "$kind" != "variant" ]] || ! expected=$(_image_identity_record_field variant); then
        th_fail "the image reports the resolved declared variant" \
            "the resolved image is not a variant cell"
        return 0
    fi
    th_assert_eq "the image reports the resolved declared variant ($expected)" "$actual" "$expected"
}

e2e_assert_declared_flavor() {
    local actual="$1" expected kind
    if ! kind=$(_image_identity_record_field kind) || [[ "$kind" != "variant" ]] || ! expected=$(_image_identity_record_field flavor); then
        th_fail "the image reports the resolved declared flavor" \
            "the resolved image is not a variant cell"
        return 0
    fi
    th_assert_eq "the image reports the resolved declared flavor ($expected)" "$actual" "$expected"
}
