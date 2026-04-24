---
layout: post
title: "PostgreSQL 18 with pgvector, pg_search, and TimescaleDB on Alpine: A RAG-Ready Database in 214 MB"
description: "Run vectors, full-text BM25 search, time-series, and GIS in one PostgreSQL container — 214 MB for the vector flavor, 242 MB with the full extension set."
date: 2026-04-26 10:00:00 +0000
tags: [postgres, pgvector, paradedb, alpine, rag, vector-search]
---

Most retrieval-augmented generation (RAG) stacks end up running four systems: PostgreSQL for relational data, a vector database (pgvector, Qdrant, Weaviate), an inverted index (Elasticsearch, Meilisearch), and some batch layer for analytics. Four systems, four sets of credentials, four clients, four different consistency models.

**One PostgreSQL instance with the right extensions can cover all of that** — and fit in a single Alpine container.

This post shows the tradeoffs of the `oorabona/postgres` image family and when each flavor makes sense.

## The flavors

The image ships 7 flavors for PostgreSQL 16, 17, and 18, each bundling a different extension set:

| Flavor | Compressed size (amd64) | Extensions |
|---|---|---|
| `base` | **108 MB** | pg_stat_statements only |
| `vector` | **214 MB** | pgvector |
| `analytics` | **179 MB** | paradedb (pg_search with BM25) |
| `timeseries` | — | timescaledb, pg_partman |
| `spatial` | — | postgis |
| `distributed` | — | citus |
| `full` | **242 MB** | pgvector + paradedb + timescale + postgis + pg_cron + pg_ivm + pg_partman + hypopg + pg_qualstats + citus |

Each extension is compiled against its PostgreSQL version — no `_pg15` / `_pg16` filename gymnastics.

## Why Alpine

The underlying base is `postgres:X-alpine` (musl libc, Alpine Linux). Three reasons:

1. **Smaller attack surface** — the stripped-down package set reduces CVE count relative to Debian slim.
2. **Multi-arch out of the box** — amd64 and arm64 from the same build pipeline.
3. **ParadeDB Alpine support** — upstream ships for glibc; we compile against musl with `RUSTFLAGS="-C target-feature=-crt-static"` so the image stays Alpine-consistent.

A gotcha that cost us half a day: Appender batch inserts on `TIMESTAMPTZ` columns reject naive timestamps. Extensions that write through the Appender path need explicit tz handling. Worth knowing if you port a DuckDB ingestion pipeline to this image.

## When to use which flavor

**`base`** — Run regular Postgres. You wouldn't pick this image for that (official `postgres` is fine), but it's the foundation every other flavor builds on.

**`vector`** — You have embeddings. Store them as `vector(1536)` (OpenAI), `vector(768)` (Sentence Transformers), etc. HNSW indexes are available out of the box:

```sql
CREATE EXTENSION vector;

CREATE TABLE docs (
  id bigserial PRIMARY KEY,
  content text,
  embedding vector(1536)
);

CREATE INDEX ON docs USING hnsw (embedding vector_cosine_ops);

-- Nearest neighbors
SELECT id, content
FROM docs
ORDER BY embedding <=> '[0.1, 0.2, ...]'::vector
LIMIT 10;
```

**`analytics`** — You need BM25 full-text search (the algorithm Elasticsearch uses). ParadeDB wraps Tantivy as a Postgres index, giving you Elastic-quality ranking without running another system:

```sql
CREATE EXTENSION pg_search;

CREATE INDEX search_idx ON docs
USING bm25 (id, content)
WITH (key_field='id');

-- Ranked results
SELECT id, content, paradedb.score(id)
FROM docs
WHERE content @@@ 'alpine AND postgres'
ORDER BY paradedb.score(id) DESC;
```

**`timeseries`** — IoT, metrics, anything with a time dimension. TimescaleDB hypertables automatically partition by time; pg_partman manages the partition lifecycle.

**`spatial`** — PostGIS. You know if you need it.

**`distributed`** — Citus for horizontal sharding. Niche but solid when you need it.

**`full`** — All of the above. 242 MB compressed. For the 12-factor apps that want to experiment without choosing upfront.

## vs stacking separate containers

Could you run `postgres:18-alpine` + `pgvector/pgvector` + `paradedb/paradedb` separately? Sure. But:

- **One connection pool** — a single `pgbouncer` or `pool.max=20` in your app covers everything
- **Transactional consistency** — you can write a document AND update its embedding AND update its BM25 index in one transaction
- **One backup** — `pg_dump`, `wal-g`, pgBackRest, all work unchanged
- **One monitoring** — `pg_stat_statements` sees every query across features

The downside: you can't independently scale the vector workload away from the transactional one. For most teams under 1 TB of data, that's a non-issue.

## Deployment

```yaml
# docker-compose.yml
services:
  db:
    image: ghcr.io/oorabona/postgres:18-alpine-full
    environment:
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?required}
      POSTGRES_DB: app
      # Required for extensions that need preload (timescaledb, pg_cron, citus)
      POSTGRES_SHARED_PRELOAD_LIBRARIES: "timescaledb,pg_cron,pg_stat_statements"
    volumes:
      - pgdata:/var/lib/postgresql/data
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped

volumes:
  pgdata:
```

After first boot, enable the extensions you want:

```sql
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_search;
CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE EXTENSION IF NOT EXISTS postgis;
```

Only the ones with `shared_preload_libraries` need a restart (timescaledb, pg_cron, citus). The others load on `CREATE EXTENSION`.

## Upgrades

When a new minor version of a preloaded extension ships, the running database may refuse to start ("extension version mismatch"). Fix:

```sql
ALTER EXTENSION timescaledb UPDATE;
ALTER EXTENSION pg_cron UPDATE;
```

The image's daily CI picks up upstream releases; after a `docker pull`, run the `ALTER EXTENSION UPDATE` for each preloaded extension. Tracked and tested in the build pipeline — no surprises from upstream tag changes.

## Gotchas

- **`TIMESTAMPTZ` + Appender** — if you ingest via the binary `COPY`/Appender path (a common DuckDB → Postgres pattern), timestamps must carry timezone metadata. Naive timestamps are rejected.
- **`chmod` errors on startup** — ignore `chmod: /var/lib/postgresql/X/docker: Operation not permitted` when using podman or rootless docker. The initdb script still succeeds.
- **Writable tmpfs** for temp files — under `read_only: true`, mount `/tmp` and `/var/run/postgresql` as tmpfs, otherwise WAL writes fail.

## Automated upstream tracking

Every extension version is pinned in `postgres/extensions/config.yaml` and bumped by CI when upstream releases:

- **pgvector** (pgvector/pgvector) via GitHub releases
- **paradedb** (paradedb/paradedb) via GitHub releases
- **timescaledb** (timescale/timescaledb) via GitHub releases
- **postgis**, **citus**, **pg_cron**, **pg_ivm**, **pg_partman**, **hypopg**, **pg_qualstats** — same

Minor/patch bumps auto-merge; majors wait for manual review. Each build produces an SPDX SBOM with all bundled extensions and their versions — handy when you need to prove which CVE you're running or aren't.

## TL;DR

```bash
# Just pgvector
docker pull ghcr.io/oorabona/postgres:18-alpine-vector      # 214 MB

# Everything
docker pull ghcr.io/oorabona/postgres:18-alpine-full        # 242 MB
```

Live status and all variants: [container dashboard](/docker-containers/container/postgres/).

If this saved you from setting up three systems, [drop a ⭐](https://github.com/oorabona/docker-containers). It's how we learn that the 29 000 monthly pulls aren't all CI robots.
