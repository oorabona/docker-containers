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

@test "latest_per_major_versions: defensive sort — misconfigured [6, 7] still yields 7.x first" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi

    # Misconfigured order: operator wrote retained_majors: [6, 7] instead of [7, 6].
    # The helper must still emit 7.x first so downstream "first version = default"
    # semantics stay correct.
    mkdir -p myapp
    cat > myapp/variants.yaml <<'EOF'
build:
  retention_strategy: latest_per_major
  retained_majors: [6, 7]
versions:
  - tag: 6.9.4-alpine
  - tag: 7.0.0-alpine
EOF
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

    # Copy the REAL wordpress/version.sh into the fixture so the test exercises
    # the actual code being shipped. The mocked helpers/latest-docker-tag above
    # is found via the script's own `$(dirname "$0")/../helpers/latest-docker-tag`
    # lookup, so it picks up the temp-dir mock and never hits the network.
    mkdir -p wordpress
    cp "$ORIG_DIR/wordpress/version.sh" wordpress/version.sh
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

# ----------------------------------------------------------------
# check_updates multi-entry output for latest_per_major containers
# ----------------------------------------------------------------

# Helper: create a minimal make-compatible fixture for check_updates tests.
# Sets up a self-contained $TEST_DIR tree that can run `./make check-updates wordpress`
# without Docker or network access.
#
# Args:
#   mock_ghcr_7  — version to return when querying GHCR for 7.x pattern
#   mock_ghcr_6  — version to return when querying GHCR for 6.x pattern
#   mock_latest_7 — version returned by version.sh --major 7
#   mock_latest_6 — version returned by version.sh --major 6
create_check_updates_fixture() {
    local mock_ghcr_7="${1:-7.0.0-alpine}"
    local mock_ghcr_6="${2:-6.9.4-alpine}"
    local mock_latest_7="${3:-7.0.0-alpine}"
    local mock_latest_6="${4:-6.9.4-alpine}"

    mkdir -p wordpress helpers scripts

    # variants.yaml with latest_per_major strategy
    cat > wordpress/variants.yaml <<'EOF'
build:
  retention_strategy: latest_per_major
  retained_majors: [7, 6]
versions:
  - tag: 7.0.0-alpine
  - tag: 6.9.4-alpine
EOF

    # version.sh: returns per-major or global latest via argument matching
    # Use printf to avoid quoting issues with the EOF markers
    printf '#!/bin/bash\n' > wordpress/version.sh
    printf 'REGISTRY_PATTERN="^[0-9]+\\.[0-9]+\\.[0-9]+-alpine$"\n' >> wordpress/version.sh
    printf 'if [[ "$1" == "--registry-pattern" ]]; then echo "$REGISTRY_PATTERN"; exit 0; fi\n' >> wordpress/version.sh
    printf 'if [[ "$1" == "--major" ]]; then\n' >> wordpress/version.sh
    printf '  case "$2" in\n' >> wordpress/version.sh
    printf '    7) echo "%s" ; exit 0 ;;\n' "${mock_latest_7}" >> wordpress/version.sh
    printf '    6) echo "%s" ; exit 0 ;;\n' "${mock_latest_6}" >> wordpress/version.sh
    printf '    *) exit 1 ;;\n' >> wordpress/version.sh
    printf '  esac\n' >> wordpress/version.sh
    printf 'fi\n' >> wordpress/version.sh
    printf 'echo "%s"\n' "${mock_latest_7}" >> wordpress/version.sh
    chmod +x wordpress/version.sh

    # latest-docker-tag mock: returns version based on the GHCR image+pattern.
    # The pattern arg is a regex like "^7\.[0-9]+..." — we match only the major
    # prefix "^N" (enough to route to the right mock return value).
    printf '#!/bin/bash\n' > helpers/latest-docker-tag
    printf '# Args: <image> <pattern>\n' >> helpers/latest-docker-tag
    printf 'pattern="$2"\n' >> helpers/latest-docker-tag
    printf 'if echo "$pattern" | grep -qE "^\\^7"; then\n' >> helpers/latest-docker-tag
    if [[ "$mock_ghcr_7" == "__EMPTY_FAILURE__" ]]; then
        printf '  exit 1\n' >> helpers/latest-docker-tag
    else
        printf '  echo "%s"; exit 0\n' "${mock_ghcr_7}" >> helpers/latest-docker-tag
    fi
    printf 'fi\n' >> helpers/latest-docker-tag
    printf 'if echo "$pattern" | grep -qE "^\\^6"; then\n' >> helpers/latest-docker-tag
    if [[ "$mock_ghcr_6" == "__EMPTY_FAILURE__" ]]; then
        printf '  exit 1\n' >> helpers/latest-docker-tag
    else
        printf '  echo "%s"; exit 0\n' "${mock_ghcr_6}" >> helpers/latest-docker-tag
    fi
    printf 'fi\n' >> helpers/latest-docker-tag
    printf 'exit 1\n' >> helpers/latest-docker-tag
    chmod +x helpers/latest-docker-tag

    # Minimal logging stub (make sources helpers/logging.sh)
    cat > helpers/logging.sh <<'EOF'
log_error()   { echo "ERROR: $*" >&2; }
log_warning() { echo "WARN: $*"  >&2; }
log_info()    { echo "INFO: $*"  >&2; }
log_success() { :; }
log_help()    { :; }
export DOCKER="${DOCKER:-docker}"
export SKOPEO="${SKOPEO:-skopeo}"
EOF

    # registry-utils stub: list_containers finds subdirs (excludes helpers/scripts/bin)
    cat > helpers/registry-utils.sh <<'EOF'
list_containers() {
    find "${1:-.}" -maxdepth 1 -mindepth 1 -type d \
        ! -name '.*' ! -name 'helpers' ! -name 'scripts' ! -name 'bin' \
        2>/dev/null | xargs -I{} basename {} 2>/dev/null
}
has_dockerfile()  { return 0; }
EOF

    # sbom-utils stub
    cat > helpers/sbom-utils.sh <<'EOF'
EOF

    # check-version stub
    cat > scripts/check-version.sh <<'EOF'
get_build_version() { echo "${2:-latest}"; return 0; }
EOF

    # build/push stubs (sourced by make but not needed for check-updates)
    cat > scripts/build-container.sh <<'EOF'
EOF
    cat > scripts/push-container.sh <<'EOF'
EOF

    cp "$ORIG_DIR/helpers/variant-utils.sh" helpers/
    cp "$ORIG_DIR/helpers/version-utils.sh" helpers/

    # Copy make to $TEST_DIR so `./make check-updates` runs with TEST_DIR as $(dirname $0).
    # This ensures `source "$(dirname "$0")/helpers/..."` resolves to the TEST_DIR stubs.
    cp "$ORIG_DIR/make" ./make
    chmod +x ./make
}

