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
       | (has("latest") and has("freshness"))]
      | all
    ' "$CHANGELOG" >/dev/null

    jq -e '
      .changes[]
      | select(.type == "removed" and .name == "oldgem")
      | (has("latest") | not) and (has("freshness") | not)
    ' "$CHANGELOG" >/dev/null

    jq -e '
      .changes[]
      | select(.type == "updated" and .name == "dupe" and .to == "1.5.0")
      | .latest == "2.0.0"
        and .freshness == "update-available"
    ' "$CHANGELOG" >/dev/null

    jq -e '
      .changes[]
      | select(.type == "updated" and .name == "dupe" and .to == "2.0.0")
      | .latest == "2.0.0"
        and .freshness == "up-to-date"
    ' "$CHANGELOG" >/dev/null

    jq -e '
      .changes[]
      | select(.type == "added" and .name == "rack")
      | .latest == "3.1.0"
        and .freshness == "up-to-date"
    ' "$CHANGELOG" >/dev/null

    jq -e '
      .changes[]
      | select(.type == "updated" and .name == "broken")
      | .latest == null
        and .freshness == "query-failed"
    ' "$CHANGELOG" >/dev/null

    jq -e '
      .changes[]
      | select(.type == "updated" and .name == "json")
      | .latest == "2.8.0"
        and .freshness == "update-available"
    ' "$CHANGELOG" >/dev/null

    [[ "$(grep -c '^latest npm dupe$' "$CALL_LOG")" -eq 1 ]]
}

@test "enrich_changelog marks update-available only when latest is greater than installed" {
    cat > "$CHANGELOG" <<'JSON'
{
  "generated_at": "2026-07-03T00:00:00Z",
  "summary": { "added": 0, "removed": 0, "updated": 6 },
  "changes": [
    { "type": "updated", "name": "regressed", "pkg_type": "npm", "from": "2.9.0", "to": "3.0.0" },
    { "type": "updated", "name": "advanced", "pkg_type": "gem", "from": "1.1.0", "to": "1.2.0" },
    { "type": "updated", "name": "equal", "pkg_type": "pypi", "from": "4.5.5", "to": "4.5.6" },
    { "type": "updated", "name": "suffix", "pkg_type": "npm", "from": "1.2.2", "to": "1.2.3-beta.1" },
    { "type": "updated", "name": "apk-regressed", "pkg_type": "apk", "from": "2.9.0-r0", "to": "3.0.0-r0" },
    { "type": "updated", "name": "unparseable", "pkg_type": "npm", "from": "older", "to": "release-candidate" }
  ]
}
JSON

    cat > "$FIXTURE" <<'JSON'
{
  "latest": {
    "npm": {
      "regressed": { "latest": "2.0.0" },
      "suffix": { "latest": "1.2.4-beta.1" },
      "unparseable": { "latest": "2.0.0" }
    },
    "gem": {
      "advanced": { "latest": "1.3.0" }
    },
    "pypi": {
      "equal": { "latest": "4.5.6" }
    },
    "apk": {
      "apk-regressed": { "latest": "2.0.0-r0" }
    }
  }
}
JSON

    run env \
        _DEPENDENCY_FRESHNESS_FIXTURE="$FIXTURE" \
        DEPENDENCY_FRESHNESS_CONCURRENCY=1 \
        bash -c 'source "$1"; source "$2"; enrich_changelog "$3"' \
        _ "$RESOLVER" "$SBOM_UTILS" "$CHANGELOG"

    [[ "$status" -eq 0 ]]
    jq -e '
      .changes[]
      | select(.name == "regressed")
      | .latest == "2.0.0"
        and .freshness == "up-to-date"
    ' "$CHANGELOG" >/dev/null
    jq -e '
      .changes[]
      | select(.name == "advanced")
      | .latest == "1.3.0"
        and .freshness == "update-available"
    ' "$CHANGELOG" >/dev/null
    jq -e '
      .changes[]
      | select(.name == "equal")
      | .latest == "4.5.6"
        and .freshness == "up-to-date"
    ' "$CHANGELOG" >/dev/null
    jq -e '
      .changes[]
      | select(.name == "suffix")
      | .latest == "1.2.4-beta.1"
        and .freshness == "update-available"
    ' "$CHANGELOG" >/dev/null
    jq -e '
      .changes[]
      | select(.name == "apk-regressed")
      | .latest == "2.0.0-r0"
        and .freshness == "up-to-date"
    ' "$CHANGELOG" >/dev/null
    jq -e '
      .changes[]
      | select(.name == "unparseable")
      | .latest == "2.0.0"
        and .freshness == "not-computed"
    ' "$CHANGELOG" >/dev/null
}

