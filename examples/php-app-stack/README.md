# PHP Application Stack

Generic PHP-FPM application with PostgreSQL database and OpenResty reverse proxy. A starting point for custom PHP projects.

## When to use this

- Custom PHP applications (APIs, web apps, microservices)
- Laravel, Symfony, or plain PHP projects
- When you need PostgreSQL instead of MySQL
- As a template to adapt for your own PHP project

## Architecture

```
               :8080
┌──────────────────────────────────────┐
│  OpenResty (reverse proxy)           │
│  Static files, security headers      │
├──────────────────────────────────────┤
│  PHP-FPM (custom Dockerfile)         │
│  pdo_pgsql extension included        │
│  Application code mounted in /app    │
├──────────────────────────────────────┤
│  PostgreSQL 17                       │
│  Init script seeds sample data       │
└──────────────────────────────────────┘
```

## Quick start

```bash
docker compose up -d
# Open http://localhost:8080 — shows PHP info with database connection status
```

## Customizing

1. Replace `src/` contents with your PHP application
2. Edit `nginx.conf` for your URL routing
3. Edit `init.sql` for your database schema
4. Add PHP extensions to the `Dockerfile` if needed

The sample `src/index.php` demonstrates:
- PHP-FPM execution through OpenResty
- PostgreSQL connectivity via PDO
- Reading sample data from the database

## Testing

```bash
bash test.sh
```
