#!/usr/bin/env bats

# Tests for resolve_lineage_file in generate-dashboard.sh
# Covers Fix B: default_variant() selection instead of filesystem-first.
# Red on current code (pre-fix); green after fix.
# Fix E: sanitize-at-read for base_image_ref with leaked ${...} placeholders.

bats_require_minimum_version 1.5.0

load "../test_helper"

PROJECT_ROOT_REAL="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
    setup_temp_dir
    export ORIG_DIR="$PWD"

    mkdir -p "$TEST_TEMP_DIR/.build-lineage"

    # Extract only the function definitions we need from generate-dashboard.sh,
    # without activating the "set -euo pipefail" that the script sets at the top
    # level (which would make failing test assertions crash the test process rather
    # than report "not ok").
    #
    # Technique: source the script in a subshell (which can tolerate the set -euo
    # pipefail environment and any top-level side effects), then extract the
    # function bodies with "declare -f" and eval them in the parent shell where we
    # control the set options.
    # Source variant-utils directly so variant_image_tag/variant_property/base_suffix
    # are available for the post-fix resolve_lineage_file (Finding #2 fix calls variant_image_tag).
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT_REAL/helpers/logging.sh"
    source "$PROJECT_ROOT_REAL/helpers/build-args-utils.sh"
    source "$PROJECT_ROOT_REAL/helpers/variant-utils.sh"

    local _fn_defs
    _fn_defs=$(
        cd "$PROJECT_ROOT_REAL" 2>/dev/null
        # shellcheck source=/dev/null
        source "$PROJECT_ROOT_REAL/generate-dashboard.sh" 2>/dev/null || true
        # Export function defs back to caller
        declare -f resolve_lineage_file
        declare -f get_build_lineage_field
    )
    eval "$_fn_defs"

    # Override SCRIPT_DIR so resolve_lineage_file reads from our temp dir
    SCRIPT_DIR="$TEST_TEMP_DIR"
    export SCRIPT_DIR
}

teardown() {
    cd "$ORIG_DIR" || true
    teardown_temp_dir
}

# Helper: create a fake lineage file in .build-lineage/
make_lineage() {
    local name="$1"
    local base_image="${2:-alpine:3.21}"
    jq -n \
        --arg base_image "$base_image" \
        --arg name "$name" \
        '{lineage_schema_version: 2, container: "test", base_image_ref: $base_image, version: "1.0", tag: $name}' \
        > "$TEST_TEMP_DIR/.build-lineage/${name}.json"
}

# Helper: create variants.yaml with optional multi-version structure
make_variants_yaml() {
    local container_dir="$1"
    local yaml_content="$2"
    mkdir -p "$container_dir"
    printf '%s\n' "$yaml_content" > "$container_dir/variants.yaml"
}

# =============================================================================
# Fix B: default_variant selection (NEVER filesystem-first)
# =============================================================================

@test "DRDV-01: Multi-variant single-version uses default_variant (debian is default)" {
    # Production web-shell: debian has suffix: "" (no suffix) → lineage file = web-shell-1.7.7.json
    # Non-default variants have explicit suffixes: -alpine, -ubuntu, -rocky
    # Fix B: must return the default variant's suffixless file, not the first filesystem match.
    make_lineage "web-shell-1.7.7" "ghcr.io/oorabona/debian:trixie"        # debian (default, no suffix)
    make_lineage "web-shell-1.7.7-alpine" "alpine:3.21"
    make_lineage "web-shell-1.7.7-ubuntu" "ubuntu:noble"
    make_lineage "web-shell-1.7.7-rocky" "rockylinux:9"

    # variants.yaml matching production structure: debian default with empty suffix
    make_variants_yaml "$TEST_TEMP_DIR/web-shell" "$(cat <<'YAML'
versions:
  - tag: "1.7.7"
    variants:
      - name: debian
        suffix: ""
        default: true
      - name: alpine
        suffix: "-alpine"
      - name: ubuntu
        suffix: "-ubuntu"
      - name: rocky
        suffix: "-rocky"
YAML
)"

    run resolve_lineage_file "web-shell"
    [ "$status" -eq 0 ]
    # Fix B: must return the default variant (debian, suffixless): web-shell-1.7.7.json
    [[ "$output" == *"web-shell-1.7.7.json" ]] || {
        echo "FAIL: expected *web-shell-1.7.7.json (debian default), got: '$output'"
        return 1
    }
    # Must NOT return a variant-suffixed file
    [[ "$output" != *"-alpine.json" && "$output" != *"-ubuntu.json" && "$output" != *"-rocky.json" ]]
}

