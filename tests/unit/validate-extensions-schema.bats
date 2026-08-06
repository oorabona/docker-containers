#!/usr/bin/env bats

# Unit tests for the single-pass PostgreSQL extensions-config schema guard.

bats_require_minimum_version 1.5.0

load "../test_helper"

setup() {
    source "$HELPERS_DIR/validate-extensions-schema.sh"
    FIXTURES_DIR="$PROJECT_ROOT/tests/fixtures/extensions-schema"
}

assert_rejected_fixture() {
    local fixture="$1"
    local expected="$2"

    run validate_extensions_schema "$FIXTURES_DIR/$fixture"
    [ "$status" -ne 0 ]
    [[ "$output" == *"$expected"* ]]
}

@test "real PostgreSQL extension config passes the schema guard" {
    run validate_extensions_schema "$PROJECT_ROOT/postgres/extensions/config.yaml"

    [ "$status" -eq 0 ]
}

@test "R1 rejects non-name flavor keys, scalars, non-name members, and duplicate members" {
    assert_rejected_fixture "flavor-bad-key.yaml" "R1 flavor key"
    assert_rejected_fixture "flavor-scalar.yaml" "R1 flavor"
    assert_rejected_fixture "flavor-member-metacharacter.yaml" "must be a name-shaped string"
    assert_rejected_fixture "flavor-duplicate-member.yaml" "lists a member more than once"
}

@test "R2 rejects flavor members that name no declared extension" {
    assert_rejected_fixture "flavor-undeclared-member.yaml" "R2 flavor"
}

@test "R3 rejects non-name extension keys" {
    assert_rejected_fixture "extension-bad-key.yaml" "R3 extension key"
}

@test "R4 rejects missing or invalid initdb modes and invalid create SQL names" {
    assert_rejected_fixture "initdb-mode-missing.yaml" "R4 extension"
    assert_rejected_fixture "initdb-mode-invalid.yaml" "R4 extension"
    assert_rejected_fixture "sql-name-invalid.yaml" "invalid SQL name"
}

# The rule is about the name that reaches PostgreSQL, which is the extension key
# whenever `sql_name` is absent. Checking only the declared `sql_name` let a key
# like `foo-bar` or `123ext` pass and emit `CREATE EXTENSION foo-bar;`, failing at
# initdb — the inline check this validator replaced did validate the resolved name.
@test "R4 rejects a key that is not an identifier when no sql_name rescues it" {
    assert_rejected_fixture "implicit-sql-name.yaml" "invalid SQL name"
}

# PostgreSQL stores 63 bytes of an identifier and TRUNCATES the rest — measured
# with `SHOW max_identifier_length` on the image this repository ships, and it
# truncates the quoted form as readily as the bare one. A 64-byte name would have
# the build check a control filename the server never opens. The boundary is
# asserted from both sides: a limit tested only where it rejects passes equally
# well when it rejects everything.
@test "R4 rejects a SQL name longer than PostgreSQL's 63 bytes" {
    assert_rejected_fixture "sql-name-too-long.yaml" "invalid SQL name"
}

@test "R4 accepts a SQL name of exactly 63 bytes" {
    run validate_extensions_schema "$FIXTURES_DIR/sql-name-at-limit.yaml"
    [ "$status" -eq 0 ]
}

@test "R5 rejects manual policies without a non-empty reason" {
    assert_rejected_fixture "manual-reason-empty.yaml" "R5 extension"
}

@test "R6 rejects SQL names that collide within one flavor" {
    assert_rejected_fixture "duplicate-sql-name.yaml" "R6 flavor"
}

@test "R7 rejects SQL names already created by the built-in initdb block" {
    assert_rejected_fixture "builtin-sql-collision.yaml" "R7 flavor"
}

@test "yamllint key-duplicates rejects duplicate mapping keys before yq parses them" {
    run yamllint -c "$PROJECT_ROOT/.yamllint.yml" "$FIXTURES_DIR/duplicate-mapping-key.yaml"

    [ "$status" -ne 0 ]
    [[ "$output" == *"duplication of key"* ]]
}

# The half yamllint cannot reach. `!!str vector:` beside `vector:` is textually
# distinct, so the text rule accepts it; the JSON conversion then writes the key
# twice and the last wins, so no rule downstream sees that there were two. The
# guard runs on the YAML side, where both are still visible.
@test "a duplicate spelled with a YAML tag is rejected, though yamllint accepts it" {
    run yamllint -c "$PROJECT_ROOT/.yamllint.yml" "$FIXTURES_DIR/tagged-duplicate-key.yaml"
    [ "$status" -eq 0 ]

    run validate_extensions_schema "$FIXTURES_DIR/tagged-duplicate-key.yaml"
    [ "$status" -ne 0 ]
    [[ "$output" == *"declares the same name more than once"* ]]
}

# The same trick at the document root. Checking only inside the sections left
# `!!str flavors:` beside `flavors:` open: every rule validated one mapping while
# the generator read the other.
@test "a tagged duplicate of a top-level key is rejected" {
    run yamllint -c "$PROJECT_ROOT/.yamllint.yml" "$FIXTURES_DIR/tagged-duplicate-root-key.yaml"
    [ "$status" -eq 0 ]

    run validate_extensions_schema "$FIXTURES_DIR/tagged-duplicate-root-key.yaml"
    [ "$status" -ne 0 ]
    [[ "$output" == *"same top-level name more than once"* ]]
}

# jq's `$` matches before one trailing newline, so a block scalar slipped
# "vector\n" past the identifier pattern. The generator strips it through command
# substitution, so validation saw two names where the build emits one.
@test "a SQL name with a trailing newline is rejected" {
    assert_rejected_fixture "trailing-newline-sql-name.yaml" "invalid SQL name"
}

# A collision needs two names reaching one image. A disabled extension reaches
# none, so sharing a SQL name with an active one is not a collision.
@test "a disabled extension sharing a SQL name is not a collision" {
    run validate_extensions_schema "$FIXTURES_DIR/disabled-sql-name-shared.yaml"
    [ "$status" -eq 0 ]
}
