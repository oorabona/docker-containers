# =============================================================================
# Modern PostgreSQL Container with Smart Multi-Stage Extension Strategy
# =============================================================================
# BUILD STAGE: Extensions requiring compilation (pgvector, pg_net, etc.)
# RUNTIME STAGE: Extensions available via apt packages (citus, postgis, etc.)

# =============================================================================
# BUILD STAGE: Source-compiled Extensions Only
# =============================================================================
ARG PG_BASE_VERSION
FROM postgres:${PG_BASE_VERSION} AS builder

# Build arguments for dynamic versions and configuration
ARG POSTGRES_MAJOR_VERSION
ARG PGVECTOR_VERSION
ARG PGNET_VERSION  
ARG PGPARTMAN_VERSION
ARG PARADEDB_VERSION
ARG PGJWT_VERSION
ARG POSTGRES_EXTENSIONS=""
ARG SHARED_PRELOAD_LIBRARIES=""

# Switch to root for build operations
USER root
ENV DEBIAN_FRONTEND=noninteractive

# Install build dependencies in one layer
RUN echo "🔨 Building PostgreSQL ${POSTGRES_VERSION} with extensions: ${POSTGRES_EXTENSIONS}" && \
    apt-get update && apt-get install -y --no-install-recommends \
        curl \
        wget \
        jq \
        ca-certificates \
        postgresql-contrib \
        build-essential \
        git \
        cmake \
        pkg-config \
        postgresql-server-dev-${POSTGRES_MAJOR_VERSION} \
        libcurl4-gnutls-dev \
        libssl-dev \
        libpq-dev \
        python3-dev \
        python3-pip \
    && rm -rf /var/lib/apt/lists/*

# ===========================================================================
# SOURCE-COMPILED Extensions Only (pgvector, pg_net, pgjwt, pg_partman, etc.)
# ===========================================================================
# Extensions that need to be compiled from source go in this build stage

# =============================================================================
# SIMPLIFIED: Profile transformation happens outside Docker in make script
# =============================================================================
# Copy configuration templates and scripts first
COPY config-templates/ /etc/postgresql/config-templates/
COPY extensions/ /etc/postgresql/extensions/
COPY scripts/ /usr/local/bin/

# Generate configuration using transformed POSTGRES_EXTENSIONS (from make script)
RUN mkdir -p /etc/postgresql/conf.d /etc/postgresql/generated && \
    chmod +x /usr/local/bin/build-config.sh && \
    echo "🐛 DEBUG: POSTGRES_EXTENSIONS in builder = '${POSTGRES_EXTENSIONS}'" && \
    POSTGRES_EXTENSIONS="${POSTGRES_EXTENSIONS}" \
    POSTGRES_CONFIG_DIR="/etc/postgresql/generated" \
    /usr/local/bin/build-config.sh build

# Create directories for compiled extensions
RUN mkdir -p /extensions-staging/lib /extensions-staging/extension

# --- pgvector (Vector Similarity Search) ---
RUN if echo "${POSTGRES_EXTENSIONS}" | grep -qE "(pg_vector|vector)"; then \
        echo "🔨 Building pgvector ${PGVECTOR_VERSION}..." && \
        git clone --branch v${PGVECTOR_VERSION} --depth 1 https://github.com/pgvector/pgvector.git /tmp/pgvector && \
        cd /tmp/pgvector && \
        make clean && make OPTFLAGS="" && make install && \
        cd / && rm -rf /tmp/pgvector; \
    fi

# --- pg_net (HTTP Client) ---
RUN if echo "${POSTGRES_EXTENSIONS}" | grep -q "pg_net"; then \
        echo "🔨 Building pg_net ${PGNET_VERSION}..." && \
        git clone --branch v${PGNET_VERSION} --depth 1 https://github.com/supabase/pg_net.git /tmp/pg_net && \
        cd /tmp/pg_net && \
        make && make install && \
        cd / && rm -rf /tmp/pg_net; \
    fi

# --- pgjwt (JWT Authentication) ---
RUN if echo "${POSTGRES_EXTENSIONS}" | grep -q "pgjwt"; then \
        echo "🔨 Building pgjwt ${PGJWT_VERSION}..." && \
        git clone --depth 1 https://github.com/michelp/pgjwt.git /tmp/pgjwt && \
        cd /tmp/pgjwt && \
        make install && \
        cd / && rm -rf /tmp/pgjwt; \
    fi

# --- pg_partman (Partition Management) ---
RUN if echo "${POSTGRES_EXTENSIONS}" | grep -q "pg_partman"; then \
        echo "🔨 Building pg_partman ${PGPARTMAN_VERSION}..." && \
        git clone --branch v${PGPARTMAN_VERSION} --depth 1 https://github.com/pgpartman/pg_partman.git /tmp/pg_partman && \
        cd /tmp/pg_partman && \
        make NO_BGW=1 install && \
        cd / && rm -rf /tmp/pg_partman; \
    fi

# --- ParadeDB pg_search (Full-text Search) ---
RUN if echo "${POSTGRES_EXTENSIONS}" | grep -q "pg_search"; then \
        echo "🔨 Building ParadeDB pg_search ${PARADEDB_VERSION}..." && \
        apt-get update && \
        cd /tmp && \
        wget -q --no-check-certificate -O pg_search.deb \
            "https://github.com/paradedb/paradedb/releases/download/v${PARADEDB_VERSION}/postgresql-${POSTGRES_MAJOR_VERSION}-pg-search_${PARADEDB_VERSION}-1PARADEDB-bookworm_amd64.deb" && \
        apt-get install -y ./pg_search.deb && \
        rm -f pg_search.deb && \
        rm -rf /var/lib/apt/lists/*; \
    fi

# Collect ONLY source-compiled extensions for runtime stage
RUN echo "📦 Collecting source-compiled extensions..." && \
    echo "Copying library files for vector, pg_net, pgjwt, pg_partman..." && \
    echo "Looking for .so files in /usr/lib/postgresql/${POSTGRES_MAJOR_VERSION}/lib:" && \
    ls -la /usr/lib/postgresql/${POSTGRES_MAJOR_VERSION}/lib/ | grep -E "(vector|pg_net|pgjwt|pg_partman)" || echo "No matching .so files found" && \
    find /usr/lib/postgresql/${POSTGRES_MAJOR_VERSION}/lib -name "vector.so" -o -name "pg_net.so" -o -name "pgjwt.so" -o -name "pg_partman_bgw.so" | while read file; do \
        echo "Copying: $file" && cp "$file" /extensions-staging/lib/ ; \
    done && \
    echo "Copying extension control and SQL files for source-compiled extensions..." && \
    find /usr/share/postgresql/${POSTGRES_MAJOR_VERSION}/extension \( -name "vector*" -o -name "pg_net*" -o -name "pgjwt*" -o -name "pg_partman*" \) | while read file; do \
        echo "Copying: $file" && cp "$file" /extensions-staging/extension/ ; \
    done && \
    echo "Source-compiled extensions collected: $(find /extensions-staging -type f | wc -l) files" && \
    echo "Library files:" && ls -la /extensions-staging/lib/ && \
    echo "Extension files:" && ls -la /extensions-staging/extension/ | head -10

# =============================================================================
# RUNTIME STAGE: APT-based Extensions + Compiled Extensions
# =============================================================================
FROM postgres:${PG_BASE_VERSION} AS runtime

# Re-declare args for runtime stage  
ARG POSTGRES_MAJOR_VERSION
ARG POSTGRES_EXTENSIONS=""
ARG SHARED_PRELOAD_LIBRARIES=""

# Switch to root for runtime setup
USER root
ENV DEBIAN_FRONTEND=noninteractive

# Install runtime dependencies and APT-BASED extensions
RUN echo "🚀 Setting up runtime PostgreSQL with APT extensions: ${POSTGRES_EXTENSIONS}" && \
    apt-get update && apt-get install -y --no-install-recommends \
        curl \
        wget \
        jq \
        ca-certificates \
        postgresql-contrib \
        libcurl4-gnutls-dev \
        libssl3 \
        python3 \
    && rm -rf /var/lib/apt/lists/*

# ===========================================================================
# APT-BASED Extensions (citus, postgis, pg_cron, hypopg, pg_qualstats)
# ===========================================================================

# APT-based extensions will be installed after copying the build extensions list

# Copy source-compiled extensions from builder stage
RUN mkdir -p /tmp/extensions
COPY --from=builder /extensions-staging /tmp/extensions/

# Copy generated configuration from builder stage
COPY --from=builder /etc/postgresql/generated /etc/postgresql/generated/
COPY --from=builder /tmp/preload_libs.txt /tmp/preload_libs.txt

# Create extension list from build ARG in persistent location
RUN echo "🔍 Extensions to install from ARG: '${POSTGRES_EXTENSIONS}'" && \
    mkdir -p /etc/postgresql/conf.d /etc/postgresql && \
    echo "${POSTGRES_EXTENSIONS}" > /etc/postgresql/postgres_extensions.txt && \
    echo "📋 Created extension file with content: $(cat /etc/postgresql/postgres_extensions.txt)"

# Create extensions list as environment variable for runtime checks
RUN export RUNTIME_EXTENSIONS="$(cat /etc/postgresql/postgres_extensions.txt 2>/dev/null || echo '${POSTGRES_EXTENSIONS}')" && \
    echo "RUNTIME_EXTENSIONS=$RUNTIME_EXTENSIONS" >> /etc/environment

# === APT-BASED Extensions (moved here to access build_extensions.txt) ===

# --- Universal Extensions (hypopg, pg_qualstats) - APT BASED ---
RUN if [ -f /etc/postgresql/postgres_extensions.txt ] && (grep -q "hypopg" /etc/postgresql/postgres_extensions.txt || grep -q "pg_qualstats" /etc/postgresql/postgres_extensions.txt); then \
        echo "🔨 Installing universal extensions..." && \
        apt-get update && \
        ( grep -q "hypopg" /etc/postgresql/postgres_extensions.txt && apt-get install -y --no-install-recommends postgresql-${POSTGRES_MAJOR_VERSION}-hypopg || true ) && \
        ( grep -q "pg_qualstats" /etc/postgresql/postgres_extensions.txt && apt-get install -y --no-install-recommends postgresql-${POSTGRES_MAJOR_VERSION}-pg-qualstats || true ) && \
        rm -rf /var/lib/apt/lists/*; \
    fi

# --- Citus (Distributed PostgreSQL) - APT BASED ---
RUN if [ -f /etc/postgresql/postgres_extensions.txt ] && grep -q "citus" /etc/postgresql/postgres_extensions.txt; then \
        echo "🔨 Installing Citus extension..." && \
        curl -s https://install.citusdata.com/community/deb.sh | bash && \
        apt-get update && \
        apt-get install -y postgresql-${POSTGRES_MAJOR_VERSION}-citus-13.1 && \
        rm -rf /var/lib/apt/lists/*; \
    fi

# --- PostGIS (Geospatial) - APT BASED ---
RUN if [ -f /etc/postgresql/postgres_extensions.txt ] && grep -q "postgis" /etc/postgresql/postgres_extensions.txt; then \
        echo "🔨 Installing PostGIS extension..." && \
        apt-get update && \
        apt-get install -y --no-install-recommends \
            postgresql-${POSTGRES_MAJOR_VERSION}-postgis-3 \
            postgresql-${POSTGRES_MAJOR_VERSION}-postgis-3-scripts && \
        rm -rf /var/lib/apt/lists/*; \
    fi

# --- pg_cron (Job Scheduler) - APT BASED ---
RUN if [ -f /etc/postgresql/postgres_extensions.txt ] && grep -q "pg_cron" /etc/postgresql/postgres_extensions.txt; then \
        echo "🔨 Installing pg_cron extension..." && \
        apt-get update && \
        apt-get install -y postgresql-${POSTGRES_MAJOR_VERSION}-cron && \
        rm -rf /var/lib/apt/lists/*; \
    fi

# hypopg and pg_qualstats are now installed above with universal extensions

# Install source-compiled extensions to proper PostgreSQL directories
RUN echo "Installing source-compiled extensions from builder stage..." && \
    if [ -d "/tmp/extensions" ] && [ "$(ls -A /tmp/extensions 2>/dev/null)" ]; then \
        echo "Found source-compiled extensions to install:" && \
        ls -la /tmp/extensions/ && \
        echo "Installing library files..." && \
        if [ -d "/tmp/extensions/lib" ] && [ "$(ls -A /tmp/extensions/lib 2>/dev/null)" ]; then \
            cp /tmp/extensions/lib/*.so /usr/lib/postgresql/${POSTGRES_MAJOR_VERSION}/lib/ 2>/dev/null || true; \
        fi && \
        echo "Installing extension files..." && \
        if [ -d "/tmp/extensions/extension" ] && [ "$(ls -A /tmp/extensions/extension 2>/dev/null)" ]; then \
            cp /tmp/extensions/extension/* /usr/share/postgresql/${POSTGRES_MAJOR_VERSION}/extension/ 2>/dev/null || true; \
        fi; \
    else \
        echo "No source-compiled extensions found in builder stage"; \
    fi && \
    rm -rf /tmp/extensions

# Configuration already generated in builder stage

# Copy remaining files
COPY conf/ /etc/postgresql/
COPY init/ /docker-entrypoint-initdb.d/

# Set proper permissions
RUN chmod +x /usr/local/bin/*.sh 2>/dev/null || true && \
    chmod +x /docker-entrypoint-initdb.d/*.sh 2>/dev/null || true

# Use the shared_preload_libraries generated by build-config.sh
RUN if [ -f /tmp/preload_libs.txt ]; then \
        SHARED_PRELOAD_LIBS=$(cat /tmp/preload_libs.txt); \
        echo "$SHARED_PRELOAD_LIBS" > /etc/postgresql/shared_preload_libraries.txt; \
        echo "📋 Using shared_preload_libraries from build-config.sh: $SHARED_PRELOAD_LIBS"; \
    else \
        echo "⚠️  No preload_libs.txt found from build-config.sh, using empty"; \
        echo "" > /etc/postgresql/shared_preload_libraries.txt; \
    fi

# Environment variables
ENV POSTGRES_EXTENSIONS=${POSTGRES_EXTENSIONS}
ENV POSTGRES_MODE="single"

# Switch back to postgres user for runtime
USER postgres

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD pg_isready -U ${POSTGRES_USER:-postgres} -d ${POSTGRES_DB:-postgres} || exit 1

EXPOSE 5432