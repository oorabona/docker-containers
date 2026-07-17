# Stack Examples

Ready-to-run Docker Compose stacks built from containers in this project. Most combine multiple containers into a deployment pattern — a "pod" that can be deployed independently — but a few wrap a single container for hands-on exploration of something that's easier to learn by doing than reading.

## Stacks

| Stack | Containers | Use Case |
|-------|-----------|----------|
| [wordpress-stack](wordpress-stack/) | OpenResty + WordPress + MariaDB | CMS hosting with auto-install |
| [wordpress-sqlite](wordpress-sqlite/) | OpenResty + WordPress (SQLite) | Lightweight CMS, no database server |
| [wordpress-composer](wordpress-composer/) | OpenResty + PHP-FPM + MariaDB | Composer-managed WordPress for dev teams |
| [php-app-stack](php-app-stack/) | OpenResty + PHP-FPM + PostgreSQL | Custom PHP application |
| [web-terminal](web-terminal/) | OpenResty + Web Shell | Secure browser-based terminal |
| [observability-stack](observability-stack/) | PostgreSQL + Vector + Grafana | Monitoring and log aggregation |
| [tor-playground](tor-playground/) | Tor (monitoring flavor) | Hands-on Tor control port, Nyx, `SIGNAL NEWNYM` |

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
│  :8080→:8080 │  │  :8080→:8080 │  │  :8080→:8080 │   │  :8080→:8080 │
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
- Network isolation (frontend/backend separation) for multi-service stacks — single-container examples like `tor-playground` have nothing to isolate from and use the default Compose network

**For production:** Replace default passwords, add TLS certificates, and restrict network access.
