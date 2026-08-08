#!/usr/bin/env bats

load "../test_helper"

setup() {
    setup_temp_dir
    export SCRIPT="$SCRIPTS_DIR/check-gpg-keys.sh"
    export TEST_PROJECT_ROOT="$TEST_TEMP_DIR/project"
    export GPG_KEYGEN_AVAILABLE=false
    mkdir -p "$TEST_PROJECT_ROOT/helpers" "$TEST_PROJECT_ROOT/openvpn" "$TEST_PROJECT_ROOT/ignored"
    local probe_home="$TEST_TEMP_DIR/gnupg-probe"
    mkdir -p "$probe_home"
    chmod 700 "$probe_home"
    if command -v gpg >/dev/null 2>&1 \
        && command -v gpgconf >/dev/null 2>&1 \
        && GNUPGHOME="$probe_home" gpgconf --launch gpg-agent >/dev/null 2>&1 \
        && GNUPGHOME="$probe_home" gpg --batch --pinentry-mode loopback --passphrase '' --no-tty \
            --quiet --quick-generate-key "probe <probe@example.test>" rsa sign "1d" >/dev/null 2>&1; then
        GPG_KEYGEN_AVAILABLE=true
    fi
    write_project_files
    write_fake_helpers
}

teardown() {
    teardown_temp_dir
    unset GPG_KEYS_NOW_TS RUN_GPG_BIN FAKE_EXPIRES_TS FAKE_EXPIRES_DATE FAKE_CURL_MODE FAKE_GPG_VERIFY_STATUS
    unset FAKE_PRIMARY_FPR FAKE_PRIMARY_COUNT FAKE_PRIMARY_VALIDITY FAKE_SIGNING_FPR FAKE_SIGNING_USABLE FAKE_SIGNING_CAPABLE
    unset FAKE_CURL_LOG FAKE_CURL_ARGS_LOG FAKE_LATEST_ARGS_LOG
    unset GPG_KEYS_YQ_BIN GPG_KEYS_JQ_BIN
    unset FAKE_GPG_REFRESH_MODE FAKE_GPG_REFRESH_LOG FAKE_REFRESH_PRIMARY_FPR FAKE_REFRESH_PRIMARY_VALIDITY
    unset FAKE_VENDORED_SHAPE FAKE_FETCHED_SHAPE GPG_KEYS_REFRESH_TIMEOUT_SECONDS GPG_KEYS_REFRESH_KILL_AFTER_SECONDS
    unset RUN_TIMEOUT_BIN FAKE_GPG_EXPORT_MODE FAKE_MV_MODE
}

write_project_files() {
    cp "$HELPERS_DIR/logging.sh" "$TEST_PROJECT_ROOT/helpers/logging.sh"
    cp "$HELPERS_DIR/collect-lines.sh" "$TEST_PROJECT_ROOT/helpers/collect-lines.sh"
    touch "$TEST_PROJECT_ROOT/openvpn/easyrsa-signing-key.asc"
    cat > "$TEST_PROJECT_ROOT/openvpn/config.yaml" <<'EOF'
build_args:
  EASYRSA_VERSION: "3.2.6"
  EASYRSA_KEY_FPR: "MATCHFPR"
dependency_sources:
  EASYRSA_VERSION:
    lifecycle: tracked
    type: github-release
    repo: OpenVPN/easy-rsa
    strip_v: true
    gpg_key:
      file: easyrsa-signing-key.asc
      expiry_warn_days: 60
      fingerprint_arg: EASYRSA_KEY_FPR
      release_asset_template: "EasyRSA-{version}.tgz"
      release_tag_template: "v{version}"
  PKCS11_HELPER_VERSION:
    lifecycle: tracked
    type: github-release
    repo: opensc/pkcs11-helper
    strip_v: false
EOF
    cat > "$TEST_PROJECT_ROOT/ignored/config.yaml" <<'EOF'
dependency_sources:
  FOO_VERSION:
    lifecycle: tracked
    type: github-release
    repo: example/foo
EOF
}

write_fake_helpers() {
cat > "$TEST_PROJECT_ROOT/helpers/gpg-key-expiry" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
keyfile="${1:?}"
[[ -f "$keyfile" ]] || exit 1
if [[ "${FAKE_NO_EXPIRY:-false}" == "true" ]]; then
  if [[ -n "${EXPECT_GPG_KEYS_GPG_BIN:-}" && "${GPG_KEYS_GPG_BIN:-}" != "$EXPECT_GPG_KEYS_GPG_BIN" ]]; then
    echo "unexpected GPG_KEYS_GPG_BIN=${GPG_KEYS_GPG_BIN:-}" >&2
    exit 97
  fi
  jq -nc --arg primary_fpr "${FAKE_PRIMARY_FPR:-MATCHFPR}" \
    --arg signing_fpr "${FAKE_SIGNING_FPR:-${FAKE_PRIMARY_FPR:-MATCHFPR}}" \
    --arg primary_count "${FAKE_PRIMARY_COUNT:-1}" \
    --arg primary_validity "${FAKE_PRIMARY_VALIDITY:--}" \
    --arg signing_capable "${FAKE_SIGNING_CAPABLE:-${FAKE_SIGNING_USABLE:-true}}" \
    --arg signing_usable "${FAKE_SIGNING_USABLE:-true}" \
    '{primary_fpr:$primary_fpr,primary_keyid:"FAKEKEYID",primary_count:($primary_count|tonumber),primary_validity:$primary_validity,signing_capable:($signing_capable == "true"),signing_usable:($signing_usable == "true"),signing_fpr:$signing_fpr,expires_ts:null,expires:null,no_expiry:true}'
else
  if [[ -n "${EXPECT_GPG_KEYS_GPG_BIN:-}" && "${GPG_KEYS_GPG_BIN:-}" != "$EXPECT_GPG_KEYS_GPG_BIN" ]]; then
    echo "unexpected GPG_KEYS_GPG_BIN=${GPG_KEYS_GPG_BIN:-}" >&2
    exit 97
  fi
  jq -nc --arg primary_fpr "${FAKE_PRIMARY_FPR:-MATCHFPR}" \
    --arg signing_fpr "${FAKE_SIGNING_FPR:-${FAKE_PRIMARY_FPR:-MATCHFPR}}" \
    --arg primary_count "${FAKE_PRIMARY_COUNT:-1}" \
    --arg primary_validity "${FAKE_PRIMARY_VALIDITY:--}" \
    --arg signing_capable "${FAKE_SIGNING_CAPABLE:-${FAKE_SIGNING_USABLE:-true}}" \
    --arg signing_usable "${FAKE_SIGNING_USABLE:-true}" \
    --arg ts "${FAKE_EXPIRES_TS:-2000000000}" \
    --arg date "${FAKE_EXPIRES_DATE:-2033-05-18}" \
    '{primary_fpr:$primary_fpr,primary_keyid:"FAKEKEYID",primary_count:($primary_count|tonumber),primary_validity:$primary_validity,signing_capable:($signing_capable == "true"),signing_usable:($signing_usable == "true"),signing_fpr:$signing_fpr,expires_ts:($ts|tonumber),expires:$date,no_expiry:false}'
fi
EOF
    chmod +x "$TEST_PROJECT_ROOT/helpers/gpg-key-expiry"

    cat > "$TEST_PROJECT_ROOT/helpers/latest-github-release" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${FAKE_LATEST_ARGS_LOG:-}" ]]; then
  printf '%s\n' "$*" >> "$FAKE_LATEST_ARGS_LOG"
fi
printf '%s\n' "${FAKE_LATEST_VERSION:-3.2.7}"
EOF
    chmod +x "$TEST_PROJECT_ROOT/helpers/latest-github-release"

cat > "$TEST_PROJECT_ROOT/helpers/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
original_args="$*"
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --retry|--retry-delay|--connect-timeout|--max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
: "${out:?missing -o}"
if [[ -n "${FAKE_CURL_LOG:-}" ]]; then
  printf '%s\n' "${url:-}" >> "$FAKE_CURL_LOG"
fi
if [[ -n "${FAKE_CURL_ARGS_LOG:-}" ]]; then
  printf '%s\n' "$original_args" >> "$FAKE_CURL_ARGS_LOG"
fi
case "${FAKE_CURL_MODE:-ok}" in
  ok) printf 'artifact\n' > "$out" ;;
  empty) : > "$out" ;;
  fail|404) exit 22 ;;
  *) exit 99 ;;
esac
EOF
    chmod +x "$TEST_PROJECT_ROOT/helpers/curl"

cat > "$TEST_PROJECT_ROOT/helpers/gpg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

default_shape() {
  printf '%s\n' \
    "pub:${FAKE_REFRESH_PRIMARY_VALIDITY:--}:2048:1:FAKEKEYID:0:0:::::scESC:" \
    'fpr:::::::::MATCHFPR:' \
    'sub:-:2048:1:FAKESUBKEY:0:0:::::s:' \
    'fpr:::::::::FAKESUBFPR:'
}

for arg in "$@"; do
  if [[ "$arg" == "--recv-keys" ]]; then
    if [[ -n "${FAKE_GPG_REFRESH_LOG:-}" ]]; then
      printf 'recv-keys\n' >> "$FAKE_GPG_REFRESH_LOG"
    fi
    case "${FAKE_GPG_REFRESH_MODE:-ok}" in
      ok) ;;
      fail) exit 2 ;;
      hang) exec sleep 3600 ;;
      hang-kill) trap '' TERM; exec sleep 3600 ;;
      *) exit 99 ;;
    esac
    exit 0
  fi
  if [[ "$arg" == "--show-keys" ]]; then
    # --show-keys is used on two different files: the vendored .asc, and the
    # staged export, which mktemp names with a leading dot.  Reading the staged
    # file must yield what was exported — the fetched shape — or the check that
    # the export preserved that shape can never pass.
    show_target="${*: -1}"
    if [[ "$(basename -- "$show_target")" == .* ]]; then
      if [[ -n "${FAKE_EXPORTED_SHAPE:-}" ]]; then
        printf '%s\n' "$FAKE_EXPORTED_SHAPE"
      elif [[ -n "${FAKE_FETCHED_SHAPE:-}" ]]; then
        printf '%s\n' "$FAKE_FETCHED_SHAPE"
      else
        default_shape
      fi
    elif [[ -n "${FAKE_VENDORED_SHAPE:-}" ]]; then
      printf '%s\n' "$FAKE_VENDORED_SHAPE"
    else
      default_shape
    fi
    exit 0
  fi
  if [[ "$arg" == "--list-keys" ]]; then
    if [[ -n "${FAKE_FETCHED_SHAPE:-}" ]]; then
      printf '%s\n' "$FAKE_FETCHED_SHAPE"
    else
      default_shape | sed "s/fpr:::::::::MATCHFPR:/fpr:::::::::${FAKE_REFRESH_PRIMARY_FPR:-MATCHFPR}:/"
    fi
    exit 0
  fi
  if [[ "$arg" == "--export" ]]; then
    # The export is deliberately whole: any --export-options here would be a
    # regression, so the fake reports which form it was called in.
    if [[ "${FAKE_GPG_EXPORT_MODE:-ok}" == "empty" ]]; then
      :
    elif [[ " $* " == *" --export-options "* ]]; then
      printf '%s\n' 'minimised export'
    else
      printf '%s\n' 'refreshed key material'
    fi
    exit 0
  fi
  if [[ "$arg" == "--import" ]]; then
    exit 0
  fi
  if [[ "$arg" == "--verify" ]]; then
    case "${FAKE_GPG_VERIFY_STATUS:-validsig}" in
      validsig)
        printf '[GNUPG:] VALIDSIG FAKEFPR 2026-01-01 0 0 0 0 0 0 0\n'
        exit 0
        ;;
      expkeysig_validsig)
        printf '[GNUPG:] EXPKEYSIG FAKEKEYID Fake Signer\n'
        printf '[GNUPG:] VALIDSIG FAKEFPR 2026-01-01 0 0 0 0 0 0 0\n'
        exit 1
        ;;
      nopubkey)
        printf '[GNUPG:] NO_PUBKEY NEWKEYID\n'
        exit 2
        ;;
      revkeysig_validsig)
        printf '[GNUPG:] REVKEYSIG FAKEKEYID Fake Signer\n'
        printf '[GNUPG:] VALIDSIG FAKEFPR 2026-01-01 0 0 0 0 0 0 0\n'
        exit 1
        ;;
      badsig)
        printf '[GNUPG:] BADSIG FAKEKEYID Fake Signer\n'
        exit 1
        ;;
      unrecognised)
        # gpg failing with no status keyword the summary knows about — a
        # malformed packet, a future GnuPG, an internal error.
        printf 'gpg: cannot open the signature: unexpected internal condition\n' >&2
        exit 2
        ;;
      expsig_validsig)
        printf '[GNUPG:] EXPSIG FAKEKEYID Fake Signer\n'
        printf '[GNUPG:] VALIDSIG FAKEFPR 2026-01-01 0 0 0 0 0 0 0\n'
        exit 1
        ;;
    esac
  fi
