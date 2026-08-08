#!/usr/bin/env bats
#
# What these tests can and cannot see.
#
# They read the Dockerfile as TEXT: a literal is present, a literal is absent,
# one line precedes another. That catches a deletion, a reordering, or a swap
# back to the unsigned source — the mutations a maintainer makes by accident.
#
# It does not decide execution. Someone who leaves the expected URLs and the
# verify command in a comment or an unreachable branch, and fetches the source
# some other way, satisfies every assertion here. No reading of Dockerfile text
# can decide that; only building the image and inspecting what it did could, and
# these tests deliberately build nothing.
#
# So the actor they stop is a careless edit, not a determined one. The e2e and
# the build are what exercise the verification for real.

load "../test_helper"

setup() {
    export DOCKERFILE="$PROJECT_ROOT/openvpn/Dockerfile"
    export CONFIG="$PROJECT_ROOT/openvpn/config.yaml"
}

@test "the vendored key is the one config.yaml pins, read from the file itself" {
    # The fingerprint assertions elsewhere compare the YAML to a constant
    # repeated in this file, so both could be edited together while the vendored
    # key became something else. This reads the key.
    local from_key from_config
    from_key="$(gpg --show-keys --with-colons "$PROJECT_ROOT/openvpn/openvpn-signing-key.asc" 2>/dev/null \
                | awk -F: '/^fpr:/{print $10; exit}')"
    from_config="$(yq -r '.build_args.OPENVPN_KEY_FPR' "$CONFIG")"

    [ -n "$from_key" ]
    [ "$from_key" = "$from_config" ]

    # And exactly one primary, which is what the Dockerfile's count asserts.
    [ "$(gpg --show-keys --with-colons "$PROJECT_ROOT/openvpn/openvpn-signing-key.asc" 2>/dev/null \
         | grep -c '^pub:')" -eq 1 ]
}

@test "replacing the OpenVPN release asset with the unsigned codeload snapshot is rejected" {
    grep -Fq 'https://github.com/OpenVPN/openvpn/releases/download/v${RELEASE_VERSION}/openvpn-${RELEASE_VERSION}.tar.gz' "$DOCKERFILE"
    grep -Fq 'https://github.com/OpenVPN/openvpn/releases/download/v${RELEASE_VERSION}/openvpn-${RELEASE_VERSION}.tar.gz.asc' "$DOCKERFILE"
    # grep, not ripgrep: rg is absent on the runner, and a test that shells out
    # to it fails there while passing locally. That cost a CI round in #1092.
    #
    # Counted rather than `! grep`, for the same reason as in the next test: a
    # non-final `! cmd` is inert under bats, and this one is only load-bearing
    # today because it happens to be last.
    [ "$(grep -ci 'github\.com/openvpn/openvpn/archive/' "$DOCKERFILE" || true)" -eq 0 ]
    # codeload.github.com serves the same unsigned snapshot under a different
    # host, so rejecting only the github.com spelling leaves the swap available.
    [ "$(grep -ci 'codeload\.github\.com' "$DOCKERFILE" || true)" -eq 0 ]
}

