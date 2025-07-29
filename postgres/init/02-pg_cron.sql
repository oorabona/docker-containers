-- pg_cron extension setup
-- This script creates pg_cron in the postgres database where it must be installed

\echo 'Setting up pg_cron extension...'

-- Check if pg_cron is in the extensions list and create in postgres database
DO $$
DECLARE
    ext_list TEXT;
BEGIN
    -- Read extensions list from file created by entrypoint
    SELECT pg_read_file('/tmp/postgres_extensions.txt') INTO ext_list;
    ext_list := trim(ext_list);
    
    -- Check if pg_cron was requested
    IF ext_list LIKE '%pg_cron%' THEN
        -- First ensure dblink is available for cross-database operations
        CREATE EXTENSION IF NOT EXISTS dblink;
        
        -- Connect to postgres database and create pg_cron
        BEGIN
            PERFORM dblink_exec('dbname=postgres', 'CREATE EXTENSION IF NOT EXISTS pg_cron');
            RAISE NOTICE '✅ pg_cron extension created in postgres database successfully';
        EXCEPTION
            WHEN OTHERS THEN
                RAISE WARNING '❌ Could not create pg_cron extension in postgres database: %', SQLERRM;
        END;
    ELSE
        RAISE NOTICE 'pg_cron not requested, skipping';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'Could not read extensions file or setup pg_cron: %', SQLERRM;
END $$;

\echo 'pg_cron extension setup completed!'