done
exit 0
EOF
    chmod +x "$TEST_PROJECT_ROOT/helpers/gpg"

cat > "$TEST_PROJECT_ROOT/helpers/mktemp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# A failing mktemp is how the isolation boundary fails to be established.
if [[ "${FAKE_MKTEMP_MODE:-ok}" == "fail" ]]; then
    exit 1
fi
exec /usr/bin/mktemp "$@"
EOF
    chmod +x "$TEST_PROJECT_ROOT/helpers/mktemp"

cat > "$TEST_PROJECT_ROOT/helpers/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${FAKE_MV_MODE:-ok}" == "fail" ]]; then
  exit 1
fi
exec /bin/mv "$@"
EOF
    chmod +x "$TEST_PROJECT_ROOT/helpers/mv"
}

run_check() {
    env PATH="$TEST_PROJECT_ROOT/helpers:$PATH" \
        GPG_KEYS_PROJECT_ROOT="$TEST_PROJECT_ROOT" \
        GPG_KEYS_GPG_BIN="${RUN_GPG_BIN:-$TEST_PROJECT_ROOT/helpers/gpg}" \
        GPG_KEYS_CURL_BIN="$TEST_PROJECT_ROOT/helpers/curl" \
        GPG_KEYS_LATEST_GH_RELEASE="$TEST_PROJECT_ROOT/helpers/latest-github-release" \
        GPG_KEYS_NOW_TS="${GPG_KEYS_NOW_TS:-}" \
        FAKE_EXPIRES_TS="${FAKE_EXPIRES_TS:-2000000000}" \
        FAKE_EXPIRES_DATE="${FAKE_EXPIRES_DATE:-2033-05-18}" \
        FAKE_NO_EXPIRY="${FAKE_NO_EXPIRY:-false}" \
        FAKE_PRIMARY_FPR="${FAKE_PRIMARY_FPR:-MATCHFPR}" \
        FAKE_PRIMARY_COUNT="${FAKE_PRIMARY_COUNT:-1}" \
        FAKE_PRIMARY_VALIDITY="${FAKE_PRIMARY_VALIDITY:--}" \
        FAKE_SIGNING_FPR="${FAKE_SIGNING_FPR:-${FAKE_PRIMARY_FPR:-MATCHFPR}}" \
        FAKE_SIGNING_USABLE="${FAKE_SIGNING_USABLE:-true}" \
        FAKE_SIGNING_CAPABLE="${FAKE_SIGNING_CAPABLE:-${FAKE_SIGNING_USABLE:-true}}" \
        FAKE_CURL_MODE="${FAKE_CURL_MODE:-ok}" \
        FAKE_CURL_ARGS_LOG="${FAKE_CURL_ARGS_LOG:-}" \
        FAKE_GPG_VERIFY_STATUS="${FAKE_GPG_VERIFY_STATUS:-validsig}" \
        FAKE_GPG_REFRESH_MODE="${FAKE_GPG_REFRESH_MODE:-ok}" \
        FAKE_GPG_REFRESH_LOG="${FAKE_GPG_REFRESH_LOG:-}" \
        FAKE_REFRESH_PRIMARY_FPR="${FAKE_REFRESH_PRIMARY_FPR:-MATCHFPR}" \
        FAKE_REFRESH_PRIMARY_VALIDITY="${FAKE_REFRESH_PRIMARY_VALIDITY:--}" \
        FAKE_VENDORED_SHAPE="${FAKE_VENDORED_SHAPE:-}" \
        FAKE_FETCHED_SHAPE="${FAKE_FETCHED_SHAPE:-}" \
        GPG_KEYS_REFRESH_TIMEOUT_SECONDS="${GPG_KEYS_REFRESH_TIMEOUT_SECONDS:-30}" \
        GPG_KEYS_REFRESH_KILL_AFTER_SECONDS="${GPG_KEYS_REFRESH_KILL_AFTER_SECONDS:-5}" \
        GPG_KEYS_TIMEOUT_BIN="${RUN_TIMEOUT_BIN:-$(command -v timeout)}" \
        FAKE_GPG_EXPORT_MODE="${FAKE_GPG_EXPORT_MODE:-ok}" \
        FAKE_MV_MODE="${FAKE_MV_MODE:-ok}" \
        FAKE_MKTEMP_MODE="${FAKE_MKTEMP_MODE:-ok}" \
        FAKE_LATEST_VERSION="${FAKE_LATEST_VERSION:-3.2.7}" \
        FAKE_LATEST_ARGS_LOG="${FAKE_LATEST_ARGS_LOG:-}" \
        EXPECT_GPG_KEYS_GPG_BIN="${EXPECT_GPG_KEYS_GPG_BIN:-}" \
        "$SCRIPT" "$@"
}

json_output() {
    printf '%s\n' "$output" | tail -n 1
}

add_monitored_container() {
    local container="$1"
    mkdir -p "$TEST_PROJECT_ROOT/$container"
    touch "$TEST_PROJECT_ROOT/$container/easyrsa-signing-key.asc"
cat > "$TEST_PROJECT_ROOT/$container/config.yaml" <<'EOF'
build_args:
  EASYRSA_KEY_FPR: "MATCHFPR"
dependency_sources:
  EASYRSA_VERSION:
    lifecycle: tracked
    type: github-release
    repo: OpenVPN/easy-rsa
    strip_v: true
    gpg_key:
      file: easyrsa-signing-key.asc
      expiry_warn_days: 60
      fingerprint_arg: EASYRSA_KEY_FPR
      release_asset_template: "EasyRSA-{version}.tgz"
      release_tag_template: "v{version}"
EOF
}

generate_live_shaped_key() {
    local outfile="$1"
    local home="$TEST_TEMP_DIR/live-shaped-gnupg"
    require_live_gpg_keygen
    mkdir -p "$home"
    chmod 700 "$home"

    GNUPGHOME="$home" gpg --faked-system-time 20230101T000000 \
        --batch --no-tty --pinentry-mode loopback --passphrase '' \
        --quiet --quick-generate-key "live-shaped <live-shaped@example.test>" rsa sign "2030-01-01"
    local fpr
    fpr="$(GNUPGHOME="$home" gpg --batch --no-tty --with-colons --list-keys "live-shaped@example.test" 2>/dev/null \
        | awk -F: '$1 == "fpr" {print $10; exit}')"
    GNUPGHOME="$home" gpg --faked-system-time 20230101T000000 \
        --batch --no-tty --pinentry-mode loopback --passphrase '' \
        --quiet --quick-add-key "$fpr" rsa sign "2024-01-01"
    GNUPGHOME="$home" gpg --batch --no-tty --pinentry-mode loopback --passphrase '' \
        --quiet --armor --export "live-shaped@example.test" > "$outfile"
    printf '%s\n' "$fpr"
}

generate_expired_primary_key() {
    local outfile="$1"
    local home="$TEST_TEMP_DIR/expired-primary-gnupg"
    require_live_gpg_keygen
    mkdir -p "$home"
    chmod 700 "$home"

    GNUPGHOME="$home" gpg --faked-system-time 20230101T000000 \
        --batch --no-tty --pinentry-mode loopback --passphrase '' \
        --quiet --quick-generate-key "expired-primary <expired-primary@example.test>" rsa sign "2024-01-01"
    local fpr
    fpr="$(GNUPGHOME="$home" gpg --batch --no-tty --with-colons --list-keys "expired-primary@example.test" 2>/dev/null \
        | awk -F: '$1 == "fpr" {print $10; exit}')"
    GNUPGHOME="$home" gpg --batch --no-tty --pinentry-mode loopback --passphrase '' \
        --quiet --armor --export "expired-primary@example.test" > "$outfile"
    printf '%s\n' "$fpr"
}

generate_cert_only_key() {
    local outfile="$1"
    local home="$TEST_TEMP_DIR/cert-only-gnupg"
    require_live_gpg_keygen
    mkdir -p "$home"
    chmod 700 "$home"

    GNUPGHOME="$home" gpg --faked-system-time 20230101T000000 \
        --batch --no-tty --pinentry-mode loopback --passphrase '' \
        --quiet --quick-generate-key "cert-only <cert-only@example.test>" rsa cert "2030-01-01"
    local fpr
    fpr="$(GNUPGHOME="$home" gpg --batch --no-tty --with-colons --list-keys "cert-only@example.test" 2>/dev/null \
        | awk -F: '$1 == "fpr" {print $10; exit}')"
    GNUPGHOME="$home" gpg --batch --no-tty --pinentry-mode loopback --passphrase '' \
        --quiet --armor --export "cert-only@example.test" > "$outfile"
    printf '%s\n' "$fpr"
}

generate_cert_only_key_with_expired_signing_subkey() {
    local outfile="$1"
    local home="$TEST_TEMP_DIR/cert-only-expired-signing-subkey-gnupg"
    require_live_gpg_keygen
    mkdir -p "$home"
    chmod 700 "$home"

    GNUPGHOME="$home" gpg --faked-system-time 20230101T000000 \
        --batch --no-tty --pinentry-mode loopback --passphrase '' \
        --quiet --quick-generate-key "cert-only-expired-signer <cert-only-expired-signer@example.test>" rsa cert "2030-01-01"
    local fpr
    fpr="$(GNUPGHOME="$home" gpg --batch --no-tty --with-colons --list-keys "cert-only-expired-signer@example.test" 2>/dev/null \
        | awk -F: '$1 == "fpr" {print $10; exit}')"
    GNUPGHOME="$home" gpg --faked-system-time 20230101T000000 \
        --batch --no-tty --pinentry-mode loopback --passphrase '' \
        --quiet --quick-add-key "$fpr" rsa sign "2024-01-01"
    GNUPGHOME="$home" gpg --batch --no-tty --pinentry-mode loopback --passphrase '' \
        --quiet --armor --export "cert-only-expired-signer@example.test" > "$outfile"
    printf '%s\n' "$fpr"
}

