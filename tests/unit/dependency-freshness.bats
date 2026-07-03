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
