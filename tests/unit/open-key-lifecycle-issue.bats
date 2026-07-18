#!/usr/bin/env bats

load "../test_helper"

setup() {
    setup_temp_dir
    export SCRIPT="$SCRIPTS_DIR/open-key-lifecycle-issue.sh"
    export GH_TOKEN="fake-token"
    export GITHUB_REPOSITORY="oorabona/docker-containers"
    export ORIG_PATH="$PATH"
    mkdir -p "$TEST_TEMP_DIR/bin"
    write_fake_gh
    cat > "$TEST_TEMP_DIR/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/sleep"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
}

teardown() {
    export PATH="$ORIG_PATH"
    teardown_temp_dir
    unset FAKE_ISSUE_LIST_MODE FAKE_ISSUE_CREATE_MODE FAKE_ISSUE_EDIT_MODE REQUIRE_LABEL_FORCE FAKE_LABEL_CREATE_MODE GH_CREATE_COUNT_FILE GH_SERVER_CREATED_FILE GH_LABEL_COUNT_FILE
}

write_fake_gh() {
cat > "$TEST_TEMP_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s ' "$@" >> "${GH_LOG:?}"
printf '\n' >> "$GH_LOG"

if [[ "${1:-}" == "issue" && "${2:-}" == "list" ]]; then
  case "${FAKE_ISSUE_LIST_MODE:-none}" in
    exact)
      printf '[{"number":77,"title":"[GPG key lifecycle] openvpn/EASYRSA_VERSION: signing key expiring"}]\n'
      ;;
    exact_after_create_error)
      if [[ -f "${GH_SERVER_CREATED_FILE:-${GH_LOG}.server_created}" ]]; then
        printf '[{"number":77,"title":"[GPG key lifecycle] openvpn/EASYRSA_VERSION: signing key expiring"}]\n'
      else
        printf '[]\n'
      fi
      ;;
    contract_exact)
      printf '[{"number":78,"title":"[GPG key lifecycle] openvpn/EASYRSA_VERSION: vendored key file problem (build-breaking)"}]\n'
      ;;
    different)
      printf '[{"number":66,"title":"[GPG key lifecycle] openvpn/EASYRSA_VERSION: release signature no longer verifies (rotation?)"}]\n'
      ;;
    unordered_exact)
      printf '[{"number":61,"title":"[GPG key lifecycle] openvpn/OTHER_GPG_VERSION: signing key expiring"},{"number":77,"title":"[GPG key lifecycle] openvpn/EASYRSA_VERSION: signing key expiring"},{"number":63,"title":"[GPG key lifecycle] openvpn/THIRD_GPG_VERSION: monitor configuration problem"}]\n'
      ;;
    unrelated_set)
      printf '[{"number":61,"title":"[GPG key lifecycle] openvpn/OTHER_GPG_VERSION: signing key expiring"},{"number":62,"title":"[GPG key lifecycle] openvpn/THIRD_GPG_VERSION: release signature no longer verifies (rotation?)"}]\n'
      ;;
    degraded_exact)
      printf '[{"number":65,"title":"[GPG key lifecycle] openvpn/EASYRSA_VERSION: signing-key monitor degraded (cannot verify latest release)"}]\n'
      ;;
    config_exact)
      printf '[{"number":64,"title":"[GPG key lifecycle] openvpn/EASYRSA_VERSION: monitor configuration problem"}]\n'
      ;;
    *)
      printf '[]\n'
      ;;
  esac
  exit 0
fi
if [[ "${1:-}" == "issue" && "${2:-}" == "create" ]]; then
  title=""
  prev=""
  for arg in "$@"; do
    if [[ "$prev" == "--title" ]]; then
      title="$arg"
      break
    fi
    prev="$arg"
  done
  count_file="${GH_CREATE_COUNT_FILE:-${GH_LOG}.create_count}"
  count=0
  if [[ -f "$count_file" ]]; then
    count="$(< "$count_file")"
  fi
  count=$((count + 1))
  printf '%s\n' "$count" > "$count_file"
  if [[ "${FAKE_ISSUE_CREATE_MODE:-ok}" == "fail_until_labels_created" ]]; then
    label_count=0
    label_count_file="${GH_LABEL_COUNT_FILE:-${GH_LOG}.label_count}"
    if [[ -f "$label_count_file" ]]; then
      label_count="$(< "$label_count_file")"
    fi
    if [[ "$label_count" -le 9 ]]; then
      printf 'create failed because labels are missing\n' >&2
      exit 1
    fi
  fi
  if [[ "${FAKE_ISSUE_CREATE_MODE:-ok}" == "fail_after_server_create" && "$count" -eq 1 ]]; then
    : > "${GH_SERVER_CREATED_FILE:-${GH_LOG}.server_created}"
    printf 'create failed after server-side success\n' >&2
    exit 1
  fi
  if [[ "${FAKE_ISSUE_CREATE_MODE:-ok}" == "fail_first" && "$count" -eq 1 ]]; then
    printf 'create failed once\n' >&2
    exit 1
  fi
  if [[ "${FAKE_ISSUE_CREATE_MODE:-ok}" == "fail_for_first_title" && "$title" == *"FIRST_GPG_VERSION"* ]]; then
    printf 'create failed for first title\n' >&2
    exit 1
  fi
  if [[ "${FAKE_ISSUE_CREATE_MODE:-ok}" == "fail" ]]; then
    printf 'create failed\n' >&2
    exit 1
  fi
  if [[ "${FAKE_ISSUE_CREATE_MODE:-ok}" == "unparseable" ]]; then
    printf 'created successfully but no URL\n'
    exit 0
  fi
  printf 'https://github.com/oorabona/docker-containers/issues/88\n'
  exit 0
