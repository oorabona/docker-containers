# PostgreSQL Container with Extension Flavors
#
# Flavors:
#   - base:      Built-in extensions only (default)
#   - vector:    + pgvector for AI/RAG
#   - analytics: + pg_partman, hypopg, pg_qualstats
#   - full:      All extensions
#
# Usage:
#   docker build --build-arg VERSION=17-alpine --build-arg FLAVOR=vector .
#
# Extension images are pulled from registry and files are copied using COPY --from=
# Build extension images first: ./scripts/build-extensions.sh postgres

ARG VERSION=17-alpine

# ============================================================================
# Extension Image References
# These images contain pre-compiled extensions in /output/
# Override these ARGs to use different versions or registries
# ============================================================================
ARG REGISTRY=ghcr.io
ARG OWNER=oorabona

# Extension images (pulled automatically during build)
ARG EXT_PGVECTOR_IMAGE=${REGISTRY}/${OWNER}/ext-pgvector:pg17-0.8.0
ARG EXT_PG_PARTMAN_IMAGE=${REGISTRY}/${OWNER}/ext-pg_partman:pg17-5.2.4
ARG EXT_HYPOPG_IMAGE=${REGISTRY}/${OWNER}/ext-hypopg:pg17-1.4.1
ARG EXT_PG_QUALSTATS_IMAGE=${REGISTRY}/${OWNER}/ext-pg_qualstats:pg17-2.1.1

# ============================================================================
# Extension Stages - Copy from extension images
# Each stage extracts files from the corresponding extension image
# ============================================================================
FROM ${EXT_PGVECTOR_IMAGE} AS ext-pgvector
FROM ${EXT_PG_PARTMAN_IMAGE} AS ext-pg_partman
FROM ${EXT_HYPOPG_IMAGE} AS ext-hypopg
FROM ${EXT_PG_QUALSTATS_IMAGE} AS ext-pg_qualstats

# ============================================================================
# Main Image
# ============================================================================
FROM postgres:${VERSION}

# Build arguments
ARG FLAVOR=base
ARG LOCALES=
ARG SHARED_PRELOAD_LIBRARIES=pg_stat_statements

# Labels
LABEL org.opencontainers.image.title="PostgreSQL ${FLAVOR}"
LABEL org.opencontainers.image.description="PostgreSQL with ${FLAVOR} extensions"
LABEL org.opencontainers.image.vendor="oorabona"
LABEL flavor="${FLAVOR}"

# Install locales if specified
RUN if [ -n "${LOCALES}" ]; then \
        for l in ${LOCALES}; do \
            localedef -i $l -c -f UTF-8 -A /usr/share/locale/locale.alias ${l}.UTF-8; \
        done; \
    fi

# ============================================================================
# Copy extensions based on flavor
# Extensions are copied to staging directories, then installed conditionally
# ============================================================================

# pgvector - for vector/full flavors
COPY --from=ext-pgvector /output/extension/ /tmp/ext/pgvector/extension/
COPY --from=ext-pgvector /output/lib/ /tmp/ext/pgvector/lib/

# pg_partman - for analytics/full flavors
COPY --from=ext-pg_partman /output/extension/ /tmp/ext/pg_partman/extension/
COPY --from=ext-pg_partman /output/lib/ /tmp/ext/pg_partman/lib/

# hypopg - for analytics/full flavors
COPY --from=ext-hypopg /output/extension/ /tmp/ext/hypopg/extension/
COPY --from=ext-hypopg /output/lib/ /tmp/ext/hypopg/lib/

# pg_qualstats - for analytics/full flavors
COPY --from=ext-pg_qualstats /output/extension/ /tmp/ext/pg_qualstats/extension/
COPY --from=ext-pg_qualstats /output/lib/ /tmp/ext/pg_qualstats/lib/

