-- Sample schema for PHP application
CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    email VARCHAR(255) UNIQUE NOT NULL,
    name VARCHAR(255) NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Sample data
INSERT INTO users (email, name) VALUES
    ('admin@example.com', 'Admin User'),
    ('user@example.com', 'Regular User')
ON CONFLICT (email) DO NOTHING;
