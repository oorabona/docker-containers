#!/usr/bin/env bash
set -Eeuo pipefail

TORRC_PATH="${TORRC_PATH:-/etc/tor/torrc}"
DATA_DIR="${DATA_DIR:-/var/lib/tor}"
GENERATED_DIR="${GENERATED_DIR:-/tmp/tor}"
GENERATED_TORRC="${GENERATED_TORRC:-${GENERATED_DIR}/torrc}"
DEFAULTS_TORRC="${DEFAULTS_TORRC:-${GENERATED_DIR}/defaults-torrc}"
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

ensure_runtime_dirs() {
    mkdir -p "$GENERATED_DIR" "$DATA_DIR"

    if [[ "$(id -u)" == "0" ]]; then
        chown -R tor:tor "$GENERATED_DIR" "$DATA_DIR"
        chmod 0700 "$DATA_DIR"
        exec su-exec tor "$0" "$@"
    fi

    if [[ -w "$DATA_DIR" ]]; then
        chmod 0700 "$DATA_DIR" 2>/dev/null || warn "could not chmod ${DATA_DIR}; Tor may refuse an insecure data directory"
    else
        warn "${DATA_DIR} is not writable by $(id -un); mounted volume ownership may need correction"
    fi
}

custom_torrc_active() {
    [[ -s "$TORRC_PATH" ]]
}

non_default_simple_env_present() {
    [[ "${SOCKS_PORT:-9050}" != "9050" ]] && return 0
    [[ "${SOCKS_BIND:-0.0.0.0}" != "0.0.0.0" ]] && return 0
    [[ -n "${EXIT_NODES:-}" ]] && return 0
    [[ -n "${EXCLUDE_EXIT_NODES:-}" ]] && return 0
    [[ -n "${PASSWORD_FILE:-}" ]] && return 0
    [[ "${CONTROL_PORT_BIND:-127.0.0.1}" != "127.0.0.1" ]] && return 0
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

control_password_hash() {
    local bind_addr="$1"
    local password_file="${PASSWORD_FILE:-}"

    if [[ -n "$password_file" ]]; then
        [[ -r "$password_file" ]] || die "PASSWORD_FILE is set but is not readable: ${password_file}"

        local control_password hashed_password
        IFS= read -r control_password < "$password_file" || true
        [[ -n "$control_password" ]] || die "PASSWORD_FILE is empty: ${password_file}"

        hashed_password=$(tor --hash-password "$control_password" | awk '/^16:/ {print; exit}')
        unset control_password
        [[ -n "$hashed_password" ]] || die "failed to hash control password from PASSWORD_FILE"
        printf '%s' "$hashed_password"
        return
    fi

    if [[ "$bind_addr" != "127.0.0.1" ]]; then
        die "CONTROL_PORT_BIND=${bind_addr} requires a readable PASSWORD_FILE; refusing unauthenticated non-loopback control port"
    fi
}

write_plumbing_defaults() {
    cat > "$DEFAULTS_TORRC" <<EOF
DataDirectory ${DATA_DIR}
PidFile ${DATA_DIR}/tor.pid
Log notice stdout
EOF
}

write_simple_torrc() {
    local socks_bind="${SOCKS_BIND:-0.0.0.0}"
    local socks_port="${SOCKS_PORT:-9050}"
    local control_bind="${CONTROL_PORT_BIND:-127.0.0.1}"
    [[ -n "$control_bind" ]] || control_bind="127.0.0.1"

    local hashed_password=""
    hashed_password=$(control_password_hash "$control_bind")

    {
        echo "DataDirectory ${DATA_DIR}"
        echo "PidFile ${DATA_DIR}/tor.pid"
        echo "RunAsDaemon 0"
        echo "Log notice stdout"
        echo "SocksPort ${socks_bind}:${socks_port}"
        echo "ControlPort ${control_bind}:${CONTROL_PORT}"
        echo "CookieAuthentication 1"
        echo "CookieAuthFile ${DATA_DIR}/control_auth_cookie"
        if [[ -n "$hashed_password" ]]; then
            echo "HashedControlPassword ${hashed_password}"
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

    ensure_runtime_dirs "$@"

    if custom_torrc_active; then
        if non_default_simple_env_present; then
            warn "custom ${TORRC_PATH} is active; SOCKS/control/exit-node environment variables are ignored"
        fi
        write_plumbing_defaults
        warn_if_identity_not_persistent "$TORRC_PATH"
        exec tor -f "$TORRC_PATH" --defaults-torrc "$DEFAULTS_TORRC" "$@"
    fi

    write_simple_torrc
    exec tor -f "$GENERATED_TORRC" "$@"
}

main "$@"