@test "enrich_changelog caps total latest-version queries and marks skipped packages not-computed" {
    local warning_log
    warning_log="${TEST_TEMP_DIR}/warnings.log"

    cat > "$CHANGELOG" <<'JSON'
{
  "generated_at": "2026-07-03T00:00:00Z",
  "summary": { "added": 0, "removed": 0, "updated": 4 },
  "changes": [
    { "type": "updated", "name": "zeta", "pkg_type": "npm", "from": "1.0.0", "to": "1.1.0" },
    { "type": "updated", "name": "beta", "pkg_type": "npm", "from": "1.0.0", "to": "1.1.0" },
    { "type": "updated", "name": "alpha", "pkg_type": "npm", "from": "1.0.0", "to": "1.1.0" },
    { "type": "updated", "name": "gamma", "pkg_type": "npm", "from": "1.0.0", "to": "1.1.0" }
  ]
}
JSON

    cat > "$FIXTURE" <<'JSON'
{
  "latest": {
    "npm": {
      "alpha": { "latest": "2.0.0" },
      "beta": { "latest": "2.0.0" },
      "gamma": { "latest": "2.0.0" },
      "zeta": { "latest": "2.0.0" }
    }
  }
}
JSON

    run env \
        _DEPENDENCY_FRESHNESS_FIXTURE="$FIXTURE" \
        DEPENDENCY_FRESHNESS_CALL_LOG="$CALL_LOG" \
        DEPENDENCY_FRESHNESS_CONCURRENCY=1 \
        DEPENDENCY_FRESHNESS_MAX_QUERIES=2 \
        bash -c 'source "$1"; source "$2"; enrich_changelog "$3" 2>"$4"' \
        _ "$RESOLVER" "$SBOM_UTILS" "$CHANGELOG" "$warning_log"

    [[ "$status" -eq 0 ]]
    grep -q '^latest npm alpha$' "$CALL_LOG"
    grep -q '^latest npm beta$' "$CALL_LOG"
    if grep -q '^latest npm gamma$' "$CALL_LOG"; then
        fail "gamma should have been skipped by the freshness query cap"
    fi
    if grep -q '^latest npm zeta$' "$CALL_LOG"; then
        fail "zeta should have been skipped by the freshness query cap"
    fi
    jq -e '
      [.changes[]
       | select(.name == "alpha" or .name == "beta")
       | .latest == "2.0.0" and .freshness == "update-available"]
      | all
    ' "$CHANGELOG" >/dev/null
    jq -e '
      [.changes[]
       | select(.name == "gamma" or .name == "zeta")
       | .latest == null and .freshness == "not-computed"]
      | all
    ' "$CHANGELOG" >/dev/null
    grep -q 'Dependency freshness query cap reached: checking 2 of 4 unique packages; skipped 2 packages as not-computed' "$warning_log"
}

@test "apk repository discovery copies repositories without running image code" {
    local fakebin docker_args repos_file
    fakebin="${TEST_TEMP_DIR}/bin"
    docker_args="${TEST_TEMP_DIR}/docker.args"
    repos_file="${TEST_TEMP_DIR}/repositories"
    printf '%s\n' "https://dl-cdn.alpinelinux.org/alpine/v3.20/main" > "$repos_file"
    mkdir -p "$fakebin"
    cat > "${fakebin}/docker" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$DOCKER_ARGS_FILE"
case "$1" in
    create)
        [[ "$*" == *"--platform linux/amd64"* ]] || exit 42
        [[ "$*" == *"example:test"* ]] || exit 42
        printf '%s\n' "created-container"
        ;;
    cp)
        [[ "$2" == "created-container:/etc/apk/repositories" ]] || exit 42
        cp "$REPOS_FILE" "$3"
        ;;
    rm)
        [[ "$2" == "created-container" ]] || exit 42
        ;;
    run)
        exit 99
        ;;
    *)
        exit 42
        ;;