@test "the release asset URL uses the version with its leading v stripped" {
    # The two archive forms disagree about the v and the move between them
    # inverts the rule: the codeload path wants the tag (`archive/v2.7.6.tar.gz`,
    # HTTP 200 — `archive/2.7.6.tar.gz` is 404), while the release assets want it
    # gone (`download/v2.7.6/openvpn-2.7.6.tar.gz`). `version.sh --upstream`
    # returns the tag form, measured, so the Dockerfile must strip it.
    #
    # The mutation this catches is reusing DOWNLOAD_VERSION for the asset name or
    # the extracted directory, which requests `openvpn-v2.7.6.tar.gz` and 404s
    # every build.
    grep -Fq 'RELEASE_VERSION="${DOWNLOAD_VERSION#v}"' "$DOCKERFILE"

    # And UPSTREAM_VERSION is required rather than falling back to VERSION.
    # VERSION carries the base suffix (`v2.7.6-alpine`), which is not a release
    # ref under either the codeload or the release-asset spelling — both 404.
    # The mutation this catches is restoring `${UPSTREAM_VERSION:-$VERSION}`,
    # which trades a clear failure at the top of the build for a 404 partway in.
    [ "$(grep -cF 'DOWNLOAD_VERSION="${UPSTREAM_VERSION:-$VERSION}"' "$DOCKERFILE" || true)" -eq 0 ]
    grep -Fq 'DOWNLOAD_VERSION="${UPSTREAM_VERSION:?' "$DOCKERFILE"

    # No release-asset path, and no assertion about the extracted directory, may
    # name the unstripped variable.
    #
    # Counted rather than `! grep`: measured inside bats, a NON-FINAL `! cmd` is
    # inert — bats suppresses errexit for a negated command, so the test reports
    # ok however the grep goes. Only the last line of a body would carry it, and
    # a form that stops asserting when someone appends a line is not an assertion.
    [ "$(grep -cE 'releases/download/.*\$\{DOWNLOAD_VERSION\}' "$DOCKERFILE" || true)" -eq 0 ]
    [ "$(grep -cF 'openvpn-${DOWNLOAD_VERSION}' "$DOCKERFILE" || true)" -eq 0 ]
}

@test "moving OpenVPN signature verification after source extraction or configuration is rejected" {
    local verify_line extract_line configure_line make_line
    verify_line="$(nl -ba "$DOCKERFILE" | awk 'index($0, "--verify openvpn.tgz.asc openvpn.tgz") {print $1; exit}')"
    extract_line="$(nl -ba "$DOCKERFILE" | awk 'index($0, "tar zxvf openvpn.tgz") {print $1; exit}')"
    configure_line="$(nl -ba "$DOCKERFILE" | awk 'index($0, "./configure --disable-lzo") {print $1; exit}')"
    make_line="$(nl -ba "$DOCKERFILE" | awk 'index($0, "make -j${NPROC}") {print $1; exit}')"

    [ -n "$verify_line" ]
    [ -n "$extract_line" ]
    [ -n "$configure_line" ]
    [ -n "$make_line" ]
    [ "$verify_line" -lt "$extract_line" ]
    [ "$verify_line" -lt "$configure_line" ]
    [ "$verify_line" -lt "$make_line" ]
}

@test "removing the exactly-one-primary-key assertion or OpenVPN primary fingerprint pin is rejected" {
    local key_count_line fingerprint_line verify_line expected_fpr="F554A3687412CFFEBDEFE0A312F5F7B42F2B01E7"
    key_count_line="$(nl -ba "$DOCKERFILE" | awk 'index($0, "grep -c") && index($0, "^pub:") {print $1; exit}')"
    fingerprint_line="$(nl -ba "$DOCKERFILE" | awk 'index($0, "${OPENVPN_KEY_FPR}") {print $1; exit}')"
    verify_line="$(nl -ba "$DOCKERFILE" | awk 'index($0, "--verify openvpn.tgz.asc openvpn.tgz") {print $1; exit}')"

    grep -Fq 'COPY openvpn-signing-key.asc /usr/local/share/openvpn/openvpn-signing-key.asc' "$DOCKERFILE"
    [ -n "$key_count_line" ]
    [ -n "$fingerprint_line" ]
    [ "$key_count_line" -lt "$fingerprint_line" ]
    [ "$fingerprint_line" -lt "$verify_line" ]
    [ "$(yq -r '.build_args.OPENVPN_KEY_FPR' "$CONFIG")" = "$expected_fpr" ]
    [ "$(yq -r '.dependency_sources.UPSTREAM_VERSION.gpg_key.fingerprint_arg' "$CONFIG")" = "OPENVPN_KEY_FPR" ]
    [ "$(yq -r '.dependency_sources.UPSTREAM_VERSION.gpg_key.signature_suffix' "$CONFIG")" = ".asc" ]
}

