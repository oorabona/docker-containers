# PostgreSQL Database Container

A production-ready PostgreSQL container with configurable versions and optimized for development and production use. Built on the official PostgreSQL Docker image with additional tooling and configuration options.

## Features

- **Version Flexibility**: Support for multiple PostgreSQL versions
- **Production Ready**: Optimized configuration for various workloads
- **Development Friendly**: Easy setup for local development
- **Backup Support**: Built-in backup and restore capabilities
- **Security**: Proper user management and security configurations

## Usage

### With Docker Compose

```yaml
version: '3.8'
services:
  postgres:
    build:
      context: .
      args:
        VERSION: 15
    environment:
      - POSTGRES_DB=myapp
      - POSTGRES_USER=myuser
      - POSTGRES_PASSWORD=mypassword
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./init:/docker-entrypoint-initdb.d
volumes:
  postgres_data:
```

### Direct Docker Run

```bash
docker run -d \
  --name postgres-db \
  -e POSTGRES_DB=myapp \
  -e POSTGRES_USER=myuser \
  -e POSTGRES_PASSWORD=mypassword \
  -p 5432:5432 \
  -v postgres_data:/var/lib/postgresql/data \
  oorabona/postgres
```

## Configuration

### Environment Variables

- `POSTGRES_DB` - Database name to create
- `POSTGRES_USER` - Database user
- `POSTGRES_PASSWORD` - Database password
- `POSTGRES_INITDB_ARGS` - Additional initdb arguments
- `PGDATA` - Database data directory (default: /var/lib/postgresql/data)

### Build Arguments

- `VERSION` - PostgreSQL version (default: latest stable)

## Database Management

### Connect to Database

```bash
# Using psql
docker-compose exec postgres psql -U myuser -d myapp

# From host (if psql installed)
psql -h localhost -U myuser -d myapp
```

### Backup and Restore

```bash
# Create backup
docker-compose exec postgres pg_dump -U myuser myapp > backup.sql

# Restore backup
docker-compose exec -T postgres psql -U myuser -d myapp < backup.sql
```

### Initialization Scripts

Place SQL scripts in `./init/` directory to run during container initialization:

```sql
-- init/01-schema.sql
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    username VARCHAR(50) UNIQUE NOT NULL,
    email VARCHAR(100) UNIQUE NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- init/02-data.sql
INSERT INTO users (username, email) VALUES 
    ('admin', 'admin@example.com'),
    ('user1', 'user1@example.com');
```

## Performance Tuning

### Common Settings

```bash
# For development
POSTGRES_INITDB_ARGS="--auth-host=trust --auth-local=trust"

# For production (in postgresql.conf)
shared_buffers = 256MB
effective_cache_size = 1GB
maintenance_work_mem = 64MB
checkpoint_completion_target = 0.9
wal_buffers = 16MB
default_statistics_target = 100
random_page_cost = 1.1
effective_io_concurrency = 200
```

## Supported Versions

- PostgreSQL 15 (default)
- PostgreSQL 14
- PostgreSQL 13
- PostgreSQL 12

Check available versions:

```bash
./version.sh latest    # Latest PostgreSQL version
./version.sh          # Current container version
```

## Security

### Base Security
- Non-root database process
- Proper file permissions
- Configurable authentication methods
- Network isolation support
- Regular security updates

### Credential Security (CRITICAL)
**NEVER** hardcode passwords in docker-compose.yml:

```yaml
# BAD - Never do this:
environment:
  POSTGRES_PASSWORD: mysecretpassword

# GOOD - Use environment variables:
environment:
  POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}

# BETTER - Use Docker secrets:
secrets:
  postgres_password:
    file: ./postgres_password.txt
```

### Runtime Hardening (Recommended)

```bash
# Secure runtime configuration
docker run -d \
  --name postgres \
  --read-only \
  --tmpfs /tmp \
  --tmpfs /run/postgresql \
  --cap-drop ALL \
  --cap-add CHOWN \
  --cap-add SETGID \
  --cap-add SETUID \
  --cap-add DAC_OVERRIDE \
  --security-opt no-new-privileges:true \
  -e POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password \
  -v postgres_data:/var/lib/postgresql/data \
  -p 127.0.0.1:5432:5432 \
  postgres
```

### Docker Compose Security Template

```yaml
services:
  postgres:
    image: ghcr.io/oorabona/postgres:latest
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
    environment:
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_DB: ${POSTGRES_DB}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    ports:
      - "127.0.0.1:5432:5432"  # Bind to localhost only

volumes:
  postgres_data:
```

### Network Security
- Bind to `127.0.0.1` instead of `0.0.0.0` for local-only access
- Use Docker networks for service-to-service communication
- Enable SSL for remote connections

## Monitoring

### Health Checks

```bash
# Check if PostgreSQL is ready
docker-compose exec postgres pg_isready -U myuser -d myapp
```

### Logs

```bash
# View PostgreSQL logs
docker-compose logs postgres

# Follow logs
docker-compose logs -f postgres
```

## Building

```bash
cd postgres
docker-compose build

# Build with specific version
docker build --build-arg VERSION=14 -t postgres:14 .
```

## Common Use Cases

1. **Web Application Backend**: Primary database for web apps
2. **Data Analytics**: OLAP workloads with proper tuning
3. **Development Environment**: Local development database
4. **Microservices**: Individual service databases
5. **Testing**: Isolated test databases
