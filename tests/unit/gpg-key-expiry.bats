#!/usr/bin/env bats

load "../test_helper"

setup() {
    setup_temp_dir
    export HELPER="$HELPERS_DIR/gpg-key-expiry"
    export GEN_GNUPGHOME="$TEST_TEMP_DIR/gnupg-src"
    export GPG_KEYGEN_AVAILABLE=false
    mkdir -p "$GEN_GNUPGHOME"
    chmod 700 "$GEN_GNUPGHOME"
    local probe_home="$TEST_TEMP_DIR/gnupg-probe"
    mkdir -p "$probe_home"
    chmod 700 "$probe_home"
    if command -v gpg >/dev/null 2>&1 \
        && command -v gpgconf >/dev/null 2>&1 \
        && GNUPGHOME="$probe_home" gpgconf --launch gpg-agent >/dev/null 2>&1 \
        && GNUPGHOME="$probe_home" gpg --batch --pinentry-mode loopback --passphrase '' --no-tty \
            --quiet --quick-generate-key "probe <probe@example.test>" rsa sign "1d" >/dev/null 2>&1; then
        GPG_KEYGEN_AVAILABLE=true
        GNUPGHOME="$GEN_GNUPGHOME" gpgconf --launch gpg-agent >/dev/null 2>&1 || true
    fi
}

teardown() {
    teardown_temp_dir
}

generate_key() {
    local name="$1"
    local expire_date="$2"
    local outfile="$3"

    require_live_gpg_keygen
    GNUPGHOME="$GEN_GNUPGHOME" gpg --batch --no-tty --pinentry-mode loopback --passphrase '' \
        --quiet --quick-generate-key "${name} <${name}@example.test>" rsa sign "$expire_date"
    GNUPGHOME="$GEN_GNUPGHOME" gpg --batch --no-tty --pinentry-mode loopback --passphrase '' \
        --quiet --armor --export "${name}@example.test" > "$outfile"
}

generate_key_with_encryption_subkey() {
    local name="$1"
    local expire_date="$2"
    local outfile="$3"

    generate_key "$name" "$expire_date" "$outfile"

    local fpr
    fpr="$(primary_fingerprint "$outfile")"
    GNUPGHOME="$GEN_GNUPGHOME" gpg --batch --no-tty --pinentry-mode loopback --passphrase '' \
        --quiet --quick-add-key "$fpr" rsa encrypt "$expire_date"
    GNUPGHOME="$GEN_GNUPGHOME" gpg --batch --no-tty --pinentry-mode loopback --passphrase '' \
        --quiet --armor --export "${name}@example.test" > "$outfile"
}

generate_primary_without_expiry_and_signing_subkey() {
    local name="$1"
    local subkey_expire_date="$2"
    local outfile="$3"

    generate_key "$name" "0" "$outfile"

    local fpr
    fpr="$(primary_fingerprint "$outfile")"
    GNUPGHOME="$GEN_GNUPGHOME" gpg --batch --no-tty --pinentry-mode loopback --passphrase '' \
        --quiet --quick-add-key "$fpr" rsa sign "$subkey_expire_date"
    GNUPGHOME="$GEN_GNUPGHOME" gpg --batch --no-tty --pinentry-mode loopback --passphrase '' \
        --quiet --armor --export "${name}@example.test" > "$outfile"
}

generate_key_with_signing_subkey() {
    local name="$1"
    local primary_expire_date="$2"
    local subkey_expire_date="$3"
    local outfile="$4"

    generate_key "$name" "$primary_expire_date" "$outfile"

    local fpr
    fpr="$(primary_fingerprint "$outfile")"
    GNUPGHOME="$GEN_GNUPGHOME" gpg --batch --no-tty --pinentry-mode loopback --passphrase '' \
        --quiet --quick-add-key "$fpr" rsa sign "$subkey_expire_date"
    GNUPGHOME="$GEN_GNUPGHOME" gpg --batch --no-tty --pinentry-mode loopback --passphrase '' \
        --quiet --armor --export "${name}@example.test" > "$outfile"
}