fi
if [[ "${1:-}" == "issue" && "${2:-}" == "edit" ]]; then
  if [[ "${FAKE_ISSUE_EDIT_MODE:-ok}" == "fail" ]]; then
    printf 'edit failed\n' >&2
    exit 1
  fi
  printf 'https://github.com/oorabona/docker-containers/issues/%s\n' "${3:-0}"
  exit 0
fi
if [[ "${1:-}" == "issue" && "${2:-}" == "comment" ]]; then
  exit 0
fi
if [[ "${1:-}" == "label" && "${2:-}" == "create" ]]; then
  count_file="${GH_LABEL_COUNT_FILE:-${GH_LOG}.label_count}"
  count=0
  if [[ -f "$count_file" ]]; then
    count="$(< "$count_file")"
  fi
  count=$((count + 1))
  printf '%s\n' "$count" > "$count_file"
  if [[ "${FAKE_LABEL_CREATE_MODE:-ok}" == "fail_first_ensure" && "$count" -le 9 ]]; then
    printf 'transient label creation failure\n' >&2
    exit 1
  fi
  if [[ "${REQUIRE_LABEL_FORCE:-false}" == "true" ]]; then
    for arg in "$@"; do
      [[ "$arg" == "--force" ]] && exit 0
    done
    printf 'label already exists\n' >&2
    exit 1
  fi
  exit 0
fi
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/gh"
    export GH_LOG="$TEST_TEMP_DIR/gh.log"
}

assert_log_lacks() {
    local unexpected="$1"
    if grep -qF "$unexpected" "$GH_LOG"; then
        echo "unexpected: $unexpected"
        return 1
    fi
}

write_json() {
    local file="$1"
    local expiry_status="${2:-ok}"
    local expiry_severity="${3:-none}"
    cat > "$file" <<EOF
[
  {
    "container": "openvpn",
    "dependency": "EASYRSA_VERSION",
    "key_file": "openvpn/easyrsa-signing-key.asc",
    "expiry": {
      "status": "${expiry_status}",
      "reason": "${expiry_status}",
      "severity": "${expiry_severity}",
      "days_left": 10,
      "expires": "2030-01-01",
      "fpr": "FAKEFPR"
    },
    "rotation": {
      "status": "ok",
      "rotation": false,
      "reason": "verified",
      "severity": "none",
      "latest": "3.2.7"
    },
    "contract": {
      "status": "ok",
      "reason": "valid",
      "severity": "none",
      "primary_fpr": "FAKEFPR",
      "primary_keyid": "FAKEKEYID",
      "primary_count": 1,
      "primary_validity": "-",
      "pinned_fpr": "FAKEFPR"
    },
    "errors": []
  }
]
EOF
}

write_rotation_json() {
    local file="$1"
    cat > "$file" <<'EOF'
[
  {
    "container": "openvpn",
    "dependency": "EASYRSA_VERSION",
    "key_file": "openvpn/easyrsa-signing-key.asc",
    "expiry": {
      "status": "ok",
      "reason": "valid",
      "severity": "none",
      "days_left": 120,
      "expires": "2030-01-01",
      "fpr": "FAKEFPR"
    },
    "rotation": {
      "status": "rotation",
      "rotation": true,
      "reason": "no-valid-signature",
      "severity": "high",
      "latest": "3.2.7"
    },
    "contract": {
      "status": "ok",
      "reason": "valid",
      "severity": "none",
      "primary_fpr": "FAKEFPR",
      "primary_keyid": "FAKEKEYID",
      "primary_count": 1,
      "primary_validity": "-",
      "pinned_fpr": "FAKEFPR"
    },
    "errors": []
  }
]
EOF
}

write_degraded_json() {
    local file="$1"
    cat > "$file" <<'EOF'
[
  {
    "container": "openvpn",
    "dependency": "EASYRSA_VERSION",
    "key_file": "openvpn/easyrsa-signing-key.asc",
    "expiry": {
      "status": "ok",
      "reason": "valid",
      "severity": "none",
      "days_left": 120,
      "expires": "2030-01-01",
      "fpr": "FAKEFPR"
    },
    "rotation": {
      "status": "error",
      "rotation": false,
      "reason": "rotation-check-unavailable",
      "severity": "warn",
      "latest": "3.2.7"
    },
    "contract": {
      "status": "ok",
      "reason": "valid",
      "severity": "none",
      "primary_fpr": "FAKEFPR",
      "primary_keyid": "FAKEKEYID",
      "primary_count": 1,
      "primary_validity": "-",
      "pinned_fpr": "FAKEFPR"
    },
    "errors": ["EASYRSA_VERSION: failed to fetch release artifact/signature for 3.2.7"]
  }
]
EOF
}

write_rotation_config_json() {
    local file="$1"
    cat > "$file" <<'EOF'
[
  {
    "container": "openvpn",
    "dependency": "EASYRSA_VERSION",
    "key_file": "openvpn/easyrsa-signing-key.asc",
    "expiry": {
      "status": "ok",
      "reason": "valid",
      "severity": "none",
      "days_left": 120,
      "expires": "2030-01-01",
      "fpr": "FAKEFPR"
    },
    "rotation": {
      "status": "error",
      "rotation": false,
      "reason": "rotation-config-unsupported",
      "severity": "high",
      "latest": null
    },
    "contract": {
      "status": "ok",
      "reason": "valid",
      "severity": "none",
      "primary_fpr": "FAKEFPR",
      "primary_keyid": "FAKEKEYID",
      "primary_count": 1,
      "primary_validity": "-",
      "pinned_fpr": "FAKEFPR"
    },
    "errors": ["EASYRSA_VERSION: rotation check requires dependency_sources.EASYRSA_VERSION.type=github-release and repo"]
  }
]
EOF
}