require_live_gpg_keygen() {
    if [[ "${GPG_KEYGEN_AVAILABLE:-false}" != "true" ]]; then
        skip "gpg key generation unavailable in this environment"
    fi
}

@test "config parsing picks dependency_sources entries with gpg_key and ignores entries without it" {
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))

    run run_check --all --json

    [ "$status" -eq 0 ]
    [ "$(jq 'length' <<< "$(json_output)")" -eq 1 ]
    [ "$(jq -r '.[0].container' <<< "$(json_output)")" = "openvpn" ]
    [ "$(jq -r '.[0].dependency' <<< "$(json_output)")" = "EASYRSA_VERSION" ]
}

@test "invalid gpg_key shape is a high config finding without raw yq errors" {
    local shape
    for shape in '[]' '"not-a-map"'; do
        yq -i ".dependency_sources.EASYRSA_VERSION.gpg_key = ${shape}" "$TEST_PROJECT_ROOT/openvpn/config.yaml"

        run run_check openvpn --json

        [ "$status" -eq 0 ]
        [ "$(jq 'length' <<< "$(json_output)")" -eq 1 ]
        [ "$(jq -r '.[0].container' <<< "$(json_output)")" = "openvpn" ]
        [ "$(jq -r '.[0].dependency' <<< "$(json_output)")" = "EASYRSA_VERSION" ]
        [ "$(jq -r '.[0].contract.reason' <<< "$(json_output)")" = "gpg-key-shape-invalid" ]
        [ "$(jq -r '.[0].contract.severity' <<< "$(json_output)")" = "high" ]
        [ "$(jq -r '.[0].config[0].reason' <<< "$(json_output)")" = "gpg-key-shape-invalid" ]
        [ "$(jq -r '.[0].config[0].severity' <<< "$(json_output)")" = "high" ]
        [[ "$output" != *"cannot index"* ]]
    done
}

@test "a signature_suffix outside {.sig,.asc} is a config finding, not a key rotation" {
    local suffix
    for suffix in '""' '".gpg"' '"../../etc/passwd"' '{}' '[]'; do
        yq -i ".dependency_sources.EASYRSA_VERSION.gpg_key.signature_suffix = ${suffix}" \
            "$TEST_PROJECT_ROOT/openvpn/config.yaml"

        run run_check openvpn --json

        [ "$status" -eq 0 ]
        [ "$(jq -r '.[0].config[0].reason' <<< "$(json_output)")" = "gpg-key-shape-invalid" ]
        [ "$(jq -r '.[0].config[0].severity' <<< "$(json_output)")" = "high" ]
        # The defect this pins: an empty suffix made the signature path equal the
        # artifact path, so gpg verified the artifact against itself, failed, and
        # the monitor announced a high-severity rotation that had not happened.
        [ "$(jq -r '.[0].rotation.rotation' <<< "$(json_output)")" = "false" ]
        [ "$(jq -r '.[0].rotation.severity' <<< "$(json_output)")" != "high" ]
    done
}

@test "non-scalar gpg_key field is a high config finding before field access" {
    yq -i '.dependency_sources.EASYRSA_VERSION.gpg_key.release_asset_template = []' "$TEST_PROJECT_ROOT/openvpn/config.yaml"

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].contract.reason' <<< "$(json_output)")" = "gpg-key-shape-invalid" ]
    [ "$(jq -r '.[0].config[0].reason' <<< "$(json_output)")" = "gpg-key-shape-invalid" ]
    [[ "$output" != *"cannot index"* ]]
}

@test "preflight fails clearly when yq is unresolvable" {
    export GPG_KEYS_YQ_BIN="$TEST_TEMP_DIR/bin/missing-yq"

    run run_check openvpn --json

    [ "$status" -ne 0 ]
    [[ "$output" == *"unable to resolve yq; set GPG_KEYS_YQ_BIN"* ]]
}

@test "preflight fails clearly when jq is unresolvable" {
    export GPG_KEYS_JQ_BIN="$TEST_TEMP_DIR/bin/missing-jq"

    run run_check openvpn --json

    [ "$status" -ne 0 ]
    [[ "$output" == *"unable to resolve jq; set GPG_KEYS_JQ_BIN"* ]]
}

@test "happy path matching primary fingerprint and one primary has no contract finding" {
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].contract.status' <<< "$(json_output)")" = "ok" ]
    [ "$(jq -r '.[0].contract.reason' <<< "$(json_output)")" = "valid" ]
    [ "$(jq -r '.[0].contract.signing_capable' <<< "$(json_output)")" = "true" ]
    [ "$(jq -r '.[0].contract.signing_usable' <<< "$(json_output)")" = "true" ]
}

@test "unchanged trust shape with different armored bytes proposes no refresh" {
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))
    local refresh_dir="$TEST_TEMP_DIR/refreshed"

    run run_check openvpn --json --refresh-dir "$refresh_dir"

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].refresh.status' <<< "$(json_output)")" = "unchanged" ]
    [ "$(jq -r '.[0].refresh.proposed' <<< "$(json_output)")" = "false" ]
    [ ! -e "$refresh_dir/openvpn/easyrsa-signing-key.asc" ]
}

@test "a changed primary or subkey trust shape proposes a refresh with its delta" {
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))
    export FAKE_FETCHED_SHAPE=$'pub:-:2048:1:FAKEKEYID:0:0:::::scESC:\nfpr:::::::::MATCHFPR:\nsub:r:2048:1:FAKESUBKEY:0:0:::::s:\nfpr:::::::::FAKESUBFPR:'
    local refresh_dir="$TEST_TEMP_DIR/refreshed"

    run run_check openvpn --json --refresh-dir "$refresh_dir"

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].refresh.status' <<< "$(json_output)")" = "changed" ]
    [ "$(jq -r '.[0].refresh.proposed' <<< "$(json_output)")" = "true" ]
    [ "$(jq -r '.[0].refresh.delta.added[]' <<< "$(json_output)")" = "sub:r:0:s:FAKESUBFPR" ]
    [ "$(jq -r '.[0].refresh.delta.removed[]' <<< "$(json_output)")" = "sub:-:0:s:FAKESUBFPR" ]
    [ "$(cat "$refresh_dir/openvpn/easyrsa-signing-key.asc")" = "refreshed key material" ]
}

@test "a keyserver fetch failure warns and does not propose a refresh" {
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))
    export FAKE_GPG_REFRESH_MODE=fail

    run run_check openvpn --json --refresh-check

    [ "$status" -eq 0 ]
    [[ "$output" == *"::warning::gpg-key-refresh: openvpn/EASYRSA_VERSION: keyserver-unavailable"* ]]
    [ "$(jq -r '.[0].refresh.status' <<< "$(json_output)")" = "unavailable" ]
    [ "$(jq -r '.[0].refresh.proposed' <<< "$(json_output)")" = "false" ]
}

@test "a fetched primary fingerprint mismatch raises the anchor alarm and does not propose a refresh" {
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))
    export FAKE_REFRESH_PRIMARY_FPR=DIFFERENTFPR

    run run_check openvpn --json --refresh-check

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].refresh.status' <<< "$(json_output)")" = "alarm" ]
    [ "$(jq -r '.[0].refresh.proposed' <<< "$(json_output)")" = "false" ]
    [ "$(jq -r '.[0].contract.status' <<< "$(json_output)")" = "error" ]
    [ "$(jq -r '.[0].contract.reason' <<< "$(json_output)")" = "primary-fingerprint-mismatch" ]
    [ "$(jq -r '.[0].contract.severity' <<< "$(json_output)")" = "high" ]
}

@test "a fetched key missing a vendored subkey raises an omission alarm and stages nothing" {
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))
    export FAKE_FETCHED_SHAPE=$'pub:-:2048:1:FAKEKEYID:0:0:::::scESC:\nfpr:::::::::MATCHFPR:'
    local refresh_dir="$TEST_TEMP_DIR/refreshed"

    run run_check openvpn --json --refresh-dir "$refresh_dir"

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].refresh.status' <<< "$(json_output)")" = "alarm" ]
    [ "$(jq -r '.[0].refresh.reason' <<< "$(json_output)")" = "missing-key-fingerprints: FAKESUBFPR" ]
    [ "$(jq -r '.[0].contract.reason' <<< "$(json_output)")" = "missing-key-fingerprints: FAKESUBFPR" ]
    [ "$(jq -r '.[0].refresh.proposed' <<< "$(json_output)")" = "false" ]
    [ ! -e "$refresh_dir/openvpn/easyrsa-signing-key.asc" ]
}

@test "the trust shape comparison ignores third-party signatures" {
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))
    export FAKE_FETCHED_SHAPE=$'pub:-:2048:1:FAKEKEYID:0:0:::::scESC:\nfpr:::::::::MATCHFPR:\nsig:::::::\nsub:-:2048:1:FAKESUBKEY:0:0:::::s:\nfpr:::::::::FAKESUBFPR:\nsig:::::::'

    run run_check openvpn --json --refresh-check

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].refresh.status' <<< "$(json_output)")" = "unchanged" ]
    [ "$(jq -r '.[0].refresh.proposed' <<< "$(json_output)")" = "false" ]
}

@test "a subkey replacement is an omission alarm even when its metadata is identical" {
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))
    export FAKE_FETCHED_SHAPE=$'pub:-:2048:1:FAKEKEYID:0:0:::::scESC:\nfpr:::::::::MATCHFPR:\nsub:-:2048:1:FAKESUBKEY:0:0:::::s:\nfpr:::::::::REPLACEDSUBFPR:'

    run run_check openvpn --json --refresh-check

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].refresh.status' <<< "$(json_output)")" = "alarm" ]
    [ "$(jq -r '.[0].refresh.reason' <<< "$(json_output)")" = "missing-key-fingerprints: FAKESUBFPR" ]
}

@test "a fetched revoked primary raises an alarm and stages nothing" {
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))
    export FAKE_REFRESH_PRIMARY_VALIDITY=r
    local refresh_dir="$TEST_TEMP_DIR/refreshed"

    run run_check openvpn --json --refresh-dir "$refresh_dir"

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].refresh.status' <<< "$(json_output)")" = "alarm" ]
    [ "$(jq -r '.[0].refresh.reason' <<< "$(json_output)")" = "primary-key-revoked" ]
    [ "$(jq -r '.[0].refresh.proposed' <<< "$(json_output)")" = "false" ]
    [ "$(jq -r '.[0].contract.status' <<< "$(json_output)")" = "error" ]
    [ "$(jq -r '.[0].contract.reason' <<< "$(json_output)")" = "primary-key-revoked" ]
    [ ! -e "$refresh_dir/openvpn/easyrsa-signing-key.asc" ]
}

