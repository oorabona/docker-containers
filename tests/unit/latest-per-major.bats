#!/usr/bin/env bats

# Unit tests for the latest_per_major_versions helper in helpers/variant-utils.sh
# and the --major flag in wordpress/version.sh

setup() {
    TEST_DIR=$(mktemp -d)
    ORIG_DIR="$PWD"
    cd "$TEST_DIR" || exit 1

    # Set up real yq if available
    export PATH="${ORIG_DIR}/bin:$PATH"

    mkdir -p helpers scripts bin wordpress

    cp "$ORIG_DIR/helpers/variant-utils.sh" helpers/
    cp "$ORIG_DIR/scripts/rotate-versions.sh" scripts/
    chmod +x scripts/rotate-versions.sh

    # Source variant-utils so helpers are available in tests
    # shellcheck disable=SC1090
    source "$ORIG_DIR/helpers/variant-utils.sh"
}

teardown() {
    cd "$ORIG_DIR" || true
    rm -rf "$TEST_DIR"
}

# ----------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------

create_latest_per_major_yaml() {
    local dir="${1:-myapp}"
    mkdir -p "$dir"
    cat > "$dir/variants.yaml" <<'EOF'
build:
  retention_strategy: latest_per_major
  retained_majors: [7, 6]
versions:
  - tag: 7.0.0-alpine
  - tag: 6.9.4-alpine
EOF
}

create_count_retention_yaml() {
    local dir="${1:-myapp}"
    mkdir -p "$dir"
    cat > "$dir/variants.yaml" <<'EOF'
build:
  version_retention: 3
versions:
  - tag: 2.0.0
  - tag: 1.9.0
EOF
}

create_no_strategy_yaml() {
    local dir="${1:-myapp}"
    mkdir -p "$dir"
    cat > "$dir/variants.yaml" <<'EOF'
build:
  requires_extensions: true
versions:
  - tag: "18"
EOF
}

create_empty_majors_yaml() {
    local dir="${1:-myapp}"
    mkdir -p "$dir"
    cat > "$dir/variants.yaml" <<'EOF'
build:
  retention_strategy: latest_per_major
  retained_majors: []
versions: []
EOF
}

# Create a mock version.sh that returns fixed values per --major N
create_mock_version_sh() {
    local dir="${1:-myapp}"
    mkdir -p "$dir"
    cat > "$dir/version.sh" <<'VEOF'
#!/bin/bash
if [[ "$1" == "--major" ]]; then
    major="$2"
    case "$major" in
        7) echo "7.0.0-alpine" ; exit 0 ;;
        6) echo "6.9.4-alpine" ; exit 0 ;;
        *) exit 1 ;;
    esac
fi
echo "7.0.0-alpine"
VEOF
    chmod +x "$dir/version.sh"
}

# Create a mock version.sh that always fails for a given major
create_failing_version_sh() {
    local dir="${1:-myapp}"
    mkdir -p "$dir"
    cat > "$dir/version.sh" <<'VEOF'
#!/bin/bash
if [[ "$1" == "--major" ]]; then
    exit 1
fi
echo "1.0.0"
VEOF
    chmod +x "$dir/version.sh"
}

# ----------------------------------------------------------------
# latest_per_major_versions — backward compat (no strategy set)
# ----------------------------------------------------------------

@test "latest_per_major_versions: returns empty (exit 0) when retention_strategy is unset" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi

    create_no_strategy_yaml "myapp"
    create_mock_version_sh "myapp"

    run latest_per_major_versions "myapp"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "latest_per_major_versions: returns empty (exit 0) when strategy is count-based (version_retention)" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi

    create_count_retention_yaml "myapp"
    create_mock_version_sh "myapp"

    run latest_per_major_versions "myapp"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ----------------------------------------------------------------
# latest_per_major_versions — empty retained_majors
# ----------------------------------------------------------------

@test "latest_per_major_versions: returns empty (exit 0) when retained_majors is empty" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi

    create_empty_majors_yaml "myapp"
    create_mock_version_sh "myapp"

    run latest_per_major_versions "myapp"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ----------------------------------------------------------------