write_contract_degraded_json() {
    local file="$1"
    cat > "$file" <<'EOF'
[
  {
    "container": "openvpn",
    "dependency": "EASYRSA_VERSION",
    "key_file": "openvpn/easyrsa-signing-key.asc",
    "expiry": {
      "status": "ok",
      "reason": "valid",
      "severity": "none",
      "days_left": 120,
      "expires": "2030-01-01",
      "fpr": "FAKEFPR"
    },
    "rotation": {
      "status": "error",
      "rotation": false,
      "reason": "rotation-check-unavailable",
      "severity": "warn",
      "latest": "3.2.7"
    },
    "contract": {
      "status": "error",
      "reason": "key-contract-mismatch",
      "severity": "high",
      "primary_fpr": "DIFFERENTFPR",
      "primary_keyid": "FAKEKEYID",
      "primary_count": 1,
      "primary_validity": "-",
      "pinned_fpr": "FAKEFPR"
    },
    "errors": ["EASYRSA_VERSION: failed to fetch release artifact/signature for 3.2.7"]
  }
]
EOF
}

write_contract_json() {
    local file="$1"
    cat > "$file" <<'EOF'
[
  {
    "container": "openvpn",
    "dependency": "EASYRSA_VERSION",
    "key_file": "openvpn/easyrsa-signing-key.asc",
    "expiry": {
      "status": "ok",
      "reason": "valid",
      "severity": "none",
      "days_left": 120,
      "expires": "2030-01-01",
      "fpr": "FAKEFPR"
    },
    "rotation": {
      "status": "ok",
      "rotation": false,
      "reason": "verified",
      "severity": "none",
      "latest": "3.2.7"
    },
    "contract": {
      "status": "error",
      "reason": "key-contract-mismatch",
      "severity": "high",
      "primary_fpr": "DIFFERENTFPR",
      "primary_keyid": "FAKEKEYID",
      "primary_count": 1,
      "primary_validity": "-",
      "pinned_fpr": "FAKEFPR"
    },
    "errors": []
  }
]
EOF
}

write_invalid_warn_rotation_json() {
    local file="$1"
    cat > "$file" <<'EOF'
[
  {
    "container": "openvpn",
    "dependency": "EASYRSA_VERSION",
    "key_file": "openvpn/easyrsa-signing-key.asc",
    "expiry": {
      "status": "ok",
      "reason": "valid",
      "severity": "none",
      "days_left": 120,
      "expires": "2030-01-01",
      "fpr": "FAKEFPR"
    },
    "rotation": {
      "status": "rotation",
      "rotation": true,
      "reason": "no-valid-signature",
      "severity": "high",
      "latest": "3.2.7"
    },
    "contract": {
      "status": "ok",
      "reason": "valid",
      "severity": "none",
      "primary_fpr": "FAKEFPR",
      "primary_keyid": "FAKEKEYID",
      "primary_count": 1,
      "primary_validity": "-",
      "pinned_fpr": "FAKEFPR"
    },
    "config": [
      {
        "reason": "invalid-warn-days",
        "severity": "warn",
        "value": "sixty",
        "message": "EASYRSA_VERSION: invalid gpg_key.expiry_warn_days: sixty"
      }
    ],
    "errors": ["EASYRSA_VERSION: invalid gpg_key.expiry_warn_days: sixty"]
  }
]
EOF
}

write_config_expiry_json() {
    local file="$1"
    cat > "$file" <<'EOF'
[
  {
    "container": "openvpn",
    "dependency": "EASYRSA_VERSION",
    "key_file": "openvpn/easyrsa-signing-key.asc",
    "expiry": {
      "status": "expiring",
      "reason": "expiring",
      "severity": "warn",
      "days_left": 10,
      "expires": "2030-01-01",
      "fpr": "FAKEFPR"
    },
    "rotation": {
      "status": "ok",
      "rotation": false,
      "reason": "verified",
      "severity": "none",
      "latest": "3.2.7"
    },
    "contract": {
      "status": "ok",
      "reason": "valid",
      "severity": "none",
      "primary_fpr": "FAKEFPR",
      "primary_keyid": "FAKEKEYID",
      "primary_count": 1,
      "primary_validity": "-",
      "pinned_fpr": "FAKEFPR"
    },
    "config": [
      {
        "reason": "invalid-warn-days",
        "severity": "warn",
        "value": "sixty",
        "message": "EASYRSA_VERSION: invalid gpg_key.expiry_warn_days: sixty"
      }
    ],
    "errors": ["EASYRSA_VERSION: invalid gpg_key.expiry_warn_days: sixty"]
  }
]
EOF
}

write_contract_config_expiry_rotation_json() {
    local file="$1"
    cat > "$file" <<'EOF'
[
  {
    "container": "openvpn",
    "dependency": "EASYRSA_VERSION",
    "key_file": "openvpn/easyrsa-signing-key.asc",
    "expiry": {
      "status": "expiring",
      "reason": "expiring",
      "severity": "warn",
      "days_left": 10,
      "expires": "2030-01-01",
      "fpr": "FAKEFPR"
    },
    "rotation": {
      "status": "rotation",
      "rotation": true,
      "reason": "no-valid-signature",
      "severity": "high",
      "latest": "3.2.7"
    },
    "contract": {
      "status": "error",
      "reason": "key-contract-mismatch",
      "severity": "high",
      "primary_fpr": "DIFFERENTFPR",
      "primary_keyid": "FAKEKEYID",
      "primary_count": 1,
      "primary_validity": "-",
      "pinned_fpr": "FAKEFPR"
    },
    "config": [
      {
        "reason": "invalid-warn-days",
        "severity": "warn",
        "value": "sixty",
        "message": "EASYRSA_VERSION: invalid gpg_key.expiry_warn_days: sixty"
      }
    ],
    "errors": ["EASYRSA_VERSION: invalid gpg_key.expiry_warn_days: sixty"]
  }
]
EOF
}