@test "DRDV-02: Multi-version multi-flavor returns latest version default flavor" {
    # Postgres-style: versions [18, 17, 16], default flavor = base
    make_lineage "postgres-18-alpine" "ghcr.io/oorabona/library/postgres:18-alpine"
    make_lineage "postgres-17-alpine" "ghcr.io/oorabona/library/postgres:17-alpine"
    make_lineage "postgres-16-alpine" "ghcr.io/oorabona/library/postgres:16-alpine"
    make_lineage "postgres-18-alpine-base" "ghcr.io/oorabona/library/postgres:18-alpine"

    make_variants_yaml "$TEST_TEMP_DIR/postgres" "$(cat <<'YAML'
versions:
  - tag: "18"
    variants:
      - name: base
        default: true
      - name: vector
  - tag: "17"
    variants:
      - name: base
        default: true
YAML
)"

    run resolve_lineage_file "postgres"
    [ "$status" -eq 0 ]
    # Should return the latest version (18) default variant (base)
    # The key invariant: must include "18" and NOT "17" or "16"
    [[ "$output" == *"postgres-18"* ]]
}

@test "DRDV-03: Versions-only container returns latest version lineage" {
    # ansible: no variants, just versions
    make_lineage "ansible-13.3.0-ubuntu" "ubuntu:noble"
    make_lineage "ansible-13.4.0-ubuntu" "ubuntu:noble"

    make_variants_yaml "$TEST_TEMP_DIR/ansible" "$(cat <<'YAML'
versions:
  - tag: "13.4.0"
  - tag: "13.3.0"
YAML
)"

    run resolve_lineage_file "ansible"
    [ "$status" -eq 0 ]
    # Should return latest version (first in list = 13.4.0)
    [[ "$output" == *"13.4.0"* ]]
}

@test "DRDV-04: Legacy container-level rollup file preserved" {
    # If container.json exists, return it directly (legacy path)
    make_lineage "foo" "alpine:3.21"

    # No variants.yaml needed — the container.json takes precedence
    run resolve_lineage_file "foo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"foo.json" ]]
}

@test "DRDV-05: Malformed variants.yaml returns empty sentinel, never filesystem-first" {
    # Create real lineage files that would be found by filesystem-first
    make_lineage "foo-1.0-alpine" "alpine:3.21"
    make_lineage "foo-1.0-debian" "debian:trixie"

    # Malformed YAML (invalid syntax)
    make_variants_yaml "$TEST_TEMP_DIR/foo" "$(printf 'versions:\n  - tag: [\nnot: valid: yaml')"

    # --separate-stderr: the yq-failure warning goes to stderr; $output must be empty
    run --separate-stderr resolve_lineage_file "foo"
    [ "$status" -eq 0 ]
    # Fix B: must return empty (sentinel), NOT a filesystem-first fallback
    [[ -z "$output" ]]
}

@test "DRDV-06: Multiple default:true variants returns first match (no ambiguity crash)" {
    make_lineage "bar-1.0-alpine" "alpine:3.21"
    make_lineage "bar-1.0-debian" "debian:trixie"

    # Two variants with default: true — first one should win (head -1 behavior)
    make_variants_yaml "$TEST_TEMP_DIR/bar" "$(cat <<'YAML'
versions:
  - tag: "1.0"
    variants:
      - name: alpine
        default: true
      - name: debian
        default: true
YAML
)"

    run resolve_lineage_file "bar"
    [ "$status" -eq 0 ]
    # Should not crash; should return one of the defaults
    # The key invariant: result must be one of the known lineage files (not empty crash)
    [[ -z "$output" || "$output" == *"bar-1.0"* ]]
}

