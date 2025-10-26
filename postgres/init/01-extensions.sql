-- Modern Extension Initialization
-- Handles extension creation with proper database context

\echo 'Initializing PostgreSQL extensions...'

-- Create helper function for safe extension enabling
CREATE OR REPLACE FUNCTION enable_extension_safely(ext_name TEXT, target_db TEXT DEFAULT NULL)
RETURNS BOOLEAN AS $$
BEGIN
    -- pg_cron must be created in postgres database only
    IF ext_name = 'pg_cron' AND current_database() != 'postgres' THEN
        RAISE NOTICE '⏭️  Skipping pg_cron - must be created in postgres database only';
        RETURN FALSE;
    END IF;
    
    EXECUTE format('CREATE EXTENSION IF NOT EXISTS %I', ext_name);
    RAISE NOTICE '✅ Extension % enabled successfully in database %', ext_name, current_database();
    RETURN TRUE;
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING '❌ Failed to enable extension %: %', ext_name, SQLERRM;
        RETURN FALSE;
END;
$$ LANGUAGE plpgsql;

-- Enable extensions from the configuration file
DO $$
DECLARE
    ext_list TEXT;
    ext_name TEXT;
    ext_array TEXT[];
    success_count INTEGER := 0;
    total_count INTEGER := 0;
    skip_count INTEGER := 0;
    current_db TEXT;
BEGIN
    -- Get current database name
    SELECT current_database() INTO current_db;
    RAISE NOTICE '🔧 Initializing extensions for database: %', current_db;
    
    -- Read extensions list from file
    BEGIN
        SELECT pg_read_file('/etc/postgresql/postgres_extensions.txt') INTO ext_list;
        ext_list := trim(ext_list);
    EXCEPTION
        WHEN OTHERS THEN
            RAISE NOTICE '🔍 No extensions file found, using minimal setup';
            ext_list := '';
    END;
    
    IF ext_list != '' THEN
        RAISE NOTICE '📦 Extensions to install: %', ext_list;
        ext_array := string_to_array(ext_list, ',');
        
        FOREACH ext_name IN ARRAY ext_array
        LOOP
            ext_name := trim(ext_name);
            IF ext_name != '' THEN
                total_count := total_count + 1;
                
                -- Handle special cases
                CASE 
                -- Extensions that require shared_preload_libraries and are handled elsewhere
                WHEN ext_name IN ('citus', 'pg_search', 'pg_net') AND 
                     EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = ext_name AND installed_version IS NULL) THEN
                    RAISE NOTICE '⏭️  Skipping % - requires server restart with shared_preload_libraries', ext_name;
                    skip_count := skip_count + 1;
                    CONTINUE;
                
                -- Extensions from postgresql-contrib (handle name variations)
                WHEN ext_name IN ('pgcrypto', 'uuid-ossp', 'pg_trgm', 'btree_gin', 'btree_gist', 'pg_stat_statements') THEN
                    IF enable_extension_safely(ext_name) THEN
                        success_count := success_count + 1;
                    END IF;
                
                -- pgvector can be specified as either 'pg_vector' or 'vector' 
                WHEN ext_name IN ('pg_vector', 'vector') THEN
                    IF enable_extension_safely('vector') THEN
                        success_count := success_count + 1;
                    END IF;
                
                -- Default case
                ELSE
                    IF enable_extension_safely(ext_name) THEN
                        success_count := success_count + 1;
                    END IF;
                END CASE;
            END IF;
        END LOOP;
        
        RAISE NOTICE '📊 Extension initialization summary:';
        RAISE NOTICE '   - Total requested: %', total_count;
        RAISE NOTICE '   - Successfully installed: %', success_count;
        RAISE NOTICE '   - Skipped (requires restart): %', skip_count;
        RAISE NOTICE '   - Failed: %', total_count - success_count - skip_count;
    ELSE
        RAISE NOTICE '🔍 No extensions specified, using PostgreSQL defaults';
    END IF;
    
    -- Special handling for pg_cron in postgres database
    IF current_db = 'postgres' AND ext_list LIKE '%pg_cron%' THEN
        RAISE NOTICE '🔧 Enabling pg_cron in postgres database...';
        IF enable_extension_safely('pg_cron') THEN
            RAISE NOTICE '✅ pg_cron enabled successfully in postgres database';
            -- Grant usage to other users if needed
            EXECUTE 'GRANT USAGE ON SCHEMA cron TO PUBLIC';
        END IF;
    END IF;
END $$;

-- Create partman schema if pg_partman is requested
DO $$
DECLARE
    ext_list TEXT;
BEGIN
    SELECT pg_read_file('/etc/postgresql/postgres_extensions.txt') INTO ext_list;
    IF ext_list LIKE '%pg_partman%' THEN
        CREATE SCHEMA IF NOT EXISTS partman;
        IF enable_extension_safely('pg_partman') THEN
            RAISE NOTICE '✅ pg_partman enabled in partman schema';
        END IF;
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        -- Ignore if file doesn't exist
        NULL;
END $$;

-- Clean up helper function
DROP FUNCTION enable_extension_safely(TEXT, TEXT);

\echo '✅ Extension initialization completed!'
\echo '💡 Note: Some extensions may require server restart with shared_preload_libraries'