write_config_parse_json() {
    local file="$1"
    cat > "$file" <<'EOF'
[
  {
    "container": "openvpn",
    "dependency": null,
    "key_file": null,
    "expiry": {
      "status": "error",
      "reason": "config-parse-error",
      "severity": "high",
      "days_left": null,
      "expires": null,
      "fpr": null
    },
    "rotation": {
      "status": "error",
      "rotation": false,
      "reason": "rotation-check-unavailable",
      "severity": "warn",
      "latest": null
    },
    "contract": {
      "status": "error",
      "reason": "config-parse-error",
      "severity": "high",
      "primary_fpr": null,
      "primary_keyid": null,
      "primary_count": null,
      "primary_validity": null,
      "pinned_fpr": null
    },
    "errors": ["openvpn: failed to parse openvpn/config.yaml"]
  }
]
EOF
}

write_missing_pinned_fingerprint_json() {
    local file="$1"
    cat > "$file" <<'EOF'
[
  {
    "container": "openvpn",
    "dependency": "EASYRSA_VERSION",
    "key_file": "openvpn/easyrsa-signing-key.asc",
    "expiry": {
      "status": "error",
      "reason": "missing-pinned-fingerprint",
      "severity": "high",
      "days_left": null,
      "expires": null,
      "fpr": null
    },
    "rotation": {
      "status": "error",
      "rotation": false,
      "reason": "rotation-check-unavailable",
      "severity": "warn",
      "latest": null
    },
    "contract": {
      "status": "error",
      "reason": "missing-pinned-fingerprint",
      "severity": "high",
      "primary_fpr": null,
      "primary_keyid": null,
      "primary_count": null,
      "primary_validity": null,
      "pinned_fpr": null
    },
    "errors": ["EASYRSA_VERSION: missing pinned gpg_key fingerprint build_arg"]
  }
]
EOF
}

write_key_file_missing_json() {
    local file="$1"
    cat > "$file" <<'EOF'
[
  {
    "container": "openvpn",
    "dependency": "EASYRSA_VERSION",
    "key_file": "openvpn/missing-signing-key.asc",
    "expiry": {
      "status": "error",
      "reason": "key-file-missing",
      "severity": "high",
      "days_left": null,
      "expires": null,
      "fpr": null
    },
    "rotation": {
      "status": "error",
      "rotation": false,
      "reason": "rotation-check-unavailable",
      "severity": "warn",
      "latest": null
    },
    "contract": {
      "status": "error",
      "reason": "key-file-missing",
      "severity": "high",
      "primary_fpr": null,
      "primary_keyid": null,
      "primary_count": null,
      "primary_validity": null,
      "pinned_fpr": "FAKEFPR"
    },
    "config": [
      {
        "reason": "key-file-missing",
        "severity": "high",
        "message": "EASYRSA_VERSION: key file missing: openvpn/missing-signing-key.asc"
      }
    ],
    "errors": ["EASYRSA_VERSION: key file missing: openvpn/missing-signing-key.asc"]
  }
]
EOF
}

write_two_dep_expiry_json() {
    local file="$1"
    cat > "$file" <<'EOF'
[
  {
    "container": "openvpn",
    "dependency": "EASYRSA_VERSION",
    "key_file": "openvpn/easyrsa-signing-key.asc",
    "expiry": {
      "status": "expiring",
      "reason": "expiring",
      "severity": "warn",
      "days_left": 10,
      "expires": "2030-01-01",
      "fpr": "FAKEFPR"
    },
    "rotation": {
      "status": "ok",
      "rotation": false,
      "reason": "verified",
      "severity": "none",
      "latest": "3.2.7"
    },
    "contract": {
      "status": "ok",
      "reason": "valid",
      "severity": "none",
      "primary_fpr": "FAKEFPR",
      "primary_keyid": "FAKEKEYID",
      "primary_count": 1,
      "primary_validity": "-",
      "pinned_fpr": "FAKEFPR"
    },
    "errors": []
  },
  {
    "container": "openvpn",
    "dependency": "OTHER_GPG_VERSION",
    "key_file": "openvpn/other-signing-key.asc",
    "expiry": {
      "status": "expiring",
      "reason": "expiring",
      "severity": "warn",
      "days_left": 20,
      "expires": "2030-02-01",
      "fpr": "OTHERFPR"
    },
    "rotation": {
      "status": "ok",
      "rotation": false,
      "reason": "verified",
      "severity": "none",
      "latest": "1.2.3"
    },
    "contract": {
      "status": "ok",
      "reason": "valid",
      "severity": "none",
      "primary_fpr": "OTHERFPR",
      "primary_keyid": "OTHERKEYID",
      "primary_count": 1,
      "primary_validity": "-",
      "pinned_fpr": "OTHERFPR"
    },
    "errors": []
  }
]
EOF
}

