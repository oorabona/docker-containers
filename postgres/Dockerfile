# PostgreSQL Container with Extension Flavors
#
# Flavors:
#   - base:        Built-in extensions only (default)
#   - vector:      + pgvector for AI/RAG
#   - analytics:   + pg_partman, hypopg, pg_qualstats
#   - timeseries:  + timescaledb for time-series data
#   - distributed: + citus for horizontal scaling
#   - full:        All Alpine-compatible extensions
#
# NOTE: search flavor (ParadeDB) disabled - requires Debian for pgrx compilation
#
# Usage:
#   docker build --build-arg VERSION=17-alpine --build-arg FLAVOR=vector .
#
# Extension images are pulled from registry and files are copied using COPY --from=
# Build extension images first: ./scripts/build-extensions.sh postgres

ARG VERSION=17-alpine
ARG MAJOR_VERSION=17

# ============================================================================
# Base Image Registry
# Use cached base images from GHCR to avoid Docker Hub rate limits
# Default: ghcr.io/oorabona/postgres-base (cached from docker.io/library/postgres)
# For local builds without cache: --build-arg BASE_IMAGE=postgres
# ============================================================================
ARG BASE_IMAGE=ghcr.io/oorabona/postgres-base

# ============================================================================
# Extension Image References
# These images contain pre-compiled extensions in /output/
# Override these ARGs to use different versions or registries
# MAJOR_VERSION is used to select the correct extension version
# ============================================================================
ARG REGISTRY=ghcr.io
ARG OWNER=oorabona

# Extension versions (independent of PostgreSQL version)
ARG PGVECTOR_VERSION=0.8.1
ARG PG_PARTMAN_VERSION=5.4.0
ARG HYPOPG_VERSION=1.4.2
ARG PG_QUALSTATS_VERSION=2.1.3
ARG CITUS_VERSION=13.2.0
ARG TIMESCALEDB_VERSION=2.24.0

# Extension images (built dynamically from MAJOR_VERSION and extension version)
ARG EXT_PGVECTOR_IMAGE=${REGISTRY}/${OWNER}/ext-pgvector:pg${MAJOR_VERSION}-${PGVECTOR_VERSION}
ARG EXT_PG_PARTMAN_IMAGE=${REGISTRY}/${OWNER}/ext-pg_partman:pg${MAJOR_VERSION}-${PG_PARTMAN_VERSION}
ARG EXT_HYPOPG_IMAGE=${REGISTRY}/${OWNER}/ext-hypopg:pg${MAJOR_VERSION}-${HYPOPG_VERSION}
ARG EXT_PG_QUALSTATS_IMAGE=${REGISTRY}/${OWNER}/ext-pg_qualstats:pg${MAJOR_VERSION}-${PG_QUALSTATS_VERSION}
ARG EXT_CITUS_IMAGE=${REGISTRY}/${OWNER}/ext-citus:pg${MAJOR_VERSION}-${CITUS_VERSION}
ARG EXT_TIMESCALEDB_IMAGE=${REGISTRY}/${OWNER}/ext-timescaledb:pg${MAJOR_VERSION}-${TIMESCALEDB_VERSION}

# ============================================================================
# Extension Stages - Copy from extension images
# Each stage extracts files from the corresponding extension image
# ============================================================================
FROM ${EXT_PGVECTOR_IMAGE} AS ext-pgvector
FROM ${EXT_PG_PARTMAN_IMAGE} AS ext-pg_partman
FROM ${EXT_HYPOPG_IMAGE} AS ext-hypopg
FROM ${EXT_PG_QUALSTATS_IMAGE} AS ext-pg_qualstats
# FROM ${EXT_PARADEDB_IMAGE} AS ext-paradedb  # Disabled - requires Debian
FROM ${EXT_CITUS_IMAGE} AS ext-citus
FROM ${EXT_TIMESCALEDB_IMAGE} AS ext-timescaledb

# ============================================================================
# Main Image
# Uses cached base image from GHCR (or Docker Hub for local builds)
# ============================================================================
ARG BASE_IMAGE
ARG VERSION
FROM ${BASE_IMAGE}:${VERSION}

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

# paradedb (pg_search) - DISABLED, requires Debian/glibc for pgrx
# COPY --from=ext-paradedb /output/extension/ /tmp/ext/paradedb/extension/
# COPY --from=ext-paradedb /output/lib/ /tmp/ext/paradedb/lib/

# citus - for distributed/full flavors
COPY --from=ext-citus /output/extension/ /tmp/ext/citus/extension/
COPY --from=ext-citus /output/lib/ /tmp/ext/citus/lib/

