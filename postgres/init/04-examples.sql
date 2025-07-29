-- Usage examples for modern PostgreSQL extensions
-- Demonstrates vector search, geospatial queries, and analytics

\echo 'Setting up usage examples...'

-- Vector Search Examples (requires vector extension)
DO $$
    BEGIN
        IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'vector') THEN
            RAISE NOTICE 'Setting up vector search examples...';
            
            CREATE SCHEMA IF NOT EXISTS ai_examples;
            
            -- Documents table with vector embeddings
            CREATE TABLE IF NOT EXISTS ai_examples.documents (
                id SERIAL PRIMARY KEY,
                title TEXT,
                content TEXT,
                embedding vector(1536),  -- OpenAI embedding dimension
                metadata JSONB,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );
            
            -- Vector similarity index (will be created later when we have data)
            -- CREATE INDEX IF NOT EXISTS documents_embedding_idx 
            --     ON ai_examples.documents USING ivfflat (embedding vector_cosine_ops);
            
            -- Function for semantic search (inside conditional block)
            EXECUTE 'CREATE OR REPLACE FUNCTION ai_examples.semantic_search(
                query_embedding vector(1536),
                similarity_threshold float DEFAULT 0.8,
                max_results int DEFAULT 10
            )
            RETURNS TABLE(id int, title text, content text, similarity float) AS $FUNC$
            BEGIN
                RETURN QUERY
                SELECT 
                    d.id,
                    d.title,
                    d.content,
                    1 - (d.embedding <=> query_embedding) as similarity
                FROM ai_examples.documents d
                WHERE 1 - (d.embedding <=> query_embedding) > similarity_threshold
                ORDER BY d.embedding <=> query_embedding
                LIMIT max_results;
            END;
            $FUNC$ LANGUAGE plpgsql';
            
            -- Example data (with dummy embeddings) - inside conditional block
            INSERT INTO ai_examples.documents (title, content, embedding, metadata) VALUES
            ('AI Introduction', 'Artificial Intelligence is transforming technology', 
             array_fill(0.1, ARRAY[1536])::vector, '{"category": "tech", "author": "system"}'),
            ('Machine Learning Basics', 'ML algorithms learn from data patterns',
             array_fill(0.2, ARRAY[1536])::vector, '{"category": "tech", "author": "system"}')
            ON CONFLICT DO NOTHING;
            
            GRANT USAGE ON SCHEMA ai_examples TO PUBLIC;
            GRANT ALL ON ALL TABLES IN SCHEMA ai_examples TO PUBLIC;  
            GRANT ALL ON ALL SEQUENCES IN SCHEMA ai_examples TO PUBLIC;
            
        ELSE
            RAISE NOTICE 'pg_vector not available, skipping vector examples';
        END IF;
    END $$;

