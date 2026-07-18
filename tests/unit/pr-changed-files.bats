#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
    ORIG_DIR="$PWD"
    TEST_DIR=$(mktemp -d)
    HELPER="$BATS_TEST_DIRNAME/../../helpers/pr-changed-files.sh"
    # shellcheck source=../../helpers/pr-changed-files.sh
    source "$HELPER"
}

teardown() {
    cd "$ORIG_DIR" || true
    rm -rf "$TEST_DIR"
}

init_repo() {
    local repo="$1"
    mkdir -p "$repo"
    cd "$repo" || return 1
    git init -q
    git symbolic-ref HEAD refs/heads/master
    mkdir -p "$repo/.git/hooks-disabled"
    git config core.hooksPath "$repo/.git/hooks-disabled"
    git config commit.gpgSign false
    git config tag.gpgSign false
    git config user.email "test@example.com"
    git config user.name "Test"
}

commit_file() {
    local path="$1"
    local content="$2"
    local message="$3"

    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$content" > "$path"
    git add "$path"
    git commit -q -m "$message"
}

@test "regression: PR diff excludes files changed only on advanced base" {
    init_repo "$TEST_DIR/regression"
    commit_file "a" "base" "test: add base"
    base_sha=$(git rev-parse HEAD)

    git checkout -q -b feat
    commit_file "pr.txt" "pr" "test: add pr file"
    feat_head_sha=$(git rev-parse HEAD)

    git checkout -q master
    git checkout -q -b advanced-base "$base_sha"
    commit_file "master-only.txt" "master" "test: add base-only file"
    advanced_base_sha=$(git rev-parse HEAD)

    run pr_changed_files "$advanced_base_sha" "$feat_head_sha"

    [ "$status" -eq 0 ]
    [ "$output" = "pr.txt" ]
    [[ "$output" != *"master-only.txt"* ]]
}

@test "happy path: branch adding one file returns that file" {
    init_repo "$TEST_DIR/happy"
    commit_file "a" "base" "test: add base"
    base_sha=$(git rev-parse HEAD)

    git checkout -q -b feat
    commit_file "one.txt" "one" "test: add one file"
    head_sha=$(git rev-parse HEAD)

    run pr_changed_files "$base_sha" "$head_sha"

    [ "$status" -eq 0 ]
    [ "$output" = "one.txt" ]
}

@test "branch with no changes since merge-base returns empty output and exit 0" {
    init_repo "$TEST_DIR/no-changes"
    commit_file "a" "base" "test: add base"
    base_sha=$(git rev-parse HEAD)

    git checkout -q -b feat
    head_sha=$(git rev-parse HEAD)

    run pr_changed_files "$base_sha" "$head_sha"

    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "rename emits both old and new paths" {
    init_repo "$TEST_DIR/rename"
    commit_file "postgres/foo" "base" "test: add postgres file"
    base_sha=$(git rev-parse HEAD)

    git checkout -q -b feat
    mkdir -p openresty
    git mv postgres/foo openresty/foo
    git commit -q -m "test: move file between containers"
    head_sha=$(git rev-parse HEAD)

    run pr_changed_files "$base_sha" "$head_sha"

    [ "$status" -eq 0 ]
    [[ "$output" == *"postgres/foo"* ]]
    [[ "$output" == *"openresty/foo"* ]]
}

@test "misuse: wrong arg count returns non-zero and writes usage to stderr" {
    run --separate-stderr pr_changed_files "only-one-arg"

    [ "$status" -ne 0 ]
    [ "$output" = "" ]
    [[ "$stderr" == *"usage: pr_changed_files <base_sha> <head_sha>"* ]]
}

@test "merge-base unavailable returns non-zero without unsafe two-dot fallback" {
    init_repo "$TEST_DIR/unrelated"
    commit_file "base-only.txt" "base" "test: add base root"
    base_sha=$(git rev-parse HEAD)

    git checkout -q --orphan other
    git rm -q -rf .
    commit_file "head-only.txt" "head" "test: add head root"
    head_sha=$(git rev-parse HEAD)

    run --separate-stderr pr_changed_files "$base_sha" "$head_sha"

    [ "$status" -eq 3 ]
    [ "$output" = "" ]
    [[ "$stderr" == *"merge-base unavailable for PR diff"* ]]
    [[ "$stderr" == *"refusing unsafe two-dot fallback"* ]]
}
