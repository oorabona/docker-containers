#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -gt 1 ]; then
    echo "usage: $0 [openvpn-image]" >&2
    exit 2
fi

image="${1:-${OPENVPN_IMAGE:-}}"
if [ -z "$image" ]; then
    echo "openvpn restart lifecycle: image ref required as argv[1] or OPENVPN_IMAGE" >&2
    exit 2
fi

suffix="${GITHUB_RUN_ID:-local}-$$-${RANDOM}"
volume="openvpn-restart-lifecycle-${suffix}"
bootstrap_container="openvpn-restart-bootstrap-${suffix}"
restart_container="openvpn-restart-existing-${suffix}"
root_baseline=""
root_listing=""
inventory_stat_format='%i|%y|%z|%a|%u|%g|%h|%F|%s|%n|%N'
# Named here rather than left to the installer default, so the client-config
# assertions can demand this exact profile instead of accepting any .ovpn.
client_name="e2e-client"
# Likewise the endpoint: the assertions cross-check the profile against it, so it
# has to be a value the test chose rather than one it read back from the profile.
endpoint="127.0.0.1"

cleanup() {
    local status=$?
    set +e
    docker rm -f "$bootstrap_container" "$restart_container" >/dev/null 2>&1
    docker volume rm -f "$volume" >/dev/null 2>&1
    if [ -n "$root_baseline" ]; then
        rm -f -- "$root_baseline"
    fi
    if [ -n "$root_listing" ]; then
        rm -f -- "$root_listing"
    fi
    return "$status"
}
trap cleanup EXIT

run_opts=(
    --cap-drop ALL
    --cap-add NET_ADMIN
    --cap-add SETUID
    --cap-add SETGID
    --security-opt no-new-privileges
    --device /dev/net/tun:/dev/net/tun
    --sysctl net.ipv4.ip_forward=1
    --sysctl net.ipv4.conf.all.forwarding=1
    --sysctl net.ipv6.conf.all.disable_ipv6=0
    --sysctl net.ipv6.conf.all.forwarding=1
)

log() {
    printf 'openvpn restart lifecycle: %s\n' "$*"
}

fail() {
    printf 'openvpn restart lifecycle: ERROR: %s\n' "$*" >&2
    exit 1
}

show_logs_tail() {
    local container="$1"

    docker logs "$container" 2>&1 | tail -80 >&2 || true
}

openvpn_server_pids() {
    local container="$1"

    docker exec "$container" sh -c '
pids=""
if command -v pgrep >/dev/null 2>&1; then
    pids=$(pgrep -x openvpn 2>/dev/null || true)
else
    for comm in /proc/[0-9]*/comm; do
        [ -r "$comm" ] || continue
        [ "$(cat "$comm" 2>/dev/null)" = openvpn ] || continue
        pid=${comm#/proc/}
        pids="${pids} ${pid%/comm}"
    done
fi

found=0
for pid in $pids; do
    cmdline=$(tr "\000" " " < "/proc/$pid/cmdline" 2>/dev/null || true)
    case "$cmdline" in
        *openvpn*--config*) printf "%s\n" "$pid"; found=1 ;;
    esac
done
[ "$found" -eq 1 ]
' 2>/dev/null
}

wait_for_openvpn() {
    local container="$1"
    local phase="$2"
    local deadline
    local pids
    local status

    deadline=$((SECONDS + 150))
    while [ "$SECONDS" -lt "$deadline" ]; do
        status="$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || true)"
        if [ "$status" != "running" ]; then
            show_logs_tail "$container"
            fail "$phase container stopped before the OpenVPN server started (state: ${status:-missing})"
        fi

        pids="$(openvpn_server_pids "$container" || true)"
        if [ -n "$pids" ]; then
            log "$phase OpenVPN server is running"
            printf 'openvpn restart lifecycle: %s server pid(s):\n%s\n' "$phase" "$pids"
            return 0
        fi

        sleep 3
    done

    show_logs_tail "$container"
    fail "$phase OpenVPN server did not start within 150s"
}

assert_no_interactive_prompt() {
    local container="$1"
    local logs

    logs="$(docker logs "$container" 2>&1 || true)"
    if printf '%s\n' "$logs" | grep -Eq 'Select an option|Welcome to the OpenVPN installer'; then
        printf '%s\n' "openvpn restart lifecycle: ERROR: restart logs show installer/menu prompt" >&2
        printf '%s\n' "$logs" | tail -80 >&2
        exit 1
    fi
}

