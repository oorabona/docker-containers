-- Security initialization script
-- Sets up Row Level Security examples and secure defaults

\echo 'Setting up security configurations...'

-- Create example schema for RLS demonstrations
CREATE SCHEMA IF NOT EXISTS security_examples;

-- Example: Multi-tenant table with RLS
CREATE TABLE IF NOT EXISTS security_examples.tenant_data (
    id SERIAL PRIMARY KEY,
    tenant_id TEXT NOT NULL,
    data JSONB,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Enable RLS on the table
ALTER TABLE security_examples.tenant_data ENABLE ROW LEVEL SECURITY;

-- Create RLS policy for tenant isolation
CREATE POLICY tenant_isolation ON security_examples.tenant_data
    FOR ALL TO PUBLIC
    USING (tenant_id = current_setting('app.current_tenant', true));

-- Example: User-based access control table
CREATE TABLE IF NOT EXISTS security_examples.user_documents (
    id SERIAL PRIMARY KEY,
    user_id TEXT NOT NULL,
    title TEXT,
    content TEXT,
    is_public BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Enable RLS
ALTER TABLE security_examples.user_documents ENABLE ROW LEVEL SECURITY;

-- Policy: Users can only see their own documents or public ones
CREATE POLICY user_document_access ON security_examples.user_documents
    FOR SELECT TO PUBLIC
    USING (user_id = current_user OR is_public = TRUE);

-- Policy: Users can only modify their own documents
CREATE POLICY user_document_modify ON security_examples.user_documents
    FOR ALL TO PUBLIC
    USING (user_id = current_user);

-- Create security functions for common patterns
CREATE OR REPLACE FUNCTION security_examples.set_current_tenant(tenant TEXT)
RETURNS void AS $$
BEGIN
    PERFORM set_config('app.current_tenant', tenant, true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to get current tenant
CREATE OR REPLACE FUNCTION security_examples.get_current_tenant()
RETURNS TEXT AS $$
BEGIN
    RETURN current_setting('app.current_tenant', true);
END;
$$ LANGUAGE plpgsql;

-- Grant usage on schema
GRANT USAGE ON SCHEMA security_examples TO PUBLIC;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA security_examples TO PUBLIC;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA security_examples TO PUBLIC;

-- Set default privileges for future objects
ALTER DEFAULT PRIVILEGES IN SCHEMA security_examples 
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA security_examples 
    GRANT USAGE, SELECT ON SEQUENCES TO PUBLIC;

\echo 'Security configuration completed!'
\echo 'Example usage:'
\echo '  SELECT security_examples.set_current_tenant(''tenant1'');'
\echo '  INSERT INTO security_examples.tenant_data (tenant_id, data) VALUES (''tenant1'', ''{"test": true}'');'
