# Extension Profiles Quick Reference

## 🎯 Choosing the Right Profile

### 📱 **Supabase Profile** - `POSTGRES_EXTENSION_PROFILE=supabase`
**Best for**: Modern web applications, real-time features, authentication

**Included Extensions**:
- `citus` - Distributed PostgreSQL foundation
- `pg_vector` - AI/ML embeddings and similarity search  
- `postgis` - Geospatial queries and location features
- `pg_cron` - Scheduled tasks and background jobs
- `pg_net` - HTTP requests from SQL
- `pgjwt` - JWT token handling for authentication
- `pgcrypto` - Encryption and security functions
- `uuid-ossp` - UUID generation
- `pg_trgm` - Fuzzy text matching

**Example Use Cases**:
- SaaS applications with user authentication
- Real-time messaging and notifications
- Location-based services
- AI-powered search and recommendations

---

### 📊 **ParadeDB Profile** - `POSTGRES_EXTENSION_PROFILE=paradedb`
**Best for**: Analytics, search engines, data lakes

**Included Extensions**:
- `citus` - Distributed PostgreSQL foundation
- `pg_search` - BM25 full-text search (when available)
- `pg_analytics` - Columnar storage for OLAP
- `pg_lakehouse` - Data lake connectivity
- `pg_sparse` - Sparse vector operations
- `pg_vector` - Dense vector search
- `postgis` - Geospatial analytics

**Example Use Cases**:
- Full-text search engines
- Business intelligence platforms
- Data lake analytics
- Document search and retrieval

---

### 🏢 **Analytics Profile** - `POSTGRES_EXTENSION_PROFILE=analytics`
**Best for**: Data warehousing, business intelligence, reporting

**Included Extensions**:
- `citus` - Horizontal scaling for large datasets
- `pg_analytics` - Columnar storage for analytical queries
- `pg_partman` - Automated partition management
- `pg_stat_monitor` - Enhanced monitoring and statistics
- `pg_vector` - Vector operations for ML analytics
- `postgis` - Spatial data analysis
- `plpython3u` - Python procedural language

**Example Use Cases**:
- Data warehouses
- Reporting dashboards
- Time-series analytics
- Large-scale data processing

---

### 🤖 **AI/ML Profile** - `POSTGRES_EXTENSION_PROFILE=ai-ml`
**Best for**: Machine learning, data science, AI applications

**Included Extensions**:
- `citus` - Scale ML workloads horizontally
- `pg_vector` - Dense vector embeddings (OpenAI, etc.)
- `pg_sparse` - Sparse vector operations
- `pg_search` - Full-text search with BM25 for NLP
- `pg_trgm` - N-gram analysis and fuzzy matching
- `plpython3u` - Python integration for ML models
- `postgis` - Geospatial machine learning

**Example Use Cases**:
- Recommendation systems
- Semantic search
- RAG (Retrieval-Augmented Generation)
- Document similarity
- Image similarity (via embeddings)

---

## 🔧 Custom Configuration

### Environment Variables

```bash
# Use a profile
POSTGRES_EXTENSION_PROFILE=supabase

# Or specify individual extensions
POSTGRES_EXTENSION_PROFILE=""
POSTGRES_EXTENSIONS="citus,vector,postgis,pg_cron"

# Deployment mode
POSTGRES_MODE=single          # single|coordinator|worker

# Locales
POSTGRES_LOCALES="en_US fr_FR de_DE"
```

### Docker Compose Example

```yaml
services:
  postgres:
    image: oorabona/postgres:15-modern
    environment:
      POSTGRES_EXTENSION_PROFILE: ai-ml
      POSTGRES_MODE: single
      POSTGRES_DB: myapp
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: changeme
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data

volumes:
  postgres_data:
```

---

## 🚀 Getting Started Examples

### 1. Web Application (Supabase-like)
```bash
# Start with web app profile
POSTGRES_EXTENSION_PROFILE=supabase docker-compose up -d

# Connect and test
psql -h localhost -U postgres -d postgres

# Test vector search
SELECT * FROM ai_examples.semantic_search(array_fill(0.1, ARRAY[1536])::vector);

# Test geospatial
SELECT * FROM geo_examples.find_nearby(48.8566, 2.3522, 50);
```

### 2. Analytics Workload
```bash
# Start with analytics profile
POSTGRES_EXTENSION_PROFILE=analytics docker-compose up -d

# Test analytics functions
SELECT * FROM analytics_examples.daily_user_stats('2024-01-01', '2024-01-31');

# Check monitoring
SELECT * FROM monitoring.slow_queries LIMIT 5;
```

### 3. AI/ML Development
```bash
# Start with AI/ML profile
POSTGRES_EXTENSION_PROFILE=ai-ml docker-compose up -d

# Create embeddings table
CREATE TABLE embeddings (
    id SERIAL PRIMARY KEY,
    content TEXT,
    embedding vector(1536)
);

# Vector similarity search
SELECT id, content, 1 - (embedding <=> $1) as similarity
FROM embeddings
ORDER BY embedding <=> $1
LIMIT 10;
```

---

## 📊 Scaling to Distributed Setup

### Single Node → Coordinator + Workers

1. **Start with single node**:
```bash
POSTGRES_EXTENSION_PROFILE=analytics docker-compose up -d
```

2. **Scale to distributed**:
```bash
# Switch to cluster configuration
docker-compose -f docker-compose.cluster.yml up -d

# Connect to coordinator
psql -h localhost -p 5432 -U postgres

# Distribute existing tables
SELECT create_distributed_table('my_table', 'id');
```

3. **Monitor cluster health**:
```sql
SELECT * FROM monitoring.citus_cluster_health;
SELECT * FROM monitoring.citus_shard_distribution;
```

---

## 🔍 Health Monitoring

```sql
-- Overall health check
SELECT * FROM public.health_check();

-- Performance monitoring
SELECT * FROM monitoring.slow_queries LIMIT 10;
SELECT * FROM monitoring.connections;

-- Cluster status (if Citus enabled)
SELECT * FROM monitoring.citus_cluster_health;
```
