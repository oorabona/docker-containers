# PostgreSQL Database Container

Production-ready PostgreSQL containers with multiple **flavors** optimized for different workloads: AI/RAG, analytics, or general purpose. Built on Alpine Linux with pre-compiled extensions.

## Quick Start

```bash
# Base PostgreSQL (smallest image)
docker pull ghcr.io/oorabona/postgres:17-alpine

# With pgvector for AI/RAG applications
docker pull ghcr.io/oorabona/postgres:17-vector-alpine

# With analytics extensions
docker pull ghcr.io/oorabona/postgres:17-analytics-alpine

# All extensions included
docker pull ghcr.io/oorabona/postgres:17-full-alpine
```

## Available Flavors

| Flavor | Description | Extensions | Use Case |
|--------|-------------|------------|----------|
| **base** | Standard PostgreSQL | Built-in only | General purpose, smallest size |
| **vector** | AI/ML optimized | + pgvector | RAG, embeddings, semantic search |
| **analytics** | Data warehouse | + pg_partman, hypopg, pg_qualstats | Large tables, query tuning |
| **full** | Everything | All extensions | Development, testing |

### Flavor Details

#### Base (`*-alpine`)
Standard PostgreSQL with built-in extensions:
- `pg_stat_statements` - Query statistics
- `pgcrypto` - Cryptographic functions
- `uuid-ossp` - UUID generation
- `btree_gin`, `btree_gist` - Additional index types
- `pg_trgm` - Trigram matching for fuzzy search

#### Vector (`*-vector-alpine`)
Includes base + **pgvector** for AI/ML workloads:
```sql
-- Store embeddings from OpenAI, Anthropic, etc.
CREATE TABLE documents (
    id SERIAL PRIMARY KEY,
    content TEXT,
    embedding vector(1536)  -- OpenAI ada-002 dimension
);

-- Create HNSW index for fast similarity search
CREATE INDEX ON documents USING hnsw (embedding vector_cosine_ops);

-- Find similar documents
SELECT * FROM documents
ORDER BY embedding <=> '[0.1, 0.2, ...]'::vector
LIMIT 10;
```

#### Analytics (`*-analytics-alpine`)
Includes base + extensions for data warehousing:
- **pg_partman** - Automatic partition management for time-series data
- **hypopg** - Hypothetical indexes for query planning
- **pg_qualstats** - Predicate statistics for index suggestions
- **pg_buffercache** - Buffer cache inspection
- **pg_prewarm** - Data preloading

```sql
-- Auto-partition a time-series table
SELECT partman.create_parent(
    p_parent_table := 'public.events',
    p_control := 'created_at',
    p_interval := 'daily'
);

-- Check hypothetical index benefit
SELECT hypopg_create_index('CREATE INDEX ON users(email)');
EXPLAIN SELECT * FROM users WHERE email = 'test@example.com';
```

#### Full (`*-full-alpine`)
All extensions for development and testing. Includes everything from vector and analytics flavors.

## Supported Versions

| Version | Flavors | Status |
|---------|---------|--------|
| PostgreSQL 18 | base | Extensions not yet compatible |
| PostgreSQL 17 | base, vector, analytics, full | **Recommended** |
| PostgreSQL 16 | base, vector, analytics, full | LTS |

### Image Tags

```
ghcr.io/oorabona/postgres:{version}-{flavor}-alpine
```

Examples:
- `17-alpine` or `17-base-alpine` - PG17 base
- `17-vector-alpine` - PG17 with pgvector
- `16-analytics-alpine` - PG16 with analytics extensions
- `17-full-alpine` - PG17 with all extensions

## Usage

### Docker Compose

```yaml
services:
  postgres:
    image: ghcr.io/oorabona/postgres:17-vector-alpine
    environment:
      POSTGRES_DB: myapp
      POSTGRES_USER: myuser
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U myuser -d myapp"]
      interval: 30s
      timeout: 10s
      retries: 3

volumes:
  postgres_data:
```

### Docker Run

```bash
docker run -d \
  --name postgres \
  -e POSTGRES_DB=myapp \
  -e POSTGRES_USER=myuser \
  -e POSTGRES_PASSWORD=secret \
  -p 5432:5432 \
  -v postgres_data:/var/lib/postgresql/data \
  ghcr.io/oorabona/postgres:17-vector-alpine
```

### Building Locally

