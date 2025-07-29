-- Extension initialization script
-- This script enables extensions based on environment variables

\echo 'Loading PostgreSQL extensions...'

-- Function to safely create extension if it doesn't exist
CREATE OR REPLACE FUNCTION enable_extension_if_available(ext_name TEXT)
RETURNS BOOLEAN AS $$
BEGIN
    EXECUTE format('CREATE EXTENSION IF NOT EXISTS %I', ext_name);
    RAISE NOTICE 'Extension % enabled successfully', ext_name;
    RETURN TRUE;
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'Failed to enable extension %: %', ext_name, SQLERRM;
        RETURN FALSE;
END;
$$ LANGUAGE plpgsql;

-- Enable core extensions that should always be available
SELECT enable_extension_if_available('plpgsql');  -- PL/pgSQL (usually default)

-- Enable extensions based on list from entrypoint script
DO $$
DECLARE
    ext_list TEXT;
    ext_name TEXT;
    ext_array TEXT[];
BEGIN
    -- Read extensions list from file created by entrypoint
    SELECT pg_read_file('/tmp/postgres_extensions.txt') INTO ext_list;
    ext_list := trim(ext_list);
    
    IF ext_list != '' THEN
        RAISE NOTICE 'Loading extensions: %', ext_list;
        -- Split comma-separated extensions
        ext_array := string_to_array(ext_list, ',');
        
        FOREACH ext_name IN ARRAY ext_array
        LOOP
            -- Trim whitespace and enable extension
            ext_name := trim(ext_name);
            IF ext_name != '' THEN
                -- Special handling for extensions with specific requirements
                CASE ext_name
                WHEN 'pg_net' THEN
                    RAISE NOTICE 'Skipping pg_net - will be handled by migration script';
                    CONTINUE;
                WHEN 'pg_cron' THEN
                    RAISE NOTICE 'Skipping pg_cron - will be created in postgres database';
                    CONTINUE;
                ELSE
                    PERFORM enable_extension_if_available(ext_name);
                END CASE;
            END IF;
        END LOOP;
    ELSE
        RAISE NOTICE 'No extensions specified in extensions file';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'Could not read extensions file, no custom extensions will be loaded';
END $$;

-- Note: Citus configuration is now handled at build-time in postgresql.conf
-- This avoids ALTER SYSTEM restrictions in initialization functions
SELECT CASE 
    WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'citus') 
    THEN 'Citus extension loaded successfully' 
    ELSE 'Citus extension not found'
END;

-- Create pg_cron in postgres database if requested
DO $$
BEGIN
    -- Check if pg_cron was requested
    IF EXISTS (
        SELECT 1 FROM (
            SELECT unnest(string_to_array(pg_read_file('/tmp/postgres_extensions.txt'), ',')) as ext
        ) t WHERE trim(t.ext) = 'pg_cron'
    ) THEN
        -- First ensure dblink is available
        CREATE EXTENSION IF NOT EXISTS dblink;
        -- Connect to postgres database and create pg_cron
        PERFORM dblink_exec('dbname=postgres', 'CREATE EXTENSION IF NOT EXISTS pg_cron');
        RAISE NOTICE 'pg_cron extension created in postgres database successfully';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'Could not create pg_cron extension in postgres database: %', SQLERRM;
END $$;

-- Clean up helper function
DROP FUNCTION IF EXISTS enable_extension_if_available(TEXT);

\echo 'Extension initialization completed!'
