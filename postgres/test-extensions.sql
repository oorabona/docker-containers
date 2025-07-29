-- Test des fonctionnalités des extensions PostgreSQL

-- 1. Test pg_vector (recherche vectorielle)
\echo '=== Test pg_vector ==='
CREATE TABLE IF NOT EXISTS test_vectors (
    id SERIAL PRIMARY KEY,
    content TEXT,
    embedding vector(3)
);

INSERT INTO test_vectors (content, embedding) VALUES 
    ('test document 1', '[1,0,0]'),
    ('test document 2', '[0,1,0]'),
    ('test document 3', '[0,0,1]')
ON CONFLICT DO NOTHING;

-- Test recherche par similarité
SELECT content, embedding <-> '[1,0,0]'::vector as distance 
FROM test_vectors 
ORDER BY distance 
LIMIT 2;

-- 2. Test PostGIS (géospatial)
\echo '=== Test PostGIS ==='
SELECT ST_AsText(ST_Point(2.3522, 48.8566)) as paris_point;

-- 3. Test pg_search (recherche full-text BM25)
\echo '=== Test pg_search ==='
-- Vérifier que pg_search est bien disponible
SELECT * FROM pg_available_extensions WHERE name = 'pg_search';

-- 4. Test pg_net (requêtes HTTP)
\echo '=== Test pg_net ==='
-- Vérifier que les tables pg_net existent
SELECT schemaname, tablename FROM pg_tables WHERE schemaname = 'net';

-- 5. Test pgjwt (JWT)
\echo '=== Test pgjwt ==='
SELECT sign('{"sub":"1234567890","name":"John Doe","iat":1516239022}', 'secret') as jwt_token;

-- 6. Test pg_cron (dans postgres database)
\echo '=== Test pg_cron (will connect to postgres db) ==='

-- 7. Test pgcrypto
\echo '=== Test pgcrypto ==='
SELECT encode(digest('Hello World', 'sha256'), 'hex') as sha256_hash;

-- 8. Test uuid-ossp
\echo '=== Test uuid-ossp ==='
SELECT uuid_generate_v4() as random_uuid;

-- Nettoyage
DROP TABLE IF EXISTS test_vectors;
