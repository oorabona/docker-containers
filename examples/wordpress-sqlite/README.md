# WordPress + SQLite Stack

Lightweight WordPress deployment with no external database — uses the SQLite Database Integration plugin for a single-container data backend.

## When to use this

- Personal blogs, portfolios, documentation sites
- Development and testing environments
- Low-traffic sites where database server overhead is not justified
- Edge deployments or resource-constrained environments
- Rapid prototyping (one `docker compose up` and you're running)

## Architecture

```
               :8080
┌──────────────────────────────────────┐
│  OpenResty (reverse proxy)           │
│  Security headers, SQLite DB block   │
├──────────────────────────────────────┤
│  WordPress (PHP-FPM)                 │
│  WP_DB_TYPE=sqlite                   │
│  SQLite file in wp-content/database/ │
└──────────────────────────────────────┘
```

No MariaDB/MySQL container needed. The SQLite database file is stored on a named volume.

## Quick start

```bash
docker compose up -d
# Site is auto-installed and ready at http://localhost:8080
# Admin: admin / change_me_now
```

## How it works

The WordPress container includes the [SQLite Database Integration](https://wordpress.org/plugins/sqlite-database-integration/) plugin (pre-installed at build time). When `WP_DB_TYPE=sqlite` is set:

1. The entrypoint creates `wp-content/database/` and activates the SQLite drop-in (`db.php`)
2. `wp config create` generates a wp-config.php with `DB_DIR` and `DB_FILE` constants
3. WordPress uses `wp-content/database/.ht.sqlite` instead of MySQL

## Admin access

The WordPress dashboard is at `http://localhost:8080/wp-admin/`. Default credentials are `admin` / `change_me_now`.

### Hiding the login URL

Set `WP_ADMIN_PATH` to hide the entire admin area behind a secret URL:

```bash
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

Also blocked by default: `/xmlrpc.php` (common brute-force vector).

## Adding plugins and themes

The wp-admin UI is locked (`DISALLOW_FILE_MODS=true`). Three ways to add plugins:

### 1. At first boot — `WP_PLUGINS` env var

```yaml
# docker-compose.yaml
environment:
  WP_PLUGINS: "classic-editor, contact-form-7"
```

> **Note:** only runs during initial setup. To reset: `docker compose down -v`.

### 2. At runtime — WP-CLI

```bash
docker compose exec wordpress wp plugin install classic-editor --activate
docker compose exec wordpress wp plugin list
```

Plugins persist in the container but are **lost if the container is recreated**.

### 3. At build time — custom Dockerfile (recommended)

```dockerfile
FROM ghcr.io/oorabona/wordpress:latest
USER root
RUN su -s /bin/bash wordpress -c " \
    wp plugin install classic-editor --activate"
USER wordpress
```

## Limitations

- Not suitable for high-concurrency write workloads (SQLite locking)
- Some plugins that use MySQL-specific SQL may not work
- No database replication or clustering
- Backup = copy the SQLite file (simpler than MySQL dumps, but no point-in-time recovery)

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `WP_DB_TYPE` | — | Set to `sqlite` to use SQLite backend |
| `WP_AUTO_INSTALL` | `true` | Auto-install WordPress on first boot |
| `WP_SITE_URL` | `http://localhost:8080` | Public site URL |
| `WP_SITE_TITLE` | `My WordPress Site` | Site title |
| `WP_ADMIN_USER` | `admin` | Admin username |
| `WP_ADMIN_PASSWORD` | (required) | Admin password |
| `WP_ADMIN_EMAIL` | (required) | Admin email |
| `WP_PLUGINS` | — | Comma-separated plugin slugs (first boot only) |
| `WP_ADMIN_PATH` | — | Secret URL path to access the admin area |

## Security model

- **DISALLOW_FILE_MODS** — no plugin/theme installs via wp-admin
- **OpenResty** blocks access to `wp-content/database/` (protects SQLite file)
- **OpenResty** blocks PHP execution in uploads, xmlrpc.php
- **WP_ADMIN_PATH** — hides login URL and entire `/wp-admin/` area (optional)

## Testing

```bash
bash test.sh
```

## See also

- [wordpress-stack](../wordpress-stack/) — Full deployment with MariaDB
- [wordpress-composer](../wordpress-composer/) — Composer-managed deployment for development teams
