# WordPress + MariaDB Stack

Full-featured WordPress deployment with MariaDB database, auto-install via WP-CLI, and OpenResty reverse proxy.

## When to use this

- Standard WordPress hosting (blogs, corporate sites, e-commerce)
- Projects needing a real MySQL/MariaDB database
- Multi-site setups or sites with heavy database usage

## Architecture

```
                   :8080
┌──────────────────────────────────────┐
│  OpenResty (reverse proxy)           │
│  Security headers, PHP-upload block  │
├──────────────────────────────────────┤
│  WordPress (PHP-FPM)                 │
│  Auto-installed via WP_AUTO_INSTALL  │
│  DISALLOW_FILE_MODS=true             │
├──────────────────────────────────────┤
│  MariaDB 11                          │
│  Persistent volume for data          │
└──────────────────────────────────────┘
```

## Quick start

```bash
docker compose up -d
# Site is auto-installed and ready at http://localhost:8080
# Admin: admin / change_me_now
```

## Admin access

The WordPress dashboard is at `http://localhost:8080/wp-admin/`. Default credentials are `admin` / `change_me_now` (see `WP_ADMIN_PASSWORD` below).

### Hiding the login URL

Set `WP_ADMIN_PATH` to hide the entire admin area behind a secret URL:

```bash
# In .env or inline
WP_ADMIN_PATH=my-secret-login docker compose up -d
```

When active, all admin paths return **404** to unauthenticated visitors:
- `/wp-login.php` → 404
- `/wp-admin/` → 404
- `/wp-admin/*.php` → 404

To access the admin:
1. Visit `http://localhost:8080/my-secret-login`
2. A secure cookie is set (SHA-256, HttpOnly, SameSite=Strict, 1 hour)
3. You are redirected to the login form
4. After login, `/wp-admin/` works normally until the cookie expires

Also blocked by default (regardless of `WP_ADMIN_PATH`): `/xmlrpc.php` (common brute-force vector).

## Adding plugins and themes

The wp-admin UI is locked (`DISALLOW_FILE_MODS=true`): no plugin or theme installation from the dashboard. This is intentional — it prevents unauthorized modifications and encourages reproducible deployments.

Three ways to add plugins:

### 1. At first boot — `WP_PLUGINS` env var

Comma-separated list of wordpress.org plugin slugs, installed and activated on first boot only:

```yaml
# docker-compose.yaml
environment:
  WP_PLUGINS: "classic-editor, redis-cache, wordfence"
```

> **Note:** this only runs during initial setup (`WP_AUTO_INSTALL`). Restarting the container does not re-install plugins. To reset, remove the volumes: `docker compose down -v`.

### 2. At runtime — WP-CLI

WP-CLI can install plugins even with `DISALLOW_FILE_MODS=true`:

```bash
# Install and activate a plugin
docker compose exec wordpress wp plugin install classic-editor --activate

# Install a specific version
docker compose exec wordpress wp plugin install woocommerce --version=9.0.0 --activate

# Install a theme
docker compose exec wordpress wp theme install flavor --activate

# List installed plugins
docker compose exec wordpress wp plugin list
```

Plugins installed this way persist in the container filesystem but are **lost if the container is recreated** (e.g., `docker compose up --force-recreate`).

### 3. At build time — custom Dockerfile (recommended for production)

For reproducible deployments, extend the base image:

```dockerfile
FROM ghcr.io/oorabona/wordpress:latest
USER root
RUN su -s /bin/bash wordpress -c " \
    wp plugin install classic-editor --activate && \
    wp plugin install redis-cache --activate"
USER wordpress
```

```yaml
# docker-compose.yaml
services:
  wordpress:
    build: .
    # ... rest of config
```

This bakes plugins into the image — they survive any container recreation.

## Configuration

All settings via environment variables (Docker secrets supported via `_FILE` suffix):

| Variable | Default | Description |
|----------|---------|-------------|
| `WP_AUTO_INSTALL` | `true` | Auto-install WordPress on first boot |
| `WP_SITE_URL` | `http://localhost:8080` | Public site URL |
| `WP_SITE_TITLE` | `My WordPress Site` | Site title |
| `WP_ADMIN_USER` | `admin` | Admin username |
| `WP_ADMIN_PASSWORD` | (required) | Admin password |
| `WP_ADMIN_EMAIL` | (required) | Admin email |
| `WP_LOCALE` | `en_US` | WordPress locale |
| `WP_TIMEZONE` | `UTC` | Site timezone |
| `WP_PLUGINS` | — | Comma-separated plugin slugs (first boot only) |
| `WP_ADMIN_PATH` | — | Secret URL path to access the admin area |

## Security model

- **DISALLOW_FILE_MODS** — no plugin/theme installs via wp-admin
- **DISALLOW_FILE_EDIT** — no code editor in wp-admin
- **OpenResty** blocks PHP execution in uploads directory and xmlrpc.php
- **WP_ADMIN_PATH** — hides login URL and entire `/wp-admin/` area (optional)
- **Network isolation** — MariaDB only accessible from WordPress (backend network)

> **Production hardening:** add `read_only: true` + `tmpfs: [/tmp, /run]` to the wordpress service for true filesystem immutability. Only the uploads volume remains writable.

## Testing

```bash
bash test.sh
```

## See also

- [wordpress-sqlite](../wordpress-sqlite/) — Same image, no database server needed
- [wordpress-composer](../wordpress-composer/) — Composer-managed deployment for development teams
