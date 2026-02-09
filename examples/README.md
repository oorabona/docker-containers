# Stack Examples

Ready-to-run Docker Compose stacks combining multiple containers from this project. Each example represents a typical deployment pattern — a "pod" that can be deployed independently.

## Stacks

| Stack | Containers | Use Case |
|-------|-----------|----------|
| [wordpress-stack](wordpress-stack/) | OpenResty + WordPress + MariaDB | CMS hosting with auto-install |
| [wordpress-sqlite](wordpress-sqlite/) | OpenResty + WordPress (SQLite) | Lightweight CMS, no database server |
| [wordpress-composer](wordpress-composer/) | OpenResty + PHP-FPM + MariaDB | Composer-managed WordPress for dev teams |
| [php-app-stack](php-app-stack/) | OpenResty + PHP-FPM + PostgreSQL | Custom PHP application |
| [web-terminal](web-terminal/) | OpenResty + Web Shell | Secure browser-based terminal |
| [observability-stack](observability-stack/) | PostgreSQL + Vector + Grafana | Monitoring and log aggregation |

## Usage

```bash
# Start a stack
cd examples/<stack-name>
docker compose up -d

# Run integration tests
bash examples/<stack-name>/test.sh

# Stop and clean up
docker compose down -v
```

## Architecture

Each stack is designed as an independent unit that maps to a Kubernetes pod:

```
wordpress-stack    wordpress-sqlite   wordpress-composer   php-app-stack
┌──────────────┐  ┌──────────────┐  ┌──────────────┐   ┌──────────────┐
│  OpenResty   │  │  OpenResty   │  │  OpenResty   │   │  OpenResty   │
│  :8080→:80   │  │  :8080→:80   │  │  :8080→:80   │   │  :8080→:80   │
├──────────────┤  ├──────────────┤  ├──────────────┤   ├──────────────┤
│  WordPress   │  │  WordPress   │  │  PHP-FPM     │   │  PHP-FPM     │
│  (PHP-FPM)   │  │  (SQLite)    │  │  (Composer)  │   │  :9000       │
├──────────────┤  └──────────────┘  ├──────────────┤   ├──────────────┤
│  MariaDB     │                    │  MariaDB     │   │  PostgreSQL  │
└──────────────┘                    └──────────────┘   └──────────────┘

web-terminal        observability-stack
┌──────────────┐   ┌──────────────────┐
│  OpenResty   │   │   Grafana :3000   │
│  (proxy+auth)│   │   Vector :8686   │
├──────────────┤   │   PostgreSQL     │
│  Web Shell   │   │   :5432          │
│  (ttyd)      │   └──────────────────┘
└──────────────┘
```

## Security

All examples include:
- Read-only root filesystem where possible
- Dropped Linux capabilities
- `no-new-privileges` security option
- Non-root users for application processes
- Network isolation (frontend/backend separation)

**For production:** Replace default passwords, add TLS certificates, and restrict network access.