assert_nat_masquerade() {
    local container="$1"

    # The restart path must regenerate and apply the iptables rules, else OpenVPN
    # runs but client traffic is not NATed. Assert the MASQUERADE rule is present.
    if ! docker exec "$container" iptables -t nat -S POSTROUTING 2>/dev/null | grep -q MASQUERADE; then
        show_logs_tail "$container"
        fail "restart did not apply the NAT MASQUERADE rule (client traffic would not route)"
    fi
    log "restart NAT MASQUERADE rule is applied"
}

client_config_inventory() {
    local container="$1"
    local inventory

    # The inventory covers tree membership; inode, nanosecond mtime and ctime,
    # mode, UID, GID, link count, type, size and pathname metadata; and regular-
    # file bytes. It intentionally does not cover atime or xattrs. The metadata
    # is captured before and after hashing, so a replacement during capture fails
    # even if it has the same size and hash collection sees only its new bytes.
    #
    # pipefail makes find's failure survive the pipe. Without it sort would report
    # success even when a directory could not be traversed, and the container drops
    # CAP_DAC_OVERRIDE, so an unreadable directory is reachable in practice — a scan
    # that cannot see the whole tree must fail rather than report an empty one.
    if ! inventory="$(docker exec -e INVENTORY_STAT_FORMAT="$inventory_stat_format" "$container" sh -c '
set -eu
set -o pipefail
metadata() {
    find /etc/openvpn/clients -type f -exec stat -c "$INVENTORY_STAT_FORMAT" {} + | sort
}

metadata_before=$(metadata)
hashes=$(find /etc/openvpn/clients -type f -exec sha256sum {} + | sort)
metadata_after=$(metadata)
[ "$metadata_before" = "$metadata_after" ] || {
    echo "client config metadata changed while inventorying"
    exit 1
}
printf "%s\\n%s\\n" "$metadata_after" "$hashes"
' 2>&1)"; then
        printf 'openvpn restart lifecycle: %s\n' "$inventory" >&2
        show_logs_tail "$container"
        fail "could not inventory client configs in $container"
    fi
    if [ -z "$inventory" ]; then
        show_logs_tail "$container"
        fail "client config inventory was empty in $container"
    fi

    printf '%s\n' "$inventory"
}

root_inventory() {
    local source="$1"
    local container="${2:-}"
    local inventory
    local -a command

    case "$source" in
        container)
            command=(docker exec -e INVENTORY_STAT_FORMAT="$inventory_stat_format" "$container" sh)
            ;;
        image)
            # This is only an inventory probe. It needs neither network access
            # nor write access, and must not have more privilege than needed to
            # traverse the tree it is measuring.
            command=(
                docker run --rm
                --cap-drop ALL
                --network none
                --read-only
                --security-opt no-new-privileges
                -e INVENTORY_STAT_FORMAT="$inventory_stat_format"
                --entrypoint sh
                "$image"
            )
            ;;
        *)
            fail "unknown /root inventory source: $source"
            ;;
    esac

    # Match the client-config inventory's stable-snapshot shape, but with two
    # formats rather than one, because this is the only inventory compared across
    # containers. What is returned describes content identity: type, mode, owner,
    # group, size, device major and minor, name, literal symlink target, whether
    # the link dangles, and regular-file bytes. A device node carries neither
    # bytes nor a size, so without its numbers a repointed one would compare
    # equal. Inode numbers and copy-up timestamps are not portable
    # identifiers of image content between a throwaway probe container and a
    # running one, so they are used only for the capture-race check below, inside
    # one container and one filesystem, and never reach the baseline comparison.
    # Neither format covers atime or xattrs.
    #
    # /root itself is recorded by type, mode and ownership only, so a directory
    # left group-readable fails while a timestamp does not. Its mtime and ctime
    # move whenever anything is created inside it — the install transiently
    # unpacks the easy-rsa archive through this directory — and this assertion is
    # that nothing is LEFT there, not that nothing ever passed through.
    #
    # The returned listing is captured between the two volatile walks, so
    # everything this function reports is bracketed by their equality.
    #
    # pipefail is essential here: with CAP_DAC_OVERRIDE dropped, find can emit a
    # partial nonempty listing after an unreadable directory. Its failure must make
    # this probe fail, not look like an empty or complete /root.
    if ! inventory="$("${command[@]}" -c '
set -eu
set -o pipefail
metadata() {
    root_dir=$(stat -c "$INVENTORY_STAT_FORMAT" /root) || return 1
    entries=$(find /root -mindepth 1 -exec stat -c "$INVENTORY_STAT_FORMAT" {} +) || return 1
    dangling=$(find /root -mindepth 1 -type l ! -exec test -e {} \; -print) || return 1
    printf "%s\\n%s\\n%s\\n" "$root_dir" "$entries" "$dangling" | sort
}
identity() {
    root_dir=$(stat -c "%a|%u|%g|%F|%n" /root) || return 1
    entries=$(find /root -mindepth 1 -exec stat -c "%a|%u|%g|%F|%s|%t|%T|%n|%N" {} +) || return 1
    dangling=$(find /root -mindepth 1 -type l ! -exec test -e {} \; -print) || return 1
    printf "%s\\n%s\\n%s\\n" "$root_dir" "$entries" "$dangling" | sort
}

