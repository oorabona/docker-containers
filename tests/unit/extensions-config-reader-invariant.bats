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
    rg '\byq -[A-Za-z]' "$file" | wc -l | tr -d '[:space:]'
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

    run rg -n 'validate_extensions_schema "\$config_file"' "$PROJECT_ROOT/helpers/extension-utils.sh"
    [ "$status" -eq 0 ]
}