@test "a fetched expired primary is unavailable while the vendored primary is valid" {
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))
    export FAKE_REFRESH_PRIMARY_VALIDITY=e
    export FAKE_VENDORED_SHAPE=$'pub:-:2048:1:FAKEKEYID:0:0:::::scESC:\nfpr:::::::::MATCHFPR:\nsub:-:2048:1:FAKESUBKEY:0:0:::::s:\nfpr:::::::::FAKESUBFPR:'
    export FAKE_FETCHED_SHAPE=$'pub:e:2048:1:FAKEKEYID:0:0:::::scESC:\nfpr:::::::::MATCHFPR:\nsub:-:2048:1:FAKESUBKEY:0:0:::::s:\nfpr:::::::::FAKESUBFPR:\nsub:-:2048:1:NEWKEY:0:0:::::s:\nfpr:::::::::REPLACEDSUBFPR:'
    local refresh_dir="$TEST_TEMP_DIR/refreshed"

    run run_check openvpn --json --refresh-dir "$refresh_dir"

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].refresh.status' <<< "$(json_output)")" = "unavailable" ]
    [ "$(jq -r '.[0].refresh.reason' <<< "$(json_output)")" = "fetched-primary-expired" ]
    [ "$(jq -r '.[0].refresh.proposed' <<< "$(json_output)")" = "false" ]
    [ ! -e "$refresh_dir/openvpn/easyrsa-signing-key.asc" ]
}

@test "an expired fetched primary still proposes when the vendored primary is also expired" {
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))
    export FAKE_REFRESH_PRIMARY_VALIDITY=e
    export FAKE_VENDORED_SHAPE=$'pub:e:2048:1:FAKEKEYID:0:0:::::scESC:\nfpr:::::::::MATCHFPR:\nsub:-:2048:1:FAKESUBKEY:0:0:::::s:\nfpr:::::::::FAKESUBFPR:'
    export FAKE_FETCHED_SHAPE=$'pub:e:2048:1:FAKEKEYID:0:0:::::scESC:\nfpr:::::::::MATCHFPR:\nsub:-:2048:1:FAKESUBKEY:0:0:::::s:\nfpr:::::::::FAKESUBFPR:\nsub:-:2048:1:NEWKEY:0:0:::::s:\nfpr:::::::::REPLACEDSUBFPR:'
    local refresh_dir="$TEST_TEMP_DIR/refreshed"

    run run_check openvpn --json --refresh-dir "$refresh_dir"

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].refresh.status' <<< "$(json_output)")" = "changed" ]
    [ "$(jq -r '.[0].refresh.proposed' <<< "$(json_output)")" = "true" ]
    [ -f "$refresh_dir/openvpn/easyrsa-signing-key.asc" ]
}

@test "a revoked subkey on a live primary is ordinary refresh work, not an alarm" {
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))
    export FAKE_FETCHED_SHAPE=$'pub:-:2048:1:FAKEKEYID:0:0:::::scESC:\nfpr:::::::::MATCHFPR:\nsub:r:2048:1:FAKESUBKEY:0:0:::::s:\nfpr:::::::::FAKESUBFPR:'

    run run_check openvpn --json --refresh-check

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].refresh.status' <<< "$(json_output)")" = "changed" ]
    [ "$(jq -r '.[0].contract.status' <<< "$(json_output)")" = "ok" ]
}

@test "a missing timeout binary fails preflight instead of reporting a keyserver outage" {
    export RUN_TIMEOUT_BIN="$TEST_TEMP_DIR/missing-timeout"

    run run_check openvpn --json --refresh-check

    [ "$status" -ne 0 ]
    [[ "$output" == *"unable to resolve timeout; set GPG_KEYS_TIMEOUT_BIN"* ]]
    [[ "$output" != *"keyserver-unavailable"* ]]
}

@test "a failed final move is unavailable rather than reported as changed" {
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))
    export FAKE_FETCHED_SHAPE=$'pub:-:2048:1:FAKEKEYID:0:0:::::scESC:\nfpr:::::::::MATCHFPR:\nsub:-:2048:1:FAKESUBKEY:0:0:::::s:\nfpr:::::::::FAKESUBFPR:\nsub:-:2048:1:NEWKEY:0:0:::::s:\nfpr:::::::::REPLACEDSUBFPR:'
    export FAKE_MV_MODE=fail
    local refresh_dir="$TEST_TEMP_DIR/refreshed"

    run run_check openvpn --json --refresh-dir "$refresh_dir"

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].refresh.status' <<< "$(json_output)")" = "unavailable" ]
    [ "$(jq -r '.[0].refresh.reason' <<< "$(json_output)")" = "key-install-unavailable" ]
    [ ! -e "$refresh_dir/openvpn/easyrsa-signing-key.asc" ]
}

@test "a zero-byte export is not installed" {
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))
    export FAKE_FETCHED_SHAPE=$'pub:-:2048:1:FAKEKEYID:0:0:::::scESC:\nfpr:::::::::MATCHFPR:\nsub:-:2048:1:FAKESUBKEY:0:0:::::s:\nfpr:::::::::FAKESUBFPR:\nsub:-:2048:1:NEWKEY:0:0:::::s:\nfpr:::::::::REPLACEDSUBFPR:'
    export FAKE_GPG_EXPORT_MODE=empty
    local refresh_dir="$TEST_TEMP_DIR/refreshed"

    run run_check openvpn --json --refresh-dir "$refresh_dir"

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].refresh.status' <<< "$(json_output)")" = "unavailable" ]
    [ "$(jq -r '.[0].refresh.reason' <<< "$(json_output)")" = "key-export-invalid" ]
    [ ! -e "$refresh_dir/openvpn/easyrsa-signing-key.asc" ]
}

@test "a hanging keyserver becomes unavailable within the configured bound" {
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))
    export FAKE_GPG_REFRESH_MODE=hang
    export GPG_KEYS_REFRESH_TIMEOUT_SECONDS=1
    export GPG_KEYS_REFRESH_KILL_AFTER_SECONDS=1
    local started elapsed
    started="$(date +%s)"

    run run_check openvpn --json --refresh-check
    elapsed=$(( $(date +%s) - started ))

    [ "$status" -eq 0 ]
    [ "$elapsed" -lt 4 ]
    [ "$(jq -r '.[0].refresh.status' <<< "$(json_output)")" = "unavailable" ]
    [ "$(jq -r '.[0].refresh.reason' <<< "$(json_output)")" = "keyserver-timeout" ]
    [ "$(jq -r '.[0].refresh.proposed' <<< "$(json_output)")" = "false" ]
}

@test "a keyserver that ignores termination is killed and remains unavailable" {
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))
    export FAKE_GPG_REFRESH_MODE=hang-kill
    export GPG_KEYS_REFRESH_TIMEOUT_SECONDS=1
    export GPG_KEYS_REFRESH_KILL_AFTER_SECONDS=1

    run run_check openvpn --json --refresh-check

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].refresh.status' <<< "$(json_output)")" = "unavailable" ]
    [ "$(jq -r '.[0].refresh.reason' <<< "$(json_output)")" = "keyserver-timeout" ]
    [ "$(jq -r '.[0].refresh.proposed' <<< "$(json_output)")" = "false" ]
}

@test "without refresh work requested, no keyserver call occurs and refresh is not-checked" {
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))
    export FAKE_GPG_REFRESH_LOG="$TEST_TEMP_DIR/refresh.log"

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    [ ! -e "$FAKE_GPG_REFRESH_LOG" ]
    [ "$(jq -r '.[0].refresh.status' <<< "$(json_output)")" = "not-checked" ]
}

@test "a human-readable refresh check reports its refresh result" {
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))

    run run_check openvpn --refresh-check

    [ "$status" -eq 0 ]
    [[ "$output" == *"refresh=unchanged"* ]]
}

@test "a workspace that cannot be created refuses instead of using the real keyring" {
    # GNUPGHOME="" is not an isolated keyring, it is the caller's own, so a
    # failing mktemp would make the fetch import into it.  The boundary that
    # cannot be established must refuse rather than widen.
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))
    export FAKE_MKTEMP_MODE=fail
    local refresh_dir="$TEST_TEMP_DIR/refreshed"

    run run_check openvpn --json --refresh-dir "$refresh_dir"

    [ "$status" -eq 0 ]
    [[ "$output" == *"refresh-workspace-unavailable"* ]]
    [[ "$output" != *'"proposed":true'* ]]
    [ ! -e "$refresh_dir/openvpn/easyrsa-signing-key.asc" ]
    # The fetch must not have run at all.
    [ ! -s "$TEST_PROJECT_ROOT/gpg-refresh.log" ] || \
        ! grep -q 'recv-keys' "$TEST_PROJECT_ROOT/gpg-refresh.log"
}

@test "an export that lost a fetched subkey is not installed" {
    # The same omission the fetch step refuses from a keyserver is just as
    # damaging arriving from the export: a staged key carrying the right primary
    # but fewer subkeys would replace the vendored file with an amputated one.
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))
    export FAKE_FETCHED_SHAPE=$'pub:-:2048:1:FAKEKEYID:0:0:::::scESC:\nfpr:::::::::MATCHFPR:\nsub:-:2048:1:FAKESUBKEY:0:0:::::s:\nfpr:::::::::FAKESUBFPR:\nsub:-:2048:1:NEWKEY:0:0:::::s:\nfpr:::::::::NEWSUBFPR:'
    # The export drops the subkey the fetch had just gained.
    export FAKE_EXPORTED_SHAPE=$'pub:-:2048:1:FAKEKEYID:0:0:::::scESC:\nfpr:::::::::MATCHFPR:\nsub:-:2048:1:FAKESUBKEY:0:0:::::s:\nfpr:::::::::FAKESUBFPR:'
    local refresh_dir="$TEST_TEMP_DIR/refreshed"

    run run_check openvpn --json --refresh-dir "$refresh_dir"

    [ "$status" -eq 0 ]
    [ ! -e "$refresh_dir/openvpn/easyrsa-signing-key.asc" ]
    [[ "$output" == *"key-export-invalid"* ]]
    [[ "$output" != *'"proposed":true'* ]]
}

@test "a refresh exports the whole key rather than a minimised one" {
    # Measured on the real openvpn key: --export-options export-minimal keeps
    # 8 subkeys of 20, dropping every expired one — six of them signing
    # subkeys that signed releases between 2019 and mid-2026 — while keeping
    # the revoked ones.  A retained rebuild of one of those releases would
    # stop verifying, so minimisation must not come back.
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))
    export FAKE_FETCHED_SHAPE=$'pub:-:2048:1:FAKEKEYID:0:0:::::scESC:\nfpr:::::::::MATCHFPR:\nsub:-:2048:1:FAKESUBKEY:0:0:::::s:\nfpr:::::::::FAKESUBFPR:\nsub:-:2048:1:NEWKEY:0:0:::::s:\nfpr:::::::::REPLACEDSUBFPR:'
    local refresh_dir="$TEST_TEMP_DIR/refreshed"

    run run_check openvpn --json --refresh-dir "$refresh_dir"

    [ "$status" -eq 0 ]
    [ "$(cat "$refresh_dir/openvpn/easyrsa-signing-key.asc")" = "refreshed key material" ]
    [[ "$(cat "$refresh_dir/openvpn/easyrsa-signing-key.asc")" != *"minimised export"* ]]
}