esac
SH
    chmod +x "${fakebin}/docker"

    run env \
        PATH="${fakebin}:$PATH" \
        DOCKER_ARGS_FILE="$docker_args" \
        REPOS_FILE="$repos_file" \
        DEPENDENCY_FRESHNESS_IMAGE_REF="example:test" \
        DEPENDENCY_FRESHNESS_PLATFORM="linux/amd64" \
        bash -c 'source "$1"; _freshness_apk_repositories' \
        _ "$RESOLVER"

    [[ "$status" -eq 0 ]]
    [[ "$output" == "https://dl-cdn.alpinelinux.org/alpine/v3.20/main" ]]
    grep -q '^create --platform linux/amd64 example:test$' "$docker_args"
    grep -q '^cp created-container:/etc/apk/repositories ' "$docker_args"
    grep -q '^rm created-container$' "$docker_args"
    if grep -q '^run ' "$docker_args"; then
        fail "docker run should not be used for APK repository discovery"
    fi
}

@test "apk repository URLs skip tagged repositories and reject untrusted fetch targets" {
    local repos expected
    repos=$'@edgecommunity https://dl-cdn.alpinelinux.org/alpine/edge/community\nhttps://dl-cdn.alpinelinux.org/alpine/v3.20/main\nhttp://dl-cdn.alpinelinux.org/alpine/v3.20/main\nhttps://example.invalid/not-alpine\nhttps://evil.invalid/alpine/v3.20/main'
    expected="https://dl-cdn.alpinelinux.org/alpine/v3.20/main/x86_64/APKINDEX.tar.gz"

    run bash -c 'source "$1"; _freshness_apk_index_urls "x86_64" "$2" 2>/dev/null' \
        _ "$RESOLVER" "$repos"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"$expected"* ]]
    [[ "$output" != *"/edge/community/"* ]]
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