metadata_before=$(metadata) || {
    echo "could not inventory /root metadata"
    exit 1
}
listing=$(identity) || {
    echo "could not inventory /root"
    exit 1
}
hashes=$(find /root -mindepth 1 -type f -exec sha256sum {} + | sort) || {
    echo "could not hash regular files in /root"
    exit 1
}
metadata_after=$(metadata) || {
    echo "could not inventory /root metadata after hashing"
    exit 1
}
[ "$metadata_before" = "$metadata_after" ] || {
    echo "/root metadata changed while inventorying"
    exit 1
}
printf "%s\\n%s\\n" "$listing" "$hashes"
' 2>&1)"; then
        printf '%s\n' "$inventory" >&2
        return 1
    fi

    printf '%s\n' "$inventory"
}

assert_client_configs() {
    local container="$1"
    local phase="$2"
    local out

    # This test covers where the profile lands, byte-for-byte agreement with the
    # server's own material, agreement with the server configuration, the subject
    # each certificate carries, and preservation across restart. It does not cover
    # client connectivity: nothing here completes a handshake, so CRL enforcement
    # and the server's actual use of the material it is configured with stay
    # unproved (#965).
    # A generated .ovpn embeds the client private key, so it must land on the
    # persistent /etc/openvpn volume in a root-only directory, mode 600 — not in
    # the container-local /root, which earlier builds wrote to and which is lost
    # when the container exits.
    if ! out="$(docker exec -e EXPECTED_CLIENT="$client_name" \
        -e EXPECTED_ENDPOINT="$endpoint" "$container" sh -c '
set -eu
set -o pipefail
dir=/etc/openvpn/clients
pki=/etc/openvpn/easy-rsa/pki
conf=/etc/openvpn/server.conf

# The configuration has to be safe to read before it can identify the material
# whose type is checked below; otherwise a FIFO in this role can stall the job.
[ ! -L "$conf" ] || { echo "$conf is a symlink"; exit 1; }
[ -f "$conf" ] || { echo "$conf is not a regular file"; exit 1; }

# awk rather than grep -c, because grep exits 1 when it matches nothing and that
# would either abort under set -e or need a || true that also swallows read
# errors. awk reports zero as a count and still fails on an unreadable file.
count_matching() {
    awk -v re="$1" "\$0 ~ re { n++ } END { print n + 0 }" "$2"
}
expect_one() {
    n=$(count_matching "$1" "$2")
    [ "$n" = 1 ] || { echo "$3 has $n lines matching [$1], expected exactly 1"; exit 1; }
}

expect_one "^[[:space:]]*port[[:space:]]"      "$conf" "$conf"
expect_one "^[[:space:]]*proto[[:space:]]"     "$conf" "$conf"
expect_one "^[[:space:]]*cert[[:space:]]"      "$conf" "$conf"
expect_one "^[[:space:]]*ca[[:space:]]"        "$conf" "$conf"
expect_one "^[[:space:]]*crl-verify[[:space:]]" "$conf" "$conf"
tls_crypt_pattern="^[[:space:]]*tls-crypt[[:space:]]"
if [ "$(count_matching "$tls_crypt_pattern" "$conf")" = 0 ]; then
    echo "this test covers the tls-crypt configuration; $conf does not use tls-crypt"
    exit 1
fi
expect_one "$tls_crypt_pattern" "$conf" "$conf"

port=$(sed -n "s/^[[:space:]]*port[[:space:]][[:space:]]*\([0-9][0-9]*\)[[:space:]]*\$/\1/p" "$conf")
proto=$(sed -n "s/^[[:space:]]*proto[[:space:]][[:space:]]*\([a-z][a-z0-9-]*\)[[:space:]]*\$/\1/p" "$conf")
server_cert=$(sed -n "s/^[[:space:]]*cert[[:space:]][[:space:]]*\([^[:space:]]*\)\.crt[[:space:]]*\$/\1/p" "$conf")
server_cert_file=$(sed -n "s/^[[:space:]]*cert[[:space:]][[:space:]]*\([^[:space:]]*\)[[:space:]]*\$/\1/p" "$conf")
server_ca=$(sed -n "s/^[[:space:]]*ca[[:space:]][[:space:]]*\([^[:space:]]*\)[[:space:]]*\$/\1/p" "$conf")
server_crl=$(sed -n "s/^[[:space:]]*crl-verify[[:space:]][[:space:]]*\([^[:space:]]*\)[[:space:]]*\$/\1/p" "$conf")
server_tls_crypt=$(sed -n "s/^[[:space:]]*tls-crypt[[:space:]][[:space:]]*\([^[:space:]]*\)[[:space:]]*\$/\1/p" "$conf")
[ -n "$port" ] && [ -n "$proto" ] && [ -n "$server_cert" ] && [ -n "$server_cert_file" ] && [ -n "$server_ca" ] && [ -n "$server_crl" ] && [ -n "$server_tls_crypt" ] ||
    { echo "could not read port, proto, server certificate, CA, CRL and tls-crypt key from $conf"; exit 1; }

case "$server_ca" in
    /*) ca_file="$server_ca" ;;
    *) ca_file="/etc/openvpn/$server_ca" ;;
esac
case "$server_cert_file" in
    /*) ;;
    *) server_cert_file="/etc/openvpn/$server_cert_file" ;;
esac
case "$server_crl" in
    /*) crl_file="$server_crl" ;;
    *) crl_file="/etc/openvpn/$server_crl" ;;
esac
case "$server_tls_crypt" in
    /*) tls_crypt_file="$server_tls_crypt" ;;
    *) tls_crypt_file="/etc/openvpn/$server_tls_crypt" ;;
esac

# The profile is checked for being a regular file further down, but so is every
# file it is compared against: the server does not open the client key, the issued
# certificate or the template, so any of them could be a FIFO without the server
# ever noticing, and the reads below would then block until the CI job timeout.
for src in "$ca_file" "$server_cert_file" "$crl_file" "$tls_crypt_file" /etc/openvpn/client-template.txt \
           "$conf" "$pki/ca.crt" "$pki/crl.pem" "$pki/private/$EXPECTED_CLIENT.key" "$pki/issued/$EXPECTED_CLIENT.crt"; do
    [ ! -L "$src" ] || { echo "$src is a symlink"; exit 1; }
    [ -f "$src" ] || { echo "$src is not a regular file"; exit 1; }
done

[ ! -L "$dir" ] || { echo "clients dir is a symlink"; exit 1; }
[ -d "$dir" ] || { echo "clients dir is missing"; exit 1; }

perms=$(stat -c "%a" -- "$dir")
[ "$perms" = "700" ] || { echo "clients dir mode is $perms, expected 700"; exit 1; }
owner=$(stat -c "%u" -- "$dir")
[ "$owner" = "0" ] || { echo "clients dir owner uid is $owner, expected 0"; exit 1; }

# find rather than a glob, and unfiltered: a glob skips dotfiles and nested paths,
# and a *.ovpn filter would ignore a backup or a renamed copy of the same secret.
# The bootstrap boot names the client, so the directory must hold that one profile
# and nothing else at all. The pipeline runs under pipefail, so a find that fails
# fails the scan rather than being masked by sort — the container drops
# CAP_DAC_OVERRIDE, making an untraversable directory reachable in practice, and a
# scan that cannot see the whole tree must fail rather than report an empty one.
found=$(find "$dir" -mindepth 1 | sort)

expected="$dir/$EXPECTED_CLIENT.ovpn"
if [ "$found" != "$expected" ]; then
    echo "expected exactly $expected and nothing else, found:"
    echo "$found"
    exit 1
fi

# A symlink could aim the bundle outside the volume, and a FIFO or device would
# pass every metadata check below while blocking the read that follows.
[ ! -L "$expected" ] || { echo "$expected is a symlink"; exit 1; }
[ -f "$expected" ] || { echo "$expected is not a regular file"; exit 1; }

perms=$(stat -c "%a" -- "$expected")
[ "$perms" = "600" ] || { echo "$expected mode is $perms, expected 600"; exit 1; }
owner=$(stat -c "%u" -- "$expected")
[ "$owner" = "0" ] || { echo "$expected owner uid is $owner, expected 0"; exit 1; }

# Each inline block is extracted by its own tags rather than by a line range.
# The profile schema below separately proves that these are the only inline tags
# and that each has one opening and closing line.
block() {
    awk -v tag="$1" "
        \$0 == \"<\" tag \">\"  { if (opened++) { bad=3; exit } inb=1; next }
        \$0 == \"</\" tag \">\" { if (!inb) { bad=4; exit } inb=0; closed=1; next }
        inb { print }
        END { if (bad) exit bad; if (inb || !closed) exit 5 }
    " "$expected"
}

# The server keeps every piece of material the bundle embeds, so each block is
# compared against its source instead of being parsed and judged. A byte
# comparison is both simpler and stronger than validation: it proves the bundle
# carries THIS server CA, THIS client key and THIS control-channel key — not
# merely well-formed PEM, and not another client credentials that would satisfy
# every structural and cryptographic check.
same_as() {
    block "$1" | diff -q - "$2" >/dev/null ||
        { echo "$expected <$1> block does not match $2"; exit 1; }
}

# Count tags across the complete profile rather than inferring their absence from
# the remainder comparison. This makes the profile inline structure independent
# of both the material files and the generated template.
#
# The tag pattern admits digits and underscores, not just letters and dashes.
# The inline options OpenVPN documents include pkcs12 and tls-crypt-v2, and a
# pattern that cannot see them lets exactly the block this check exists to
# reject straight through.
for tag in ca cert key tls-crypt; do
    expect_one "^<$tag>$" "$expected" "$expected"
    expect_one "^</$tag>$" "$expected" "$expected"
done
if ! awk "
    /^<\\/?[A-Za-z0-9_-]+>\$/ {
        if (\$0 !~ /^<(ca|cert|key|tls-crypt)>\$/ &&
            \$0 !~ /^<\\/(ca|cert|key|tls-crypt)>\$/) {
            print \"unexpected inline tag: \" \$0
            bad = 1
        }
    }
    END { exit bad }
" "$expected"; then
    echo "$expected has an inline tag other than ca, cert, key or tls-crypt"
    exit 1
fi

# mktemp rather than a fixed path: this runs as root while an unprivileged
# OpenVPN process is alive, and a predictable name it could pre-create as a
# symlink would turn this redirection into a write to whatever it aimed at. The
# template is spelled out rather than left to TMPDIR, so the scratch directory
# cannot land inside a tree these checks are about to make assertions on.
work=$(mktemp -d /tmp/openvpn-client-check.XXXXXX)
trap "rm -rf \"$work\"" EXIT

# easy-rsa stores an issued certificate with a human-readable dump ahead of the
# PEM, so only the PEM section is comparable. The subject is read back from this
# extracted PEM further down rather than from the dump, which is not the
# certificate and could disagree with it.
sed -n "/^-----BEGIN CERTIFICATE-----/,/^-----END CERTIFICATE-----/p" \
    "$pki/issued/$EXPECTED_CLIENT.crt" > "$work/issued.pem"

# Each material source has one expected PEM object, with only whitespace outside
# its envelope. This rejects appended objects before the profile byte-for-byte
# block comparison carries the material identity. The optional third argument
# admits non-blank lines ahead of the envelope, for the one source that has them:
# openvpn --genkey writes a three-line comment header above the static key, and
# the profile embeds the file whole. Nothing is ever admitted after the envelope,
# which is where appended material would land.
validate_single_pem() {
    source_file=$1
    expected_labels=$2
    leading_ok=${3:-}

    awk -v expected_labels="$expected_labels" -v leading_ok="$leading_ok" "
        {
            line = \$0
            if (line ~ /^-----BEGIN/) {
                begins++
                label = line
                sub(/^-----BEGIN /, \"\", label)
                sub(/-----$/, \"\", label)
                if (state != 0 || line != \"-----BEGIN \" label \"-----\" ||
                    index(\"|\" expected_labels \"|\", \"|\" label \"|\") == 0) {
                    bad = 1
                }
                begin_label = label
                state = 1
                next
            }
            if (line ~ /^-----END/) {
                ends++
                if (state != 1 || line != \"-----END \" begin_label \"-----\") {
                    bad = 1
                }
                state = 2
                next
            }
            if (line ~ /^[[:space:]]*\$/) {
                next
            }
            if (state == 0 && leading_ok != \"\" && line ~ leading_ok) {
                next
            }
            if (state == 0 || state == 2) {
                bad = 1
            }
        }
        END {
            if (begins != 1 || ends != 1 || state != 2) {
                bad = 1
            }
            exit bad
        }
    " "$source_file" || {
        echo "$source_file must contain exactly one expected PEM object and no unexpected text outside it"
        exit 1
    }
}

validate_single_pem "$ca_file" "CERTIFICATE"
validate_single_pem "$work/issued.pem" "CERTIFICATE"
validate_single_pem "$pki/private/$EXPECTED_CLIENT.key" "PRIVATE KEY|RSA PRIVATE KEY|EC PRIVATE KEY"
validate_single_pem "$tls_crypt_file" "OpenVPN Static key V1" "^#"

same_as ca        "$ca_file"
same_as key       "$pki/private/$EXPECTED_CLIENT.key"
same_as tls-crypt "$tls_crypt_file"
block cert | diff -q - "$work/issued.pem" >/dev/null ||
    { echo "$expected <cert> is not the certificate issued to $EXPECTED_CLIENT"; exit 1; }

# Both comparisons above would still pass if the PKI itself held a key that does
# not belong to its certificate, so the pair is asserted directly.
cert_pub=$(openssl x509 -noout -pubkey -in "$work/issued.pem") ||
    { echo "$expected certificate public key could not be read"; exit 1; }
key_pub=$(openssl pkey -pubout -in "$pki/private/$EXPECTED_CLIENT.key") ||
    { echo "$expected private key public part could not be derived"; exit 1; }
[ "$cert_pub" = "$key_pub" ] ||
    { echo "$expected certificate and key are not a pair"; exit 1; }

# OpenSSL treats every certificate in -CAfile as a trust anchor. The source
# schema above proves the configured CA has exactly one certificate, which must
# be the CA generated in this PKI, not merely an anchor that happens to verify
# either certificate independently.
configured_ca_fingerprint=$(openssl x509 -in "$ca_file" -noout -sha256 -fingerprint | sed "s/^[^=]*=//") ||
    { echo "could not read the configured CA certificate at $ca_file"; exit 1; }
pki_ca_fingerprint=$(openssl x509 -in "$pki/ca.crt" -noout -sha256 -fingerprint | sed "s/^[^=]*=//") ||
    { echo "could not read the PKI CA certificate at $pki/ca.crt"; exit 1; }
[ "$configured_ca_fingerprint" = "$pki_ca_fingerprint" ] || {
    echo "$ca_file has one trust anchor, but it is not this PKI CA ($pki/ca.crt)"
    exit 1
}

# Matching the PKI proves the bundle was not swapped; it cannot prove the PKI
# produced a usable certificate, and nothing else here would — the server loads
# its own certificate, never the client one. The default trust store is disabled
# so only this server CA can vouch for it, and the purpose is pinned: the server
# certificate is signed by the same CA and is rejected here, as a client would
# reject it.
openssl verify -no-CApath -no-CAstore -purpose sslclient \
    -CAfile "$ca_file" "$work/issued.pem" >/dev/null ||
    { echo "$expected client certificate does not verify against the server CA"; exit 1; }

# Verifying against the CA proves the CA signed it; it proves nothing about whose
# name it carries, and every check above passes just as well when the PKI issues
# one shared name to everything it signs. The subject is the field a client
# checks, so it is asserted directly, on the client certificate here and on the
# server certificate below. Exactly one commonName is required: a certificate
# carrying two would satisfy a match against either.
expect_cn() {   # expect_cn <certificate> <expected common name> <what it is>
    cn_subject=$(openssl x509 -noout -subject -nameopt multiline -in "$1") ||
        { echo "could not read the subject of $1"; exit 1; }
    cn_value=$(echo "$cn_subject" | sed -n "s/^[[:space:]]*commonName[[:space:]]*=[[:space:]]*//p")
    [ -n "$cn_value" ] && [ "$(echo "$cn_value" | wc -l)" -eq 1 ] ||
        { echo "$1 must carry exactly one commonName, found [$cn_value]"; exit 1; }
    [ "$cn_value" = "$2" ] || { echo "$3 is named [$cn_value], expected [$2]"; exit 1; }
}
expect_cn "$work/issued.pem" "$EXPECTED_CLIENT" "the certificate issued to $EXPECTED_CLIENT"