@test "an unpaired pub/sub record is unavailable instead of comparing equal" {
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))
    export FAKE_FETCHED_SHAPE=$'pub:-:2048:1:FAKEKEYID:0:0:::::scESC:\nsub:-:2048:1:FAKESUBKEY:0:0:::::s:\nfpr:::::::::FAKESUBFPR:'

    run run_check openvpn --json --refresh-check

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].refresh.status' <<< "$(json_output)")" = "unavailable" ]
    [ "$(jq -r '.[0].refresh.reason' <<< "$(json_output)")" = "key-shape-unavailable" ]
}

@test "workflow GPG gate treats config-only rows as findings" {
    local findings="$TEST_TEMP_DIR/findings.json"
    cat > "$findings" <<'EOF'
[
  {
    "container": "openvpn",
    "dependency": "EASYRSA_VERSION",
    "expiry": {"status": "ok", "reason": "valid", "severity": "none"},
    "rotation": {"status": "ok", "rotation": false, "reason": "verified", "severity": "none"},
    "contract": {"status": "ok", "reason": "valid", "severity": "none"},
    "config": [{"reason": "invalid-warn-days", "severity": "warn", "value": "sixty"}],
    "errors": ["EASYRSA_VERSION: invalid gpg_key.expiry_warn_days: sixty"]
  }
]
EOF
    local filter has_findings
    filter="$(awk '
      /has_findings="\$\(jq -r '\''/ {capture=1; next}
      capture && /'\'' findings\.json\)"/ {capture=0; exit}
      capture {print}
    ' "$PROJECT_ROOT/.github/workflows/upstream-monitor.yaml")"
    has_findings="$(jq -r "$filter" "$findings")"

    [ "$has_findings" = "true" ]
}

@test "workflow GPG tokened issue steps are gated to master" {
    local wf="$PROJECT_ROOT/.github/workflows/upstream-monitor.yaml"
    local token_if issue_if
    token_if="$(yq -r '.jobs."check-gpg-keys".steps[] | select(.id == "app-token") | .if // ""' "$wf")"
    issue_if="$(yq -r '.jobs."check-gpg-keys".steps[] | select(.name == "Open or refresh GPG key lifecycle issues") | .if // ""' "$wf")"

    [[ "$token_if" == *"steps.gpg.outputs.has_findings == 'true'"* ]]
    [[ "$token_if" == *"github.ref == 'refs/heads/master'"* ]]
    [[ "$issue_if" == *"steps.gpg.outputs.has_findings == 'true'"* ]]
    [[ "$issue_if" == *"github.ref == 'refs/heads/master'"* ]]
}

@test "workflow fans changed GPG key shapes into one pinned create-pull-request matrix job" {
    local wf="$PROJECT_ROOT/.github/workflows/upstream-monitor.yaml"
    local matrix pr_action add_paths
    matrix="$(yq -r '.jobs."refresh-vendored-gpg-keys".strategy.matrix.include' "$wf")"
    pr_action="$(yq -r '.jobs."refresh-vendored-gpg-keys".steps[] | select(.id == "create-pr") | .uses' "$wf")"
    add_paths="$(yq -r '.jobs."refresh-vendored-gpg-keys".steps[] | select(.id == "create-pr") | .with."add-paths"' "$wf")"

    [[ "$matrix" == *"fromJson(needs.check-gpg-keys.outputs.refresh_candidates)"* ]]
    [ "$pr_action" = "peter-evans/create-pull-request@5f6978faf089d4d20b00c7766989d076bb2fc7f1" ]
    [ "$add_paths" = '${{ matrix.key_file }}' ]
}

@test "workflow passes refresh matrix values into shell through environment variables" {
    local wf="$PROJECT_ROOT/.github/workflows/upstream-monitor.yaml"
    local env_container env_dependency refresh_run
    env_container="$(yq -r '.jobs."refresh-vendored-gpg-keys".steps[] | select(.id == "refresh") | .env.CONTAINER' "$wf")"
    env_dependency="$(yq -r '.jobs."refresh-vendored-gpg-keys".steps[] | select(.id == "refresh") | .env.DEPENDENCY' "$wf")"
    refresh_run="$(yq -r '.jobs."refresh-vendored-gpg-keys".steps[] | select(.id == "refresh") | .run' "$wf")"

    [ "$env_container" = '${{ matrix.container }}' ]
    [ "$env_dependency" = '${{ matrix.dependency }}' ]
    [[ "$refresh_run" != *'${{ matrix.'* ]]
}

@test "trust contract mismatch is high when no signing-capable key exists" {
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))
    export FAKE_SIGNING_CAPABLE=false
    export FAKE_SIGNING_USABLE=false

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].contract.status' <<< "$(json_output)")" = "error" ]
    [ "$(jq -r '.[0].contract.reason' <<< "$(json_output)")" = "key-contract-mismatch" ]
    [ "$(jq -r '.[0].contract.severity' <<< "$(json_output)")" = "high" ]
    [ "$(jq -r '.[0].contract.signing_capable' <<< "$(json_output)")" = "false" ]
    [ "$(jq -r '.[0].contract.signing_usable' <<< "$(json_output)")" = "false" ]
}

@test "revoked primary is a high contract mismatch even without an expiry finding" {
    export FAKE_NO_EXPIRY=true
    export FAKE_PRIMARY_VALIDITY=r
    export FAKE_SIGNING_CAPABLE=true
    export FAKE_SIGNING_USABLE=false

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].contract.status' <<< "$(json_output)")" = "error" ]
    [ "$(jq -r '.[0].contract.reason' <<< "$(json_output)")" = "key-contract-mismatch" ]
    [ "$(jq -r '.[0].contract.severity' <<< "$(json_output)")" = "high" ]
    [ "$(jq -r '.[0].contract.primary_validity' <<< "$(json_output)")" = "r" ]
    [ "$(jq -r '.[0].expiry.status' <<< "$(json_output)")" = "ok" ]
    [ "$(jq -r '.[0].expiry.reason' <<< "$(json_output)")" = "no-expiry" ]
}

@test "invalid and disabled primaries are high contract mismatches" {
    local validity
    for validity in i d; do
        export FAKE_NO_EXPIRY=true
        export FAKE_PRIMARY_VALIDITY="$validity"
        export FAKE_SIGNING_CAPABLE=true
        export FAKE_SIGNING_USABLE=false

        run run_check openvpn --json

        [ "$status" -eq 0 ]
        [ "$(jq -r '.[0].contract.status' <<< "$(json_output)")" = "error" ]
        [ "$(jq -r '.[0].contract.reason' <<< "$(json_output)")" = "key-contract-mismatch" ]
        [ "$(jq -r '.[0].contract.severity' <<< "$(json_output)")" = "high" ]
        [ "$(jq -r '.[0].contract.primary_validity' <<< "$(json_output)")" = "$validity" ]
    done
}

@test "cert-only primary with no signing subkey is a high contract mismatch" {
    require_live_gpg_keygen
    local keyfile="$TEST_PROJECT_ROOT/openvpn/easyrsa-signing-key.asc"
    local primary_fpr
    primary_fpr="$(generate_cert_only_key "$keyfile")"
    cp "$HELPERS_DIR/gpg-key-expiry" "$TEST_PROJECT_ROOT/helpers/gpg-key-expiry"
    chmod +x "$TEST_PROJECT_ROOT/helpers/gpg-key-expiry"
    PRIMARY_FPR="$primary_fpr" yq -i '.build_args.EASYRSA_KEY_FPR = strenv(PRIMARY_FPR)' "$TEST_PROJECT_ROOT/openvpn/config.yaml"
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))
    export RUN_GPG_BIN
    RUN_GPG_BIN="$(command -v gpg)"

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].contract.status' <<< "$(json_output)")" = "error" ]
    [ "$(jq -r '.[0].contract.reason' <<< "$(json_output)")" = "key-contract-mismatch" ]
    [ "$(jq -r '.[0].contract.severity' <<< "$(json_output)")" = "high" ]
    [ "$(jq -r '.[0].contract.signing_capable' <<< "$(json_output)")" = "false" ]
    [ "$(jq -r '.[0].contract.signing_usable' <<< "$(json_output)")" = "false" ]
}

@test "expired primary signing key keeps contract ok and reports expired expiry" {
    export FAKE_PRIMARY_VALIDITY=e
    export FAKE_SIGNING_CAPABLE=true
    export FAKE_SIGNING_USABLE=false
    export FAKE_EXPIRES_TS=1704067200
    export FAKE_EXPIRES_DATE=2024-01-01
    export GPG_KEYS_NOW_TS=2000000000

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].contract.status' <<< "$(json_output)")" = "ok" ]
    [ "$(jq -r '.[0].contract.reason' <<< "$(json_output)")" = "valid" ]
    [ "$(jq -r '.[0].contract.signing_capable' <<< "$(json_output)")" = "true" ]
    [ "$(jq -r '.[0].contract.signing_usable' <<< "$(json_output)")" = "false" ]
    [ "$(jq -r '.[0].expiry.status' <<< "$(json_output)")" = "expired" ]
    [ "$(jq -r '.[0].expiry.reason' <<< "$(json_output)")" = "signing-key-expired" ]
    [ "$(jq -r '.[0].expiry.severity' <<< "$(json_output)")" = "high" ]
    [ "$(jq -r '.[0].expiry.expires' <<< "$(json_output)")" = "2024-01-01" ]
}

@test "trust contract mismatch is high when primary fingerprint differs from pinned fingerprint" {
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))
    export FAKE_PRIMARY_FPR=DIFFERENTFPR

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].contract.status' <<< "$(json_output)")" = "error" ]
    [ "$(jq -r '.[0].contract.reason' <<< "$(json_output)")" = "key-contract-mismatch" ]
    [ "$(jq -r '.[0].contract.severity' <<< "$(json_output)")" = "high" ]
}

@test "trust contract mismatch is high when pinned fingerprint casing differs from key fingerprint" {
    yq -i '.build_args.EASYRSA_KEY_FPR = "matchfpr"' "$TEST_PROJECT_ROOT/openvpn/config.yaml"
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].contract.status' <<< "$(json_output)")" = "error" ]
    [ "$(jq -r '.[0].contract.reason' <<< "$(json_output)")" = "key-contract-mismatch" ]
    [ "$(jq -r '.[0].contract.primary_fpr' <<< "$(json_output)")" = "MATCHFPR" ]
    [ "$(jq -r '.[0].contract.pinned_fpr' <<< "$(json_output)")" = "matchfpr" ]
}

@test "helper invocation passes the configured gpg binary" {
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))
    export EXPECT_GPG_KEYS_GPG_BIN="$TEST_PROJECT_ROOT/helpers/gpg"

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].contract.status' <<< "$(json_output)")" = "ok" ]
}

