#!/usr/bin/env bats

# Unit tests for helpers/validate-base-cache-schema.sh
#
# Guard: static config.yaml schema validation for base_image_cache dual-schema.
# Discriminator is BINARY on ghcr_repo: present+non-empty => old-style, else new-style.
# A slash in source is valid for both styles (Docker Hub namespace).
#
# Rules tested:
#   VBC-02: new-style source without slash → REJECT
#   VBC-03: new-style source with registry prefix (dot/colon before first slash) → REJECT
#   VBC-04: new-style source with tag (:) → REJECT
#   VBC-05: new-style source with digest (@) → REJECT
#   VBC-06: new-style source with uppercase letters → REJECT
#   VBC-07: new-style source with empty path component (//) → REJECT
#   VBC-08: REMOTE_CR in build_args → REJECT
#   VBC-09: old-style entry with empty/absent arg → REJECT
#   VBC-10: valid new-style (source: library/postgres, no ghcr_repo) → PASS
#   VBC-11: valid old-style (ghcr_repo + arg present) → PASS
#   VBC-11d: valid old-style with namespaced source (hashicorp/terraform) → PASS [regression lock]
#   VBC-11e: valid new-style with non-library namespace (hashicorp/terraform) → PASS
#   VBC-12: container dir name with slash → REJECT (defensive invariant)
#   VBC-13: new-style source with leading slash (single segment /php) → PASS (chained-on-own marker)
#   VBC-13b: new-style source with leading slash (multi-segment /library/postgres) → PASS
#   VBC-13c: wordpress-real: source: /php → PASS (regression lock for #531)
#   VBC-13d: source: /php/ (trailing slash after leading slash) → REJECT
#   VBC-13e: source: //php (double slash) → REJECT
#   VBC-14: new-style source with trailing slash → REJECT (empty path component)
#   VBC-R7C-GLOB-01: build_args value with glob * → REJECT (R7c allowlist)
#   VBC-R7C-GLOB-02: build_args value with glob ? → REJECT (R7c allowlist)
#   VBC-R7C-BRACE-01: build_args value with brace expansion → REJECT (R7c allowlist)
#   VBC-R7C-CMD-01: build_args value with $() command substitution → REJECT (R7c allowlist)
#   VBC-R7C-CMD-02: build_args value with backtick substitution → REJECT (R7c allowlist)
#   VBC-R7C-EMPTY-01: build_args value that is an empty string → REJECT (R7c allowlist)
#   VBC-SRC-GLOB-01: new-style source with glob * → REJECT (R6d allowlist)
#   VBC-SRC-GLOB-02: new-style source with glob ? → REJECT (R6d allowlist)

setup() {
    TEST_DIR=$(mktemp -d)
    ORIG_DIR="$PWD"
    cd "$TEST_DIR" || exit 1

    # Source the guard helper once available
    source "$ORIG_DIR/helpers/validate-base-cache-schema.sh"
}

teardown() {
    cd "$ORIG_DIR" || true
    rm -rf "$TEST_DIR"
}

# Helper: create a minimal container dir + config.yaml
# Usage: make_container <name> <yaml_content>
make_container() {
    local name="$1"
    local yaml="$2"
    mkdir -p "$name"
    printf '%s\n' "$yaml" > "$name/config.yaml"
}

# ─── REJECT cases ─────────────────────────────────────────────────────────────

@test "VBC-02: new-style source without slash → REJECT" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source: postgres
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

@test "VBC-03: new-style source with registry prefix (docker.io/) → REJECT" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source: docker.io/library/postgres
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

@test "VBC-03b: new-style source with ghcr.io registry prefix → REJECT" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source: ghcr.io/owner/image
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

@test "VBC-03c: new-style source with colon-port registry (localhost:5000/img) → REJECT" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source: localhost:5000/myimage
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

@test "VBC-04: new-style source with tag colon → REJECT" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source: library/postgres:16
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

@test "VBC-05: new-style source with digest @ → REJECT" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source: library/postgres@sha256:abc123
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

@test "VBC-06: new-style source with uppercase letters → REJECT" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source: Library/Postgres
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

@test "VBC-07: new-style source with empty path component (//) → REJECT" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source: library//postgres
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

@test "VBC-08: REMOTE_CR present in build_args → REJECT" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source: library/postgres
    tags: ["latest"]
