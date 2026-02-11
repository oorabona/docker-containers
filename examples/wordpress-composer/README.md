# WordPress via Composer

WordPress deployed as a Composer project — core, plugins, and themes are PHP dependencies managed via `composer.json`. Based on the [cloudrly/wordpress](https://github.com/cloudrly/wordpress) project structure.

## When to use this

- Development teams managing WordPress sites as code
- CI/CD pipelines where reproducible builds matter (`composer.lock`)
- Hosted WordPress platforms with blue/green or rolling deployments
- Projects with custom plugins/themes versioned alongside the site
- Organizations already using Composer for PHP dependency management

## Architecture

```
               :8080
┌──────────────────────────────────────┐
│  OpenResty (reverse proxy)           │
│  Blocks /vendor/, uploads PHP        │
├──────────────────────────────────────┤
│  PHP-FPM (custom Dockerfile)         │
│  public/wp/        → WP core         │
│  public/wp-content/→ themes, plugins │
│  vendor/           → Composer deps   │
├──────────────────────────────────────┤
│  MariaDB 11                          │
│  Persistent volume for data          │
└──────────────────────────────────────┘
```

Key structural difference from the standard WordPress image: the core lives in `public/wp/` and content in `public/wp-content/`, separated by [roots/wordpress](https://github.com/roots/wordpress).

## Quick start

```bash
docker compose up -d --build
# Wait for build (Composer resolves dependencies)
# Site available at http://localhost:8080 (requires wp-cli install, see below)
```

Install WordPress via WP-CLI:
```bash
docker compose exec wordpress wp core install \
    --url="http://localhost:8080" \
    --title="My Site" \
    --admin_user=admin \
    --admin_password=change_me \
    --admin_email=admin@example.com
```

## Admin access

After install, the dashboard is at `http://localhost:8080/wp/wp-admin/`.

> In the Composer layout, WP core lives at `/wp/`, so admin URLs are prefixed with `/wp/`.

### Hiding the login URL

Set `WP_ADMIN_PATH` to hide the entire admin area behind a secret URL:

```bash
WP_ADMIN_PATH=my-secret-login docker compose up -d --build
```

When active, all admin paths return **404** to unauthenticated visitors:
- `/wp/wp-login.php` → 404
- `/wp/wp-admin/` → 404
- `/wp/wp-admin/*.php` → 404

To access the admin:
1. Visit `http://localhost:8080/my-secret-login`
2. A secure cookie is set (SHA-256, HttpOnly, SameSite=Strict, 1 hour)
3. You are redirected to the login form
4. After login, `/wp/wp-admin/` works normally until the cookie expires

Also blocked by default: `/wp/xmlrpc.php` (common brute-force vector).

## Adding plugins and themes

Unlike the standard WordPress image, plugins here are **Composer dependencies** — not installed via wp-admin or WP-CLI.

### Adding a plugin

Edit `composer.json`, add the dependency, and rebuild:

```bash
# 1. Add to composer.json "require" section:
#   "wpackagist-plugin/classic-editor": "^1.6"
#   "wpackagist-plugin/akismet": "^5.0"
#   "wpackagist-theme/flavor": "*"

# 2. Rebuild the image
docker compose up -d --build
```

### Adding a custom plugin (not on wpackagist)

For private or custom plugins, add them as local paths or Git repositories:

```json
{
    "repositories": [
        {"type": "path", "url": "./custom-plugins/my-plugin"}
    ],
    "require": {
        "my-org/my-plugin": "*"
    }
}
```

### Available repositories

- **packagist.org** — PHP libraries (e.g., `vlucas/phpdotenv`)
- **wpackagist.org** — WordPress plugins and themes (mirrors wordpress.org)
- **roots/wordpress** — WordPress core as a Composer package

### Why not WP-CLI for plugins?

In the Composer model, `composer.lock` is the single source of truth for what's installed. Using WP-CLI to install plugins would bypass Composer, creating drift between the lockfile and the actual deployed code. Every change goes through `composer.json` → rebuild → deploy.

## How it works

The Dockerfile uses a multi-stage build:

1. **Builder stage** (`composer:2`): resolves dependencies, downloads WP core to `public/wp/`, installs themes/plugins to `public/wp-content/`
2. **Runtime stage** (PHP-FPM): copies built app, adds WP-CLI, runs as non-root

The `wp-config.php` reads all settings from environment variables — no secrets in code.

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `WORDPRESS_DB_HOST` | `localhost` | Database host |
| `WORDPRESS_DB_NAME` | `wordpress` | Database name |
| `WORDPRESS_DB_USER` | `root` | Database user |
| `WORDPRESS_DB_PASSWORD` | — | Database password |
| `WP_HOME` | `http://localhost` | Public site URL |
| `WP_DEBUG` | `false` | Enable WordPress debug mode |
| `WP_ADMIN_PATH` | — | Secret URL path to access the admin area |
| `DISALLOW_FILE_MODS` | `true` | Block plugin/theme installs via wp-admin |
| `DISALLOW_FILE_EDIT` | `true` | Block code editor in wp-admin |
| `WP_AUTO_UPDATE_CORE` | `false` | Disable automatic core updates |
| `AUTOMATIC_UPDATER_DISABLED` | `true` | Disable all background updates |

## Security model

Security constants are **configurable via environment variables** (not hardcoded). The compose file enables them by default:

| Variable | Default | Effect |
|----------|---------|--------|
| `DISALLOW_FILE_MODS` | `true` | No plugin/theme installs via wp-admin |
| `DISALLOW_FILE_EDIT` | `true` | No code editor in wp-admin |
| `WP_AUTO_UPDATE_CORE` | `false` | No automatic core updates |
| `AUTOMATIC_UPDATER_DISABLED` | `true` | No background updates at all |

Set any of these to an empty value to disable that restriction.

Additional security layers:
- **Composer autoloader** only — no remote code execution
- **OpenResty** blocks access to `/vendor/`, PHP in uploads, xmlrpc.php
- **WP_ADMIN_PATH** — hides login URL and entire `/wp/wp-admin/` area (optional)
- All dependencies pinned in `composer.lock` (reproducible builds)

> **Production hardening:** add `read_only: true` + `tmpfs: [/tmp, /run]` to the wordpress service. The image is already self-contained — only the uploads volume and database need to be writable.

## Testing

```bash
bash test.sh
```

## See also

- [wordpress-stack](../wordpress-stack/) — Standard deployment with auto-install
- [wordpress-sqlite](../wordpress-sqlite/) — Lightweight deployment without database server
- [cloudrly/wordpress](https://github.com/cloudrly/wordpress) — Original Composer project template
