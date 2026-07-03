#!/usr/bin/env bats

# Unit tests for SBOM changelog dependency freshness enrichment.
# All tests are fixture-driven (no registry network calls).

setup() {
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
    RESOLVER="${PROJECT_ROOT}/helpers/dependency-freshness.sh"
    SBOM_UTILS="${PROJECT_ROOT}/helpers/sbom-utils.sh"
    TEST_TEMP_DIR="$(mktemp -d)"
    CHANGELOG="${TEST_TEMP_DIR}/synthetic.changelog.json"
    CURRENT_SBOM="${TEST_TEMP_DIR}/current.sbom.json"
    FIXTURE="${TEST_TEMP_DIR}/freshness-fixture.json"
    CALL_LOG="${TEST_TEMP_DIR}/calls.log"
}

teardown() {
    rm -rf "$TEST_TEMP_DIR"
}

write_synthetic_changelog() {
    cat > "$CHANGELOG" <<'JSON'
{
  "generated_at": "2026-07-03T00:00:00Z",
  "summary": { "added": 1, "removed": 1, "updated": 5 },
  "changes": [
    { "type": "updated", "name": "dupe", "pkg_type": "npm", "from": "1.4.0", "to": "1.5.0" },
    { "type": "updated", "name": "dupe", "pkg_type": "npm", "from": "1.5.0", "to": "2.0.0" },
    { "type": "updated", "name": "parent", "pkg_type": "npm", "from": "0.9.0", "to": "1.0.0" },
    { "type": "updated", "name": "broken", "pkg_type": "npm", "from": "0.1.0", "to": "0.2.0" },
    { "type": "added", "name": "rack", "pkg_type": "gem", "version": "3.1.0" },
    { "type": "updated", "name": "json", "pkg_type": "gem", "from": "2.6.0", "to": "2.7.0" },
    { "type": "removed", "name": "oldgem", "pkg_type": "gem", "version": "0.1.0" }
  ]
}
JSON
}

write_freshness_fixture() {
    cat > "$FIXTURE" <<'JSON'
{
  "latest": {
    "npm": {
      "dupe": { "latest": "2.0.0" },
      "parent": { "latest": "1.0.0" },
      "broken": { "latest": null, "query_failed": true }
    },
    "gem": {
      "rack": { "latest": "3.1.0" },
      "json": { "latest": "2.8.0" }
    }
  },
  "manifests": {
    "npm": {
      "dupe@1.5.0": {},
      "dupe@2.0.0": {},
      "parent@1.0.0": {
        "dependencies": { "dupe": "^1.0.0" }
      },
      "broken@0.2.0": {}
    },
    "gem": {
      "rack": [
        { "number": "3.1.0", "dependencies": { "runtime": [] } }
      ],
      "json": [
        { "number": "2.7.0", "dependencies": { "runtime": [] } }
      ]
    }
  }
}
JSON
}

write_apk_index_tarball() {
    local tarball="$1"
    local content="$2"
    local index_dir
    index_dir="$(mktemp -d "${TEST_TEMP_DIR}/apk-index.XXXXXX")"
    printf '%b' "$content" > "${index_dir}/APKINDEX"
    tar -czf "$tarball" -C "$index_dir" APKINDEX
}

assert_range_includes() {
    local pkg_type="$1"
    local range="$2"
    local version="$3"

    run bash -c 'source "$1"; _freshness_range_includes "$2" "$3" "$4"' \
        _ "$RESOLVER" "$pkg_type" "$range" "$version"
    [[ "$status" -eq 0 ]]
}

assert_range_excludes() {
    local pkg_type="$1"
    local range="$2"
    local version="$3"

    run bash -c 'source "$1"; _freshness_range_includes "$2" "$3" "$4"' \
        _ "$RESOLVER" "$pkg_type" "$range" "$version"
    [[ "$status" -ne 0 ]]
}

