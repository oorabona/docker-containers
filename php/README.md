# PHP-FPM

Production-ready PHP-FPM container with Composer integration, optimized for modern PHP applications. Built on Alpine Linux with essential extensions and security hardening.

[![Docker Hub](https://img.shields.io/docker/v/oorabona/php?sort=semver&label=Docker%20Hub)](https://hub.docker.com/r/oorabona/php)
[![GHCR](https://img.shields.io/badge/GHCR-oorabona%2Fphp-blue)](https://ghcr.io/oorabona/php)
[![Build](https://github.com/oorabona/docker-containers/actions/workflows/auto-build.yaml/badge.svg)](https://github.com/oorabona/docker-containers/actions/workflows/auto-build.yaml)

## Quick Start

```bash
# Pull from GitHub Container Registry
docker pull ghcr.io/oorabona/php:8.4-fpm-alpine

# Pull from Docker Hub
docker pull oorabona/php:8.4-fpm-alpine
```

## Features

### PHP Extensions
- **gd** - Image processing with FreeType and JPEG support
- **mysqli** - MySQL database connectivity
- **opcache** - Opcode caching for performance
- **zip** - ZIP archive handling
- **apcu** - User-space caching

### Included Tools
- **Composer** 2.9.5 - Dependency management
- **Git** - Version control for Composer
- Custom helper scripts:
  - `entrypoint-fpm` - Container initialization
  - `healthcheck-fpm` - Health monitoring
  - `command-loop` - Background command runner
  - `command-loop-w-cooldown` - Command runner with cooldown

### Configuration
- Production-ready `php.ini` settings
- Optimized OPcache configuration (512MB, 20,000 files)
- APCu enabled for user-space caching
- Security hardening (expose_php=off, session security)
- Custom PHP-FPM pool configuration
- Session management ready for Redis (commented out)

### Security Features
- Non-root user (`nobody`)
- Minimal Alpine base (reduced attack surface)
- Multi-stage build (build dependencies removed)
- Hardened session security (HTTPOnly, Secure, SameSite)
- Read-only filesystem compatible
- Capability dropping support

## Usage

### Docker Compose

```yaml
services:
  php:
    image: ghcr.io/oorabona/php:8.4-fpm-alpine
    volumes:
      - ./app:/var/www/app
      - composer-cache:/var/www/.composer
    environment:
      APP_ENV: prod
      APP_DEBUG: 0
    networks:
      - backend
    healthcheck:
      test: ["CMD", "healthcheck-fpm"]
      interval: 30s
      timeout: 10s
      retries: 3

  nginx:
    image: nginx:alpine
    ports:
      - "80:80"
    volumes:
      - ./app:/var/www/app:ro
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      - php
    networks:
      - backend

networks:
  backend:

volumes:
  composer-cache:
```

### Docker Run

```bash
# Run PHP-FPM
docker run -d \
  --name php-fpm \
  -v $(pwd)/app:/var/www/app \
  -v composer-cache:/var/www/.composer \
  ghcr.io/oorabona/php:8.4-fpm-alpine

# Run Composer commands
docker run --rm \
  -v $(pwd):/var/www/app \
  -w /var/www/app \
  ghcr.io/oorabona/php:8.4-fpm-alpine \
  composer install
```

### Nginx Configuration Example

PHP-FPM requires a web server (Nginx, Apache, Caddy, etc.). Example Nginx configuration:

```nginx
server {
    listen 80;
    root /var/www/app/public;
    index index.php;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass php:9000;  # PHP-FPM service name
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
    }
}
```

## Configuration

### Build Arguments

| Argument | Description | Default |
|----------|-------------|---------|
| `VERSION` | PHP base image version | (required) |
| `COMPOSER_VERSION` | Composer version | 2.9.5 |
| `APCU_VERSION` | APCu extension version | 5.1.28 |
| `COMPOSER_AUTH` | Composer authentication JSON for private repos | "" |

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `APP_ENV` | Application environment | prod |
| `APP_DEBUG` | Debug mode (0=off, 1=on) | 0 |
| `APP_BASE_PATH` | Application base path | /var/www/app/ |
| `COMPOSER_AUTH` | Composer authentication (build-time) | "" |
| `COMPOSER_CACHE_DIR` | Composer cache directory | /var/www/.composer/ |

### Volumes

| Path | Purpose |
|------|---------|
| `/var/www/` | Application root and Composer cache |
| `/var/www/app/` | Application code directory |
| `/var/www/.composer/` | Composer cache (mount for persistence) |
| `/var/log/shared/` | Shared log directory |

### Ports

| Port | Protocol | Purpose |
|------|----------|---------|
| 9000 | TCP | PHP-FPM FastCGI (NOT HTTP) |

**Important**: PHP-FPM listens on port 9000 for FastCGI connections. This is NOT an HTTP port. You must use a web server (Nginx, Apache, etc.) to handle HTTP requests and proxy to PHP-FPM.

## Security

### Base Security
- **Non-root user**: Runs as `nobody` user
- **Alpine-based**: Minimal base image (~80MB)
- **Multi-stage build**: Build dependencies removed from final image
- **Production php.ini**: Secure defaults (expose_php=off)
- **Session hardening**: HTTPOnly, Secure, SameSite=Strict
- **Read-only filesystem**: Compatible with `--read-only` flag

### Runtime Hardening

```yaml
services:
  php:
    image: ghcr.io/oorabona/php:8.4-fpm-alpine
    read_only: true
    tmpfs:
      - /tmp
      - /run
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    volumes:
      - ./app:/var/www/app:ro
      - composer-cache:/var/www/.composer
    user: "nobody:nobody"
```

### Docker Run Security

```bash
docker run -d \
  --name php-fpm \
  --read-only \
  --tmpfs /tmp \
  --tmpfs /run \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  -v $(pwd)/app:/var/www/app:ro \
  -v composer-cache:/var/www/.composer \
  ghcr.io/oorabona/php:8.4-fpm-alpine
```

### Security Best Practices
- Never include `COMPOSER_AUTH` with credentials in version control
- Use Docker secrets or environment variables for sensitive data
- Mount application code as read-only in production (`:ro`)
- Keep PHP and dependencies updated via automated builds
- Review uploaded files if handling file uploads
- Use HTTPS only (ensure `session.cookie_secure=1` works)

## PHP Configuration Details

### OPcache Settings
```ini
opcache.memory_consumption=512        # 512MB cache
opcache.max_accelerated_files=20000   # Cache up to 20,000 files
opcache.validate_timestamps=0         # No revalidation (production)
opcache.revalidate_freq=2             # Check every 2 seconds (if enabled)
opcache.enable_cli=1                  # Enable for CLI scripts
```

### APCu Settings
```ini
apc.enable_cli=1                      # Enable for CLI
apc.enable=1                          # Enable for web requests
```

### Resource Limits
```ini
memory_limit=256M                     # 256MB per request
max_execution_time=360                # 6 minutes
post_max_size=100M                    # Max POST size
upload_max_filesize=100M              # Max file upload size
```

### Session Security
```ini
session.cookie_httponly=1             # JavaScript cannot access
session.cookie_secure=1               # HTTPS only
session.cookie_same_site=Strict       # CSRF protection
session.use_strict_mode=1             # Reject uninitialized session IDs
```

## Dependencies

This container includes pinned versions of third-party dependencies:

| Dependency | Version | Source | License |
|------------|---------|--------|---------|
| Composer | 2.9.5 | [composer/composer](https://github.com/composer/composer) | MIT |
| APCu | 5.1.28 | [krakjoe/apcu](https://github.com/krakjoe/apcu) | PHP-3.01 |

Versions are automatically monitored and updated via GitHub Actions.

## Architecture

**Supported Platforms:**
- linux/amd64
- linux/arm64

**Base Images:**
- Build stage: `composer:${COMPOSER_VERSION}` (Alpine)
- Runtime stage: `php:${VERSION}` (Alpine FPM)

**Size:** ~80MB compressed

## Advanced Usage

### Using Composer Authentication

For private repositories, pass authentication at build time:

```bash
# Create composer auth JSON
cat > auth.json <<EOF
{
  "github-oauth": {
    "github.com": "ghp_yourTokenHere"
  }
}
EOF

# Build with authentication
docker build \
  --build-arg VERSION=8.4-fpm-alpine \
  --build-arg COMPOSER_AUTH="$(cat auth.json)" \
  -t php:custom .
```

**Warning**: Never commit `COMPOSER_AUTH` to version control. Use build secrets or CI variables.

### Custom PHP Extensions

To add additional extensions, create a custom Dockerfile:

```dockerfile
FROM ghcr.io/oorabona/php:8.4-fpm-alpine

USER root
RUN apk add --no-cache --virtual .build-deps $PHPIZE_DEPS \
    && pecl install redis \
    && docker-php-ext-enable redis \
    && apk del .build-deps

USER nobody
```

### Development Mode

For development, you may want timestamps validation and display_errors:

```dockerfile
FROM ghcr.io/oorabona/php:8.4-fpm-alpine

USER root
RUN echo "opcache.validate_timestamps=1" >> $PHP_INI_DIR/conf.d/php.ini \
    && echo "display_errors=on" >> $PHP_INI_DIR/conf.d/php.ini \
    && echo "error_reporting=E_ALL" >> $PHP_INI_DIR/conf.d/php.ini

USER nobody
ENV APP_ENV=dev
ENV APP_DEBUG=1
```

### Command Loop Scripts

The container includes helper scripts for running background commands:

```bash
# Run command repeatedly
docker exec php-fpm command-loop "php artisan queue:work"

# Run with cooldown period between executions
docker exec php-fpm command-loop-w-cooldown "php artisan schedule:run"
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

## Building Locally

```bash
# From repository root
cd php

# Build with specific PHP version
docker build \
  --build-arg VERSION=8.4-fpm-alpine \
  --build-arg COMPOSER_VERSION=2.9.5 \
  --build-arg APCU_VERSION=5.1.28 \
  -t php:8.4-fpm-alpine .

# Build with docker-compose
docker-compose build
```

## Common Frameworks

### Laravel

```yaml
services:
  php:
    image: ghcr.io/oorabona/php:8.4-fpm-alpine
    volumes:
      - ./laravel:/var/www/app
    environment:
      APP_ENV: production
      APP_DEBUG: 0
    working_dir: /var/www/app
```

### Symfony

```yaml
services:
  php:
    image: ghcr.io/oorabona/php:8.4-fpm-alpine
    volumes:
      - ./symfony:/var/www/app
    environment:
      APP_ENV: prod
      APP_DEBUG: 0
    working_dir: /var/www/app/public
```

### WordPress

For WordPress, consider using the [wordpress container](../wordpress/) which includes additional optimizations.

## Troubleshooting

### Health Check Failing

```bash
# Check PHP-FPM status
docker exec php-fpm healthcheck-fpm

# Check PHP-FPM logs
docker logs php-fpm

# Validate FPM configuration
docker exec php-fpm php-fpm -t
```

### Connection Issues

```bash
# Verify PHP-FPM is listening on port 9000
docker exec php-fpm netstat -tlnp | grep 9000

# Test from web server container
docker exec nginx nc -zv php 9000
```

### Composer Issues

```bash
# Clear Composer cache
docker exec php-fpm composer clear-cache

# Diagnose Composer
docker exec php-fpm composer diagnose

# Check Composer version
docker exec php-fpm composer --version
```

### Permission Issues

```bash
# Check ownership
docker exec php-fpm ls -la /var/www/

# Fix ownership (if needed)
docker exec -u root php-fpm chown -R nobody:nobody /var/www/
```

## Links

- **Docker Hub**: https://hub.docker.com/r/oorabona/php
- **GitHub Container Registry**: https://ghcr.io/oorabona/php
- **Source Code**: https://github.com/oorabona/docker-containers/tree/master/php
- **Issue Tracker**: https://github.com/oorabona/docker-containers/issues
- **Official PHP Documentation**: https://www.php.net/docs.php
- **PHP-FPM Documentation**: https://www.php.net/manual/en/install.fpm.php
- **Composer Documentation**: https://getcomposer.org/doc/
