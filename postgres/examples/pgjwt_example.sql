-- pgjwt Extension Examples
-- JWT (JSON Web Token) creation and validation in PostgreSQL
--
-- Usage: docker compose exec postgres psql -U postgres -d myapp < examples/pgjwt_example.sql

\echo '🔐 === pgjwt Examples - JWT Token Operations ==='

-- Example 1: Create a simple JWT token
\echo '🎫 Example 1: Create a basic JWT token'
SELECT sign(
    '{"sub":"1234567890","name":"John Doe","iat":1516239022}',
    'your-256-bit-secret'
) as jwt_token;

-- Example 2: Create JWT with custom claims
\echo '📋 Example 2: JWT with custom application claims'
WITH user_claims AS (
    SELECT jsonb_build_object(
        'user_id', 12345,
        'username', 'john_doe',
        'email', 'john@example.com',
        'role', 'admin',
        'permissions', ARRAY['read', 'write', 'delete'],
        'iat', extract(epoch from now())::int,
        'exp', extract(epoch from now() + interval '1 hour')::int,
        'iss', 'myapp.com',
        'aud', 'myapp-users'
    ) as claims
)
SELECT 
    claims::text as token_payload,
    sign(claims::text, 'my-secret-key-change-in-production') as jwt_token
FROM user_claims;

-- Example 3: Verify JWT token
\echo '✅ Example 3: Verify and decode JWT token'
WITH test_token AS (
    SELECT sign(
        '{"user_id":999,"username":"test_user","exp":' || 
        extract(epoch from now() + interval '1 hour')::int || '}',
        'verification-secret'
    ) as token
)
SELECT 
    token as original_token,
    verify(token, 'verification-secret') as payload,
    verify(token, 'verification-secret')::json->>'user_id' as extracted_user_id,
    verify(token, 'verification-secret')::json->>'username' as extracted_username
FROM test_token;

-- Example 4: Create a user authentication system
\echo '👥 Example 4: User authentication system with JWT'

-- Create users table
CREATE TABLE IF NOT EXISTS app_users (
    id SERIAL PRIMARY KEY,
    username TEXT UNIQUE NOT NULL,
    email TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,  -- In real app, use bcrypt or similar
    role TEXT DEFAULT 'user',
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    last_login TIMESTAMPTZ
);

-- Insert sample users
INSERT INTO app_users (username, email, password_hash, role) VALUES 
    ('admin', 'admin@example.com', 'hashed_password_123', 'admin'),
    ('john_doe', 'john@example.com', 'hashed_password_456', 'user'),
    ('jane_smith', 'jane@example.com', 'hashed_password_789', 'moderator')
ON CONFLICT (username) DO NOTHING;

-- Function to generate JWT for authenticated user
CREATE OR REPLACE FUNCTION generate_user_jwt(
    p_username TEXT,
    p_password TEXT,  -- In real app, this would be hashed and compared
    p_secret TEXT DEFAULT 'default-jwt-secret-change-me'
)
RETURNS TABLE(
    success BOOLEAN,
    jwt_token TEXT,
    user_info JSONB,
    expires_at TIMESTAMPTZ
) AS $$
DECLARE
    user_record app_users%ROWTYPE;
    token_claims JSONB;
    expiry_time TIMESTAMPTZ;
BEGIN
    -- Find and validate user (simplified - in real app, verify password hash)
    SELECT * INTO user_record 
    FROM app_users 
    WHERE username = p_username 
      AND is_active = true;
    
    IF NOT FOUND THEN
        -- User not found or inactive
        RETURN QUERY SELECT 
            FALSE,
            NULL::TEXT,
            NULL::JSONB,
            NULL::TIMESTAMPTZ;
        RETURN;
    END IF;
    
    -- Update last login
    UPDATE app_users 
    SET last_login = NOW() 
    WHERE id = user_record.id;
    
    -- Set expiry time
    expiry_time := NOW() + INTERVAL '24 hours';
    
    -- Build JWT claims
    token_claims := jsonb_build_object(
        'sub', user_record.id,
        'username', user_record.username,
        'email', user_record.email,
        'role', user_record.role,
        'iat', extract(epoch from now())::int,
        'exp', extract(epoch from expiry_time)::int,
        'iss', 'myapp-auth-service',
        'aud', 'myapp-users'
    );
    
    -- Return success with JWT
    RETURN QUERY SELECT 
        TRUE,
        sign(token_claims::text, p_secret),
        jsonb_build_object(
            'user_id', user_record.id,
            'username', user_record.username,
            'email', user_record.email,
            'role', user_record.role
        ),
        expiry_time;