@test "enrich_changelog labels updated and added rows, leaves removed untouched, and fails open per row" {
    write_synthetic_changelog
    write_freshness_fixture

    run env \
        _DEPENDENCY_FRESHNESS_FIXTURE="$FIXTURE" \
        DEPENDENCY_FRESHNESS_CONCURRENCY=1 \
        DEPENDENCY_FRESHNESS_CALL_LOG="$CALL_LOG" \
        bash -c 'source "$1"; source "$2"; enrich_changelog "$3"' \
        _ "$RESOLVER" "$SBOM_UTILS" "$CHANGELOG"

    [[ "$status" -eq 0 ]]

    jq -e '
      [.changes[] | select(.type == "updated" or .type == "added")
       | (has("latest") and has("freshness") and has("capped_by"))]
      | all
    ' "$CHANGELOG" >/dev/null

    jq -e '
      .changes[]
      | select(.type == "removed" and .name == "oldgem")
      | (has("latest") | not) and (has("freshness") | not) and (has("capped_by") | not)
    ' "$CHANGELOG" >/dev/null

    jq -e '
      .changes[]
      | select(.type == "updated" and .name == "dupe" and .to == "1.5.0")
      | .latest == "2.0.0"
        and .freshness == "capped"
        and .capped_by == "parent ^1.0.0"
    ' "$CHANGELOG" >/dev/null

    jq -e '
      .changes[]
      | select(.type == "updated" and .name == "dupe" and .to == "2.0.0")
      | .latest == "2.0.0"
        and .freshness == "up-to-date"
        and .capped_by == null
    ' "$CHANGELOG" >/dev/null

    jq -e '
      .changes[]
      | select(.type == "added" and .name == "rack")
      | .latest == "3.1.0"
        and .freshness == "up-to-date"
        and .capped_by == null
    ' "$CHANGELOG" >/dev/null

    jq -e '
      .changes[]
      | select(.type == "updated" and .name == "broken")
      | .latest == null
        and .freshness == "query-failed"
        and .capped_by == null
    ' "$CHANGELOG" >/dev/null

    jq -e '
      .changes[]
      | select(.type == "updated" and .name == "json")
      | .latest == "2.8.0"
        and .freshness == "constraint-not-detected"
        and .capped_by == null
    ' "$CHANGELOG" >/dev/null

    [[ "$(grep -c '^latest npm dupe$' "$CALL_LOG")" -eq 1 ]]
}

@test "enrich_changelog detects caps from unchanged parents in the current SBOM" {
    cat > "$CHANGELOG" <<'JSON'
{
  "generated_at": "2026-07-03T00:00:00Z",
  "summary": { "added": 0, "removed": 0, "updated": 1 },
  "changes": [
    { "type": "updated", "name": "child", "pkg_type": "npm", "from": "1.0.0", "to": "1.5.0" }
  ]
}
JSON

    cat > "$CURRENT_SBOM" <<'JSON'
{
  "SPDXID": "SPDXRef-DOCUMENT",
  "packages": [
    {
      "name": "parent",
      "versionInfo": "1.0.0",
      "externalRefs": [
        { "referenceCategory": "PACKAGE-MANAGER", "referenceLocator": "pkg:npm/parent@1.0.0" }
      ]
    },
    {
      "name": "child",
      "versionInfo": "1.5.0",
      "externalRefs": [
        { "referenceCategory": "PACKAGE-MANAGER", "referenceLocator": "pkg:npm/child@1.5.0" }
      ]
    }
  ]
}
JSON

    cat > "$FIXTURE" <<'JSON'
{
  "latest": {
    "npm": {
      "child": { "latest": "2.0.0" }
    }
  },
  "manifests": {
    "npm": {
      "parent@1.0.0": { "dependencies": { "child": "^1.0.0" } },
      "child@1.5.0": {}
    }
  }
}
JSON

    run env \
        _DEPENDENCY_FRESHNESS_FIXTURE="$FIXTURE" \
        DEPENDENCY_FRESHNESS_CONCURRENCY=1 \
        DEPENDENCY_FRESHNESS_CALL_LOG="$CALL_LOG" \
        bash -c 'source "$1"; source "$2"; enrich_changelog "$3" "$4"' \
        _ "$RESOLVER" "$SBOM_UTILS" "$CHANGELOG" "$CURRENT_SBOM"

    [[ "$status" -eq 0 ]]
    jq -e '
      .changes[]
      | select(.name == "child")
      | .latest == "2.0.0"
        and .freshness == "capped"
        and .capped_by == "parent ^1.0.0"
    ' "$CHANGELOG" >/dev/null
    grep -q '^manifest npm parent@1.0.0$' "$CALL_LOG"
    ! grep -q '^latest npm parent$' "$CALL_LOG"
}

@test "range parser handles common npm and RubyGems requirement forms" {
    assert_range_includes gem "~> 2.0" "2.5.0"
    assert_range_excludes gem "~> 2.0" "3.0.0"
    assert_range_includes gem ">= 0" "0.1.0"

    assert_range_includes npm ">= 1.0.0" "1.2.0"
    assert_range_includes npm "1.2.x" "1.2.9"
    assert_range_excludes npm "1.2.x" "1.3.0"
    assert_range_includes npm "1.2" "1.2.5"
    assert_range_excludes npm "1.2" "1.3.0"
    assert_range_includes npm "~1" "1.9.9"
    assert_range_excludes npm "~1" "2.0.0"
    assert_range_includes npm "1.2.0 - 1.4.0" "1.3.0"
    assert_range_excludes npm "1.2.0 - 1.4.0" "1.5.0"
    assert_range_includes npm "0.5.x || >= 1.0.0" "0.5.2"

    run bash -c 'source "$1"; _freshness_semver_cmp "2.0.0-alpha" "2.0.0"' _ "$RESOLVER"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "-1" ]]
}

