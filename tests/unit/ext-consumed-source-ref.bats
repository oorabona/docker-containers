#!/usr/bin/env bats

# The consumed-source gateway owns generated Dockerfile source references.  The
# checks below cover its three modes plus the narrow frozen rotation selector.

bats_require_minimum_version 1.5.0

load "../test_helper"

_source_extension_utils() {
    # shellcheck disable=SC1091
    source "$HELPERS_DIR/extension-utils.sh"
}

_digest() {
    printf 'sha256:%064d' "${1:-0}"
}

# shellcheck disable=SC2317
setup() {
    setup_temp_dir
    _source_extension_utils
    get_registry() { printf 'ghcr.io'; }
    get_repo_owner() { printf 'testowner'; }
    unset ROTATION_CANDIDATE_REF EXTENSION_PACKAGE_SUFFIX PR_TAG_SUFFIX
}

teardown() {
    unset ROTATION_CANDIDATE_REF EXTENSION_PACKAGE_SUFFIX PR_TAG_SUFFIX
    teardown_temp_dir
}

# shellcheck disable=SC2030,SC2031
@test "matching frozen candidate wins pinned-digest, probe, and direct modes" {
    local digest candidate
    digest=$(_digest 42)
    candidate="pgvector:18:0.8.2=ghcr.io/testowner/ext-pgvector-staging@${digest}"
    export ROTATION_CANDIDATE_REF="$candidate"

    ext_ref_resolve() { printf 'probe-must-not-run'; return 0; }

    run ext_consumed_source_ref pgvector 0.8.2 18 ghcr.io testowner pinned-digest "$(_digest 1)"
    [ "$status" -eq 0 ]
    [ "$output" = "ghcr.io/testowner/ext-pgvector-staging@${digest}" ]

    run ext_consumed_source_ref pgvector 0.8.2 18 ghcr.io testowner probe
    [ "$status" -eq 0 ]
    [ "$output" = "ghcr.io/testowner/ext-pgvector-staging@${digest}" ]

    run ext_consumed_source_ref pgvector 0.8.2 18 ghcr.io testowner direct
    [ "$status" -eq 0 ]
    [ "$output" = "ghcr.io/testowner/ext-pgvector-staging@${digest}" ]
}

# shellcheck disable=SC2030,SC2031
@test "non-matching frozen candidate keeps retained and other extensions canonical" {
    local digest
    digest=$(_digest 43)
    export ROTATION_CANDIDATE_REF="pgvector:18:0.8.2=ghcr.io/testowner/ext-pgvector-staging@${digest}"

    run ext_consumed_source_ref pgvector 0.8.1 18 ghcr.io testowner direct
    [ "$status" -eq 0 ]
    [ "$output" = "ghcr.io/testowner/ext-pgvector:pg18-0.8.1" ]

    run ext_consumed_source_ref postgis 0.8.2 18 ghcr.io testowner direct
    [ "$status" -eq 0 ]
    [ "$output" = "ghcr.io/testowner/ext-postgis:pg18-0.8.2" ]
}

# shellcheck disable=SC2030,SC2031
@test "malformed frozen candidates fail closed without a source reference" {
    local digest short_digest upper_digest invalid
    digest=$(_digest 44)
    short_digest="sha256:$(printf '%063d' 0)"
    upper_digest="sha256:A$(printf '%063d' 0)"
    local -a invalid=(
        "pgvector:18:0.8.2"
        "pgvector:18:0.8.2=ghcr.io/testowner/ext-pgvector@${digest}=extra"
        "pgvector:18:=ghcr.io/testowner/ext-pgvector@${digest}"
        "pgvector:18abc:0.8.2=ghcr.io/testowner/ext-pgvector@${digest}"
        "pgvector:18:0.8.2=ghcr.io/testowner/ext-pgvector"
        "pgvector:18:0.8.2=ghcr.io/testowner/ext-pgvector@${short_digest}"
        "pgvector:18:0.8.2=ghcr.io/testowner/ext-pgvector@${upper_digest}"
        "pgvector:18:0.8.2=ghcr.io/not-testowner/ext-pgvector@${digest}"
        "pgvector:18:0.8.2=registry.example/testowner/ext-pgvector@${digest}"
    )

    for invalid in "${invalid[@]}"; do
        export ROTATION_CANDIDATE_REF="$invalid"
        run --separate-stderr ext_consumed_source_ref pgvector 0.8.2 18 ghcr.io testowner direct
        [ "$status" -eq 2 ]
        [ -z "$output" ]
    done
}

