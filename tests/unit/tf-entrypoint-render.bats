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

if [ "${JINJA2_BLOCK:-}" = "1" ]; then
    : "${JINJA2_READY_FILE:?}"
    : "${JINJA2_RELEASE_FILE:?}"
    printf '%s' "${JINJA2_PARTIAL_OUTPUT:-partial output}"
    printf '%s\n' ready > "$JINJA2_READY_FILE"
    attempt=0
    while [ ! -e "$JINJA2_RELEASE_FILE" ]; do
        attempt=$((attempt + 1))
        if [ "$attempt" -ge 100 ]; then
            printf 'timed out waiting for render release\n' >&2
            exit 70
        fi
        sleep 0.05
    done
    exit 0
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

start_blocked_entrypoint() {
    local entrypoint="$1"
    local workdir="$2"
    local ready_file="$3"
    local release_file="$4"

    env \
        PATH="$TEST_BIN:$PATH" \
        BASH_ENV="$FAKE_BASH_ENV" \
        FAKE_EXEC_LOG="$workdir/exec.log" \
        CONFIGFILE="$workdir/config.json" \
        JINJA2_BLOCK=1 \
        JINJA2_READY_FILE="$ready_file" \
        JINJA2_RELEASE_FILE="$release_file" \
        bash -c 'cd "$1" && shift && command exec bash "$@"' bash "$workdir" "$entrypoint" &
    STARTED_ENTRYPOINT_PID=$!
}

wait_for_nonempty_file() {
    local file="$1"
    local attempt

    for attempt in {1..100}; do
        [ -s "$file" ] && return 0
        sleep 0.05
    done
    return 1
}