build_args:
  REMOTE_CR: ghcr.io/owner
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
    [[ "$output" =~ "REMOTE_CR" ]]
}

# VBC-08b (RED→GREEN for FIX 3): REMOTE_CR key with null value → REJECT
# The old code used `// "null"` value-check: `REMOTE_CR:` (YAML-null) returns the
# string "null" via `// "null"` fallback and PASSED the check. Fixed by checking
# key presence via `yq has("REMOTE_CR")` instead of checking the value.
@test "VBC-08b: REMOTE_CR key with null value (REMOTE_CR:) → REJECT (FIX-3 regression lock)" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source: library/postgres
    tags: ["latest"]
build_args:
  REMOTE_CR:
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "REMOTE_CR" ]]
    # Mutation guard: the old code would have returned 0 (passed) — must NOT be 0
}

# VBC-08c: REMOTE_CR key with explicit null literal → REJECT
@test "VBC-08c: REMOTE_CR key with explicit YAML null → REJECT" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source: library/postgres
    tags: ["latest"]
build_args:
  REMOTE_CR: null
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "REMOTE_CR" ]]
}

@test "VBC-09: old-style with empty arg → REJECT" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - arg: ""
    source: ubuntu
    ghcr_repo: ubuntu-base
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

@test "VBC-09b: old-style with absent arg → REJECT" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source: ubuntu
    ghcr_repo: ubuntu-base
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

# VBC-09c (RED→GREEN for arg identifier safety): arg with spaces → REJECT
# A value like "BASE_IMAGE --network host" passes the non-empty check but would
# inject extra docker CLI tokens when expanded into CUSTOM_BUILD_ARGS. The fix
# restricts arg to a valid Docker ARG identifier: ^[A-Za-z_][A-Za-z0-9_]*$.
@test "VBC-09c: old-style arg with spaces (injection risk) → REJECT" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - arg: "BASE_IMAGE --network host"
    source: ubuntu
    ghcr_repo: ubuntu-base
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

@test "VBC-09d: old-style arg with two words (FOO BAR) → REJECT" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - arg: "FOO BAR"
    source: ubuntu
    ghcr_repo: ubuntu-base
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

@test "VBC-09e: old-style arg with hyphen (not a valid identifier) → REJECT" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - arg: BASE-IMAGE
    source: ubuntu
    ghcr_repo: ubuntu-base
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

@test "VBC-09f: old-style arg BASE_IMAGE (valid identifier) → PASS (regression lock)" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - arg: BASE_IMAGE
    source: ubuntu
    ghcr_repo: ubuntu-base
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -eq 0 ]
}

@test "VBC-13: new-style source with leading slash (single segment /php) → PASS (chained-on-own marker)" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source: /php
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -eq 0 ]
}

@test "VBC-13b: new-style source with leading slash (multi-segment /library/postgres) → PASS" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source: /library/postgres
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -eq 0 ]
}

@test "VBC-13c: wordpress real config — source: /php → PASS (regression lock #531)" {
    make_container "wordpress" "$(cat <<'EOF'
base_image: "${REMOTE_CR}/php:${PHP_TAG}"
base_image_cache:
  - source: /php
    tags: ["latest"]
build_args:
  PHP_TAG: "latest"
EOF
)"
    run validate_container_base_cache_schema "wordpress"
    [ "$status" -eq 0 ]
}

@test "VBC-13d: new-style source with trailing slash after leading slash (/php/) → REJECT" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source: /php/
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

@test "VBC-13e: new-style source with double slash (//php) → REJECT" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source: //php
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

@test "VBC-14: new-style source with trailing slash → REJECT" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source: library/postgres/
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

# ─── PASS cases ───────────────────────────────────────────────────────────────

@test "VBC-10: valid new-style (source: library/postgres, no ghcr_repo) → PASS" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source: library/postgres
    tags_from_versions: true
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -eq 0 ]
}

@test "VBC-11: valid old-style (ghcr_repo + arg present) → PASS" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - arg: BASE_IMAGE
    source: ubuntu
    ghcr_repo: ubuntu-base
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -eq 0 ]
}

@test "VBC-11b: valid old-style multiple entries → PASS" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - arg: BASE_IMAGE
    source: ubuntu
    ghcr_repo: ubuntu-base
    tags: ["latest"]
  - arg: ALPINE_BASE
    source: alpine
    ghcr_repo: alpine-base
    tags: ["3.21"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -eq 0 ]
}

