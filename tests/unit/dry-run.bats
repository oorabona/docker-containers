#!/usr/bin/env bats

setup() {
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
}

@test "DOCKER defaults to docker when DRY_RUN unset" {
    unset DRY_RUN DOCKER
    source "$PROJECT_ROOT/helpers/logging.sh"
    [[ "$DOCKER" == "docker" ]]
}

@test "DOCKER becomes echo docker when DRY_RUN=true" {
    export DRY_RUN=true
    unset DOCKER
    source "$PROJECT_ROOT/helpers/logging.sh"
    [[ "$DOCKER" == "echo docker" ]]
}

@test "DOCKER can be overridden even with DRY_RUN=true" {
    export DRY_RUN=true
    export DOCKER="/usr/local/bin/podman"
    source "$PROJECT_ROOT/helpers/logging.sh"
    [[ "$DOCKER" == "/usr/local/bin/podman" ]]
}

@test "SKOPEO defaults to skopeo when DRY_RUN unset" {
    unset DRY_RUN SKOPEO
    source "$PROJECT_ROOT/helpers/logging.sh"
    [[ "$SKOPEO" == "skopeo" ]]
}

@test "SKOPEO becomes echo skopeo when DRY_RUN=true" {
    export DRY_RUN=true
    unset SKOPEO
    source "$PROJECT_ROOT/helpers/logging.sh"
    [[ "$SKOPEO" == "echo skopeo" ]]
}

@test "echo docker outputs the full command" {
    DOCKER="echo docker"
    result=$($DOCKER buildx build --load --platform linux/amd64 -t myimage:latest .)
    [[ "$result" == "docker buildx build --load --platform linux/amd64 -t myimage:latest ." ]]
}
