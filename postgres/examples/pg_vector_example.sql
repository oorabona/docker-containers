-- pg_vector Extension Examples
-- Vector similarity search for AI/ML applications
-- 
-- Usage: docker compose exec postgres psql -U postgres -d myapp < examples/pg_vector_example.sql

\echo '🤖 === pg_vector Examples - AI/ML Vector Search ==='

-- Create a table for document embeddings
CREATE TABLE IF NOT EXISTS document_embeddings (
    id SERIAL PRIMARY KEY,
    title TEXT NOT NULL,
    content TEXT,
    embedding vector(1536),  -- OpenAI embedding dimension
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Insert sample data with mock embeddings
INSERT INTO document_embeddings (title, content, embedding) VALUES 
    ('AI Overview', 'Introduction to artificial intelligence concepts', 
     array_fill(0.1, ARRAY[1536])::vector),
    ('Machine Learning Basics', 'Fundamentals of ML algorithms and techniques',
     array_fill(0.2, ARRAY[1536])::vector),
    ('Deep Learning Guide', 'Neural networks and deep learning explained',
     array_fill(0.3, ARRAY[1536])::vector),
    ('Data Science Workflow', 'End-to-end data science project methodology',
     array_fill(0.4, ARRAY[1536])::vector),
    ('Python for AI', 'Using Python libraries for artificial intelligence',
     array_fill(0.5, ARRAY[1536])::vector)
ON CONFLICT DO NOTHING;

-- Create an index for vector similarity search
CREATE INDEX IF NOT EXISTS idx_document_embeddings_vector 
ON document_embeddings USING ivfflat (embedding vector_cosine_ops) 
WITH (lists = 100);

\echo '📋 Document embeddings table created with sample data'

-- Example 1: Vector similarity search (cosine distance)
\echo '🔍 Example 1: Find similar documents using cosine similarity'
SELECT 
    id,
    title,
    1 - (embedding <=> array_fill(0.15, ARRAY[1536])::vector) as similarity_score
FROM document_embeddings
ORDER BY embedding <=> array_fill(0.15, ARRAY[1536])::vector
LIMIT 3;

-- Example 2: Vector similarity with threshold
\echo '🎯 Example 2: Find documents with similarity above threshold'
SELECT 
    id,
    title,
    content,
    1 - (embedding <=> array_fill(0.25, ARRAY[1536])::vector) as similarity
FROM document_embeddings
WHERE (embedding <=> array_fill(0.25, ARRAY[1536])::vector) < 0.5  -- 50% similarity threshold
ORDER BY embedding <=> array_fill(0.25, ARRAY[1536])::vector;

-- Example 3: Vector operations and aggregation
\echo '📊 Example 3: Vector aggregation and statistics'
SELECT 
    COUNT(*) as total_documents,
    AVG(embedding <=> array_fill(0.0, ARRAY[1536])::vector) as avg_distance_from_zero
FROM document_embeddings;

-- Example 4: Hybrid search (text + vector)
\echo '🔗 Example 4: Hybrid search combining text and vector similarity'
SELECT 
    id,
    title,
    content,
    1 - (embedding <=> array_fill(0.3, ARRAY[1536])::vector) as vector_similarity,
    ts_rank(to_tsvector('english', title || ' ' || content), plainto_tsquery('machine learning')) as text_relevance
FROM document_embeddings
WHERE to_tsvector('english', title || ' ' || content) @@ plainto_tsquery('machine learning')
   OR (embedding <=> array_fill(0.3, ARRAY[1536])::vector) < 0.8
ORDER BY 
    (1 - (embedding <=> array_fill(0.3, ARRAY[1536])::vector)) * 0.7 + 
    ts_rank(to_tsvector('english', title || ' ' || content), plainto_tsquery('machine learning')) * 0.3 DESC;

-- Example 5: Create a function for semantic search
\echo '⚡ Example 5: Create reusable semantic search function'
CREATE OR REPLACE FUNCTION semantic_search(
    query_embedding vector(1536),
    similarity_threshold FLOAT DEFAULT 0.7,
    result_limit INT DEFAULT 10
)
RETURNS TABLE(
    document_id INT,
    document_title TEXT,
    document_content TEXT,
    similarity_score FLOAT
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        de.id,
        de.title,
        de.content,
        (1 - (de.embedding <=> query_embedding))::FLOAT
    FROM document_embeddings de
    WHERE (de.embedding <=> query_embedding) < (1 - similarity_threshold)
    ORDER BY de.embedding <=> query_embedding
    LIMIT result_limit;
END;
$$ LANGUAGE plpgsql;

-- Test the semantic search function
\echo '🧪 Testing semantic search function'
SELECT * FROM semantic_search(
    array_fill(0.35, ARRAY[1536])::vector,
    0.5,  -- 50% similarity threshold
    5     -- Top 5 results
);

\echo '✅ pg_vector examples completed!'
\echo '💡 Tip: Replace mock embeddings with real ones from OpenAI, Sentence Transformers, etc.'