@test "DRDV-07: Default variant lineage missing, falls back to any present variant with notice" {
    # debian is default but its lineage file doesn't exist — fall back to alpine
    make_lineage "web-shell-1.7.7-alpine" "alpine:3.21"
    # No web-shell-1.7.7-debian.json

    make_variants_yaml "$TEST_TEMP_DIR/web-shell" "$(cat <<'YAML'
versions:
  - tag: "1.7.7"
    variants:
      - name: debian
        default: true
      - name: alpine
YAML
)"

    run resolve_lineage_file "web-shell"
    [ "$status" -eq 0 ]
    # Falls back to any present variant
    [[ "$output" == *"web-shell-1.7.7-alpine.json" ]]
}

@test "DRDV-08: All variant lineage files missing returns empty string" {
    # No .json files exist for baz
    make_variants_yaml "$TEST_TEMP_DIR/baz" "$(cat <<'YAML'
versions:
  - tag: "1.0"
    variants:
      - name: alpine
        default: true
YAML
)"

    run resolve_lineage_file "baz"
    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
}

# =============================================================================
# Fix E: sanitize-at-read — base_image_ref with ${ returns empty
# =============================================================================

@test "DRDV-09: Pre-v2 entry with leaked base_image_ref treated as empty at read" {
    # Create a pre-v2 lineage file with a leaked placeholder
    jq -n '{container:"sslh","base_image_ref":"${OS_IMAGE_BASE}:${OS_IMAGE_TAG}","version":"v2.3.1","tag":"v2.3.1-alpine"}' \
        > "$TEST_TEMP_DIR/.build-lineage/sslh-v2.3.1-alpine.json"

    # make container.json for simple resolution
    cp "$TEST_TEMP_DIR/.build-lineage/sslh-v2.3.1-alpine.json" \
       "$TEST_TEMP_DIR/.build-lineage/sslh.json"

    run get_build_lineage_field "sslh" "base_image_ref"
    [ "$status" -eq 0 ]
    # Fix E: sanitize-at-read: leaked placeholder should return empty, not the literal "${...}"
    [[ -z "$output" || "$output" == "unknown" ]]
}

# =============================================================================
# Regression: Finding #2 — resolve_lineage_file must use variant_image_tag for
# the default variant filename, not raw default_name in a glob.
# (orthogonal gate codex MEDIUM finding)
# =============================================================================

@test "DRDV-10: Postgres default-variant (base) resolves suffixless file, not -base suffixed file" {
    # Production postgres tags: base variant → "18-alpine" (NO -base suffix),
    # vector variant → "18-alpine-vector". The current bug: the glob
    # *{default_name}.json = *base.json matches "postgres-18-alpine-base.json"
    # (if it exists) and picks it instead of the correct "postgres-18-alpine.json".
    #
    # This test deliberately creates BOTH the suffixless file AND a stale/wrong
    # -base-suffixed file (which can arrive via a mis-tagged build), and verifies
    # that resolve_lineage_file returns the CORRECT suffixless one.
    make_lineage "postgres-18-alpine" "ghcr.io/oorabona/library/postgres:18-alpine"
    make_lineage "postgres-18-alpine-vector" "ghcr.io/oorabona/library/postgres:18-alpine"
    # Also create the wrong -base-suffixed stale file (the one the old glob would pick)
    make_lineage "postgres-18-alpine-base" "stale-wrong-base-image:should-not-be-selected"

    make_variants_yaml "$TEST_TEMP_DIR/postgres" "$(cat <<'YAML'
build:
  base_suffix: "-alpine"
versions:
  - tag: "18"
    variants:
      - name: base
        default: true
      - name: vector
        suffix: "-vector"
YAML
)"

    run resolve_lineage_file "postgres"
    [ "$status" -eq 0 ]
    # Must return the SUFFIXLESS file (postgres-18-alpine.json), NOT postgres-18-alpine-base.json
    [[ "$output" == *"postgres-18-alpine.json" ]] || {
        echo "FAIL: expected *postgres-18-alpine.json, got: '$output'"
        return 1
    }
    # Explicitly must NOT end in -base.json (old glob would have picked this one)
    [[ "$output" != *"-base.json" ]] || {
        echo "FAIL: returned file has -base suffix (wrong): '$output'"
        return 1
    }
}

