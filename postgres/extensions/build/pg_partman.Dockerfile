# Build pg_partman extension for PostgreSQL
# https://github.com/pgpartman/pg_partman
#
# pg_partman provides automatic partition management for time-series
# and serial-based table partitioning

ARG REMOTE_CR=ghcr.io/oorabona
ARG MAJOR_VERSION
FROM ${REMOTE_CR}/library/postgres:${MAJOR_VERSION}-alpine AS builder

ARG REMOTE_CR
ARG EXT_VERSION
ARG EXT_REPO
ARG MAJOR_VERSION

# Validate required build args
RUN : "${EXT_VERSION:?required}" "${EXT_REPO:?required}"

# Install build dependencies.
# PGXS hardcodes a specific clang-N for JIT bitcode (with_llvm=yes). Derive that
# major from the postgres base's Makefile.global and install exactly it, so the
# toolchain tracks the base instead of being re-pinned (the clang19→clang21 drift).
RUN set -eux \
    && apk add --no-cache \
        build-base \
        git \
        icu-dev \
    && pg_clang_major="$(grep -oE 'clang-[0-9]+' "$(dirname "$(pg_config --pgxs)")/../Makefile.global" | head -1 | grep -oE '[0-9]+')" \
    && : "${pg_clang_major:?could not determine postgres CLANG major}" \
    && apk add --no-cache "clang${pg_clang_major}" "llvm${pg_clang_major}-dev"

# Download and build pg_partman
WORKDIR /build

RUN git clone --branch v${EXT_VERSION} --depth 1 \
    https://github.com/${EXT_REPO}.git pg_partman

WORKDIR /build/pg_partman

# Build
RUN make PG_CONFIG=/usr/local/bin/pg_config && \
    make install DESTDIR=/install

# Prepare output structure
RUN mkdir -p /output/extension /output/lib && \
    cp -v /install/usr/local/share/postgresql/extension/pg_partman* /output/extension/ && \
    cp -v /install/usr/local/lib/postgresql/pg_partman_bgw.so /output/lib/ 2>/dev/null || true

# Add metadata
RUN echo "extension=pg_partman" > /output/metadata.txt && \
    echo "version=${EXT_VERSION}" >> /output/metadata.txt && \
    echo "major_version=${MAJOR_VERSION}" >> /output/metadata.txt && \
    echo "build_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> /output/metadata.txt

# List output for verification
RUN ls -laR /output/

# Final stage: only the compiled extension files
FROM scratch
COPY --from=builder /output/ /output/