generate_key_with_expired_signing_subkey() {
    local name="$1"
    local outfile="$2"

    require_live_gpg_keygen
    GNUPGHOME="$GEN_GNUPGHOME" gpg --faked-system-time 20230101T000000 \
        --batch --no-tty --pinentry-mode loopback --passphrase '' \
        --quiet --quick-generate-key "${name} <${name}@example.test>" rsa sign "2030-01-01"

    local fpr
    fpr="$(primary_fingerprint_from_home "${name}@example.test")"
    GNUPGHOME="$GEN_GNUPGHOME" gpg --faked-system-time 20230101T000000 \
        --batch --no-tty --pinentry-mode loopback --passphrase '' \
        --quiet --quick-add-key "$fpr" rsa sign "2024-01-01"
    GNUPGHOME="$GEN_GNUPGHOME" gpg --batch --no-tty --pinentry-mode loopback --passphrase '' \
        --quiet --armor --export "${name}@example.test" > "$outfile"
}

generate_expired_primary_key() {
    local name="$1"
    local outfile="$2"

    require_live_gpg_keygen
    GNUPGHOME="$GEN_GNUPGHOME" gpg --faked-system-time 20230101T000000 \
        --batch --no-tty --pinentry-mode loopback --passphrase '' \
        --quiet --quick-generate-key "${name} <${name}@example.test>" rsa sign "2024-01-01"
    GNUPGHOME="$GEN_GNUPGHOME" gpg --batch --no-tty --pinentry-mode loopback --passphrase '' \
        --quiet --armor --export "${name}@example.test" > "$outfile"
}

generate_cert_only_key() {
    local name="$1"
    local outfile="$2"

    require_live_gpg_keygen
    GNUPGHOME="$GEN_GNUPGHOME" gpg --batch --no-tty --pinentry-mode loopback --passphrase '' \
        --quiet --quick-generate-key "${name} <${name}@example.test>" rsa cert "2030-01-01"
    GNUPGHOME="$GEN_GNUPGHOME" gpg --batch --no-tty --pinentry-mode loopback --passphrase '' \
        --quiet --armor --export "${name}@example.test" > "$outfile"
}

require_live_gpg_keygen() {
    if [[ "${GPG_KEYGEN_AVAILABLE:-false}" != "true" ]]; then
        skip "gpg key generation unavailable in this environment"
    fi
}

primary_fingerprint_from_home() {
    local uid="$1"
    GNUPGHOME="$GEN_GNUPGHOME" gpg --batch --no-tty --with-colons --list-keys "$uid" 2>/dev/null \
        | awk -F: '$1 == "fpr" {print $10; exit}'
}

primary_colon_value() {
    local keyfile="$1"
    local field="$2"
    gpg --batch --show-keys --with-colons "$keyfile" 2>/dev/null \
        | awk -F: -v field="$field" '$1 == "pub" {print $field; exit}'
}

primary_fingerprint() {
    local keyfile="$1"
    gpg --batch --show-keys --with-colons "$keyfile" 2>/dev/null \
        | awk -F: '$1 == "fpr" {print $10; exit}'
}

signing_subkey_colon_value() {
    local keyfile="$1"
    local field="$2"
    gpg --batch --show-keys --with-colons "$keyfile" 2>/dev/null \
        | awk -F: -v field="$field" '
            $1 == "sub" && $12 ~ /[sS]/ {want = 1; value = $field; next}
            want == 1 && $1 == "fpr" {print value; exit}
        '
}

signing_subkey_fingerprint() {
    local keyfile="$1"
    gpg --batch --show-keys --with-colons "$keyfile" 2>/dev/null \
        | awk -F: '
            $1 == "sub" && $12 ~ /[sS]/ {want = 1; next}
            want == 1 && $1 == "fpr" {print $10; exit}
        '
}

@test "a key with expiry set reports expires, expires_ts, no_expiry false, and primary metadata" {
    local keyfile="$TEST_TEMP_DIR/expiring.asc"
    generate_key "expiring-key" "2030-01-01" "$keyfile"

    local expected_ts expected_date primary_fpr primary_keyid
    expected_ts="$(primary_colon_value "$keyfile" 7)"
    expected_date="$(date -u -d "@${expected_ts}" +%F)"
    primary_fpr="$(primary_fingerprint "$keyfile")"
    primary_keyid="$(primary_colon_value "$keyfile" 5)"

    run "$HELPER" "$keyfile"

    [ "$status" -eq 0 ]
    [ "$(jq -r '.primary_count' <<< "$output")" = "1" ]
    [ "$(jq -r '.primary_fpr' <<< "$output")" = "$primary_fpr" ]
    [ "$(jq -r '.primary_keyid' <<< "$output")" = "$primary_keyid" ]
    [ "$(jq -r '.primary_validity' <<< "$output")" != "e" ]
    [ "$(jq -r '.signing_capable' <<< "$output")" = "true" ]
    [ "$(jq -r '.signing_usable' <<< "$output")" = "true" ]
    [ "$(jq -r '.signing_fpr' <<< "$output")" = "$primary_fpr" ]
    [ "$(jq -r '.expires_ts' <<< "$output")" = "$expected_ts" ]
    [ "$(jq -r '.expires' <<< "$output")" = "$expected_date" ]
    [ "$(jq -r '.no_expiry' <<< "$output")" = "false" ]
}