@test "VBC-11c: no base_image_cache section → PASS (no entries to validate)" {
    make_container "myapp" "$(cat <<'EOF'
build_args:
  FOO: bar
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -eq 0 ]
}

@test "VBC-11d: valid old-style with namespaced source (regression lock — hashicorp/terraform pattern) → PASS" {
    # Regression lock: old-style entries (ghcr_repo set) may have a slash in source
    # because Docker Hub uses namespace/image paths (e.g. hashicorp/terraform).
    # The discriminator is BINARY — ghcr_repo present => old-style, full stop.
    # A slash in source is the upstream namespace separator, not a new-style indicator.
    # This test was RED before R1 deletion and proves the bug is locked out.
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - arg: TERRAFORM_BASE
    source: hashicorp/terraform
    ghcr_repo: terraform-base
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -eq 0 ]
}

@test "VBC-11e: valid new-style with non-library namespace (hashicorp/terraform, no ghcr_repo) → PASS" {
    # Guards against future R3 tightening that might mistakenly reject 2-segment
    # paths that are not under the 'library/' namespace.
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source: hashicorp/terraform
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -eq 0 ]
}

@test "VBC-12: defensive — container dir name with slash would be invalid (path check)" {
    # Container names are directory names on disk — they cannot contain /
    # This is a repo invariant. We verify the guard is consistent:
    # a container with a path traversal dir name cannot be created normally.
    # We test the guard rejects a hypothetical 'a/b' name by passing invalid path.
    run validate_container_base_cache_schema "nonexistent/slash"
    # Should fail cleanly (dir does not exist or name contains slash)
    [ "$status" -ne 0 ]
}

# ─── Multi-container scan ─────────────────────────────────────────────────────

@test "VBC-SCAN-01: validate_all_containers_base_cache_schema — all valid → exit 0" {
    make_container "c1" "$(cat <<'EOF'
base_image_cache:
  - arg: BASE_IMAGE
    source: ubuntu
    ghcr_repo: ubuntu-base
    tags: ["latest"]
EOF
)"
    make_container "c2" "$(cat <<'EOF'
base_image_cache:
  - source: library/postgres
    tags_from_versions: true
EOF
)"
    run validate_all_containers_base_cache_schema "."
    [ "$status" -eq 0 ]
}

@test "VBC-SCAN-02: validate_all_containers_base_cache_schema — one invalid → exit non-zero" {
    make_container "good" "$(cat <<'EOF'
base_image_cache:
  - arg: BASE_IMAGE
    source: ubuntu
    ghcr_repo: ubuntu-base
    tags: ["latest"]
EOF
)"
    make_container "bad" "$(cat <<'EOF'
base_image_cache:
  - source: postgres
    tags: ["latest"]
EOF
)"
    run validate_all_containers_base_cache_schema "."
    [ "$status" -ne 0 ]
    [[ "$output" =~ "bad" ]]
}

# ─── Fail-closed: yq missing / parse error (FINDING B) ────────────────────────

# VBC-FC-01 (RED→GREEN for FINDING B): malformed YAML → validation failure (not pass)
# A yq parse error on a syntactically invalid config.yaml must cause the guard to
# return non-zero. Previously a yq command substitution error returned "" + exit-0
# from the subshell, causing the outer variable to be "" which the guard treated as
# "no REMOTE_CR" → silent pass. Fixed by checking yq exit status explicitly.
@test "VBC-FC-01: malformed config.yaml (yq parse error) → REJECT (fail-closed lock)" {
    mkdir -p badyaml
    # Deliberately malformed YAML — yq will error on this
    printf 'build_args: { REMOTE_CR: [unclosed\n' > badyaml/config.yaml
    run validate_container_base_cache_schema "badyaml"
    [ "$status" -ne 0 ]
}

# VBC-FC-02: yq missing from PATH → validation failure (not pass)
# Tests the command-v guard at the top of validate_container_base_cache_schema.
# ─── FIX 1: build_args key/value injection (R7b, R7c) ────────────────────────