write_three_expiry_json() {
    local file="$1"
    cat > "$file" <<'EOF'
[
  {
    "container": "openvpn",
    "dependency": "FIRST_GPG_VERSION",
    "key_file": "openvpn/first-signing-key.asc",
    "expiry": {
      "status": "expiring",
      "reason": "expiring",
      "severity": "warn",
      "days_left": 10,
      "expires": "2030-01-01",
      "fpr": "FIRSTFPR"
    },
    "rotation": {
      "status": "ok",
      "rotation": false,
      "reason": "verified",
      "severity": "none",
      "latest": "1.0.0"
    },
    "contract": {
      "status": "ok",
      "reason": "valid",
      "severity": "none",
      "primary_fpr": "FIRSTFPR",
      "primary_keyid": "FIRSTKEYID",
      "primary_count": 1,
      "primary_validity": "-",
      "pinned_fpr": "FIRSTFPR"
    },
    "errors": []
  },
  {
    "container": "openvpn",
    "dependency": "SECOND_GPG_VERSION",
    "key_file": "openvpn/second-signing-key.asc",
    "expiry": {
      "status": "expiring",
      "reason": "expiring",
      "severity": "warn",
      "days_left": 20,
      "expires": "2030-02-01",
      "fpr": "SECONDFPR"
    },
    "rotation": {
      "status": "ok",
      "rotation": false,
      "reason": "verified",
      "severity": "none",
      "latest": "2.0.0"
    },
    "contract": {
      "status": "ok",
      "reason": "valid",
      "severity": "none",
      "primary_fpr": "SECONDFPR",
      "primary_keyid": "SECONDKEYID",
      "primary_count": 1,
      "primary_validity": "-",
      "pinned_fpr": "SECONDFPR"
    },
    "errors": []
  },
  {
    "container": "openvpn",
    "dependency": "THIRD_GPG_VERSION",
    "key_file": "openvpn/third-signing-key.asc",
    "expiry": {
      "status": "expiring",
      "reason": "expiring",
      "severity": "warn",
      "days_left": 30,
      "expires": "2030-03-01",
      "fpr": "THIRDFPR"
    },
    "rotation": {
      "status": "ok",
      "rotation": false,
      "reason": "verified",
      "severity": "none",
      "latest": "3.0.0"
    },
    "contract": {
      "status": "ok",
      "reason": "valid",
      "severity": "none",
      "primary_fpr": "THIRDFPR",
      "primary_keyid": "THIRDKEYID",
      "primary_count": 1,
      "primary_validity": "-",
      "pinned_fpr": "THIRDFPR"
    },
    "errors": []
  }
]
EOF
}

@test "no existing issue creates once with stable labels" {
    local json_file="$TEST_TEMP_DIR/findings.json"
    write_json "$json_file" "expiring" "warn"

    run "$SCRIPT" --json-file "$json_file"

    [ "$status" -eq 0 ]
    [ "$(grep -c 'issue create' "$GH_LOG")" -eq 1 ]
    grep -q 'automation,gpg-key-lifecycle,container:openvpn' "$GH_LOG"
    grep -q '\[GPG key lifecycle\] openvpn/EASYRSA_VERSION: signing key expiring' "$GH_LOG"
    grep -q 'Signing key fingerprint' "$GH_LOG"
    grep -q -- '--limit 100' "$GH_LOG"
    assert_log_lacks '--search'
}

@test "same-container dependencies get distinct issue titles" {
    local json_file="$TEST_TEMP_DIR/findings.json"
    write_two_dep_expiry_json "$json_file"

    run "$SCRIPT" --json-file "$json_file"

    [ "$status" -eq 0 ]
    [ "$(grep -c 'issue create' "$GH_LOG")" -eq 2 ]
    grep -q '\[GPG key lifecycle\] openvpn/EASYRSA_VERSION: signing key expiring' "$GH_LOG"
    grep -q '\[GPG key lifecycle\] openvpn/OTHER_GPG_VERSION: signing key expiring' "$GH_LOG"
}

@test "existing open expiry issue refreshes body and is not duplicated" {
    local json_file="$TEST_TEMP_DIR/findings.json"
    write_json "$json_file" "expiring" "warn"
    export FAKE_ISSUE_LIST_MODE=exact

    run "$SCRIPT" --json-file "$json_file"

    [ "$status" -eq 0 ]
    [[ "$output" == *"refreshed #77"* ]]
    grep -q 'issue edit 77' "$GH_LOG"
    grep -q 'Days left' "$GH_LOG"
    [ "$(grep -c 'issue comment' "$GH_LOG")" -eq 0 ]
    [ "$(grep -c 'issue create' "$GH_LOG")" -eq 0 ]
}

@test "label-scoped issue list matches exact title even when returned out of title order" {
    local json_file="$TEST_TEMP_DIR/findings.json"
    write_json "$json_file" "expiring" "warn"
    export FAKE_ISSUE_LIST_MODE=unordered_exact

    run "$SCRIPT" --json-file "$json_file"

    [ "$status" -eq 0 ]
    [[ "$output" == *"refreshed #77"* ]]
    grep -q 'issue edit 77' "$GH_LOG"
    grep -q -- '--limit 100' "$GH_LOG"
    assert_log_lacks '--search'
    [ "$(grep -c 'issue create' "$GH_LOG")" -eq 0 ]
}

@test "different-titled open issue with same labels does not suppress create" {
    local json_file="$TEST_TEMP_DIR/findings.json"
    write_json "$json_file" "expiring" "warn"
    export FAKE_ISSUE_LIST_MODE=different

    run "$SCRIPT" --json-file "$json_file"

    [ "$status" -eq 0 ]
    [ "$(grep -c 'issue create' "$GH_LOG")" -eq 1 ]
    [ "$(grep -c 'issue comment' "$GH_LOG")" -eq 0 ]
}

@test "unrelated label-scoped issue set creates a new exact-title issue" {
    local json_file="$TEST_TEMP_DIR/findings.json"
    write_json "$json_file" "expiring" "warn"
    export FAKE_ISSUE_LIST_MODE=unrelated_set

    run "$SCRIPT" --json-file "$json_file"

    [ "$status" -eq 0 ]
    [ "$(grep -c 'issue create' "$GH_LOG")" -eq 1 ]
    [ "$(grep -c 'issue edit' "$GH_LOG")" -eq 0 ]
    assert_log_lacks '--search'
}

@test "rotation finding keeps rotation title" {
    local json_file="$TEST_TEMP_DIR/findings.json"
    write_rotation_json "$json_file"

    run "$SCRIPT" --json-file "$json_file"

    [ "$status" -eq 0 ]
    grep -q '\[GPG key lifecycle\] openvpn/EASYRSA_VERSION: release signature no longer verifies (rotation?)' "$GH_LOG"
}