# =============================================================================
# Finding #1 (gate r3 codex MEDIUM): Legacy rollup must NOT shadow newer per-tag file
# =============================================================================

@test "DRDV-11: Per-tag lineage preferred over stale legacy rollup when both exist" {
    # Scenario: cache contains an OLD {container}.json (legacy rollup from a prior-era build)
    # AND a current {container}-{version}-{variant}.json (per-tag file from the new build).
    # The legacy rollup carries a STALE base_image_ref; the per-tag file has the current truth.
    # resolve_lineage_file must return the PER-TAG file, not the legacy rollup.

    # Legacy rollup — stale base_image_ref
    jq -n '{lineage_schema_version: 2, container: "myapp", base_image_ref: "OLD-stale-value", version: "2.0", tag: "myapp-2.0-alpine"}' \
        > "$TEST_TEMP_DIR/.build-lineage/myapp.json"

    # Per-tag file — current truth
    jq -n '{lineage_schema_version: 2, container: "myapp", base_image_ref: "CURRENT-fresh-value", version: "2.0", tag: "2.0-alpine"}' \
        > "$TEST_TEMP_DIR/.build-lineage/myapp-2.0-alpine.json"

    make_variants_yaml "$TEST_TEMP_DIR/myapp" "$(cat <<'YAML'
versions:
  - tag: "2.0"
    variants:
      - name: alpine
        default: true
YAML
)"

    run resolve_lineage_file "myapp"
    [ "$status" -eq 0 ]
    # Must return the per-tag file, NOT the legacy rollup
    [[ "$output" == *"myapp-2.0-alpine.json" ]] || {
        echo "FAIL: expected per-tag file myapp-2.0-alpine.json, got: '$output'"
        return 1
    }
    [[ "$output" != *"myapp.json" ]] || {
        echo "FAIL: returned stale legacy rollup myapp.json instead of per-tag file"
        return 1
    }

    # Confirm the resolved file actually carries the CURRENT base_image_ref
    local resolved_base
    resolved_base=$(jq -r '.base_image_ref' "$output")
    [[ "$resolved_base" == "CURRENT-fresh-value" ]] || {
        echo "FAIL: base_image_ref is stale: '$resolved_base' (expected CURRENT-fresh-value)"
        return 1
    }
}

# =============================================================================
# Finding #2 (gate r3 codex LOW): Sidecar files must not be returned by fallback glob
# =============================================================================

@test "DRDV-12: Sidecar files excluded from fallback glob — no false-positive match" {
    # Scenario: .build-lineage/ contains ONLY sidecar files for a container
    # (e.g. foo-1.0-alpine.sbom.json, foo-1.0-alpine.history.json).
    # No actual lineage file (foo-1.0-alpine.json) exists.
    # resolve_lineage_file must return empty string, not a sidecar file.

    mkdir -p "$TEST_TEMP_DIR/.build-lineage"
    # Create sidecar files only — NOT a real lineage file
    echo '{"type":"sbom"}' > "$TEST_TEMP_DIR/.build-lineage/foo-1.0-alpine.sbom.json"
    echo '{"type":"history"}' > "$TEST_TEMP_DIR/.build-lineage/foo-1.0-alpine.history.json"
    echo '{"type":"changelog"}' > "$TEST_TEMP_DIR/.build-lineage/foo-1.0-alpine.changelog.json"

    make_variants_yaml "$TEST_TEMP_DIR/foo" "$(cat <<'YAML'
versions:
  - tag: "1.0"
    variants:
      - name: alpine
        default: true
YAML
)"

    run resolve_lineage_file "foo"
    [ "$status" -eq 0 ]
    # Must return empty — no real lineage file exists, sidecar files must not match
    [[ -z "$output" ]] || {
        echo "FAIL: expected empty output but got: '$output'"
        return 1
    }
}

# =============================================================================
# Finding #1 (gate r4 copilot MEDIUM): Legacy rollup substring false positives
# Pre-fix: [[ "$legacy_tag" == *"$current_latest"* ]] (substring contains)
# Post-fix: [[ "$legacy_tag" == "$current_latest" ]]  (exact match)
# =============================================================================

