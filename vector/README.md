# Vector

[![Docker Hub](https://img.shields.io/docker/v/oorabona/vector?sort=semver&label=Docker%20Hub)](https://hub.docker.com/r/oorabona/vector)
[![GHCR](https://img.shields.io/badge/GHCR-vector-blue?logo=github)](https://github.com/oorabona/docker-containers/pkgs/container/vector)
[![Build](https://github.com/oorabona/docker-containers/actions/workflows/auto-build.yaml/badge.svg)](https://github.com/oorabona/docker-containers/actions/workflows/auto-build.yaml)

High-performance observability data pipeline for collecting, transforming, and routing logs, metrics, and events. Built on [Vector](https://vector.dev/) with a pre-built musl static binary on Alpine Linux.

## Why this image

This image packages [Vector](https://vector.dev/) as a minimal, production-hardened container suited for vendor-free observability pipelines.

- **Minimal attack surface.** Built on Alpine Linux using the upstream musl-linked static Vector binary from GitHub Releases. The binary is self-contained — it does not depend on glibc or a shell interpreter at runtime, even though Alpine still ships `ash` for image-level operations.
- **Multiple architectures.** Published for both `linux/amd64` and `linux/arm64`, tested on each arch in CI. Pulls the correct platform layer automatically on `docker pull`.
- **Verifiable provenance.** Every build produces a Sigstore SBOM attestation (cosign) and a Trivy vulnerability scan. Digests are recorded in build lineage and surfaced on the dashboard.
- **Automated upstream tracking.** The upstream-monitor workflow checks the Vector GitHub release feed daily and opens a PR when a new version is available, keeping the image current without manual intervention.
- **Common sink/source coverage.** Supports Docker log collection, syslog, file tailing, Prometheus scrape, and OpenTelemetry out of the box. Pairs directly with the `oorabona/postgres:<version>-full-alpine` flavor (TimescaleDB + ParadeDB) for a complete vendor-free log/metrics store — see the PostgreSQL sink example below.

## Verify this image

Every build ships a Sigstore-signed SBOM and a full Trivy scan — verify them yourself, no login required:

```bash
gh attestation verify oci://ghcr.io/oorabona/vector:latest --owner oorabona
```

Full walkthrough (SBOM payload, Trivy findings, multi-arch manifest inspection, upstream dependency tracking) → <https://oorabona.github.io/docker-containers/verify-images/>

## Quick Start

```bash
# Pull the image
docker pull ghcr.io/oorabona/vector:latest

# Run with default demo config (generates sample logs → console)
docker run -d --name vector -p 8686:8686 ghcr.io/oorabona/vector:latest

# Run with custom config
docker run -d --name vector \
  -v /path/to/vector.yaml:/etc/vector/vector.yaml:ro \
  -p 8686:8686 \
  ghcr.io/oorabona/vector:latest

# Monitor pipeline performance
docker exec vector vector top
```

## Build

```bash
# Build with latest upstream version
./make build vector

# Build with specific version
./make build vector 0.53.0
```

### Build Args

| Arg | Default | Description |
|-----|---------|-------------|
| `VERSION` | `latest` | Full version tag (set by build system) |
| `UPSTREAM_VERSION` | _(auto)_ | Raw upstream version (e.g., `0.53.0`) |
| `OS_IMAGE_BASE` | `alpine` | Base image distribution |
| `OS_IMAGE_TAG` | `latest` | Base image tag |

## Configuration

Vector uses a YAML configuration file at `/etc/vector/vector.yaml`. The default config runs a demo pipeline that generates sample JSON logs and prints them to the console.

For production, mount your own configuration:

```yaml
# vector.yaml — collect Docker logs, enrich, send to PostgreSQL
api:
  enabled: true
  address: "0.0.0.0:8686"

sources:
  docker_logs:
    type: docker_logs

transforms:
  enrich:
    type: remap
    inputs: ["docker_logs"]
    source: |
      # Parse structured fields and add metadata
      .host = get_hostname!()
      .environment = get_env_var("VECTOR_ENV") ?? "production"
      .processed_at = now()

sinks:
  postgresql:
    type: postgres
    inputs: ["enrich"]
    endpoint: "postgresql://vector:password@postgres:5432/observability"
    table: "logs"
    encoding:
      codec: json
```

### PostgreSQL Sink (Vendor-Free Observability)

Vector pairs with our [postgres:full](../postgres/) image (TimescaleDB + pgvector + ParadeDB + Citus) for a complete vendor-free observability stack:

- **Logs** → PostgreSQL with TimescaleDB hypertables for time-series queries
- **Metrics** → PostgreSQL with continuous aggregates for efficient rollups
- **Search** → ParadeDB BM25 index for full-text search over logs

See [`examples/docker-compose.yaml`](examples/docker-compose.yaml) for a ready-to-run stack.

## Ports

| Port | Service |
|------|---------|
| 8686 | Vector API (health checks, `vector top`, GraphQL playground) |

Additional ports depend on your configured sources (e.g., 514 for syslog, 9000 for Prometheus scrape, 4317 for OpenTelemetry).

## Volumes

| Path | Purpose |
|------|---------|
| `/etc/vector/vector.yaml` | Configuration file (mount read-only) |
| `/var/lib/vector/` | Buffer data directory (for disk buffers) |

## Health Check

Built-in health check via Vector API:

```
GET http://localhost:8686/health → {"ok": true}
```

## Management

```bash
# Reload configuration without restart (graceful)
docker kill --signal=HUP vector

# View real-time pipeline metrics
docker exec vector vector top

# Validate configuration before deploying
docker exec vector vector validate /etc/vector/vector.yaml

# View logs
docker logs -f vector
```

## Architecture

```
Sources (inputs)          Transforms (VRL)            Sinks (outputs)
┌─────────────┐          ┌──────────────────┐        ┌──────────────┐
│ docker_logs  │───┐      │ remap (enrich)   │───┐    │ PostgreSQL   │
│ syslog       │───┤─────>│ filter (route)   │───┤───>│ S3 / GCS     │
│ file         │───┤      │ aggregate        │───┤    │ Elasticsearch│
│ prometheus   │───┘      │ dedupe           │───┘    │ console      │
└─────────────┘          └──────────────────┘        └──────────────┘
```

Runs as non-root user `vector` (uid 1000). Pre-built musl-linked static binary downloaded from GitHub releases — supports `x86_64` and `aarch64`.

## Security Considerations

- Runs as non-root user `vector` (uid 1000)
- No shell access required — single static binary
- Mount config read-only (`:ro`)
- Use environment variables or secrets for sink credentials
- Buffer data at `/var/lib/vector/` — mount a volume for persistence and to avoid data loss on restart
- TLS supported for all network sources and sinks

## Dependencies

| Component | Version | Source | Monitoring |
|-----------|---------|--------|------------|
| Vector | 0.53.0 | [GitHub](https://github.com/vectordotdev/vector) | upstream-monitor |
| Alpine Linux | latest | Base image | upstream |

## Links

- [Vector Documentation](https://vector.dev/docs/)
- [Vector Configuration Reference](https://vector.dev/docs/reference/configuration/)
- [VRL (Vector Remap Language)](https://vector.dev/docs/reference/vrl/)
- [Available Sources](https://vector.dev/docs/reference/configuration/sources/)
- [Available Sinks](https://vector.dev/docs/reference/configuration/sinks/)
- [Vector Blog](https://vector.dev/blog/)
