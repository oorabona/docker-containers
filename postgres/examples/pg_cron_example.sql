-- pg_cron Extension Examples
-- Job scheduling and background task automation
--
-- Usage: docker compose exec postgres psql -U postgres -d postgres < examples/pg_cron_example.sql
-- Note: pg_cron jobs must be managed from the 'postgres' database

\echo '⏰ === pg_cron Examples - Job Scheduling ==='

-- Check if we're in the correct database
SELECT current_database() as current_db, 
       CASE WHEN current_database() = 'postgres' 
            THEN '✅ Correct database for pg_cron' 
            ELSE '❌ Switch to postgres database for pg_cron' 
       END as status;

-- Example 1: Simple scheduled job
\echo '🕐 Example 1: Schedule a simple job every minute'
SELECT cron.schedule(
    'test-job-every-minute',
    '* * * * *',  -- Every minute
    'INSERT INTO public.cron_log (message, executed_at) VALUES (''Hello from cron!'', NOW());'
);

-- Create a log table to track cron job executions
CREATE TABLE IF NOT EXISTS public.cron_log (
    id SERIAL PRIMARY KEY,
    message TEXT,
    executed_at TIMESTAMPTZ DEFAULT NOW()
);

-- Example 2: Daily cleanup job
\echo '🗑️ Example 2: Daily cleanup job at 2 AM'
SELECT cron.schedule(
    'daily-cleanup',
    '0 2 * * *',  -- Every day at 2:00 AM
    'DELETE FROM public.cron_log WHERE executed_at < NOW() - INTERVAL ''7 days'';'
);

-- Example 3: Weekly report generation
\echo '📊 Example 3: Weekly report job every Sunday at 6 AM'
SELECT cron.schedule(
    'weekly-report',
    '0 6 * * 0',  -- Every Sunday at 6:00 AM
    $$
    INSERT INTO public.cron_log (message, executed_at) 
    VALUES ('Weekly report generated: ' || (
        SELECT COUNT(*) || ' total log entries' 
        FROM public.cron_log 
        WHERE executed_at >= NOW() - INTERVAL '7 days'
    ), NOW());
    $$
);

-- Example 4: Custom business logic job
\echo '💼 Example 4: Business logic - user activity summary'

-- Create sample tables for business logic
CREATE TABLE IF NOT EXISTS public.user_activities (
    id SERIAL PRIMARY KEY,
    user_id INT NOT NULL,
    activity_type TEXT NOT NULL,
    activity_date DATE DEFAULT CURRENT_DATE,
    activity_count INT DEFAULT 1
);

CREATE TABLE IF NOT EXISTS public.daily_user_stats (
    id SERIAL PRIMARY KEY,
    user_id INT NOT NULL,
    activity_date DATE NOT NULL,
    total_activities INT DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(user_id, activity_date)
);

-- Insert sample activity data
INSERT INTO public.user_activities (user_id, activity_type, activity_date, activity_count) VALUES 
    (1, 'login', CURRENT_DATE, 5),
    (1, 'page_view', CURRENT_DATE, 25),
    (2, 'login', CURRENT_DATE, 3),
    (2, 'purchase', CURRENT_DATE, 2),
    (3, 'login', CURRENT_DATE, 1)
ON CONFLICT DO NOTHING;

-- Schedule job to aggregate daily user statistics
SELECT cron.schedule(
    'daily-user-stats',
    '0 1 * * *',  -- Every day at 1:00 AM
    $$
    INSERT INTO public.daily_user_stats (user_id, activity_date, total_activities)
    SELECT 
        user_id,
        activity_date,
        SUM(activity_count)
    FROM public.user_activities
    WHERE activity_date = CURRENT_DATE - INTERVAL '1 day'
    GROUP BY user_id, activity_date
    ON CONFLICT (user_id, activity_date) 
    DO UPDATE SET 
        total_activities = EXCLUDED.total_activities,
        created_at = NOW();
    $$
);

-- Example 5: Database maintenance job
\echo '🔧 Example 5: Database maintenance - vacuum and analyze'
SELECT cron.schedule(
    'db-maintenance',
    '0 3 * * 1',  -- Every Monday at 3:00 AM
    'VACUUM ANALYZE public.cron_log; VACUUM ANALYZE public.user_activities;'
);

-- Example 6: Conditional job with error handling
\echo '🛡️ Example 6: Job with error handling and conditions'
SELECT cron.schedule(
    'conditional-cleanup',
    '0 4 * * *',  -- Every day at 4:00 AM
    $$
    DO $$
    DECLARE
        old_count INT;
    BEGIN
        -- Count records to be deleted
        SELECT COUNT(*) INTO old_count 
        FROM public.cron_log 
        WHERE executed_at < NOW() - INTERVAL '30 days';
        
        -- Only proceed if there are records to delete
        IF old_count > 0 THEN
            DELETE FROM public.cron_log 
            WHERE executed_at < NOW() - INTERVAL '30 days';
            
            INSERT INTO public.cron_log (message, executed_at)
            VALUES ('Cleaned up ' || old_count || ' old log entries', NOW());
        ELSE
            INSERT INTO public.cron_log (message, executed_at)
            VALUES ('No old records to clean up', NOW());
        END IF;
        
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO public.cron_log (message, executed_at)
        VALUES ('Error in cleanup job: ' || SQLERRM, NOW());
    END $$;
    $$
);

