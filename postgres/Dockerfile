# PostgreSQL with Modern Extensions - Dynamic Extension Selection
# Uses POSTGRES_EXTENSIONS environment variable (comma-separated list)
# Example: POSTGRES_EXTENSIONS="vector,pg_net,pgjwt,pg_search"

ARG VERSION=15
ARG POSTGRES_EXTENSIONS=""

# Dynamic extension versions (can be overridden via build args)
ARG PGVECTOR_VERSION=v0.8.0
ARG PGNET_VERSION=v0.19.3
ARG PGPARTMAN_VERSION=v5.2.4
ARG PARADEDB_VERSION=v0.17.2

FROM postgres:${VERSION} AS builder

# Re-declare ARG variables for builder stage
ARG PGVECTOR_VERSION=v0.8.0
ARG PGNET_VERSION=v0.19.3
ARG PGPARTMAN_VERSION=v5.2.4
ARG PARADEDB_VERSION=v0.17.2

# Build dependencies for compiling source-based extensions only
RUN apt-get update && apt-get install -y \
    build-essential \
    postgresql-server-dev-15 \
    git \
    curl \
    ca-certificates \
    pkg-config \
    libssl-dev \
    libzstd-dev \
    liblz4-dev \
    libcurl4-openssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Conditionally build pg_vector if requested
ARG POSTGRES_EXTENSIONS
RUN if echo "${POSTGRES_EXTENSIONS}" | grep -qE "(pg_vector|vector)"; then \
    echo "Building pg_vector from source..." \
    && git clone --branch "${PGVECTOR_VERSION}" --depth 1 https://github.com/pgvector/pgvector.git /tmp/pgvector \
    && cd /tmp/pgvector \
    && make clean \
    && make OPTFLAGS="" \
    && make install; \
else \
    echo "Skipping pg_vector"; \
fi

# Conditionally build pg_net if requested
RUN if echo "${POSTGRES_EXTENSIONS}" | grep -q "pg_net"; then \
    echo "Building pg_net from source..." \
    && git clone --branch "${PGNET_VERSION}" --depth 1 https://github.com/supabase/pg_net.git /tmp/pg_net \
    && cd /tmp/pg_net \
    && make install \
    && echo "Creating missing pg_net--0.19.3.sql installation script..." \
    && cp /usr/share/postgresql/15/extension/pg_net--0.19.2--0.19.3.sql /usr/share/postgresql/15/extension/pg_net--0.19.3.sql; \
else \
    echo "Skipping pg_net"; \
fi

# Conditionally build pgjwt if requested
RUN if echo "${POSTGRES_EXTENSIONS}" | grep -q "pgjwt"; then \
    echo "Building pgjwt from source..." \
    && git clone --depth 1 https://github.com/michelp/pgjwt.git /tmp/pgjwt \
    && cd /tmp/pgjwt \
    && make install; \
else \
    echo "Skipping pgjwt"; \
fi

# Conditionally build pg_partman if requested
RUN if echo "${POSTGRES_EXTENSIONS}" | grep -q "pg_partman"; then \
    echo "Building pg_partman from source..." \
    && git clone --branch "${PGPARTMAN_VERSION}" --depth 1 https://github.com/pgpartman/pg_partman.git /tmp/pg_partman \
    && cd /tmp/pg_partman \
    && make NO_BGW=1 install; \
else \
    echo "Skipping pg_partman"; \
fi

# Production runtime stage
FROM postgres:${VERSION}

# Re-declare ARG variables for final stage
ARG PGVECTOR_VERSION=v0.8.0
ARG PGNET_VERSION=v0.19.3
ARG PGPARTMAN_VERSION=v5.2.4
ARG PARADEDB_VERSION=v0.17.2
ARG POSTGRES_EXTENSIONS=""

# Copy compiled extensions from builder stage
COPY --from=builder /usr/share/postgresql/15/extension/. /usr/share/postgresql/15/extension/
COPY --from=builder /usr/lib/postgresql/15/lib/. /usr/lib/postgresql/15/lib/

