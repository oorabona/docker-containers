#!/usr/bin/env bats

load "../test_helper"

@test "openvpn EasyRSA pinned fingerprint matches vendored primary key fingerprint" {
    local pinned_fpr actual_fpr
    pinned_fpr="$(yq -r '.build_args.EASYRSA_KEY_FPR' "$PROJECT_ROOT/openvpn/config.yaml")"

    actual_fpr="$(gpg --batch --show-keys --with-colons "$PROJECT_ROOT/openvpn/easyrsa-signing-key.asc" 2>/dev/null \
        | awk -F: '$1 == "fpr" {print $10; exit}')"

    [ "$pinned_fpr" = "$actual_fpr" ]
}

@test "check-dependency-versions openvpn passes the INV-05 build_arg preflight (exit 0)" {
    # INV-05 (every build_arg has a dependency_sources entry) is enforced in a
    # preflight that exits non-zero BEFORE any network version resolution, so a
    # zero exit is a network-independent lock: EASYRSA_KEY_FPR must have its
    # untracked dependency_sources entry. (Version-resolution/network errors are
    # fail-soft and deliberately do not fail this preflight lock.)
    run "$PROJECT_ROOT/scripts/check-dependency-versions.sh" openvpn --json
    [ "$status" -eq 0 ]
}
