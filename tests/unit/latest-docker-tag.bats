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

write_fake_digest_docker_with_transient_failure() {
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
        printf '{"Repository":"library/debian","Tags":["11","12","trixie"]}\n'
        ;;
    inspect)
        if [[ "${1:-}" == "--format" ]]; then
            shift 2
        fi
        ref="${1:-}"
        case "$ref" in
            docker://library/debian:trixie)
                echo "sha256:thirteen"
                ;;
            docker://library/debian:11)
                # Transient failure on an unrelated earlier candidate.
                exit 1
                ;;
            docker://library/debian:12)
                echo "sha256:twelve"
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

write_fake_tag_listing_docker() {
    mkdir -p "${TEST_TEMP_DIR}/bin"
    cat > "${TEST_TEMP_DIR}/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

: "${REGISTRY_CALL_LOG:?}"
printf '%s\n' "$*" >> "$REGISTRY_CALL_LOG"
printf '{"Repository":"library/debian","Tags":["bookworm","trixie"]}\n'
EOF
    chmod +x "${TEST_TEMP_DIR}/bin/docker"
}

write_fake_malformed_inspect_docker() {
    mkdir -p "${TEST_TEMP_DIR}/bin"
    cat > "${TEST_TEMP_DIR}/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" != "run" ]]; then
    exit 99
fi
shift
[[ "${1:-}" == "--rm" ]] && shift
shift # skopeo image
[[ "${1:-}" == "inspect" ]] || exit 98
shift

if [[ "${1:-}" == "--format" ]]; then
    exit 1
fi

printf 'not valid JSON\n'
EOF
    chmod +x "${TEST_TEMP_DIR}/bin/docker"
}

run_resolve_numeric_alias() {
    env PATH="${TEST_TEMP_DIR}/bin:$PATH" "$HELPER" resolve-numeric-alias "$@"
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

@test "resolve-numeric-alias returns 3 and no output when the target digest lookup fails" {
    write_fake_digest_docker

    run run_resolve_numeric_alias "library/debian" "missing" '^[0-9]+$'

    [ "$status" -eq 3 ]
    [ -z "$output" ]
}

@test "resolve-numeric-alias returns 3 when a candidate digest lookup fails" {
    write_fake_digest_docker_with_transient_failure

    run run_resolve_numeric_alias "library/debian" "trixie" '^[0-9]+$'

    [ "$status" -eq 3 ]
    [ -z "$output" ]
}

@test "resolve-numeric-alias treats an unclassified enumeration status as indeterminate" {
    run bash -c '
        source "$1"
        docker-tag-digest() { printf "sha256:target\\n"; }
        docker-tag-matching-tags() { return 127; }
        resolve-numeric-alias "library/debian" "trixie" "^[0-9]+$"
    ' _ "$HELPER"

    [ "$status" -eq 3 ]
    [ -z "$output" ]
}

@test "resolve-numeric-alias rejects an empty pattern before contacting the registry" {
    write_fake_tag_listing_docker
    local call_log="${TEST_TEMP_DIR}/registry-calls"

    run env PATH="${TEST_TEMP_DIR}/bin:$PATH" REGISTRY_CALL_LOG="$call_log" \
        "$HELPER" resolve-numeric-alias "library/debian" "trixie" ""

    [ "$status" -eq 3 ]
    [ -z "$output" ]
    [ ! -e "$call_log" ]
}

@test "docker-tag-matching-tags rejects an empty pattern before contacting the registry" {
    write_fake_tag_listing_docker
    local call_log="${TEST_TEMP_DIR}/registry-calls"

    run env PATH="${TEST_TEMP_DIR}/bin:$PATH" REGISTRY_CALL_LOG="$call_log" \
        "$HELPER" docker-tag-matching-tags "library/debian" ""

    [ "$status" -eq 3 ]
    [ -z "$output" ]
    [ ! -e "$call_log" ]
}

@test "latest-docker-tag rejects an empty pattern before contacting the registry" {
    write_fake_tag_listing_docker
    local call_log="${TEST_TEMP_DIR}/registry-calls"
    ln -s "$HELPER" "${TEST_TEMP_DIR}/bin/latest-docker-tag"

    run env PATH="${TEST_TEMP_DIR}/bin:$PATH" REGISTRY_CALL_LOG="$call_log" \
        latest-docker-tag "library/debian" ""

    [ "$status" -eq 3 ]
    [ -z "$output" ]
    [ ! -e "$call_log" ]
}

@test "check-docker-tag rejects an empty pattern before contacting the registry" {
    write_fake_tag_listing_docker
    local call_log="${TEST_TEMP_DIR}/registry-calls"

    run env PATH="${TEST_TEMP_DIR}/bin:$PATH" REGISTRY_CALL_LOG="$call_log" \
        "$HELPER" check-docker-tag "library/debian" ""

    [ "$status" -eq 3 ]
    [ ! -e "$call_log" ]
}

@test "check-docker-tag accepts a non-empty pattern and queries the registry" {
    write_fake_tag_listing_docker
    local call_log="${TEST_TEMP_DIR}/registry-calls"

    run env PATH="${TEST_TEMP_DIR}/bin:$PATH" REGISTRY_CALL_LOG="$call_log" \
        "$HELPER" check-docker-tag "library/debian" '^trixie$'

    [ "$status" -eq 0 ]
    [ "$output" = "trixie" ]
    [ -s "$call_log" ]
}

@test "docker-tag-digest returns 3 when fallback inspect output is malformed" {
    write_fake_malformed_inspect_docker

    run env PATH="${TEST_TEMP_DIR}/bin:$PATH" \
        "$HELPER" docker-tag-digest "library/debian" "trixie"

    [ "$status" -eq 3 ]
    [ -z "$output" ]
}