@test "apk latest selection ignores versions from tagged repositories" {
    local main_index edge_index repos result_file download_log
    main_index="${TEST_TEMP_DIR}/main.APKINDEX.tar.gz"
    edge_index="${TEST_TEMP_DIR}/edge.APKINDEX.tar.gz"
    result_file="${TEST_TEMP_DIR}/apk-result.json"
    download_log="${TEST_TEMP_DIR}/tagged-downloads.log"

    write_apk_index_tarball "$main_index" $'P:foo\nV:1.0.0-r0\n\n'
    write_apk_index_tarball "$edge_index" $'P:foo\nV:9.9.9-r0\n\n'
    repos=$'@edge https://dl-cdn.alpinelinux.org/alpine/edge/main\nhttps://dl-cdn.alpinelinux.org/alpine/v3.20/main'

    run env \
        MAIN_INDEX="$main_index" \
        EDGE_INDEX="$edge_index" \
        DOWNLOAD_LOG="$download_log" \
        DEPENDENCY_FRESHNESS_PLATFORM="linux/amd64" \
        DEPENDENCY_FRESHNESS_APK_REPOSITORIES="$repos" \
        bash -c '
          source "$1"
          _freshness_http_download() {
            printf "%s\n" "$1" >> "$DOWNLOAD_LOG"
            case "$1" in
              */edge/main/*) cp "$EDGE_INDEX" "$2" ;;
              */v3.20/main/*) cp "$MAIN_INDEX" "$2" ;;
              *) return 1 ;;
            esac
          }
          _freshness_apk foo > "$2"
        ' _ "$RESOLVER" "$result_file"

    [[ "$status" -eq 0 ]]
    jq -e '.latest == "1.0.0-r0" and .query_failed == false' "$result_file" >/dev/null
    if grep -q '/edge/main/' "$download_log"; then
        fail "tagged APK repositories should not be downloaded"
    fi
}

@test "enrich_changelog resets APK image platform and index state per container in one shell" {
    local first_changelog second_changelog first_index second_index first_repos second_repos fakebin docker_log download_log
    first_changelog="${TEST_TEMP_DIR}/first.changelog.json"
    second_changelog="${TEST_TEMP_DIR}/second.changelog.json"
    first_index="${TEST_TEMP_DIR}/first.APKINDEX.tar.gz"
    second_index="${TEST_TEMP_DIR}/second.APKINDEX.tar.gz"
    first_repos="${TEST_TEMP_DIR}/first.repositories"
    second_repos="${TEST_TEMP_DIR}/second.repositories"
    fakebin="${TEST_TEMP_DIR}/bin"
    docker_log="${TEST_TEMP_DIR}/docker.log"
    download_log="${TEST_TEMP_DIR}/downloads.log"

    write_apk_index_tarball "$first_index" $'P:widget\nV:1.0.0-r0\n\n'
    write_apk_index_tarball "$second_index" $'P:widget\nV:2.0.0-r0\n\n'
    printf '%s\n' "https://dl-cdn.alpinelinux.org/alpine/v3.20/main" > "$first_repos"
    printf '%s\n' "https://dl-cdn.alpinelinux.org/alpine/v3.21/main" > "$second_repos"

    mkdir -p "$fakebin"
    cat > "${fakebin}/docker" <<'SH'
#!/bin/bash
case "$1" in
    create)
        image_ref=""
        for arg in "$@"; do
            case "$arg" in
                ghcr.io/example/first:latest|ghcr.io/example/second:latest)
                    image_ref="$arg"
                    ;;
            esac
        done
        printf '%s\n' "$image_ref" >> "$DOCKER_LOG"
        case "$image_ref" in
            ghcr.io/example/first:latest) printf '%s\n' "first-container" ;;
            ghcr.io/example/second:latest) printf '%s\n' "second-container" ;;
            *) exit 1 ;;
        esac
        ;;
    cp)
        case "$2" in
            first-container:/etc/apk/repositories) cp "$FIRST_REPOS" "$3" ;;
            second-container:/etc/apk/repositories) cp "$SECOND_REPOS" "$3" ;;
            *) exit 1 ;;
        esac
        ;;
    rm)
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
SH
    chmod +x "${fakebin}/docker"

    cat > "$first_changelog" <<'JSON'
{
  "generated_at": "2026-07-03T00:00:00Z",
  "summary": { "added": 0, "removed": 0, "updated": 1 },
  "changes": [
    { "type": "updated", "name": "widget", "pkg_type": "apk", "from": "0.9.0-r0", "to": "1.0.0-r0" }
  ]
}
JSON

    cat > "${TEST_TEMP_DIR}/first.json" <<'JSON'
{
  "images": { "ghcr": "ghcr.io/example/first:latest" },
  "platform": "linux/amd64"
}
JSON

    cat > "$second_changelog" <<'JSON'
{
  "generated_at": "2026-07-03T00:00:00Z",
  "summary": { "added": 0, "removed": 0, "updated": 1 },
  "changes": [
    { "type": "updated", "name": "widget", "pkg_type": "apk", "from": "1.9.0-r0", "to": "2.0.0-r0" }
  ]
}
JSON

    cat > "${TEST_TEMP_DIR}/second.json" <<'JSON'
{
  "images": { "ghcr": "ghcr.io/example/second:latest" },
  "platform": "linux/arm64"
}
JSON

    run env \
        PATH="${fakebin}:$PATH" \
        DOCKER_LOG="$docker_log" \
        DOWNLOAD_LOG="$download_log" \
        FIRST_INDEX="$first_index" \
        SECOND_INDEX="$second_index" \
        FIRST_REPOS="$first_repos" \
        SECOND_REPOS="$second_repos" \
        DEPENDENCY_FRESHNESS_APK_REPOSITORY_ALLOW_REGEX='^https://dl-cdn\.alpinelinux\.org/alpine/' \
        DEPENDENCY_FRESHNESS_CONCURRENCY=1 \
        bash -c '
          source "$1"
          source "$2"
          _freshness_http_download() {
            printf "%s\n" "$1" >> "$DOWNLOAD_LOG"
            case "$1" in
              */v3.20/main/x86_64/APKINDEX.tar.gz) cp "$FIRST_INDEX" "$2" ;;
              */v3.21/main/aarch64/APKINDEX.tar.gz) cp "$SECOND_INDEX" "$2" ;;
              *) return 1 ;;
            esac
          }
          enrich_changelog "$3"
          enrich_changelog "$4"
        ' _ "$RESOLVER" "$SBOM_UTILS" "$first_changelog" "$second_changelog"

    [[ "$status" -eq 0 ]]
    jq -e '
      .changes[]
      | select(.name == "widget")
      | .latest == "1.0.0-r0"
        and .freshness == "up-to-date"
    ' "$first_changelog" >/dev/null
    jq -e '
      .changes[]
      | select(.name == "widget")
      | .latest == "2.0.0-r0"
        and .freshness == "up-to-date"
    ' "$second_changelog" >/dev/null
    grep -q '^ghcr.io/example/first:latest$' "$docker_log"
    grep -q '^ghcr.io/example/second:latest$' "$docker_log"
    grep -q '/v3.20/main/x86_64/APKINDEX.tar.gz$' "$download_log"
    grep -q '/v3.21/main/aarch64/APKINDEX.tar.gz$' "$download_log"
}