# Run check_updates inside the fixture and capture JSON output to stdout.
# Usage: run_check_updates <container>
run_check_updates() {
    local container="${1:-wordpress}"
    # Suppress docker-compose availability check errors from make
    ./make check-updates "$container" 2>/dev/null
}

create_default_check_updates_fixture() {
    local mock_current="${1:-1.0.0-ubuntu}"
    local mock_latest="${2:-2.0.0-ubuntu}"
    local registry_pattern="${3:-^[0-9]+\.[0-9]+(\.[0-9]+)?-ubuntu$}"

    mkdir -p ansible helpers scripts

    cat > ansible/variants.yaml <<'EOF'
build:
  requires_extensions: false
versions:
  - tag: 1.0.0-ubuntu
EOF

    printf '#!/bin/bash\n' > ansible/version.sh
    printf "REGISTRY_PATTERN='%s'\n" "$registry_pattern" >> ansible/version.sh
    printf 'if [[ "$1" == "--registry-pattern" ]]; then echo "$REGISTRY_PATTERN"; exit 0; fi\n' >> ansible/version.sh
    printf 'echo "%s"\n' "$mock_latest" >> ansible/version.sh
    chmod +x ansible/version.sh

    printf '#!/bin/bash\n' > helpers/latest-docker-tag
    if [[ "$mock_current" == "__NO_PUBLISHED__" ]]; then
        printf 'echo "no-published-version"\n' >> helpers/latest-docker-tag
        printf 'exit 0\n' >> helpers/latest-docker-tag
    elif [[ "$mock_current" == "__EMPTY_FAILURE__" ]]; then
        printf 'exit 1\n' >> helpers/latest-docker-tag
    else
        printf 'echo "%s"\n' "$mock_current" >> helpers/latest-docker-tag
        printf 'exit 0\n' >> helpers/latest-docker-tag
    fi
    chmod +x helpers/latest-docker-tag

    cat > helpers/logging.sh <<'EOF'
log_error()   { echo "ERROR: $*" >&2; }
log_warning() { echo "WARN: $*"  >&2; }
log_info()    { echo "INFO: $*"  >&2; }
log_success() { :; }
log_help()    { :; }
export DOCKER="${DOCKER:-docker}"
export SKOPEO="${SKOPEO:-skopeo}"
EOF

    cat > helpers/registry-utils.sh <<'EOF'
list_containers() {
    find "${1:-.}" -maxdepth 1 -mindepth 1 -type d \
        ! -name '.*' ! -name 'helpers' ! -name 'scripts' ! -name 'bin' \
        2>/dev/null | xargs -I{} basename {} 2>/dev/null
}
has_dockerfile()  { return 0; }
EOF

    cat > helpers/sbom-utils.sh <<'EOF'
EOF

    cat > scripts/check-version.sh <<'EOF'
get_build_version() { echo "${2:-latest}"; return 0; }
EOF

    cat > scripts/build-container.sh <<'EOF'
EOF
    cat > scripts/push-container.sh <<'EOF'
EOF

    cp "$ORIG_DIR/helpers/version-utils.sh" helpers/

    cp "$ORIG_DIR/make" ./make
    chmod +x ./make
}