# VBC-R7B-01: crafted key with spaces + injected --build-arg → REJECT
# The gate finding: `"X --build-arg REMOTE_CR": value` would be expanded unquoted
# into docker flags, bypassing the REMOTE_CR key check.
@test "VBC-R7B-01: build_args key with spaces (injection vector) → REJECT" {
    make_container "myapp" "$(cat <<'EOF'
build_args:
  "X --build-arg REMOTE_CR": "ghcr.io/attacker"
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

# VBC-R7B-02: key with hyphen (not a valid ARG identifier) → REJECT
@test "VBC-R7B-02: build_args key with hyphen → REJECT" {
    make_container "myapp" "$(cat <<'EOF'
build_args:
  INVALID-KEY: "somevalue"
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

# VBC-R7C-01: value containing a space (flag injection) → REJECT
@test "VBC-R7C-01: build_args value with embedded space (flag injection) → REJECT" {
    make_container "myapp" "$(cat <<'EOF'
build_args:
  BASE_IMAGE: "foo --network host"
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

# VBC-R7C-02: value containing embedded newlines → REJECT (newline injection class)
# ROOT CAUSE: a line-by-line yq read splits "ubuntu\n--build-arg\nREMOTE_CR=x" into
# three separate lines (each clean) — the old loop passed this. The JSON-based check
# reads the whole value atomically; \s in jq regex catches newlines before any split.
# YAML double-quoted strings interpret \n as a literal newline character, so the
# fixture below produces a value with actual embedded newlines that a shell would
# word-split into separate docker CLI tokens when expanded unquoted.
@test "VBC-R7C-02: build_args value with embedded newlines (newline injection) → REJECT" {
    make_container "myapp" "$(cat <<'EOF'
build_args:
  BASE_IMAGE: "ubuntu\n--build-arg\nREMOTE_CR=ghcr.io/attacker"
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

# ─── FIX 3: build_args value positive allowlist (R7c — glob/shell metacharacters) ─

# VBC-R7C-GLOB-01 (RED→GREEN): value with glob * → REJECT
# "ubuntu*" passes the whitespace check but glob-expands when unquoted in a shell.
# The positive allowlist ^[A-Za-z0-9._/:@+=-]+$ has no *, so it rejects this.
@test "VBC-R7C-GLOB-01: build_args value with glob asterisk → REJECT (R7c allowlist)" {
    make_container "myapp" "$(cat <<'EOF'
build_args:
  BASE_IMAGE: "*"
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

# VBC-R7C-GLOB-02 (RED→GREEN): value with glob ? → REJECT
@test "VBC-R7C-GLOB-02: build_args value with glob question mark → REJECT (R7c allowlist)" {
    make_container "myapp" "$(cat <<'EOF'
build_args:
  BASE_IMAGE: "a?b"
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

# VBC-R7C-BRACE-01 (RED→GREEN): value with brace expansion → REJECT
# "a{b,c}" passes whitespace check; in an unquoted shell context it expands to "ab ac".
@test "VBC-R7C-BRACE-01: build_args value with brace expansion → REJECT (R7c allowlist)" {
    make_container "myapp" "$(cat <<'EOF'
build_args:
  BASE_IMAGE: "a{b,c}"
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

# VBC-R7C-CMD-01 (RED→GREEN): value with $() command substitution → REJECT
# $(id) passes whitespace check; shell would execute id when expanded unquoted.
@test "VBC-R7C-CMD-01: build_args value with dollar-paren command substitution → REJECT (R7c allowlist)" {
    make_container "myapp" "$(cat <<'EOF'
build_args:
  BASE_IMAGE: "$(id)"
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

# VBC-R7C-CMD-02 (RED→GREEN): value with backtick substitution → REJECT
@test "VBC-R7C-CMD-02: build_args value with backtick command substitution → REJECT (R7c allowlist)" {
    # shellcheck disable=SC2016
    make_container "myapp" 'build_args:
  BASE_IMAGE: "`id`"
'
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

# VBC-R7C-EMPTY-01 (RED→GREEN): value that is an empty string → REJECT
# An empty build_arg value is unusual and semantically void; reject to avoid
# silent misconfigurations that produce --build-arg KEY= (empty injection).
@test "VBC-R7C-EMPTY-01: build_args value that is an empty string → REJECT (R7c allowlist)" {
    make_container "myapp" "$(cat <<'EOF'
build_args:
  BASE_IMAGE: ""
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

# VBC-R7B-PASS: valid identifier keys (php real config pattern) → PASS
@test "VBC-R7B-PASS: multiple valid ARG identifier keys (php pattern) → PASS" {
    make_container "myapp" "$(cat <<'EOF'
build_args:
  BASE_IMAGE: "php"
  COMPOSER_BASE: "composer"
  COMPOSER_VERSION: "2.9.8"
  APCU_VERSION: "5.1.28"
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -eq 0 ]
}

# VBC-R7C-PASS: value with colon+slash (docker image ref, no whitespace) → PASS
@test "VBC-R7C-PASS: build_args value with colon and slash (image ref) → PASS" {
    make_container "myapp" "$(cat <<'EOF'
build_args:
  WORDPRESS_IMAGE: "ghcr.io/oorabona/php:latest"
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -eq 0 ]
}

@test "VBC-FC-02: yq not in PATH → REJECT (fail-closed lock)" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source: library/postgres
    tags_from_versions: true
EOF
)"
    # Run with a PATH that excludes yq — the guard must return non-zero
    run env PATH="/usr/bin:/bin" bash -c "
        source '$ORIG_DIR/helpers/validate-base-cache-schema.sh'
        validate_container_base_cache_schema 'myapp'
    "
    [ "$status" -ne 0 ]
    [[ "$output" =~ "yq" ]]
}

# VBC-FC-03: jq required — guard emits clear error and rejects when jq unavailable
# PATH isolation for jq is not feasible when jq lives in /bin (always in PATH).
# Instead we verify the guard via function override: replace jq with a stub that
# returns 127 (command-not-found exit code) to exercise the command -v branch.
@test "VBC-FC-03: jq unavailable (stub) → REJECT (fail-closed lock)" {
    make_container "myapp" "$(cat <<'EOF'
build_args:
  BASE_IMAGE: "ubuntu"
EOF
)"
    run bash -c "
        jq() { return 127; }
        export -f jq
        source '$ORIG_DIR/helpers/validate-base-cache-schema.sh'
        cd '$TEST_DIR'
        validate_container_base_cache_schema 'myapp'
    "
    [ "$status" -ne 0 ]
}

# ─── FIX 2: source whitespace / non-scalar checks ─────────────────────────────

# VBC-SRC-WS-01: source containing a space → REJECT
# "library/postgres bad" passes all prior format rules (has slash, no colon, lowercase,
# no empty component) but the embedded space would break cache probing / imagetools refs.
@test "VBC-SRC-WS-01: new-style source with embedded space → REJECT" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source: "library/postgres bad"
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "whitespace" ]] || [[ "$output" =~ "source" ]]
}

# VBC-SRC-WS-02: source containing a tab → REJECT
@test "VBC-SRC-WS-02: new-style source with embedded tab → REJECT" {
    make_container "myapp" "$(printf 'base_image_cache:\n  - source: "library/postgres\teval"\n    tags: ["latest"]\n')"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
}

# VBC-SRC-NS-01: non-scalar source (object/mapping) → REJECT
# yq emits the object as a non-string representation; the guard must detect
# and reject it rather than treating the stringified object as a source path.
@test "VBC-SRC-NS-01: new-style source that is an object (non-scalar) → REJECT" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source:
      a: b
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
}

# VBC-SRC-NS-02: null source → REJECT (null is non-scalar string, unusable as image ref)
@test "VBC-SRC-NS-02: new-style source is null → REJECT" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
}