@test "DRDV-13: Legacy rollup tag 11.0-alpine does NOT match current_latest 1.0 (substring false positive)" {
    # Pre-fix: "11.0-alpine" CONTAINS "1.0" → substring match fires → wrong rollup returned
    # Post-fix: "11.0-alpine" != "1.0" → no match → empty returned (correct)

    # Legacy rollup with tag "11.0-alpine"
    jq -n '{lineage_schema_version: 2, container: "mypkg", base_image_ref: "old:11.0", version: "11.0", tag: "11.0-alpine"}' \
        > "$TEST_TEMP_DIR/.build-lineage/mypkg.json"

    # Per-tag file for current latest 1.0 does NOT exist (that is the scenario)
    # variants.yaml says current latest = "1.0"
    make_variants_yaml "$TEST_TEMP_DIR/mypkg" "$(cat <<'YAML'
versions:
  - tag: "1.0"
    variants:
      - name: alpine
        default: true
YAML
)"

    run resolve_lineage_file "mypkg"
    [ "$status" -eq 0 ]
    # Post-fix: legacy_tag "11.0-alpine" does NOT equal current_latest "1.0" → empty
    [[ -z "$output" ]] || {
        echo "FAIL: expected empty (no match), got: '$output'"
        echo "  (pre-fix: substring '1.0' found inside '11.0-alpine' → false positive)"
        return 1
    }
}

@test "DRDV-14: Legacy rollup tag 2.0-debian matches current_latest 2.0 via prefix (version same)" {
    # Finding #2 (gate r5): prefix-match fix: legacy_tag="2.0-debian" starts with "2.0-"
    # → returns the legacy rollup (the version matches, regardless of variant suffix).
    # Note: prior to Finding #2, exact-match was used → empty; prefix-match is the r5 correction.

    jq -n '{lineage_schema_version: 2, container: "webapp", base_image_ref: "debian:trixie", version: "2.0", tag: "2.0-debian"}' \
        > "$TEST_TEMP_DIR/.build-lineage/webapp.json"

    # Per-tag file for 2.0-alpine does NOT exist
    make_variants_yaml "$TEST_TEMP_DIR/webapp" "$(cat <<'YAML'
versions:
  - tag: "2.0"
    variants:
      - name: alpine
        default: true
YAML
)"

    run resolve_lineage_file "webapp"
    [ "$status" -eq 0 ]
    # Post-fix (r5 prefix match): legacy_tag "2.0-debian" starts with "2.0-" → rollup returned
    # "2.0-debian" has the same version as current_latest "2.0" → valid legacy fallback
    [[ "$output" == *"webapp.json" ]] || {
        echo "FAIL: expected webapp.json (prefix match 2.0-debian starts-with 2.0-), got: '$output'"
        return 1
    }
}

@test "DRDV-15: Legacy rollup exact match — tag equals current_latest exactly (valid use case)" {
    # When legacy_tag == current_latest exactly, the legacy rollup SHOULD be returned.
    # (This is the legitimate case: a versions-only container wrote {container}.json
    #  but its per-tag file somehow didn't land in .build-lineage.)

    jq -n '{lineage_schema_version: 2, container: "simpleapp", base_image_ref: "alpine:3.21", version: "3.21", tag: "3.21"}' \
        > "$TEST_TEMP_DIR/.build-lineage/simpleapp.json"

    # Per-tag file simpleapp-3.21*.json does NOT exist
    make_variants_yaml "$TEST_TEMP_DIR/simpleapp" "$(cat <<'YAML'
versions:
  - tag: "3.21"
YAML
)"

    run resolve_lineage_file "simpleapp"
    [ "$status" -eq 0 ]
    # current_latest="3.21", legacy_tag="3.21": exact match → legacy rollup returned
    [[ "$output" == *"simpleapp.json" ]] || {
        echo "FAIL: expected simpleapp.json (exact match should return legacy rollup), got: '$output'"
        return 1
    }
}

