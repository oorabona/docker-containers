#!/usr/bin/env bats

# Generator-level coverage for the generated PostgreSQL flavor install block.
# The expected extension lists are read from the real configuration so this
# fails when a flavor gains an extension without a generated install call.

bats_require_minimum_version 1.5.0

load "../test_helper"

_source_extension_utils() {
    # shellcheck disable=SC1091
    source "$HELPERS_DIR/extension-utils.sh"
}

_write_timescaledb_versionset() {
    local version
    version=$(yq -r '.extensions.timescaledb.version' "$CONFIG_FILE")
    printf '%s\n' \
        "{\"ext\":\"timescaledb\",\"pg_major\":\"18\",\"ceiling\":\"${version}\",\"resolved\":[\"${version}\"],\"available\":[\"${version}\"],\"excluded\":[]}" \
        > "$ROOT_DIR/.build-lineage/ext-timescaledb-pg18-versionset.json"
}

_generate() {
    local flavor="$1"
    local generated_file="$2"

    generate_dockerfile \
        "$CONFIG_FILE" \
        "$PROJECT_ROOT/postgres/Dockerfile" \
        "$flavor" \
        18 \
        ghcr.io \
        testowner \
        > "$generated_file"
}

_initdb_sql_block() {
    local generated_file="$1"

    sed -n \
        '/-- .* flavor: compiled extensions/,/01-init-flavor.sql/p' \
        "$generated_file"
}

_flavor_initdb_block() {
    local generated_file="$1"

    awk '
        /^RUN set -eux; \\$/ {
            candidate = $0 ORS
            collecting = 1
            next
        }
        collecting {
            candidate = candidate $0 ORS
        }
        collecting && /-- .* flavor: compiled extensions/ {
            printf "%s", candidate
            collecting = 0
            emitting = 1
            next
        }
        emitting {
            print
            if (/01-init-flavor\.sql/) {
                exit
            }
        }
    ' "$generated_file"
}

_extract_flavor_initdb_shell() {
    local generated_file="$1"
    local shell_file="$2"
    local sql_file="$3"

    printf '%s\n' '#!/bin/sh' > "$shell_file"
    _flavor_initdb_block "$generated_file" \
        | sed -e '1s/^RUN //' -e 's/; \\$//' \
            -e "s|/docker-entrypoint-initdb.d/01-init-flavor.sql|$sql_file|g" \
        >> "$shell_file"
    chmod +x "$shell_file"
}

_mock_pg_config_sharedir() {
    local sharedir="$1"

    mkdir -p "$TEST_TEMP_DIR/bin"
    printf '%s\n' '#!/bin/sh' "printf '%s\\n' '$sharedir'" \
        > "$TEST_TEMP_DIR/bin/pg_config"
    chmod +x "$TEST_TEMP_DIR/bin/pg_config"
    _mock_gosu
}

# The generated block asks `gosu postgres test -r …` because the build runs as
# root and PostgreSQL does not, and root reads files the server cannot. There is
# no postgres user here and no privilege to drop, so the stub drops the username
# and runs the rest as whoever is running the suite — which still distinguishes a
# readable file from an unreadable one, as long as that is not root.
_mock_gosu() {
    mkdir -p "$TEST_TEMP_DIR/bin"
    printf '%s\n' '#!/bin/sh' 'shift' 'exec "$@"' > "$TEST_TEMP_DIR/bin/gosu"
    chmod +x "$TEST_TEMP_DIR/bin/gosu"
}