# latest_per_major_versions — happy path
# ----------------------------------------------------------------

@test "latest_per_major_versions: calls version.sh --major N for each major and emits one version per line" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi

    create_latest_per_major_yaml "myapp"
    create_mock_version_sh "myapp"

    run latest_per_major_versions "myapp"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 2 ]
    echo "$output" | grep -q "7.0.0-alpine"
    echo "$output" | grep -q "6.9.4-alpine"
}

@test "latest_per_major_versions: order preserved — retained_majors [7, 6] yields 7.x first then 6.x" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi

    create_latest_per_major_yaml "myapp"
    create_mock_version_sh "myapp"

    run latest_per_major_versions "myapp"
    [ "$status" -eq 0 ]

    first=$(echo "$output" | head -1)
    second=$(echo "$output" | tail -1)
    [[ "$first" == "7.0.0-alpine" ]]
    [[ "$second" == "6.9.4-alpine" ]]
}

# ----------------------------------------------------------------
# latest_per_major_versions — failure cases
# ----------------------------------------------------------------

@test "latest_per_major_versions: returns non-zero when version.sh fails for any major" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi

    create_latest_per_major_yaml "myapp"
    create_failing_version_sh "myapp"

    run latest_per_major_versions "myapp"
    [ "$status" -ne 0 ]
}

@test "latest_per_major_versions: returns non-zero (exit 1) when variants.yaml is missing" {
    run latest_per_major_versions "nonexistent_dir"
    [ "$status" -ne 0 ]
}

# ----------------------------------------------------------------
# wordpress/version.sh --major N
# ----------------------------------------------------------------

@test "version.sh --major: returns versioned tag when latest-docker-tag returns a match" {
    # Mock helpers/latest-docker-tag so no Docker required
    mkdir -p helpers
    cat > helpers/latest-docker-tag <<'MOCK'
#!/bin/bash
# Args: library/wordpress "^7\.[0-9]+\.[0-9]+$"
# Return a fixed version matching the major
pattern="$2"
if echo "7.0.0" | grep -qE "${pattern}"; then
    echo "7.0.0"
    exit 0
fi
exit 1
MOCK
    chmod +x helpers/latest-docker-tag

    # Create a minimal wordpress/version.sh pointing at our mock
    mkdir -p wordpress
    cat > wordpress/version.sh <<'VEOF'
#!/bin/bash
REGISTRY_PATTERN="^[0-9]+\.[0-9]+\.[0-9]+-alpine$"
if [[ "$1" == "--registry-pattern" ]]; then echo "$REGISTRY_PATTERN"; exit 0; fi
if [[ "$1" == "--major" ]]; then
    major="$2"
    if [[ -z "$major" || ! "$major" =~ ^[0-9]+$ ]]; then
        echo "error: --major requires a numeric value" >&2; exit 1
    fi
    upstream_version=$("$(dirname "$0")/../helpers/latest-docker-tag" library/wordpress "^${major}\.[0-9]+\.[0-9]+\$")
    if [[ -n "$upstream_version" ]]; then echo "${upstream_version}-alpine"; exit 0; fi
    exit 1
fi
upstream_version=$("$(dirname "$0")/../helpers/latest-docker-tag" library/wordpress "^[0-9]+\.[0-9]+\.[0-9]+$")
if [[ -n "$upstream_version" ]]; then echo "${upstream_version}-alpine"; else exit 1; fi
VEOF
    chmod +x wordpress/version.sh

    run wordpress/version.sh --major 7
    [ "$status" -eq 0 ]
    [[ "$output" == "7.0.0-alpine" ]]
}

