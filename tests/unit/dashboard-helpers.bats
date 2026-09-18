#!/usr/bin/env bats

# Unit tests for dashboard helper functions in generate-dashboard.sh
# Covers lineage resolution, version mismatch detection, and fallback chains

setup() {
    TEST_DIR=$(mktemp -d)
    ORIG_DIR="$PWD"
    cd "$TEST_DIR" || exit 1

    # Source generate-dashboard.sh — the BASH_SOURCE guard prevents
    # generate_data from running when sourced, only functions are defined
    source "$ORIG_DIR/helpers/logging.sh" 2>/dev/null || true
    source "$ORIG_DIR/helpers/variant-utils.sh" 2>/dev/null || true
    source "$ORIG_DIR/generate-dashboard.sh" 2>/dev/null || true
    source "$ORIG_DIR/helpers/trivy-utils.sh" 2>/dev/null || true

    # Override SCRIPT_DIR AFTER sourcing — generate-dashboard.sh line 11
    # sets it to dirname "$0", we need it pointing to our test dir
    export SCRIPT_DIR="$TEST_DIR"
}

teardown() {
    cd "$ORIG_DIR" || true
    rm -rf "$TEST_DIR"
}

# --- Helper: create lineage file ---

@test "caller-provided Trivy cache survives the dashboard-profiling suite" {
    local caller_cache="$TEST_DIR/caller-provided-trivy-cache"
    printf 'caller-owned\n' > "$caller_cache"

    run bash -c 'cd "$1" && TRIVY_CACHE_FILE="$2" bats "$3"' _ \
        "$ORIG_DIR" "$caller_cache" "$ORIG_DIR/tests/unit/dashboard-profiling.bats"
    [ "$status" -eq 0 ] || {
        echo "$output" >&2
        return 1
    }
    [ -f "$caller_cache" ]
}

create_lineage_file() {
    local filename="$1"
    local version="$2"
    local build_digest="${3:-abc123def456}"
    local base_image_ref="${4:-postgres:${version}}"

    mkdir -p "$TEST_DIR/.build-lineage"
    cat > "$TEST_DIR/.build-lineage/$filename" <<EOF
{
  "container": "postgres",
  "version": "$version",
  "tag": "$version",
  "flavor": "base",
  "build_digest": "$build_digest",
  "base_image_ref": "$base_image_ref",
  "built_at": "2026-02-02T18:00:00+00:00"
}
EOF
}

# ===================================================================
# resolve_variant_lineage_file
# ===================================================================

@test "resolve_variant_lineage_file: finds primary per-tag file" {
    create_lineage_file "postgres-18-alpine.json" "18-alpine"

    run resolve_variant_lineage_file "postgres" "18-alpine" "base"
    [ "$status" -eq 0 ]
    [[ "$output" == *"postgres-18-alpine.json" ]]
}

@test "resolve_variant_lineage_file: finds variant-specific file" {
    create_lineage_file "postgres-18-alpine-vector.json" "18-alpine"

    run resolve_variant_lineage_file "postgres" "18-alpine-vector" "vector"
    [ "$status" -eq 0 ]
    [[ "$output" == *"postgres-18-alpine-vector.json" ]]
}

@test "resolve_variant_lineage_file: fallback to flavor file" {
    # No per-tag file, but flavor file exists
    create_lineage_file "postgres-vector.json" "18-alpine"

    run resolve_variant_lineage_file "postgres" "18-alpine-vector" "vector"
    [ "$status" -eq 0 ]
    [[ "$output" == *"postgres-vector.json" ]]
}

@test "resolve_variant_lineage_file: fallback to main container file" {
    # No per-tag or per-flavor file, but main container file exists
    create_lineage_file "postgres.json" "18-alpine"

    run resolve_variant_lineage_file "postgres" "18-alpine-vector" "vector"
    [ "$status" -eq 0 ]
    [[ "$output" == *"postgres.json" ]]
}