# The configured CRL must be byte-identical to the CRL the PKI generated during
# this run; semantic validity alone would also accept a stale CRL signed by the same CA.
cmp -s "$crl_file" "$pki/crl.pem" || {
    echo "$crl_file does not match the CRL at $pki/crl.pem generated during this run"
    exit 1
}
# Its validity window is checked like any other. This proves neither that the
# running server loads nor enforces the CRL — that needs handshake coverage and
# is tracked separately.
openssl verify -no-CApath -no-CAstore -purpose sslclient \
    -CAfile "$ca_file" -CRLfile "$crl_file" -crl_check "$work/issued.pem" >/dev/null ||
    { echo "$expected client certificate is revoked or does not verify against the server CRL"; exit 1; }

# The configured server certificate has to be usable for the server role too, and
# to carry the name the profile pins. That pin is written from the certificate
# file base (verify-x509-name, asserted below), which a client cannot check
# against anything unless the subject matches it — so the two are tied together
# here rather than each being compared only to itself.
openssl verify -no-CApath -no-CAstore -purpose sslserver \
    -CAfile "$ca_file" "$server_cert_file" >/dev/null ||
    { echo "$conf server certificate does not verify against the configured CA"; exit 1; }
expect_cn "$server_cert_file" "$server_cert" "$conf server certificate"

