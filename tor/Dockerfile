ARG REMOTE_CR=ghcr.io/oorabona
ARG OS_IMAGE_TAG=latest

FROM ${REMOTE_CR}/library/alpine:${OS_IMAGE_TAG}

ARG FLAVOR=default
ARG TOR_VERSION
ARG LYREBIRD_VERSION
ARG NYX_VERSION

RUN set -eu; \
    apk_upstream_version() { \
        package="$1"; \
        installed="$(apk info -e -v "$package" 2>/dev/null | head -n 1)"; \
        if [ -z "$installed" ]; then \
            echo "Package is not installed: ${package}" >&2; \
            exit 1; \
        fi; \
        actual="$(printf '%s\n' "$installed" | sed -n "s/^${package}-\\(.*\\)-r[0-9][0-9]*$/\\1/p" | head -n 1)"; \
        if [ -z "$actual" ]; then \
            echo "Could not parse installed package version for ${package}: ${installed}" >&2; \
            exit 1; \
        fi; \
        printf '%s\n' "$actual"; \
    }; \
    warn_declared_version_drift() { \
        package="$1"; \
        declared="$2"; \
        actual="$3"; \
        if [ -n "$declared" ] && [ "$actual" != "$declared" ]; then \
            echo "WARNING: ${package} installed upstream version ${actual} differs from declared ${declared}; keeping build non-failing and recording installed version" >&2; \
        fi; \
    }; \
    : "${TOR_VERSION:?required}" "${LYREBIRD_VERSION:?required}"; \
    nyx_installed_version=""; \
    apk add --no-cache \
        bash \
        ca-certificates \
        curl \
        lyrebird \
        su-exec \
        tini \
        tor; \
    tor_installed_version="$(apk_upstream_version tor)"; \
    lyrebird_installed_version="$(apk_upstream_version lyrebird)"; \
    warn_declared_version_drift tor "$TOR_VERSION" "$tor_installed_version"; \
    warn_declared_version_drift lyrebird "$LYREBIRD_VERSION" "$lyrebird_installed_version"; \
    case "${FLAVOR}" in \
        default) \
            ;; \
        monitoring) \
            : "${NYX_VERSION:?required}"; \
            apk add --no-cache nyx py3-stem; \
            nyx_installed_version="$(apk_upstream_version nyx)"; \
            warn_declared_version_drift nyx "$NYX_VERSION" "$nyx_installed_version"; \
            ;; \
        *) \
            echo "Unknown FLAVOR: ${FLAVOR}" >&2; exit 1 \
            ;; \
    esac; \
    if ! grep -q '^tor:' /etc/group; then addgroup -S tor; fi; \
    if ! id -u tor >/dev/null 2>&1; then adduser -S -D -H -h /var/lib/tor -s /sbin/nologin -G tor tor; fi; \
    mkdir -p /etc/tor /var/lib/tor /tmp/tor /usr/local/share/tor; \
    { \
        printf 'TOR_VERSION=%s\n' "$tor_installed_version"; \
        printf 'LYREBIRD_VERSION=%s\n' "$lyrebird_installed_version"; \
        if [ -n "$nyx_installed_version" ]; then \
            printf 'NYX_VERSION=%s\n' "$nyx_installed_version"; \
        fi; \
    } > /usr/local/share/tor/package-versions.env; \
    : > /etc/tor/torrc; \
    chown -R tor:tor /etc/tor /var/lib/tor /tmp/tor /usr/local/share/tor; \
    chmod 0700 /var/lib/tor /tmp/tor

COPY --chown=tor:tor --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh

# Retained rebuilds install the current Alpine packages from the rolling base,
# so do not stamp the declared TOR_VERSION into OCI version metadata here. The
# actual installed package versions are recorded above in package-versions.env.
LABEL org.opencontainers.image.title="Tor" \
      org.opencontainers.image.description="Tor SOCKS proxy with relay, bridge, hidden-service, Lyrebird, and optional Nyx monitoring support" \
      org.opencontainers.image.source="https://github.com/oorabona/docker-containers" \
      org.opencontainers.image.documentation="https://oorabona.github.io/docker-containers/container/tor/" \
      org.opencontainers.image.vendor="oorabona" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.flavor="${FLAVOR}"

VOLUME ["/var/lib/tor"]

USER tor

EXPOSE 9050 9001

HEALTHCHECK --interval=30s --timeout=20s --start-period=90s --retries=3 \
    CMD pid_file="${DATA_DIR:-/var/lib/tor}/tor.pid"; \
        pid=""; \
        [ -s "$pid_file" ] && pid="$(cat "$pid_file" 2>/dev/null || true)"; \
        case "$pid" in ""|*[!0-9]*) tor_alive=false ;; *) kill -0 "$pid" 2>/dev/null && tor_alive=true || tor_alive=false ;; esac; \
        if [ "$tor_alive" != "true" ]; then \
            if command -v pgrep >/dev/null 2>&1; then pgrep -x tor >/dev/null || exit 1; \
            elif command -v pidof >/dev/null 2>&1; then pidof tor >/dev/null || exit 1; \
            else exit 1; fi; \
        fi; \
        torrc_path="${TORRC_PATH:-/etc/tor/torrc}"; \
        simple_torrc=true; \
        if [ -e "$torrc_path" ] && grep -qE '^[[:space:]]*[^#[:space:]]' "$torrc_path"; then simple_torrc=false; fi; \
        if [ "$simple_torrc" = "true" ] || [ "${CHECK:-false}" = "true" ]; then \
            socks_bind="${SOCKS_BIND:-0.0.0.0}"; \
            if [ "$socks_bind" = "0.0.0.0" ] || [ "$socks_bind" = "::" ]; then socks_host="127.0.0.1"; else socks_host="$socks_bind"; fi; \
            case "$socks_host" in *:*) socks_endpoint="[${socks_host}]:${SOCKS_PORT:-9050}" ;; *) socks_endpoint="${socks_host}:${SOCKS_PORT:-9050}" ;; esac; \
            if [ "${CHECK:-false}" = "true" ]; then \
                curl -fsS --max-time 20 --socks5-hostname "$socks_endpoint" https://check.torproject.org/api/ip | grep -q '"IsTor":true'; \
            else \
                nc -z "$socks_host" "${SOCKS_PORT:-9050}"; \
            fi; \
        fi

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["tor"]