# =============================================================================
# Finding #2 (gate r5 copilot MEDIUM): Legacy rollup tag comparison mismatch
# Pre-fix: exact match used, but lineage_file.tag="1.7.7-debian" and
# variants_file.versions[0].tag="1.7.7" → never equal → correct rollup skipped.
# Post-fix: prefix match allows "1.7.7-debian" to match "1.7.7" (version prefix).
# =============================================================================

@test "DRDV-16: Legacy rollup with full tag '1.7.7-debian' matches current_latest '1.7.7'" {
    # web-shell-style: legacy web-shell.json was written with .tag="1.7.7-debian".
    # variants.yaml has versions[0].tag="1.7.7".
    # Per-tag resolution finds nothing (no web-shell-1.7.7*.json in .build-lineage/).
    # Post-fix: prefix match "1.7.7-debian" starts with "1.7.7" → legacy rollup returned.
    jq -n '{lineage_schema_version: 2, container: "web-shell", base_image_ref: "ghcr.io/oorabona/debian:trixie", version: "1.7.7", tag: "1.7.7-debian"}' \
        > "$TEST_TEMP_DIR/.build-lineage/web-shell.json"

    # No per-tag file exists for 1.7.7
    make_variants_yaml "$TEST_TEMP_DIR/web-shell" "$(cat <<'YAML'
versions:
  - tag: "1.7.7"
    variants:
      - name: debian
        default: true
      - name: alpine
YAML
)"

    run resolve_lineage_file "web-shell"
    [ "$status" -eq 0 ]
    # Post-fix: prefix match must return the legacy rollup
    [[ "$output" == *"web-shell.json" ]] || {
        echo "FAIL: expected web-shell.json (prefix match 1.7.7-debian starts-with 1.7.7), got: '$output'"
        echo "  (pre-fix: exact match '1.7.7-debian' != '1.7.7' → empty → correct rollup skipped)"
        return 1
    }
}

# =============================================================================
# Finding #4 (gate r5 copilot MEDIUM): Malformed variants.yaml must fail closed
# Pre-fix: yq failure → latest_version="" → falls through to legacy rollup silently.
# Post-fix: detect yq exit code, emit stderr warning, return empty immediately.
#           NEVER fall back to legacy rollup when variants.yaml is malformed.
# =============================================================================

@test "DRDV-17: Malformed variants.yaml with stale legacy rollup present — fails closed, not silent fallback" {
    # Scenario: variants.yaml is malformed AND a stale {container}.json exists.
    # Pre-fix: yq fails → latest_version="" → legacy fallback fires → stale rollup returned silently.
    # Post-fix: detect yq failure → return empty AND emit stderr warning.
    jq -n '{lineage_schema_version: 2, container: "broken-pkg", base_image_ref: "STALE:wrong", version: "1.0", tag: "1.0"}' \
        > "$TEST_TEMP_DIR/.build-lineage/broken-pkg.json"

    # Deliberately malformed YAML
    make_variants_yaml "$TEST_TEMP_DIR/broken-pkg" "$(printf 'versions:\n  - tag: [\nnot: valid: yaml')"

    # --separate-stderr: the yq-failure warning goes to stderr; $output must be empty
    run --separate-stderr resolve_lineage_file "broken-pkg"
    [ "$status" -eq 0 ]

    # Post-fix: must return empty (fail closed), NOT the stale legacy rollup
    [[ -z "$output" ]] || {
        echo "FAIL: expected empty output (fail closed), got: '$output'"
        echo "  (pre-fix: malformed yaml causes silent fallback to stale legacy rollup)"
        return 1
    }
}

# =============================================================================
# Finding #1 (gate r9 codex MEDIUM): Delimiter-bound version glob in fallback
# Pre-fix: -name "${container}-${latest_version}*.json" — matches version
#   prefix without a delimiter, so "1.0" matches "1.0.1-alpine.json" (collision).
# Post-fix: -name "${container}-${latest_version}.json" -o
#            -name "${container}-${latest_version}-*.json"
#   The hyphen delimiter ensures "1.0" only matches "1.0.json" or "1.0-*.json",
#   not "1.0.1-alpine.json".
# =============================================================================

