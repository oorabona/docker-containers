# WordPress

Production-ready WordPress container built on PHP-FPM with WP-CLI, performance optimizations, and security hardening.

[![Docker Hub](https://img.shields.io/docker/v/oorabona/wordpress?sort=semver&label=Docker%20Hub)](https://hub.docker.com/r/oorabona/wordpress)
[![GHCR](https://img.shields.io/badge/GHCR-oorabona%2Fwordpress-blue)](https://ghcr.io/oorabona/wordpress)
[![Build](https://github.com/oorabona/docker-containers/actions/workflows/auto-build.yaml/badge.svg)](https://github.com/oorabona/docker-containers/actions/workflows/auto-build.yaml)

## Quick Start

### Docker Compose

```yaml
services:
  nginx:
    image: nginx:alpine
    ports:
      - "80:80"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - wordpress_data:/var/www/html:ro
    depends_on:
      - wordpress

  wordpress:
    image: ghcr.io/oorabona/wordpress:latest
    environment:
      WORDPRESS_DB_HOST: db
      WORDPRESS_DB_NAME: ${WORDPRESS_DB_NAME}
      WORDPRESS_DB_USER: ${WORDPRESS_DB_USER}
      WORDPRESS_DB_PASSWORD: ${WORDPRESS_DB_PASSWORD}
    volumes:
      - wordpress_data:/var/www/html

  db:
    image: mysql:8.0
    environment:
      MYSQL_DATABASE: ${WORDPRESS_DB_NAME}
      MYSQL_USER: ${WORDPRESS_DB_USER}
      MYSQL_PASSWORD: ${WORDPRESS_DB_PASSWORD}
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
    volumes:
      - db_data:/var/lib/mysql

volumes:
  wordpress_data:
  db_data:
```

### Docker Run

```bash
# Start database
docker run -d --name wordpress-db \
  -e MYSQL_DATABASE=wordpress \
  -e MYSQL_USER=wordpress \
  -e MYSQL_PASSWORD=secret \
  -e MYSQL_ROOT_PASSWORD=rootsecret \
  mysql:8.0

# Start WordPress
docker run -d --name wordpress \
  --link wordpress-db:mysql \
  -e WORDPRESS_DB_HOST=mysql \
  -e WORDPRESS_DB_NAME=wordpress \
  -e WORDPRESS_DB_USER=wordpress \
  -e WORDPRESS_DB_PASSWORD=secret \
  -v wordpress_data:/var/www/html \
  ghcr.io/oorabona/wordpress:latest

# Start web server (example with Nginx)
docker run -d --name nginx \
  --link wordpress:wordpress \
  -p 80:80 \
  -v wordpress_data:/var/www/html:ro \
  -v ./nginx.conf:/etc/nginx/nginx.conf:ro \
  nginx:alpine
```

**Important:** This container runs PHP-FPM on port 9000, not a web server. You must pair it with Nginx, Apache, or another reverse proxy to serve HTTP traffic.

## Features

- **Built on PHP Image** - Inherits all PHP extensions (gd, mysqli, opcache, zip) from [ghcr.io/oorabona/php](https://github.com/oorabona/docker-containers/tree/master/php)
- **WP-CLI Included** - Command-line interface for WordPress management
- **Performance Optimized** - WordPress-tuned OPcache settings for improved performance
- **Security Hardened** - Non-root user, limited sudo access, minimal dependencies
- **Alpine-based** - Small image size, fast startup
- **MariaDB Client** - Database tools included for debugging

## Build Arguments

| Argument | Description | Default |
|----------|-------------|---------|
| `PHP_IMAGE` | Base PHP-FPM image | `ghcr.io/oorabona/php:latest` |
| `WPCLI_VERSION` | WP-CLI version | `2.12.0` |

## Environment Variables

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `WORDPRESS_DB_HOST` | Database hostname | - | Yes |
| `WORDPRESS_DB_NAME` | Database name | - | Yes |
| `WORDPRESS_DB_USER` | Database username | - | Yes |
| `WORDPRESS_DB_PASSWORD` | Database password | - | Yes |
| `WORDPRESS_TABLE_PREFIX` | Table prefix | `wp_` | No |
| `WORDPRESS_DEBUG` | Enable debug mode | `false` | No |

Additional PHP-FPM environment variables inherited from the base PHP image.

## Volumes

| Path | Description |
|------|-------------|
| `/var/www/html` | WordPress installation directory |

For plugin/theme development, mount specific directories:

```yaml
volumes:
  - wordpress_data:/var/www/html
  - ./my-theme:/var/www/html/wp-content/themes/my-theme
  - ./my-plugin:/var/www/html/wp-content/plugins/my-plugin
```

## Ports

| Port | Protocol | Description |
|------|----------|-------------|
| `9000` | TCP | PHP-FPM (requires reverse proxy for HTTP) |

**Note:** This container does NOT expose port 80/443. You must use a reverse proxy (Nginx, Apache, Caddy) to serve HTTP traffic. See [Nginx configuration example](#nginx-configuration).

## WP-CLI Usage

Execute WP-CLI commands in the running container:

```bash
# Check WP-CLI info
docker exec wordpress wp --info

# Install plugins
docker exec wordpress wp plugin install contact-form-7 --activate

# Update core
docker exec wordpress wp core update

# List users
docker exec wordpress wp user list

# Database operations
docker exec wordpress wp db check
docker exec wordpress wp db optimize
```

## Nginx Configuration

Example Nginx configuration for serving WordPress via FastCGI:

```nginx
upstream php {
    server wordpress:9000;
}

server {
    listen 80;
    server_name example.com;

    root /var/www/html;
    index index.php;

    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass php;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param PATH_INFO $fastcgi_path_info;
    }

    location ~ /\.ht {
        deny all;
    }
}
```

## Security

### Base Security

- **Alpine Linux** - Minimal attack surface with carefully selected packages
- **Non-root User** - Container runs as `wordpress` user (not root)
- **Limited Sudo** - sudo access restricted to `/usr/local/bin/wp` only
- **Regular Updates** - Automated rebuilds on upstream changes

### Runtime Hardening

```yaml
services:
  wordpress:
    image: ghcr.io/oorabona/wordpress:latest
    read_only: true
    tmpfs:
      - /tmp
      - /run
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETGID
      - SETUID
    security_opt:
      - no-new-privileges:true
    volumes:
      - wordpress_data:/var/www/html
    environment:
      WORDPRESS_DB_HOST: db
      WORDPRESS_DB_NAME: ${WORDPRESS_DB_NAME}
      WORDPRESS_DB_USER: ${WORDPRESS_DB_USER}
      WORDPRESS_DB_PASSWORD: ${WORDPRESS_DB_PASSWORD}
```

### Credential Management

**Never hardcode passwords:**

```yaml
# BAD
environment:
  WORDPRESS_DB_PASSWORD: mysecretpassword

# GOOD - Environment variable
environment:
  WORDPRESS_DB_PASSWORD: ${WORDPRESS_DB_PASSWORD}

# BETTER - Docker secrets
secrets:
  db_password:
    file: ./secrets/db_password.txt
environment:
  WORDPRESS_DB_PASSWORD_FILE: /run/secrets/db_password
```

## Performance Tuning

### WordPress-Optimized OPcache Settings

The container includes tuned OPcache configuration:

```ini
opcache.memory_consumption=128
opcache.interned_strings_buffer=8
opcache.max_accelerated_files=4000
opcache.revalidate_freq=2
opcache.fast_shutdown=1
opcache.enable_cli=1
```

### PHP Resource Limits

Inherited from base PHP image:
- Memory limit: 512M
- Upload limit: 64M
- Execution time: 300s

Override via environment or custom PHP configuration file.

## Dependencies

| Component | Version | Source | Monitoring |
|-----------|---------|--------|------------|
| PHP | latest | [oorabona/php](https://github.com/oorabona/docker-containers/tree/master/php) | Base image tag |
| WP-CLI | 2.12.0 | [wp-cli/wp-cli](https://github.com/wp-cli/wp-cli) | GitHub releases |

Dependency versions are automatically monitored and updated via CI/CD.

## Health Check

Built-in health check verifies PHP-FPM status:

```bash
# Manual health check
docker exec wordpress php-fpm -t

# Docker health status
docker inspect --format='{{.State.Health.Status}}' wordpress
```

## Backup & Restore

### Database Backup

```bash
# Backup via WP-CLI
docker exec wordpress wp db export /tmp/backup.sql

# Copy backup out of container
docker cp wordpress:/tmp/backup.sql ./backup.sql
```

### File Backup

```bash
# Backup WordPress files
docker exec wordpress tar -czf /tmp/wp-files.tar.gz /var/www/html

# Copy backup out
docker cp wordpress:/tmp/wp-files.tar.gz ./wp-files.tar.gz
```

### Restore

```bash
# Restore database
docker exec -i wordpress wp db import - < backup.sql

# Restore files
docker cp wp-files.tar.gz wordpress:/tmp/
docker exec wordpress tar -xzf /tmp/wp-files.tar.gz -C /
```

## Building Locally

```bash
# Build with default versions
./make build wordpress

# Build with specific PHP version
docker build \
  --build-arg PHP_IMAGE=ghcr.io/oorabona/php:8.2-fpm-alpine \
  --build-arg WPCLI_VERSION=2.12.0 \
  -t wordpress:custom .

# Check current version
./version.sh current

# Check latest upstream version
./version.sh latest
```

## Architecture

```
wordpress/
├── Dockerfile              # Multi-stage build based on PHP image
├── config.yaml             # WP-CLI version and dependency config
├── docker-compose.yml      # Example compose file
├── docker-entrypoint.sh    # Container entrypoint script
├── version.sh              # Version discovery script
└── README.md               # This file
```

### Container Layers

```
Alpine Linux
  └── PHP-FPM (from oorabona/php)
      └── WordPress additions
          ├── WP-CLI
          ├── MariaDB client
          ├── WordPress-tuned OPcache
          └── Security hardening
```

## Links

- [Docker Hub](https://hub.docker.com/r/oorabona/wordpress)
- [GitHub Container Registry](https://ghcr.io/oorabona/wordpress)
- [Source Code](https://github.com/oorabona/docker-containers/tree/master/wordpress)
- [Base PHP Image](https://github.com/oorabona/docker-containers/tree/master/php)
- [WP-CLI Documentation](https://wp-cli.org/)
- [WordPress Documentation](https://wordpress.org/documentation/)
