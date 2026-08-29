#!/usr/bin/env bats

# Unit tests for scripts/list-extension-versions.sh.  The lister is the
# workflow boundary between image-cell declarations and --major-version.

load "../test_helper"

@test "lister emits each postgres cell's declared bare major" {
    run "$SCRIPTS_DIR/list-extension-versions.sh"

    [ "$status" -eq 0 ] || {
        echo "FAIL: extension version lister must succeed"
        return 1
    }
    [[ "$output" == *"Containers with extensions: postgres"* ]] || {
        echo "FAIL: postgres must remain the extension container"
        return 1
    }
    [[ "$output" == *"Versions map: postgres:18,17,16"* ]] || {
        echo "FAIL: lister must emit declared bare majors, not resolved image tags"
        return 1
    }
    [[ "$output" == *"-> v18 needs extensions"* ]] || {
        echo "FAIL: lister notice must name the declared bare major"
        return 1
    }
    [[ "$output" != *"18.6-alpine"* ]] || {
        echo "FAIL: lister must not emit the resolved container tag as a major"
        return 1
    }
}

@test "lister leaves a scoped container without extensions unaffected" {
    run env EXTENSION_CONTAINERS_JSON='["wordpress"]' "$SCRIPTS_DIR/list-extension-versions.sh"

    [ "$status" -eq 0 ] || {
        echo "FAIL: lister must succeed for a scoped non-extension container"
        return 1
    }
    [[ "$output" == *"Containers with extensions: "* ]] || {
        echo "FAIL: a container without extensions must not enter containers"
        return 1
    }
    [[ "$output" == *"Versions map: "* ]] || {
        echo "FAIL: a container without extensions must not enter versions_map"
        return 1
    }
    [[ "$output" != *"postgres"* ]] || {
        echo "FAIL: scoped non-extension discovery must not add postgres"
        return 1
    }
}