# ─── FIX 3: source positive allowlist (R6d — glob/shell metacharacters) ──────────

# VBC-SRC-GLOB-01 (RED→GREEN): source with glob * → REJECT (R6d allowlist)
# "lib*/postgres" passes the whitespace and uppercase checks but glob-expands
# when used unquoted in a shell imagetools/skopeo reference.
@test "VBC-SRC-GLOB-01: new-style source with glob asterisk → REJECT (R6d allowlist)" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source: "lib*/postgres"
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

# VBC-SRC-GLOB-02 (RED→GREEN): source with glob ? → REJECT (R6d allowlist)
@test "VBC-SRC-GLOB-02: new-style source with glob question mark → REJECT (R6d allowlist)" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source: "library/postgr?s"
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

# VBC-SRC-PASS: valid whitespace-free scalar source → PASS (regression lock)
@test "VBC-SRC-PASS: clean source library/postgres (whitespace-free scalar) → PASS" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source: library/postgres
    tags_from_versions: true
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -eq 0 ]
}

# VBC-BA-NS-01: build_args value that is an object → REJECT (FIX 2: non-scalar value)
# tostring on an object emits '{"foo":"bar"}' which may or may not contain \s,
# but `type == "object"` is always a non-scalar that should be rejected explicitly.
@test "VBC-BA-NS-01: build_args value that is an object → REJECT (non-scalar)" {
    make_container "myapp" "$(cat <<'EOF'
build_args:
  BASE_IMAGE:
    foo: bar
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

# VBC-BA-NS-02: build_args value that is an array → REJECT (non-scalar)
@test "VBC-BA-NS-02: build_args value that is an array → REJECT (non-scalar)" {
    make_container "myapp" "$(cat <<'EOF'
build_args:
  BASE_IMAGE:
    - ubuntu
    - alpine
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
}

# VBC-BA-NS-PASS: numeric value (valid scalar, type==number) → PASS
@test "VBC-BA-NS-PASS: build_args value that is a number (scalar) → PASS" {
    make_container "myapp" "$(cat <<'EOF'
build_args:
  NPROC: 4
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -eq 0 ]
}