END;
$$ LANGUAGE plpgsql;

-- Test user authentication and JWT generation
\echo '🧪 Testing user authentication and JWT generation'
SELECT * FROM generate_user_jwt('john_doe', 'dummy_password');

-- Example 5: JWT token validation and user authorization
\echo '🔒 Example 5: JWT validation and authorization'
CREATE OR REPLACE FUNCTION validate_jwt_and_authorize(
    p_jwt_token TEXT,
    p_required_role TEXT DEFAULT 'user',
    p_secret TEXT DEFAULT 'default-jwt-secret-change-me'
)
RETURNS TABLE(
    is_valid BOOLEAN,
    user_id INT,
    username TEXT,
    user_role TEXT,
    is_authorized BOOLEAN,
    error_message TEXT
) AS $$
DECLARE
    decoded_payload JSONB;
    token_exp INT;
    current_time INT;
BEGIN
    BEGIN
        -- Verify and decode the JWT
        SELECT verify(p_jwt_token, p_secret)::jsonb INTO decoded_payload;
        
        -- Check if token is expired
        token_exp := (decoded_payload->>'exp')::int;
        current_time := extract(epoch from now())::int;
        
        IF token_exp < current_time THEN
            RETURN QUERY SELECT 
                FALSE, NULL::INT, NULL::TEXT, NULL::TEXT, FALSE, 'Token expired';
            RETURN;
        END IF;
        
        -- Check role authorization
        RETURN QUERY SELECT 
            TRUE,
            (decoded_payload->>'sub')::int,
            decoded_payload->>'username',
            decoded_payload->>'role',
            CASE 
                WHEN p_required_role = 'admin' THEN decoded_payload->>'role' = 'admin'
                WHEN p_required_role = 'moderator' THEN decoded_payload->>'role' IN ('admin', 'moderator')
                ELSE TRUE  -- 'user' level access
            END,
            NULL::TEXT;
            
    EXCEPTION WHEN OTHERS THEN
        RETURN QUERY SELECT 
            FALSE, NULL::INT, NULL::TEXT, NULL::TEXT, FALSE, 'Invalid token signature';
    END;
END;
$$ LANGUAGE plpgsql;

-- Test JWT validation with different roles
\echo '🧪 Testing JWT validation with role-based authorization'
WITH test_jwt AS (
    SELECT jwt_token FROM generate_user_jwt('admin', 'dummy_password') WHERE success = true
)
SELECT 
    'Admin accessing admin resource' as test_case,
    is_valid,
    username,
    user_role,
    is_authorized
FROM test_jwt, validate_jwt_and_authorize(test_jwt.jwt_token, 'admin');

-- Example 6: Create API session management
\echo '🗂️ Example 6: API session management with JWT'
CREATE TABLE IF NOT EXISTS user_sessions (
    id SERIAL PRIMARY KEY,
    user_id INT REFERENCES app_users(id),
    jwt_token_hash TEXT NOT NULL,  -- Store hash of JWT for revocation
    created_at TIMESTAMPTZ DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL,
    is_revoked BOOLEAN DEFAULT FALSE,
    revoked_at TIMESTAMPTZ,
    user_agent TEXT,
    ip_address INET
);

-- Function to create and store session
CREATE OR REPLACE FUNCTION create_user_session(
    p_username TEXT,
    p_password TEXT,
    p_user_agent TEXT DEFAULT NULL,
    p_ip_address INET DEFAULT NULL
)
RETURNS TABLE(
    success BOOLEAN,
    session_id INT,
    jwt_token TEXT,
    expires_at TIMESTAMPTZ
) AS $$
DECLARE
    auth_result RECORD;
    new_session_id INT;
BEGIN
    -- Generate JWT
    SELECT * INTO auth_result 
    FROM generate_user_jwt(p_username, p_password);
    
    IF NOT auth_result.success THEN
        RETURN QUERY SELECT FALSE, NULL::INT, NULL::TEXT, NULL::TIMESTAMPTZ;
        RETURN;
    END IF;
    
    -- Store session
    INSERT INTO user_sessions (user_id, jwt_token_hash, expires_at, user_agent, ip_address)
    VALUES (
        (auth_result.user_info->>'user_id')::int,
        md5(auth_result.jwt_token),  -- Store hash, not actual token
        auth_result.expires_at,
        p_user_agent,
        p_ip_address
    )
    RETURNING id INTO new_session_id;
    
    RETURN QUERY SELECT 
        TRUE,
        new_session_id,
        auth_result.jwt_token,
        auth_result.expires_at;
