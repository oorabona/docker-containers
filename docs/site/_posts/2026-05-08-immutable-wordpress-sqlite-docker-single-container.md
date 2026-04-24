---
layout: post
title: "Immutable WordPress in Docker: DISALLOW_FILE_MODS + SQLite for Single-Container Deployments"
description: "A 237 MB WordPress container that runs SQLite (no MariaDB), blocks in-dashboard plugin installs, and fits the immutable-infrastructure pattern."
date: 2026-05-08 10:00:00 +0000
tags: [wordpress, docker, sqlite, immutable, security]
---

If you've ever deployed WordPress to production, you know the drill: set up MariaDB, set up WordPress, give wp-admin to someone, come back in 6 months to a 30-plugin Frankenstein with 4 known-vulnerable versions and a cryptominer in `wp-content/uploads/`.

The `oorabona/wordpress` image is for the other path: **WordPress as immutable infrastructure**. No in-dashboard plugin installs, no theme editor, single-container deployment with SQLite instead of MariaDB. Your code is in git; the container never edits itself.

## What's in the image

```bash
docker pull ghcr.io/oorabona/wordpress:latest
# 237 MB compressed, amd64 + arm64
```

- **WordPress core** (latest stable, auto-tracked from [wp.org releases](https://wordpress.org/download/releases/))
- **WP-CLI 2.12.0** for scripted admin (no need to click buttons)
- **SQLite Database Integration plugin** pre-installed (wordpress.org plugin 2.2.23)
- **PHP-FPM** from the [oorabona/php](/docker-containers/container/php/) image (Composer, APCu baked in)
- **Non-root user `wordpress`** with passwordless sudo scoped to `/usr/local/bin/wp` only
- **Healthcheck** via `php-fpm -t`
- **OPcache tuned** for WordPress (128 MB, 4 000 files, `fast_shutdown=1`)

The `wp-config.php` hard-codes two constants that change everything:

```php
define('DISALLOW_FILE_MODS', true);   // Block all plugin/theme install UI
define('DISALLOW_FILE_EDIT', true);   // Block the built-in file editor
```

This is not a preference; it's baked in. The container has no ability to install a plugin via the dashboard. If someone steals an admin password, they cannot install a malicious plugin. They cannot edit `functions.php` from the editor. They cannot do the 90% of post-compromise actions that turn a compromised WordPress into a crypto miner or a spam relay.

## The SQLite story

WordPress officially requires MySQL or MariaDB, but a [wordpress.org plugin](https://wordpress.org/plugins/sqlite-database-integration/) adds SQLite as an adapter. It's stable, widely used, maintained. For sites under a few thousand posts and < 10 writes/s, SQLite is fine — and simpler.

Our image bundles the SQLite integration plugin in `wp-content/plugins/`. On first boot:

```bash
docker run -d \
  --name wp \
  -e DB_DIR=/var/www/html/wp-content/database \
  -v wp-data:/var/www/html/wp-content \
  -p 8080:80 \
  ghcr.io/oorabona/wordpress:latest
```

No MariaDB container, no database URL, no root password to rotate. One `wp-data` volume contains everything: uploaded media, the SQLite file, site configuration.

### When SQLite is the right call

- **Small sites** — blogs, landing pages, documentation, portfolios (< 10 000 page views/day)
- **Development / staging** — `docker-compose up` and you're live, no DB server to manage
- **Edge deployments** — a WordPress per customer site on a Raspberry Pi, each fully isolated
- **Homelab** — you want to run WordPress next to your Jellyfin without adding MariaDB

### When to stick with MariaDB

- Shared hosting, multi-site networks, heavy concurrency, > 100 k posts, real-time collaboration. The SQLite plugin is honest about its limits; heavy-write workloads show it.

## Full stack with MariaDB (if you need it)

The image also works with MariaDB. The only difference is `wp-config.php` gets the usual `DB_HOST`, `DB_USER`, etc. — and you remove the SQLite plugin activation.

```yaml
# compose.yml
services:
  wp:
    image: ghcr.io/oorabona/wordpress:latest
    environment:
      WORDPRESS_DB_HOST: db
      WORDPRESS_DB_USER: wp
      WORDPRESS_DB_PASSWORD: ${MYSQL_PASSWORD:?required}
      WORDPRESS_DB_NAME: wordpress
    volumes:
      - wp-data:/var/www/html/wp-content
    depends_on:
      db:
        condition: service_healthy
    ports:
      - "8080:80"
    restart: unless-stopped

  db:
    image: mariadb:11
    environment:
      MYSQL_RANDOM_ROOT_PASSWORD: "yes"
      MYSQL_DATABASE: wordpress
      MYSQL_USER: wp
      MYSQL_PASSWORD: ${MYSQL_PASSWORD:?required}
    volumes:
      - db-data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped

volumes:
  wp-data:
  db-data:
```

Nothing exotic here. The immutability applies equally to both.

## Managing plugins and themes without the UI

This is where most people get confused. "If `DISALLOW_FILE_MODS` is on, how do I install a plugin?"

**Answer:** you add it to your image, or you mount it from a volume controlled by your deploy pipeline. WordPress admin is for content, not infrastructure.

### Option A: bake plugins into a derived image

```dockerfile
FROM ghcr.io/oorabona/wordpress:latest

# Add the plugins you actually need
RUN wp --allow-root plugin install yoast-seo contact-form-7 wp-super-cache

# Optional: pin versions
RUN wp --allow-root plugin install yoast-seo --version=22.8.1
```

Rebuild + redeploy = plugins installed. Want to remove a plugin? Remove the RUN line and redeploy.

### Option B: mount a plugin directory from git

```yaml
services:
  wp:
    image: ghcr.io/oorabona/wordpress:latest
    volumes:
      - ./plugins-repo:/var/www/html/wp-content/plugins/custom:ro
```

Your custom plugin lives in a git repo. Deploy = `docker compose pull && docker compose up -d`. Rollback = `git revert`.

Either way, the *attack surface* is deliberate. No admin compromise can install new code.

## What breaks with `DISALLOW_FILE_MODS`

- **WordPress auto-update** — the built-in updater is disabled. You must bump the image tag and redeploy. Since our image is auto-rebuilt when a WP release ships (with SBOM + attestation), `docker pull` replaces it.
- **Plugin/theme auto-updates** — same story. Bake new versions into the derived image or update your mounted volume.
- **Plugin installer UI** — gone. The admin sidebar doesn't even show "Add New" under Plugins.
- **Theme customizer > "Install Theme"** — gone. Use FTP on the dev box, commit the theme, redeploy.

None of this is actually a downside for the deployment pattern you want. If you want auto-updates, you want the mutable-stateful model — which this image isn't for.

## WP-CLI inside the container

Admin scripting via WP-CLI works as expected:

```bash
docker exec -it wp sudo -u wordpress wp user create alice alice@example.com \
  --role=editor --user_pass=$(openssl rand -base64 24)

docker exec -it wp sudo -u wordpress wp search-replace 'old.example.com' 'new.example.com'

docker exec -it wp sudo -u wordpress wp db export /tmp/backup.sql
docker cp wp:/tmp/backup.sql ./
```

The `wordpress` user has passwordless sudo for `/usr/local/bin/wp` only. No other binary. Even with a shell in the container, an attacker can't `sudo su`.

## Gotchas

- **`wp-content/uploads/`** must be writable. The Docker volume mount point already is. Don't mount it `:ro`.
- **Fast CGI buffering** on your reverse proxy (nginx) matters for large uploads. Default limits in our [openresty image](/docker-containers/container/openresty/) allow 100 MB per upload; adjust `client_max_body_size` if you host media.
- **Reverse proxy headers** — set `WP_HOME` and `WP_SITEURL` via env vars if you're behind a proxy, otherwise login redirects break.
- **Backup = backup the volume.** With SQLite, `wp-data` contains the whole database. Back up `wp-data`, restore `wp-data`, you're whole.
- **Plugin file size** — some plugins bundle megabytes of assets that belong in media storage. An image built with 20 baked plugins can easily hit 500 MB. Watch your layer sizes.

## Comparison with other images

| Image | Size | Comes with | In-dashboard installs |
|---|---|---|---|
| `wordpress:latest` (official) | ~250 MB | MySQL or PostgreSQL (no SQLite) | **allowed** |
| `bitnami/wordpress` | ~900 MB | MariaDB + phpMyAdmin + everything | **allowed** |
| `oorabona/wordpress` | **237 MB** | SQLite plugin, WP-CLI, no DB | **blocked** |

Ours is the smallest and the most locked down. It's also the only one that ships an SBOM and Sigstore attestation out of the box.

## TL;DR

```bash
# SQLite, single container, immutable
docker run -d --name wp \
  -v wp-data:/var/www/html/wp-content \
  -p 8080:80 \
  ghcr.io/oorabona/wordpress:latest
```

Every flavor and full config: [container dashboard](/docker-containers/container/wordpress/).

If this pattern saved you from an incident response, [⭐ the repo](https://github.com/oorabona/docker-containers). (We know the 2.5k pulls aren't all from CI. You're real. Wave.)