@test "trust contract mismatch is high when the key file has two primaries" {
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))
    export FAKE_PRIMARY_COUNT=2

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].contract.status' <<< "$(json_output)")" = "error" ]
    [ "$(jq -r '.[0].contract.reason' <<< "$(json_output)")" = "key-contract-mismatch" ]
    [ "$(jq -r '.[0].contract.severity' <<< "$(json_output)")" = "high" ]
}

@test "missing fingerprint_arg or referenced build_arg fails closed for the dependency" {
    yq -i 'del(.dependency_sources.EASYRSA_VERSION.gpg_key.fingerprint_arg)' "$TEST_PROJECT_ROOT/openvpn/config.yaml"
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].contract.status' <<< "$(json_output)")" = "error" ]
    [ "$(jq -r '.[0].contract.reason' <<< "$(json_output)")" = "missing-pinned-fingerprint" ]
    [ "$(jq -r '.[0].contract.severity' <<< "$(json_output)")" = "high" ]
}

@test "expiry on a live-shaped key uses the pinned primary expiry, not an expired signing subkey" {
    require_live_gpg_keygen
    local keyfile="$TEST_PROJECT_ROOT/openvpn/easyrsa-signing-key.asc"
    local primary_fpr
    primary_fpr="$(generate_live_shaped_key "$keyfile")"
    cp "$HELPERS_DIR/gpg-key-expiry" "$TEST_PROJECT_ROOT/helpers/gpg-key-expiry"
    chmod +x "$TEST_PROJECT_ROOT/helpers/gpg-key-expiry"
    PRIMARY_FPR="$primary_fpr" yq -i '.build_args.EASYRSA_KEY_FPR = strenv(PRIMARY_FPR)' "$TEST_PROJECT_ROOT/openvpn/config.yaml"
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))
    export RUN_GPG_BIN
    RUN_GPG_BIN="$(command -v gpg)"

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].contract.status' <<< "$(json_output)")" = "ok" ]
    [ "$(jq -r '.[0].contract.signing_capable' <<< "$(json_output)")" = "true" ]
    [ "$(jq -r '.[0].contract.signing_usable' <<< "$(json_output)")" = "true" ]
    [ "$(jq -r '.[0].expiry.fpr' <<< "$(json_output)")" = "$primary_fpr" ]
    [ "$(jq -r '.[0].expiry.expires' <<< "$(json_output)")" = "2030-01-01" ]
    [ "$(jq -r '.[0].expiry.expires' <<< "$(json_output)")" != "2024-01-01" ]
}

@test "already-expired primary reports expired status with date instead of key parse error" {
    require_live_gpg_keygen
    local keyfile="$TEST_PROJECT_ROOT/openvpn/easyrsa-signing-key.asc"
    local primary_fpr
    primary_fpr="$(generate_expired_primary_key "$keyfile")"
    cp "$HELPERS_DIR/gpg-key-expiry" "$TEST_PROJECT_ROOT/helpers/gpg-key-expiry"
    chmod +x "$TEST_PROJECT_ROOT/helpers/gpg-key-expiry"
    PRIMARY_FPR="$primary_fpr" yq -i '.build_args.EASYRSA_KEY_FPR = strenv(PRIMARY_FPR)' "$TEST_PROJECT_ROOT/openvpn/config.yaml"
    export GPG_KEYS_NOW_TS=2000000000
    export RUN_GPG_BIN
    RUN_GPG_BIN="$(command -v gpg)"

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].contract.status' <<< "$(json_output)")" = "ok" ]
    [ "$(jq -r '.[0].contract.signing_capable' <<< "$(json_output)")" = "true" ]
    [ "$(jq -r '.[0].contract.signing_usable' <<< "$(json_output)")" = "false" ]
    [ "$(jq -r '.[0].expiry.status' <<< "$(json_output)")" = "expired" ]
    [ "$(jq -r '.[0].expiry.reason' <<< "$(json_output)")" = "signing-key-expired" ]
    [ "$(jq -r '.[0].expiry.severity' <<< "$(json_output)")" = "high" ]
    [ "$(jq -r '.[0].expiry.expires' <<< "$(json_output)")" = "2024-01-01" ]
    [ "$(jq -r '.[0].expiry.fpr' <<< "$(json_output)")" = "$primary_fpr" ]
}

@test "expired-only signing subkey reports signing-key-expired even when cert-only primary has later expiry" {
    require_live_gpg_keygen
    local keyfile="$TEST_PROJECT_ROOT/openvpn/easyrsa-signing-key.asc"
    local primary_fpr expired_signing_fpr
    primary_fpr="$(generate_cert_only_key_with_expired_signing_subkey "$keyfile")"
    expired_signing_fpr="$(gpg --batch --show-keys --with-colons "$keyfile" 2>/dev/null \
        | awk -F: '$1 == "sub" && $12 ~ /[sS]/ {pending = 1; next} pending == 1 && $1 == "fpr" {print $10; exit}')"
    cp "$HELPERS_DIR/gpg-key-expiry" "$TEST_PROJECT_ROOT/helpers/gpg-key-expiry"
    chmod +x "$TEST_PROJECT_ROOT/helpers/gpg-key-expiry"
    PRIMARY_FPR="$primary_fpr" yq -i '.build_args.EASYRSA_KEY_FPR = strenv(PRIMARY_FPR)' "$TEST_PROJECT_ROOT/openvpn/config.yaml"
    export GPG_KEYS_NOW_TS=1784332800
    export RUN_GPG_BIN
    RUN_GPG_BIN="$(command -v gpg)"

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].contract.status' <<< "$(json_output)")" = "ok" ]
    [ "$(jq -r '.[0].contract.signing_capable' <<< "$(json_output)")" = "true" ]
    [ "$(jq -r '.[0].contract.signing_usable' <<< "$(json_output)")" = "false" ]
    [ "$(jq -r '.[0].expiry.status' <<< "$(json_output)")" = "expired" ]
    [ "$(jq -r '.[0].expiry.reason' <<< "$(json_output)")" = "signing-key-expired" ]
    [ "$(jq -r '.[0].expiry.severity' <<< "$(json_output)")" = "high" ]
    [ "$(jq -r '.[0].expiry.expires' <<< "$(json_output)")" = "2024-01-01" ]
    [ "$(jq -r '.[0].expiry.fpr' <<< "$(json_output)")" = "$expired_signing_fpr" ]
}

@test "live valid EasyRSA vendored key keeps normal expiry classification when primary signer is usable" {
    if ! command -v gpg >/dev/null 2>&1; then
        skip "gpg unavailable in this environment"
    fi

    local keyfile="$TEST_PROJECT_ROOT/openvpn/easyrsa-signing-key.asc"
    cp "$PROJECT_ROOT/openvpn/easyrsa-signing-key.asc" "$keyfile"
    cp "$HELPERS_DIR/gpg-key-expiry" "$TEST_PROJECT_ROOT/helpers/gpg-key-expiry"
    chmod +x "$TEST_PROJECT_ROOT/helpers/gpg-key-expiry"

    local primary_fpr
    primary_fpr="$(gpg --batch --show-keys --with-colons "$keyfile" 2>/dev/null \
        | awk -F: '$1 == "fpr" {print $10; exit}')"
    PRIMARY_FPR="$primary_fpr" yq -i '.build_args.EASYRSA_KEY_FPR = strenv(PRIMARY_FPR)' "$TEST_PROJECT_ROOT/openvpn/config.yaml"
    export GPG_KEYS_NOW_TS=1784332800
    export RUN_GPG_BIN
    RUN_GPG_BIN="$(command -v gpg)"

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    [ "$primary_fpr" = "6F4056821152F03B6B24F2FCF8489F839D7367F3" ]
    [ "$(jq -r '.[0].contract.status' <<< "$(json_output)")" = "ok" ]
    [ "$(jq -r '.[0].contract.reason' <<< "$(json_output)")" = "valid" ]
    [ "$(jq -r '.[0].contract.primary_fpr' <<< "$(json_output)")" = "$primary_fpr" ]
    [ "$(jq -r '.[0].contract.signing_capable' <<< "$(json_output)")" = "true" ]
    [ "$(jq -r '.[0].contract.signing_usable' <<< "$(json_output)")" = "true" ]
    [ "$(jq -r '.[0].expiry.status' <<< "$(json_output)")" = "ok" ]
    [ "$(jq -r '.[0].expiry.reason' <<< "$(json_output)")" = "valid" ]
    [ "$(jq -r '.[0].expiry.severity' <<< "$(json_output)")" = "none" ]
    [ "$(jq -r '.[0].expiry.reason' <<< "$(json_output)")" != "signing-key-expired" ]
}

@test "expiry is expiring/warn when days_left is within warn_days" {
    export FAKE_EXPIRES_TS=2000000000
    export GPG_KEYS_NOW_TS=$((2000000000 - 10 * 86400))

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].expiry.status' <<< "$(json_output)")" = "expiring" ]
    [ "$(jq -r '.[0].expiry.severity' <<< "$(json_output)")" = "warn" ]
    [ "$(jq -r '.[0].expiry.days_left' <<< "$(json_output)")" = "10" ]
}

@test "expiry_warn_days with leading zero is evaluated as base 10" {
    yq -i '.dependency_sources.EASYRSA_VERSION.gpg_key.expiry_warn_days = "08"' "$TEST_PROJECT_ROOT/openvpn/config.yaml"
    export FAKE_EXPIRES_TS=2000000000
    export GPG_KEYS_NOW_TS=$((2000000000 - 5 * 86400))

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].expiry.status' <<< "$(json_output)")" = "expiring" ]
    [ "$(jq -r '.[0].expiry.severity' <<< "$(json_output)")" = "warn" ]
    [ "$(jq -r '.[0].expiry.days_left' <<< "$(json_output)")" = "5" ]
}

@test "expiry_warn_days over the maximum is a config finding without arithmetic overflow" {
    yq -i '.dependency_sources.EASYRSA_VERSION.gpg_key.expiry_warn_days = "999999999999999999999"' "$TEST_PROJECT_ROOT/openvpn/config.yaml"
    export FAKE_EXPIRES_TS=2000000000
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].config[0].reason' <<< "$(json_output)")" = "invalid-warn-days" ]
    [ "$(jq -r '.[0].config[0].value' <<< "$(json_output)")" = "999999999999999999999" ]
    [ "$(jq -r '.[0].errors[0]' <<< "$(json_output)")" = "EASYRSA_VERSION: invalid gpg_key.expiry_warn_days: 999999999999999999999" ]
}

@test "--warn-days accepts normal bounded values" {
    export FAKE_EXPIRES_TS=2000000000
    export GPG_KEYS_NOW_TS=$((2000000000 - 55 * 86400))

    run run_check openvpn --json --warn-days 60

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].expiry.status' <<< "$(json_output)")" = "expiring" ]
    [ "$(jq -r '.[0].expiry.days_left' <<< "$(json_output)")" = "55" ]
}

@test "--warn-days over the maximum is rejected with usage error" {
    run run_check openvpn --json --warn-days 999999999999

    [ "$status" -eq 2 ]
    [[ "$output" == *"usage: check-gpg-keys.sh"* ]]
}