@test "contract finding uses higher-priority vendored key file title" {
    local json_file="$TEST_TEMP_DIR/findings.json"
    write_contract_json "$json_file"

    run "$SCRIPT" --json-file "$json_file"

    [ "$status" -eq 0 ]
    [ "$(grep -c 'issue create' "$GH_LOG")" -eq 1 ]
    grep -q '\[GPG key lifecycle\] openvpn/EASYRSA_VERSION: vendored key file problem (build-breaking)' "$GH_LOG"
    assert_log_lacks 'signing key expiring'
}

@test "contract issue body names the finding container build" {
    local json_file="$TEST_TEMP_DIR/findings.json"
    write_contract_json "$json_file"
    jq '.[0].container = "foo" | .[0].key_file = "foo/easyrsa-signing-key.asc"' "$json_file" > "${json_file}.tmp"
    mv "${json_file}.tmp" "$json_file"

    run "$SCRIPT" --json-file "$json_file"

    [ "$status" -eq 0 ]
    grep -q 'before the next foo build' "$GH_LOG"
    assert_log_lacks 'before the next OpenVPN build'
}

@test "existing contract issue refreshes body and is not duplicated" {
    local json_file="$TEST_TEMP_DIR/findings.json"
    write_contract_json "$json_file"
    export FAKE_ISSUE_LIST_MODE=contract_exact

    run "$SCRIPT" --json-file "$json_file"

    [ "$status" -eq 0 ]
    [[ "$output" == *"refreshed #78"* ]]
    grep -q 'issue edit 78' "$GH_LOG"
    grep -q 'Primary fingerprint' "$GH_LOG"
    [ "$(grep -c 'issue comment' "$GH_LOG")" -eq 0 ]
    [ "$(grep -c 'issue create' "$GH_LOG")" -eq 0 ]
}

@test "existing rotation issue refreshes body and is not duplicated" {
    local json_file="$TEST_TEMP_DIR/findings.json"
    write_rotation_json "$json_file"
    export FAKE_ISSUE_LIST_MODE=different

    run "$SCRIPT" --json-file "$json_file"

    [ "$status" -eq 0 ]
    [[ "$output" == *"refreshed #66"* ]]
    grep -q 'issue edit 66' "$GH_LOG"
    grep -q 'Latest release' "$GH_LOG"
    [ "$(grep -c 'issue comment' "$GH_LOG")" -eq 0 ]
    [ "$(grep -c 'issue create' "$GH_LOG")" -eq 0 ]
}

@test "rotation-check-unavailable opens distinct degraded issue when no higher-priority finding exists" {
    local json_file="$TEST_TEMP_DIR/findings.json"
    write_degraded_json "$json_file"

    run "$SCRIPT" --json-file "$json_file"

    [ "$status" -eq 0 ]
    [ "$(grep -c 'issue create' "$GH_LOG")" -eq 1 ]
    grep -q '\[GPG key lifecycle\] openvpn/EASYRSA_VERSION: signing-key monitor degraded (cannot verify latest release)' "$GH_LOG"
    grep -q 'rotation-check-unavailable' "$GH_LOG"
    grep -q 'Once the check succeeds again' "$GH_LOG"
}

@test "rotation-config-unsupported opens config issue, not degraded issue" {
    local json_file="$TEST_TEMP_DIR/findings.json"
    write_rotation_config_json "$json_file"

    run "$SCRIPT" --json-file "$json_file"

    [ "$status" -eq 0 ]
    [ "$(grep -c 'issue create' "$GH_LOG")" -eq 1 ]
    grep -q '\[GPG key lifecycle\] openvpn/EASYRSA_VERSION: monitor configuration problem' "$GH_LOG"
    grep -q 'rotation-config-unsupported' "$GH_LOG"
    assert_log_lacks 'signing-key monitor degraded'
}

@test "existing degraded issue refreshes body and is not duplicated" {
    local json_file="$TEST_TEMP_DIR/findings.json"
    write_degraded_json "$json_file"
    export FAKE_ISSUE_LIST_MODE=degraded_exact

    run "$SCRIPT" --json-file "$json_file"

    [ "$status" -eq 0 ]
    [[ "$output" == *"refreshed #65"* ]]
    grep -q 'issue edit 65' "$GH_LOG"
    grep -q 'GPG signing-key monitor degraded' "$GH_LOG"
    [ "$(grep -c 'issue comment' "$GH_LOG")" -eq 0 ]
    [ "$(grep -c 'issue create' "$GH_LOG")" -eq 0 ]
}

@test "contract finding wins over degraded rotation-check-unavailable" {
    local json_file="$TEST_TEMP_DIR/findings.json"
    write_contract_degraded_json "$json_file"

    run "$SCRIPT" --json-file "$json_file"

    [ "$status" -eq 0 ]
    [ "$(grep -c 'issue create' "$GH_LOG")" -eq 1 ]
    grep -q '\[GPG key lifecycle\] openvpn/EASYRSA_VERSION: vendored key file problem (build-breaking)' "$GH_LOG"
    assert_log_lacks 'signing-key monitor degraded'
}

@test "existing issue refresh fails closed when gh issue edit fails" {
    local json_file="$TEST_TEMP_DIR/findings.json"
    write_json "$json_file" "expiring" "warn"
    export FAKE_ISSUE_LIST_MODE=exact
    export FAKE_ISSUE_EDIT_MODE=fail

    run "$SCRIPT" --json-file "$json_file"

    [ "$status" -ne 0 ]
    grep -q 'issue edit 77' "$GH_LOG"
    [ "$(grep -c 'issue create' "$GH_LOG")" -eq 0 ]
}

