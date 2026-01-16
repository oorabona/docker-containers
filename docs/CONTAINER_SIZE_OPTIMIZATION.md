# Container Size Optimization Guide

Best practices for minimizing Docker image sizes in this repository.

## Current Image Sizes

| Container | Size | Status |
|-----------|------|--------|
| sslh | ~18 MB | Optimized (Alpine + minimal deps) |
| postgres | ~284 MB | Good (Alpine variant) |
| php | ~668 MB | Acceptable (includes many extensions) |
| openresty | ~933 MB | Could be improved (multi-stage build) |

## Optimization Techniques

### 1. Use Alpine Base Images

Alpine Linux images are ~5 MB vs ~120 MB for Debian.

```dockerfile
# Good
FROM alpine:latest

# Avoid for size-sensitive builds
FROM debian:latest
```

### 2. Multi-Stage Builds

Separate build dependencies from runtime:

```dockerfile
# Stage 1: Builder
FROM alpine:latest AS builder
RUN apk add --no-cache build-base
COPY . /src
RUN make -C /src

# Stage 2: Runtime (clean)
FROM alpine:latest
COPY --from=builder /src/bin /usr/local/bin/
```

### 3. Clean Up in Same Layer

Build artifacts must be removed in the same `RUN` command:

```dockerfile
# Bad - cleanup in separate layer doesn't reduce size
RUN apk add build-base && make
RUN rm -rf /var/cache/apk/*

# Good - single layer
RUN apk add --no-cache --virtual .build-deps build-base \
    && make \
    && apk del .build-deps
```

### 4. Use Virtual Package Groups

Alpine's virtual packages make cleanup easy:

```dockerfile
RUN apk add --no-cache --virtual .build-deps \
        gcc \
        musl-dev \
        make \
    && ./configure && make install \
    && apk del .build-deps
```

### 5. Minimize Layers

Combine related commands:

```dockerfile
# Bad - 4 layers
RUN apk update
RUN apk add curl
RUN curl -O https://example.com/file
RUN rm -rf /var/cache/apk/*

# Good - 1 layer
RUN apk add --no-cache curl \
    && curl -O https://example.com/file
```

### 6. Use .dockerignore

Prevent unnecessary files from being copied:

```dockerignore
.git
*.md
tests/
docs/
```

### 7. Avoid Installing Docs

```dockerfile
# Alpine: docs are not installed by default
# For other distros, exclude doc packages
RUN apt-get install --no-install-recommends package
```

## Checking Image Size

```bash
# List images with sizes
docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}"

# Analyze layers
docker history <image>

# Deep dive with dive tool
dive <image>
```

## Container-Specific Notes

### OpenResty

Current size: ~933 MB. Optimization opportunity:
- Convert to multi-stage build
- Build OpenSSL/PCRE/OpenResty in builder stage
- Copy only runtime files to final stage
- Expected reduction: ~50-60%

### PHP

Already optimized with:
- Multi-stage build (composer)
- Virtual build deps cleanup
- Runtime deps auto-detection

### PostgreSQL

Uses Alpine variant with extensions compiled from source.
Further optimization limited by extension requirements.

### SSLH

Already highly optimized:
- Alpine base
- Minimal dependencies
- Single binary

## CI/CD Considerations

1. **Build Cache**: Use registry cache to speed up builds
2. **Multi-arch**: ARM64 builds may have different sizes
3. **Security**: Smaller images = smaller attack surface

## Tools

- **dive**: Layer-by-layer analysis - `dive <image>`
- **docker slim**: Auto-optimize images - `docker-slim build <image>`
- **trivy**: Security + size insights - `trivy image <image>`