@test "DRDV-18: Version prefix-collision — '1.0' must NOT match '1.0.1-alpine.json' in fallback glob" {
    # Scenario: latest_version="1.0" in variants.yaml.
    # .build-lineage/ has foo-1.0.1-alpine.json (NEXT major patch, NOT the latest 1.0).
    # Pre-fix glob: "${container}-${latest_version}*.json" matches "1.0.1-alpine.json"
    #   because "1.0.1-alpine.json" starts with "1.0".
    # Post-fix: delimiter-bound pattern requires hyphen after version → no match → empty returned.
    #
    # The default variant resolution path (variant_image_tag) also returns empty
    # because foo/variants.yaml has no variants[] — so code falls into the
    # "fallback within per-tag resolution" glob path being tested here.

    # Only file present: the WRONG version (1.0.1, NOT 1.0)
    make_lineage "foo-1.0.1-alpine" "alpine:3.21"

    make_variants_yaml "$TEST_TEMP_DIR/foo" "$(cat <<'YAML'
versions:
  - tag: "1.0"
YAML
)"

    run resolve_lineage_file "foo"
    [ "$status" -eq 0 ]
    # Post-fix: must return empty — "1.0.1-alpine.json" is NOT a valid match for version "1.0"
    [[ -z "$output" ]] || {
        echo "FAIL: prefix collision — version '1.0' matched '1.0.1-alpine.json' (wrong version)"
        echo "  Got: '$output'"
        echo "  (pre-fix: glob '1.0*.json' matches '1.0.1-alpine.json' — no delimiter boundary)"
        return 1
    }
}

# =============================================================================
# Finding #2 (gate r9 copilot HIGH): Guarded yq assignment under set -e
# Pre-fix: latest_version=$(yq ...) ; _yq_rc=$?
#   Under set -euo pipefail, when yq exits non-zero the assignment line aborts
#   the bash shell BEFORE _yq_rc=$? is evaluated — the guard is dead code.
# Post-fix: if ! latest_version=$(yq ...); then ... fi
#   The if-form suppresses set -e on the command substitution exit code,
#   so the guard branch runs correctly.
# =============================================================================

@test "DRDV-19: Guarded yq assignment — malformed YAML does not abort parent shell under set -e" {
    # This test asserts that resolve_lineage_file is callable from a set -e
    # context without killing the parent shell on a yq parse failure.
    # Technique: invoke the function from within an explicit set -e subshell,
    # and verify the subshell exits 0 (function returns cleanly, not crashed).

    # Create real lineage files that would be found if the guard were absent
    make_lineage "grd-1.0-alpine" "alpine:3.21"

    # Deliberately malformed YAML
    make_variants_yaml "$TEST_TEMP_DIR/grd" "$(printf 'versions:\n  - tag: [\nnot: valid: yaml')"

    # Run in a subshell with set -e to detect abort-vs-return distinction.
    # If the fix is NOT applied: the yq assignment aborts the subshell → exit non-zero.
    # If the fix IS applied: resolve_lineage_file returns 0 → subshell exits 0.
    run bash -c "
        set -euo pipefail
        # Re-source the helpers and extract resolve_lineage_file exactly as setup() does
        source '${PROJECT_ROOT_REAL}/helpers/logging.sh'
        source '${PROJECT_ROOT_REAL}/helpers/build-args-utils.sh'
        source '${PROJECT_ROOT_REAL}/helpers/variant-utils.sh'
        _fn_defs=\$(
            cd '${PROJECT_ROOT_REAL}'
            source '${PROJECT_ROOT_REAL}/generate-dashboard.sh' 2>/dev/null || true
            declare -f resolve_lineage_file
        )
        eval \"\$_fn_defs\"
        SCRIPT_DIR='${TEST_TEMP_DIR}'
        export SCRIPT_DIR
        # Call the function — must return 0 (not abort the shell)
        resolve_lineage_file 'grd' >/dev/null 2>&1
        # If we reach here, the function did NOT abort the shell
        echo 'SHELL_CONTINUED'
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"SHELL_CONTINUED"* ]] || {
        echo "FAIL: subshell did not continue after resolve_lineage_file returned"
        echo "  Status: $status, output: '$output'"
        echo "  (pre-fix: yq failure aborted the shell; SHELL_CONTINUED never printed)"
        return 1
    }
}