create_debian_check_updates_fixture() {
    local mock_current="${1:-trixie}"
    local mock_latest="${2:-bookworm}"

    mkdir -p debian helpers scripts bin

    cat > debian/variants.yaml <<'EOF'
build:
  requires_extensions: false
versions:
  - tag: trixie
EOF

    printf '#!/bin/bash\n' > debian/version.sh
    printf 'if [[ "$1" == "--registry-pattern" ]]; then echo "^(trixie|bookworm|bullseye)$"; exit 0; fi\n' >> debian/version.sh
    printf 'if [[ "$1" == "--numeric-alias-image" ]]; then echo "library/debian"; exit 0; fi\n' >> debian/version.sh
    printf 'if [[ "$1" == "--numeric-alias-pattern" ]]; then echo "^[0-9]+$"; exit 0; fi\n' >> debian/version.sh
    printf 'echo "%s"\n' "$mock_latest" >> debian/version.sh
    chmod +x debian/version.sh

    cp "$ORIG_DIR/helpers/docker-tag" helpers/docker-tag
    chmod +x helpers/docker-tag
    ln -sf docker-tag helpers/latest-docker-tag

    printf '#!/bin/bash\n' > bin/docker
    printf 'set -euo pipefail\n' >> bin/docker
    printf 'MOCK_CURRENT=%q\n' "$mock_current" >> bin/docker
    cat >> bin/docker <<'EOF'
if [[ "${1:-}" != "run" ]]; then
    exit 99
fi
shift

if [[ "${1:-}" == "--rm" ]]; then
    shift
fi

shift # skopeo image
command="${1:-}"
shift

case "$command" in
    list-tags)
        ref="${1:-}"
        case "$ref" in
            docker://ghcr.io/oorabona/debian)
                printf '{"Repository":"ghcr.io/oorabona/debian","Tags":["%s"]}\n' "$MOCK_CURRENT"
                ;;
            docker://library/debian)
                printf '{"Repository":"library/debian","Tags":["11","12","13","12.14","bookworm","trixie","bullseye"]}\n'
                ;;
            *)
                exit 41
                ;;
        esac
        ;;
    inspect)
        if [[ "${1:-}" == "--format" ]]; then
            shift 2
        fi
        ref="${1:-}"
        case "$ref" in
            docker://library/debian:trixie|docker://library/debian:13)
                echo "sha256:thirteen"
                ;;
            docker://library/debian:bookworm|docker://library/debian:12)
                echo "sha256:twelve"
                ;;
            docker://library/debian:bullseye|docker://library/debian:11)
                echo "sha256:eleven"
                ;;
            *)
                exit 42
                ;;
        esac
        ;;
    *)
        exit 98
        ;;
esac
EOF
    chmod +x bin/docker
    export PATH="$TEST_DIR/bin:$PATH"

    cat > helpers/logging.sh <<'EOF'