@test "the verification decides on gpg's status, not its exit code" {
    # `gpg --verify` exits 0 for a signature made by a revoked or an expired key
    # — measured, v2.7.4 returns 0 with "Note: This key has expired!" — and the
    # exactly-one-primary assertion bounds primaries, not the ten signing subkeys
    # under this one. Deleting these two greps leaves the verification looking
    # present while a revoked key's signature is accepted, and every other test
    # in this file stays green.
    grep -Fq -- '--status-fd 3 --verify openvpn.tgz.asc openvpn.tgz' "$DOCKERFILE"

    # The allowlist and the denylist are both load-bearing: without the first,
    # an absent signature passes; without the second, a revoked one does.
    grep -q "GOODSIG|EXPKEYSIG" "$DOCKERFILE"
    grep -q "REVKEYSIG|BADSIG|ERRSIG|NO_PUBKEY" "$DOCKERFILE"

    # And the status must be consulted before the archive is extracted.
    local status_line extract_line
    # Anchor on the check, not on the comment above it that names the same
    # statuses — the first REVKEYSIG in this file is prose.
    status_line="$(nl -ba "$DOCKERFILE" | awk 'index($0, "REVKEYSIG|BADSIG|ERRSIG|NO_PUBKEY") {print $1; exit}')"
    extract_line="$(nl -ba "$DOCKERFILE" | awk 'index($0, "tar zxvf openvpn.tgz") {print $1; exit}')"
    [ -n "$status_line" ]
    [ -n "$extract_line" ]
    [ "$status_line" -lt "$extract_line" ]
}

@test "the archive preflight lets tar's own status decide" {
    # `tar tzf … | head -1` reports success on a truncated archive whose first
    # member is right, because head exits 0 having read its line. Both preflights
    # list to a file so tar's status is the one that counts.
    [ "$(grep -cE 'tar tzf [^|]*\| *head' "$DOCKERFILE" || true)" -eq 0 ]
    grep -Fq 'tar tzf openvpn.tgz > /tmp/ovpn-members.txt' "$DOCKERFILE"
}

@test "removing the signed archive's versioned top-level-directory replay check is rejected" {
    grep -Fq 'tar tzf openvpn.tgz' "$DOCKERFILE"
    grep -Fq '= "openvpn-${RELEASE_VERSION}/"' "$DOCKERFILE"
}

@test "moving the ovpn checksum after chmod or dropping its configured digest is rejected" {
    local checksum_line chmod_line
    checksum_line="$(nl -ba "$DOCKERFILE" | awk '/sha256sum -c -/ {print $1; exit}')"
    chmod_line="$(nl -ba "$DOCKERFILE" | awk 'index($0, "chmod +x ovpn") {print $1; exit}')"

    [ -n "$checksum_line" ]
    [ -n "$chmod_line" ]
    [ "$checksum_line" -lt "$chmod_line" ]
    grep -Fq '"${OVPN_SHA256}" ovpn | sha256sum -c -' "$DOCKERFILE"
    [ "$(yq -r '.build_args.OVPN_SHA256' "$CONFIG")" = "a1cfb43755aeb0e56d06cdb60be6e6bbf831468414ccbea8cb860729bd8ed451" ]
}

@test "removing OpenVPN verification args from the required build-arg assertion is rejected" {
    grep -Fq 'ARG OPENVPN_KEY_FPR' "$DOCKERFILE"
    grep -Fq 'ARG OVPN_SHA256' "$DOCKERFILE"
    grep -Fq '"${OPENVPN_KEY_FPR:?required}"' "$DOCKERFILE"
    grep -Fq '"${OVPN_SHA256:?required}"' "$DOCKERFILE"
}