@test "a key with no expiry reports no_expiry true and null expires_ts" {
    local keyfile="$TEST_TEMP_DIR/no-expiry.asc"
    generate_key "no-expiry-key" "0" "$keyfile"

    run "$HELPER" "$keyfile"

    [ "$status" -eq 0 ]
    [ "$(jq -r '.no_expiry' <<< "$output")" = "true" ]
    [ "$(jq -r '.expires_ts' <<< "$output")" = "null" ]
    [ "$(jq -r '.expires' <<< "$output")" = "null" ]
}

@test "encryption subkeys are ignored and the primary fingerprint is reported" {
    local keyfile="$TEST_TEMP_DIR/with-subkey.asc"
    generate_key_with_encryption_subkey "subkey-primary" "2031-01-01" "$keyfile"

    local fpr
    fpr="$(primary_fingerprint "$keyfile")"

    run "$HELPER" "$keyfile"

    [ "$status" -eq 0 ]
    [ "$(jq -r '.signing_fpr' <<< "$output")" = "$fpr" ]
    [ "$(jq -r '.signing_capable' <<< "$output")" = "true" ]
    [ "$(jq -r '.signing_usable' <<< "$output")" = "true" ]
    [ "$(jq -r '.expires' <<< "$output")" = "$(date -u -d "@$(primary_colon_value "$keyfile" 7)" +%F)" ]
}

@test "active signing subkey expiry is reported when it expires before the primary" {
    local keyfile="$TEST_TEMP_DIR/signing-subkey-earlier.asc"
    generate_key_with_signing_subkey "subkey-earlier" "2033-01-01" "2032-01-01" "$keyfile"

    local expected_ts expected_fpr primary_fpr
    expected_ts="$(signing_subkey_colon_value "$keyfile" 7)"
    expected_fpr="$(signing_subkey_fingerprint "$keyfile")"
    primary_fpr="$(primary_fingerprint "$keyfile")"

    run "$HELPER" "$keyfile"

    [ "$status" -eq 0 ]
    [ "$(jq -r '.primary_fpr' <<< "$output")" = "$primary_fpr" ]
    [ "$(jq -r '.signing_capable' <<< "$output")" = "true" ]
    [ "$(jq -r '.signing_usable' <<< "$output")" = "true" ]
    [ "$(jq -r '.signing_fpr' <<< "$output")" = "$expected_fpr" ]
    [ "$(jq -r '.expires_ts' <<< "$output")" = "$expected_ts" ]
    [ "$(jq -r '.expires' <<< "$output")" = "$(date -u -d "@${expected_ts}" +%F)" ]
}

@test "signing subkey expiry is reported when primary has no expiry" {
    local keyfile="$TEST_TEMP_DIR/signing-subkey.asc"
    generate_primary_without_expiry_and_signing_subkey "subkey-signer" "2032-01-01" "$keyfile"

    local expected_ts expected_fpr
    expected_ts="$(signing_subkey_colon_value "$keyfile" 7)"
    expected_fpr="$(signing_subkey_fingerprint "$keyfile")"

    run "$HELPER" "$keyfile"

    [ "$status" -eq 0 ]
    [ "$(jq -r '.signing_fpr' <<< "$output")" = "$expected_fpr" ]
    [ "$(jq -r '.signing_capable' <<< "$output")" = "true" ]
    [ "$(jq -r '.signing_usable' <<< "$output")" = "true" ]
    [ "$(jq -r '.expires_ts' <<< "$output")" = "$expected_ts" ]
    [ "$(jq -r '.expires' <<< "$output")" = "$(date -u -d "@${expected_ts}" +%F)" ]
    [ "$(jq -r '.no_expiry' <<< "$output")" = "false" ]
}