log_error()   { echo "ERROR: $*" >&2; }
log_warning() { echo "WARN: $*"  >&2; }
log_info()    { echo "INFO: $*"  >&2; }
log_success() { :; }
log_help()    { :; }
export DOCKER="${DOCKER:-docker}"
export SKOPEO="${SKOPEO:-skopeo}"
EOF

    cat > helpers/registry-utils.sh <<'EOF'
list_containers() {
    find "${1:-.}" -maxdepth 1 -mindepth 1 -type d \
        ! -name '.*' ! -name 'helpers' ! -name 'scripts' ! -name 'bin' \
        2>/dev/null | xargs -I{} basename {} 2>/dev/null
}
has_dockerfile()  { return 0; }
EOF

    cat > helpers/sbom-utils.sh <<'EOF'
EOF

    cat > scripts/check-version.sh <<'EOF'
get_build_version() { echo "${2:-latest}"; return 0; }
EOF

    cat > scripts/build-container.sh <<'EOF'
EOF
    cat > scripts/push-container.sh <<'EOF'
EOF

    cp "$ORIG_DIR/helpers/version-utils.sh" helpers/

    cp "$ORIG_DIR/make" ./make
    chmod +x ./make
}

@test "check_updates multi-entry: emits one entry per retained major for latest_per_major container" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi

    create_check_updates_fixture "7.0.0-alpine" "6.9.4-alpine" "7.0.0-alpine" "6.9.4-alpine"

    run run_check_updates wordpress
    [ "$status" -eq 0 ]

    # Should have exactly 2 entries
    count=$(echo "$output" | jq 'length')
    [ "$count" -eq 2 ]

    # Both entries should have major_line set (7 first, 6 second — desc sort)
    ml0=$(echo "$output" | jq -r '.[0].major_line')
    ml1=$(echo "$output" | jq -r '.[1].major_line')
    [[ "$ml0" == "7" ]]
    [[ "$ml1" == "6" ]]
}

@test "check_updates multi-entry: update_available=true only for 6.x when 6.x has new patch" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi

    # GHCR has 7.0.0-alpine (up-to-date) and 6.9.4-alpine; upstream has 6.9.5-alpine for 6.x
    create_check_updates_fixture "7.0.0-alpine" "6.9.4-alpine" "7.0.0-alpine" "6.9.5-alpine"

    run run_check_updates wordpress
    [ "$status" -eq 0 ]

    # 7.x should be up-to-date, 6.x should have update available
    update_7=$(echo "$output" | jq -r '.[] | select(.major_line == "7") | .update_available')
    update_6=$(echo "$output" | jq -r '.[] | select(.major_line == "6") | .update_available')
    [[ "$update_7" == "false" ]]
    [[ "$update_6" == "true" ]]

    # Container field should be composite key "wordpress:7" / "wordpress:6"
    container_7=$(echo "$output" | jq -r '.[] | select(.major_line == "7") | .container')
    container_6=$(echo "$output" | jq -r '.[] | select(.major_line == "6") | .container')
    [[ "$container_7" == "wordpress:7" ]]
    [[ "$container_6" == "wordpress:6" ]]
}

@test "check_updates multi-entry: update_available=false for both lines when nothing changed" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi

    # Both GHCR and upstream are in sync for both majors
    create_check_updates_fixture "7.0.0-alpine" "6.9.4-alpine" "7.0.0-alpine" "6.9.4-alpine"

    run run_check_updates wordpress
    [ "$status" -eq 0 ]

    update_7=$(echo "$output" | jq -r '.[] | select(.major_line == "7") | .update_available')
    update_6=$(echo "$output" | jq -r '.[] | select(.major_line == "6") | .update_available')
    [[ "$update_7" == "false" ]]
    [[ "$update_6" == "false" ]]
}

@test "check_updates multi-entry: downgrade in latest_per_major path is not an update" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi

    # GHCR already has 6.9.5-alpine, but upstream resolution reports older 6.9.4-alpine.
    create_check_updates_fixture "7.0.0-alpine" "6.9.5-alpine" "7.0.0-alpine" "6.9.4-alpine"

    run run_check_updates wordpress
    [ "$status" -eq 0 ]

    update_6=$(echo "$output" | jq -r '.[] | select(.major_line == "6") | .update_available')
    status_6=$(echo "$output" | jq -r '.[] | select(.major_line == "6") | .status')
    [[ "$update_6" == "false" ]]
    [[ "$status_6" == "up_to_date" ]]
}