# The template must contain no inline material, so an extra block in both the
# template and profile cannot hide from the remainder comparison below. The tag
# pattern matches the one the profile scanner uses, digits and underscores
# included, for the same reason: a tag this cannot see is a block that hides here.
if ! awk "
    /^<\\/?[A-Za-z0-9_-]+>\$/ || /^-----BEGIN/ || /^-----END/ { bad = 1 }
    END { exit bad }
" /etc/openvpn/client-template.txt; then
    echo "/etc/openvpn/client-template.txt contains inline material"
    exit 1
fi

# Everything that is not one of the four blocks above must be exactly the template
# the installer renders for this server. Comparing the remainder rather than
# grepping for directives asserts their exact values, rejects a duplicate, a
# reordering or an empty operand, and accounts for every byte of the profile:
# only the four known blocks are stripped, so an extra inline block cannot be
# smuggled in — it stays in the remainder and fails here.
awk "
    /^<(ca|cert|key|tls-crypt)>\$/   { skip=1; next }
    /^<\\/(ca|cert|key|tls-crypt)>\$/ { skip=0; next }
    !skip
" "$expected" > "$work/rest.txt"
diff -q "$work/rest.txt" /etc/openvpn/client-template.txt >/dev/null ||
    { echo "$expected directives differ from /etc/openvpn/client-template.txt"; exit 1; }

