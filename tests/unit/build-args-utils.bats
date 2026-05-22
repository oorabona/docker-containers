#!/usr/bin/env bats

# Unit tests for helpers/build-args-utils.sh
#
# Covers build_args_flags / prepare_build_args point-of-use validation (FIX 1):
#   - REMOTE_CR key → abort (non-zero, no flags emitted)
#   - non-identifier key → abort
#   - whitespace in value → abort
#   - newline in value → abort
#   - non-scalar value (object) → abort
#   - valid config (php pattern, 4 build_args) → same flags as before (regression lock)

setup() {
    TEST_DIR=$(mktemp -d)
    ORIG_DIR="$PWD"
    cd "$TEST_DIR" || exit 1

    # Source dependencies
    source "$ORIG_DIR/helpers/logging.sh"
    source "$ORIG_DIR/helpers/build-args-utils.sh"
}

teardown() {
    cd "$ORIG_DIR" || true
    rm -rf "$TEST_DIR"
}

# Helper: create container dir + config.yaml
make_container() {
    local name="$1"
    local yaml="$2"
    mkdir -p "$name"
    printf '%s\n' "$yaml" > "$name/config.yaml"
}

# ─── FIX 1: build_args_flags fail-closed enforcement ─────────────────────────

@test "BAU-01: build_args_flags aborts (non-zero) when REMOTE_CR key present" {
    make_container "myapp" "$(cat <<'EOF'
build_args:
  BASE_IMAGE: "ubuntu"
  REMOTE_CR: "ghcr.io/attacker"
EOF
)"
    run build_args_flags "myapp"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "REMOTE_CR" ]]
}

@test "BAU-02: build_args_flags aborts on non-identifier key (contains space)" {
    make_container "myapp" "$(cat <<'EOF'
build_args:
  "X --network host": "val"
EOF
)"
    run build_args_flags "myapp"
    [ "$status" -ne 0 ]
}

@test "BAU-03: build_args_flags aborts on key with hyphen (invalid Docker ARG)" {
    make_container "myapp" "$(cat <<'EOF'
build_args:
  INVALID-KEY: "value"
EOF
)"
    run build_args_flags "myapp"
    [ "$status" -ne 0 ]
}

@test "BAU-04: build_args_flags aborts on value with embedded space" {
    make_container "myapp" "$(cat <<'EOF'
build_args:
  BASE_IMAGE: "foo --network host"
EOF
)"
    run build_args_flags "myapp"
    [ "$status" -ne 0 ]
}

@test "BAU-05: build_args_flags aborts on value with embedded newline" {
    make_container "myapp" "$(cat <<'EOF'
build_args:
  BASE_IMAGE: "ubuntu\n--build-arg\nREMOTE_CR=x"
EOF
)"
    run build_args_flags "myapp"
    [ "$status" -ne 0 ]
}

@test "BAU-06: build_args_flags aborts on non-scalar value (object)" {
    make_container "myapp" "$(cat <<'EOF'
build_args:
  BASE_IMAGE:
    foo: bar
EOF
)"
    run build_args_flags "myapp"
    [ "$status" -ne 0 ]
}

# ─── FIX 1: regression lock — valid config emits identical flags ──────────────

# php pattern: 4 build_args, all clean identifiers + scalar values (no whitespace)
@test "BAU-PASS-01: php-shaped config (4 valid build_args) → correct flags emitted (regression lock)" {
    make_container "myapp" "$(cat <<'EOF'
build_args:
  BASE_IMAGE: "php"
  COMPOSER_BASE: "composer"
  COMPOSER_VERSION: "2.9.8"
  APCU_VERSION: "5.1.28"
EOF
)"
    run build_args_flags "myapp"
    [ "$status" -eq 0 ]
    # Output must contain all 4 --build-arg flags
    [[ "$output" =~ "--build-arg BASE_IMAGE=php" ]]
    [[ "$output" =~ "--build-arg COMPOSER_BASE=composer" ]]
    [[ "$output" =~ "--build-arg COMPOSER_VERSION=2.9.8" ]]
    [[ "$output" =~ "--build-arg APCU_VERSION=5.1.28" ]]
    # Output must NOT contain anything that looks like an extra injected flag
    [[ ! "$output" =~ "REMOTE_CR" ]]
}

@test "BAU-PASS-02: empty build_args section → no flags, zero exit" {
    make_container "myapp" "$(cat <<'EOF'
build_args: {}
EOF
)"
    run build_args_flags "myapp"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "BAU-PASS-03: absent build_args section → no flags, zero exit" {
    make_container "myapp" "$(cat <<'EOF'
base_image: "ubuntu:latest"
EOF
)"
    run build_args_flags "myapp"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "BAU-PASS-04: ansible-shaped config (7 valid build_args) → correct flags emitted (regression lock)" {
    make_container "myapp" "$(cat <<'EOF'
build_args:
  BASE_IMAGE: "ubuntu"
  OS_VERSION: "latest"
  PYASN1_VERSION: "0.6.3"
  PARAMIKO_VERSION: "5.0.0"
  CFFI_VERSION: "2.0.0"
  CRYPTOGRAPHY_VERSION: "48.0.0"
  PYCRYPTODOME_VERSION: "3.23.0"
EOF
)"
    run build_args_flags "myapp"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "--build-arg BASE_IMAGE=ubuntu" ]]
    [[ "$output" =~ "--build-arg OS_VERSION=latest" ]]
    [[ "$output" =~ "--build-arg PYASN1_VERSION=0.6.3" ]]
    [[ "$output" =~ "--build-arg PARAMIKO_VERSION=5.0.0" ]]
    [[ "$output" =~ "--build-arg CFFI_VERSION=2.0.0" ]]
    [[ "$output" =~ "--build-arg CRYPTOGRAPHY_VERSION=48.0.0" ]]
    [[ "$output" =~ "--build-arg PYCRYPTODOME_VERSION=3.23.0" ]]
}

@test "BAU-PASS-05: value with colon+slash (image ref, no whitespace) → PASS" {
    make_container "myapp" "$(cat <<'EOF'
build_args:
  WORDPRESS_IMAGE: "ghcr.io/oorabona/php:latest"
EOF
)"
    run build_args_flags "myapp"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "--build-arg WORDPRESS_IMAGE=ghcr.io/oorabona/php:latest" ]]
}

@test "BAU-PASS-06: no config.yaml → empty output, zero exit (no-op)" {
    mkdir -p empty_container
    run build_args_flags "empty_container"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