@test "apk repository discovery overrides image entrypoint" {
    local fakebin docker_args
    fakebin="${TEST_TEMP_DIR}/bin"
    docker_args="${TEST_TEMP_DIR}/docker.args"
    mkdir -p "$fakebin"
    cat > "${fakebin}/docker" <<'SH'
#!/bin/bash
printf '%s\n' "$*" > "$DOCKER_ARGS_FILE"
if [[ "$*" == *"--entrypoint cat"* ]]; then
    printf '%s\n' "https://dl-cdn.alpinelinux.org/alpine/v3.20/main"
    exit 0
fi
exit 42
SH
    chmod +x "${fakebin}/docker"

    run env \
        PATH="${fakebin}:$PATH" \
        DOCKER_ARGS_FILE="$docker_args" \
        DEPENDENCY_FRESHNESS_IMAGE_REF="example:test" \
        bash -c 'source "$1"; _freshness_apk_repositories' \
        _ "$RESOLVER"

    [[ "$status" -eq 0 ]]
    [[ "$output" == "https://dl-cdn.alpinelinux.org/alpine/v3.20/main" ]]
    grep -q -- '--entrypoint cat' "$docker_args"
}

@test "apk repository URLs parse tags and reject untrusted fetch targets" {
    local repos expected
    repos=$'@edgecommunity https://dl-cdn.alpinelinux.org/alpine/edge/community\nhttp://dl-cdn.alpinelinux.org/alpine/v3.20/main\nhttps://example.invalid/not-alpine\nhttps://evil.invalid/alpine/v3.20/main'
    expected="https://dl-cdn.alpinelinux.org/alpine/edge/community/x86_64/APKINDEX.tar.gz"

    run bash -c 'source "$1"; _freshness_apk_index_urls "x86_64" "$2" 2>/dev/null' \
        _ "$RESOLVER" "$repos"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"$expected"* ]]
    [[ "$output" != *"http://dl-cdn"* ]]
    [[ "$output" != *"example.invalid"* ]]
    [[ "$output" != *"evil.invalid"* ]]
}