```bash
# Build base flavor
docker build --build-arg VERSION=17-alpine --build-arg FLAVOR=base -t postgres:17 .

# Build vector flavor
docker build --build-arg VERSION=17-alpine --build-arg FLAVOR=vector -t postgres:17-vector .

# Build with all extensions
docker build --build-arg VERSION=17-alpine --build-arg FLAVOR=full -t postgres:17-full .
```

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `POSTGRES_DB` | Database name | postgres |
| `POSTGRES_USER` | Database user | postgres |
| `POSTGRES_PASSWORD` | User password | (required) |
| `POSTGRES_INITDB_ARGS` | Additional initdb arguments | |
| `PGDATA` | Data directory | /var/lib/postgresql/data |

### Initialization Scripts

Place `.sql` or `.sh` files in a volume mounted to `/docker-entrypoint-initdb.d/`:

```yaml
volumes:
  - ./init:/docker-entrypoint-initdb.d
```

Scripts run alphabetically on first container start:
```
init/
├── 01-schema.sql
├── 02-seed-data.sql
└── 03-setup.sh
```

### Performance Tuning

For production workloads, consider these settings in `postgresql.conf`:

```ini
# Memory
shared_buffers = 256MB
effective_cache_size = 1GB
work_mem = 16MB
maintenance_work_mem = 128MB

# Write-Ahead Log
wal_buffers = 16MB
checkpoint_completion_target = 0.9
max_wal_size = 2GB

# Query Planner
random_page_cost = 1.1
effective_io_concurrency = 200
default_statistics_target = 100
```

## Extensions Reference

### Compiled Extensions

| Extension | Version | Description | Flavors |
|-----------|---------|-------------|---------|
| pgvector | 0.8.0 | Vector similarity search | vector, full |
| pg_partman | 5.2.4 | Partition management | analytics, full |
| hypopg | 1.4.1 | Hypothetical indexes | analytics, full |
| pg_qualstats | 2.1.1 | Predicate statistics | analytics, full |

### Built-in Extensions

All flavors include these PostgreSQL contrib extensions:
- `pg_stat_statements` - Query performance statistics
- `pgcrypto` - Cryptographic functions
- `uuid-ossp` - UUID generation
- `btree_gin` / `btree_gist` - Additional index types
- `pg_trgm` - Fuzzy string matching

Analytics and full flavors also include:
- `pg_buffercache` - Shared buffer inspection
- `pg_prewarm` - Buffer cache preloading
- `file_fdw` / `postgres_fdw` - Foreign data wrappers (full only)

## Security

### Credential Management

**Never hardcode passwords:**

```yaml
# BAD
environment:
  POSTGRES_PASSWORD: mysecretpassword

# GOOD - Environment variable
environment:
  POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}

# BETTER - Docker secrets
secrets:
  postgres_password:
    file: ./secrets/postgres_password.txt
```

### Runtime Hardening

```yaml
services:
  postgres:
    image: ghcr.io/oorabona/postgres:17-alpine
    read_only: true
    tmpfs:
      - /tmp
      - /run/postgresql
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETGID
      - SETUID
      - DAC_OVERRIDE
    security_opt:
      - no-new-privileges:true
    ports:
      - "127.0.0.1:5432:5432"  # Local only
```

### Network Security

- Bind to `127.0.0.1` for local-only access
- Use Docker networks for service communication
- Enable SSL for remote connections

## Monitoring

### Health Check

```bash
# Check if PostgreSQL is ready
docker exec postgres pg_isready -U myuser -d myapp

# Connection test
docker exec postgres psql -U myuser -d myapp -c "SELECT 1"
```

### Query Statistics

```sql
-- Enable pg_stat_statements (already enabled in all flavors)
-- Top 10 slowest queries
SELECT query, calls, mean_exec_time, total_exec_time
FROM pg_stat_statements
ORDER BY mean_exec_time DESC
LIMIT 10;
```

### Buffer Cache Analysis (analytics/full)

```sql
-- Buffer cache usage by table
SELECT c.relname,
       count(*) AS buffers,
       pg_size_pretty(count(*) * 8192) AS size
FROM pg_buffercache b
JOIN pg_class c ON b.relfilenode = c.relfilenode
GROUP BY c.relname
ORDER BY buffers DESC
LIMIT 10;
```

## Backup & Restore

### Create Backup

