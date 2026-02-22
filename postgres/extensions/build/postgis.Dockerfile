# Build PostGIS extension for PostgreSQL
# https://github.com/postgis/postgis
#
# PostGIS adds geospatial object support to PostgreSQL
# Reference: https://github.com/postgis/docker-postgis (Alpine variant)
#
# IMPORTANT: Flavors using PostGIS must install runtime deps in the main
# Dockerfile: geos gdal proj json-c libxml2 protobuf-c
#
# Usage:
#   docker build -f postgis.Dockerfile \
#     --build-arg MAJOR_VERSION=17 \
#     --build-arg EXT_VERSION=3.5.5 \
#     -t postgis-builder .
#
# Output: /output/ contains files to extract via docker cp

ARG MAJOR_VERSION=17
FROM postgres:${MAJOR_VERSION}-alpine

ARG EXT_VERSION=3.5.5
ARG EXT_REPO=postgis/postgis

# Install build dependencies
# PostGIS requires GEOS, PROJ, GDAL, json-c, libxml2, protobuf-c for spatial operations
RUN apk add --no-cache \
    build-base \
    clang19 \
    llvm19-dev \
    autoconf \
    automake \
    libtool \
    gettext-dev \
    git \
    geos-dev \
    proj-dev \
    gdal-dev \
    json-c-dev \
    libxml2-dev \
    protobuf-c-dev \
    pcre2-dev \
    perl \
    && ln -sf /usr/bin/clang-19 /usr/bin/clang \
    && ln -sf /usr/bin/clang++-19 /usr/bin/clang++

# Download PostGIS source
WORKDIR /build

RUN git clone --branch ${EXT_VERSION} --depth 1 \
    https://github.com/${EXT_REPO}.git postgis

WORKDIR /build/postgis

# Build PostGIS
# autogen.sh generates the configure script
# --enable-lto enables Link Time Optimization
RUN gettextize \
    && ./autogen.sh \
    && ./configure --enable-lto \
    && make -j"$(nproc)" \
    && make install DESTDIR=/install

# Prepare output structure
# PostGIS installs to multiple locations:
#   - extension/ : control files, SQL scripts
#   - lib/       : shared libraries (.so)
RUN mkdir -p /output/extension /output/lib && \
    cp -v /install/usr/local/share/postgresql/extension/postgis* /output/extension/ && \
    cp -v /install/usr/local/lib/postgresql/postgis*.so /output/lib/ && \
    # Also copy address_standardizer and postgis_topology if built
    cp -v /install/usr/local/share/postgresql/extension/address_standardizer* /output/extension/ 2>/dev/null || true && \
    cp -v /install/usr/local/share/postgresql/extension/postgis_topology* /output/extension/ 2>/dev/null || true && \
    cp -v /install/usr/local/share/postgresql/extension/postgis_raster* /output/extension/ 2>/dev/null || true && \
    cp -v /install/usr/local/share/postgresql/extension/postgis_tiger_geocoder* /output/extension/ 2>/dev/null || true && \
    cp -v /install/usr/local/lib/postgresql/address_standardizer*.so /output/lib/ 2>/dev/null || true && \
    cp -v /install/usr/local/lib/postgresql/postgis_topology*.so /output/lib/ 2>/dev/null || true && \
    cp -v /install/usr/local/lib/postgresql/postgis_raster*.so /output/lib/ 2>/dev/null || true

# Add metadata
RUN echo "extension=postgis" > /output/metadata.txt && \
    echo "version=${EXT_VERSION}" >> /output/metadata.txt && \
    echo "major_version=${MAJOR_VERSION}" >> /output/metadata.txt && \
    echo "build_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> /output/metadata.txt

# List output for verification
RUN ls -laR /output/