@test "issue markdown escapes table cell delimiters backticks and newlines" {
    local json_file="$TEST_TEMP_DIR/findings.json"
    cat > "$json_file" <<'EOF'
[
  {
    "container": "openvpn",
    "dependency": "EASYRSA|VERSION",
    "key_file": "openvpn/key`name.asc",
    "expiry": {
      "status": "expiring",
      "reason": "expiring",
      "severity": "warn",
      "days_left": 10,
      "expires": "line one\nline two",
      "fpr": "FAKE|FPR"
    },
    "rotation": {
      "status": "ok",
      "rotation": false,
      "reason": "verified",
      "severity": "none",
      "latest": "3.2.7"
    },
    "contract": {
      "status": "ok",
      "reason": "valid",
      "severity": "none",
      "primary_fpr": "FAKEFPR",
      "primary_keyid": "FAKEKEYID",
      "primary_count": 1,
      "primary_validity": "-",
      "pinned_fpr": "FAKEFPR"
    },
    "errors": []
  }
]
EOF

    run "$SCRIPT" --json-file "$json_file"

    [ "$status" -eq 0 ]
    grep -Fq 'EASYRSA\|VERSION' "$GH_LOG"
    grep -Fq 'openvpn/key\`name.asc' "$GH_LOG"
    grep -Fq 'FAKE\|FPR' "$GH_LOG"
    grep -Fq 'line one line two' "$GH_LOG"
}

@test "ok-only findings do not create or comment" {
    local json_file="$TEST_TEMP_DIR/findings.json"
    write_json "$json_file" "ok" "none"

    run "$SCRIPT" --json-file "$json_file"

    [ "$status" -eq 0 ]
    [ ! -f "$GH_LOG" ] || [ "$(grep -Ec 'issue (create|comment)' "$GH_LOG")" -eq 0 ]
}

@test "malformed YAML routes to config issue rather than vendored key file issue" {
    local json_file="$TEST_TEMP_DIR/findings.json"
    write_config_parse_json "$json_file"

    run "$SCRIPT" --json-file "$json_file"

    [ "$status" -eq 0 ]
    [ "$(grep -c 'issue create' "$GH_LOG")" -eq 1 ]
    grep -q '\[GPG key lifecycle\] openvpn: monitor configuration problem' "$GH_LOG"
    grep -q 'GPG key monitor configuration finding' "$GH_LOG"
    assert_log_lacks 'vendored key file problem (build-breaking)'
}

@test "per-dependency config issue title includes container and dependency" {
    local json_file="$TEST_TEMP_DIR/findings.json"
    write_missing_pinned_fingerprint_json "$json_file"

    run "$SCRIPT" --json-file "$json_file"

    [ "$status" -eq 0 ]
    [ "$(grep -c 'issue create' "$GH_LOG")" -eq 1 ]
    grep -q '\[GPG key lifecycle\] openvpn/EASYRSA_VERSION: monitor configuration problem' "$GH_LOG"
    assert_log_lacks 'vendored key file problem (build-breaking)'
}

@test "missing key file routes to config issue rather than vendored key file issue" {
    local json_file="$TEST_TEMP_DIR/findings.json"
    write_key_file_missing_json "$json_file"

    run "$SCRIPT" --json-file "$json_file"

    [ "$status" -eq 0 ]
    [ "$(grep -c 'issue create' "$GH_LOG")" -eq 1 ]
    grep -q '\[GPG key lifecycle\] openvpn/EASYRSA_VERSION: monitor configuration problem' "$GH_LOG"
    grep -q 'key-file-missing' "$GH_LOG"
    assert_log_lacks 'vendored key file problem (build-breaking)'
}

@test "existing config issue refreshes body and is not duplicated" {
    local json_file="$TEST_TEMP_DIR/findings.json"
    write_missing_pinned_fingerprint_json "$json_file"
    export FAKE_ISSUE_LIST_MODE=config_exact

    run "$SCRIPT" --json-file "$json_file"

    [ "$status" -eq 0 ]
    [[ "$output" == *"refreshed #64"* ]]
    grep -q 'issue edit 64' "$GH_LOG"
    grep -q 'missing-pinned-fingerprint' "$GH_LOG"
    [ "$(grep -c 'issue create' "$GH_LOG")" -eq 0 ]
}

@test "invalid warn days routes to config and does not suppress real rotation issue" {
    local json_file="$TEST_TEMP_DIR/findings.json"
    write_invalid_warn_rotation_json "$json_file"

    run "$SCRIPT" --json-file "$json_file"

    [ "$status" -eq 0 ]
    [ "$(grep -c 'issue create' "$GH_LOG")" -eq 2 ]
    grep -q '\[GPG key lifecycle\] openvpn/EASYRSA_VERSION: monitor configuration problem' "$GH_LOG"
    grep -q '\[GPG key lifecycle\] openvpn/EASYRSA_VERSION: release signature no longer verifies (rotation?)' "$GH_LOG"
    assert_log_lacks 'signing key expiring'
    assert_log_lacks 'vendored key file problem (build-breaking)'
}

@test "config finding and real expiry finding open independent issues" {
    local json_file="$TEST_TEMP_DIR/findings.json"
    write_config_expiry_json "$json_file"

    run "$SCRIPT" --json-file "$json_file"

    [ "$status" -eq 0 ]
    [ "$(grep -c 'issue create' "$GH_LOG")" -eq 2 ]
    grep -q '\[GPG key lifecycle\] openvpn/EASYRSA_VERSION: monitor configuration problem' "$GH_LOG"
    grep -q '\[GPG key lifecycle\] openvpn/EASYRSA_VERSION: signing key expiring' "$GH_LOG"
    grep -q 'invalid-warn-days' "$GH_LOG"
    grep -q 'Days left' "$GH_LOG"
}

