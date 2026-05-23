#!/usr/bin/env bats

# Unit tests for compute_expand_retained_map in helpers/variant-utils.sh
# Tests per-container expand-retained signal computation from git-diff-derived changed-files.

setup() {
    TEST_DIR=$(mktemp -d)
    ORIG_DIR="$PWD"
    cd "$TEST_DIR" || exit 1

    # Provide a minimal yq mock (variant-utils.sh sources it but compute_expand_retained_map
    # does not use yq — the mock prevents accidental real-yq side-effects in tests)
    mkdir -p bin
    cat > bin/yq <<'MOCK'
#!/bin/bash
echo ""
MOCK
    chmod +x bin/yq
    export PATH="$TEST_DIR/bin:$PATH"

    source "$ORIG_DIR/helpers/variant-utils.sh"

    # Default fixture: an empty changed-files list
    CHANGED_FILES="$TEST_DIR/changed_files.txt"
    touch "$CHANGED_FILES"
}

teardown() {
    cd "$ORIG_DIR" || true
    rm -rf "$TEST_DIR"
}

# ---------------------------------------------------------------------------
# SC-02: config.yaml change for a container triggers expansion
# ---------------------------------------------------------------------------

@test "SC-02: config.yaml change for openresty → openresty:true" {
    echo "openresty/config.yaml" >> "$CHANGED_FILES"
    run compute_expand_retained_map "push" "false" "$CHANGED_FILES" '["openresty"]'
    [ "$status" -eq 0 ]
    val=$(echo "$output" | jq -r '.openresty')
    [ "$val" = "true" ]
}

# ---------------------------------------------------------------------------
# SC-03: LAST_REBUILD.md change for a container triggers expansion
# ---------------------------------------------------------------------------

@test "SC-03: LAST_REBUILD.md change for openresty → openresty:true" {
    echo "openresty/LAST_REBUILD.md" >> "$CHANGED_FILES"
    run compute_expand_retained_map "push" "false" "$CHANGED_FILES" '["openresty"]'
    [ "$status" -eq 0 ]
    val=$(echo "$output" | jq -r '.openresty')
    [ "$val" = "true" ]
}

# ---------------------------------------------------------------------------
# SC-04: pull_request event → all containers true regardless of diff
# ---------------------------------------------------------------------------

@test "SC-04: pull_request event → all containers true regardless of diff" {
    # Only Dockerfile changed (not in trigger list), but PR event wins
    echo "openresty/Dockerfile" >> "$CHANGED_FILES"
    run compute_expand_retained_map "pull_request" "false" "$CHANGED_FILES" '["openresty"]'
    [ "$status" -eq 0 ]
    val=$(echo "$output" | jq -r '.openresty')
    [ "$val" = "true" ]
}

# ---------------------------------------------------------------------------
# SC-05: build_all_retained="true" → all containers true
# ---------------------------------------------------------------------------

@test "SC-05: build_all_retained=true → all containers true" {
    # changed_files is empty; operator override must win
    run compute_expand_retained_map "push" "true" "$CHANGED_FILES" '["openresty","postgres"]'
    [ "$status" -eq 0 ]
    or_val=$(echo "$output" | jq -r '.openresty')
    pg_val=$(echo "$output" | jq -r '.postgres')
    [ "$or_val" = "true" ]
    [ "$pg_val" = "true" ]
}

# ---------------------------------------------------------------------------
# SC-11: sibling-name collision — php-fpm/config.yaml must NOT trigger php
# ---------------------------------------------------------------------------

@test "SC-11: php-fpm/config.yaml change does NOT trigger php expansion (exact-match regression-lock)" {
    echo "php-fpm/config.yaml" >> "$CHANGED_FILES"
    run compute_expand_retained_map "push" "false" "$CHANGED_FILES" '["php"]'
    [ "$status" -eq 0 ]
    val=$(echo "$output" | jq -r '.php')
    [ "$val" = "false" ]
}

# ---------------------------------------------------------------------------
# SC-12 / ERR-05: build_all_retained="false" (the STRING) must NOT expand
# ---------------------------------------------------------------------------

