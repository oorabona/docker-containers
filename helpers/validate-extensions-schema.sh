#!/bin/bash
# validate-extensions-schema.sh
# Static schema-validation guard for postgres/extensions/config.yaml.
#
# Enforces the extension declaration invariants before a generator reads any
# field. Called by generate_dockerfile and by validate-version-scripts.sh.
#
# Rules enforced:
#   R1. flavors must be a mapping. Each key must match ^[A-Za-z0-9_-]+$ and
#       each value must be a list of unique name-shaped strings.
#   R2. Every flavor member must name a declared extension.
#   R3. extensions must be a mapping. Each key must match ^[A-Za-z0-9_-]+$.
#   R4. Each compiled extension must declare exactly one initdb.mode, either
#       create or manual. create may carry sql_name only when it matches the
#       folded PostgreSQL unquoted-identifier form ^[a-z_][a-z0-9_]*$.
#   R5. A manual initdb policy must carry a non-empty string initdb.reason.
#   R6. Within a flavor, no create-mode extensions may resolve to the same SQL
#       name (sql_name, or the extension key when sql_name is absent).
#   R7. A create-mode SQL name may not collide with a name already created by
#       the built-in 00-init-extensions.sql block (builtin_extensions).
#
# Duplicate YAML mapping keys are intentionally outside this parsed-document
# guard: the YAML parser discards the first value. .yamllint.yml enables
# yamllint's key-duplicates rule against config.yaml and variants.yaml files.
#
# Usage:
#   source helpers/validate-extensions-schema.sh
#   validate_extensions_schema <extensions_config_file>  # -> 0 = ok, 1 = error
#
# Note: intentionally does NOT set -euo pipefail — this file is sourced into
# callers which manage their own error-handling mode.

