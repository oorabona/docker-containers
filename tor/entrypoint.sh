#!/usr/bin/env bash
set -Eeuo pipefail

TORRC_PATH="${TORRC_PATH:-/etc/tor/torrc}"
DATA_DIR="${DATA_DIR:-/var/lib/tor}"
readonly GENERATED_DIR="/tmp/tor"
readonly GENERATED_TORRC="${GENERATED_DIR}/torrc"
readonly DEFAULTS_TORRC="${GENERATED_DIR}/defaults-torrc"
CONTROL_PORT="${CONTROL_PORT:-9051}"

log() {
    printf 'tor-entrypoint: %s\n' "$*" >&2
}

warn() {
    log "WARNING: $*"
}

die() {
    log "ERROR: $*"
    exit 1
}

reject_control_chars() {
    local name="$1"
    local value="$2"

    if [[ "$value" =~ [[:cntrl:]] ]]; then
        die "${name} must not contain control characters"
    fi
}

validate_port() {
    local name="$1"
    local value="$2"
    local number

    reject_control_chars "$name" "$value"
    [[ "$value" =~ ^[0-9]+$ ]] || die "${name} must be an integer port from 1 to 65535"
    [[ "${#value}" -le 5 ]] || die "${name} must be an integer port from 1 to 65535"

    number=$((10#$value))
    (( number >= 1 && number <= 65535 )) || die "${name} must be an integer port from 1 to 65535"
}

is_ipv4_address() {
    awk -v ip="$1" '
        BEGIN {
            n = split(ip, parts, ".")
            if (n != 4) exit 1
            for (i = 1; i <= n; i++) {
                if (parts[i] !~ /^[0-9]+$/) exit 1
                if (parts[i] < 0 || parts[i] > 255) exit 1
            }
        }
    '
}

is_ipv6_address() {
    local value="$1"
    local ipv4_tail ipv6_prefix

    [[ "$value" == *:* ]] || return 1
    [[ "$value" != *:::* ]] || return 1

    if [[ "$value" == *.* ]]; then
        ipv4_tail="${value##*:}"
        ipv6_prefix="${value%:*}"
        [[ "$ipv4_tail" != "$value" ]] || return 1
        [[ "$ipv6_prefix" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
        is_ipv4_address "$ipv4_tail" || return 1
    else
        [[ "$value" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
    fi

    awk -v ip="$value" '
        function valid_ipv4(value, parts, n, i) {
            n = split(value, parts, ".")
            if (n != 4) return 0
            for (i = 1; i <= n; i++) {
                if (parts[i] !~ /^[0-9]+$/) return 0
                if (parts[i] < 0 || parts[i] > 255) return 0
            }
            return 1
        }

        BEGIN {
            tmp = ip
            if (gsub(/::/, "::", tmp) > 1) exit 1
            if (ip ~ /^:[^:]/ || ip ~ /[^:]:$/) exit 1

            compressed = index(ip, "::") > 0
            n = split(ip, parts, ":")
            groups = 0
            for (i = 1; i <= n; i++) {
                if (parts[i] == "") continue
                if (parts[i] ~ /\./) {
                    if (i != n || !valid_ipv4(parts[i])) exit 1
                    groups += 2
                    continue
                }
                if (parts[i] !~ /^[0-9A-Fa-f]{1,4}$/) exit 1
                groups++
            }

            if (compressed) {
                if (groups >= 8) exit 1
            } else if (groups != 8) {
                exit 1
            }
        }
    '
}

validate_bind_address() {
    local name="$1"
    local value="$2"

    reject_control_chars "$name" "$value"
    if is_ipv4_address "$value" || is_ipv6_address "$value"; then
        return 0
    fi

    die "${name} must be a plain IPv4 or IPv6 address"
}

validate_tor_path() {
    local name="$1"
    local value="$2"
    local segment trimmed
    local -a segments

    reject_control_chars "$name" "$value"
    [[ "$value" == /* ]] || die "${name} must be an absolute path"
    [[ "$value" != "/" ]] || die "${name} must not be the filesystem root"
    [[ "$value" =~ ^/[A-Za-z0-9._@:+-]+(/[A-Za-z0-9._@:+-]+)*/?$ ]] || die "${name} contains unsupported path characters"

    trimmed="${value%/}"
    IFS='/' read -r -a segments <<< "${trimmed#/}"
    for segment in "${segments[@]}"; do
        [[ "$segment" != "." && "$segment" != ".." ]] || die "${name} must not contain . or .. path segments"
    done
}

reject_sensitive_data_dir() {
    local value="${1%/}"
    local denied
    local allowed_data_dir="/var/lib/tor"
    local -a denied_paths=(
        /
        /etc
        /var/lib
        /tmp
        /usr
        /bin
        /sbin
        /lib
        /lib64
        /proc
        /sys
        /dev
        /root
        /boot
        /home
    )

    if [[ "$value" == "$allowed_data_dir" || "$value" == "$allowed_data_dir"/* ]]; then
        return 0
    fi

    for denied in "${denied_paths[@]}"; do
        if [[ "$value" == "$denied" || "$value" == "$denied"/* ]]; then
            die "DATA_DIR must not be a sensitive system path: ${denied}"
        fi
        if [[ "$denied" == "$value"/* ]]; then
            die "DATA_DIR must not be a parent of sensitive system path: ${denied}"
        fi
    done
}

validate_country_list() {
    local name="$1"
    local raw="$2"
    local item seen=false
    local -a parts

    [[ -z "$raw" ]] && return 0
    reject_control_chars "$name" "$raw"

    IFS=',' read -r -a parts <<< "$raw"
    for item in "${parts[@]}"; do
        item="${item//[[:space:]]/}"
        [[ -z "$item" ]] && continue
        [[ "$item" =~ ^[A-Za-z]{2}$ ]] || die "${name} must be a comma-separated list of two-letter country codes"
        seen=true
    done

    [[ "$seen" == "true" ]] || die "${name} must contain at least one two-letter country code"
}

validate_torrc_env() {
    local socks_bind="${SOCKS_BIND:-0.0.0.0}"
    local socks_port="${SOCKS_PORT:-9050}"
    local control_bind="${CONTROL_PORT_BIND:-127.0.0.1}"
    [[ -n "$control_bind" ]] || control_bind="127.0.0.1"

    validate_bind_address "SOCKS_BIND" "$socks_bind"
    validate_port "SOCKS_PORT" "$socks_port"
    validate_bind_address "CONTROL_PORT_BIND" "$control_bind"
    validate_port "CONTROL_PORT" "$CONTROL_PORT"
    validate_country_list "EXIT_NODES" "${EXIT_NODES:-}"
    validate_country_list "EXCLUDE_EXIT_NODES" "${EXCLUDE_EXIT_NODES:-}"
}

validate_runtime_paths() {
    validate_tor_path "DATA_DIR" "$DATA_DIR"
    reject_sensitive_data_dir "$DATA_DIR"
}

ensure_runtime_dirs() {
    mkdir -p "$GENERATED_DIR" "$DATA_DIR"

    if [[ "$(id -u)" == "0" ]]; then
        chown -R tor:tor "$GENERATED_DIR" "$DATA_DIR"
        chmod 0700 "$GENERATED_DIR" "$DATA_DIR"
        exec su-exec tor "$0" "$@"
    fi

    if [[ -w "$GENERATED_DIR" ]]; then
        chmod 0700 "$GENERATED_DIR" 2>/dev/null || warn "could not chmod ${GENERATED_DIR}; generated torrc files may not be private"
    else
        warn "${GENERATED_DIR} is not writable by $(id -un); generated torrc cannot be written"
    fi

    if [[ -w "$DATA_DIR" ]]; then
        chmod 0700 "$DATA_DIR" 2>/dev/null || warn "could not chmod ${DATA_DIR}; Tor may refuse an insecure data directory"
    else
        warn "${DATA_DIR} is not writable by $(id -un); mounted volume ownership may need correction"
    fi
}

custom_torrc_active() {
    [[ -e "$TORRC_PATH" ]] || return 1

    if grep -qE '^[[:space:]]*[^#[:space:]]' "$TORRC_PATH"; then
        return 0
    else
        local rc=$?
        [[ "$rc" -eq 2 ]] && die "could not read TORRC_PATH: ${TORRC_PATH}"
    fi

    return 1
}

non_default_simple_env_present() {
    [[ "${SOCKS_PORT:-9050}" != "9050" ]] && return 0
    [[ "${SOCKS_BIND:-0.0.0.0}" != "0.0.0.0" ]] && return 0
    [[ -n "${EXIT_NODES:-}" ]] && return 0
    [[ -n "${EXCLUDE_EXIT_NODES:-}" ]] && return 0
    [[ -n "${PASSWORD_FILE:-}" ]] && return 0
    [[ "${CONTROL_PORT_BIND:-127.0.0.1}" != "127.0.0.1" ]] && return 0
    [[ "${CONTROL_PORT:-9051}" != "9051" ]] && return 0
    return 1
}

render_country_list() {
    local raw="$1"
    local item out=""
    local -a parts
    IFS=',' read -r -a parts <<< "$raw"
    for item in "${parts[@]}"; do
        item="${item//[[:space:]]/}"
        [[ -z "$item" ]] && continue
        out="${out:+${out},}{${item}}"
    done
    printf '%s' "$out"
}

is_loopback_bind() {
    [[ "$1" == "127.0.0.1" || "$1" == "::1" ]]
}

require_control_auth() {
    local bind_addr="$1"
    local password_file="${PASSWORD_FILE:-}"

    if [[ -z "$password_file" ]] && ! is_loopback_bind "$bind_addr"; then
        die "CONTROL_PORT_BIND=${bind_addr} requires a readable PASSWORD_FILE; refusing unauthenticated non-loopback control port"
    fi
}

CONTROL_PASSWORD_HASH=""

load_control_password_hash() {
    local password_file="${PASSWORD_FILE:-}"
    local control_password hashed_password

    CONTROL_PASSWORD_HASH=""
    [[ -n "$password_file" ]] || return 0

    [[ -r "$password_file" ]] || die "PASSWORD_FILE is set but is not readable: ${password_file}"

    IFS= read -r control_password < "$password_file" || true
    [[ -n "$control_password" ]] || die "PASSWORD_FILE is empty: ${password_file}"

    if [[ "$control_password" =~ ^16:[0-9A-Fa-f]+$ ]]; then
        CONTROL_PASSWORD_HASH="$control_password"
        unset control_password
        return 0
    fi

    # tor(1) documents --hash-password PASSWORD, with no stdin or file input for
    # this operation. The plaintext is briefly visible in the hash helper's argv
    # to processes sharing the container PID namespace; Docker's default
    # per-container PID namespace limits that residual exposure.
    if ! hashed_password=$(tor --hash-password "$control_password" | awk '/^16:/ {print; exit}'); then
        unset control_password
        die "failed to hash control password from PASSWORD_FILE"
    fi
    unset control_password

    [[ -n "$hashed_password" ]] || die "failed to hash control password from PASSWORD_FILE"
    CONTROL_PASSWORD_HASH="$hashed_password"
}

format_tor_endpoint() {
    local bind_addr="$1"
    local port="$2"

    if [[ "$bind_addr" == *:* ]]; then
        printf '[%s]:%s' "$bind_addr" "$port"
    else
        printf '%s:%s' "$bind_addr" "$port"
    fi
}

write_plumbing_defaults() {
    rm -f "$DEFAULTS_TORRC"
    (
        umask 077
        cat > "$DEFAULTS_TORRC" <<EOF
DataDirectory ${DATA_DIR}
PidFile ${DATA_DIR}/tor.pid
Log notice stdout
EOF
    )
    chmod 0600 "$DEFAULTS_TORRC"
}

write_simple_torrc() {
    local socks_bind="${SOCKS_BIND:-0.0.0.0}"
    local socks_port="${SOCKS_PORT:-9050}"
    local control_bind="${CONTROL_PORT_BIND:-127.0.0.1}"
    [[ -n "$control_bind" ]] || control_bind="127.0.0.1"

    require_control_auth "$control_bind"
    load_control_password_hash

    local socks_endpoint control_endpoint
    socks_endpoint=$(format_tor_endpoint "$socks_bind" "$socks_port")
    control_endpoint=$(format_tor_endpoint "$control_bind" "$CONTROL_PORT")

    rm -f "$GENERATED_TORRC"
    (
        umask 077
        {
            echo "DataDirectory ${DATA_DIR}"
            echo "PidFile ${DATA_DIR}/tor.pid"
            echo "RunAsDaemon 0"
            echo "Log notice stdout"
            echo "SocksPort ${socks_endpoint}"
            echo "ControlPort ${control_endpoint}"
            echo "CookieAuthentication 1"
            echo "CookieAuthFile ${DATA_DIR}/control_auth_cookie"
            if [[ -n "$CONTROL_PASSWORD_HASH" ]]; then
                echo "HashedControlPassword ${CONTROL_PASSWORD_HASH}"
            fi

            if [[ -n "${EXIT_NODES:-}" ]]; then
                local exit_nodes
                exit_nodes=$(render_country_list "$EXIT_NODES")
                [[ -n "$exit_nodes" ]] && echo "ExitNodes ${exit_nodes}"
            fi

            if [[ -n "${EXCLUDE_EXIT_NODES:-}" ]]; then
                local exclude_exit_nodes
                exclude_exit_nodes=$(render_country_list "$EXCLUDE_EXIT_NODES")
                [[ -n "$exclude_exit_nodes" ]] && echo "ExcludeExitNodes ${exclude_exit_nodes}"
            fi
        } > "$GENERATED_TORRC"
    )
    chmod 0600 "$GENERATED_TORRC"
}

warn_if_identity_not_persistent() {
    local active_torrc="$1"

    grep -Eiq '^[[:space:]]*(HiddenServiceDir|ORPort)\b' "$active_torrc" || return 0

    local root_dev data_dev
    root_dev=$(stat -c '%d' / 2>/dev/null || true)
    data_dev=$(stat -c '%d' "$DATA_DIR" 2>/dev/null || true)

    if [[ -n "$root_dev" && -n "$data_dev" && "$root_dev" == "$data_dev" ]]; then
        warn "${DATA_DIR} does not look like a mounted volume (best-effort check). Relay, bridge, or hidden-service identity will not survive container replacement unless this path is persisted."
    fi
}

main() {
    if [[ $# -gt 0 && "${1:-}" != "tor" && "${1:0:1}" != "-" ]]; then
        exec "$@"
    fi

    if [[ "${1:-}" == "tor" ]]; then
        shift
    fi

    validate_runtime_paths
    ensure_runtime_dirs "$@"

    if custom_torrc_active; then
        if non_default_simple_env_present; then
            warn "custom ${TORRC_PATH} is active; SOCKS/control/exit-node environment variables are ignored"
        fi
        write_plumbing_defaults
        warn_if_identity_not_persistent "$TORRC_PATH"
        exec tor -f "$TORRC_PATH" --defaults-torrc "$DEFAULTS_TORRC" "$@"
    fi

    validate_torrc_env
    write_simple_torrc
    exec tor -f "$GENERATED_TORRC" "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