@test "expired signing subkey is excluded and primary expiry is reported" {
    local keyfile="$TEST_TEMP_DIR/expired-signing-subkey.asc"
    generate_key_with_expired_signing_subkey "expired-subkey-signer" "$keyfile"

    local expected_ts primary_fpr
    expected_ts="$(primary_colon_value "$keyfile" 7)"
    primary_fpr="$(primary_fingerprint "$keyfile")"

    run "$HELPER" "$keyfile"

    [ "$status" -eq 0 ]
    [ "$(jq -r '.primary_fpr' <<< "$output")" = "$primary_fpr" ]
    [ "$(jq -r '.signing_capable' <<< "$output")" = "true" ]
    [ "$(jq -r '.signing_usable' <<< "$output")" = "true" ]
    [ "$(jq -r '.signing_fpr' <<< "$output")" = "$primary_fpr" ]
    [ "$(jq -r '.expires_ts' <<< "$output")" = "$expected_ts" ]
    [ "$(jq -r '.expires' <<< "$output")" = "$(date -u -d "@${expected_ts}" +%F)" ]
}

@test "already-expired primary reports the primary expiry instead of refusing" {
    local keyfile="$TEST_TEMP_DIR/expired-primary.asc"
    generate_expired_primary_key "expired-primary" "$keyfile"

    local expected_ts primary_fpr
    expected_ts="$(primary_colon_value "$keyfile" 7)"
    primary_fpr="$(primary_fingerprint "$keyfile")"

    run "$HELPER" "$keyfile"

    [ "$status" -eq 0 ]
    [ "$(jq -r '.primary_validity' <<< "$output")" = "e" ]
    [ "$(jq -r '.signing_capable' <<< "$output")" = "true" ]
    [ "$(jq -r '.signing_usable' <<< "$output")" = "false" ]
    [ "$(jq -r '.signing_fpr' <<< "$output")" = "$primary_fpr" ]
    [ "$(jq -r '.expires_ts' <<< "$output")" = "$expected_ts" ]
    [ "$(jq -r '.expires' <<< "$output")" = "$(date -u -d "@${expected_ts}" +%F)" ]
}

@test "cert-only primary still reports the primary expiry" {
    local keyfile="$TEST_TEMP_DIR/cert-only.asc"
    generate_cert_only_key "cert-only-key" "$keyfile"

    run "$HELPER" "$keyfile"

    [ "$status" -eq 0 ]
    [ "$(jq -r '.signing_fpr' <<< "$output")" = "$(primary_fingerprint "$keyfile")" ]
    [ "$(jq -r '.signing_capable' <<< "$output")" = "false" ]
    [ "$(jq -r '.signing_usable' <<< "$output")" = "false" ]
    [ "$(jq -r '.expires' <<< "$output")" = "$(date -u -d "@$(primary_colon_value "$keyfile" 7)" +%F)" ]
}

@test "missing file exits 1 with an error on stderr" {
    run "$HELPER" "$TEST_TEMP_DIR/missing.asc"

    [ "$status" -eq 1 ]
    [[ "$output" == *"key file not found"* ]]
}

@test "garbage file exits 1 with an error on stderr" {
    printf 'not a key\n' > "$TEST_TEMP_DIR/garbage.asc"

    run "$HELPER" "$TEST_TEMP_DIR/garbage.asc"

    [ "$status" -eq 1 ]
    [[ "$output" == *"failed to read key metadata"* ]]
}

@test "metadata read uses configured gpg binary and does not import" {
    local keyfile="$TEST_TEMP_DIR/fake.asc"
    local fake_gpg="$TEST_TEMP_DIR/fake-gpg"
    printf 'fake key material\n' > "$keyfile"
    cat > "$fake_gpg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do
  if [[ "$arg" == "--import" ]]; then
    echo "unexpected import" >&2
    exit 99
  fi
done
if [[ "$*" == *"--show-keys"* && "$*" == *"--with-colons"* ]]; then
  printf 'pub:-:2048:1:FAKEKEYID:1893456000::::::scSC::::::23::0:\n'
  printf 'fpr:::::::::FAKEPRIMARYFPR:\n'
  exit 0
fi
exit 98
EOF
    chmod +x "$fake_gpg"

    run env GPG_KEYS_GPG_BIN="$fake_gpg" "$HELPER" "$keyfile"

    [ "$status" -eq 0 ]
    [ "$(jq -r '.primary_fpr' <<< "$output")" = "FAKEPRIMARYFPR" ]
    [ "$(jq -r '.primary_keyid' <<< "$output")" = "FAKEKEYID" ]
    [ "$(jq -r '.signing_capable' <<< "$output")" = "true" ]
    [ "$(jq -r '.signing_usable' <<< "$output")" = "true" ]
}