assert_no_render_temporary_files() {
    local workdir="$1"

    ! find "$workdir" -type f \( -name '.tf-render.*' -o -name '*.tf.??????' \) -print -quit | grep -q .
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
        mapfile -t temporary_files < <(find "$workdir" -maxdepth 1 -type f -name '.tf-render.*' -print)
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

@test "a directory output is rejected without changing its contents for each entrypoint" {
    local entrypoint
    local name
    local workdir
    local output_directory

    for entrypoint in "${ENTRYPOINTS[@]}"; do
        name="$(entrypoint_name "$entrypoint")"
        workdir="$BATS_TEST_TMPDIR/$name-directory-output"
        output_directory="$workdir/x.tf"
        mkdir -p "$output_directory"
        printf '{}' > "$workdir/config.json"
        printf 'template' > "$workdir/x.tf.j2"
        printf 'KEEP' > "$output_directory/keep"

        run_entrypoint "$entrypoint" "$workdir"

        [ "$status" -ne 0 ]
        [[ "$output" == *"Could not replace"* ]]
        [[ "$output" == *"x.tf.j2"* ]]
        cmp -s <(printf 'KEEP') "$output_directory/keep"
        [ "$(find "$output_directory" -mindepth 1 -maxdepth 1 -print | wc -l)" -eq 1 ]
        assert_no_render_temporary_files "$workdir"
    done
}

@test "a symlink to a directory output is rejected without changing its target for each entrypoint" {
    local entrypoint
    local name
    local workdir
    local target_directory

    for entrypoint in "${ENTRYPOINTS[@]}"; do
        name="$(entrypoint_name "$entrypoint")"
        workdir="$BATS_TEST_TMPDIR/$name-symlink-directory-output"
        target_directory="$workdir/target"
        mkdir -p "$target_directory"
        printf '{}' > "$workdir/config.json"
        printf 'template' > "$workdir/x.tf.j2"
        printf 'KEEP' > "$target_directory/keep"
        ln -s target "$workdir/x.tf"

        run_entrypoint "$entrypoint" "$workdir"

        [ "$status" -ne 0 ]
        [[ "$output" == *"Could not replace"* ]]
        [[ "$output" == *"x.tf.j2"* ]]
        [ -L "$workdir/x.tf" ]
        cmp -s <(printf 'KEEP') "$target_directory/keep"
        [ "$(find "$target_directory" -mindepth 1 -maxdepth 1 -print | wc -l)" -eq 1 ]
        assert_no_render_temporary_files "$workdir"
    done
}

@test "SIGTERM during rendering removes each entrypoint temporary file" {
    local entrypoint
    local name
    local workdir
    local jinja2_ready_file
    local release_file
    local entrypoint_status
    local -a temporary_files

    for entrypoint in "${ENTRYPOINTS[@]}"; do
        name="$(entrypoint_name "$entrypoint")"
        workdir="$BATS_TEST_TMPDIR/$name-signal"
        jinja2_ready_file="$workdir/jinja2.ready"
        release_file="$workdir/release-jinja2"
        mkdir -p "$workdir"
        printf '{}' > "$workdir/config.json"
        printf 'template' > "$workdir/x.tf.j2"
        printf 'OLD' > "$workdir/x.tf"

        start_blocked_entrypoint "$entrypoint" "$workdir" "$jinja2_ready_file" "$release_file"
        wait_for_nonempty_file "$jinja2_ready_file"
        kill -TERM "$STARTED_ENTRYPOINT_PID"
        sleep 0.05
        mapfile -t temporary_files < <(find "$workdir" -maxdepth 1 -type f -name '.tf-render.*' -print)
        [ "${#temporary_files[@]}" -eq 1 ]
        cmp -s <(printf 'partial output') "${temporary_files[0]}"
        : > "$release_file"
        if wait "$STARTED_ENTRYPOINT_PID"; then
            entrypoint_status=0
        else
            entrypoint_status=$?
        fi

        [ "$entrypoint_status" -ne 0 ]
        assert_no_render_temporary_files "$workdir"
        cmp -s <(printf 'OLD') "$workdir/x.tf"
        [ ! -e "$workdir/exec.log" ]
    done
}

@test "rendering preserves existing modes and applies the test umask to new outputs for each entrypoint" {
    local entrypoint
    local name
    local workdir
    local test_umask
    local expected_new_mode

    umask 0027
    test_umask="$(umask)"
    expected_new_mode="$(printf '%03o' "$((0666 & ~8#$test_umask))")"

    for entrypoint in "${ENTRYPOINTS[@]}"; do
        name="$(entrypoint_name "$entrypoint")"
        workdir="$BATS_TEST_TMPDIR/$name-mode"
        mkdir -p "$workdir"
        printf '{}' > "$workdir/config.json"
        printf 'template' > "$workdir/existing.tf.j2"
        printf 'OLD' > "$workdir/existing.tf"
        chmod 0644 "$workdir/existing.tf"
        printf 'template' > "$workdir/new.tf.j2"

        run_entrypoint "$entrypoint" "$workdir"

        [ "$status" -eq 0 ]
        [ "$(stat -c %a "$workdir/existing.tf")" = 644 ]
        [ "$(stat -c %a "$workdir/new.tf")" = "$expected_new_mode" ]
        assert_final_cli_was_intercepted "$entrypoint" "$workdir"
    done
}

@test "a 250-byte output basename renders for each entrypoint" {
    local entrypoint
    local name
    local workdir
    local output_basename

    printf -v output_basename '%*s' 247 ''
    output_basename="${output_basename// /a}.tf"
    [ "${#output_basename}" -eq 250 ]

    for entrypoint in "${ENTRYPOINTS[@]}"; do
        name="$(entrypoint_name "$entrypoint")"
        workdir="$BATS_TEST_TMPDIR/$name-long-output-name"
        mkdir -p "$workdir"
        printf '{}' > "$workdir/config.json"
        printf 'template' > "$workdir/$output_basename.j2"

        run_entrypoint "$entrypoint" "$workdir"

        [ "$status" -eq 0 ]
        cmp -s <(printf 'rendered output') "$workdir/$output_basename"
        assert_final_cli_was_intercepted "$entrypoint" "$workdir"
    done
}