@test "apk latest selection keeps highest version across multiple repositories" {
    local main_index community_index repos result_file
    main_index="${TEST_TEMP_DIR}/main.APKINDEX.tar.gz"
    community_index="${TEST_TEMP_DIR}/community.APKINDEX.tar.gz"
    result_file="${TEST_TEMP_DIR}/apk-result.json"

    write_apk_index_tarball "$community_index" $'P:foo\nV:1.0.0-r0\n\n'
    write_apk_index_tarball "$main_index" $'P:foo\nV:1.0.0-r1\n\n'
    repos=$'https://dl-cdn.alpinelinux.org/alpine/v3.20/community\nhttps://dl-cdn.alpinelinux.org/alpine/v3.20/main'

    run env \
        MAIN_INDEX="$main_index" \
        COMMUNITY_INDEX="$community_index" \
        DEPENDENCY_FRESHNESS_PLATFORM="linux/amd64" \
        DEPENDENCY_FRESHNESS_APK_REPOSITORIES="$repos" \
        bash -c '
          source "$1"
          _freshness_http_download() {
            case "$1" in
              */community/*) cp "$COMMUNITY_INDEX" "$2" ;;
              */main/*) cp "$MAIN_INDEX" "$2" ;;
              *) return 1 ;;
            esac
          }
          _freshness_apk foo > "$2"
        ' _ "$RESOLVER" "$result_file"

    [[ "$status" -eq 0 ]]
    jq -e '.latest == "1.0.0-r1" and .query_failed == false' "$result_file" >/dev/null
}

@test "deb packages are marked not-computed instead of querying Debian source packages" {
    cat > "$CHANGELOG" <<'JSON'
{
  "generated_at": "2026-07-03T00:00:00Z",
  "summary": { "added": 0, "removed": 0, "updated": 1 },
  "changes": [
    { "type": "updated", "name": "libssl3", "pkg_type": "deb", "from": "3.0.13", "to": "3.0.14" }
  ]
}
JSON

    run env \
        DEPENDENCY_FRESHNESS_CALL_LOG="$CALL_LOG" \
        bash -c 'source "$1"; source "$2"; enrich_changelog "$3"' \
        _ "$RESOLVER" "$SBOM_UTILS" "$CHANGELOG"

    [[ "$status" -eq 0 ]]
    jq -e '
      .changes[]
      | select(.name == "libssl3")
      | .latest == null
        and .freshness == "not-computed"
        and .capped_by == null
    ' "$CHANGELOG" >/dev/null
    [[ ! -f "$CALL_LOG" ]] || ! grep -q '^latest deb libssl3$' "$CALL_LOG"
}

@test "malformed npm and gem constraint responses do not discard valid rows" {
    local npm_batch gem_batch npm_out gem_out
    npm_out="${TEST_TEMP_DIR}/npm-constraints.json"
    gem_out="${TEST_TEMP_DIR}/gem-constraints.json"
    npm_batch='[
      {"pkg_type":"npm","name":"bad-parent","installed":"1.0.0"},
      {"pkg_type":"npm","name":"good-parent","installed":"1.0.0"}
    ]'
    gem_batch='[
      {"pkg_type":"gem","name":"bad-gem","installed":"1.0.0"},
      {"pkg_type":"gem","name":"good-gem","installed":"1.0.0"}
    ]'

    run bash -c '
      source "$1"
      _freshness_fetch_npm_manifest() {
        if [[ "$1" == "bad-parent" ]]; then
          printf "%s\n" "{not-json"
        else
          jq -cn "{dependencies:{child:\"^1.0.0\"}}"
        fi
      }
      DEPENDENCY_FRESHNESS_CONCURRENCY=1
      _freshness_npm_constraints_for_batch "$2" > "$3"
    ' _ "$RESOLVER" "$npm_batch" "$npm_out"
    [[ "$status" -eq 0 ]]
    jq -e 'length == 1 and .[0].parent == "good-parent" and .[0].child == "child"' "$npm_out" >/dev/null

    run bash -c '
      source "$1"
      _freshness_fetch_gem_versions() {
        if [[ "$1" == "bad-gem" ]]; then
          printf "%s\n" "[not-json"
        else
          jq -cn "[{number:\"1.0.0\",dependencies:{runtime:[{name:\"child\",requirements:\"~> 2.0\"}]}}]"
        fi
      }
      DEPENDENCY_FRESHNESS_CONCURRENCY=1
      _freshness_gem_constraints_for_batch "$2" > "$3"
    ' _ "$RESOLVER" "$gem_batch" "$gem_out"
    [[ "$status" -eq 0 ]]
    jq -e 'length == 1 and .[0].parent == "good-gem" and .[0].child == "child"' "$gem_out" >/dev/null
}

@test "constraint manifest fetching supports bounded parallel workers" {
    local batch out
    out="${TEST_TEMP_DIR}/parallel-constraints.json"
    batch='[
      {"pkg_type":"npm","name":"parent-a","installed":"1.0.0"},
      {"pkg_type":"npm","name":"parent-b","installed":"1.0.0"}
    ]'

    cat > "$FIXTURE" <<'JSON'
{
  "manifests": {
    "npm": {
      "parent-a@1.0.0": { "dependencies": { "child-a": "^1.0.0" } },
      "parent-b@1.0.0": { "dependencies": { "child-b": "^2.0.0" } }
    }
  }
}
JSON

    run env \
        _DEPENDENCY_FRESHNESS_FIXTURE="$FIXTURE" \
        DEPENDENCY_FRESHNESS_CONCURRENCY=2 \
        bash -c 'source "$1"; _freshness_constraints_for_batch npm "$2" > "$3"' \
        _ "$RESOLVER" "$batch" "$out"

    [[ "$status" -eq 0 ]]
    jq -e '
      length == 2
      and ([.[].child] | sort) == ["child-a", "child-b"]
    ' "$out" >/dev/null
}

@test "enrich_changelog returns nonzero when final changelog write fails" {
    local locked_dir locked_changelog
    locked_dir="${TEST_TEMP_DIR}/locked"
    locked_changelog="${locked_dir}/fail.changelog.json"
    mkdir -p "$locked_dir"

    cat > "$locked_changelog" <<'JSON'
{
  "generated_at": "2026-07-03T00:00:00Z",
  "summary": { "added": 0, "removed": 0, "updated": 1 },
  "changes": [
    { "type": "updated", "name": "pkg", "pkg_type": "npm", "from": "1.0.0", "to": "1.1.0" }
  ]
}
JSON

    cat > "$FIXTURE" <<'JSON'
{
  "latest": {
    "npm": {
      "pkg": { "latest": "1.1.0" }
    }
  },
  "manifests": {
    "npm": {
      "pkg@1.1.0": {}
    }
  }
}
JSON

    chmod 500 "$locked_dir"
    run env \
        _DEPENDENCY_FRESHNESS_FIXTURE="$FIXTURE" \
        DEPENDENCY_FRESHNESS_CONCURRENCY=1 \
        bash -c 'source "$1"; source "$2"; enrich_changelog "$3"' \
        _ "$RESOLVER" "$SBOM_UTILS" "$locked_changelog"
    chmod 700 "$locked_dir"

    [[ "$status" -ne 0 ]]
}