@test "check_updates multi-entry: accepted empty current_version ambiguity reports new-container" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi

    # Accepted pre-existing ambiguity: Docker/GHCR/skopeo/rate-limit helper failures and genuinely unpublished containers both yield empty current_version; status is cosmetic, not a fully reasoned contract.
    create_check_updates_fixture "7.0.0-alpine" "__EMPTY_FAILURE__" "7.0.0-alpine" "6.9.4-alpine"

    run run_check_updates wordpress
    [ "$status" -eq 0 ]

    current_6=$(echo "$output" | jq -r '.[] | select(.major_line == "6") | .current_version')
    update_6=$(echo "$output" | jq -r '.[] | select(.major_line == "6") | .update_available')
    status_6=$(echo "$output" | jq -r '.[] | select(.major_line == "6") | .status')
    [[ -z "$current_6" ]]
    [[ "$update_6" == "true" ]]
    [[ "$status_6" == "new-container" ]]
}

@test "check_updates default path: genuine newer latest is an update" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi

    create_default_check_updates_fixture "1.0.0-ubuntu" "1.1.0-ubuntu"

    run run_check_updates ansible
    [ "$status" -eq 0 ]

    update_available=$(echo "$output" | jq -r '.[0].update_available')
    status_value=$(echo "$output" | jq -r '.[0].status')
    [[ "$update_available" == "true" ]]
    [[ "$status_value" == "update-available" ]]
}

@test "check_updates default path: digit-leading versions skip numeric alias probes" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi

    create_default_check_updates_fixture "1.0.0-ubuntu" "1.1.0-ubuntu"
    call_log="${TEST_DIR}/numeric-alias-calls.log"

    printf '#!/bin/bash\n' > ansible/version.sh
    printf 'CALL_LOG=%q\n' "$call_log" >> ansible/version.sh
    cat >> ansible/version.sh <<'EOF'
REGISTRY_PATTERN='^[0-9]+\.[0-9]+(\.[0-9]+)?-ubuntu$'
if [[ "${1:-}" == "--registry-pattern" ]]; then echo "$REGISTRY_PATTERN"; exit 0; fi
if [[ "${1:-}" == "--numeric-alias-image" || "${1:-}" == "--numeric-alias-pattern" ]]; then
    printf '%s\n' "$1" >> "$CALL_LOG"
    echo "unexpected numeric alias probe" >&2
    exit 77
fi
echo "1.1.0-ubuntu"
EOF
    chmod +x ansible/version.sh

    run run_check_updates ansible
    [ "$status" -eq 0 ]

    update_available=$(echo "$output" | jq -r '.[0].update_available')
    status_value=$(echo "$output" | jq -r '.[0].status')
    [[ "$update_available" == "true" ]]
    [[ "$status_value" == "update-available" ]]
    if [[ -s "$call_log" ]]; then
        fail "numeric alias flags should not be invoked for digit-leading versions"
    fi
}

@test "check_updates default path: v-prefixed versions flag genuine upgrades" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi

    create_default_check_updates_fixture "v2.6.17-alpine" "v2.6.18-alpine" "^v[0-9]+\.[0-9]+\.[0-9]+-alpine$"

    run run_check_updates ansible
    [ "$status" -eq 0 ]

    update_available=$(echo "$output" | jq -r '.[0].update_available')
    status_value=$(echo "$output" | jq -r '.[0].status')
    [[ "$update_available" == "true" ]]
    [[ "$status_value" == "update-available" ]]
}

@test "check_updates default path: v-prefixed downgrades are not updates" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi

    create_default_check_updates_fixture "v2.6.17-alpine" "v2.6.16-alpine" "^v[0-9]+\.[0-9]+\.[0-9]+-alpine$"

    run run_check_updates ansible
    [ "$status" -eq 0 ]

    update_available=$(echo "$output" | jq -r '.[0].update_available')
    status_value=$(echo "$output" | jq -r '.[0].status')
    [[ "$update_available" == "false" ]]
    [[ "$status_value" == "up_to_date" ]]
}

