---
layout: post
title: "Vendor-Free Observability: Vector + PostgreSQL as a Datadog Alternative"
description: "A 52 MB Vector container paired with PostgreSQL (pgvector, TimescaleDB) gives you logs, metrics, and traces without the SaaS bill. Here's how."
date: 2026-05-06 10:00:00 +0000
tags: [observability, vector, postgres, timescaledb, self-hosted, logs, metrics]
---

A three-person startup comes to you with a $4 000/month Datadog bill and asks how to cut it. A 500-person enterprise comes with a $150 000 ELK licence and asks the same. Both problems have the same root cause: **observability gets billed per byte you ingest**, and once your app emits logs, you're locked in.

This post shows how two containers — [Vector](/docker-containers/container/vector/) (52 MB) and [PostgreSQL with TimescaleDB](/docker-containers/container/postgres/) — replace most of what Datadog / Splunk / Elastic sells. No vendor, no per-byte tax, your data stays on your infrastructure.

## The architecture in one diagram

```
┌──────────────┐     ┌──────────────────┐      ┌───────────────────┐
│ Logs (apps)  │──┐  │                  │      │                   │
└──────────────┘  │  │                  │      │  Postgres + time- │
                  ├─▶│  Vector (52 MB)  │─────▶│  scaleDB hyper-   │
┌──────────────┐  │  │  musl static bin │      │  tables           │
│ Metrics      │──┤  │                  │      │                   │
│ (Prometheus) │  │  │  VRL transforms  │      │  + pgvector for   │
└──────────────┘  │  │  routing, buffer │      │  log embeddings   │
                  │  │                  │      │                   │
┌──────────────┐  │  └────────┬─────────┘      └─────────┬─────────┘
│ syslog,      │──┘           │                          │
│ systemd,     │              │                          │
│ journald     │              ▼                          ▼
└──────────────┘     ┌──────────────────┐      ┌───────────────────┐
                     │  Also: S3, Kafka,│      │  Query: Grafana,  │
                     │  New Relic, DD   │      │  psql, SQL alerts │
                     │  (parallel fan-  │      │                   │
                     │   out during     │      │                   │
                     │   migration)     │      │                   │
                     └──────────────────┘      └───────────────────┘
```

Vector is the pipeline. PostgreSQL is the store. You already know SQL. The bill is electricity.

## Vector in 60 seconds

