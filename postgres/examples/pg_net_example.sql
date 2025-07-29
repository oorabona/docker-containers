-- pg_net Extension Examples  
-- HTTP client for making requests directly from PostgreSQL
--
-- Usage: docker compose exec postgres psql -U postgres -d myapp < examples/pg_net_example.sql

\echo '🌐 === pg_net Examples - HTTP Client Operations ==='

-- Check if pg_net is properly configured
\echo '🔍 Checking pg_net configuration and tables'
SELECT schemaname, tablename 
FROM pg_tables 
WHERE schemaname = 'net'
ORDER BY tablename;

-- Example 1: Simple GET request
\echo '📥 Example 1: Simple HTTP GET request'
SELECT 
    status,
    content::json->>'origin' as client_ip,
    content::json->>'url' as requested_url
FROM net.http_get('https://httpbin.org/get');

-- Example 2: GET with custom headers
\echo '📋 Example 2: GET request with custom headers'
SELECT 
    status,
    content::json->>'headers'->>'User-Agent' as user_agent,
    content::json->>'headers'->>'Custom-Header' as custom_header
FROM net.http_get(
    'https://httpbin.org/get',
    headers => '{"User-Agent": "PostgreSQL-pg_net", "Custom-Header": "MyApp-v1.0"}'::jsonb
);

-- Example 3: POST request with JSON data
\echo '📤 Example 3: POST request with JSON payload'
SELECT 
    status,
    content::json->>'json' as received_json,
    content::json->>'data' as raw_data
FROM net.http_post(
    'https://httpbin.org/post',
    '{"event": "user_signup", "user_id": 12345, "timestamp": "2025-07-29T10:00:00Z"}',
    'application/json'
);

-- Example 4: Handling different HTTP status codes
\echo '🚦 Example 4: Testing different HTTP status codes'
WITH http_requests AS (
    SELECT 
        200 as expected_status,
        net.http_get('https://httpbin.org/status/200') as response
    UNION ALL
    SELECT 
        404 as expected_status,
        net.http_get('https://httpbin.org/status/404') as response
    UNION ALL
    SELECT 
        500 as expected_status,
        net.http_get('https://httpbin.org/status/500') as response
)
SELECT 
    expected_status,
    (response).status as actual_status,
    CASE 
        WHEN (response).status = expected_status THEN '✅ Expected'
        ELSE '❌ Unexpected'
    END as status_check
FROM http_requests;

-- Example 5: Working with JSON APIs
\echo '🔄 Example 5: Working with JSON APIs - JSONPlaceholder example'
WITH api_response AS (
    SELECT content::json as data  
    FROM net.http_get('https://jsonplaceholder.typicode.com/posts/1')
    WHERE status = 200
)
SELECT 
    data->>'title' as post_title,
    data->>'body' as post_body,
    data->>'userId' as user_id
FROM api_response;