@test "check_updates default path: accepted empty current_version ambiguity reports new-container" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi

    # Accepted pre-existing ambiguity: Docker/GHCR/skopeo/rate-limit helper failures and genuinely unpublished containers both yield empty current_version; status is cosmetic, not a fully reasoned contract.
    create_default_check_updates_fixture "__EMPTY_FAILURE__" "14.1.0-ubuntu"

    run run_check_updates ansible
    [ "$status" -eq 0 ]

    current_version=$(echo "$output" | jq -r '.[0].current_version')
    update_available=$(echo "$output" | jq -r '.[0].update_available')
    status_value=$(echo "$output" | jq -r '.[0].status')
    [[ -z "$current_version" ]]
    [[ "$update_available" == "true" ]]
    [[ "$status_value" == "new-container" ]]
}

@test "check_updates default path: same numeric tuple with different suffix is an update" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi

    # dpkg compares Debian-style revision suffixes numerically, so r1 is a real update over r0.
    create_default_check_updates_fixture "1.2.3-r0" "1.2.3-r1" "^[0-9]+\.[0-9]+\.[0-9]+-r[0-9]+$"

    run run_check_updates ansible
    [ "$status" -eq 0 ]

    update_available=$(echo "$output" | jq -r '.[0].update_available')
    status_value=$(echo "$output" | jq -r '.[0].status')
    [[ "$update_available" == "true" ]]
    [[ "$status_value" == "update-available" ]]
}

@test "check_updates default path: revision-suffix downgrade is not an update" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi

    create_default_check_updates_fixture "1.2.3-r10" "1.2.3-r2" "^[0-9]+\.[0-9]+\.[0-9]+-r[0-9]+$"

    run run_check_updates ansible
    [ "$status" -eq 0 ]

    update_available=$(echo "$output" | jq -r '.[0].update_available')
    status_value=$(echo "$output" | jq -r '.[0].status')
    [[ "$update_available" == "false" ]]
    [[ "$status_value" == "up_to_date" ]]
}

@test "check_updates default path: ansible downgrade regression is not an update" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi

    create_default_check_updates_fixture "14.1.0-ubuntu" "14.0.0-ubuntu"

    run run_check_updates ansible
    [ "$status" -eq 0 ]

    update_available=$(echo "$output" | jq -r '.[0].update_available')
    status_value=$(echo "$output" | jq -r '.[0].status')
    [[ "$update_available" == "false" ]]
    [[ "$status_value" == "up_to_date" ]]
}

@test "check_updates default path: debian codename downgrade is blocked through numeric alias digests" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi

    create_debian_check_updates_fixture "trixie" "bookworm"

    run run_check_updates debian
    [ "$status" -eq 0 ]

    update_available=$(echo "$output" | jq -r '.[0].update_available')
    status_value=$(echo "$output" | jq -r '.[0].status')
    current_version=$(echo "$output" | jq -r '.[0].current_version')
    latest_version=$(echo "$output" | jq -r '.[0].latest_version')
    [[ "$current_version" == "trixie" ]]
    [[ "$latest_version" == "bookworm" ]]
    [[ "$update_available" == "false" ]]
    [[ "$status_value" == "up_to_date" ]]
}

@test "check_updates default path: debian codename upgrade remains an update through numeric alias digests" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi

    create_debian_check_updates_fixture "bookworm" "trixie"

    run run_check_updates debian
    [ "$status" -eq 0 ]

    update_available=$(echo "$output" | jq -r '.[0].update_available')
    status_value=$(echo "$output" | jq -r '.[0].status')
    current_version=$(echo "$output" | jq -r '.[0].current_version')
    latest_version=$(echo "$output" | jq -r '.[0].latest_version')
    [[ "$current_version" == "bookworm" ]]
    [[ "$latest_version" == "trixie" ]]
    [[ "$update_available" == "true" ]]
    [[ "$status_value" == "update-available" ]]
}

@test "check_updates default path: testing and stable labels without numeric alias remain permissive" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi

    create_default_check_updates_fixture "testing" "stable" "^(stable|testing)$"

    run run_check_updates ansible
    [ "$status" -eq 0 ]

    update_available=$(echo "$output" | jq -r '.[0].update_available')
    status_value=$(echo "$output" | jq -r '.[0].status')
    [[ "$update_available" == "true" ]]
    [[ "$status_value" == "update-available" ]]
}