[Vector](https://vector.dev/) (by Datadog, open-source MPL-2.0) is a rust-written pipeline for logs, metrics, and traces. Think "fluentd/logstash replacement but written in 2020 and 10× faster."

Our image:

```bash
docker pull ghcr.io/oorabona/vector:latest-alpine
# 52 MB, multi-arch, static musl binary
```

- **FROM scratch-ish** — alpine with the static vector binary downloaded at build time
- **Multi-arch** (amd64, arm64)
- **Non-root** (uid 1000)
- **HEALTHCHECK** via Vector's `/health` endpoint
- Auto-tracked from [vectordotdev/vector](https://github.com/vectordotdev/vector) releases (with a regex that correctly ignores their `vdev-v*` CLI subproject releases — story [here](/docker-containers/2026/04/24/sslh-docker-port-multiplexing.html))

## A minimal config: Nginx logs to Postgres

```toml
# vector.toml
data_dir = "/var/lib/vector"

[sources.nginx]
type = "file"
include = ["/var/log/nginx/*.log"]
ignore_older_secs = 86400
read_from = "end"

[transforms.parse]
type = "remap"
inputs = ["nginx"]
source = '''
  . = parse_regex!(
    .message,
    r'^(?P<remote>\S+) \S+ \S+ \[(?P<time>[^\]]+)\] "(?P<method>\S+) (?P<path>\S+) \S+" (?P<status>\d+) (?P<bytes>\d+)'
  )
  .timestamp = parse_timestamp!(.time, "%d/%b/%Y:%H:%M:%S %z")
  .status = to_int!(.status)
  .bytes = to_int!(.bytes)
'''

[sinks.postgres]
type = "postgres"
inputs = ["parse"]
endpoint = "postgres://vector:${POSTGRES_PASSWORD}@db:5432/observability"
table = "nginx_logs"
batch.max_events = 1000
batch.timeout_secs = 5
```

Create the destination table:

```sql
CREATE TABLE nginx_logs (
  timestamp TIMESTAMPTZ NOT NULL,
  remote    TEXT,
  method    TEXT,
  path      TEXT,
  status    INT,
  bytes     BIGINT
);

SELECT create_hypertable('nginx_logs', 'timestamp', chunk_time_interval => INTERVAL '1 day');
CREATE INDEX ON nginx_logs (status, timestamp DESC);
```

That's it. Nginx access logs flow into a TimescaleDB hypertable, automatically partitioned by day. Queries:

```sql
-- Top 10 404 paths in the last hour
SELECT path, count(*) as hits
FROM nginx_logs
WHERE timestamp > now() - interval '1 hour'
  AND status = 404
GROUP BY path
ORDER BY hits DESC
LIMIT 10;
```

No Kibana, no query language to learn. SQL.

## Why pair Vector with our Postgres

We ship a [postgres:18-alpine-full](/docker-containers/container/postgres/) variant with:

- **TimescaleDB** for time-series compression (10×–100× size reduction on old chunks)
- **pgvector** for embedding-based log search (recent Datadog-ish feature: "find logs similar to this one")
- **pg_cron** for scheduled rollups ("aggregate hourly stats overnight")
- **paradedb / pg_search** for BM25 full-text log search — the Elasticsearch use case without Elasticsearch

One container, one database, every observability workload.

## Real use cases

### 1. Log search at scale

With pg_search on the `message` column:

```sql
CREATE INDEX log_search ON nginx_logs
  USING bm25 (timestamp, path, message) WITH (key_field='timestamp');

-- "Find error logs mentioning database"
SELECT timestamp, message
FROM nginx_logs
WHERE message @@@ 'error AND database'
ORDER BY paradedb.score(timestamp) DESC
LIMIT 50;
```

### 2. Anomaly detection with embeddings

```sql
-- Assume an external pipeline wrote embeddings to log_embeddings(log_id, embedding vector(768))
-- "Find logs similar to this error"
WITH needle AS (
  SELECT embedding FROM log_embeddings WHERE log_id = 12345
)
SELECT l.timestamp, l.message
FROM log_embeddings e
JOIN nginx_logs l ON l.id = e.log_id
CROSS JOIN needle
ORDER BY e.embedding <=> needle.embedding
LIMIT 20;
```

### 3. Alerts without a separate system

```sql
-- Every minute, check if p99 latency exceeded threshold
SELECT cron.schedule(
  'latency-alert',
  '* * * * *',
  $$
    INSERT INTO alerts (fired_at, rule, detail)
    SELECT now(), 'p99_too_high', jsonb_build_object('p99', p99)
    FROM (
      SELECT percentile_cont(0.99) WITHIN GROUP (ORDER BY response_ms) p99
      FROM nginx_logs
      WHERE timestamp > now() - interval '5 min'
    ) x
    WHERE p99 > 2000
  $$
);
```

PagerDuty trigger = webhook from a Postgres trigger on the `alerts` table. 20 lines of SQL. No Grafana Mimir.

## Size story

| Component | Size | vs. "standard" stack |
|---|---|---|
| Vector | **52 MB** | vs. Logstash ~800 MB (JVM) |
| Postgres+full | **242 MB** | vs. Elasticsearch 700 MB + Kibana 1 GB |
| TOTAL | **~294 MB** | vs. ~2.5 GB |

Before anyone says "but you still need Prometheus, Grafana, etc.": you don't. Vector does metric scraping (Prometheus source + remap), Postgres does storage, and Grafana (if you want a UI) has a Postgres data source. The whole stack is 5 containers, ~500 MB total.

## Migration from Datadog

Vector has a `datadog_agent` source that accepts DD Agent protocol. Run in parallel:

```toml
[sources.dd_proxy]
type = "datadog_agent"
address = "0.0.0.0:8080"

# Original sink: keep sending to Datadog
[sinks.datadog]
type = "datadog_logs"
inputs = ["dd_proxy"]
default_api_key = "${DATADOG_API_KEY}"

# New sink: also send to Postgres
[sinks.postgres_logs]
type = "postgres"
inputs = ["dd_proxy"]
endpoint = "postgres://..."
table = "all_logs"
```

Point your applications' `DD_API_ENDPOINT` to Vector instead of `api.datadoghq.com`, verify the Postgres side is collecting, then turn off the Datadog sink. Your apps don't need a single code change.

## Limitations

- **Traces** — Vector can route OTEL traces to Postgres but the querying story is weak. Tempo or Jaeger in parallel still makes sense for trace search.
- **Log retention > 90 days** at high volume — Postgres hypertable compression handles this (tens of GB → GB with timescale_toolkit), but at petabyte scale you want a dedicated cold store (S3 via Vector's S3 sink).
- **Query latency** — Elasticsearch is faster for interactive log search on very large datasets. Postgres catches up with proper indexing, but if you're running > 10 TB of indexed logs, benchmark.
- **Alerting UI** — no Kibana rule builder. You write SQL. If your team can't write SQL, this stack is the wrong call.

For 95% of companies, though, this stack is under-specced for the bills they're paying elsewhere.

## TL;DR

```bash
# Vector: the pipeline
docker pull ghcr.io/oorabona/vector:latest-alpine              # 52 MB

# Postgres with everything: the store
docker pull ghcr.io/oorabona/postgres:18-alpine-full           # 242 MB
```

Both on [the dashboard](/docker-containers/container/vector/).

If this stack saves you a Datadog renewal, [⭐ the repo](https://github.com/oorabona/docker-containers). We add features based on what the star count tells us people actually want.
