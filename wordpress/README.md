# WordPress

Production-ready WordPress container built on PHP-FPM with WP-CLI, auto-install, and security hardening.

[![Docker Hub](https://img.shields.io/docker/v/oorabona/wordpress?sort=semver&label=Docker%20Hub)](https://hub.docker.com/r/oorabona/wordpress)
[![GHCR](https://img.shields.io/badge/GHCR-oorabona%2Fwordpress-blue)](https://ghcr.io/oorabona/wordpress)
[![Build](https://github.com/oorabona/docker-containers/actions/workflows/auto-build.yaml/badge.svg)](https://github.com/oorabona/docker-containers/actions/workflows/auto-build.yaml)

## Quick Start

```yaml
services:
  openresty:
    image: ghcr.io/oorabona/openresty:latest
    ports:
      - "8080:80"
    volumes:
      - ./nginx.conf:/usr/local/openresty/nginx/conf/nginx.conf:ro
    depends_on:
      wordpress:
        condition: service_healthy

  wordpress:
    image: ghcr.io/oorabona/wordpress:latest
    volumes:
      - wp_uploads:/var/www/html/wp-content/uploads
    environment:
      WORDPRESS_DB_HOST: mariadb
      WORDPRESS_DB_NAME: wordpress
      WORDPRESS_DB_USER: wordpress
      WORDPRESS_DB_PASSWORD_FILE: /run/secrets/db_pass
      WP_AUTO_INSTALL: "true"
      WP_SITE_URL: "https://example.com"
      WP_SITE_TITLE: "My Site"
      WP_ADMIN_USER: admin
      WP_ADMIN_EMAIL: admin@example.com
      WP_ADMIN_PASSWORD_FILE: /run/secrets/admin_pass
      WP_LOCALE: fr_FR
      WP_TIMEZONE: "Europe/Paris"
      WP_PLUGINS: "redis-cache,wordfence"
    depends_on:
      mariadb:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "php-fpm -t"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
    security_opt:
      - no-new-privileges:true

  mariadb:
    image: mariadb:11
    environment:
      MARIADB_ROOT_PASSWORD_FILE: /run/secrets/db_root_pass
      MARIADB_DATABASE: wordpress
      MARIADB_USER: wordpress
      MARIADB_PASSWORD_FILE: /run/secrets/db_pass
    volumes:
      - mariadb_data:/var/lib/mysql
    healthcheck:
      test: ["CMD-SHELL", "healthcheck.sh --connect --innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 5

volumes:
  mariadb_data:
  wp_uploads:
```

With `WP_AUTO_INSTALL=true`, the site is fully operational on first boot — no setup wizard needed.

**Important:** This container runs PHP-FPM on port 9000. It requires a reverse proxy (OpenResty, Nginx, Caddy) to serve HTTP traffic.

## Features

- **Auto-install** — WordPress installs itself on first boot via wp-cli (idempotent)
- **Security hardened** — `DISALLOW_FILE_MODS`, non-root user, no file editor
- **Built on PHP image** — Inherits all PHP extensions (gd, mysqli, opcache, zip) from [ghcr.io/oorabona/php](../php/)
- **WP-CLI included** — Full command-line WordPress management
- **Docker secrets** — All sensitive env vars support `_FILE` suffix
- **Alpine-based** — Small image, fast startup

## Auto-Install

When `WP_AUTO_INSTALL=true` is set, the entrypoint automatically:

1. Generates `wp-config.php` from database env vars
2. Injects security constants (`DISALLOW_FILE_MODS`, `DISALLOW_FILE_EDIT`, etc.)
3. Runs `wp core install` with the provided site settings
4. Sets locale and timezone (if configured)
5. Configures SEO-friendly permalinks (`/%postname%/`)
6. Installs and activates plugins from `WP_PLUGINS` list
7. Disables search engine indexing (enable when ready via wp-admin)

The process is **idempotent** — restarting the container skips installation if WordPress is already set up.

## Environment Variables

### Database (required)

| Variable | Description | Default |
|----------|-------------|---------|
| `WORDPRESS_DB_HOST` | Database hostname | — |
| `WORDPRESS_DB_NAME` | Database name | `wordpress` |
| `WORDPRESS_DB_USER` | Database username | `root` |
| `WORDPRESS_DB_PASSWORD` | Database password | — |

### Auto-Install (optional)

| Variable | Description | Default |
|----------|-------------|---------|
| `WP_AUTO_INSTALL` | Enable auto-install on first boot | `false` |
| `WP_SITE_URL` | Site URL (with protocol) | `http://localhost` |
| `WP_SITE_TITLE` | Site title | `WordPress Site` |
| `WP_ADMIN_USER` | Admin username | `admin` |
| `WP_ADMIN_PASSWORD` | Admin password | — (required) |
| `WP_ADMIN_EMAIL` | Admin email | — (required) |
| `WP_LOCALE` | Site locale (e.g. `fr_FR`) | — |
| `WP_TIMEZONE` | Timezone (e.g. `Europe/Paris`) | — |
| `WP_PLUGINS` | Comma-separated plugin slugs | — |

All variables support the `_FILE` suffix for Docker secrets (e.g. `WP_ADMIN_PASSWORD_FILE`).

### Build Arguments

| Argument | Description | Default |
|----------|-------------|---------|
| `PHP_IMAGE` | Base PHP-FPM image | `ghcr.io/oorabona/php:latest` |
| `WPCLI_VERSION` | WP-CLI version | `2.12.0` |
| `VERSION` | WordPress version | latest |

## Security Model

### Application Layer

The auto-generated `wp-config.php` includes:

```php
define('DISALLOW_FILE_MODS', true);    // No plugin/theme install via wp-admin
define('DISALLOW_FILE_EDIT', true);    // No code editor in wp-admin
define('WP_AUTO_UPDATE_CORE', false);  // Updates via image rebuild
define('AUTOMATIC_UPDATER_DISABLED', true);
```

This means:
- **No file modifications through WordPress** — plugins, themes, and core updates can only happen by rebuilding the container image
- **No code editor** — the theme/plugin editor in wp-admin is disabled
- **Predictable state** — what's in the image is what runs

### Container Layer

```yaml
wordpress:
  security_opt:
    - no-new-privileges:true
  # After first successful boot, add:
  # read_only: true
  # tmpfs:
  #   - /tmp
  #   - /run
```

### Reverse Proxy Layer (OpenResty/Nginx)

```nginx
# Block PHP execution in uploads — critical security rule
location ~* /wp-content/uploads/.*\.php$ {
    deny all;
}

# Block access to sensitive files
location ~* /(wp-config\.php|readme\.html|license\.txt) {
    deny all;
}

# Block XML-RPC (unless needed)
location = /xmlrpc.php {
    deny all;
}

# Rate limit wp-login.php
location = /wp-login.php {
    limit_req zone=login burst=3 nodelay;
    # ... fastcgi_pass
}
```

### Update Workflow

Traditional WordPress updates files in-place (risky). This image uses an immutable approach:

```
Plugin/theme/core update needed
  → Update WP_PLUGINS env var or image tag
  → docker compose pull && docker compose up -d
  → Container restarts with new versions
  → Database is persistent, no data loss
```

### Credential Management

```yaml
# Docker secrets (recommended)
secrets:
  db_pass:
    file: ./secrets/db_password.txt
  admin_pass:
    file: ./secrets/admin_password.txt

services:
  wordpress:
    environment:
      WORDPRESS_DB_PASSWORD_FILE: /run/secrets/db_pass
      WP_ADMIN_PASSWORD_FILE: /run/secrets/admin_pass
    secrets:
      - db_pass
      - admin_pass
```

## Volumes

| Path | Description | Notes |
|------|-------------|-------|
| `/var/www/html/wp-content/uploads` | Media uploads | Only writable volume needed |

WordPress core, plugins, and themes are baked into the image. Only the uploads directory needs persistent storage.

## WP-CLI Usage

```bash
# Site info
docker exec wordpress wp core version
docker exec wordpress wp option get siteurl

# Database
docker exec wordpress wp db check
docker exec wordpress wp db export /tmp/backup.sql

# Users
docker exec wordpress wp user list

# Plugins (read-only — informational)
docker exec wordpress wp plugin list
docker exec wordpress wp plugin status
```

**Note:** `wp plugin install` and `wp theme install` are blocked by `DISALLOW_FILE_MODS`. Plugin installation is done via the `WP_PLUGINS` env var or at image build time.

## Performance

### WordPress-Optimized OPcache

```ini
opcache.memory_consumption=128
opcache.interned_strings_buffer=8
opcache.max_accelerated_files=4000
opcache.revalidate_freq=2
opcache.fast_shutdown=1
opcache.enable_cli=1
```

### PHP Resource Limits

Inherited from base PHP image: memory 512M, upload 64M, execution 300s. Override via custom PHP config mount.

## Architecture

```
┌───────────────────────────────────┐
│         OpenResty / Nginx         │  ← Reverse proxy, security headers,
│   (rate limiting, PHP block in    │     PHP-in-uploads block
│    uploads, security headers)     │
└───────────────┬───────────────────┘
                │ fastcgi :9000
┌───────────────▼───────────────────┐
│     WordPress (PHP-FPM)           │  ← Read-only filesystem
│                                   │     DISALLOW_FILE_MODS=true
│  wp-content/uploads/ → volume     │     Auto-install via wp-cli
└───────────────┬───────────────────┘
                │
┌───────────────▼───────────────────┐
│         MariaDB / MySQL           │  ← All WordPress data lives here
│                                   │     Persistent volume
└───────────────────────────────────┘
```

### Container Layers

```
Alpine Linux
  └── PHP-FPM (from oorabona/php)
      ├── gd, mysqli, opcache, zip, apcu
      └── WordPress
          ├── WordPress core (downloaded at build time)
          ├── WP-CLI
          ├── MariaDB client tools
          └── Auto-install entrypoint
```

### Database Backend

This image is designed for **MariaDB/MySQL**, which is WordPress's native and most battle-tested database backend.

WordPress 6.4+ introduced experimental SQLite support via a drop-in plugin. A future lightweight variant could leverage SQLite for single-container deployments (dev environments, static-ish sites, edge hosting), eliminating the MariaDB dependency. This is not currently implemented.

## Building Locally

```bash
# Build with default versions
./make build wordpress

# Build with specific versions
docker build \
  --build-arg PHP_IMAGE=ghcr.io/oorabona/php:latest \
  --build-arg WPCLI_VERSION=2.12.0 \
  --build-arg VERSION=6.9.1 \
  -t wordpress:custom .
```

## Dependencies

| Component | Version | Source | Monitoring |
|-----------|---------|--------|------------|
| PHP | latest | [oorabona/php](../php/) | Base image tag |
| WP-CLI | 2.12.0 | [wp-cli/wp-cli](https://github.com/wp-cli/wp-cli) | GitHub releases |
| WordPress | latest | [wordpress.org](https://wordpress.org/) | API |

## Links

- [Docker Hub](https://hub.docker.com/r/oorabona/wordpress)
- [GitHub Container Registry](https://ghcr.io/oorabona/wordpress)
- [Source Code](https://github.com/oorabona/docker-containers/tree/master/wordpress)
- [Base PHP Image](../php/)
- [Example Stack](../examples/wordpress-stack/)
- [WP-CLI Documentation](https://wp-cli.org/)