@test "expiry is expired/high when now is past primary expiry" {
    export FAKE_EXPIRES_TS=2000000000
    export GPG_KEYS_NOW_TS=$((2000000000 + 86400))

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].expiry.status' <<< "$(json_output)")" = "expired" ]
    [ "$(jq -r '.[0].expiry.severity' <<< "$(json_output)")" = "high" ]
}

@test "expiry is ok when far before expiry" {
    export FAKE_EXPIRES_TS=2000000000
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].expiry.status' <<< "$(json_output)")" = "ok" ]
    [ "$(jq -r '.[0].expiry.severity' <<< "$(json_output)")" = "none" ]
}

@test "rotation fetches the default .sig and configured signature suffixes" {
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))
    export FAKE_GPG_VERIFY_STATUS=validsig
    export FAKE_CURL_LOG="$TEST_TEMP_DIR/curl.urls"
    export FAKE_LATEST_VERSION=4.0.0

    run run_check openvpn --json
    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].rotation.rotation' <<< "$(json_output)")" = "false" ]
    [ "$(jq -r '.[0].rotation.status' <<< "$(json_output)")" = "ok" ]
    grep -qx 'https://github.com/OpenVPN/easy-rsa/releases/download/v4.0.0/EasyRSA-4.0.0.tgz' "$FAKE_CURL_LOG"
    grep -qx 'https://github.com/OpenVPN/easy-rsa/releases/download/v4.0.0/EasyRSA-4.0.0.tgz.sig' "$FAKE_CURL_LOG"

    yq -i '.dependency_sources.EASYRSA_VERSION.gpg_key.signature_suffix = ".asc"' "$TEST_PROJECT_ROOT/openvpn/config.yaml"
    : > "$FAKE_CURL_LOG"
    run run_check openvpn --json
    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].rotation.rotation' <<< "$(json_output)")" = "false" ]
    [ "$(jq -r '.[0].rotation.status' <<< "$(json_output)")" = "ok" ]
    grep -qx 'https://github.com/OpenVPN/easy-rsa/releases/download/v4.0.0/EasyRSA-4.0.0.tgz' "$FAKE_CURL_LOG"
    grep -qx 'https://github.com/OpenVPN/easy-rsa/releases/download/v4.0.0/EasyRSA-4.0.0.tgz.asc' "$FAKE_CURL_LOG"

    export FAKE_GPG_VERIFY_STATUS=expkeysig_validsig
    run run_check openvpn --json
    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].rotation.rotation' <<< "$(json_output)")" = "false" ]
    [ "$(jq -r '.[0].rotation.status' <<< "$(json_output)")" = "ok" ]
}

@test "release asset template beginning with dash does not break basename" {
    yq -i '.dependency_sources.EASYRSA_VERSION.gpg_key.release_asset_template = "-EasyRSA-{version}.tgz"' "$TEST_PROJECT_ROOT/openvpn/config.yaml"
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))
    export FAKE_CURL_LOG="$TEST_TEMP_DIR/curl.urls"
    export FAKE_LATEST_VERSION=4.0.0

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].rotation.status' <<< "$(json_output)")" = "ok" ]
    grep -qx 'https://github.com/OpenVPN/easy-rsa/releases/download/v4.0.0/-EasyRSA-4.0.0.tgz' "$FAKE_CURL_LOG"
    grep -qx 'https://github.com/OpenVPN/easy-rsa/releases/download/v4.0.0/-EasyRSA-4.0.0.tgz.sig' "$FAKE_CURL_LOG"
}

@test "missing release templates is a high config error and does not guess asset names" {
    yq -i 'del(.dependency_sources.EASYRSA_VERSION.gpg_key.release_asset_template)' "$TEST_PROJECT_ROOT/openvpn/config.yaml"
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))
    export FAKE_CURL_LOG="$TEST_TEMP_DIR/curl.urls"

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].contract.status' <<< "$(json_output)")" = "ok" ]
    [ "$(jq -r '.[0].contract.reason' <<< "$(json_output)")" = "valid" ]
    [ "$(jq -r '.[0].rotation.reason' <<< "$(json_output)")" = "missing-release-template" ]
    [ "$(jq -r '.[0].config[0].reason' <<< "$(json_output)")" = "missing-release-template" ]
    [ ! -f "$FAKE_CURL_LOG" ]
}

@test "missing release templates do not hide a key contract mismatch" {
    yq -i 'del(.dependency_sources.EASYRSA_VERSION.gpg_key.release_asset_template)' "$TEST_PROJECT_ROOT/openvpn/config.yaml"
    export FAKE_PRIMARY_FPR=DIFFERENTFPR
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))
    export FAKE_CURL_LOG="$TEST_TEMP_DIR/curl.urls"

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].contract.status' <<< "$(json_output)")" = "error" ]
    [ "$(jq -r '.[0].contract.reason' <<< "$(json_output)")" = "key-contract-mismatch" ]
    [ "$(jq -r '.[0].contract.primary_fpr' <<< "$(json_output)")" = "DIFFERENTFPR" ]
    [ "$(jq -r '.[0].rotation.reason' <<< "$(json_output)")" = "missing-release-template" ]
    [ "$(jq -r '.[0].config[0].reason' <<< "$(json_output)")" = "missing-release-template" ]
    [ ! -f "$FAKE_CURL_LOG" ]
}

@test "a signature the vendored key cannot verify is a high error, not a rotation" {
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))
    export FAKE_GPG_VERIFY_STATUS=nopubkey

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    # NO_PUBKEY names a key id read from an unauthenticated signature packet, so
    # it says gpg could not verify with the key it holds — not that upstream
    # signed with a different one.
    [ "$(jq -r '.[0].rotation.rotation' <<< "$(json_output)")" = "false" ]
    [ "$(jq -r '.[0].rotation.status' <<< "$(json_output)")" = "error" ]
    [ "$(jq -r '.[0].rotation.reason' <<< "$(json_output)")" = "rotation-check-unavailable" ]
    [ "$(jq -r '.[0].rotation.severity' <<< "$(json_output)")" = "high" ]
}

@test "a REVKEYSIG plus VALIDSIG verification is a high error, not a rotation" {
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))
    export FAKE_GPG_VERIFY_STATUS=revkeysig_validsig

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].rotation.rotation' <<< "$(json_output)")" = "false" ]
    [ "$(jq -r '.[0].rotation.status' <<< "$(json_output)")" = "error" ]
    [ "$(jq -r '.[0].rotation.reason' <<< "$(json_output)")" = "rotation-check-unavailable" ]
    [ "$(jq -r '.[0].rotation.severity' <<< "$(json_output)")" = "high" ]
}

@test "a BADSIG verification is a high error, not a rotation" {
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))
    export FAKE_GPG_VERIFY_STATUS=badsig

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].rotation.rotation' <<< "$(json_output)")" = "false" ]
    [ "$(jq -r '.[0].rotation.status' <<< "$(json_output)")" = "error" ]
    [ "$(jq -r '.[0].rotation.reason' <<< "$(json_output)")" = "rotation-check-unavailable" ]
    [ "$(jq -r '.[0].rotation.severity' <<< "$(json_output)")" = "high" ]
}

@test "gpg output with no recognised keyword still emits a finding" {
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))
    export FAKE_GPG_VERIFY_STATUS=unrecognised

    run run_check openvpn --json

    # Under `set -euo pipefail` the summary's grep exits 1 when it matches
    # nothing, and without a guard that status aborts the function building this
    # very finding. Measured: the caller returns 1 and emits nothing at all.
    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].rotation.status' <<< "$(json_output)")" = "error" ]
    [ "$(jq -r '.[0].rotation.reason' <<< "$(json_output)")" = "rotation-check-unavailable" ]
    [[ "$(jq -r '.[0].errors | join("; ")' <<< "$(json_output)")" == *"no GnuPG status output"* ]]
}

@test "a failed verification names what gpg reported, not just that it failed" {
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))
    export FAKE_GPG_VERIFY_STATUS=badsig

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    # This reason is shared with a fetch that never completed, so the errors
    # entry is the only thing telling an operator which of the two happened.
    # Without it the issue reads "Failure detail: unknown".
    [[ "$(jq -r '.[0].errors | join("; ")' <<< "$(json_output)")" == *"signature verification failed"* ]]
    [[ "$(jq -r '.[0].errors | join("; ")' <<< "$(json_output)")" == *"BADSIG"* ]]
}

@test "an EXPSIG plus VALIDSIG verification is a high error, not a rotation" {
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))
    export FAKE_GPG_VERIFY_STATUS=expsig_validsig

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].rotation.rotation' <<< "$(json_output)")" = "false" ]
    [ "$(jq -r '.[0].rotation.status' <<< "$(json_output)")" = "error" ]
    [ "$(jq -r '.[0].rotation.reason' <<< "$(json_output)")" = "rotation-check-unavailable" ]
    [ "$(jq -r '.[0].rotation.severity' <<< "$(json_output)")" = "high" ]
}

@test "missing repo is a high rotation config error, not degraded" {
    yq -i 'del(.dependency_sources.EASYRSA_VERSION.repo)' "$TEST_PROJECT_ROOT/openvpn/config.yaml"
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].rotation.status' <<< "$(json_output)")" = "error" ]
    [ "$(jq -r '.[0].rotation.reason' <<< "$(json_output)")" = "rotation-config-unsupported" ]
    [ "$(jq -r '.[0].rotation.severity' <<< "$(json_output)")" = "high" ]
    [ "$(jq -r '.[0].errors[0]' <<< "$(json_output)")" = "EASYRSA_VERSION: rotation check requires dependency_sources.EASYRSA_VERSION.type=github-release and repo" ]
}

@test "null repo is a high rotation config error, not degraded" {
    yq -i '.dependency_sources.EASYRSA_VERSION.repo = null' "$TEST_PROJECT_ROOT/openvpn/config.yaml"
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].rotation.status' <<< "$(json_output)")" = "error" ]
    [ "$(jq -r '.[0].rotation.reason' <<< "$(json_output)")" = "rotation-config-unsupported" ]
    [ "$(jq -r '.[0].rotation.severity' <<< "$(json_output)")" = "high" ]
}

@test "missing type is a high rotation config error, not degraded" {
    yq -i 'del(.dependency_sources.EASYRSA_VERSION.type)' "$TEST_PROJECT_ROOT/openvpn/config.yaml"
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].rotation.status' <<< "$(json_output)")" = "error" ]
    [ "$(jq -r '.[0].rotation.reason' <<< "$(json_output)")" = "rotation-config-unsupported" ]
    [ "$(jq -r '.[0].rotation.severity' <<< "$(json_output)")" = "high" ]
}

@test "non github-release type is a high rotation config error, not degraded" {
    yq -i '.dependency_sources.EASYRSA_VERSION.type = "github-tags"' "$TEST_PROJECT_ROOT/openvpn/config.yaml"
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].rotation.status' <<< "$(json_output)")" = "error" ]
    [ "$(jq -r '.[0].rotation.reason' <<< "$(json_output)")" = "rotation-config-unsupported" ]
    [ "$(jq -r '.[0].rotation.severity' <<< "$(json_output)")" = "high" ]
}

