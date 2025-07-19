ARG VERSION=latest
FROM postgres:${VERSION}
ARG LOCALES=

RUN for l in ${LOCALES}; do \
    localedef -i $l -c -f UTF-8 -A /usr/share/locale/locale.alias ${l}.UTF-8; \
    done

# Add healthcheck to verify PostgreSQL is ready
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD pg_isready -U ${POSTGRES_USER:-postgres} || exit 1