@test "broken key contract still opens independent config issue while suppressing expiry and rotation" {
    local json_file="$TEST_TEMP_DIR/findings.json"
    write_contract_config_expiry_rotation_json "$json_file"

    run "$SCRIPT" --json-file "$json_file"

    [ "$status" -eq 0 ]
    [ "$(grep -c 'issue create' "$GH_LOG")" -eq 2 ]
    grep -q '\[GPG key lifecycle\] openvpn/EASYRSA_VERSION: vendored key file problem (build-breaking)' "$GH_LOG"
    grep -q '\[GPG key lifecycle\] openvpn/EASYRSA_VERSION: monitor configuration problem' "$GH_LOG"
    grep -q 'invalid-warn-days' "$GH_LOG"
    assert_log_lacks 'signing key expiring'
    assert_log_lacks 'release signature no longer verifies'
}

@test "unparseable gh issue create output fails closed" {
    local json_file="$TEST_TEMP_DIR/findings.json"
    write_json "$json_file" "expiring" "warn"
    export FAKE_ISSUE_CREATE_MODE=unparseable

    run "$SCRIPT" --json-file "$json_file"

    [ "$status" -ne 0 ]
    [[ "$output" == *"gh issue create succeeded but returned no issue number"* ]]
    [[ "$output" != *"created #unknown"* ]]
}

@test "create error after server-side success re-searches and refreshes existing issue" {
    local json_file="$TEST_TEMP_DIR/findings.json"
    write_json "$json_file" "expiring" "warn"
    export FAKE_ISSUE_LIST_MODE=exact_after_create_error
    export FAKE_ISSUE_CREATE_MODE=fail_after_server_create
    export GH_SERVER_CREATED_FILE="$TEST_TEMP_DIR/server-created"

    run "$SCRIPT" --json-file "$json_file"

    [ "$status" -eq 0 ]
    [ "$(grep -c 'issue list' "$GH_LOG")" -eq 2 ]
    [ "$(grep -c 'issue create' "$GH_LOG")" -eq 1 ]
    grep -q 'issue edit 77' "$GH_LOG"
    [[ "$output" == *"refreshed #77"* ]]
}

@test "transient create failure retries search and creates once successfully" {
    local json_file="$TEST_TEMP_DIR/findings.json"
    write_json "$json_file" "expiring" "warn"
    export FAKE_ISSUE_CREATE_MODE=fail_first

    run "$SCRIPT" --json-file "$json_file"

    [ "$status" -eq 0 ]
    [ "$(grep -c 'issue list' "$GH_LOG")" -eq 2 ]
    [ "$(grep -c 'issue create' "$GH_LOG")" -eq 2 ]
    [ "$(grep -c 'created #88' <<< "$output")" -eq 1 ]
}

@test "transient label failure is retried with the search-act upsert unit" {
    local json_file="$TEST_TEMP_DIR/findings.json"
    write_json "$json_file" "expiring" "warn"
    export FAKE_LABEL_CREATE_MODE=fail_first_ensure
    export FAKE_ISSUE_CREATE_MODE=fail_until_labels_created
    export GH_LABEL_COUNT_FILE="$TEST_TEMP_DIR/label-count"

    run "$SCRIPT" --json-file "$json_file"

    [ "$status" -eq 0 ]
    [ "$(grep -c 'issue list' "$GH_LOG")" -eq 2 ]
    [ "$(grep -c 'issue create' "$GH_LOG")" -eq 2 ]
    [ "$(grep -c 'label create' "$GH_LOG")" -eq 12 ]
    [ "$(grep -c 'created #88' <<< "$output")" -eq 1 ]
}

@test "all create attempts fail closed after retrying the search-act unit" {
    local json_file="$TEST_TEMP_DIR/findings.json"
    write_json "$json_file" "expiring" "warn"
    export FAKE_ISSUE_CREATE_MODE=fail

    run "$SCRIPT" --json-file "$json_file"

    [ "$status" -ne 0 ]
    [ "$(grep -c 'issue list' "$GH_LOG")" -eq 3 ]
    [ "$(grep -c 'issue create' "$GH_LOG")" -eq 3 ]
    [[ "$output" == *"gh issue create failed for title: [GPG key lifecycle] openvpn/EASYRSA_VERSION: signing key expiring"* ]]
}

@test "all attempts failing for one row records failure continues remaining findings and fails overall" {
    local json_file="$TEST_TEMP_DIR/findings.json"
    write_three_expiry_json "$json_file"
    export FAKE_ISSUE_CREATE_MODE=fail_for_first_title
    export GH_CREATE_COUNT_FILE="$TEST_TEMP_DIR/create-count"

    run "$SCRIPT" --json-file "$json_file"

    [ "$status" -ne 0 ]
    [ "$(grep -c 'issue create' "$GH_LOG")" -eq 5 ]
    grep -q '\[GPG key lifecycle\] openvpn/FIRST_GPG_VERSION: signing key expiring' "$GH_LOG"
    grep -q '\[GPG key lifecycle\] openvpn/SECOND_GPG_VERSION: signing key expiring' "$GH_LOG"
    grep -q '\[GPG key lifecycle\] openvpn/THIRD_GPG_VERSION: signing key expiring' "$GH_LOG"
    [[ "$output" == *"issue operation failed for expiry finding; continuing"* ]]
    [[ "$output" == *"1 issue operation(s) failed"* ]]
}

@test "label creation uses force once per label without retrying existing-label successes" {
    local json_file="$TEST_TEMP_DIR/findings.json"
    write_json "$json_file" "expiring" "warn"
    export REQUIRE_LABEL_FORCE=true

    run "$SCRIPT" --json-file "$json_file"

    [ "$status" -eq 0 ]
    [ "$(grep -c 'label create automation' "$GH_LOG")" -eq 1 ]
    [ "$(grep -c 'label create gpg-key-lifecycle' "$GH_LOG")" -eq 1 ]
    [ "$(grep -c 'label create container:openvpn' "$GH_LOG")" -eq 1 ]
    [ "$(grep -c -- '--force' "$GH_LOG")" -eq 3 ]
    [ "$(grep -c 'issue create' "$GH_LOG")" -eq 1 ]
}