_declared_extensions() {
    local flavor="$1"

    pgver=18 flav="$flavor" yq -r '
        . as $root |
        .flavors[strenv(flav)][] | . as $ext |
        select(
            ($root.extensions[$ext].disabled == true | not) and
            (($root.extensions[$ext].max_pg_version // 999) >= (strenv(pgver) | tonumber))
        )
    ' "$CONFIG_FILE"
}

_generated_install_calls() {
    local generated_file="$1"

    sed -n \
        '/^    # Generated flavor guard and install list for /,/^    # Cleanup staging directory/p' \
        "$generated_file" \
        | sed -n 's/^    install_ext \([^;]*\); \\$/\1/p'
}

_extract_generated_flavor_guard() {
    local generated_file="$1"
    local guard_file="$2"

    sed -n \
        '/^    # Generated flavor guard and install list for /,/^    install_ext /p' \
        "$generated_file" \
        | sed -e '1d' -e '$d' -e 's/^[[:space:]]*//' -e 's/ \\$//' \
        > "$guard_file"
}

setup() {
    setup_temp_dir
    export ROOT_DIR="$TEST_TEMP_DIR"
    export CONFIG_FILE="$PROJECT_ROOT/postgres/extensions/config.yaml"
    mkdir -p "$ROOT_DIR/.build-lineage"
    _write_timescaledb_versionset
    _source_extension_utils
}

teardown() {
    teardown_temp_dir
    unset ROOT_DIR CONFIG_FILE
}

@test "generated installs exactly match config flavors for vector analytics timeseries and full" {
    local flavor
    for flavor in vector analytics timeseries full; do
        local generated_file="$TEST_TEMP_DIR/Dockerfile.${flavor}"
        local expected_file="$TEST_TEMP_DIR/${flavor}.expected"
        local actual_file="$TEST_TEMP_DIR/${flavor}.actual"

        run _generate "$flavor" "$generated_file"
        [ "$status" -eq 0 ]

        _declared_extensions "$flavor" > "$expected_file"
        _generated_install_calls "$generated_file" > "$actual_file"
        diff -u "$expected_file" "$actual_file"
    done
}

@test "base generates with no compiled extension installs" {
    local generated_file="$TEST_TEMP_DIR/Dockerfile.base"

    run _generate base "$generated_file"

    [ "$status" -eq 0 ]
    ! grep -q '^    install_ext ' "$generated_file"
}

@test "an undeclared flavor fails generation and names the typo" {
    local generated_file="$TEST_TEMP_DIR/Dockerfile.vecteur"

    run _generate vecteur "$generated_file"

    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown flavor 'vecteur'"* ]]
    [[ "$output" == *"declared flavors:"* ]]
}

@test "a template missing EXTENSION_INSTALLS fails generation" {
    local template="$TEST_TEMP_DIR/Dockerfile.missing-installs"

    sed '/@@EXTENSION_INSTALLS@@/d' "$PROJECT_ROOT/postgres/Dockerfile" > "$template"

    run generate_dockerfile \
        "$CONFIG_FILE" \
        "$template" \
        base \
        18 \
        ghcr.io \
        testowner

    [ "$status" -ne 0 ]
    [[ "$output" == *"@@EXTENSION_INSTALLS@@"* ]]
    [[ "$output" == *"$template"* ]]
}

@test "a declared flavor with a shell metacharacter fails generation" {
    local invalid_config="$TEST_TEMP_DIR/invalid-flavor-config.yaml"

    cp "$CONFIG_FILE" "$invalid_config"
    printf '%s\n' '  "$(>/tmp/pwn)": []' >> "$invalid_config"

    run generate_dockerfile \
        "$invalid_config" \
        "$PROJECT_ROOT/postgres/Dockerfile" \
        base \
        18 \
        ghcr.io \
        testowner

    [ "$status" -ne 0 ]
    [[ "$output" == *'R1 flavor key'* ]]
}

@test "generated FLAVOR default is bound to its guard" {
    local generated_file="$TEST_TEMP_DIR/Dockerfile.vector"
    local guard_file="$TEST_TEMP_DIR/flavor-guard.sh"

    run _generate vector "$generated_file"
    [ "$status" -eq 0 ]
    grep -Fxq 'ARG FLAVOR=vector' "$generated_file"

    _extract_generated_flavor_guard "$generated_file" "$guard_file"
    run env FLAVOR=analytics sh "$guard_file"

    [ "$status" -ne 0 ]
    [[ "$output" == *"generated Dockerfile is for flavor vector, got analytics"* ]]
}

@test "generated initdb SQL uses configured SQL names and leaves pg_cron manual" {
    local generated_file="$TEST_TEMP_DIR/Dockerfile.vector"
    local initdb_sql

    run _generate vector "$generated_file"
    [ "$status" -eq 0 ]

    initdb_sql=$(_initdb_sql_block "$generated_file")
    # Quoted, as the built-in block quotes "uuid-ossp". Measured on PostgreSQL 18:
    # the bare form is a syntax error for a reserved word while the quoted form
    # parses, and the two are indistinguishable for the folded lowercase names the
    # schema admits.
    [[ "$initdb_sql" == *'CREATE EXTENSION IF NOT EXISTS "vector";'* ]]
    [[ "$initdb_sql" == *'CREATE EXTENSION IF NOT EXISTS "pg_search";'* ]]
    [[ "$initdb_sql" != *'pg_cron'* ]]
    grep -Fqx '    install_ext pg_cron; \' "$generated_file"
    grep -Fq 'PRELOAD="${PRELOAD:+$PRELOAD,}pg_cron"' "$generated_file"
}

@test "every real create-mode extension gets a control-file check before flavor SQL" {
    local generated_file="$TEST_TEMP_DIR/Dockerfile.full"
    local initdb_block
    local last_check
    local first_create
    local ext_name
    local sql_name

    run _generate full "$generated_file"
    [ "$status" -eq 0 ]

    initdb_block=$(_flavor_initdb_block "$generated_file")
    # The LAST check against the FIRST create, not first-against-first: the
    # property is that no statement is written before every name behind it has
    # been vouched for. Comparing the first of each is satisfied by a block that
    # interleaves them, which would write SQL for a name checked afterwards.
    last_check=$(grep -n 'gosu postgres test -r' <<< "$initdb_block" | tail -n 1 | cut -d: -f1)
    first_create=$(grep -n 'CREATE EXTENSION' <<< "$initdb_block" | head -n 1 | cut -d: -f1)
    [ "$last_check" -lt "$first_create" ]

    while IFS=$'\t' read -r ext_name sql_name; do
        [[ -z "$ext_name" ]] && continue
        # As the postgres user, not as root: root reads a 0600 control the server
        # cannot, so a root-run test reports success for the exact case this
        # check exists to catch.
        [[ "$initdb_block" == *"gosu postgres test -r \"\${sharedir}/extension/${sql_name}.control\""* ]]
        [[ "$initdb_block" == *"extension key '${ext_name}' resolves to SQL name '${sql_name}'"* ]]
        [[ "$initdb_block" == *"CREATE EXTENSION IF NOT EXISTS \"${sql_name}\";"* ]]
    done < <(
        yq -r '
            .extensions | to_entries[]
            | select(.value.initdb.mode == "create")
            | [.key, (.value.initdb.sql_name // .key)]
            | @tsv
        ' "$CONFIG_FILE"
    )

    [[ "$initdb_block" != *'extension/pg_cron.control'* ]]
    [[ "$initdb_block" != *'CREATE EXTENSION IF NOT EXISTS "pg_cron";'* ]]
}

@test "generated control-file check fails before writing flavor SQL when control is absent" {
    local generated_file="$TEST_TEMP_DIR/Dockerfile.vector"
    local shell_file="$TEST_TEMP_DIR/flavor-initdb.sh"
    local sql_file="$TEST_TEMP_DIR/01-init-flavor.sql"
    local sharedir="$TEST_TEMP_DIR/sharedir"

    run _generate vector "$generated_file"
    [ "$status" -eq 0 ]
    _extract_flavor_initdb_shell "$generated_file" "$shell_file" "$sql_file"
    _mock_pg_config_sharedir "$sharedir"

    run env "PATH=$TEST_TEMP_DIR/bin:$PATH" sh "$shell_file"

    [ "$status" -ne 0 ]
    [[ "$output" == *"extension key 'pgvector' resolves to SQL name 'vector'"* ]]
    [[ "$output" == *"$sharedir/extension/vector.control"* ]]
    [[ "$output" == *'initdb.sql_name in postgres/extensions/config.yaml'* ]]
    [ ! -e "$sql_file" ]
}

@test "generated control-file check accepts a present control file and writes flavor SQL" {
    local generated_file="$TEST_TEMP_DIR/Dockerfile.vector"
    local shell_file="$TEST_TEMP_DIR/flavor-initdb.sh"
    local sql_file="$TEST_TEMP_DIR/01-init-flavor.sql"
    local sharedir="$TEST_TEMP_DIR/sharedir"

    run _generate vector "$generated_file"
    [ "$status" -eq 0 ]
    _extract_flavor_initdb_shell "$generated_file" "$shell_file" "$sql_file"
    _mock_pg_config_sharedir "$sharedir"
    mkdir -p "$sharedir/extension"
    touch "$sharedir/extension/vector.control" "$sharedir/extension/pg_search.control" \
        "$sharedir/extension/pg_ivm.control"

    run env "PATH=$TEST_TEMP_DIR/bin:$PATH" sh "$shell_file"

    [ "$status" -eq 0 ]
    [ -f "$sql_file" ]
    grep -Fq 'CREATE EXTENSION IF NOT EXISTS "vector";' "$sql_file"
}

# The absent-control case above removes the FIRST name the block checks. A
# regression that left `exit 1` in only the first branch would pass it while
# writing SQL for every later name. This removes the last one instead.
@test "a control file missing for the LAST checked name still withholds the SQL" {
    local generated_file="$TEST_TEMP_DIR/Dockerfile.full"
    local shell_file="$TEST_TEMP_DIR/flavor-initdb.sh"
    local sql_file="$TEST_TEMP_DIR/01-init-flavor.sql"
    local sharedir="$TEST_TEMP_DIR/sharedir"
    local last name

    run _generate full "$generated_file"
    [ "$status" -eq 0 ]
    _extract_flavor_initdb_shell "$generated_file" "$shell_file" "$sql_file"
    _mock_pg_config_sharedir "$sharedir"

    # Every name the block checks, in the order it checks them.
    last=$(grep -o 'extension/[a-z_][a-z0-9_]*\.control' "$shell_file" \
        | sed 's|extension/||;s|\.control||' | awk '!seen[$0]++' | tail -n 1)
    [ -n "$last" ]

    mkdir -p "$sharedir/extension"
    for name in $(grep -o 'extension/[a-z_][a-z0-9_]*\.control' "$shell_file" \
        | sed 's|extension/||;s|\.control||' | awk '!seen[$0]++'); do
        [ "$name" = "$last" ] && continue
        : > "$sharedir/extension/${name}.control"
    done

    run env "PATH=$TEST_TEMP_DIR/bin:$PATH" sh "$shell_file"

    [ "$status" -ne 0 ]
    [[ "$output" == *"$sharedir/extension/${last}.control"* ]]
    [ ! -e "$sql_file" ]
}

# A control file that exists but the server cannot read is the failure this check
# exists to move from first startup to build time, and `test -f` as root reports
# success for it. Measured on the shipped image: a 0600 root:root control passes
# both `test -f` and `test -r` for root, and fails `gosu postgres test -r`.
# `cp -av` preserves mode from the staging tree, and this repository has already
# shipped a 0700 onto a PostgreSQL system directory that way.
@test "a control file that exists but is unreadable fails the build" {
    local generated_file="$TEST_TEMP_DIR/Dockerfile.vector"
    local shell_file="$TEST_TEMP_DIR/flavor-initdb.sh"
    local sql_file="$TEST_TEMP_DIR/01-init-flavor.sql"
    local sharedir="$TEST_TEMP_DIR/sharedir"
    local name

    # root reads regardless of mode, so this case is unobservable as root.
    [ "$(id -u)" -ne 0 ] || skip "running as root: an unreadable file is still readable"

    run _generate vector "$generated_file"
    [ "$status" -eq 0 ]
    _extract_flavor_initdb_shell "$generated_file" "$shell_file" "$sql_file"
    _mock_pg_config_sharedir "$sharedir"

    mkdir -p "$sharedir/extension"
    for name in $(grep -o 'extension/[a-z_][a-z0-9_]*\.control' "$shell_file" \
        | sed 's|extension/||;s|\.control||' | awk '!seen[$0]++'); do
        : > "$sharedir/extension/${name}.control"
    done
    chmod 000 "$sharedir/extension/vector.control"

    run env "PATH=$TEST_TEMP_DIR/bin:$PATH" sh "$shell_file"

    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot read a control file"* ]]
    [[ "$output" == *"$sharedir/extension/vector.control"* ]]
    [ ! -e "$sql_file" ]
}

# Without gosu the check would silently become the root test it replaces, which
# reports success for the one case it exists to catch. So its absence has to be
# an error rather than a fallback, and that is only observable when it is absent.
@test "the build refuses to run the check at all when gosu is missing" {
    local generated_file="$TEST_TEMP_DIR/Dockerfile.vector"
    local shell_file="$TEST_TEMP_DIR/flavor-initdb.sh"
    local sql_file="$TEST_TEMP_DIR/01-init-flavor.sql"
    local sharedir="$TEST_TEMP_DIR/sharedir"
    local name

    run _generate vector "$generated_file"
    [ "$status" -eq 0 ]
    _extract_flavor_initdb_shell "$generated_file" "$shell_file" "$sql_file"
    _mock_pg_config_sharedir "$sharedir"
    rm -f "$TEST_TEMP_DIR/bin/gosu"

    # Every control file present, so the only reason to fail is the missing gosu.
    mkdir -p "$sharedir/extension"
    for name in $(grep -o 'extension/[a-z_][a-z0-9_]*\.control' "$shell_file" \
        | sed 's|extension/||;s|\.control||' | awk '!seen[$0]++'); do
        : > "$sharedir/extension/${name}.control"
    done

    # PATH holds only the stub directory, so a gosu installed on the host cannot
    # answer for one that would be missing in the image. `sh` is linked into it
    # deliberately: with an EMPTY directory every `command -v` fails alike, and
    # the test would pass just as well if the guard probed some other binary.
    ln -sf /bin/sh "$TEST_TEMP_DIR/bin/sh"
    run env "PATH=$TEST_TEMP_DIR/bin" /bin/sh "$shell_file"

    [ "$status" -ne 0 ]
    [[ "$output" == *"gosu is required"* ]]
    [ ! -e "$sql_file" ]
}

# A zero exit says pg_config ran, not that it answered. An empty result would make
# every test read /extension/<name>.control, where an unrelated match is a false
# pass; a relative one resolves against whatever directory the build stage is in.
@test "a sharedir that is empty or relative is refused rather than searched" {
    local generated_file="$TEST_TEMP_DIR/Dockerfile.vector"
    local shell_file="$TEST_TEMP_DIR/flavor-initdb.sh"
    local sql_file="$TEST_TEMP_DIR/01-init-flavor.sql"
    local answer

    run _generate vector "$generated_file"
    [ "$status" -eq 0 ]

    for answer in "" "relative" "./relative"; do
        rm -f "$sql_file"
        _extract_flavor_initdb_shell "$generated_file" "$shell_file" "$sql_file"
        _mock_pg_config_sharedir "$answer"

        run env "PATH=$TEST_TEMP_DIR/bin:$PATH" sh "$shell_file"

        [ "$status" -ne 0 ]
        [[ "$output" == *"is not an absolute path"* ]]
        [ ! -e "$sql_file" ]
    done
}

@test "disabled and version-incompatible extensions are absent from stages copies installs and initdb SQL" {
    local filtered_config="$TEST_TEMP_DIR/filtered-config.yaml"
    local generated_file="$TEST_TEMP_DIR/Dockerfile.vector"
    local ext

    cp "$CONFIG_FILE" "$filtered_config"
    yq -i '.extensions.pgvector.disabled = true | .extensions.pg_ivm.max_pg_version = 17' "$filtered_config"

    run generate_dockerfile "$filtered_config" "$PROJECT_ROOT/postgres/Dockerfile" vector 18 ghcr.io testowner
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$generated_file"

    for ext in pgvector pg_ivm; do
        ! grep -Fq " AS ext-${ext}" "$generated_file"
        ! grep -Fq "/tmp/ext/${ext}/" "$generated_file"
        ! grep -Fqx "    install_ext ${ext}; \\" "$generated_file"
        ! grep -Fq "CREATE EXTENSION IF NOT EXISTS \"${ext}\";" "$generated_file"
    done
    ! grep -Fq 'CREATE EXTENSION IF NOT EXISTS "vector";' "$generated_file"
}

@test "a compiled extension without initdb.mode fails generation" {
    local invalid_config="$TEST_TEMP_DIR/missing-initdb-mode.yaml"

    cp "$CONFIG_FILE" "$invalid_config"
    yq -i 'del(.extensions.pgvector.initdb.mode)' "$invalid_config"

    run generate_dockerfile "$invalid_config" "$PROJECT_ROOT/postgres/Dockerfile" vector 18 ghcr.io testowner

    [ "$status" -ne 0 ]
    [[ "$output" == *'R4 extension "pgvector" must declare initdb.mode'* ]]
}

@test "an unrecognised initdb mode fails generation" {
    local invalid_config="$TEST_TEMP_DIR/unknown-initdb-mode.yaml"

    cp "$CONFIG_FILE" "$invalid_config"
    yq -i '.extensions.pgvector.initdb.mode = "later"' "$invalid_config"

    run generate_dockerfile "$invalid_config" "$PROJECT_ROOT/postgres/Dockerfile" vector 18 ghcr.io testowner

    [ "$status" -ne 0 ]
    [[ "$output" == *'R4 extension "pgvector" must declare initdb.mode'* ]]
}

@test "duplicate initdb SQL names within a flavor fail generation" {
    local invalid_config="$TEST_TEMP_DIR/duplicate-initdb-name.yaml"

    cp "$CONFIG_FILE" "$invalid_config"
    yq -i '.extensions.paradedb.initdb.sql_name = "vector"' "$invalid_config"

    run generate_dockerfile "$invalid_config" "$PROJECT_ROOT/postgres/Dockerfile" vector 18 ghcr.io testowner

    [ "$status" -ne 0 ]
    [[ "$output" == *'R6 flavor "vector" resolves more than one extension to SQL name "vector"'* ]]
}

@test "unsafe and built-in initdb SQL names fail generation" {
    local unsafe_config="$TEST_TEMP_DIR/unsafe-initdb-name.yaml"
    local builtin_config="$TEST_TEMP_DIR/builtin-initdb-name.yaml"

    cp "$CONFIG_FILE" "$unsafe_config"
    yq -i '.extensions.pgvector.initdb.sql_name = "vector; DROP"' "$unsafe_config"
    run generate_dockerfile "$unsafe_config" "$PROJECT_ROOT/postgres/Dockerfile" vector 18 ghcr.io testowner
    [ "$status" -ne 0 ]
    [[ "$output" == *'R4 extension "pgvector" resolves to an invalid SQL name'* ]]

    cp "$CONFIG_FILE" "$builtin_config"
    yq -i '.extensions.pgvector.initdb.sql_name = "pgcrypto"' "$builtin_config"
    run generate_dockerfile "$builtin_config" "$PROJECT_ROOT/postgres/Dockerfile" vector 18 ghcr.io testowner
    [ "$status" -ne 0 ]
    [[ "$output" == *'R7 flavor "vector" resolves an extension to built-in SQL name "pgcrypto"'* ]]
}

# A flavour declared as a scalar, or holding anything that is not a list of
# name-shaped strings, is a declaration the generator cannot act on. Read as an
# empty list it produced an image with no compiled extensions carrying that
# flavour's label — the same shape as an undeclared key and an unsafe name, which
# is why the whole section's form is validated rather than one property of it.
@test "a malformed flavour declaration fails generation instead of emptying the image" {
    local scalar_config="$TEST_TEMP_DIR/scalar-flavor.yaml"
    local nonstring_config="$TEST_TEMP_DIR/nonstring-flavor.yaml"

    cp "$CONFIG_FILE" "$scalar_config"
    yq -i '.flavors.vector = "pgvector"' "$scalar_config"
    run generate_dockerfile "$scalar_config" "$PROJECT_ROOT/postgres/Dockerfile" vector 18 ghcr.io oorabona
    [ "$status" -ne 0 ]
    [[ "$output" == *vector* ]]

    cp "$CONFIG_FILE" "$nonstring_config"
    yq -i '.flavors.vector = ["pgvector", {"paradedb": true}]' "$nonstring_config"
    run generate_dockerfile "$nonstring_config" "$PROJECT_ROOT/postgres/Dockerfile" vector 18 ghcr.io oorabona
    [ "$status" -ne 0 ]
}

# The requested flavour, not only the declared keys. yq's `env()` parses its
# value as YAML, so `vector # $(id)` reduces to `vector`, membership succeeds,
# and the original text is what reaches the generated ARG, the guard and its
# echo — the substitution runs before the guard can reject it.
@test "a requested flavour carrying shell metacharacters fails generation" {
    run generate_dockerfile "$CONFIG_FILE" "$PROJECT_ROOT/postgres/Dockerfile" \
        'vector # $(touch /tmp/flavor-injection-canary)' 18 ghcr.io oorabona
    [ "$status" -ne 0 ]
    [ ! -e /tmp/flavor-injection-canary ]
    [[ "$output" == *'invalid flavor name requested'* ]]
}

# The last two structural properties. A member naming no declared extension
# resolved its version as null and emitted an `ext-<typo>:pg18-null` stage,
# deferring a legible error to the docker pull; a member listed twice slipped
# past the SQL-name duplicate check whenever its policy was `manual`.
@test "a flavour member that names no extension, or names one twice, fails generation" {
    local unknown_config="$TEST_TEMP_DIR/unknown-member.yaml"
    local dup_config="$TEST_TEMP_DIR/duplicate-member.yaml"

    cp "$CONFIG_FILE" "$unknown_config"
    yq -i '.flavors.vector = ["pgvectro"]' "$unknown_config"
    run generate_dockerfile "$unknown_config" "$PROJECT_ROOT/postgres/Dockerfile" vector 18 ghcr.io oorabona
    [ "$status" -ne 0 ]

    cp "$CONFIG_FILE" "$dup_config"
    yq -i '.flavors.vector = ["pg_cron", "pg_cron"]' "$dup_config"
    run generate_dockerfile "$dup_config" "$PROJECT_ROOT/postgres/Dockerfile" vector 18 ghcr.io oorabona
    [ "$status" -ne 0 ]
}

# PostgreSQL folds an unquoted identifier to lower case and rejects a leading
# digit, so the name that passes generation has to be the name the server will
# see. Accepting mixed case let `vector` and `Vector` both pass the duplicate
# check while folding to one, and `123ext` reach an initdb that cannot run it.
@test "initdb SQL names that PostgreSQL would fold or reject fail generation" {
    local digit_config="$TEST_TEMP_DIR/digit-initdb-name.yaml"
    local case_config="$TEST_TEMP_DIR/case-initdb-name.yaml"

    cp "$CONFIG_FILE" "$digit_config"
    yq -i '.extensions.pgvector.initdb.sql_name = "123ext"' "$digit_config"
    run generate_dockerfile "$digit_config" "$PROJECT_ROOT/postgres/Dockerfile" vector 18 ghcr.io oorabona
    [ "$status" -ne 0 ]
    [[ "$output" == *'R4 extension "pgvector" resolves to an invalid SQL name'* ]]

    cp "$CONFIG_FILE" "$case_config"
    yq -i '.extensions.pgvector.initdb.sql_name = "Vector"' "$case_config"
    run generate_dockerfile "$case_config" "$PROJECT_ROOT/postgres/Dockerfile" vector 18 ghcr.io oorabona
    [ "$status" -ne 0 ]
    [[ "$output" == *'R4 extension "pgvector" resolves to an invalid SQL name'* ]]
}

@test "unexpanded source templates have bare markers that Dockerfile parsing rejects" {
    local template
    local marker
    local -a templates=(
        "$PROJECT_ROOT/postgres/Dockerfile"
        "$PROJECT_ROOT/github-runner/Dockerfile.linux"
        "$PROJECT_ROOT/web-shell/Dockerfile"
    )

    for template in "${templates[@]}"; do
        while IFS= read -r marker; do
            [[ -z "$marker" ]] && continue
            grep -Eq "^[[:space:]]*${marker}$" "$template"
        done < <(grep -oE '@@[A-Z0-9_]+@@' "$template" | sort -u)
    done
}