# ---------------------------------------------------------------------------
# validate_extensions_schema <extensions_config_file>
#
# Makes one yq pass over the parsed document and reports every schema error to
# stderr. A yq parse/read failure is a validation failure (fail closed).
# ---------------------------------------------------------------------------
validate_extensions_schema() {
    local config_file="$1"
    local document
    local errors
    local error

    command -v yq >/dev/null 2>&1 || {
        printf 'ERROR [extensions schema]: yq is required but was not found in PATH.\n' >&2
        return 1
    }

    if [[ ! -f "$config_file" ]]; then
        printf 'ERROR [extensions schema]: config file not found: %s\n' "$config_file" >&2
        return 1
    fi

    # Two entries resolving to one name, before the conversion below erases the
    # evidence. yq keeps both in the YAML document; emitting JSON writes the key
    # twice and jq keeps the last, so no rule downstream can see that there were
    # two. The yamllint gate does not see it either: it reads the raw text, and
    # `!!str vector:` beside `vector:` is textually distinct. What is left is
    # this — the parsed key count against its distinct count, on the YAML side,
    # which is spelling-independent in a way no text rule can be.
    local _dup_section
    for _dup_section in flavors extensions; do
        local _keys _distinct
        _keys=$(sec="$_dup_section" yq -r '.[strenv(sec)] | select(tag == "!!map") | keys | length' \
            "$config_file" 2>/dev/null) || _keys=""
        _distinct=$(sec="$_dup_section" yq -r '.[strenv(sec)] | select(tag == "!!map") | keys | unique | length' \
            "$config_file" 2>/dev/null) || _distinct=""
        if [[ -n "$_keys" && -n "$_distinct" && "$_keys" != "$_distinct" ]]; then
            printf 'ERROR [extensions schema] %s: %s declares the same name more than once (%s entries, %s distinct)\n' \
                "$config_file" "$_dup_section" "$_keys" "$_distinct" >&2
            return 1
        fi
    done

    # yq reads and parses the YAML exactly once. jq validates the resulting
    # JSON document, preserving YAML strings as strings rather than asking yq
    # to parse any environment input with env().
    if ! document=$(yq -o=json '.' "$config_file" 2>&1); then
        printf 'ERROR [extensions schema]: yq could not parse or read %s:\n%s\n' \
            "$config_file" "$document" >&2
        return 1
    fi

    command -v jq >/dev/null 2>&1 || {
        printf 'ERROR [extensions schema]: jq is required but was not found in PATH.\n' >&2
        return 1
    }

    if ! errors=$(jq -r '
        # \A and \z, not ^ and $: jq accepts one trailing newline before $, so
        # `sql_name: |` followed by `vector` yields "vector\n" and passes. The
        # generator captures that through command substitution, which strips the
        # newline — so validation sees two distinct names where the build sees
        # one, and a collision check comparing them finds nothing to report.
        def name_shaped: type == "string" and test("\\A[A-Za-z0-9_-]+\\z");
        def sql_identifier: type == "string" and test("\\A[a-z_][a-z0-9_]*\\z");
        def valid_flavor_members: type == "array" and all(.[]; name_shaped);
        def valid_extension_entry:
          type == "object"
          and (.initdb | type == "object")
          and (.initdb | has("mode"))
          and (.initdb.mode | type == "string")
          and (.initdb.mode == "create" or .initdb.mode == "manual");
        . as $root
        | [
            if ($root.flavors | type) != "object" then
              "R1 flavors must be a mapping"
            else empty end,
            if ($root.extensions | type) != "object" then
              "R3 extensions must be a mapping"
            else empty end,

            # Two entries resolving to one name, whatever their spelling. The
            # yamllint gate catches a textually duplicated key; it does not catch
            # `!!str vector:` beside `vector:`, which it accepts and yq keeps as
            # two entries whose lookup returns the last. `to_entries` then
            # validates both while the generator reads only one, so the image
            # comes out with no extensions under that name. Comparing the parsed
            # key count to its distinct count is spelling-independent, which no
            # rule over the raw text can be.
            if (($root.flavors | type) == "object")
               and (($root.flavors | keys | length) != ($root.flavors | keys | unique | length)) then
              "R1 flavors declares the same name more than once after parsing"
            else empty end,
            if (($root.extensions | type) == "object")
               and (($root.extensions | keys | length) != ($root.extensions | keys | unique | length)) then
              "R3 extensions declares the same name more than once after parsing"
            else empty end,

            if ($root.flavors | type) == "object" then
              $root.flavors | to_entries[] | . as $flavor
              | if ($flavor.key | name_shaped) then empty
                else "R1 flavor key " + ($flavor.key | @json) + " is not name-shaped" end,
                if ($flavor.value | type) == "array" then empty
                else "R1 flavor " + ($flavor.key | @json) + " must be a list" end,
                if ($flavor.value | type) == "array" then
                  $flavor.value | to_entries[] | . as $member
                  | if ($member.value | name_shaped) then empty
                    else "R1 flavor " + ($flavor.key | @json) + " member "
                         + ($member.key | tostring) + " must be a name-shaped string" end
                else empty end,
                if ($flavor.value | valid_flavor_members) then
                  if (($flavor.value | length) == ($flavor.value | unique | length)) then empty
                  else "R1 flavor " + ($flavor.key | @json) + " lists a member more than once" end
                else empty end,
                if (($root.extensions | type) == "object") and ($flavor.value | valid_flavor_members) then
                  $flavor.value[] | . as $member
                  | if ($root.extensions | has($member)) then empty
                    else "R2 flavor " + ($flavor.key | @json) + " names undeclared extension "
                         + ($member | @json) end
                else empty end
            else empty end,

            if ($root.extensions | type) == "object" then
              $root.extensions | to_entries[] | . as $extension
              | if ($extension.key | name_shaped) then empty
                else "R3 extension key " + ($extension.key | @json) + " is not name-shaped" end,
                if ($extension.value | valid_extension_entry) then empty
                else "R4 extension " + ($extension.key | @json)
                     + " must declare initdb.mode exactly once as create or manual" end,
                if (($extension.value | valid_extension_entry)
                    and $extension.value.initdb.mode == "create"
                    and (((if ($extension.value.initdb | has("sql_name"))
                           then $extension.value.initdb.sql_name
                           else $extension.key end) | sql_identifier) | not)) then
                  "R4 extension " + ($extension.key | @json)
                  + " resolves to an invalid SQL name (expected ^[a-z_][a-z0-9_]*$)"
                else empty end,
                if (($extension.value | valid_extension_entry)
                    and $extension.value.initdb.mode == "manual"
                    and ((($extension.value.initdb | has("reason")) | not)
                         or ($extension.value.initdb.reason | type != "string")
                         or ($extension.value.initdb.reason | length == 0))) then
                  "R5 extension " + ($extension.key | @json)
                  + " has initdb.mode manual but no non-empty initdb.reason"
                else empty end
            else empty end,

            if (($root.flavors | type) == "object") and (($root.extensions | type) == "object") then
              $root.flavors | to_entries[] | . as $flavor
              | select($flavor.value | valid_flavor_members)
              | [ $flavor.value[] | . as $member
                  | select($root.extensions | has($member))
                  | select($root.extensions[$member] | valid_extension_entry)
                  | select($root.extensions[$member].initdb.mode == "create")
                  # A collision needs two names that both reach one image. An
                  # extension the generator filters out — disabled outright —
                  # reaches none, so rejecting a config for a name it shares with
                  # an active one refuses something that cannot happen. The
                  # version cap is not applied here because this validation is
                  # per-document, not per-PostgreSQL-major; a name capped out of
                  # one major still collides in another.
                  | select($root.extensions[$member].disabled != true)
                  | ($root.extensions[$member].initdb.sql_name // $member) ] as $sql_names
              | (($root.builtin_extensions // []) | if type == "array" then . else [] end) as $builtins
              | (
                  $sql_names | group_by(.) | map(select(length > 1) | .[0])[]
                  | "R6 flavor " + ($flavor.key | @json)
                    + " resolves more than one extension to SQL name " + (. | @json)
                ),
                (
                  $sql_names[] as $sql_name | select($builtins | index($sql_name) != null)
                  | "R7 flavor " + ($flavor.key | @json)
                    + " resolves an extension to built-in SQL name " + ($sql_name | @json)
                )
            else empty end
          ]
        | .[]
    ' <<< "$document" 2>&1); then
        printf 'ERROR [extensions schema]: jq could not validate %s:\n%s\n' \
            "$config_file" "$errors" >&2
        return 1
    fi

    if [[ -n "$errors" ]]; then
        while IFS= read -r error; do
            [[ -n "$error" ]] || continue
            printf 'ERROR [extensions schema] %s: %s\n' "$config_file" "$error" >&2
        done <<< "$errors"
        return 1
    fi

    return 0
}

export -f validate_extensions_schema