-- PostGIS Examples (requires postgis)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'postgis') THEN
        RAISE NOTICE 'Setting up PostGIS examples...';
        
        CREATE SCHEMA IF NOT EXISTS geo_examples;
        
        -- Locations table
        CREATE TABLE IF NOT EXISTS geo_examples.locations (
            id SERIAL PRIMARY KEY,
            name TEXT,
            location GEOMETRY(POINT, 4326),
            properties JSONB,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
        
        -- Spatial index
        CREATE INDEX IF NOT EXISTS locations_geom_idx
            ON geo_examples.locations USING GIST (location);
        
        -- Function for nearby search
        CREATE OR REPLACE FUNCTION geo_examples.find_nearby(
            center_lat float,
            center_lon float,
            radius_km float DEFAULT 10
        )
        RETURNS TABLE(id int, name text, distance_km float) AS $func$
        BEGIN
            RETURN QUERY
            SELECT 
                l.id,
                l.name,
                ST_Distance(l.location, ST_SetSRID(ST_MakePoint(center_lon, center_lat), 4326)::geography) / 1000 as distance_km
            FROM geo_examples.locations l
            WHERE ST_DWithin(l.location::geography, ST_SetSRID(ST_MakePoint(center_lon, center_lat), 4326)::geography, radius_km * 1000)
            ORDER BY l.location <-> ST_SetSRID(ST_MakePoint(center_lon, center_lat), 4326);
        END;
        $func$ LANGUAGE plpgsql;
        
        -- Example data
        INSERT INTO geo_examples.locations (name, location, properties) VALUES
        ('Eiffel Tower', ST_SetSRID(ST_MakePoint(2.2945, 48.8584), 4326), '{"type": "landmark", "country": "France"}'),
        ('Central Park', ST_SetSRID(ST_MakePoint(-73.9654, 40.7829), 4326), '{"type": "park", "country": "USA"}')
        ON CONFLICT DO NOTHING;
        
        GRANT USAGE ON SCHEMA geo_examples TO PUBLIC;
        GRANT ALL ON ALL TABLES IN SCHEMA geo_examples TO PUBLIC;
        GRANT ALL ON ALL SEQUENCES IN SCHEMA geo_examples TO PUBLIC;
    END IF;
END $$;

-- Analytics Examples (requires pg_partman or manual partitioning)
DO $$
BEGIN
    RAISE NOTICE 'Setting up analytics examples...';
    
    CREATE SCHEMA IF NOT EXISTS analytics_examples;
    
    -- Events table for analytics (with time-based partitioning)
    CREATE TABLE IF NOT EXISTS analytics_examples.events (
        id SERIAL,
        event_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        event_type TEXT,
        user_id TEXT,
        properties JSONB,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (id, event_time)
    ) PARTITION BY RANGE (event_time);

        -- Create partition for 2024 data
        CREATE TABLE IF NOT EXISTS analytics_examples.events_2024 
            PARTITION OF analytics_examples.events
            FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');

        -- Create partition for 2025 data  
        CREATE TABLE IF NOT EXISTS analytics_examples.events_2025
            PARTITION OF analytics_examples.events
            FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');

        -- Index for time-series queries
        CREATE INDEX IF NOT EXISTS events_time_idx 
            ON analytics_examples.events (event_time);

        -- Sample data for analytics
        INSERT INTO analytics_examples.events (event_type, user_id, properties) VALUES
        ('page_view', 'user123', '{"page": "/home", "duration": 30}'),
        ('purchase', 'user456', '{"product": "laptop", "amount": 999.99}'),
        ('signup', 'user789', '{"method": "email", "source": "organic"}');

        GRANT USAGE ON SCHEMA analytics_examples TO PUBLIC;
        GRANT ALL ON ALL TABLES IN SCHEMA analytics_examples TO PUBLIC;
        GRANT ALL ON ALL SEQUENCES IN SCHEMA analytics_examples TO PUBLIC;
END $$;
-- PostGIS Examples (requires postgis)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'postgis') THEN
        RAISE NOTICE 'Setting up PostGIS examples...';
        
        CREATE SCHEMA IF NOT EXISTS geo_examples;
        
        -- Locations table
        CREATE TABLE IF NOT EXISTS geo_examples.locations (
            id SERIAL PRIMARY KEY,
            name TEXT,
            location GEOMETRY(POINT, 4326),
            properties JSONB,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
        
        -- Spatial index
        CREATE INDEX IF NOT EXISTS locations_geom_idx 
            ON geo_examples.locations USING GIST (location);
        
        -- Function for nearby search
        CREATE OR REPLACE FUNCTION geo_examples.find_nearby(
            center_lat float,
            center_lon float,
            radius_km float DEFAULT 10
        )
        RETURNS TABLE(id int, name text, distance_km float) AS $func$
        BEGIN
            RETURN QUERY
            SELECT 
                l.id,
                l.name,
                ST_Distance(l.location, ST_SetSRID(ST_MakePoint(center_lon, center_lat), 4326)::geography) / 1000 as distance_km
            FROM geo_examples.locations l
            WHERE ST_DWithin(l.location::geography, ST_SetSRID(ST_MakePoint(center_lon, center_lat), 4326)::geography, radius_km * 1000)
            ORDER BY l.location <-> ST_SetSRID(ST_MakePoint(center_lon, center_lat), 4326);
        END;
        $func$ LANGUAGE plpgsql;
        
        -- Example locations
        INSERT INTO geo_examples.locations (name, location, properties) VALUES
        ('Paris', ST_SetSRID(ST_MakePoint(2.3522, 48.8566), 4326), '{"country": "France", "type": "city"}'),
        ('London', ST_SetSRID(ST_MakePoint(-0.1276, 51.5074), 4326), '{"country": "UK", "type": "city"}'),
        ('New York', ST_SetSRID(ST_MakePoint(-74.0060, 40.7128), 4326), '{"country": "USA", "type": "city"}')
        ON CONFLICT DO NOTHING;
        
        GRANT USAGE ON SCHEMA geo_examples TO PUBLIC;
        GRANT ALL ON ALL TABLES IN SCHEMA geo_examples TO PUBLIC;
        GRANT ALL ON ALL SEQUENCES IN SCHEMA geo_examples TO PUBLIC;
    END IF;
END $$;

-- pg_cron Examples (requires pg_cron)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        RAISE NOTICE 'Setting up pg_cron examples...';
        
        -- Example: Daily cleanup job (only if vector extension exists)
        IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'vector') THEN
            SELECT cron.schedule('daily-cleanup', '0 2 * * *', 
                'DELETE FROM ai_examples.documents WHERE created_at < NOW() - INTERVAL ''30 days'';');
        END IF;
        
        -- Example: Update statistics weekly
        SELECT cron.schedule('weekly-stats', '0 1 * * 0',
            'ANALYZE;');
            
        RAISE NOTICE 'Scheduled jobs created. View with: SELECT * FROM cron.job;';
    END IF;
