# Modern PostgreSQL Container with Extensions
# Supports dynamic extension selection via POSTGRES_EXTENSIONS environment variable
# Architecture: Multi-stage build with optimized layers

ARG VERSION=15
ARG POSTGRES_EXTENSIONS=""

# Extension versions (centralized configuration)
ARG PGVECTOR_VERSION=v0.8.0
ARG PGNET_VERSION=v0.19.3
ARG PGPARTMAN_VERSION=v5.2.4
ARG PARADEDB_VERSION=v0.17.2

FROM postgres:${VERSION} AS builder

# Re-declare extension versions for builder stage  
ARG PGVECTOR_VERSION
ARG PGNET_VERSION
ARG PGPARTMAN_VERSION
ARG PARADEDB_VERSION
ARG POSTGRES_EXTENSIONS

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

# Build pg_vector if requested
RUN if echo "${POSTGRES_EXTENSIONS}" | grep -qE "(pg_vector|vector)"; then \
    echo "Building pg_vector ${PGVECTOR_VERSION}..." && \
    git clone --branch "${PGVECTOR_VERSION}" --depth 1 https://github.com/pgvector/pgvector.git /tmp/pgvector && \
    cd /tmp/pgvector && \
    make clean && make OPTFLAGS="" && make install && \
    rm -rf /tmp/pgvector; \
else \
    echo "Skipping pg_vector"; \
fi

# Build pg_net if requested - using standard installation only
RUN if echo "${POSTGRES_EXTENSIONS}" | grep -q "pg_net"; then \
    echo "Building pg_net ${PGNET_VERSION} from source..." && \
    git clone --branch "${PGNET_VERSION}" --depth 1 https://github.com/supabase/pg_net.git /tmp/pg_net && \
    cd /tmp/pg_net && \
    make && make install && \
    rm -rf /tmp/pg_net && \
    echo "pg_net installed successfully using standard make install"; \
else \
    echo "Skipping pg_net"; \
fi

# Build pgjwt if requested
RUN if echo "${POSTGRES_EXTENSIONS}" | grep -q "pgjwt"; then \
    echo "Building pgjwt..." && \
    git clone --depth 1 https://github.com/michelp/pgjwt.git /tmp/pgjwt && \
    cd /tmp/pgjwt && \
    make install && \
    rm -rf /tmp/pgjwt; \
else \
    echo "Skipping pgjwt"; \
fi