# ─── FIX A: old-style ghcr_repo allowlist (R9) ───────────────────────────────

# VBC-R9-01 (RED→GREEN): ghcr_repo with embedded space + flag token → REJECT
# The injection: "ubuntu-base --network host" would expand to:
#   --build-arg BASE_IMAGE=ghcr.io/owner/ubuntu-base --network host
# injecting extra docker CLI flags.
@test "VBC-R9-01: old-style ghcr_repo with space+flag (injection) → REJECT (R9)" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - arg: BASE_IMAGE
    source: ubuntu
    ghcr_repo: "ubuntu-base --network host"
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "myapp" ]]
    [[ "$output" =~ "ghcr_repo" ]]
}

# VBC-R9-02: ghcr_repo with embedded semicolon → REJECT
@test "VBC-R9-02: old-style ghcr_repo with semicolon → REJECT (R9)" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - arg: BASE_IMAGE
    source: ubuntu
    ghcr_repo: "ubuntu-base;id"
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "ghcr_repo" ]]
}

# VBC-R9-03: ghcr_repo with $ (parameter expansion attempt) → REJECT
@test "VBC-R9-03: old-style ghcr_repo with dollar sign → REJECT (R9)" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - arg: BASE_IMAGE
    source: ubuntu
    ghcr_repo: "ubuntu-base$EXTRA"
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "ghcr_repo" ]]
}

# VBC-R9-PASS-01: valid ghcr_repo names (all current containers) → PASS
@test "VBC-R9-PASS-01: valid old-style ghcr_repo names (ubuntu-base, ruby-base, etc.) → PASS" {
    # Regression lock: all current container ghcr_repo values must pass
    for repo in ubuntu-base ruby-base php-base composer-base alpine-base rocky-base debian-base terraform-base postgres-base python-base; do
        make_container "app-${repo}" "$(cat <<EOF
base_image_cache:
  - arg: BASE_IMAGE
    source: test
    ghcr_repo: ${repo}
    tags: ["latest"]
EOF
)"
        run validate_container_base_cache_schema "app-${repo}"
        [ "$status" -eq 0 ] || {
            echo "FAILED for ghcr_repo=${repo}, output: $output"
            return 1
        }
    done
}

# VBC-R9-PASS-02: valid ghcr_repo with slash (org/repo) → PASS
@test "VBC-R9-PASS-02: old-style ghcr_repo with slash (org/repo) → PASS (R9 allows slash)" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - arg: BASE_IMAGE
    source: hashicorp/terraform
    ghcr_repo: terraform/base
    tags: ["latest"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -eq 0 ]
}

# ─── FIX B: tags[] value allowlist (R10) ─────────────────────────────────────

# VBC-R10-01 (RED→GREEN): tag with embedded space → REJECT
# "18 --network host" has no injection path in the current CI (values are
# double-quoted), but the value is still syntactically invalid as an OCI tag
# and is rejected to close the class entirely.
@test "VBC-R10-01: tags value with embedded space → REJECT (R10)" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - arg: BASE_IMAGE
    source: ubuntu
    ghcr_repo: ubuntu-base
    tags: ["18 --network host"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "tags" ]]
}