END $$;

-- Analytics Examples (if available)
CREATE SCHEMA IF NOT EXISTS analytics_examples;

-- Time-series like table for analytics
CREATE TABLE IF NOT EXISTS analytics_examples.events (
    id SERIAL PRIMARY KEY,
    event_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    event_type TEXT,
    user_id TEXT,
    properties JSONB,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Partitioning by time (manual example - pg_partman would automate this)
CREATE TABLE IF NOT EXISTS analytics_examples.events_2024 
    PARTITION OF analytics_examples.events
    FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');

-- Index for time-series queries
CREATE INDEX IF NOT EXISTS events_time_idx 
    ON analytics_examples.events (event_time);

-- Example analytical function
CREATE OR REPLACE FUNCTION analytics_examples.daily_user_stats(start_date date, end_date date)
RETURNS TABLE(date date, unique_users bigint, total_events bigint) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        event_time::date as date,
        COUNT(DISTINCT user_id) as unique_users,
        COUNT(*) as total_events
    FROM analytics_examples.events
    WHERE event_time::date BETWEEN start_date AND end_date
    GROUP BY event_time::date
    ORDER BY date;
END;
$$ LANGUAGE plpgsql;

-- Sample data
INSERT INTO analytics_examples.events (event_type, user_id, properties) VALUES
('page_view', 'user1', '{"page": "/home", "referrer": "google"}'),
('click', 'user1', '{"element": "button", "page": "/home"}'),
('page_view', 'user2', '{"page": "/about", "referrer": "direct"}')
ON CONFLICT DO NOTHING;

GRANT USAGE ON SCHEMA analytics_examples TO PUBLIC;
GRANT ALL ON ALL TABLES IN SCHEMA analytics_examples TO PUBLIC;
GRANT ALL ON ALL SEQUENCES IN SCHEMA analytics_examples TO PUBLIC;

\echo 'Usage examples setup completed!'
\echo ''
\echo 'Example queries to try:'  
\echo '  -- Vector search (if pg_vector enabled):'
\echo '  SELECT * FROM ai_examples.semantic_search(array_fill(0.1, ARRAY[1536])::vector);'
\echo ''
\echo '  -- Geospatial search (if PostGIS enabled):'
\echo '  SELECT * FROM geo_examples.find_nearby(48.8566, 2.3522, 50);'  
\echo ''
\echo '  -- Analytics query:'
\echo '  SELECT * FROM analytics_examples.daily_user_stats(CURRENT_DATE - 7, CURRENT_DATE);'
