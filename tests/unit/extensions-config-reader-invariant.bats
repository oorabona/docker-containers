#!/usr/bin/env bats

# The generator's extension field reads are intentionally confined to these
# two helpers. generate_dockerfile validates its config before extension-utils
# reads it; version-set-resolver is a compatibility reader with its own narrow
# version-set purpose. A new field read belongs in the schema guard first.

bats_require_minimum_version 1.5.0

load "../test_helper"

_direct_yq_read_count() {
    local file="$1"

    # Count only yq invocations, not comments, command-existence checks, or
    # log messages. Continuation lines belong to the yq command that begins on
    # the previous line, so counting its start is sufficient.
    #
    # grep, not rg: the runner has no ripgrep, and a guard that cannot run must
    # fail rather than pass — which is what it did, at the cost of a CI round.
    # -E for the word boundary, which BRE spells differently across greps.
    #
    # grep -c exits 1 on no match and 2 on a real error. Only the first is a
    # count of zero; the second must not be reported as one, so it propagates.
    local count status=0
    count=$(grep -cE '\byq -[A-Za-z]' "$file") || status=$?
    if (( status > 1 )); then
        echo "grep failed reading $file (status $status)" >&3
        return "$status"
    fi
    printf '%s' "${count//[[:space:]]/}"
}

@test "extension config has no new direct yq readers outside the sanctioned 16 plus 3" {
    local extension_utils_reads
    local resolver_reads

    extension_utils_reads=$(_direct_yq_read_count "$PROJECT_ROOT/helpers/extension-utils.sh")
    resolver_reads=$(_direct_yq_read_count "$PROJECT_ROOT/helpers/version-set-resolver.sh")

    if [[ "$extension_utils_reads" != "16" || "$resolver_reads" != "3" ]]; then
        echo "unexpected extension-config yq reader count: extension-utils=${extension_utils_reads}, version-set-resolver=${resolver_reads}; put new declaration validation in helpers/validate-extensions-schema.sh before adding a reader" >&3
        false
    fi

    run grep -n 'validate_extensions_schema "\$config_file"' "$PROJECT_ROOT/helpers/extension-utils.sh"
    [ "$status" -eq 0 ]
}
