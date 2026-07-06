#!/usr/bin/env bats

setup() {
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
    TEST_TEMP_DIR="$(mktemp -d)"
    HELPER="${PROJECT_ROOT}/helpers/docker-tag"
}

teardown() {
    rm -rf "$TEST_TEMP_DIR"
}

write_fake_digest_docker() {
    mkdir -p "${TEST_TEMP_DIR}/bin"
    cat > "${TEST_TEMP_DIR}/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" != "run" ]]; then
    exit 99
fi
shift

if [[ "${1:-}" == "--rm" ]]; then
    shift
fi

shift # skopeo image
command="${1:-}"
shift

case "$command" in
    list-tags)
        ref="${1:-}"
        if [[ "$ref" != "docker://library/debian" ]]; then
            exit 41
        fi
        printf '{"Repository":"library/debian","Tags":["11","12","13","12.14","bookworm","trixie","bullseye"]}\n'
        ;;
    inspect)
        if [[ "${1:-}" == "--format" ]]; then
            shift 2
        fi
        ref="${1:-}"
        case "$ref" in
            docker://library/debian:trixie|docker://library/debian:13)
                echo "sha256:thirteen"
                ;;
            docker://library/debian:bookworm|docker://library/debian:12)
                echo "sha256:twelve"
                ;;
            docker://library/debian:bullseye|docker://library/debian:11)
                echo "sha256:eleven"
                ;;
            docker://library/debian:orphan)
                echo "sha256:orphan"
                ;;
            *)
                exit 42
                ;;
        esac
        ;;
    *)
        exit 98
        ;;
esac
EOF
    chmod +x "${TEST_TEMP_DIR}/bin/docker"
}

run_resolve_numeric_alias() {
    env PATH="${TEST_TEMP_DIR}/bin:$PATH" bash -c '
        source "$1"
        resolve-numeric-alias "$2" "$3" "$4"
    ' _ "$HELPER" "$@"
}

@test "resolve-numeric-alias returns the numeric tag with a matching digest" {
    write_fake_digest_docker

    run run_resolve_numeric_alias "library/debian" "trixie" '^[0-9]+$'

    [ "$status" -eq 0 ]
    [ "$output" = "13" ]
}

@test "resolve-numeric-alias returns 1 and no output when no numeric digest matches" {
    write_fake_digest_docker

    run run_resolve_numeric_alias "library/debian" "orphan" '^[0-9]+$'

    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "resolve-numeric-alias returns 1 and no output when a lookup fails" {
    write_fake_digest_docker

    run run_resolve_numeric_alias "library/debian" "missing" '^[0-9]+$'

    [ "$status" -eq 1 ]
    [ -z "$output" ]
}