# Matching the template proves the bundle copied it, not that the template is
# right, so the three values that depend on this deployment are cross-checked
# against the server configuration and the certificate it names — artifacts the
# comparison above is not derived from. The endpoint comes from the test, which
# chose it, rather than from anything the container produced.
# Each of these must appear once, on both sides. A second occurrence would make
# the extraction below silently yield two newline-separated values, and on the
# profile side a match anywhere is not enough: a bundle carrying both the right
# remote and a second, wrong one would satisfy a presence check while sending the
# client somewhere else.
expect_one "^[[:space:]]*remote[[:space:]]"           "$work/rest.txt" "$expected"
expect_one "^[[:space:]]*proto[[:space:]]"            "$work/rest.txt" "$expected"
expect_one "^[[:space:]]*verify-x509-name[[:space:]]" "$work/rest.txt" "$expected"

# This test installs with the defaults, which is a UDP server, and the assertion
# below compares the two protocol values directly. That equality is a property of
# UDP, not a general rule: a TCP server pairs tcp-server with tcp-client rather
# than repeating one value. Asserting the protocol this test actually exercises
# keeps the comparison honest and makes a future TCP variant fail here, where the
# pairing has to be handled, rather than pass on an accident.
[ "$proto" = "udp" ] ||
    { echo "expected a udp server in $conf, found [$proto]"; exit 1; }

