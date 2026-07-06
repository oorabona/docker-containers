#!/usr/bin/env bats

# Unit tests for helpers/version-utils.sh

setup() {
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"

    # shellcheck source=../../helpers/version-utils.sh
    source "$PROJECT_ROOT/helpers/version-utils.sh"
}

@test "version_is_greater: returns true for a normal greater version" {
    run version_is_greater "2.0.0" "1.0.0"
    [ "$status" -eq 0 ]
}

@test "version_is_greater: ansible downgrade regression is not greater" {
    run version_is_greater "14.0.0-ubuntu" "14.1.0-ubuntu"
    [ "$status" -eq 1 ]
}

@test "version_is_greater: equal versions are not greater" {
    run version_is_greater "1.2.3" "1.2.3"
    [ "$status" -eq 1 ]
}

@test "version_is_greater: missing numeric components are padded with zero" {
    run version_is_greater "1.2" "1.2.0"
    [ "$status" -eq 1 ]
}

@test "version_is_greater: unequal segment counts compare numerically" {
    run version_is_greater "1.2.1" "1.2"
    [ "$status" -eq 0 ]
}

@test "version_is_greater: unparseable input does not report greater" {
    run version_is_greater "release-candidate" "1.0.0"
    [ "$status" -eq 2 ]
}