@test "revoked invalid and disabled signing primaries are not signing_capable, but expired is" {
    local keyfile="$TEST_TEMP_DIR/fake.asc"
    local fake_gpg="$TEST_TEMP_DIR/fake-gpg"
    printf 'fake key material\n' > "$keyfile"
    cat > "$fake_gpg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *"--show-keys"* && "$*" == *"--with-colons"* ]]; then
  printf 'pub:%s:2048:1:FAKEKEYID:1700000000:1893456000:::::scSC::::::23::0:\n' "${FAKE_PRIMARY_VALIDITY:?}"
  printf 'fpr:::::::::FAKEPRIMARYFPR:\n'
  exit 0
fi
exit 98
EOF
    chmod +x "$fake_gpg"

    local validity
    for validity in r i d; do
        run env FAKE_PRIMARY_VALIDITY="$validity" GPG_KEYS_GPG_BIN="$fake_gpg" "$HELPER" "$keyfile"

        [ "$status" -eq 0 ]
        [ "$(jq -r '.primary_validity' <<< "$output")" = "$validity" ]
        [ "$(jq -r '.signing_capable' <<< "$output")" = "false" ]
        [ "$(jq -r '.signing_usable' <<< "$output")" = "false" ]
    done

    run env FAKE_PRIMARY_VALIDITY=e GPG_KEYS_GPG_BIN="$fake_gpg" "$HELPER" "$keyfile"

    [ "$status" -eq 0 ]
    [ "$(jq -r '.primary_validity' <<< "$output")" = "e" ]
    [ "$(jq -r '.signing_capable' <<< "$output")" = "true" ]
    [ "$(jq -r '.signing_usable' <<< "$output")" = "false" ]
}

@test "json output uses configured jq binary" {
    local keyfile="$TEST_TEMP_DIR/fake.asc"
    local fake_gpg="$TEST_TEMP_DIR/fake-gpg"
    local fake_jq="$TEST_TEMP_DIR/fake-jq"
    local jq_log="$TEST_TEMP_DIR/jq.log"
    local real_jq
    real_jq="$(command -v jq)"
    printf 'fake key material\n' > "$keyfile"
    cat > "$fake_gpg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *"--show-keys"* && "$*" == *"--with-colons"* ]]; then
  printf 'pub:-:2048:1:FAKEKEYID:1700000000:1893456000:::::scSC::::::23::0:\n'
  printf 'fpr:::::::::FAKEPRIMARYFPR:\n'
  exit 0
fi
exit 98
EOF
    chmod +x "$fake_gpg"
    cat > "$fake_jq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_JQ_LOG:?}"
exec "${REAL_JQ:?}" "$@"
EOF
    chmod +x "$fake_jq"

    run env GPG_KEYS_GPG_BIN="$fake_gpg" GPG_KEYS_JQ_BIN="$fake_jq" \
        FAKE_JQ_LOG="$jq_log" REAL_JQ="$real_jq" "$HELPER" "$keyfile"

    [ "$status" -eq 0 ]
    [ "$(jq -r '.primary_fpr' <<< "$output")" = "FAKEPRIMARYFPR" ]
    grep -q -- "-nc" "$jq_log"
}

@test "unresolvable configured jq fails closed with a clear message" {
    local keyfile="$TEST_TEMP_DIR/fake.asc"
    local fake_gpg="$TEST_TEMP_DIR/fake-gpg"
    printf 'fake key material\n' > "$keyfile"
    printf '#!/usr/bin/env bash\nexit 98\n' > "$fake_gpg"
    chmod +x "$fake_gpg"

    run env GPG_KEYS_GPG_BIN="$fake_gpg" GPG_KEYS_JQ_BIN="$TEST_TEMP_DIR/bin/missing-jq" "$HELPER" "$keyfile"

    [ "$status" -eq 1 ]
    [[ "$output" == *"unable to resolve jq; set GPG_KEYS_JQ_BIN"* ]]
}