-- Example 6: Batch HTTP requests (simulated async)
\echo '📊 Example 6: Multiple HTTP requests for data aggregation'
CREATE TABLE IF NOT EXISTS api_responses (
    id SERIAL PRIMARY KEY,
    request_url TEXT,
    response_status INT,
    response_data JSONB,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Store multiple API responses
INSERT INTO api_responses (request_url, response_status, response_data)
SELECT 
    'https://httpbin.org/get?page=' || i,
    (net.http_get('https://httpbin.org/get?page=' || i)).status,
    (net.http_get('https://httpbin.org/get?page=' || i)).content::jsonb
FROM generate_series(1, 3) as i;

-- Analyze the stored responses
SELECT 
    request_url,
    response_status,
    response_data->>'url' as requested_url,
    created_at
FROM api_responses
ORDER BY created_at DESC
LIMIT 5;

-- Example 7: Creating a webhook system
\echo '🔗 Example 7: Webhook notification system'
CREATE TABLE IF NOT EXISTS webhook_events (
    id SERIAL PRIMARY KEY,
    event_type TEXT NOT NULL,
    event_data JSONB,
    webhook_url TEXT,
    response_status INT,
    sent_at TIMESTAMPTZ DEFAULT NOW()
);

-- Function to send webhook notifications
CREATE OR REPLACE FUNCTION send_webhook(
    event_type TEXT,
    event_data JSONB,
    webhook_url TEXT DEFAULT 'https://httpbin.org/post'
)
RETURNS TABLE(
    event_id INT,
    status_code INT,
    success BOOLEAN
) AS $$
DECLARE
    new_event_id INT;
    response_status INT;
BEGIN
    -- Insert the event
    INSERT INTO webhook_events (event_type, event_data, webhook_url)
    VALUES (event_type, event_data, webhook_url)
    RETURNING id INTO new_event_id;
    
    -- Send the webhook
    SELECT (net.http_post(
        webhook_url,
        jsonb_build_object(
            'event_type', event_type,
            'event_data', event_data,
            'timestamp', NOW()
        )::text,
        'application/json'
    )).status INTO response_status;
    
    -- Update the event with response status
    UPDATE webhook_events 
    SET response_status = response_status 
    WHERE id = new_event_id;
    
    -- Return result
    RETURN QUERY SELECT 
        new_event_id,
        response_status,
        response_status BETWEEN 200 AND 299;
END;
$$ LANGUAGE plpgsql;

-- Test the webhook system
\echo '🧪 Testing webhook notification system'
SELECT * FROM send_webhook(
    'user_action',
    '{"user_id": 123, "action": "login", "ip": "192.168.1.1"}'::jsonb
);

-- Example 8: HTTP client with timeout and error handling
\echo '⏱️ Example 8: Request with timeout handling'
CREATE OR REPLACE FUNCTION safe_http_get(
    url TEXT,
    timeout_seconds INT DEFAULT 30
)
RETURNS TABLE(
    success BOOLEAN,
    status_code INT,
    response_body TEXT,
    error_message TEXT
) AS $$
DECLARE
    response net.http_response_result;
BEGIN
    BEGIN
        -- Make HTTP request
        SELECT * INTO response FROM net.http_get(url);
        
        -- Return success result
        RETURN QUERY SELECT 
            TRUE,
            response.status,
            response.content,
            NULL::TEXT;
            
    EXCEPTION WHEN OTHERS THEN
        -- Return error result
        RETURN QUERY SELECT 
            FALSE,
            NULL::INT,
            NULL::TEXT,
            SQLERRM;
    END;
END;
$$ LANGUAGE plpgsql;

-- Test safe HTTP function
\echo '🧪 Testing safe HTTP request function'
SELECT * FROM safe_http_get('https://httpbin.org/delay/2');  -- 2 second delay
SELECT * FROM safe_http_get('https://invalid-url-that-should-fail.com');

-- Example 9: Real-world integration - Weather API simulation
\echo '🌤️ Example 9: Weather API integration pattern'
CREATE TABLE IF NOT EXISTS weather_cache (
    id SERIAL PRIMARY KEY,
    location TEXT NOT NULL,
    temperature FLOAT,
    description TEXT,
    fetched_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(location)
);

-- Function to fetch and cache weather data
CREATE OR REPLACE FUNCTION fetch_weather(location_name TEXT)
RETURNS TABLE(
    location TEXT,
    temperature FLOAT,
    description TEXT,
    cache_status TEXT
) AS $$
DECLARE
    cached_data RECORD;
    api_response net.http_response_result;
BEGIN
    -- Check cache first (cache for 1 hour)
    SELECT * INTO cached_data 
    FROM weather_cache 
    WHERE location = location_name 
      AND fetched_at > NOW() - INTERVAL '1 hour';
    
    IF FOUND THEN
        -- Return cached data
        RETURN QUERY SELECT 
            cached_data.location,
            cached_data.temperature,
            cached_data.description,
            'cached'::TEXT;
    ELSE
        -- Simulate API call (using httpbin for demo)
        SELECT * INTO api_response 
        FROM net.http_get('https://httpbin.org/json');
        
        -- In real scenario, parse actual weather API response
        -- For demo, we'll use mock data
        INSERT INTO weather_cache (location, temperature, description)
        VALUES (location_name, 22.5, 'Partly cloudy')
        ON CONFLICT (location) DO UPDATE SET
            temperature = EXCLUDED.temperature,
            description = EXCLUDED.description,
            fetched_at = NOW();
        
        RETURN QUERY SELECT 
            location_name,
            22.5::FLOAT,
            'Partly cloudy'::TEXT,
            'fresh'::TEXT;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Test weather caching system
\echo '🧪 Testing weather API with caching'
SELECT * FROM fetch_weather('Paris');
SELECT * FROM fetch_weather('Paris');  -- Should return cached result

-- Show webhook events summary
\echo '📋 Webhook events summary'
SELECT 
    event_type,
    COUNT(*) as event_count,
    AVG(response_status) as avg_response_status,
    MAX(sent_at) as last_sent
FROM webhook_events
GROUP BY event_type;

-- Clean up example tables (optional)
-- DROP TABLE IF EXISTS api_responses;
-- DROP TABLE IF EXISTS webhook_events;
-- DROP TABLE IF EXISTS weather_cache;

\echo '✅ pg_net examples completed!'
\echo '💡 Tip: pg_net runs HTTP requests asynchronously via background worker'
\echo '🔒 Security: Configure pg_net carefully in production - consider network restrictions'