@test "check_updates default path: equal versions are not an update" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi

    create_default_check_updates_fixture "14.1.0-ubuntu" "14.1.0-ubuntu"

    run run_check_updates ansible
    [ "$status" -eq 0 ]

    update_available=$(echo "$output" | jq -r '.[0].update_available')
    status_value=$(echo "$output" | jq -r '.[0].status')
    [[ "$update_available" == "false" ]]
    [[ "$status_value" == "up_to_date" ]]
}

@test "check_updates default path: no published version remains a new container" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi

    create_default_check_updates_fixture "__NO_PUBLISHED__" "14.1.0-ubuntu"

    run run_check_updates ansible
    [ "$status" -eq 0 ]

    current_version=$(echo "$output" | jq -r '.[0].current_version')
    update_available=$(echo "$output" | jq -r '.[0].update_available')
    status_value=$(echo "$output" | jq -r '.[0].status')
    [[ "$current_version" == "no-published-version" ]]
    [[ "$update_available" == "true" ]]
    [[ "$status_value" == "new-container" ]]
}

# ----------------------------------------------------------------
# rotate-versions.sh — MAJOR_LINE single-line update path
# ----------------------------------------------------------------

@test "rotate MAJOR_LINE=6: updates only the 6.x entry, leaves 7.x untouched" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi

    create_latest_per_major_yaml "myapp"
    create_mock_version_sh "myapp"

    # Pass major_line as positional arg (mirrors upstream-monitor call)
    run scripts/rotate-versions.sh "myapp" "6.9.5-alpine" "6"
    [ "$status" -eq 0 ]

    tag0=$(yq -r '.versions[0].tag' myapp/variants.yaml)
    tag1=$(yq -r '.versions[1].tag' myapp/variants.yaml)

    # 7.x entry must be unchanged
    [[ "$tag0" == "7.0.0-alpine" ]]
    # 6.x entry must be updated
    [[ "$tag1" == "6.9.5-alpine" ]]
}

@test "rotate MAJOR_LINE env: updates only the 6.x entry via env var" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi

    create_latest_per_major_yaml "myapp"
    create_mock_version_sh "myapp"

    # Use MAJOR_LINE env var (mirrors upstream-monitor env block)
    run env MAJOR_LINE=6 scripts/rotate-versions.sh "myapp" "6.9.5-alpine"
    [ "$status" -eq 0 ]

    tag0=$(yq -r '.versions[0].tag' myapp/variants.yaml)
    tag1=$(yq -r '.versions[1].tag' myapp/variants.yaml)
    [[ "$tag0" == "7.0.0-alpine" ]]
    [[ "$tag1" == "6.9.5-alpine" ]]
}

@test "rotate MAJOR_LINE=7: updates only the 7.x entry, leaves 6.x untouched" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi

    create_latest_per_major_yaml "myapp"
    create_mock_version_sh "myapp"

    run scripts/rotate-versions.sh "myapp" "7.0.1-alpine" "7"
    [ "$status" -eq 0 ]

    tag0=$(yq -r '.versions[0].tag' myapp/variants.yaml)
    tag1=$(yq -r '.versions[1].tag' myapp/variants.yaml)
    [[ "$tag0" == "7.0.1-alpine" ]]
    [[ "$tag1" == "6.9.4-alpine" ]]
}

@test "rotate MAJOR_LINE=invalid: exits 1 for non-numeric major_line" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi

    create_latest_per_major_yaml "myapp"
    create_mock_version_sh "myapp"

    run scripts/rotate-versions.sh "myapp" "6.9.5-alpine" "abc"
    [ "$status" -eq 1 ]
}

@test "rotate without MAJOR_LINE: full re-resolution path still works (regression)" {
    if ! command -v yq &>/dev/null; then skip "yq not available"; fi
    if ! command -v jq &>/dev/null; then skip "jq not available"; fi

    create_latest_per_major_yaml "myapp"
    create_mock_version_sh "myapp"

    # No MAJOR_LINE — full re-resolution via latest_per_major_versions
    run scripts/rotate-versions.sh "myapp" "7.0.0-alpine"
    [ "$status" -eq 0 ]

    count=$(yq -r '.versions | length' myapp/variants.yaml)
    [ "$count" -eq 2 ]

    tag0=$(yq -r '.versions[0].tag' myapp/variants.yaml)
    tag1=$(yq -r '.versions[1].tag' myapp/variants.yaml)
    [[ "$tag0" == "7.0.0-alpine" ]]
    [[ "$tag1" == "6.9.4-alpine" ]]
}