# timescaledb - for timeseries/full flavors
COPY --from=ext-timescaledb /output/extension/ /tmp/ext/timescaledb/extension/
COPY --from=ext-timescaledb /output/lib/ /tmp/ext/timescaledb/lib/

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
        timeseries) \
            install_ext timescaledb; \
            install_ext pg_partman \
            ;; \
        distributed) \
            install_ext citus \
            ;; \
        full) \
            install_ext pgvector; \
            install_ext pg_partman; \
            install_ext hypopg; \
            install_ext pg_qualstats; \
            install_ext citus; \
            install_ext timescaledb \
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
        timeseries) \
            printf '%s\n' \
                '-- TimescaleDB flavor extensions' \
                'CREATE EXTENSION IF NOT EXISTS timescaledb;' \
                'CREATE EXTENSION IF NOT EXISTS pg_partman;' \
                'CREATE EXTENSION IF NOT EXISTS pg_buffercache;' \
                'CREATE EXTENSION IF NOT EXISTS pg_prewarm;' \
                > /docker-entrypoint-initdb.d/01-init-flavor.sql \
            ;; \
        distributed) \
            printf '%s\n' \
                '-- Citus distributed flavor extensions' \
                'CREATE EXTENSION IF NOT EXISTS citus;' \
                'CREATE EXTENSION IF NOT EXISTS pg_buffercache;' \
                'CREATE EXTENSION IF NOT EXISTS pg_prewarm;' \
                > /docker-entrypoint-initdb.d/01-init-flavor.sql \
            ;; \
        full) \
            printf '%s\n' \
                '-- Full flavor extensions (Alpine-compatible)' \
                'CREATE EXTENSION IF NOT EXISTS vector;' \
                'CREATE EXTENSION IF NOT EXISTS pg_partman;' \
                'CREATE EXTENSION IF NOT EXISTS hypopg;' \
                'CREATE EXTENSION IF NOT EXISTS pg_qualstats;' \
                'CREATE EXTENSION IF NOT EXISTS citus;' \
                'CREATE EXTENSION IF NOT EXISTS timescaledb;' \
                'CREATE EXTENSION IF NOT EXISTS pg_buffercache;' \
                'CREATE EXTENSION IF NOT EXISTS pg_prewarm;' \
                'CREATE EXTENSION IF NOT EXISTS file_fdw;' \
                'CREATE EXTENSION IF NOT EXISTS postgres_fdw;' \
                > /docker-entrypoint-initdb.d/01-init-flavor.sql \
            ;; \
    esac

# Configure shared_preload_libraries based on actually installed extensions
# Detects which extensions need preloading by checking for their .so files
# Order matters: citus must be first, then timescaledb, then others
RUN PRELOAD=""; \
    # Citus must be loaded first if present
    if [ -f /usr/local/lib/postgresql/citus.so ]; then \
        PRELOAD="citus"; \
    fi; \
    # TimescaleDB should be loaded early
    if ls /usr/local/lib/postgresql/timescaledb*.so 1>/dev/null 2>&1; then \
        PRELOAD="${PRELOAD:+$PRELOAD,}timescaledb"; \
    fi; \
    # pg_stat_statements is always available (built-in)
    PRELOAD="${PRELOAD:+$PRELOAD,}pg_stat_statements"; \
    # pg_qualstats if present
    if [ -f /usr/local/lib/postgresql/pg_qualstats.so ]; then \
        PRELOAD="${PRELOAD:+$PRELOAD,}pg_qualstats"; \
    fi; \
    echo "$PRELOAD" > /etc/postgresql-preload.conf && \
    echo "Configured shared_preload_libraries: $PRELOAD"

# Create startup script that configures shared_preload_libraries
RUN printf '%s\n' \
    '#!/bin/sh' \
    'PRELOAD=$(cat /etc/postgresql-preload.conf)' \
    'exec docker-entrypoint.sh postgres -c shared_preload_libraries="$PRELOAD" "$@"' \
    > /usr/local/bin/docker-entrypoint-wrapper.sh && \
    chmod +x /usr/local/bin/docker-entrypoint-wrapper.sh

# Add healthcheck
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD pg_isready -U ${POSTGRES_USER:-postgres} || exit 1

# Expose standard PostgreSQL port
EXPOSE 5432

# Use wrapper script that sets shared_preload_libraries
ENTRYPOINT ["/usr/local/bin/docker-entrypoint-wrapper.sh"]
CMD []