```bash
# SQL dump
docker exec postgres pg_dump -U myuser myapp > backup.sql

# Binary backup (faster for large DBs)
docker exec postgres pg_basebackup -U myuser -D /backup -Ft -z
```

### Restore

```bash
# From SQL dump
docker exec -i postgres psql -U myuser -d myapp < backup.sql

# Create fresh database from backup
docker exec postgres createdb -U myuser myapp_restored
docker exec -i postgres psql -U myuser -d myapp_restored < backup.sql
```

## Version Management

```bash
# Check current version
./version.sh

# Check latest upstream version
./version.sh latest

# Output format (JSON for CI integration)
./version.sh --json
```

## Architecture

```
postgres/
├── Dockerfile              # Multi-flavor build
├── variants.yaml           # Version/flavor matrix
├── extensions/
│   ├── config.yaml         # Extension definitions
│   ├── build/              # Build scripts per extension
│   └── artifacts/          # Compiled extension tarballs
├── flavors/
│   ├── base.yaml           # Base flavor config
│   ├── vector.yaml         # Vector flavor config
│   ├── analytics.yaml      # Analytics flavor config
│   └── full.yaml           # Full flavor config
└── custom-init/            # Custom initialization scripts
```

## Creating Custom Flavors

You can create your own flavor by combining extensions to match your specific needs.

### Step 1: Create a Flavor Definition

Create a new file in `flavors/`:

```yaml
# flavors/myapp.yaml
name: myapp
description: "Custom flavor for my application"
extends: base

# Select which compiled extensions to include
extensions:
  - pgvector      # For AI features
  - pg_partman    # For time-series data

# Additional built-in extensions
builtin_extensions:
  - pg_buffercache

# Extensions requiring shared_preload_libraries
shared_preload_libraries: []

# Image tags to publish
tags:
  - "{version}-myapp-alpine"
  - "{major}-myapp-alpine"
```

### Step 2: Update variants.yaml

Add your variant to the version matrix:

```yaml
# variants.yaml
versions:
  - tag: "17"
    variants:
      # ... existing variants ...
      - name: myapp
        suffix: "-myapp"
        flavor: myapp
        description: "Custom flavor for my application"
```

### Step 3: Update Dockerfile

Add your flavor to the install script in the Dockerfile:

```dockerfile
case "${FLAVOR}" in
    # ... existing flavors ...
    myapp) \
        install_ext pgvector; \
        install_ext pg_partman \
        ;; \
esac
```

And create the initialization script:

```dockerfile
RUN case "${FLAVOR}" in
    # ... existing flavors ...
    myapp) \
        printf '%s\n' \
            '-- MyApp flavor extensions' \
            'CREATE EXTENSION IF NOT EXISTS vector;' \
            'CREATE EXTENSION IF NOT EXISTS pg_partman;' \
            > /docker-entrypoint-initdb.d/01-init-flavor.sql \
        ;; \
esac
```

### Step 4: Build Your Flavor

```bash
# Build locally
docker build \
  --build-arg VERSION=17-alpine \
  --build-arg FLAVOR=myapp \
  -t postgres:17-myapp .

# Test it
docker run -d --name pg-test \
  -e POSTGRES_PASSWORD=test \
  postgres:17-myapp

# Verify extensions
docker exec pg-test psql -U postgres -c "\dx"
```

### Adding New Extensions

To add an extension not yet supported:

1. **Create build script** in `extensions/build/`:
   ```bash
   # extensions/build/myext.sh
   #!/bin/bash
   git clone https://github.com/org/myext.git
   cd myext
   make USE_PGXS=1
   make USE_PGXS=1 install DESTDIR=/output
   ```

2. **Add to config.yaml**:
   ```yaml
   extensions:
     myext:
       version: "1.0.0"
       description: "My custom extension"
       repo: "org/myext"
       build_deps:
         - build-base
       shared_preload: false
   ```

3. **Build the extension**:
   ```bash
   ./scripts/build-extensions.sh postgres myext
   ```

4. **Reference in Dockerfile** using `COPY --from=`

## Roadmap

### Planned Extensions

- **ParadeDB** - Full-text search with BM25 (Elasticsearch alternative)
- **PostGIS** - Geospatial database extension
- **TimescaleDB** - Time-series optimization

### Future Improvements

- PostgreSQL 18 extension support
- ARM64 optimized builds
- pg_stat_monitor integration