@test "pinned-digest rejects malformed digests rather than emitting a tag" {
    run --separate-stderr ext_consumed_source_ref pgvector 0.8.2 18 ghcr.io testowner pinned-digest "sha256:bad"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

# shellcheck disable=SC2030,SC2031
@test "caller registry and owner reach direct, pinned-digest, and probe modes" {
    export EXTENSION_REGISTRY=environment.example
    export GITHUB_REPOSITORY_OWNER=environment-owner
    get_registry() { printf '%s' "$EXTENSION_REGISTRY"; }
    get_repo_owner() { printf '%s' "$GITHUB_REPOSITORY_OWNER"; }

    run ext_consumed_source_ref pgvector 0.8.2 18 custom.io customowner direct
    [ "$status" -eq 0 ]
    [ "$output" = "custom.io/customowner/ext-pgvector:pg18-0.8.2" ]

    local digest
    digest=$(_digest 59)
    run ext_consumed_source_ref pgvector 0.8.2 18 custom.io customowner pinned-digest "$digest"
    [ "$status" -eq 0 ]
    [ "$output" = "custom.io/customowner/ext-pgvector@${digest}" ]

    # ext_ref_resolve derives its identity internally, so probe proves the
    # gateway's one temporary environment forwarding point.
    _image_registry_probe_3state() { return 0; }
    run ext_consumed_source_ref pgvector 0.8.2 18 custom.io customowner probe
    [ "$status" -eq 0 ]
    [ "$output" = "custom.io/customowner/ext-pgvector:pg18-0.8.2" ]
}

@test "empty registry or owner is refused without a source reference" {
    run --separate-stderr ext_consumed_source_ref pgvector 0.8.2 18 "" customowner direct
    [ "$status" -ne 0 ]
    [ -z "$output" ]

    run --separate-stderr ext_consumed_source_ref pgvector 0.8.2 18 custom.io "" direct
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

# shellcheck disable=SC2030,SC2031
@test "generated direct path stays unprobed and the frozen candidate preserves COPY count" {
    mkdir -p "$TEST_TEMP_DIR/extensions"
    cat > "$TEST_TEMP_DIR/extensions/config.yaml" <<'EOF'
extensions:
  pgvector:
    version: "0.8.2"
    repo: "pgvector/pgvector"
    priority: 1
    initdb:
      mode: create
flavors:
  vector:
    - pgvector
EOF
    cat > "$TEST_TEMP_DIR/Dockerfile.template" <<'EOF'
ARG VERSION
# @@EXTENSION_STAGES@@
FROM postgres:${VERSION}
# @@FLAVOR_ARG@@
# @@EXTENSION_COPIES@@
# @@EXTENSION_INSTALLS@@
# @@BUILTIN_INITDB@@
# @@FLAVOR_INITDB@@
# @@RUNTIME_DEPS@@
EOF
    export ROOT_DIR="$TEST_TEMP_DIR"
    export EXT_CONSUMED_PROBE_LOG="$TEST_TEMP_DIR/probe.log"
    : > "$EXT_CONSUMED_PROBE_LOG"
    # shellcheck disable=SC2317
    _image_registry_probe_3state() { printf '%s\n' "$1" >> "$EXT_CONSUMED_PROBE_LOG"; return 0; }

    run generate_dockerfile "$TEST_TEMP_DIR/extensions/config.yaml" "$TEST_TEMP_DIR/Dockerfile.template" vector 18 ghcr.io testowner
    [ "$status" -eq 0 ]
    local canonical_output="$output"
    [ ! -s "$EXT_CONSUMED_PROBE_LOG" ]
    [[ "$canonical_output" == *"FROM ghcr.io/testowner/ext-pgvector:pg18-0.8.2 AS ext-pgvector"* ]]

    local digest candidate canonical_copy_count candidate_copy_count
    digest=$(_digest 45)
    candidate="pgvector:18:0.8.2=ghcr.io/testowner/ext-pgvector-staging@${digest}"
    export ROTATION_CANDIDATE_REF="$candidate"
    run generate_dockerfile "$TEST_TEMP_DIR/extensions/config.yaml" "$TEST_TEMP_DIR/Dockerfile.template" vector 18 ghcr.io testowner
    [ "$status" -eq 0 ]
    [[ "$output" == *"FROM ghcr.io/testowner/ext-pgvector-staging@${digest} AS ext-pgvector"* ]]
    canonical_copy_count=$(grep -c '^COPY --from=' <<<"$canonical_output" || true)
    candidate_copy_count=$(grep -c '^COPY --from=' <<<"$output" || true)
    [ "$candidate_copy_count" -eq "$canonical_copy_count" ]
}

# shellcheck disable=SC2030,SC2031
@test "generated collector keeps an older retained version canonical beside the frozen candidate" {
    mkdir -p "$TEST_TEMP_DIR/extensions" "$TEST_TEMP_DIR/.build-lineage"
    cat > "$TEST_TEMP_DIR/extensions/config.yaml" <<'EOF'
extensions:
  timescaledb:
    version: "2.27.1"
    repo: "timescale/timescaledb"
    priority: 1
    initdb:
      mode: create
    version_set:
      resolver: "scripts/resolvers/timescaledb-ha.sh"
flavors:
  timeseries:
    - timescaledb
EOF
    cat > "$TEST_TEMP_DIR/Dockerfile.template" <<'EOF'
ARG VERSION
# @@EXTENSION_STAGES@@
FROM postgres:${VERSION}
# @@FLAVOR_ARG@@
# @@EXTENSION_COPIES@@
# @@EXTENSION_INSTALLS@@
# @@BUILTIN_INITDB@@
# @@FLAVOR_INITDB@@
# @@RUNTIME_DEPS@@
EOF
    local older_digest ceiling_digest frozen_digest
    older_digest=$(_digest 51)
    ceiling_digest=$(_digest 52)
    frozen_digest=$(_digest 53)
    cat > "$TEST_TEMP_DIR/.build-lineage/ext-timescaledb-pg18-versionset.json" <<EOF
{"ext":"timescaledb","pg_major":"18","ceiling":"2.27.1","resolved":["2.25.0","2.27.1"],"available":["2.25.0","2.27.1"],"excluded":[],"version_digests":{"2.25.0":"${older_digest}","2.27.1":"${ceiling_digest}"}}
EOF
    export ROOT_DIR="$TEST_TEMP_DIR"

    run generate_dockerfile "$TEST_TEMP_DIR/extensions/config.yaml" "$TEST_TEMP_DIR/Dockerfile.template" timeseries 18 ghcr.io testowner
    [ "$status" -eq 0 ]
    local canonical_output="$output"
    [[ "$canonical_output" == *"COPY --from=ghcr.io/testowner/ext-timescaledb@${older_digest} /output/ /2.25.0/"* ]]
    [[ "$canonical_output" == *"COPY --from=ghcr.io/testowner/ext-timescaledb@${ceiling_digest} /output/ /2.27.1/"* ]]

    export ROTATION_CANDIDATE_REF="timescaledb:18:2.27.1=ghcr.io/testowner/ext-timescaledb-staging@${frozen_digest}"
    run generate_dockerfile "$TEST_TEMP_DIR/extensions/config.yaml" "$TEST_TEMP_DIR/Dockerfile.template" timeseries 18 ghcr.io testowner
    [ "$status" -eq 0 ]
    [[ "$output" == *"COPY --from=ghcr.io/testowner/ext-timescaledb@${older_digest} /output/ /2.25.0/"* ]]
    [[ "$output" == *"COPY --from=ghcr.io/testowner/ext-timescaledb-staging@${frozen_digest} /output/ /2.27.1/"* ]]
    [ "$(grep -c '^COPY --from=' <<<"$output" || true)" -eq "$(grep -c '^COPY --from=' <<<"$canonical_output" || true)" ]
}

# shellcheck disable=SC2030,SC2031
@test "generated self-heal collector routes its probe map through the frozen candidate" {
    mkdir -p "$TEST_TEMP_DIR/extensions" "$TEST_TEMP_DIR/.build-lineage"
    cat > "$TEST_TEMP_DIR/extensions/config.yaml" <<'EOF'
extensions:
  timescaledb:
    version: "2.27.1"
    repo: "timescale/timescaledb"
    priority: 1
    initdb:
      mode: create
    version_set:
      resolver: "scripts/resolvers/timescaledb-ha.sh"
flavors:
  timeseries:
    - timescaledb
EOF
    cat > "$TEST_TEMP_DIR/Dockerfile.template" <<'EOF'
ARG VERSION
# @@EXTENSION_STAGES@@
FROM postgres:${VERSION}
# @@FLAVOR_ARG@@
# @@EXTENSION_COPIES@@
# @@EXTENSION_INSTALLS@@
# @@BUILTIN_INITDB@@
# @@FLAVOR_INITDB@@
# @@RUNTIME_DEPS@@
EOF
    export ROOT_DIR="$TEST_TEMP_DIR"
    resolve_version_set() { printf '["2.25.0","2.27.1"]'; }
    # shellcheck disable=SC2317
    _image_registry_probe_3state() { return 0; }
    local frozen_digest
    frozen_digest=$(_digest 54)
    export ROTATION_CANDIDATE_REF="timescaledb:18:2.27.1=ghcr.io/testowner/ext-timescaledb-staging@${frozen_digest}"

    run generate_dockerfile "$TEST_TEMP_DIR/extensions/config.yaml" "$TEST_TEMP_DIR/Dockerfile.template" timeseries 18 ghcr.io testowner
    [ "$status" -eq 0 ]
    [[ "$output" == *"COPY --from=ghcr.io/testowner/ext-timescaledb:pg18-2.25.0 /output/ /2.25.0/"* ]]
    [[ "$output" == *"COPY --from=ghcr.io/testowner/ext-timescaledb-staging@${frozen_digest} /output/ /2.27.1/"* ]]
}

# shellcheck disable=SC2030,SC2031
@test "generated tag-only collector and both single-version modes honor the frozen candidate" {
    mkdir -p "$TEST_TEMP_DIR/extensions" "$TEST_TEMP_DIR/.build-lineage"
    cat > "$TEST_TEMP_DIR/extensions/config.yaml" <<'EOF'
extensions:
  timescaledb:
    version: "2.27.1"
    repo: "timescale/timescaledb"
    priority: 1
    initdb:
      mode: create
    version_set:
      resolver: "scripts/resolvers/timescaledb-ha.sh"
  pgvector:
    version: "0.8.2"
    repo: "pgvector/pgvector"
    priority: 2
    initdb:
      mode: create
flavors:
  timeseries:
    - timescaledb
  vector:
    - pgvector
EOF
    cat > "$TEST_TEMP_DIR/Dockerfile.template" <<'EOF'
ARG VERSION
# @@EXTENSION_STAGES@@
FROM postgres:${VERSION}
# @@FLAVOR_ARG@@
# @@EXTENSION_COPIES@@
# @@EXTENSION_INSTALLS@@
# @@BUILTIN_INITDB@@
# @@FLAVOR_INITDB@@
# @@RUNTIME_DEPS@@
EOF
    cat > "$TEST_TEMP_DIR/.build-lineage/ext-timescaledb-pg18-versionset.json" <<'EOF'
{"ext":"timescaledb","pg_major":"18","ceiling":"2.27.1","resolved":["2.25.0","2.27.1"],"available":["2.25.0","2.27.1"],"excluded":[]}
EOF
    export ROOT_DIR="$TEST_TEMP_DIR"
    local tag_digest pinned_digest probe_digest
    tag_digest=$(_digest 55)
    pinned_digest=$(_digest 56)
    probe_digest=$(_digest 57)

    export ROTATION_CANDIDATE_REF="timescaledb:18:2.27.1=ghcr.io/testowner/ext-timescaledb-staging@${tag_digest}"
    run generate_dockerfile "$TEST_TEMP_DIR/extensions/config.yaml" "$TEST_TEMP_DIR/Dockerfile.template" timeseries 18 ghcr.io testowner
    [ "$status" -eq 0 ]
    [[ "$output" == *"COPY --from=ghcr.io/testowner/ext-timescaledb:pg18-2.25.0 /output/ /2.25.0/"* ]]
    [[ "$output" == *"COPY --from=ghcr.io/testowner/ext-timescaledb-staging@${tag_digest} /output/ /2.27.1/"* ]]

    cat > "$TEST_TEMP_DIR/.build-lineage/ext-timescaledb-pg18-versionset.json" <<EOF
{"ext":"timescaledb","pg_major":"18","ceiling":"2.27.1","resolved":["2.27.1"],"available":["2.27.1"],"excluded":[],"version_digests":{"2.27.1":"$(_digest 58)"}}
EOF
    export ROTATION_CANDIDATE_REF="timescaledb:18:2.27.1=ghcr.io/testowner/ext-timescaledb-staging@${pinned_digest}"
    run generate_dockerfile "$TEST_TEMP_DIR/extensions/config.yaml" "$TEST_TEMP_DIR/Dockerfile.template" timeseries 18 ghcr.io testowner
    [ "$status" -eq 0 ]
    [[ "$output" == *"FROM ghcr.io/testowner/ext-timescaledb-staging@${pinned_digest} AS ext-timescaledb"* ]]

    export PR_TAG_SUFFIX=-pr42
    # shellcheck disable=SC2317
    _image_registry_probe_3state() { return 0; }
    export ROTATION_CANDIDATE_REF="pgvector:18:0.8.2=ghcr.io/testowner/ext-pgvector-staging@${probe_digest}"
    run generate_dockerfile "$TEST_TEMP_DIR/extensions/config.yaml" "$TEST_TEMP_DIR/Dockerfile.template" vector 18 ghcr.io testowner
    [ "$status" -eq 0 ]
    [[ "$output" == *"FROM ghcr.io/testowner/ext-pgvector-staging@${probe_digest} AS ext-pgvector"* ]]
}

@test "generate_dockerfile has no consumed-reference bypass" {
    # This lint catches a newly added bypass; it is not proof that none exists.
    # The sole ext_image_repository allowance compares artifact provenance; it
    # does not emit a consumed reference.
    local body non_provenance_body
    body=$(awk '/^generate_dockerfile\(\) \{/{inside=1} inside {print} /^}$/ && inside {exit}' "$HELPERS_DIR/extension-utils.sh")
    non_provenance_body=$(awk '
        /^[[:space:]]*#/ { next }
        /_expected_digest_repository=\$\(ext_image_repository "\$ext_name" "\$registry" "\$owner"\) \|\| return 1/ { next }
        { print }
    ' <<<"$body")
    if grep -Eq '(^|[^[:alnum:]_])(ext_image_name|ext_image_repository|ext_ref_resolve)[[:space:]]+' <<<"$non_provenance_body"; then
        echo "generate_dockerfile bypasses ext_consumed_source_ref"
        return 1
    fi
    if grep -Eq '"\$\{[^}]+\}@\$\{[^}]+\}"' <<<"$body"; then
        echo "generate_dockerfile assembles a digest reference directly"
        return 1
    fi
}