@test "enrich_changelog clears stale APK image and platform when lineage is missing" {
    local first_changelog second_changelog first_index first_repos fakebin docker_log download_log
    first_changelog="${TEST_TEMP_DIR}/first.changelog.json"
    second_changelog="${TEST_TEMP_DIR}/second.changelog.json"
    first_index="${TEST_TEMP_DIR}/first.APKINDEX.tar.gz"
    first_repos="${TEST_TEMP_DIR}/first.repositories"
    fakebin="${TEST_TEMP_DIR}/bin"
    docker_log="${TEST_TEMP_DIR}/docker.log"
    download_log="${TEST_TEMP_DIR}/downloads.log"

    write_apk_index_tarball "$first_index" $'P:widget\nV:1.0.0-r0\n\n'
    printf '%s\n' "https://dl-cdn.alpinelinux.org/alpine/v3.20/main" > "$first_repos"

    mkdir -p "$fakebin"
    cat > "${fakebin}/docker" <<'SH'
#!/bin/bash
case "$1" in
    create)
        printf '%s\n' "$*" >> "$DOCKER_LOG"
        [[ "$*" == *"ghcr.io/example/first:latest"* ]] || exit 1
        printf '%s\n' "first-container"
        ;;
    cp)
        cp "$FIRST_REPOS" "$3"
        ;;
    rm)
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
SH
    chmod +x "${fakebin}/docker"

    cat > "$first_changelog" <<'JSON'
{
  "generated_at": "2026-07-03T00:00:00Z",
  "summary": { "added": 0, "removed": 0, "updated": 1 },
  "changes": [
    { "type": "updated", "name": "widget", "pkg_type": "apk", "from": "0.9.0-r0", "to": "1.0.0-r0" }
  ]
}
JSON

    cat > "${TEST_TEMP_DIR}/first.json" <<'JSON'
{
  "images": { "ghcr": "ghcr.io/example/first:latest" },
  "platform": "linux/amd64"
}
JSON

    cat > "$second_changelog" <<'JSON'
{
  "generated_at": "2026-07-03T00:00:00Z",
  "summary": { "added": 0, "removed": 0, "updated": 1 },
  "changes": [
    { "type": "updated", "name": "widget", "pkg_type": "apk", "from": "0.9.0-r0", "to": "1.0.0-r0" }
  ]
}
JSON

    run env \
        PATH="${fakebin}:$PATH" \
        DOCKER_LOG="$docker_log" \
        DOWNLOAD_LOG="$download_log" \
        FIRST_INDEX="$first_index" \
        FIRST_REPOS="$first_repos" \
        DEPENDENCY_FRESHNESS_APK_REPOSITORY_ALLOW_REGEX='^https://dl-cdn\.alpinelinux\.org/alpine/' \
        DEPENDENCY_FRESHNESS_CONCURRENCY=1 \
        bash -c '
          source "$1"
          source "$2"
          _freshness_http_download() {
            printf "%s\n" "$1" >> "$DOWNLOAD_LOG"
            case "$1" in
              */v3.20/main/x86_64/APKINDEX.tar.gz) cp "$FIRST_INDEX" "$2" ;;
              *) return 1 ;;
            esac
          }
          enrich_changelog "$3"
          enrich_changelog "$4"
        ' _ "$RESOLVER" "$SBOM_UTILS" "$first_changelog" "$second_changelog"

    [[ "$status" -eq 0 ]]
    jq -e '
      .changes[]
      | select(.name == "widget")
      | .latest == "1.0.0-r0"
        and .freshness == "up-to-date"
    ' "$first_changelog" >/dev/null
    jq -e '
      .changes[]
      | select(.name == "widget")
      | .latest == null
        and .freshness == "query-failed"
    ' "$second_changelog" >/dev/null
    [[ "$(grep -c '^create ' "$docker_log")" -eq 1 ]]
    [[ "$(grep -c '/v3.20/main/x86_64/APKINDEX.tar.gz$' "$download_log")" -eq 1 ]]
}

