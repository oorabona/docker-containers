-- Citus Extension Examples
-- Distributed PostgreSQL for horizontal scaling
--
-- Usage: docker compose exec postgres psql -U postgres -d myapp < examples/citus_example.sql

\echo '🌐 === Citus Examples - Distributed PostgreSQL ==='

-- Check Citus cluster status
\echo '🔍 Example 1: Check Citus cluster configuration'
SELECT * FROM citus_version();

-- Show current nodes in the cluster
SELECT * FROM master_get_active_worker_nodes();

-- Example 2: Create distributed tables
\echo '📊 Example 2: Create and distribute tables'

-- Create a users table
CREATE TABLE IF NOT EXISTS users (
    user_id SERIAL,
    username TEXT NOT NULL,
    email TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (user_id)
);

-- Create an events table for analytics
CREATE TABLE IF NOT EXISTS events (
    event_id BIGSERIAL,
    user_id INT NOT NULL,
    event_type TEXT NOT NULL,
    event_data JSONB,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (event_id, user_id)  -- Include distribution column in PK
);

-- Create a products table
CREATE TABLE IF NOT EXISTS products (
    product_id SERIAL,
    name TEXT NOT NULL,
    category TEXT,
    price DECIMAL(10,2),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (product_id)
);

-- Create orders table
CREATE TABLE IF NOT EXISTS orders (
    order_id BIGSERIAL,
    user_id INT NOT NULL,
    product_id INT NOT NULL,
    quantity INT DEFAULT 1,
    order_total DECIMAL(10,2),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (order_id, user_id)  -- Include distribution column in PK
);

\echo '📋 Tables created, now distributing them across nodes...'

-- Distribute tables (this is what makes Citus special!)
SELECT create_distributed_table('users', 'user_id');
SELECT create_distributed_table('events', 'user_id');  -- Co-locate with users
SELECT create_distributed_table('orders', 'user_id');  -- Co-locate with users

-- Create reference table for products (replicated to all nodes)
SELECT create_reference_table('products');

\echo '✅ Tables distributed! Users, events, and orders are sharded by user_id'
\echo '📚 Products table is replicated as reference table'

-- Example 3: Insert sample data
\echo '📥 Example 3: Insert sample data across the cluster'

-- Insert users
INSERT INTO users (username, email) VALUES 
    ('alice', 'alice@example.com'),
    ('bob', 'bob@example.com'),
    ('charlie', 'charlie@example.com'),
    ('diana', 'diana@example.com'),
    ('eve', 'eve@example.com')
ON CONFLICT DO NOTHING;

-- Insert products (reference table - replicated everywhere)
INSERT INTO products (name, category, price) VALUES 
    ('Laptop', 'Electronics', 999.99),
    ('Mouse', 'Electronics', 29.99),
    ('Book', 'Education', 19.99),
    ('Coffee Mug', 'Home', 12.99),
    ('Headphones', 'Electronics', 199.99)
ON CONFLICT DO NOTHING;

-- Insert events (distributed by user_id)
INSERT INTO events (user_id, event_type, event_data) 
SELECT 
    u.user_id,
    'page_view',
    jsonb_build_object(
        'page', '/product/' || (1 + random() * 4)::int,
        'timestamp', NOW() - (random() * interval '30 days')
    )
FROM users u, generate_series(1, 10) -- 10 events per user
ON CONFLICT DO NOTHING;

-- Insert orders (distributed by user_id, co-located with users)
INSERT INTO orders (user_id, product_id, quantity, order_total)
SELECT 
    u.user_id,
    (1 + random() * 5)::int,
    (1 + random() * 3)::int,
    (20 + random() * 500)::decimal(10,2)
FROM users u, generate_series(1, 3) -- 3 orders per user
ON CONFLICT DO NOTHING;

\echo '📊 Sample data inserted across distributed tables'

-- Example 4: Distributed queries
\echo '🔍 Example 4: Distributed query examples'

-- Single-tenant query (efficient - uses single shard)
\echo '🎯 Single-tenant query (user_id = 1):'
SELECT 
    u.username,
    COUNT(e.event_id) as total_events,
    COUNT(o.order_id) as total_orders,
    SUM(o.order_total) as total_spent
FROM users u
LEFT JOIN events e ON u.user_id = e.user_id
LEFT JOIN orders o ON u.user_id = o.user_id
WHERE u.user_id = 1
GROUP BY u.user_id, u.username;

-- Multi-tenant analytics (distributed across all shards)
\echo '📈 Multi-tenant analytics query:'
SELECT 
    u.username,
    COUNT(DISTINCT e.event_id) as page_views,
    COUNT(DISTINCT o.order_id) as orders,
    COALESCE(SUM(o.order_total), 0) as total_revenue
FROM users u
LEFT JOIN events e ON u.user_id = e.user_id AND e.event_type = 'page_view'
LEFT JOIN orders o ON u.user_id = o.user_id
GROUP BY u.user_id, u.username
ORDER BY total_revenue DESC;

-- Example 5: Reference table joins (efficient)
\echo '🔗 Example 5: Joins with reference tables'
SELECT 
    p.name as product_name,
    p.category,
    COUNT(o.order_id) as times_ordered,
    SUM(o.quantity) as total_quantity,
    SUM(o.order_total) as total_revenue
FROM products p
JOIN orders o ON p.product_id = o.product_id
GROUP BY p.product_id, p.name, p.category
ORDER BY total_revenue DESC;