# Install extensions based on flavor
RUN set -eux; \
    # Function to install an extension from staging
    install_ext() { \
        local ext=$1; \
        if [ -d "/tmp/ext/${ext}/extension" ]; then \
            echo "Installing extension: ${ext}"; \
            cp -v /tmp/ext/${ext}/extension/* /usr/local/share/postgresql/extension/ 2>/dev/null || true; \
            cp -v /tmp/ext/${ext}/lib/* /usr/local/lib/postgresql/ 2>/dev/null || true; \
        fi; \
    }; \
    \
    # Install extensions based on flavor
    case "${FLAVOR}" in \
        base) \
            echo "Base flavor: no compiled extensions" \
            ;; \
        vector) \
            install_ext pgvector \
            ;; \
        analytics) \
            install_ext pg_partman; \
            install_ext hypopg; \
            install_ext pg_qualstats \
            ;; \
        full) \
            install_ext pgvector; \
            install_ext pg_partman; \
            install_ext hypopg; \
            install_ext pg_qualstats \
            ;; \
        *) \
            echo "Unknown flavor: ${FLAVOR}"; \
            exit 1 \
            ;; \
    esac; \
    \
    # Cleanup staging directory
    rm -rf /tmp/ext

# Create initialization script for built-in extensions
RUN printf '%s\n' \
    '-- Initialize built-in extensions' \
    '-- These are available in standard PostgreSQL' \
    '' \
    '-- Statistics and monitoring' \
    'CREATE EXTENSION IF NOT EXISTS pg_stat_statements;' \
    '' \
    '-- Cryptography' \
    'CREATE EXTENSION IF NOT EXISTS pgcrypto;' \
    '' \
    '-- Data types' \
    'CREATE EXTENSION IF NOT EXISTS "uuid-ossp";' \
    '' \
    '-- Indexing improvements' \
    'CREATE EXTENSION IF NOT EXISTS btree_gin;' \
    'CREATE EXTENSION IF NOT EXISTS btree_gist;' \
    'CREATE EXTENSION IF NOT EXISTS pg_trgm;' \
    > /docker-entrypoint-initdb.d/00-init-extensions.sql

# Create flavor-specific initialization script
RUN case "${FLAVOR}" in \
        vector) \
            printf '%s\n' \
                '-- Vector flavor extensions' \
                'CREATE EXTENSION IF NOT EXISTS vector;' \
                > /docker-entrypoint-initdb.d/01-init-flavor.sql \
            ;; \
        analytics) \
            printf '%s\n' \
                '-- Analytics flavor extensions' \
                'CREATE EXTENSION IF NOT EXISTS pg_partman;' \
                'CREATE EXTENSION IF NOT EXISTS hypopg;' \
                'CREATE EXTENSION IF NOT EXISTS pg_qualstats;' \
                'CREATE EXTENSION IF NOT EXISTS pg_buffercache;' \
                'CREATE EXTENSION IF NOT EXISTS pg_prewarm;' \
                > /docker-entrypoint-initdb.d/01-init-flavor.sql \
            ;; \
        full) \
            printf '%s\n' \
                '-- Full flavor extensions' \
                'CREATE EXTENSION IF NOT EXISTS vector;' \
                'CREATE EXTENSION IF NOT EXISTS pg_partman;' \
                'CREATE EXTENSION IF NOT EXISTS hypopg;' \
                'CREATE EXTENSION IF NOT EXISTS pg_qualstats;' \
                'CREATE EXTENSION IF NOT EXISTS pg_buffercache;' \
                'CREATE EXTENSION IF NOT EXISTS pg_prewarm;' \
                'CREATE EXTENSION IF NOT EXISTS file_fdw;' \
                'CREATE EXTENSION IF NOT EXISTS postgres_fdw;' \
                > /docker-entrypoint-initdb.d/01-init-flavor.sql \
            ;; \
    esac

# Configure shared_preload_libraries
# This is set at container start via environment or postgresql.conf
ENV POSTGRES_SHARED_PRELOAD_LIBRARIES="${SHARED_PRELOAD_LIBRARIES}"

# Add healthcheck
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD pg_isready -U ${POSTGRES_USER:-postgres} || exit 1

# Expose standard PostgreSQL port
EXPOSE 5432

# Default command (inherited from base image)
CMD ["postgres"]