-- Example 7: Multi-database job (cross-database operations)
\echo '🔄 Example 7: Cross-database operation'
SELECT cron.schedule(
    'cross-db-sync',
    '*/30 * * * *',  -- Every 30 minutes
    $$
    INSERT INTO public.cron_log (message, executed_at)
    VALUES ('Cross-database sync completed at ' || NOW(), NOW());
    $$
);

-- Example 8: View current cron jobs
\echo '📋 Example 8: List all scheduled cron jobs'
SELECT 
    jobid,
    schedule,
    command,
    nodename,
    nodeport,
    database,
    username,
    active,
    jobname
FROM cron.job
ORDER BY jobid;

-- Example 9: Job execution history
\echo '📈 Example 9: View job execution history'
SELECT 
    runid,
    jobid,
    database,
    username,
    command,
    status,
    return_message,
    start_time,
    end_time,
    end_time - start_time as duration
FROM cron.job_run_details
ORDER BY start_time DESC
LIMIT 10;

-- Example 10: Create a function for complex scheduled tasks
\echo '⚡ Example 10: Create reusable function for scheduled tasks'
CREATE OR REPLACE FUNCTION public.generate_daily_report()
RETURNS TEXT AS $$
DECLARE
    report_text TEXT;
    user_count INT;
    activity_count INT;
    today_date DATE := CURRENT_DATE;
BEGIN
    -- Get user statistics
    SELECT COUNT(DISTINCT user_id) INTO user_count
    FROM public.user_activities
    WHERE activity_date = today_date;
    
    -- Get total activities
    SELECT COALESCE(SUM(activity_count), 0) INTO activity_count
    FROM public.user_activities
    WHERE activity_date = today_date;
    
    -- Build report
    report_text := 'Daily Report for ' || today_date || E'\n' ||
                   '- Active users: ' || user_count || E'\n' ||
                   '- Total activities: ' || activity_count || E'\n' ||
                   '- Generated at: ' || NOW();
    
    -- Log the report
    INSERT INTO public.cron_log (message, executed_at)
    VALUES ('Daily report: ' || user_count || ' users, ' || activity_count || ' activities', NOW());
    
    RETURN report_text;
END;
$$ LANGUAGE plpgsql;

-- Schedule the daily report function
SELECT cron.schedule(
    'daily-report-function',
    '0 8 * * *',  -- Every day at 8:00 AM
    'SELECT public.generate_daily_report();'
);

-- Example 11: Manage jobs (unschedule/reschedule)
\echo '🎛️ Example 11: Job management operations'

-- Function to safely unschedule a job
CREATE OR REPLACE FUNCTION public.safe_unschedule_job(job_name TEXT)
RETURNS BOOLEAN AS $$
DECLARE
    job_exists BOOLEAN;
BEGIN
    -- Check if job exists
    SELECT EXISTS(SELECT 1 FROM cron.job WHERE jobname = job_name) INTO job_exists;
    
    IF job_exists THEN
        PERFORM cron.unschedule(job_name);
        INSERT INTO public.cron_log (message, executed_at)
        VALUES ('Job unscheduled: ' || job_name, NOW());
        RETURN TRUE;
    ELSE
        INSERT INTO public.cron_log (message, executed_at)
        VALUES ('Job not found for unscheduling: ' || job_name, NOW());
        RETURN FALSE;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Example of unscheduling (commented out to keep demo jobs)
-- SELECT public.safe_unschedule_job('test-job-every-minute');

-- Example 12: Monitor job performance
\echo '⚡ Example 12: Job performance monitoring'
SELECT 
    j.jobname,
    j.schedule,
    COUNT(jr.runid) as total_runs,
    COUNT(jr.runid) FILTER (WHERE jr.status = 'succeeded') as successful_runs,
    COUNT(jr.runid) FILTER (WHERE jr.status = 'failed') as failed_runs,
    AVG(EXTRACT(EPOCH FROM (jr.end_time - jr.start_time))) as avg_duration_seconds,
    MAX(jr.start_time) as last_run_time
FROM cron.job j
LEFT JOIN cron.job_run_details jr ON j.jobid = jr.jobid
WHERE j.active = true
GROUP BY j.jobid, j.jobname, j.schedule
ORDER BY j.jobname;

-- Wait a moment and show some log entries
\echo '⏳ Waiting for a few cron executions...'
SELECT pg_sleep(3);

-- Show recent cron log entries
\echo '📝 Recent cron job log entries:'
SELECT 
    message,
    executed_at,
    executed_at - LAG(executed_at) OVER (ORDER BY executed_at) as time_since_previous
FROM public.cron_log
ORDER BY executed_at DESC
LIMIT 10;

-- Show job status summary
\echo '📊 Cron jobs status summary:'
SELECT 
    COUNT(*) as total_jobs,
    COUNT(*) FILTER (WHERE active = true) as active_jobs,
    COUNT(*) FILTER (WHERE active = false) as inactive_jobs
FROM cron.job;

\echo '✅ pg_cron examples completed!'
\echo '💡 Tips:'
\echo '  - Always test cron expressions before scheduling'
\echo '  - Use fully qualified table names in cron jobs'
\echo '  - Monitor job execution via cron.job_run_details'
\echo '  - Consider time zones when scheduling jobs'
\echo '  - Use functions for complex job logic'
\echo '⚠️  Remember: pg_cron jobs run in the postgres database context'