@test "apk version comparison fallback follows Alpine suffix ordering" {
    run bash -c 'source "$1"; _freshness_apk_version_gt "1.0.0" "1.0.0_rc1"' _ "$RESOLVER"
    [[ "$status" -eq 0 ]]

    run bash -c 'source "$1"; _freshness_apk_version_gt "1.0.0_rc1" "1.0.0"' _ "$RESOLVER"
    [[ "$status" -ne 0 ]]

    run bash -c 'source "$1"; _freshness_apk_version_gt "1.0.0_p1" "1.0.0"' _ "$RESOLVER"
    [[ "$status" -eq 0 ]]
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
    ' "$CHANGELOG" >/dev/null
    if [[ -f "$CALL_LOG" ]] && grep -q '^latest deb libssl3$' "$CALL_LOG"; then
        fail "deb packages should not be queried for dependency freshness"
    fi
}

@test "PyPI-only changelog resolves only the changed PyPI package" {
    cat > "$CHANGELOG" <<'JSON'
{
  "generated_at": "2026-07-03T00:00:00Z",
  "summary": { "added": 0, "removed": 0, "updated": 1 },
  "changes": [
    { "type": "updated", "name": "requests", "pkg_type": "pypi", "from": "2.32.0", "to": "2.32.3" }
  ]
}
JSON

    cat > "$FIXTURE" <<'JSON'
{
  "latest": {
    "pypi": {
      "requests": { "latest": "2.32.3" }
    }
  }
}
JSON

    run env \
        _DEPENDENCY_FRESHNESS_FIXTURE="$FIXTURE" \
        DEPENDENCY_FRESHNESS_CALL_LOG="$CALL_LOG" \
        DEPENDENCY_FRESHNESS_CONCURRENCY=8 \
        bash -c 'source "$1"; source "$2"; enrich_changelog "$3"' \
        _ "$RESOLVER" "$SBOM_UTILS" "$CHANGELOG"

    [[ "$status" -eq 0 ]]
    grep -q '^latest pypi requests$' "$CALL_LOG"
    if grep -q '^latest npm ' "$CALL_LOG"; then
        fail "PyPI-only changelog should not query npm"
    fi
    if grep -q '^latest gem ' "$CALL_LOG"; then
        fail "PyPI-only changelog should not query gem"
    fi
}

@test "container detail layout escapes changelog JSON data attributes" {
    local layout
    layout="${PROJECT_ROOT}/docs/site/_layouts/container-detail.html"

    [[ "$(grep -c "data-changelog='{{ .* | jsonify | escape }}" "$layout")" -eq 3 ]]
    if grep -q "data-changelog='{{ .* | jsonify }}'" "$layout"; then
        fail "changelog JSON data attributes should be escaped"
    fi
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