# VBC-R10-02: tag with semicolon → REJECT
@test "VBC-R10-02: tags value with semicolon → REJECT (R10)" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - arg: BASE_IMAGE
    source: ubuntu
    ghcr_repo: ubuntu-base
    tags: ["latest;id"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "tags" ]]
}

# VBC-R10-03: tag with bare $ (not a valid ${IDENT} placeholder) → REJECT
@test "VBC-R10-03: tags value with bare dollar sign (not a valid placeholder) → REJECT (R10)" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - arg: BASE_IMAGE
    source: ubuntu
    ghcr_repo: ubuntu-base
    tags: ["$VERSION"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "tags" ]]
}

# VBC-R10-04: tag with new-style entry → REJECT propagates via new-style path too
@test "VBC-R10-04: new-style entry tags value with injection chars → REJECT (R10)" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source: library/postgres
    tags: ["18 --network host"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "tags" ]]
}

# VBC-R10-PASS-01: literal tags → PASS (regression lock)
@test "VBC-R10-PASS-01: literal tags (latest, 18-alpine, 3.21, noble, 9) → PASS" {
    for tag in latest 18-alpine 3.21 noble 9 24.04 3.12-alpine; do
        make_container "app-tag-$(echo "$tag" | tr '.' '-')" "$(cat <<EOF
base_image_cache:
  - arg: BASE_IMAGE
    source: ubuntu
    ghcr_repo: ubuntu-base
    tags: ["${tag}"]
EOF
)"
        run validate_container_base_cache_schema "app-tag-$(echo "$tag" | tr '.' '-')"
        [ "$status" -eq 0 ] || {
            echo "FAILED for tag=${tag}, output: $output"
            return 1
        }
    done
}

# VBC-R10-PASS-02: ${VERSION} placeholder → PASS
@test "VBC-R10-PASS-02: tags with \${VERSION} placeholder → PASS (R10 template allowlist)" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - arg: BASE_IMAGE
    source: hashicorp/terraform
    ghcr_repo: terraform-base
    tags: ["${VERSION}"]
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -eq 0 ]
}

# VBC-R10-PASS-03 (CRITICAL regression lock): jekyll composite template tag → PASS
# "ruby-base" with tags: ["${RUBY_VERSION}-alpine${ALPINE_VERSION}"] is the
# real jekyll config. This MUST pass — the composite template mixes literal
# text ("-alpine") with two ${IDENT} placeholders.
@test "VBC-R10-PASS-03: jekyll composite template tag \${RUBY_VERSION}-alpine\${ALPINE_VERSION} → PASS (regression lock)" {
    make_container "jekyll" "$(cat <<'EOF'
base_image_cache:
  - arg: BASE_IMAGE
    source: ruby
    ghcr_repo: ruby-base
    tags: ["${RUBY_VERSION}-alpine${ALPINE_VERSION}"]
EOF
)"
    run validate_container_base_cache_schema "jekyll"
    [ "$status" -eq 0 ]
}

# VBC-R10-PASS-04: ${UPSTREAM_VERSION} placeholder (terraform pattern) → PASS
@test "VBC-R10-PASS-04: tags with \${UPSTREAM_VERSION} placeholder → PASS (terraform pattern)" {
    make_container "terraform" "$(cat <<'EOF'
base_image_cache:
  - arg: TERRAFORM_BASE
    source: hashicorp/terraform
    ghcr_repo: terraform-base
    tags: ["${UPSTREAM_VERSION}"]
  - arg: ALPINE_BASE
    source: alpine
    ghcr_repo: alpine-base
    tags: ["latest"]
  - arg: PYTHON_BASE
    source: python
    ghcr_repo: python-base
    tags: ["3.12-alpine"]
EOF
)"
    run validate_container_base_cache_schema "terraform"
    [ "$status" -eq 0 ]
}

# VBC-R10-PASS-05: tags_from_versions=true (no tags[] to validate) → PASS
@test "VBC-R10-PASS-05: tags_from_versions=true entries skip tag validation → PASS" {
    make_container "myapp" "$(cat <<'EOF'
base_image_cache:
  - source: library/postgres
    tags_from_versions: true
EOF
)"
    run validate_container_base_cache_schema "myapp"
    [ "$status" -eq 0 ]
}
