# PostgreSQL Extension Examples

This directory contains practical, ready-to-use examples for each PostgreSQL extension available in this container. These examples are designed to be loaded manually and do not affect the build process.

## 🚀 Quick Usage

Load any example into your running PostgreSQL container:

```bash
# For examples that work in any database (most extensions)
docker compose exec postgres psql -U postgres -d myapp < examples/pg_vector_example.sql

# For pg_cron (must use postgres database)
docker compose exec postgres psql -U postgres -d postgres < examples/pg_cron_example.sql
```

## 📁 Available Examples

### 🤖 **AI/ML Extensions**
- **`pg_vector_example.sql`** - Vector similarity search for AI/ML applications
  - Document embeddings with OpenAI-compatible dimensions
  - Semantic search functions
  - Hybrid text + vector search
  - Performance optimization examples

### 🗺️ **Geospatial Extensions**
- **`postgis_example.sql`** - Geospatial data and location-based queries
  - Point, line, and polygon operations
  - Distance calculations and proximity search
  - Spatial indexing and aggregations
  - Real-world landmark examples

### 🌐 **HTTP & Networking**
- **`pg_net_example.sql`** - HTTP client for API integrations
  - GET/POST requests with custom headers
  - JSON API consumption
  - Webhook systems and notification patterns
  - Error handling and timeout management

### 🔐 **Authentication & Security**
- **`pgjwt_example.sql`** - JWT token creation and validation
  - User authentication systems
  - Role-based authorization
  - Session management with refresh tokens
  - Production security best practices

### ⏰ **Automation & Scheduling**
- **`pg_cron_example.sql`** - Job scheduling and background tasks
  - Daily/weekly/monthly job patterns
  - Database maintenance automation
  - Business logic scheduling
  - Job monitoring and error handling

### 🌐 **Distributed Systems**
- **`citus_example.sql`** - Distributed PostgreSQL operations
  - Table distribution and sharding
  - Multi-tenant query patterns
  - Cross-shard analytics
  - Scaling and monitoring examples

## 💡 Usage Patterns

### 🎯 **Single Extension Examples**
Test individual extensions in isolation:
```bash
# Start with a specific extension
docker compose exec postgres psql -U postgres -d myapp < examples/pg_vector_example.sql
```

### 🔗 **Combined Extension Examples**
Many real-world applications combine multiple extensions:
```bash
# Load multiple examples for integrated functionality
docker compose exec postgres psql -U postgres -d myapp < examples/pg_vector_example.sql
docker compose exec postgres psql -U postgres -d myapp < examples/postgis_example.sql
docker compose exec postgres psql -U postgres -d myapp < examples/pg_net_example.sql
```

### 🧪 **Development & Testing**
Use examples as starting points for your own development:
```bash
# Copy and modify examples for your use case
cp examples/pg_vector_example.sql my_custom_vectors.sql
# Edit my_custom_vectors.sql with your specific requirements
docker compose exec postgres psql -U postgres -d myapp < my_custom_vectors.sql
```

## 📊 **Extension Compatibility**

All examples are designed to work with the extensions as configured in this container:

| Example File | Required Extensions | Database |
|--------------|-------------------|----------|
| `pg_vector_example.sql` | vector | myapp |
| `postgis_example.sql` | postgis | myapp |
| `pg_net_example.sql` | pg_net | myapp |
| `pgjwt_example.sql` | pgcrypto (for pgjwt) | myapp |
| `pg_cron_example.sql` | pg_cron | **postgres** |
| `citus_example.sql` | citus | myapp |

## 🔧 **Customization Guide**

### Modifying Examples
1. **Copy the example file** to avoid affecting the original
2. **Edit connection parameters** if using different database names
3. **Adjust data samples** to match your domain
4. **Scale the examples** up or down based on your needs

### Creating New Examples
Use the existing examples as templates:
```sql
-- Your Extension Example
-- Brief description of what this demonstrates
--
-- Usage: docker compose exec postgres psql -U postgres -d myapp < examples/your_example.sql

\echo '🔧 === Your Extension Examples ==='

-- Example 1: Basic functionality
\echo '📋 Example 1: Basic operations'
-- Your SQL here

-- Example 2: Advanced usage
\echo '⚡ Example 2: Advanced patterns'
-- Your SQL here

\echo '✅ Your extension examples completed!'
\echo '💡 Tips and best practices for this extension'
```

## 🚨 **Important Notes**

### Database Context
- **Most extensions**: Use `myapp` database (default application database)
- **pg_cron only**: Must use `postgres` database for job scheduling
- **Cross-database**: Some examples show how to work across databases

### Data Persistence
- Examples create tables and data that **persist** between runs
- Use `DROP TABLE IF EXISTS` in your custom examples if you want clean runs
- Consider using transaction blocks for testing: `BEGIN; ... ROLLBACK;`

### Production Considerations
- Examples use **demo data and simple passwords**
- **Change all secrets** before using in production
- **Review security settings** for your specific use case
- **Scale parameters** (timeouts, batch sizes) for your workload

## 🎯 **Real-World Integration**

These examples demonstrate patterns commonly used in:

- **🌐 Web Applications**: User authentication, geolocation, API integrations
- **🤖 AI/ML Platforms**: Vector search, recommendation systems, embeddings
- **📊 Analytics Systems**: Distributed queries, scheduled reports, data aggregation
- **🏢 Enterprise Apps**: Multi-tenant patterns, background jobs, security policies

## 📚 **Further Reading**

For more advanced usage, refer to:
- [Main README.md](../README.md) - Complete system documentation
- [Official PostgreSQL documentation](https://www.postgresql.org/docs/)
- Individual extension documentation linked in the main README

---

**💡 These examples provide production-ready patterns while remaining educational and easy to understand. Feel free to adapt them to your specific use cases!**