END;
$$ LANGUAGE plpgsql;

-- Test session creation
\echo '🧪 Testing session creation'
SELECT * FROM create_user_session('jane_smith', 'dummy_password', 'Mozilla/5.0', '192.168.1.100'::inet);

-- Example 7: Session revocation (logout)
\echo '🚪 Example 7: Session revocation (logout functionality)'
CREATE OR REPLACE FUNCTION revoke_session(p_jwt_token TEXT)
RETURNS BOOLEAN AS $$
DECLARE
    token_hash TEXT;
BEGIN
    token_hash := md5(p_jwt_token);
    
    UPDATE user_sessions 
    SET is_revoked = TRUE, revoked_at = NOW()
    WHERE jwt_token_hash = token_hash 
      AND is_revoked = FALSE
      AND expires_at > NOW();
    
    RETURN FOUND;
END;
$$ LANGUAGE plpgsql;

-- Example 8: Active sessions monitoring
\echo '📊 Example 8: Monitor active sessions'
SELECT 
    u.username,
    u.email,
    u.role,
    s.created_at as session_start,
    s.expires_at,
    s.user_agent,
    s.ip_address,
    CASE 
        WHEN s.is_revoked THEN 'Revoked'
        WHEN s.expires_at < NOW() THEN 'Expired'
        ELSE 'Active'
    END as session_status
FROM user_sessions s
JOIN app_users u ON s.user_id = u.id
ORDER BY s.created_at DESC
LIMIT 10;

-- Example 9: JWT with refresh token pattern
\echo '🔄 Example 9: Refresh token implementation'
CREATE OR REPLACE FUNCTION generate_token_pair(
    p_username TEXT,
    p_password TEXT
)
RETURNS TABLE(
    access_token TEXT,
    refresh_token TEXT,
    access_expires_at TIMESTAMPTZ,
    refresh_expires_at TIMESTAMPTZ
) AS $$
DECLARE
    user_record app_users%ROWTYPE;
    access_exp TIMESTAMPTZ;
    refresh_exp TIMESTAMPTZ;
    access_claims JSONB;
    refresh_claims JSONB;
BEGIN
    -- Validate user
    SELECT * INTO user_record 
    FROM app_users 
    WHERE username = p_username AND is_active = true;
    
    IF NOT FOUND THEN
        RETURN;
    END IF;
    
    -- Set expiry times
    access_exp := NOW() + INTERVAL '15 minutes';  -- Short-lived access token
    refresh_exp := NOW() + INTERVAL '7 days';     -- Long-lived refresh token
    
    -- Build access token claims
    access_claims := jsonb_build_object(
        'sub', user_record.id,
        'username', user_record.username,
        'email', user_record.email,
        'role', user_record.role,
        'type', 'access',
        'iat', extract(epoch from now())::int,
        'exp', extract(epoch from access_exp)::int
    );
    
    -- Build refresh token claims
    refresh_claims := jsonb_build_object(
        'sub', user_record.id,
        'type', 'refresh',
        'iat', extract(epoch from now())::int,
        'exp', extract(epoch from refresh_exp)::int
    );
    
    RETURN QUERY SELECT 
        sign(access_claims::text, 'access-secret'),
        sign(refresh_claims::text, 'refresh-secret'),
        access_exp,
        refresh_exp;
END;
$$ LANGUAGE plpgsql;

-- Test token pair generation
\echo '🧪 Testing access/refresh token pair generation'
SELECT 
    left(access_token, 50) || '...' as access_token_preview,
    left(refresh_token, 50) || '...' as refresh_token_preview,
    access_expires_at,
    refresh_expires_at
FROM generate_token_pair('admin', 'dummy_password');

-- Show session summary
\echo '📈 Session summary'
SELECT 
    COUNT(*) as total_sessions,
    COUNT(*) FILTER (WHERE is_revoked = FALSE AND expires_at > NOW()) as active_sessions,
    COUNT(*) FILTER (WHERE is_revoked = TRUE) as revoked_sessions,
    COUNT(*) FILTER (WHERE expires_at <= NOW()) as expired_sessions
FROM user_sessions;

\echo '✅ pgjwt examples completed!'
\echo '💡 Tips:'
\echo '  - Always use strong, unique secrets in production'
\echo '  - Consider using RS256 (RSA) instead of HS256 for better security'
\echo '  - Implement proper password hashing (bcrypt, scrypt, or Argon2)'
\echo '  - Store JWT secrets as environment variables, not in code'
\echo '🔒 Security: Never store JWT secrets in your database or version control!'