-- Example 6: Distributed aggregations
\echo '📊 Example 6: Distributed aggregations and window functions'
SELECT 
    DATE_TRUNC('day', created_at) as day,
    COUNT(*) as daily_events,
    COUNT(DISTINCT user_id) as active_users,
    AVG(COUNT(*)) OVER (
        ORDER BY DATE_TRUNC('day', created_at) 
        ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    ) as seven_day_avg_events
FROM events
GROUP BY DATE_TRUNC('day', created_at)
ORDER BY day DESC
LIMIT 10;

-- Example 7: Cross-shard operations (use carefully)
\echo '⚠️ Example 7: Cross-shard operations (expensive but sometimes necessary)'
WITH user_stats AS (
    SELECT 
        user_id,
        COUNT(*) as event_count,
        MAX(created_at) as last_activity
    FROM events
    GROUP BY user_id
),
order_stats AS (
    SELECT 
        user_id,
        COUNT(*) as order_count,
        SUM(order_total) as total_spent
    FROM orders
    GROUP BY user_id
)
SELECT 
    u.username,
    u.email,
    COALESCE(us.event_count, 0) as events,
    COALESCE(os.order_count, 0) as orders,
    COALESCE(os.total_spent, 0) as revenue,
    us.last_activity
FROM users u
LEFT JOIN user_stats us ON u.user_id = us.user_id
LEFT JOIN order_stats os ON u.user_id = os.user_id
ORDER BY revenue DESC;

-- Example 8: Citus utility functions
\echo '🛠️ Example 8: Citus utility and monitoring functions'

-- Check table distribution info
SELECT 
    schemaname,
    tablename,
    citus_table_type,
    distribution_column,
    shard_count
FROM citus_tables
WHERE schemaname = 'public';

-- View shard distribution
\echo '📊 Shard distribution across nodes:'
SELECT 
    nodename,
    nodeport,
    COUNT(*) as shard_count,
    SUM(shard_size) as total_size_bytes
FROM citus_shards cs
JOIN citus_shard_sizes css USING (shardid)
GROUP BY nodename, nodeport
ORDER BY nodename, nodeport;

-- Example 9: Citus-specific DDL operations
\echo '🔧 Example 9: Citus-specific schema operations'

-- Add an index to distributed table
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_events_created_at 
ON events (created_at);

-- Add a column to distributed table
ALTER TABLE events ADD COLUMN IF NOT EXISTS session_id TEXT;

-- Update statistics (important for query planning)
SELECT run_command_on_workers('ANALYZE events;');

-- Example 10: Monitoring and performance
\echo '📈 Example 10: Citus monitoring and performance queries'

-- Check query performance across workers
SELECT 
    query,
    calls,
    mean_exec_time,
    total_exec_time
FROM citus_stat_statements
WHERE query NOT LIKE '%pg_stat_statements%'
ORDER BY total_exec_time DESC
LIMIT 5;

-- Check worker node health
SELECT 
    nodename,
    nodeport,
    isactive,
    noderole,
    groupid
FROM pg_dist_node
ORDER BY groupid, nodename;

-- Example 11: Scaling operations
\echo '⚖️ Example 11: Scaling and rebalancing (simulation)'

-- Show current shard distribution
\echo 'Current shard distribution:'
SELECT 
    schemaname || '.' || tablename as table_name,
    COUNT(*) as shard_count,
    MIN(shard_size) as min_shard_size,
    MAX(shard_size) as max_shard_size,
    AVG(shard_size) as avg_shard_size
FROM citus_shards cs
JOIN citus_shard_sizes css USING (shardid)
WHERE schemaname = 'public'
GROUP BY schemaname, tablename;

-- In a real scenario, you would:
-- 1. Add new worker nodes: SELECT * FROM master_add_node('new-worker', 5432);
-- 2. Rebalance shards: SELECT rebalance_table_shards('users');
-- 3. Monitor the rebalancing: SELECT * FROM get_rebalance_progress();

-- Example 12: Tenant isolation patterns
\echo '🏢 Example 12: Tenant isolation and performance patterns'

-- Create tenant-aware view
CREATE OR REPLACE VIEW tenant_dashboard AS
SELECT 
    u.user_id as tenant_id,
    u.username as tenant_name,
    COUNT(DISTINCT e.event_id) as total_events,
    COUNT(DISTINCT o.order_id) as total_orders,
    SUM(o.order_total) as lifetime_value,
    MAX(e.created_at) as last_activity,
    COUNT(DISTINCT DATE(e.created_at)) as active_days
FROM users u
LEFT JOIN events e ON u.user_id = e.user_id
LEFT JOIN orders o ON u.user_id = o.user_id
GROUP BY u.user_id, u.username;

-- Query tenant dashboard (efficient single-tenant access)
\echo '🎯 Tenant-specific dashboard:'
SELECT * FROM tenant_dashboard WHERE tenant_id = 2;

-- Multi-tenant summary (cross-shard query)
\echo '📊 Multi-tenant summary:'
SELECT 
    COUNT(*) as total_tenants,
    AVG(total_events) as avg_events_per_tenant,
    AVG(total_orders) as avg_orders_per_tenant,
    SUM(lifetime_value) as total_platform_revenue
FROM tenant_dashboard;

\echo '✅ Citus examples completed!'
\echo '💡 Key Citus concepts demonstrated:'
\echo '  - Distributed tables (sharded by distribution column)'
\echo '  - Reference tables (replicated to all nodes)'
\echo '  - Co-location (related tables use same distribution column)'
\echo '  - Single-tenant vs multi-tenant query patterns'
\echo '  - Cross-shard operations and their cost'
\echo '  - Monitoring and scaling operations'
\echo '🚀 For production: Consider connection pooling, monitoring, and backup strategies'