expect_directive() {
    awk -v expected="$1" "
        {
            line = \$0
            sub(/^[[:space:]]*/, \"\", line)
            sub(/[[:space:]]*\$/, \"\", line)
            gsub(/[[:space:]][[:space:]]*/, \" \", line)
            if (line == expected) found = 1
        }
        END { exit !found }
    " "$work/rest.txt" ||
        { echo "$expected has no directive [$1] agreeing with $conf"; exit 1; }
}
expect_directive "proto $proto"
expect_directive "remote $EXPECTED_ENDPOINT $port"
expect_directive "verify-x509-name $server_cert name"

echo "verified $expected byte for byte against the server PKI"
' 2>&1)"; then
        printf 'openvpn restart lifecycle: %s\n' "$out" >&2
        show_logs_tail "$container"
        fail "$phase client config check failed"
    fi
    log "$phase $out"

    # Asserted separately from the listing below so the two failures do not share
    # one message. The baseline comparison catches a new entry; it cannot catch
    # this profile being written over a path the image already shipped, and this
    # is the one such path whose name the test knows. -L as well as -e, since -e
    # follows a symlink and reports a dangling one as absent.
    if ! docker exec -e EXPECTED_CLIENT="$client_name" "$container" sh -c '
set -eu
profile=/root/"$EXPECTED_CLIENT".ovpn
if [ -e "$profile" ] || [ -L "$profile" ]; then
    echo "$profile exists"
    exit 1
fi
' >&2; then
        show_logs_tail "$container"
        fail "$phase wrote the client profile to the ephemeral /root"
    fi

    root_listing="$(mktemp "${TMPDIR:-/tmp}/openvpn-root-listing.XXXXXX")"
    if ! root_inventory container "$container" > "$root_listing"; then
        show_logs_tail "$container"
        fail "$phase could not list /root completely"
    fi
    # Comparing a stable entry-and-content inventory against the image baseline
    # keeps Alpine changes out of this regression check. Both boots must leave
    # /root as the image ships it: additions, replacements, an entry whose bytes
    # or recorded fields differ, a dangling symlink made live by a generated
    # profile, or a relaxed mode or owner on the directory itself all fail here.
    # What the format does not carry it cannot compare: extended attributes, and
    # hard-link topology among entries that are otherwise identical. Neither is
    # a way to leave a generated profile behind, which is what this denies.
    if ! diff -u "$root_baseline" "$root_listing" >&2; then
        show_logs_tail "$container"
        fail "$phase left /root differing from the image baseline"
    fi
    rm -f "$root_listing"
    root_listing=""
}

pki_ca_hash() {
    local container="$1"
    local hash

    if ! hash="$(docker exec "$container" sha256sum /etc/openvpn/easy-rsa/pki/ca.crt 2>/dev/null | awk '{print $1}')"; then
        show_logs_tail "$container"
        fail "could not read generated CA certificate from $container"
    fi
    if [ -z "$hash" ]; then
        show_logs_tail "$container"
        fail "generated CA certificate hash was empty in $container"
    fi

    printf '%s\n' "$hash"
}

log "using image $image"
log "capturing image /root baseline"
root_baseline="$(mktemp "${TMPDIR:-/tmp}/openvpn-root-baseline.XXXXXX")"
if ! root_inventory image > "$root_baseline"; then
    fail "could not capture the image /root baseline"
fi
log "creating volume $volume"
docker volume create "$volume" >/dev/null

log "bootstrap boot: install and start with persisted /etc/openvpn"
docker run -d \
    --name "$bootstrap_container" \
    "${run_opts[@]}" \
    -v "$volume:/etc/openvpn" \
    -e START_EXISTING=y \
    -e AUTO_INSTALL=y \
    -e AUTO_START=y \
    -e ENDPOINT="$endpoint" \
    -e CLIENT="$client_name" \
    "$image" >/dev/null
wait_for_openvpn "$bootstrap_container" "bootstrap"

ca_before="$(pki_ca_hash "$bootstrap_container")"
log "bootstrap generated CA certificate hash: $ca_before"

assert_client_configs "$bootstrap_container" "bootstrap"
clients_before="$(client_config_inventory "$bootstrap_container")"

log "destroying bootstrap container and keeping volume"
docker rm -f "$bootstrap_container" >/dev/null

log "restart boot: start existing config non-interactively"
# AUTO_INSTALL=y is set alongside START_EXISTING=y — matching the shipped Compose
# config — to prove START_EXISTING takes precedence over AUTO_INSTALL for an
# existing config (it must start the server, not re-run the installer).
docker run -d \
    --name "$restart_container" \
    "${run_opts[@]}" \
    -v "$volume:/etc/openvpn" \
    -e START_EXISTING=y \
    -e AUTO_INSTALL=y \
    -e AUTO_START=y \
    "$image" >/dev/null
wait_for_openvpn "$restart_container" "restart"
assert_no_interactive_prompt "$restart_container"
assert_nat_masquerade "$restart_container"
ca_after="$(pki_ca_hash "$restart_container")"
if [ "$ca_before" != "$ca_after" ]; then
    fail "restart changed the persisted CA certificate hash (before: $ca_before, after: $ca_after)"
fi
log "PASS: restart preserved existing CA certificate hash"

assert_client_configs "$restart_container" "restart"
clients_after="$(client_config_inventory "$restart_container")"
if [ "$clients_before" != "$clients_after" ]; then
    printf 'openvpn restart lifecycle: before:\n%s\nafter:\n%s\n' "$clients_before" "$clients_after" >&2
    fail "restart did not leave the client configs untouched"
fi
log "PASS: restart left the client configs untouched, not dropped and rebuilt"

# Stability: guard against a start-then-exit restart. The server must still be
# running after a short settle interval, not merely have existed once.
sleep 5
wait_for_openvpn "$restart_container" "restart-stable"
assert_client_configs "$restart_container" "restart-stable"
clients_stable="$(client_config_inventory "$restart_container")"
if [ "$clients_before" != "$clients_stable" ]; then
    printf 'openvpn restart lifecycle: before:\n%s\nafter stable wait:\n%s\n' "$clients_before" "$clients_stable" >&2
    fail "restart-stable did not leave the client configs untouched"
fi
log "PASS: restart-stable left the client configs untouched, not dropped and rebuilt"

log "PASS: existing /etc/openvpn volume restarts non-interactively with START_EXISTING=y"