@test "SC-12/ERR-05: build_all_retained string 'false' does NOT incorrectly expand" {
    # changed_files empty, build_all_retained is the literal string "false"
    run compute_expand_retained_map "push" "false" "$CHANGED_FILES" '["openresty"]'
    [ "$status" -eq 0 ]
    val=$(echo "$output" | jq -r '.openresty')
    [ "$val" = "false" ]
}

# ---------------------------------------------------------------------------
# SC-13: empty changed_files (no sentinel) → all false
# ---------------------------------------------------------------------------

@test "SC-13: empty changed_files file (no sentinel) → all containers false" {
    # CHANGED_FILES exists but is empty; no .diff_failed sentinel
    run compute_expand_retained_map "push" "false" "$CHANGED_FILES" '["openresty","postgres"]'
    [ "$status" -eq 0 ]
    or_val=$(echo "$output" | jq -r '.openresty')
    pg_val=$(echo "$output" | jq -r '.postgres')
    [ "$or_val" = "false" ]
    [ "$pg_val" = "false" ]
}

# ---------------------------------------------------------------------------
# SC-14: .diff_failed sentinel present → all containers true
# ---------------------------------------------------------------------------

@test "SC-14: .diff_failed sentinel present → all containers true" {
    # Sentinel file alongside changed_files
    touch "${CHANGED_FILES}.diff_failed"
    run compute_expand_retained_map "push" "false" "$CHANGED_FILES" '["openresty","postgres"]'
    [ "$status" -eq 0 ]
    or_val=$(echo "$output" | jq -r '.openresty')
    pg_val=$(echo "$output" | jq -r '.postgres')
    [ "$or_val" = "true" ]
    [ "$pg_val" = "true" ]
}

# ---------------------------------------------------------------------------
# SC-15 / ERR-06: empty event_name → all containers true (legacy caller fallback)
# ---------------------------------------------------------------------------

@test "SC-15/ERR-06: empty event_name → all containers true" {
    run compute_expand_retained_map "" "false" "$CHANGED_FILES" '["openresty"]'
    [ "$status" -eq 0 ]
    val=$(echo "$output" | jq -r '.openresty')
    [ "$val" = "true" ]
}

# ---------------------------------------------------------------------------
# Extra: unknown event_name treated same as empty (ERR-06)
# ---------------------------------------------------------------------------

@test "unknown event_name treated as unrecognized → all containers true" {
    run compute_expand_retained_map "some_made_up_event" "false" "$CHANGED_FILES" '["openresty"]'
    [ "$status" -eq 0 ]
    val=$(echo "$output" | jq -r '.openresty')
    [ "$val" = "true" ]
}

# ---------------------------------------------------------------------------
# Mixed: only one of multiple containers has a dep-change trigger
# ---------------------------------------------------------------------------

@test "mixed: only openresty/config.yaml changed → openresty:true, postgres:false, debian:false" {
    echo "openresty/config.yaml" >> "$CHANGED_FILES"
    run compute_expand_retained_map "push" "false" "$CHANGED_FILES" '["openresty","postgres","debian"]'
    [ "$status" -eq 0 ]
    or_val=$(echo "$output" | jq -r '.openresty')
    pg_val=$(echo "$output" | jq -r '.postgres')
    deb_val=$(echo "$output" | jq -r '.debian')
    [ "$or_val" = "true" ]
    [ "$pg_val" = "false" ]
    [ "$deb_val" = "false" ]
}

# ---------------------------------------------------------------------------
# schedule event without dep trigger → all false (recognized event, dep logic applies)
# ---------------------------------------------------------------------------

@test "schedule event, empty diff → all containers false" {
    # "schedule" is recognized; no dep trigger; no sentinel; no operator override
    run compute_expand_retained_map "schedule" "false" "$CHANGED_FILES" '["openresty","postgres"]'
    [ "$status" -eq 0 ]
    or_val=$(echo "$output" | jq -r '.openresty')
    pg_val=$(echo "$output" | jq -r '.postgres')
    [ "$or_val" = "false" ]
    [ "$pg_val" = "false" ]
}
