-- PostgreSQL Monitoring Setup (Consolidated)
-- Sets up performance monitoring and statistics collection

\echo 'Setting up PostgreSQL monitoring and statistics...'

-- Enable pg_stat_statements if available (handled by shared_preload_libraries)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_stat_statements') THEN
        -- Extension will be created by post-startup activation if needed
        RAISE NOTICE '📊 pg_stat_statements will be activated automatically if configured';
    ELSE
        RAISE NOTICE '⚠️  pg_stat_statements not available in this build';
    END IF;
END $$;

-- Create monitoring views for easy access to statistics
CREATE OR REPLACE VIEW pg_extension_status AS
SELECT 
    e.extname as extension_name,
    e.extversion as version,
    n.nspname as schema,
    CASE 
        WHEN e.extname = ANY('{citus,pg_search,pg_net,pg_cron}') 
        THEN 'shared_preload_libraries'
        ELSE 'regular'
    END as extension_type
FROM pg_extension e
JOIN pg_namespace n ON e.extnamespace = n.oid
ORDER BY extension_type, extension_name;

-- Create a simple health check function
CREATE OR REPLACE FUNCTION pg_container_health()
RETURNS TABLE(
    metric TEXT,
    value TEXT,
    status TEXT
) AS $$
BEGIN
    -- Extension count
    RETURN QUERY SELECT 
        'extensions_loaded'::TEXT,
        count(*)::TEXT,
        CASE WHEN count(*) > 3 THEN '✅ Good' ELSE '⚠️  Minimal' END
    FROM pg_extension WHERE extname != 'plpgsql';
    
    -- Database connections
    RETURN QUERY SELECT 
        'active_connections'::TEXT,
        count(*)::TEXT,
        '✅ Active'::TEXT
    FROM pg_stat_activity WHERE state = 'active';
    
    -- Cache hit ratio (if pg_stat_database is available)
    RETURN QUERY SELECT 
        'cache_hit_ratio'::TEXT,
        CASE 
            WHEN sum(blks_hit + blks_read) = 0 THEN '0%'
            ELSE round(100.0 * sum(blks_hit) / sum(blks_hit + blks_read), 2)::TEXT || '%'
        END,
        CASE 
            WHEN sum(blks_hit + blks_read) = 0 THEN '🔄 Starting'
            WHEN round(100.0 * sum(blks_hit) / sum(blks_hit + blks_read), 2) > 90 THEN '✅ Excellent'
            WHEN round(100.0 * sum(blks_hit) / sum(blks_hit + blks_read), 2) > 80 THEN '👍 Good'
            ELSE '⚠️  Poor'
        END
    FROM pg_stat_database;
END;
$$ LANGUAGE plpgsql;

-- Grant usage to postgres user
GRANT SELECT ON pg_extension_status TO PUBLIC;
GRANT EXECUTE ON FUNCTION pg_container_health() TO PUBLIC;

\echo '✅ Monitoring setup completed!'
\echo '💡 Use SELECT * FROM pg_extension_status; to see loaded extensions'
\echo '💡 Use SELECT * FROM pg_container_health(); for health status';