@test "fetch failure is rotation-check-unavailable error and is never reported as rotation" {
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))

    local mode
    for mode in fail 404 empty; do
        export FAKE_CURL_MODE="$mode"
        run run_check openvpn --json

        [ "$status" -eq 0 ]
        [ "$(jq -r '.[0].rotation.status' <<< "$(json_output)")" = "error" ]
        [ "$(jq -r '.[0].rotation.reason' <<< "$(json_output)")" = "rotation-check-unavailable" ]
        [ "$(jq -r '.[0].rotation.rotation' <<< "$(json_output)")" = "false" ]
    done
}

@test "curl artifact fetches use bounded max-time" {
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))
    export FAKE_CURL_ARGS_LOG="$TEST_TEMP_DIR/curl.args"

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    [ "$(grep -c -- '--max-time 45' "$FAKE_CURL_ARGS_LOG")" -eq 2 ]
    [ "$(grep -c -- '--connect-timeout 15' "$FAKE_CURL_ARGS_LOG")" -eq 2 ]
    [ "$(grep -c -- '--retry 2' "$FAKE_CURL_ARGS_LOG")" -eq 2 ]
}

@test "gpg_key dependency with tag_pattern fails closed as unsupported rotation config" {
    yq -i '.dependency_sources.EASYRSA_VERSION.tag_pattern = "^v[0-9]+\\.[0-9]+\\.[0-9]+$"' "$TEST_PROJECT_ROOT/openvpn/config.yaml"
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))
    export FAKE_CURL_LOG="$TEST_TEMP_DIR/curl.urls"
    export FAKE_LATEST_ARGS_LOG="$TEST_TEMP_DIR/latest.args"

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].rotation.status' <<< "$(json_output)")" = "error" ]
    [ "$(jq -r '.[0].rotation.reason' <<< "$(json_output)")" = "rotation-tag-pattern-unsupported" ]
    [ "$(jq -r '.[0].rotation.severity' <<< "$(json_output)")" = "high" ]
    [ "$(jq -r '.[0].config[0].reason' <<< "$(json_output)")" = "rotation-tag-pattern-unsupported" ]
    [ "$(jq -r '.[0].config[0].severity' <<< "$(json_output)")" = "high" ]
    [ ! -f "$FAKE_CURL_LOG" ]
    [ ! -f "$FAKE_LATEST_ARGS_LOG" ]
}

@test "invalid gpg_key expiry_warn_days is a per-dependency config error and other containers continue" {
    add_monitored_container "another"
    yq -i '.dependency_sources.EASYRSA_VERSION.gpg_key.expiry_warn_days = "sixty"' "$TEST_PROJECT_ROOT/openvpn/config.yaml"
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))

    run run_check --all --json

    [ "$status" -eq 0 ]
    [ "$(jq 'length' <<< "$(json_output)")" -eq 2 ]
    [ "$(jq -r '.[] | select(.container == "openvpn") | .expiry.status' <<< "$(json_output)")" = "ok" ]
    [ "$(jq -r '.[] | select(.container == "openvpn") | .expiry.reason' <<< "$(json_output)")" = "valid" ]
    [ "$(jq -r '.[] | select(.container == "openvpn") | .expiry.severity' <<< "$(json_output)")" = "none" ]
    [ "$(jq -r '.[] | select(.container == "openvpn") | .config[0].reason' <<< "$(json_output)")" = "invalid-warn-days" ]
    [ "$(jq -r '.[] | select(.container == "openvpn") | .config[0].severity' <<< "$(json_output)")" = "warn" ]
    [ "$(jq -r '.[] | select(.container == "openvpn") | .contract.status' <<< "$(json_output)")" = "ok" ]
    [ "$(jq -r '.[] | select(.container == "openvpn") | .contract.reason' <<< "$(json_output)")" = "valid" ]
    [ "$(jq -r '.[] | select(.container == "openvpn") | .errors[0]' <<< "$(json_output)")" = "EASYRSA_VERSION: invalid gpg_key.expiry_warn_days: sixty" ]
    [ "$(jq -r '.[] | select(.container == "another") | .expiry.status' <<< "$(json_output)")" = "ok" ]
}

@test "invalid gpg_key expiry_warn_days emits a config warning when it is the only finding" {
    yq -i '.dependency_sources.EASYRSA_VERSION.gpg_key.expiry_warn_days = "sixty"' "$TEST_PROJECT_ROOT/openvpn/config.yaml"
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].contract.status' <<< "$(json_output)")" = "ok" ]
    [ "$(jq -r '.[0].expiry.status' <<< "$(json_output)")" = "ok" ]
    [ "$(jq -r '.[0].rotation.status' <<< "$(json_output)")" = "ok" ]
    [ "$(jq -r '.[0].config[0].reason' <<< "$(json_output)")" = "invalid-warn-days" ]
    [[ "$output" == *"::warning::gpg-key-config: openvpn/EASYRSA_VERSION: invalid-warn-days sixty"* ]]
}

@test "invalid expiry_warn_days does not hide an already-expired signing key" {
    yq -i '.dependency_sources.EASYRSA_VERSION.gpg_key.expiry_warn_days = "sixty"' "$TEST_PROJECT_ROOT/openvpn/config.yaml"
    export FAKE_EXPIRES_TS=1704067200
    export FAKE_EXPIRES_DATE=2024-01-01
    export GPG_KEYS_NOW_TS=2000000000

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].expiry.status' <<< "$(json_output)")" = "expired" ]
    [ "$(jq -r '.[0].expiry.reason' <<< "$(json_output)")" = "expired" ]
    [ "$(jq -r '.[0].expiry.severity' <<< "$(json_output)")" = "high" ]
    [ "$(jq -r '.[0].expiry.expires' <<< "$(json_output)")" = "2024-01-01" ]
    [ "$(jq -r '.[0].config[0].reason' <<< "$(json_output)")" = "invalid-warn-days" ]
    [ "$(jq -r '.[0].config[0].severity' <<< "$(json_output)")" = "warn" ]
    [ "$(jq -r '.[0].errors[0]' <<< "$(json_output)")" = "EASYRSA_VERSION: invalid gpg_key.expiry_warn_days: sixty" ]
}

@test "invalid gpg_key file with parent traversal is a high per-dependency config error" {
    yq -i '.dependency_sources.EASYRSA_VERSION.gpg_key.file = "../secret.asc"' "$TEST_PROJECT_ROOT/openvpn/config.yaml"

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].contract.status' <<< "$(json_output)")" = "error" ]
    [ "$(jq -r '.[0].contract.reason' <<< "$(json_output)")" = "key-file-invalid" ]
    [ "$(jq -r '.[0].contract.severity' <<< "$(json_output)")" = "high" ]
    [ "$(jq -r '.[0].expiry.reason' <<< "$(json_output)")" = "key-file-invalid" ]
    [ "$(jq -r '.[0].config[0].reason' <<< "$(json_output)")" = "key-file-invalid" ]
    [ "$(jq -r '.[0].errors[0]' <<< "$(json_output)")" = "EASYRSA_VERSION: invalid gpg_key.file: ../secret.asc" ]
}

@test "invalid gpg_key file with slash is rejected before path construction" {
    yq -i '.dependency_sources.EASYRSA_VERSION.gpg_key.file = "keys/easyrsa.asc"' "$TEST_PROJECT_ROOT/openvpn/config.yaml"

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].contract.reason' <<< "$(json_output)")" = "key-file-invalid" ]
    [ "$(jq -r '.[0].expiry.severity' <<< "$(json_output)")" = "high" ]
}

@test "invalid expiry_warn_days leaves contract valid and does not suppress the signature verdict" {
    yq -i '.dependency_sources.EASYRSA_VERSION.gpg_key.expiry_warn_days = "sixty"' "$TEST_PROJECT_ROOT/openvpn/config.yaml"
    export GPG_KEYS_NOW_TS=$((2000000000 - 100 * 86400))
    export FAKE_GPG_VERIFY_STATUS=nopubkey

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].contract.status' <<< "$(json_output)")" = "ok" ]
    [ "$(jq -r '.[0].contract.reason' <<< "$(json_output)")" = "valid" ]
    [ "$(jq -r '.[0].expiry.reason' <<< "$(json_output)")" = "valid" ]
    [ "$(jq -r '.[0].config[0].reason' <<< "$(json_output)")" = "invalid-warn-days" ]
    [ "$(jq -r '.[0].rotation.status' <<< "$(json_output)")" = "error" ]
    [ "$(jq -r '.[0].rotation.reason' <<< "$(json_output)")" = "rotation-check-unavailable" ]
    [ "$(jq -r '.[0].rotation.rotation' <<< "$(json_output)")" = "false" ]
}

@test "malformed config for a monitored container is surfaced as a finding" {
    printf 'dependency_sources:\n  EASYRSA_VERSION: [\n' > "$TEST_PROJECT_ROOT/openvpn/config.yaml"

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].container' <<< "$(json_output)")" = "openvpn" ]
    [ "$(jq -r '.[0].contract.status' <<< "$(json_output)")" = "error" ]
    [ "$(jq -r '.[0].contract.reason' <<< "$(json_output)")" = "config-parse-error" ]
    [ "$(jq -r '.[0].expiry.reason' <<< "$(json_output)")" = "config-parse-error" ]
}

@test "explicit scalar dependency_sources is a high config-shape-invalid finding" {
    printf 'dependency_sources: nope\n' > "$TEST_PROJECT_ROOT/openvpn/config.yaml"

    run run_check openvpn --json

    [ "$status" -eq 0 ]
    [ "$(jq 'length' <<< "$(json_output)")" -eq 1 ]
    [ "$(jq -r '.[0].container' <<< "$(json_output)")" = "openvpn" ]
    [ "$(jq -r '.[0].contract.status' <<< "$(json_output)")" = "error" ]
    [ "$(jq -r '.[0].contract.reason' <<< "$(json_output)")" = "config-shape-invalid" ]
    [ "$(jq -r '.[0].contract.severity' <<< "$(json_output)")" = "high" ]
    [ "$(jq -r '.[0].errors[0]' <<< "$(json_output)")" = "openvpn: dependency_sources in $TEST_PROJECT_ROOT/openvpn/config.yaml must be a mapping" ]
}

@test "--all includes scalar dependency_sources as a high config-shape-invalid finding" {
    printf 'dependency_sources: nope\n' > "$TEST_PROJECT_ROOT/openvpn/config.yaml"

    run run_check --all --json

    [ "$status" -eq 0 ]
    [ "$(jq 'length' <<< "$(json_output)")" -eq 1 ]
    [ "$(jq -r '.[0].container' <<< "$(json_output)")" = "openvpn" ]
    [ "$(jq -r '.[0].contract.reason' <<< "$(json_output)")" = "config-shape-invalid" ]
}

@test "explicit valid container without gpg_key is a json no-op" {
    run run_check ignored --json

    [ "$status" -eq 0 ]
    [ "$(json_output)" = "[]" ]
}

@test "explicit missing container target exits non-zero with stderr message" {
    run run_check doesnotexist

    [ "$status" -ne 0 ]
    [[ "$output" == *"no config.yaml found for target container: doesnotexist"* ]]
}

@test "explicit invalid container target is rejected before config path construction" {
    run run_check ../openvpn --json

    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid target container: ../openvpn"* ]]
}