# Pass POSTGRES_EXTENSIONS to runtime for conditional package installation
ARG POSTGRES_EXTENSIONS
ENV POSTGRES_EXTENSIONS=${POSTGRES_EXTENSIONS}

# Base system setup
RUN apt-get update && apt-get install -y \
    curl \
    ca-certificates \
    wget \
    gnupg \
    lsb-release \
    locales-all \
    && rm -rf /var/lib/apt/lists/*

# Conditionally add Citus repository and install Citus if requested
RUN if echo "${POSTGRES_EXTENSIONS}" | grep -q "citus"; then \
    echo "Installing Citus..." \
    && curl https://install.citusdata.com/community/deb.sh | bash \
    && apt-get update \
    && apt-get install -y postgresql-15-citus-13.1 \
    && rm -rf /var/lib/apt/lists/*; \
else \
    echo "Skipping Citus"; \
fi

# Conditionally install PostGIS if requested
RUN if echo "${POSTGRES_EXTENSIONS}" | grep -q "postgis"; then \
    echo "Installing PostGIS..." \
    && apt-get update \
    && apt-get install -y postgresql-15-postgis-3 postgresql-15-postgis-3-scripts \
    && rm -rf /var/lib/apt/lists/*; \
else \
    echo "Skipping PostGIS"; \
fi

# Conditionally install pg_cron if requested
RUN if echo "${POSTGRES_EXTENSIONS}" | grep -q "pg_cron"; then \
    echo "Installing pg_cron..." \
    && apt-get update \
    && apt-get install -y postgresql-15-cron \
    && rm -rf /var/lib/apt/lists/*; \
else \
    echo "Skipping pg_cron"; \
fi

# Conditionally install postgresql-contrib (contains many useful extensions)
RUN if echo "${POSTGRES_EXTENSIONS}" | grep -qE "(pgcrypto|uuid-ossp|pg_trgm|btree_gin|btree_gist|pg_stat_statements)"; then \
    echo "Installing postgresql-contrib for contrib extensions..." \
    && apt-get update \
    && apt-get install -y postgresql-contrib \
    && rm -rf /var/lib/apt/lists/*; \
else \
    echo "Skipping postgresql-contrib"; \
fi

# Conditionally install HypoPG (hypothetical indexes) - Universal benefit
RUN if echo "${POSTGRES_EXTENSIONS}" | grep -q "hypopg"; then \
    echo "Installing HypoPG for index optimization..." \
    && apt-get update \
    && apt-get install -y postgresql-15-hypopg \
    && rm -rf /var/lib/apt/lists/*; \
else \
    echo "Skipping HypoPG"; \
fi

# Conditionally install pg_qualstats (query predicate statistics)
RUN if echo "${POSTGRES_EXTENSIONS}" | grep -q "pg_qualstats"; then \
    echo "Installing pg_qualstats for query analysis..." \
    && apt-get update \
    && apt-get install -y postgresql-15-pg-qualstats \
    && rm -rf /var/lib/apt/lists/*; \
else \
    echo "Skipping pg_qualstats"; \
fi

# postgres_fdw is included in postgresql-contrib, so no separate installation needed

# Conditionally install ParadeDB extensions from precompiled .deb packages
RUN if echo "${POSTGRES_EXTENSIONS}" | grep -q "pg_search"; then \
    echo "Installing ParadeDB pg_search from precompiled package..." \
    && cd /tmp \
    && echo "Downloading pg_search..." \
    && wget --no-check-certificate -O pg_search.deb \
       "https://github.com/paradedb/paradedb/releases/download/${PARADEDB_VERSION}/postgresql-15-pg-search_${PARADEDB_VERSION#v}-1PARADEDB-bookworm_amd64.deb" \
    && echo "Installing pg_search..." \
    && dpkg -i pg_search.deb \
    && rm -f pg_search.deb; \
else \
    echo "Skipping ParadeDB pg_search"; \
fi

# Note: pg_analytics is not available in ParadeDB v0.17.2
RUN if echo "${POSTGRES_EXTENSIONS}" | grep -q "pg_analytics"; then \
    echo "WARNING: pg_analytics is not available in ParadeDB v0.17.2 - skipping"; \
fi

# Configure PostgreSQL for extensions at BUILD TIME
RUN echo "Configuring PostgreSQL for extensions at build time..." \
    && PRELOAD_LIBS="" \
    && if echo "${POSTGRES_EXTENSIONS}" | grep -q "citus"; then \
        PRELOAD_LIBS="${PRELOAD_LIBS:+$PRELOAD_LIBS,}citus"; \
    fi \
    && if echo "${POSTGRES_EXTENSIONS}" | grep -q "pg_cron"; then \
        PRELOAD_LIBS="${PRELOAD_LIBS:+$PRELOAD_LIBS,}pg_cron"; \
    fi \
    && if echo "${POSTGRES_EXTENSIONS}" | grep -q "pg_stat_statements"; then \
        PRELOAD_LIBS="${PRELOAD_LIBS:+$PRELOAD_LIBS,}pg_stat_statements"; \
    fi \
    && if echo "${POSTGRES_EXTENSIONS}" | grep -q "pg_search"; then \
        PRELOAD_LIBS="${PRELOAD_LIBS:+$PRELOAD_LIBS,}pg_search"; \
    fi \
    && if echo "${POSTGRES_EXTENSIONS}" | grep -q "pg_net"; then \
        PRELOAD_LIBS="${PRELOAD_LIBS:+$PRELOAD_LIBS,}pg_net"; \
    fi \
    && if echo "${POSTGRES_EXTENSIONS}" | grep -q "pg_qualstats"; then \
        PRELOAD_LIBS="${PRELOAD_LIBS:+$PRELOAD_LIBS,}pg_qualstats"; \
    fi \
    && if [ -n "$PRELOAD_LIBS" ]; then \
        echo "shared_preload_libraries = '$PRELOAD_LIBS'" >> /usr/share/postgresql/postgresql.conf.sample; \
        echo "cron.database_name = 'postgres'" >> /usr/share/postgresql/postgresql.conf.sample; \
        echo "citus.use_secondary_nodes = 'never'" >> /usr/share/postgresql/postgresql.conf.sample; \
        echo "max_prepared_transactions = 200" >> /usr/share/postgresql/postgresql.conf.sample; \
    fi \
    && if echo "${POSTGRES_EXTENSIONS}" | grep -q "pg_net"; then \
        echo "# pg_net configuration" >> /usr/share/postgresql/postgresql.conf.sample; \
        echo "pg_net.database_name = 'myapp'" >> /usr/share/postgresql/postgresql.conf.sample; \
        echo "pg_net.ttl = 300" >> /usr/share/postgresql/postgresql.conf.sample; \
        echo "pg_net.batch_size = 100" >> /usr/share/postgresql/postgresql.conf.sample; \
    fi

# Environment variables for extension management
ENV POSTGRES_EXTENSION_PROFILE=""
ENV POSTGRES_MODE="single"
ENV POSTGRES_LOCALES="en_US.UTF-8,fr_FR.UTF-8"

# Copy configuration files and scripts
COPY conf/ /etc/postgresql/
COPY init/ /docker-entrypoint-initdb.d/
COPY extensions/ /etc/postgresql/extensions/
COPY scripts/docker-entrypoint.sh /usr/local/bin/custom-entrypoint.sh

# Create non-root postgres directories
RUN mkdir -p /var/lib/postgresql/data /var/run/postgresql \
    && chown -R postgres:postgres /var/lib/postgresql /var/run/postgresql \
    && chmod 755 /usr/local/bin/custom-entrypoint.sh

# Health check for container status
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD pg_isready -U ${POSTGRES_USER:-postgres} -d ${POSTGRES_DB:-postgres} || exit 1

EXPOSE 5432
USER postgres

# Use custom entrypoint that handles extension profiles
ENTRYPOINT ["/usr/local/bin/custom-entrypoint.sh"]
CMD ["postgres"]