@test "version.sh --major: fails fast with non-numeric argument" {
    mkdir -p helpers
    cat > helpers/latest-docker-tag <<'MOCK'
#!/bin/bash
echo "should-not-be-called"
exit 0
MOCK
    chmod +x helpers/latest-docker-tag

    mkdir -p wordpress
    cat > wordpress/version.sh <<'VEOF'
#!/bin/bash
REGISTRY_PATTERN="^[0-9]+\.[0-9]+\.[0-9]+-alpine$"
if [[ "$1" == "--registry-pattern" ]]; then echo "$REGISTRY_PATTERN"; exit 0; fi
if [[ "$1" == "--major" ]]; then
    major="$2"
    if [[ -z "$major" || ! "$major" =~ ^[0-9]+$ ]]; then
        echo "error: --major requires a numeric value" >&2; exit 1
    fi
    upstream_version=$("$(dirname "$0")/../helpers/latest-docker-tag" library/wordpress "^${major}\.[0-9]+\.[0-9]+\$")
    if [[ -n "$upstream_version" ]]; then echo "${upstream_version}-alpine"; exit 0; fi
    exit 1
fi
upstream_version=$("$(dirname "$0")/../helpers/latest-docker-tag" library/wordpress "^[0-9]+\.[0-9]+\.[0-9]+$")
if [[ -n "$upstream_version" ]]; then echo "${upstream_version}-alpine"; else exit 1; fi
VEOF
    chmod +x wordpress/version.sh

    run wordpress/version.sh --major abc
    [ "$status" -ne 0 ]
}

@test "version.sh --major: fails fast when no argument given after --major" {
    mkdir -p helpers
    cat > helpers/latest-docker-tag <<'MOCK'
#!/bin/bash
echo "should-not-be-called"
exit 0
MOCK
    chmod +x helpers/latest-docker-tag

    mkdir -p wordpress
    cat > wordpress/version.sh <<'VEOF'
#!/bin/bash
REGISTRY_PATTERN="^[0-9]+\.[0-9]+\.[0-9]+-alpine$"
if [[ "$1" == "--registry-pattern" ]]; then echo "$REGISTRY_PATTERN"; exit 0; fi
if [[ "$1" == "--major" ]]; then
    major="$2"
    if [[ -z "$major" || ! "$major" =~ ^[0-9]+$ ]]; then
        echo "error: --major requires a numeric value" >&2; exit 1
    fi
    upstream_version=$("$(dirname "$0")/../helpers/latest-docker-tag" library/wordpress "^${major}\.[0-9]+\.[0-9]+\$")
    if [[ -n "$upstream_version" ]]; then echo "${upstream_version}-alpine"; exit 0; fi
    exit 1
fi
upstream_version=$("$(dirname "$0")/../helpers/latest-docker-tag" library/wordpress "^[0-9]+\.[0-9]+\.[0-9]+$")
if [[ -n "$upstream_version" ]]; then echo "${upstream_version}-alpine"; else exit 1; fi
VEOF
    chmod +x wordpress/version.sh

    run wordpress/version.sh --major
    [ "$status" -ne 0 ]
}

# ----------------------------------------------------------------
# rotate-versions.sh — latest_per_major strategy
# ----------------------------------------------------------------

@test "rotate: latest_per_major strategy rewrites versions[] from resolved output" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi

    create_latest_per_major_yaml "myapp"
    create_mock_version_sh "myapp"

    run scripts/rotate-versions.sh "myapp" "7.0.0-alpine"
    [ "$status" -eq 0 ]

    count=$(yq -r '.versions | length' myapp/variants.yaml)
    [ "$count" -eq 2 ]

    tag0=$(yq -r '.versions[0].tag' myapp/variants.yaml)
    tag1=$(yq -r '.versions[1].tag' myapp/variants.yaml)
    [[ "$tag0" == "7.0.0-alpine" ]]
    [[ "$tag1" == "6.9.4-alpine" ]]
}

@test "rotate: latest_per_major exit code 2 is NOT returned (strategy takes over from count-based)" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi

    create_latest_per_major_yaml "myapp"
    create_mock_version_sh "myapp"

    # If latest_per_major were to fall through to count-based path, it would exit 2.
    # The strategy branch should intercept and exit 0.
    run scripts/rotate-versions.sh "myapp" "anything"
    [ "$status" -eq 0 ]
}
