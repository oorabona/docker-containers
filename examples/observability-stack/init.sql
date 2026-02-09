-- Observability schema for Vector → PostgreSQL pipeline
-- TimescaleDB hypertables for efficient time-series storage

CREATE TABLE IF NOT EXISTS logs (
    timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    host VARCHAR(255),
    source_type VARCHAR(100),
    message TEXT,
    metadata JSONB DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS metrics (
    timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    name VARCHAR(255) NOT NULL,
    value DOUBLE PRECISION,
    tags JSONB DEFAULT '{}'::jsonb
);

-- Convert to hypertables if TimescaleDB is available
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'timescaledb') THEN
        PERFORM create_hypertable('logs', 'timestamp', if_not_exists => TRUE);
        PERFORM create_hypertable('metrics', 'timestamp', if_not_exists => TRUE);

        RAISE NOTICE 'TimescaleDB hypertables created';
    ELSE
        -- Fallback: standard indexes
        CREATE INDEX IF NOT EXISTS idx_logs_timestamp ON logs (timestamp DESC);
        CREATE INDEX IF NOT EXISTS idx_metrics_timestamp ON metrics (timestamp DESC);
        CREATE INDEX IF NOT EXISTS idx_metrics_name ON metrics (name, timestamp DESC);
        RAISE NOTICE 'Standard indexes created (TimescaleDB not available)';
    END IF;
END $$;

-- GIN index for JSONB metadata queries
CREATE INDEX IF NOT EXISTS idx_logs_metadata ON logs USING gin (metadata);
CREATE INDEX IF NOT EXISTS idx_metrics_tags ON metrics USING gin (tags);
