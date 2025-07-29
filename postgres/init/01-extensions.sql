-- Modern Extension Initialization (Refactored)
-- Uses centralized extension-manager logic for consistency
-- Simplified and optimized for the new architecture

\echo 'Initializing PostgreSQL extensions with modern approach...'

-- Create helper function for safe extension enabling
CREATE OR REPLACE FUNCTION enable_extension_safely(ext_name TEXT)
RETURNS BOOLEAN AS $$
BEGIN
    EXECUTE format('CREATE EXTENSION IF NOT EXISTS %I', ext_name);
    RAISE NOTICE '✅ Extension % enabled successfully', ext_name;
    RETURN TRUE;
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING '❌ Failed to enable extension %: %', ext_name, SQLERRM;
        RETURN FALSE;
END;
$$ LANGUAGE plpgsql;

-- Enable extensions from the extension-manager generated list
DO $$
DECLARE
    ext_list TEXT;
    ext_name TEXT;
    ext_array TEXT[];
    success_count INTEGER := 0;
    total_count INTEGER := 0;
BEGIN
    -- Read extensions list from file created by extension-manager
    BEGIN
        SELECT pg_read_file('/tmp/postgres_extensions.txt') INTO ext_list;
        ext_list := trim(ext_list);
    EXCEPTION
        WHEN OTHERS THEN
            RAISE NOTICE '🔍 No extensions file found, using minimal setup';
            ext_list := '';
    END;
    
    IF ext_list != '' THEN
        RAISE NOTICE '🔧 Loading extensions: %', ext_list;
        ext_array := string_to_array(ext_list, ',');
        
        FOREACH ext_name IN ARRAY ext_array
        LOOP
            ext_name := trim(ext_name);
            IF ext_name != '' THEN
                total_count := total_count + 1;
                
                -- Skip extensions that require shared_preload_libraries
                -- These are handled by the post-startup activation script
                CASE ext_name
                WHEN 'citus' THEN
                    RAISE NOTICE '⏭️  Skipping citus - handled by post-startup activation';
                    CONTINUE;
                WHEN 'pg_search' THEN
                    RAISE NOTICE '⏭️  Skipping pg_search - handled by post-startup activation';
                    CONTINUE;
                WHEN 'pg_net' THEN
                    RAISE NOTICE '⏭️  Skipping pg_net - handled by post-startup activation';
                    CONTINUE;
                WHEN 'pg_cron' THEN
                    RAISE NOTICE '⏭️  Skipping pg_cron - will be created in postgres database';
                    CONTINUE;
                ELSE
                    -- Enable regular extensions
                    IF enable_extension_safely(ext_name) THEN
                        success_count := success_count + 1;
                    END IF;
                END CASE;
            END IF;
        END LOOP;
        
        RAISE NOTICE '📊 Extension initialization: % successful out of % regular extensions', 
            success_count, total_count - 4; -- Subtract shared_preload extensions
    ELSE
        RAISE NOTICE '🔍 No extensions specified, using PostgreSQL defaults';
    END IF;
END $$;

-- Clean up helper function
DROP FUNCTION enable_extension_safely(TEXT);

\echo '✅ Extension initialization completed!'
\echo '🔄 Note: Extensions requiring shared_preload_libraries will be activated post-startup';