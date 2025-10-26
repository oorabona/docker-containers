-- PostGIS Extension Examples
-- Geospatial data and location-based queries
-- 
-- Usage: docker compose exec postgres psql -U postgres -d myapp < examples/postgis_example.sql

\echo '🗺️ === PostGIS Examples - Geospatial Operations ==='

-- Create a table for locations
CREATE TABLE IF NOT EXISTS locations (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT,
    location GEOMETRY(POINT, 4326),  -- WGS84 coordinate system
    category TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Insert sample locations (famous landmarks)
INSERT INTO locations (name, description, location, category) VALUES 
    ('Eiffel Tower', 'Iconic iron tower in Paris', ST_GeomFromText('POINT(2.2945 48.8584)', 4326), 'landmark'),
    ('Times Square', 'Commercial intersection in NYC', ST_GeomFromText('POINT(-73.985 40.758)', 4326), 'landmark'),
    ('Tokyo Tower', 'Communications tower in Tokyo', ST_GeomFromText('POINT(139.7454 35.6586)', 4326), 'landmark'),
    ('Big Ben', 'Clock tower in London', ST_GeomFromText('POINT(-0.1246 51.4994)', 4326), 'landmark'),
    ('Sydney Opera House', 'Multi-venue performing arts center', ST_GeomFromText('POINT(151.2153 -33.8568)', 4326), 'landmark'),
    ('Central Park', 'Urban park in Manhattan', ST_GeomFromText('POINT(-73.9654 40.7829)', 4326), 'park'),
    ('Golden Gate Bridge', 'Suspension bridge in San Francisco', ST_GeomFromText('POINT(-122.4783 37.8199)', 4326), 'bridge')
ON CONFLICT DO NOTHING;

-- Create spatial index for better performance
CREATE INDEX IF NOT EXISTS idx_locations_geom ON locations USING GIST (location);

\echo '📍 Locations table created with sample data and spatial index'

-- Example 1: Basic geometric operations
\echo '📐 Example 1: Basic geometric operations'
SELECT 
    name,
    ST_AsText(location) as coordinates,
    ST_X(location) as longitude,
    ST_Y(location) as latitude
FROM locations
LIMIT 3;

-- Example 2: Distance calculations
\echo '📏 Example 2: Calculate distances between locations'
SELECT 
    l1.name as from_location,
    l2.name as to_location,
    ROUND(ST_Distance(l1.location::geography, l2.location::geography) / 1000, 2) as distance_km
FROM locations l1, locations l2
WHERE l1.id < l2.id  -- Avoid duplicate pairs
ORDER BY ST_Distance(l1.location::geography, l2.location::geography)
LIMIT 5;

-- Example 3: Find nearby locations (within radius)
\echo '🎯 Example 3: Find locations within 50km of Paris (Eiffel Tower)'
WITH paris_location AS (
    SELECT location FROM locations WHERE name = 'Eiffel Tower'
)
SELECT 
    l.name,
    l.description,
    ROUND(ST_Distance(l.location::geography, p.location::geography) / 1000, 2) as distance_km
FROM locations l, paris_location p
WHERE ST_DWithin(l.location::geography, p.location::geography, 50000)  -- 50km in meters
  AND l.name != 'Eiffel Tower'
ORDER BY ST_Distance(l.location::geography, p.location::geography);

-- Example 4: Bounding box queries
\echo '📦 Example 4: Find locations within a bounding box (Europe approx.)'
SELECT 
    name,
    description,
    ST_AsText(location) as coordinates
FROM locations
WHERE ST_Contains(
    ST_MakeEnvelope(-10, 35, 40, 70, 4326),  -- Rough Europe bounding box
    location
);

-- Example 5: Create areas and check containment
\echo '🏙️ Example 5: Create city areas and check point containment'

-- Create a table for city areas
CREATE TABLE IF NOT EXISTS city_areas (
    id SERIAL PRIMARY KEY,
    city_name TEXT NOT NULL,
    area GEOMETRY(POLYGON, 4326)
);

-- Insert a rough polygon for Paris (very simplified)
INSERT INTO city_areas (city_name, area) VALUES 
    ('Paris', ST_GeomFromText('POLYGON((2.224 48.815, 2.469 48.815, 2.469 48.902, 2.224 48.902, 2.224 48.815))', 4326))
ON CONFLICT DO NOTHING;

-- Check which landmarks are within Paris area
SELECT 
    l.name as landmark,
    ca.city_name,
    ST_Contains(ca.area, l.location) as is_within_city
FROM locations l
CROSS JOIN city_areas ca
WHERE ca.city_name = 'Paris';

-- Example 6: Nearest neighbor search
\echo '🔍 Example 6: Find the 3 nearest landmarks to a given point'
WITH query_point AS (
    SELECT ST_GeomFromText('POINT(0 51.5)', 4326) as location  -- London coordinates
)
SELECT 
    l.name,
    l.category,
    ROUND(ST_Distance(l.location::geography, q.location::geography) / 1000, 2) as distance_km
FROM locations l, query_point q
ORDER BY l.location <-> q.location  -- KNN operator for nearest neighbor
LIMIT 3;

-- Example 7: Spatial aggregation
\echo '📊 Example 7: Spatial aggregation - center point of all landmarks'
SELECT 
    ST_AsText(ST_Centroid(ST_Collect(location))) as center_point,
    COUNT(*) as total_locations,
    ST_AsText(ST_Envelope(ST_Collect(location))) as bounding_box
FROM locations;

-- Example 8: Create a function for location search
\echo '⚡ Example 8: Create reusable proximity search function'
CREATE OR REPLACE FUNCTION find_nearby_locations(
    search_lat FLOAT,
    search_lon FLOAT,
    radius_km FLOAT DEFAULT 10,
    location_category TEXT DEFAULT NULL
)
RETURNS TABLE(
    location_name TEXT,
    location_description TEXT,
    distance_km NUMERIC,
    coordinates TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        l.name,
        l.description,
        ROUND((ST_Distance(
            l.location::geography, 
            ST_GeomFromText('POINT(' || search_lon || ' ' || search_lat || ')', 4326)::geography
        ) / 1000)::numeric, 2),
        ST_AsText(l.location)
    FROM locations l
    WHERE ST_DWithin(
        l.location::geography,
        ST_GeomFromText('POINT(' || search_lon || ' ' || search_lat || ')', 4326)::geography,
        radius_km * 1000
    )
    AND (location_category IS NULL OR l.category = location_category)
    ORDER BY ST_Distance(
        l.location::geography,
        ST_GeomFromText('POINT(' || search_lon || ' ' || search_lat || ')', 4326)::geography
    );
END;
$$ LANGUAGE plpgsql;

-- Test the proximity search function
\echo '🧪 Testing proximity search function - landmarks within 100km of London'
SELECT * FROM find_nearby_locations(51.5074, -0.1278, 100, 'landmark');

-- Example 9: Advanced: Line and polygon operations
\echo '🛣️ Example 9: Working with lines (routes) and polygons'

-- Create a simple route
WITH route AS (
    SELECT ST_MakeLine(ARRAY[
        ST_GeomFromText('POINT(2.2945 48.8584)', 4326),  -- Eiffel Tower
        ST_GeomFromText('POINT(-0.1246 51.4994)', 4326)   -- Big Ben
    ]) as line_geom
)
SELECT 
    ST_AsText(line_geom) as route_wkt,
    ROUND(ST_Length(line_geom::geography) / 1000, 2) as route_length_km
FROM route;

\echo '✅ PostGIS examples completed!'
\echo '💡 Tip: PostGIS supports many more operations - buffers, intersections, spatial joins, etc.'