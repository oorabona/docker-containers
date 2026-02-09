# Observability Stack

Vendor-free monitoring pipeline: Vector collects logs and metrics, stores them in PostgreSQL (with TimescaleDB), and Grafana provides visualization.

## When to use this

- Self-hosted monitoring without vendor lock-in (no Datadog/Elastic fees)
- Log aggregation from Docker containers or syslog sources
- Metric collection and visualization with Grafana dashboards
- When you want full control over your observability data

## Architecture

```
┌──────────────────────────────────────┐
│  Grafana :3000                       │
│  Dashboards and alerting             │
├──────────────────────────────────────┤
│  Vector :8686                        │
│  Log/metric collection pipeline      │
│  demo_logs → PostgreSQL              │
├──────────────────────────────────────┤
│  PostgreSQL 17 (full) :5432          │
│  TimescaleDB for time-series data    │
│  Tables: logs, metrics               │
└──────────────────────────────────────┘
```

## Quick start

```bash
docker compose up -d
# Grafana:    http://localhost:3000 (admin / admin)
# Vector API: http://localhost:8686/health
# PostgreSQL: localhost:15432 (vector / vector)
```

## Query examples

Via Grafana or `psql`:

```sql
-- Recent logs
SELECT * FROM logs ORDER BY timestamp DESC LIMIT 20;

-- Log volume by host
SELECT host, count(*) FROM logs GROUP BY host ORDER BY count DESC;
```

## Customizing

- Edit `vector.yaml` to add your own sources (files, syslog, Docker, etc.)
- Edit `init.sql` to adjust table schemas
- Add Grafana dashboards in `grafana/dashboards/`

## Testing

```bash
bash test.sh
```