@test "resolve_variant_lineage_file: returns empty when nothing found" {
    mkdir -p "$TEST_DIR/.build-lineage"

    run resolve_variant_lineage_file "postgres" "18-alpine" "base"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ===================================================================
# resolve_variant_lineage_json — version mismatch detection
# This is the function that had the bug fixed in commit 147e7cc
# ===================================================================

@test "lineage_json: same version — returns real build_digest" {
    create_lineage_file "postgres-18-alpine.json" "18-alpine" "c38236b266dd" "postgres:18-alpine"

    run resolve_variant_lineage_json "postgres" "18-alpine" "18-alpine" "postgres" "base"
    [ "$status" -eq 0 ]
    # Should return the real digest, not "unknown"
    [[ "$output" == *"c38236b266dd"* ]]
}

@test "lineage_json: rolling tag 18-alpine vs full version 18.1-alpine — no mismatch" {
    # This is THE bug that was fixed: lineage has "18-alpine" (build tag),
    # current_version is "18.1-alpine" (full upstream version).
    # Major version 18 matches → digest should be preserved.
    create_lineage_file "postgres-18-alpine.json" "18-alpine" "c38236b266dd" "postgres:18-alpine"

    run resolve_variant_lineage_json "postgres" "18-alpine" "18.1-alpine" "postgres" "base"
    [ "$status" -eq 0 ]
    # Digest must be preserved (not reset to "unknown")
    [[ "$output" == *"c38236b266dd"* ]]
    [[ "$output" != *'"build_digest":"unknown"'* ]]
}

@test "lineage_json: rolling tag 17-alpine vs full version 17.2-alpine — no mismatch" {
    create_lineage_file "postgres-17-alpine.json" "17-alpine" "deadbeef1234" "postgres:17-alpine"

    run resolve_variant_lineage_json "postgres" "17-alpine" "17.2-alpine" "postgres" "base"
    [ "$status" -eq 0 ]
    [[ "$output" == *"deadbeef1234"* ]]
}

@test "lineage_json: rolling tag 16-alpine vs full version 16.8-alpine — no mismatch" {
    create_lineage_file "postgres-16-alpine.json" "16-alpine" "feed0000cafe" "postgres:16-alpine"

    run resolve_variant_lineage_json "postgres" "16-alpine" "16.8-alpine" "postgres" "base"
    [ "$status" -eq 0 ]
    [[ "$output" == *"feed0000cafe"* ]]
}

@test "lineage_json: different major version — triggers mismatch" {
    # Lineage is from PG 17, but current version is PG 18 → mismatch
    create_lineage_file "postgres-18-alpine.json" "17-alpine" "olddigest1234" "postgres:17-alpine"

    run resolve_variant_lineage_json "postgres" "18-alpine" "18.1-alpine" "postgres" "base"
    [ "$status" -eq 0 ]
    # Digest should be reset to "unknown" due to major version mismatch
    [[ "$output" == *'"build_digest":"unknown"'* ]] || [[ "$output" == *"unknown"* ]]
}

@test "lineage_json: no lineage file — returns unknown digest with derived base_image" {
    mkdir -p "$TEST_DIR/.build-lineage"

    run resolve_variant_lineage_json "postgres" "18-alpine" "18.1-alpine" "postgres:18-alpine" "base"
    [ "$status" -eq 0 ]
    [[ "$output" == *"unknown"* ]]
}

@test "lineage_json: exact version match (non-rolling tag like terraform)" {
    create_lineage_file "terraform-1.10.0.json" "1.10.0" "tf_digest_123" "hashicorp/terraform:1.10.0"

    run resolve_variant_lineage_json "terraform" "1.10.0" "1.10.0" "hashicorp/terraform" "base"
    [ "$status" -eq 0 ]
    [[ "$output" == *"tf_digest_123"* ]]
}

@test "lineage_json: latest tag — skips mismatch check (no numeric prefix)" {
    create_lineage_file "terraform-base.json" "1.14.4-alpine" "tf_latest_digest" "hashicorp/terraform:1.14.4"

    run resolve_variant_lineage_json "terraform" "latest-base" "latest" "hashicorp/terraform" "base"
    [ "$status" -eq 0 ]
    [[ "$output" == *"tf_latest_digest"* ]]
}

# ===================================================================
# resolve_variant_lineage_file — multiple PG versions coexisting
# ===================================================================

@test "lineage_file: PG 18 and PG 17 files coexist, correct one resolved" {
    create_lineage_file "postgres-18-alpine.json" "18-alpine" "digest_18"
    create_lineage_file "postgres-17-alpine.json" "17-alpine" "digest_17"

    run resolve_variant_lineage_file "postgres" "18-alpine" "base"
    [[ "$output" == *"postgres-18-alpine.json" ]]

    run resolve_variant_lineage_file "postgres" "17-alpine" "base"
    [[ "$output" == *"postgres-17-alpine.json" ]]
}

@test "lineage_file: variant files resolved independently" {
    create_lineage_file "postgres-18-alpine-vector.json" "18-alpine" "vec_digest"
    create_lineage_file "postgres-18-alpine-analytics.json" "18-alpine" "ana_digest"

    run resolve_variant_lineage_file "postgres" "18-alpine-vector" "vector"
    [[ "$output" == *"postgres-18-alpine-vector.json" ]]

    run resolve_variant_lineage_file "postgres" "18-alpine-analytics" "analytics"
    [[ "$output" == *"postgres-18-alpine-analytics.json" ]]
}

# ===================================================================
# Non-variant trust-strip emission
# Regression test for round-14 non-variant attestation + trivy emission.
# Integration-style: calls generate_data() with mocked helpers so the
# non-variant (has_variants:false) code path is exercised end-to-end.
# ===================================================================

@test "generate_data: non-variant container emits only a well-formed trivy_summary" {
    # ---- fixture: minimal container directory (no variants.yaml) ----
    mkdir -p "$TEST_DIR/myapp"
    printf '#!/bin/bash\necho "1.2.3"\n' > "$TEST_DIR/myapp/version.sh"
    chmod +x "$TEST_DIR/myapp/version.sh"
    printf 'FROM alpine:3.19\n' > "$TEST_DIR/myapp/Dockerfile"

    # Lineage file with oci_subject_digest so trust-strip code path is taken
    mkdir -p "$TEST_DIR/.build-lineage"
    cat > "$TEST_DIR/.build-lineage/myapp-1.2.3.json" <<'EOF'
{
  "container": "myapp",
  "version": "1.2.3",
  "build_digest": "sha256:aaabbbccc",
  "oci_subject_digest": "sha256:deadbeef1234",
  "base_image_ref": "alpine:3.19",
  "built_at": "2026-05-04T00:00:00+00:00"
}
EOF

    # Output dirs expected by generate_data
    mkdir -p "$TEST_DIR/docs/site/_data"
    mkdir -p "$TEST_DIR/docs/site/_containers"

    # Point generate-dashboard.sh globals at TEST_DIR
    export SCRIPT_DIR="$TEST_DIR"
    DATA_FILE="$TEST_DIR/docs/site/_data/containers.yml"
    CONTAINERS_DIR="$TEST_DIR/docs/site/_containers"
    STATS_FILE="$TEST_DIR/docs/site/_data/stats.yml"
    TRIVY_CACHE_FILE=$(mktemp)
    export TRIVY_CACHE_FILE DATA_FILE CONTAINERS_DIR STATS_FILE

    # ---- mock all external helpers ----
    get_current_published_version() { echo "1.2.3"; }
    get_container_build_status()     { echo "success"; }
    populate_container_build_status_cache() { :; }
    get_dockerhub_stats()            { echo "pulls:0 stars:0"; }
    get_ghcr_sizes()                 { echo ""; }
    ghcr_get_manifest_sizes()        { echo ""; }
    get_sbom_summary()               { echo "{}"; }
    get_sbom_packages()              { echo "{}"; }
    get_changelog()                  { echo "{}"; }
    get_build_history()              { echo "[]"; }
    build_trivy_category()           { echo "myapp:1.2.3"; }
    get_attestation_id()             { echo "att-id-xyz"; }
    get_attestation_url()            { echo "https://example.com/att/att-id-xyz"; }
    TEST_NONVARIANT_TRIVY_SUMMARY='{"display_source":"unavailable","last_scan":null,"as_of":null,"counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0},"top_advisories":[],"scan_record":null,"code_scanning":null}'
    get_trivy_summary() {
        [[ "${TEST_NONVARIANT_TRIVY_FAILURE:-false}" == "true" ]] && return 1
        printf '%s\n' "$TEST_NONVARIANT_TRIVY_SUMMARY"
    }
    generate_container_page()        { :; }
    fetch_recent_activity()          { echo "[]"; }
    calculate_build_success_rate()   { echo "5:5:100"; }
    write_stats_file()               { :; }
    export -f get_current_published_version get_container_build_status \
              populate_container_build_status_cache get_dockerhub_stats \
              get_ghcr_sizes ghcr_get_manifest_sizes get_sbom_summary \
              get_sbom_packages get_changelog get_build_history \
              build_trivy_category get_attestation_id get_attestation_url \
              get_trivy_summary generate_container_page fetch_recent_activity \
              calculate_build_success_rate write_stats_file

    # ---- run generate_data (not via `run` — we need side-effects on disk) ----
    generate_data

    # ---- assert: containers.yml contains attestation_url + trivy_summary ----
    [ -f "$DATA_FILE" ]
    yml_content=$(cat "$DATA_FILE")
    [[ "$yml_content" == *"attestation_url"* ]]
    [[ "$yml_content" == *"trivy_summary"* ]]
    [[ "$yml_content" == *"att-id-xyz"* ]]
    [[ "$yml_content" == *"display_source: unavailable"* ]]
    # Validate production schema: counts sub-object must be present (not flat critical/high at top level).
    # yq -P serialises {"counts":{"critical":0,...}} as "counts:\n  critical: 0" in YAML.
    [[ "$yml_content" == *"counts:"* ]]

    # An invalid helper object is an internal invariant failure, not ordinary
    # absence: publish the explicit unavailable state and make it observable.
    TEST_NONVARIANT_TRIVY_SUMMARY='{"display_source":"scan-record","last_scan":"2026-09-04T00:00:00Z","as_of":"2026-09-04T00:00:00Z","counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0},"top_advisories":[],"scan_record":{"scan_at":"2026-09-04T00:00:00Z","counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0}},"code_scanning":{"fetched_at":"2026-09-05T00:00:00Z","counts":{"critical":0,"high":1,"medium":0,"low":0,"info":0},"top_advisories":[]}}'
    run generate_data
    [ "$status" -eq 0 ]
    [[ "$output" == *"invalid helper result"* ]]
    [[ "$output" == *"myapp:1.2.3"* ]]
    run yq -e '.[0].trivy_summary.display_source == "unavailable"' "$DATA_FILE"
    [ "$status" -eq 0 ]

    # A helper failure receives the same treatment rather than the historical
    # empty-object substitution that omitted trivy_summary altogether.
    TEST_NONVARIANT_TRIVY_FAILURE=true
    run generate_data
    [ "$status" -eq 0 ]
    [[ "$output" == *"get_trivy_summary failed"* ]]
    [[ "$output" == *"myapp:1.2.3"* ]]
    run yq -e '.[0].trivy_summary.display_source == "unavailable"' "$DATA_FILE"
    [ "$status" -eq 0 ]

    rm -f "$TRIVY_CACHE_FILE"
}

# ===================================================================
# Variant Trivy-summary emission
# ===================================================================

_collect_variant_yaml_with_trivy_summary() {
    variant_image_tag() { printf '%s-%s\n' "$1" "$2"; }
    variant_property() {
        case "$3" in
            description) printf 'Base variant\n' ;;
            default) printf 'true\n' ;;
            *) printf '\n' ;;
        esac
    }
    resolve_variant_lineage_json() { printf '%s\n' '{"build_digest":"sha256:variant","base_image":"alpine:3.19"}'; }
    get_variant_build_args_json() { printf '[]\n'; }
    get_sbom_summary() { printf '{}\n'; }
    get_sbom_packages() { printf '{}\n'; }
    get_changelog() { printf '{}\n'; }
    get_build_history() { printf '[]\n'; }
    get_attestation_id() { return 1; }
    build_trivy_category() { printf 'variant:1.0-base\n'; }
    ghcr_get_manifest_sizes() { printf '\n'; }
    ghcr_get_multi_arch_digests() {
        [[ -n "${TEST_VARIANT_LOOKUP_MARKER:-}" ]] && : > "$TEST_VARIANT_LOOKUP_MARKER"
        printf '%s\n' "${TEST_VARIANT_MULTI_ARCH_DIGESTS:-}"
    }
    get_trivy_summary() {
        [[ "${TEST_VARIANT_TRIVY_FAILURE:-false}" == "true" ]] && return 1
        printf '%s\n' "$TEST_TRIVY_SUMMARY"
    }
    variant_deps_for_flavor() { printf '[]\n'; }

    collect_variant_json "variant" "$TEST_DIR/variant" "base" "1.0" "alpine:3.19" false "${TEST_VARIANT_PUBLICATION_CONFIRMED:-false}" 2>/dev/null | yq -P
}

