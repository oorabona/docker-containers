ARG REMOTE_CR=ghcr.io/oorabona
ARG OS_IMAGE_TAG=latest

FROM ${REMOTE_CR}/library/alpine:${OS_IMAGE_TAG}

ARG FLAVOR=default
ARG TOR_VERSION
ARG LYREBIRD_VERSION
ARG NYX_VERSION

RUN : "${TOR_VERSION:?required}" "${LYREBIRD_VERSION:?required}" "${NYX_VERSION:?required}" \
    && apk add --no-cache \
        bash \
        ca-certificates \
        curl \
        lyrebird \
        su-exec \
        tini \
        tor \
    && case "${FLAVOR}" in \
        default) \
            ;; \
        monitoring) \
            apk add --no-cache nyx py3-stem \
            ;; \
        *) \
            echo "Unknown FLAVOR: ${FLAVOR}" >&2; exit 1 \
            ;; \
    esac \
    && if ! grep -q '^tor:' /etc/group; then addgroup -S tor; fi \
    && if ! id -u tor >/dev/null 2>&1; then adduser -S -D -H -h /var/lib/tor -s /sbin/nologin -G tor tor; fi \
    && mkdir -p /etc/tor /var/lib/tor /tmp/tor \
    && : > /etc/tor/torrc \
    && chown -R tor:tor /etc/tor /var/lib/tor /tmp/tor \
    && chmod 0700 /var/lib/tor

COPY --chown=tor:tor --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh

LABEL org.opencontainers.image.title="Tor" \
      org.opencontainers.image.description="Tor SOCKS proxy with relay, bridge, hidden-service, Lyrebird, and optional Nyx monitoring support" \
      org.opencontainers.image.source="https://github.com/oorabona/docker-containers" \
      org.opencontainers.image.documentation="https://oorabona.github.io/docker-containers/container/tor/" \
      org.opencontainers.image.vendor="oorabona" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${TOR_VERSION}" \
      org.opencontainers.image.flavor="${FLAVOR}"

VOLUME ["/var/lib/tor"]

USER tor

EXPOSE 9050 9001

HEALTHCHECK --interval=30s --timeout=20s --start-period=90s --retries=3 \
    CMD if [ "${CHECK:-false}" = "true" ]; then \
            curl -fsS --max-time 20 --socks5-hostname "127.0.0.1:${SOCKS_PORT:-9050}" https://check.torproject.org/api/ip | grep -q '"IsTor":true'; \
        else \
            nc -z 127.0.0.1 "${SOCKS_PORT:-9050}"; \
        fi

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["tor"]
