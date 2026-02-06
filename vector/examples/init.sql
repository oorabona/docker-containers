-- Initialize observability database for Vector
-- Works with postgres:full (TimescaleDB + ParadeDB)

-- Logs table: stores structured log events from Vector
CREATE TABLE IF NOT EXISTS logs (
    timestamp  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    host       TEXT,
    message    TEXT,
    source_type TEXT,
    service    TEXT,
    metadata   JSONB
);

-- Metrics table: stores Vector internal metrics
CREATE TABLE IF NOT EXISTS metrics (
    timestamp  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    name       TEXT,
    kind       TEXT,
    tags       JSONB,
    counter    JSONB,
    gauge      JSONB,
    metadata   JSONB
);

-- Convert to TimescaleDB hypertables for efficient time-series queries
-- (only if TimescaleDB is available — fails gracefully on base flavor)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'timescaledb') THEN
        PERFORM create_hypertable('logs', 'timestamp', if_not_exists => TRUE);
        PERFORM create_hypertable('metrics', 'timestamp', if_not_exists => TRUE);
        RAISE NOTICE 'TimescaleDB hypertables created for logs and metrics';
    ELSE
        RAISE NOTICE 'TimescaleDB not available — using regular tables';
    END IF;
END
$$;

-- Create indexes for common query patterns
CREATE INDEX IF NOT EXISTS idx_logs_host ON logs (host, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_logs_service ON logs (service, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_metrics_name ON metrics (name, timestamp DESC);