@test "collect_variant_json records manifest evidence only from matching exact-tag lineage" {
    mkdir -p "$TEST_DIR/.build-lineage"
    local digest="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    jq -nc --arg digest "$digest" '{container: "variant", tag: "1.0-base", multi_arch_index_digest: $digest}' \
        > "$TEST_DIR/.build-lineage/variant-1.0-base.json"
    TEST_VARIANT_PUBLICATION_CONFIRMED=false
    TEST_VARIANT_MULTI_ARCH_DIGESTS=''
    TEST_VARIANT_LOOKUP_MARKER="$TEST_DIR/registry-lookup-called"
    TEST_TRIVY_SUMMARY='{}'

    run _collect_variant_yaml_with_trivy_summary
    [ "$status" -eq 0 ]
    run yq -e '.publication_observation.registry == "ghcr.io" and .publication_observation.repository == "oorabona/variant" and .publication_observation.tag == "1.0-base" and .publication_observation.source == "exact_lineage_manifest" and .publication_observation.index_digest == "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' <<<"$output"
    [ "$status" -eq 0 ]
    [ ! -e "$TEST_VARIANT_LOOKUP_MARKER" ]

    jq -nc --arg digest "$digest" '{container: "other-container", tag: "1.0-base", multi_arch_index_digest: $digest}' \
        > "$TEST_DIR/.build-lineage/variant-1.0-base.json"
    run _collect_variant_yaml_with_trivy_summary
    [ "$status" -eq 0 ]
    run yq -e 'has("publication_observation") | not' <<<"$output"
    [ "$status" -eq 0 ]
    [ ! -e "$TEST_VARIANT_LOOKUP_MARKER" ]

    jq -nc --arg digest "$digest" '{container: "variant", tag: "another-tag", multi_arch_index_digest: $digest}' \
        > "$TEST_DIR/.build-lineage/variant-1.0-base.json"
    run _collect_variant_yaml_with_trivy_summary
    [ "$status" -eq 0 ]
    run yq -e 'has("publication_observation") | not' <<<"$output"
    [ "$status" -eq 0 ]

    TEST_VARIANT_PUBLICATION_CONFIRMED=false
    jq -nc '{container: "variant", tag: "1.0-base", multi_arch_index_digest: "sha256:not-a-manifest"}' \
        > "$TEST_DIR/.build-lineage/variant-1.0-base.json"
    run _collect_variant_yaml_with_trivy_summary
    [ "$status" -eq 0 ]
    run yq -e 'has("publication_observation") | not' <<<"$output"
    [ "$status" -eq 0 ]
    run yq -e 'has("multi_arch_index_digest") | not' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "collect_variant_json records a live publication observation without exact lineage" {
    local digest="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    TEST_VARIANT_PUBLICATION_CONFIRMED=true
    TEST_VARIANT_MULTI_ARCH_DIGESTS=$(jq -nc --arg digest "$digest" '{index_digest: $digest}')
    TEST_TRIVY_SUMMARY='{}'

    run _collect_variant_yaml_with_trivy_summary
    [ "$status" -eq 0 ]
    run yq -e '.publication_observation.source == "registry_manifest_lookup" and .publication_observation.index_digest == "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "collect_variant_json rejects malformed live publication evidence without exact lineage" {
    TEST_VARIANT_PUBLICATION_CONFIRMED=true
    TEST_VARIANT_MULTI_ARCH_DIGESTS='{"index_digest":"sha256:not-a-manifest","manifest_digest_amd64":""}'
    TEST_TRIVY_SUMMARY='{}'

    run _collect_variant_yaml_with_trivy_summary
    [ "$status" -eq 0 ]
    run yq -e 'has("publication_observation") | not' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "collect_variant_json uses live evidence for partial exact lineage without replacing metadata" {
    mkdir -p "$TEST_DIR/.build-lineage"
    local amd64="sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    local index="sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    jq -nc --arg amd64 "$amd64" '{container: "variant", tag: "1.0-base", multi_arch_platforms: ["linux/amd64"], manifest_digest_amd64: $amd64}' \
        > "$TEST_DIR/.build-lineage/variant-1.0-base.json"
    TEST_VARIANT_PUBLICATION_CONFIRMED=true
    TEST_VARIANT_MULTI_ARCH_DIGESTS=$(jq -nc --arg index "$index" '{index_digest: $index, manifest_digest_amd64: ""}')
    TEST_TRIVY_SUMMARY='{}'

    run _collect_variant_yaml_with_trivy_summary
    [ "$status" -eq 0 ]
    run yq -e '.publication_observation.source == "registry_manifest_lookup" and .publication_observation.index_digest == "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" and .manifest_digest_amd64 == "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd" and .multi_arch_platforms[0] == "linux/amd64" and (.multi_arch_platforms | length) == 1' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "collect_variant_json keeps partial exact metadata when live evidence is malformed" {
    mkdir -p "$TEST_DIR/.build-lineage"
    local amd64="sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
    jq -nc --arg amd64 "$amd64" '{container: "variant", tag: "1.0-base", manifest_digest_amd64: $amd64}' \
        > "$TEST_DIR/.build-lineage/variant-1.0-base.json"
    TEST_VARIANT_PUBLICATION_CONFIRMED=true
    TEST_VARIANT_MULTI_ARCH_DIGESTS='{"index_digest":"sha256:not-a-manifest","manifest_digest_amd64":""}'
    TEST_TRIVY_SUMMARY='{}'

    run _collect_variant_yaml_with_trivy_summary
    [ "$status" -eq 0 ]
    run yq -e 'has("publication_observation") | not and .manifest_digest_amd64 == "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"' <<<"$output"
    [ "$status" -eq 0 ]
}

# ===================================================================
# Variant action bar default publication observation
# Versions-only containers deliberately have no synthesized variants when
# exact lineage is absent. Their current_version observation must therefore
# reach both the rendered no-script fallback and the component as a default.
# ===================================================================

@test "variant action bar renders the versions-only default command in no-script and interactive paths" {
    run node - "$ORIG_DIR/docs/site/_includes/variant-action-bar.html" "$ORIG_DIR/docs/site/assets/js/components/variant-action-bar.js" <<'NODE'
const fs = require('fs');
const vm = require('vm');
const [templatePath, componentPath] = process.argv.slice(2);
const tag = '1.2.3';
const observation = {
  registry: 'ghcr.io', repository: 'oorabona/fixture', tag,
  source: 'registry_manifest_lookup',
  index_digest: 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
};

function escapeAttribute(value) {
  return value.replace(/&/g, '&amp;').replace(/"/g, '&quot;')
    .replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function renderVersionsOnlyActionBar() {
  const source = fs.readFileSync(templatePath, 'utf8');
  const expectedAttribute = 'data-default-publication-observation="{{ _vab_default_publication_observation | jsonify | escape }}"';
  const startTag = source.match(/<variant-action-bar\s+id="variant-action-bar"[\s\S]*?>/);
  if (!startTag || !startTag[0].includes(expectedAttribute)) throw new Error('default observation is not serialized');
  const renderedStartTag = startTag[0].replace(
    expectedAttribute,
    'data-default-publication-observation="' + escapeAttribute(JSON.stringify(observation)) + '"'
  );
  const noScriptStart = source.indexOf('<noscript>');
  const variantDetails = source.indexOf('{%- if page.versions or page.variants -%}', noScriptStart);
  let noScript = source.slice(noScriptStart, variantDetails);
  noScript = noScript.replace(
    /\{%- if _vab_default_has_publication_observation -%\}([\s\S]*?)\{%- else -%\}([\s\S]*?)\{%- endif -%\}/,
    '$1'
  );
  noScript = noScript.replace(/\{\{ page\.github_username \| escape \}\}/g, 'oorabona')
    .replace(/\{\{ page\.name \| escape \}\}/g, 'fixture')
    .replace(/\{\{ _vab_default_tag \| escape \}\}/g, tag);
  return { renderedStartTag, noScript };
}

function loadBar() {
  global.HTMLElement = class {};
  const definitions = {};
  global.customElements = { get: () => undefined, define: (name, value) => { definitions[name] = value; } };
  const modelPath = componentPath.replace('/components/variant-action-bar.js', '/variant-selection-model.js');
  vm.runInThisContext(fs.readFileSync(modelPath, 'utf8'), { filename: modelPath });
  vm.runInThisContext(fs.readFileSync(componentPath, 'utf8'), { filename: componentPath });
  return new definitions['variant-action-bar']();
}

function interactivePull(defaultObservation) {
  const bar = loadBar();
  bar.dataset = {
    container: 'fixture', imageBase: 'ghcr.io/oorabona/fixture', defaultTag: tag,
    defaultVersion: '', defaultFlavor: '', registries: '[{"id":"ghcr","label":"GHCR"}]',
    versions: '[{"tag":"1.2.3","variants":[]}]', flavors: '[]', variants: '[]',
    defaultPublicationObservation: JSON.stringify(defaultObservation)
  };
  bar._parseData();
  const pull = { textContent: '' };
  bar.querySelectorAll = () => [];
  bar.querySelector = (selector) => selector === '[data-vab-cmd="pull"]' ? pull : null;
  bar._updateCollapsedActionsState = () => {};
  bar._updateStickyCommand = () => {};
  bar._updateCommands();
  return pull.textContent;
}

const rendered = renderVersionsOnlyActionBar();
const expected = 'docker pull ghcr.io/oorabona/fixture:' + tag;
if (!rendered.renderedStartTag.includes('data-default-publication-observation="' + escapeAttribute(JSON.stringify(observation)) + '"')) process.exit(1);
if (!rendered.noScript.includes(expected)) process.exit(1);
if (interactivePull(observation) !== expected) process.exit(1);
NODE
    [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "variant action bar rejects default observations whose tag or repository disagrees with the rendered reference" {
    run node - "$ORIG_DIR/docs/site/assets/js/components/variant-action-bar.js" <<'NODE'
const fs = require('fs');
const vm = require('vm');
global.HTMLElement = class {};
const definitions = {};
global.customElements = { get: () => undefined, define: (name, value) => { definitions[name] = value; } };
const modelPath = process.argv[2].replace('/components/variant-action-bar.js', '/variant-selection-model.js');
vm.runInThisContext(fs.readFileSync(modelPath, 'utf8'), { filename: modelPath });
vm.runInThisContext(fs.readFileSync(process.argv[2], 'utf8'), { filename: process.argv[2] });
const bar = new definitions['variant-action-bar']();
bar.dataset = {
  container: 'fixture', imageBase: 'ghcr.io/oorabona/fixture', defaultTag: '1.2.3',
  defaultVersion: '', defaultFlavor: '', registries: '[{"id":"ghcr","label":"GHCR"}]',
  versions: '[{"tag":"1.2.3","variants":[]}]', flavors: '[]', variants: '[]',
  defaultPublicationObservation: JSON.stringify({
    registry: 'ghcr.io', repository: 'oorabona/fixture', tag: 'other-tag', source: 'registry_tag_lookup'
  })
};
bar._parseData();
const pull = { textContent: '' };
bar.querySelectorAll = () => [];
bar.querySelector = (selector) => selector === '[data-vab-cmd="pull"]' ? pull : null;
bar._updateCommands();
if (pull.textContent || bar._hasPublicationObservation(bar._currentVariant, '1.2.3')) process.exit(1);
bar.dataset.defaultPublicationObservation = JSON.stringify({
  registry: 'ghcr.io', repository: 'oorabona/other-fixture', tag: '1.2.3', source: 'registry_tag_lookup'
});
bar._parseData();
if (bar._hasPublicationObservation(bar._currentVariant, '1.2.3')) process.exit(1);
NODE
    [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "variant action bar rejects malformed, absent, and invalid-JSON default observations without throwing" {
    run node - "$ORIG_DIR/docs/site/assets/js/components/variant-action-bar.js" <<'NODE'
const fs = require('fs');
const vm = require('vm');
global.HTMLElement = class {};
const definitions = {};
global.customElements = { get: () => undefined, define: (name, value) => { definitions[name] = value; } };
const modelPath = process.argv[2].replace('/components/variant-action-bar.js', '/variant-selection-model.js');
vm.runInThisContext(fs.readFileSync(modelPath, 'utf8'), { filename: modelPath });
vm.runInThisContext(fs.readFileSync(process.argv[2], 'utf8'), { filename: process.argv[2] });
function hasObservation(value, includeAttribute) {
  const bar = new definitions['variant-action-bar']();
  bar.dataset = {
    container: 'fixture', imageBase: 'ghcr.io/oorabona/fixture', defaultTag: '1.2.3',
    defaultVersion: '', defaultFlavor: '', registries: '[{"id":"ghcr","label":"GHCR"}]',
    versions: '[{"tag":"1.2.3","variants":[]}]', flavors: '[]', variants: '[]'
  };
  if (includeAttribute) bar.dataset.defaultPublicationObservation = value;
  bar._parseData();
  return bar._hasPublicationObservation(bar._currentVariant, '1.2.3');
}
const malformed = JSON.stringify({
  registry: 'ghcr.io', repository: 'oorabona/fixture', tag: '1.2.3',
  source: 'registry_manifest_lookup', index_digest: 'sha256:not-a-manifest'
});
if (hasObservation(malformed, true) || hasObservation('', false) || hasObservation('{not-json', true)) process.exit(1);
NODE
    [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "variant action bar uses a current variant observation instead of the default observation" {
    run node - "$ORIG_DIR/docs/site/assets/js/components/variant-action-bar.js" <<'NODE'
const fs = require('fs');
const vm = require('vm');
global.HTMLElement = class {};
const definitions = {};
global.customElements = { get: () => undefined, define: (name, value) => { definitions[name] = value; } };
const modelPath = process.argv[2].replace('/components/variant-action-bar.js', '/variant-selection-model.js');
vm.runInThisContext(fs.readFileSync(modelPath, 'utf8'), { filename: modelPath });
vm.runInThisContext(fs.readFileSync(process.argv[2], 'utf8'), { filename: process.argv[2] });
const tag = '1.2.3-base';
function isOffered(variantObservation, defaultObservation) {
  const bar = new definitions['variant-action-bar']();
  bar.dataset = {
    container: 'fixture', imageBase: 'ghcr.io/oorabona/fixture', defaultTag: tag,
    defaultVersion: '1.2.3', defaultFlavor: 'base', registries: '[{"id":"ghcr","label":"GHCR"}]',
    versions: '[{"tag":"1.2.3","variants":[{"tag":"1.2.3-base"}]}]', flavors: '[]',
    variants: JSON.stringify([{ tag, version: '1.2.3', flavor: 'base', publication_observation: variantObservation }]),
    defaultPublicationObservation: JSON.stringify(defaultObservation)
  };
  bar._parseData();
  return bar._hasPublicationObservation(bar._currentVariant, tag);
}
const valid = { registry: 'ghcr.io', repository: 'oorabona/fixture', tag, source: 'registry_tag_lookup' };
const invalid = { registry: 'ghcr.io', repository: 'oorabona/fixture', tag: 'other-tag', source: 'registry_tag_lookup' };
if (isOffered(invalid, valid)) process.exit(1);
if (!isOffered(valid, invalid)) process.exit(1);
NODE
    [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "collect_variant_json: Code Scanning evidence without scan record is emitted" {
    TEST_TRIVY_SUMMARY='{"display_source":"code-scanning","last_scan":null,"as_of":"2026-09-05T00:00:00Z","counts":{"critical":1,"high":0,"medium":0,"low":0,"info":0},"top_advisories":[],"scan_record":null,"code_scanning":{"fetched_at":"2026-09-05T00:00:00Z","counts":{"critical":1,"high":0,"medium":0,"low":0,"info":0},"top_advisories":[]}}'

    run _collect_variant_yaml_with_trivy_summary
    [ "$status" -eq 0 ]
    run yq -e '.trivy_summary.display_source == "code-scanning" and .trivy_summary.counts.critical == 1' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "collect_variant_json publishes unavailable evidence for a scan record that hides Code Scanning" {
    TEST_TRIVY_SUMMARY='{"display_source":"scan-record","last_scan":"2026-09-04T00:00:00Z","as_of":"2026-09-04T00:00:00Z","counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0},"top_advisories":[],"scan_record":{"scan_at":"2026-09-04T00:00:00Z","counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0}},"code_scanning":{"fetched_at":"2026-09-05T00:00:00Z","counts":{"critical":0,"high":1,"medium":0,"low":0,"info":0},"top_advisories":[]}}'

    run _collect_variant_yaml_with_trivy_summary
    [ "$status" -eq 0 ]
    run yq -e '.trivy_summary.display_source == "unavailable"' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "collect_variant_json: unavailable evidence is emitted" {
    TEST_TRIVY_SUMMARY='{"display_source":"unavailable","last_scan":null,"as_of":null,"counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0},"top_advisories":[],"scan_record":null,"code_scanning":null}'

    run _collect_variant_yaml_with_trivy_summary
    [ "$status" -eq 0 ]
    run yq -e '.trivy_summary.display_source == "unavailable"' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "collect_variant_json: empty Trivy fallback publishes unavailable evidence" {
    TEST_TRIVY_SUMMARY='{}'

    run _collect_variant_yaml_with_trivy_summary
    [ "$status" -eq 0 ]
    run yq -e '.trivy_summary.display_source == "unavailable"' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "collect_variant_json: malformed Trivy evidence publishes unavailable evidence" {
    TEST_TRIVY_SUMMARY='{"display_source":"bogus","counts":{"critical":0,"high":"2"}}'

    run _collect_variant_yaml_with_trivy_summary
    [ "$status" -eq 0 ]
    run yq -e '.trivy_summary.display_source == "unavailable"' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "collect_variant_json: Trivy helper failure publishes unavailable evidence" {
    TEST_VARIANT_TRIVY_FAILURE=true

    run _collect_variant_yaml_with_trivy_summary
    [ "$status" -eq 0 ]
    run yq -e '.trivy_summary.display_source == "unavailable"' <<<"$output"
    [ "$status" -eq 0 ]
}

# ===================================================================
# .history.json merge logic — jq union+dedup+truncate
# Tests for the update-dashboard.yaml jq pipeline that merges *.history.json
# files across multiple lineage-derived-${run_id} artifacts.
# The expression under test:
#   jq -s 'add | unique_by((.built_at // "") + "/" + (.build_digest // ""))
#          | sort_by(.built_at) | reverse | .[:10]'
# ===================================================================

# Helper: the exact jq expression from the workflow merge block
_history_merge_jq() {
    jq -s 'add | unique_by((.built_at // "") + "/" + (.build_digest // "")) | sort_by(.built_at) | reverse | .[:10]' "$@"
}

@test "history merge: two files with distinct rows produces merged output with both rows" {
    tmp1=$(mktemp --suffix=.json)
    tmp2=$(mktemp --suffix=.json)
    cat > "$tmp1" <<'EOF'
[{"built_at":"2026-05-01T10:00:00Z","build_digest":"sha256:aaa","version":"1.0"}]
EOF
    cat > "$tmp2" <<'EOF'
[{"built_at":"2026-05-02T10:00:00Z","build_digest":"sha256:bbb","version":"1.1"}]
EOF

    result=$(_history_merge_jq "$tmp1" "$tmp2")
    rm -f "$tmp1" "$tmp2"

    count=$(echo "$result" | jq 'length')
    [ "$count" -eq 2 ]
    echo "$result" | jq -e 'any(.[]; .build_digest == "sha256:aaa")' > /dev/null
    echo "$result" | jq -e 'any(.[]; .build_digest == "sha256:bbb")' > /dev/null
}

@test "history merge: two files with identical row produces single row (dedup)" {
    tmp1=$(mktemp --suffix=.json)
    tmp2=$(mktemp --suffix=.json)
    row='[{"built_at":"2026-05-01T10:00:00Z","build_digest":"sha256:aaa","version":"1.0"}]'
    echo "$row" > "$tmp1"
    echo "$row" > "$tmp2"

    result=$(_history_merge_jq "$tmp1" "$tmp2")
    rm -f "$tmp1" "$tmp2"

    count=$(echo "$result" | jq 'length')
    [ "$count" -eq 1 ]
}

@test "history merge: output is sorted newest-first" {
    tmp1=$(mktemp --suffix=.json)
    tmp2=$(mktemp --suffix=.json)
    cat > "$tmp1" <<'EOF'
[{"built_at":"2026-05-01T10:00:00Z","build_digest":"sha256:older","version":"1.0"}]
EOF
    cat > "$tmp2" <<'EOF'
[{"built_at":"2026-05-03T10:00:00Z","build_digest":"sha256:newer","version":"1.2"}]
EOF

    result=$(_history_merge_jq "$tmp1" "$tmp2")
    rm -f "$tmp1" "$tmp2"

    first_digest=$(echo "$result" | jq -r '.[0].build_digest')
    [ "$first_digest" = "sha256:newer" ]
}

@test "history merge: post-merge truncation caps at 10 entries" {
    # Build two files with 7 rows each — 5 shared (dedup to 1), net 9 unique + 5 shared=9 total
    # More precisely: generate 14 distinct rows across two files to get 14 after dedup,
    # then verify truncation keeps only 10.
    tmp1=$(mktemp --suffix=.json)
    tmp2=$(mktemp --suffix=.json)

    # 8 rows in file 1
    jq -n '[range(1;9) | {built_at: ("2026-05-0\(.)T10:00:00Z"), build_digest: ("sha256:file1_\(.)"), version: "1.0"}]' > "$tmp1"
    # 8 rows in file 2 (all distinct built_at + digest)
    jq -n '[range(1;9) | {built_at: ("2026-05-1\(.)T10:00:00Z"), build_digest: ("sha256:file2_\(.)"), version: "1.0"}]' > "$tmp2"

    result=$(_history_merge_jq "$tmp1" "$tmp2")
    rm -f "$tmp1" "$tmp2"

    count=$(echo "$result" | jq 'length')
    # 16 unique rows total, but capped at 10
    [ "$count" -eq 10 ]
}

@test "history merge: null built_at rows dedup correctly (symmetric null-guard)" {
    tmp1=$(mktemp --suffix=.json)
    tmp2=$(mktemp --suffix=.json)
    row='[{"built_at":null,"build_digest":"sha256:nullat","version":"1.0"}]'
    echo "$row" > "$tmp1"
    echo "$row" > "$tmp2"

    result=$(_history_merge_jq "$tmp1" "$tmp2")
    rm -f "$tmp1" "$tmp2"

    count=$(echo "$result" | jq 'length')
    [ "$count" -eq 1 ]
}