# Build pg_partman if requested
RUN if echo "${POSTGRES_EXTENSIONS}" | grep -q "pg_partman"; then \
    echo "Building pg_partman ${PGPARTMAN_VERSION}..." && \
    git clone --branch "${PGPARTMAN_VERSION}" --depth 1 https://github.com/pgpartman/pg_partman.git /tmp/pg_partman && \
    cd /tmp/pg_partman && \
    make NO_BGW=1 install && \
    rm -rf /tmp/pg_partman; \
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
    gettext-base \
    bc \
    && rm -rf /var/lib/apt/lists/*

# Install Citus if requested
RUN if echo "${POSTGRES_EXTENSIONS}" | grep -q "citus"; then \
    echo "Installing Citus..." && \
    curl https://install.citusdata.com/community/deb.sh | bash && \
    apt-get update && \
    apt-get install -y postgresql-15-citus-13.1 && \
    rm -rf /var/lib/apt/lists/*; \
else \
    echo "Skipping Citus"; \
fi

# Install PostGIS if requested
RUN if echo "${POSTGRES_EXTENSIONS}" | grep -q "postgis"; then \
    echo "Installing PostGIS..." && \
    apt-get update && \
    apt-get install -y postgresql-15-postgis-3 postgresql-15-postgis-3-scripts && \
    rm -rf /var/lib/apt/lists/*; \
else \
    echo "Skipping PostGIS"; \
fi

# Install pg_cron if requested
RUN if echo "${POSTGRES_EXTENSIONS}" | grep -q "pg_cron"; then \
    echo "Installing pg_cron..." && \
    apt-get update && \
    apt-get install -y postgresql-15-cron && \
    rm -rf /var/lib/apt/lists/*; \
else \
    echo "Skipping pg_cron"; \
fi

# Install postgresql-contrib if requested
RUN if echo "${POSTGRES_EXTENSIONS}" | grep -qE "(pgcrypto|uuid-ossp|pg_trgm|btree_gin|btree_gist|pg_stat_statements)"; then \
    echo "Installing postgresql-contrib..." && \
    apt-get update && \
    apt-get install -y postgresql-contrib && \
    rm -rf /var/lib/apt/lists/*; \
else \
    echo "Skipping postgresql-contrib"; \
fi

# Install universally beneficial extensions (always installed)
RUN echo "Installing universal extensions..." && \
    apt-get update && \
    apt-get install -y \
        postgresql-15-hypopg \
        postgresql-15-pg-qualstats \
    && rm -rf /var/lib/apt/lists/* && \
    echo "Universal extensions installed successfully"

# Install ParadeDB from official precompiled binaries
RUN if echo "${POSTGRES_EXTENSIONS}" | grep -q "pg_search"; then \
    echo "Installing ParadeDB pg_search from official release..." && \
    apt-get update && \
    cd /tmp && \
    # Use official precompiled binary for Debian bookworm + PostgreSQL 15
    wget -q --no-check-certificate -O pg_search.deb \
       "https://github.com/paradedb/paradedb/releases/download/${PARADEDB_VERSION}/postgresql-15-pg-search_${PARADEDB_VERSION#v}-1PARADEDB-bookworm_amd64.deb" && \
    # Install with dependency resolution
    apt-get install -y ./pg_search.deb && \
    rm -f pg_search.deb && \
    rm -rf /var/lib/apt/lists/* && \
    echo "ParadeDB pg_search installed from official precompiled package"; \
else \
    echo "Skipping ParadeDB pg_search"; \
fi

# Copy configuration templates and scripts
COPY config-templates/ /etc/postgresql/config-templates/

# Environment variables for extension management
ENV POSTGRES_EXTENSION_PROFILE=""
ENV POSTGRES_MODE="single"
ENV POSTGRES_LOCALES="en_US.UTF-8,fr_FR.UTF-8"

# Copy configuration files and scripts
COPY conf/ /etc/postgresql/
COPY init/ /docker-entrypoint-initdb.d/
COPY extensions/ /etc/postgresql/extensions/
COPY scripts/docker-entrypoint.sh /usr/local/bin/custom-entrypoint.sh
COPY scripts/build-config.sh /usr/local/bin/build-config.sh

# Generate PostgreSQL configuration at BUILD TIME (not runtime)
RUN echo "🔧 Generating PostgreSQL configuration at build time..." && \
    export POSTGRES_CONFIG_DIR="/etc/postgresql/generated" && \
    mkdir -p "$POSTGRES_CONFIG_DIR" && \
    /usr/local/bin/build-config.sh build && \
    echo "✅ Configuration generated at build time in $POSTGRES_CONFIG_DIR" && \
    echo "" && \
    echo "🔧 Setting shared_preload_libraries directly in postgresql.conf..." && \
    # Read the shared_preload_libraries calculated by build-config.sh \
    SHARED_PRELOAD=$(cat /tmp/preload_libs.txt) && \
    if [ -n "$SHARED_PRELOAD" ]; then \
        echo "shared_preload_libraries = '$SHARED_PRELOAD'" >> "$POSTGRES_CONFIG_DIR/postgresql.conf" && \
        echo "✅ shared_preload_libraries set to: $SHARED_PRELOAD"; \
    else \
        echo "ℹ️  No shared_preload_libraries needed (file content: '$SHARED_PRELOAD')"; \
    fi

# Create post-startup extension activation script at BUILD TIME
RUN echo "🔧 Creating post-startup extension activation script..." && \
    SHARED_PRELOAD=$(cat /tmp/preload_libs.txt) && \
    if [ -n "$SHARED_PRELOAD" ]; then \
        echo "-- Activate extensions that require shared_preload_libraries AFTER PostgreSQL restart" > /usr/local/bin/activate-extensions.sql && \
        echo "-- Generated at build time for extensions: ${POSTGRES_EXTENSIONS}" >> /usr/local/bin/activate-extensions.sql && \
        echo "" >> /usr/local/bin/activate-extensions.sql && \
        if echo "${POSTGRES_EXTENSIONS}" | grep -q "citus"; then \
            echo "-- Create citus extension" >> /usr/local/bin/activate-extensions.sql && \
            echo "CREATE EXTENSION IF NOT EXISTS citus;" >> /usr/local/bin/activate-extensions.sql && \
            echo "SELECT 'Citus extension activated' as status;" >> /usr/local/bin/activate-extensions.sql && \
            echo "" >> /usr/local/bin/activate-extensions.sql; \
        fi && \
        if echo "${POSTGRES_EXTENSIONS}" | grep -q "pg_search"; then \
            echo "-- Create pg_search extension" >> /usr/local/bin/activate-extensions.sql && \
            echo "CREATE EXTENSION IF NOT EXISTS pg_search;" >> /usr/local/bin/activate-extensions.sql && \
            echo "SELECT 'pg_search extension activated' as status;" >> /usr/local/bin/activate-extensions.sql && \
            echo "" >> /usr/local/bin/activate-extensions.sql; \
        fi && \
        if echo "${POSTGRES_EXTENSIONS}" | grep -q "pg_net"; then \
            echo "-- Create pg_net extension" >> /usr/local/bin/activate-extensions.sql && \
            echo "CREATE EXTENSION IF NOT EXISTS pg_net;" >> /usr/local/bin/activate-extensions.sql && \
            echo "SELECT 'pg_net extension activated' as status;" >> /usr/local/bin/activate-extensions.sql && \
            echo "" >> /usr/local/bin/activate-extensions.sql; \
        fi && \
        if echo "${POSTGRES_EXTENSIONS}" | grep -q "pg_cron"; then \
            echo "-- Create pg_cron extension in postgres database" >> /usr/local/bin/activate-extensions.sql && \
            echo "CREATE EXTENSION IF NOT EXISTS dblink;" >> /usr/local/bin/activate-extensions.sql && \
            echo "SELECT dblink_exec('dbname=postgres', 'CREATE EXTENSION IF NOT EXISTS pg_cron');" >> /usr/local/bin/activate-extensions.sql && \
            echo "SELECT 'pg_cron extension activated in postgres database' as status;" >> /usr/local/bin/activate-extensions.sql && \
            echo "" >> /usr/local/bin/activate-extensions.sql; \
        fi && \
        echo "SELECT 'All shared_preload_libraries extensions activated!' as final_status;" >> /usr/local/bin/activate-extensions.sql && \
        echo "✅ Post-startup extension activation script created"; \
    else \
        echo "ℹ️  No shared_preload_libraries extensions to activate"; \
    fi

# Create configuration setup script at BUILD TIME
RUN echo "🔧 Creating configuration setup script..." && \
    echo '#!/bin/bash' > /docker-entrypoint-initdb.d/00-setup-config.sh && \
    echo 'echo "🔧 Copying pre-generated PostgreSQL configuration..."' >> /docker-entrypoint-initdb.d/00-setup-config.sh && \
    echo 'if [[ -f "/etc/postgresql/generated/postgresql.conf" ]]; then' >> /docker-entrypoint-initdb.d/00-setup-config.sh && \
    echo '    cp /etc/postgresql/generated/postgresql.conf "$PGDATA/postgresql.conf"' >> /docker-entrypoint-initdb.d/00-setup-config.sh && \
    echo '    echo "✅ Pre-generated configuration applied to $PGDATA/postgresql.conf"' >> /docker-entrypoint-initdb.d/00-setup-config.sh && \
    echo '    echo "🔄 PostgreSQL will restart with the new configuration"' >> /docker-entrypoint-initdb.d/00-setup-config.sh && \
    echo 'else' >> /docker-entrypoint-initdb.d/00-setup-config.sh && \
    echo '    echo "⚠️  Pre-generated configuration not found"' >> /docker-entrypoint-initdb.d/00-setup-config.sh && \
    echo 'fi' >> /docker-entrypoint-initdb.d/00-setup-config.sh && \
    chmod +x /docker-entrypoint-initdb.d/00-setup-config.sh && \
    echo "✅ Configuration setup script created"

# Create non-root postgres directories and set script permissions
RUN mkdir -p /var/lib/postgresql/data /var/run/postgresql \
    && chown -R postgres:postgres /var/lib/postgresql /var/run/postgresql \
    && chmod 755 /usr/local/bin/custom-entrypoint.sh \
    && chmod 755 /usr/local/bin/build-config.sh

# Health check for container status
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD pg_isready -U ${POSTGRES_USER:-postgres} -d ${POSTGRES_DB:-postgres} || exit 1

EXPOSE 5432
USER postgres

# Use custom entrypoint that handles extension profiles
ENTRYPOINT ["/usr/local/bin/custom-entrypoint.sh"]
CMD ["postgres"]
