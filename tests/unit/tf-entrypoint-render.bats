#!/usr/bin/env bats

# The entrypoints keep their CLI paths absolute.  BASH_ENV lets these tests run
# the real rendering loop while replacing only the final Bash exec builtin, so
# neither Terraform nor OpenTofu is invoked.

setup() {
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="${TF_ENTRYPOINT_PROJECT_ROOT:-$(cd "$TEST_DIR/../.." && pwd)}"
    ENTRYPOINTS=(
        "$PROJECT_ROOT/terraform/docker-entrypoint.sh"
        "$PROJECT_ROOT/opentofu/docker-entrypoint.sh"
    )
    TEST_BIN="$BATS_TEST_TMPDIR/bin"
    FAKE_BASH_ENV="$BATS_TEST_TMPDIR/bash-env"

    mkdir -p "$TEST_BIN"

    cat > "$TEST_BIN/jinja2" <<'EOF'
#!/bin/sh

if [ "$#" -ne 2 ]; then
    printf 'expected template and config arguments\n' >&2
    exit 64
fi

if [ "${JINJA2_FAIL:-}" = "1" ]; then
    printf '%s' "${JINJA2_PARTIAL_OUTPUT:-partial output}"
    exit 42
fi

printf '%s' "${JINJA2_OUTPUT:-rendered output}"
EOF
    chmod +x "$TEST_BIN/jinja2"

    cat > "$FAKE_BASH_ENV" <<'EOF'
exec() {
    printf '%s\n' "$*" > "${FAKE_EXEC_LOG:?}"
}
EOF
}

entrypoint_name() {
    basename "$(dirname "$1")"
}

expected_cli() {
    case "$(entrypoint_name "$1")" in
        terraform)
            printf '/bin/terraform\n'
            ;;
        opentofu)
            printf '/usr/local/bin/tofu\n'
            ;;
    esac
}

run_entrypoint() {
    local entrypoint="$1"
    local workdir="$2"
    shift 2

    run env \
        PATH="$TEST_BIN:$PATH" \
        BASH_ENV="$FAKE_BASH_ENV" \
        FAKE_EXEC_LOG="$workdir/exec.log" \
        CONFIGFILE="$workdir/config.json" \
        "$@" \
        bash -c 'cd "$1" && shift && "$@"' bash "$workdir" "$entrypoint"
}

assert_final_cli_was_intercepted() {
    local entrypoint="$1"
    local workdir="$2"

    [ -s "$workdir/exec.log" ]
    grep -Fqx "$(expected_cli "$entrypoint")" "$workdir/exec.log"
}

@test "failed template rendering leaves each existing output unchanged and removes its temporary file" {
    local entrypoint
    local name
    local workdir
    local -a temporary_files

    for entrypoint in "${ENTRYPOINTS[@]}"; do
        name="$(entrypoint_name "$entrypoint")"
        workdir="$BATS_TEST_TMPDIR/$name-failure"
        mkdir -p "$workdir"
        printf '{}' > "$workdir/config.json"
        printf 'template' > "$workdir/x.tf.j2"
        printf 'OLD' > "$workdir/x.tf"

        run_entrypoint "$entrypoint" "$workdir" JINJA2_FAIL=1

        [ "$status" -ne 0 ]
        [[ "$output" == *"Could not render"* ]]
        [[ "$output" == *"x.tf.j2"* ]]
        cmp -s <(printf 'OLD') "$workdir/x.tf"
        mapfile -t temporary_files < <(find "$workdir" -maxdepth 1 -type f -name 'x.tf.??????' -print)
        [ "${#temporary_files[@]}" -eq 0 ]
    done
}

@test "successful rendering replaces each output symlink without writing its target" {
    local entrypoint
    local name
    local workdir
    local rendered

    for entrypoint in "${ENTRYPOINTS[@]}"; do
        name="$(entrypoint_name "$entrypoint")"
        workdir="$BATS_TEST_TMPDIR/$name-symlink"
        rendered="$name rendered output"
        mkdir -p "$workdir"
        printf '{}' > "$workdir/config.json"
        printf 'template' > "$workdir/x.tf.j2"
        printf 'VICTIM' > "$workdir/victim"
        ln -s victim "$workdir/x.tf"

        run_entrypoint "$entrypoint" "$workdir" JINJA2_OUTPUT="$rendered"

        [ "$status" -eq 0 ]
        [ ! -L "$workdir/x.tf" ]
        [ -f "$workdir/x.tf" ]
        cmp -s <(printf '%s' "$rendered") "$workdir/x.tf"
        cmp -s <(printf 'VICTIM') "$workdir/victim"
        assert_final_cli_was_intercepted "$entrypoint" "$workdir"
    done
}

@test "successful rendering writes exactly the complete jinja2 output for each entrypoint" {
    local entrypoint
    local name
    local workdir
    local rendered

    for entrypoint in "${ENTRYPOINTS[@]}"; do
        name="$(entrypoint_name "$entrypoint")"
        workdir="$BATS_TEST_TMPDIR/$name-success"
        rendered="$name complete rendered output"
        mkdir -p "$workdir"
        printf '{}' > "$workdir/config.json"
        printf 'template' > "$workdir/x.tf.j2"

        run_entrypoint "$entrypoint" "$workdir" JINJA2_OUTPUT="$rendered"

        [ "$status" -eq 0 ]
        cmp -s <(printf '%s' "$rendered") "$workdir/x.tf"
        assert_final_cli_was_intercepted "$entrypoint" "$workdir"
    done
}
