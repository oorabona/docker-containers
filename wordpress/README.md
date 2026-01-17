# WordPress Container

Production-ready WordPress with PHP optimization, security hardening, and flexible configuration.

## Features

- **Multi-PHP Support** - Configurable PHP versions
- **Performance Optimized** - OPcache, caching, memory optimization  
- **Security Hardened** - Best practices and regular updates
- **Development Friendly** - Easy local setup
- **Production Ready** - Optimized for deployment

## Quick Start

### Docker Compose
```yaml
services:
  wordpress:
    image: oorabona/wordpress
    environment:
      WORDPRESS_DB_HOST: db
      WORDPRESS_DB_NAME: wordpress
      WORDPRESS_DB_USER: wordpress
      WORDPRESS_DB_PASSWORD: password
    ports:
      - "8080:80"
    volumes:
      - wordpress_data:/var/www/html
    depends_on:
      - db

  db:
    image: mysql:8.0
    environment:
      MYSQL_DATABASE: wordpress
      MYSQL_USER: wordpress
      MYSQL_PASSWORD: password
      MYSQL_ROOT_PASSWORD: rootpassword
    volumes:
      - db_data:/var/lib/mysql

volumes:
  wordpress_data:
  db_data:
```

### Direct Docker
```bash
# Start database
docker run -d --name wordpress-db \
  -e MYSQL_DATABASE=wordpress \
  -e MYSQL_USER=wordpress \
  -e MYSQL_PASSWORD=password \
  mysql:8.0

# Start WordPress
docker run -d --name wordpress-site \
  --link wordpress-db:mysql \
  -p 8080:80 \
  -e WORDPRESS_DB_HOST=mysql \
  -e WORDPRESS_DB_NAME=wordpress \
  oorabona/wordpress
```

## Configuration

### Environment Variables
- `WORDPRESS_DB_HOST` - Database hostname
- `WORDPRESS_DB_NAME` - Database name  
- `WORDPRESS_DB_USER` - Database username
- `WORDPRESS_DB_PASSWORD` - Database password
- `WORDPRESS_TABLE_PREFIX` - Table prefix (default: wp_)
- `WORDPRESS_DEBUG` - Enable debug mode (default: false)

### Build Arguments
- `PHP_VERSION` - PHP version (default: 8.1-apache)

## Development

### Local Setup
```bash
# Start services
docker-compose up -d

# Access site
open http://localhost:8080

# View logs
docker-compose logs -f wordpress
```

### WP-CLI Commands
```bash
# Execute WP-CLI
docker-compose exec wordpress wp --info

# Install plugins
docker-compose exec wordpress wp plugin install contact-form-7 --activate

# Update core
docker-compose exec wordpress wp core update
```

### Plugin/Theme Development
```yaml
volumes:
  - ./my-theme:/var/www/html/wp-content/themes/my-theme
  - ./my-plugin:/var/www/html/wp-content/plugins/my-plugin
```

## Performance & Security

### PHP Optimizations
- OPcache enabled with optimal settings
- Memory limit: 512M
- Upload limit: 64M  
- Execution time: 300s

### Security Features
- Regular automated updates
- Proper file permissions
- Disabled admin file editing
- Security headers configuration

## Security

### Base Security
- Based on our optimized PHP image (Alpine-based)
- Minimal attack surface with carefully selected packages
- Regular security updates through automated rebuilds

### User Security
- **Non-root by default**: Container runs as `wordpress` user
- **Limited sudo**: sudo access restricted to `/usr/local/bin/wp` only (not full root)
- **Proper ownership**: WordPress files owned by wordpress user

### Runtime Hardening (Recommended)

```bash
# Secure runtime configuration
docker run -d \
  --name wordpress \
  --read-only \
  --tmpfs /tmp \
  --tmpfs /run \
  --cap-drop ALL \
  --cap-add CHOWN \
  --cap-add SETGID \
  --cap-add SETUID \
  --security-opt no-new-privileges:true \
  -v wordpress_data:/var/www/html \
  wordpress
```

### Docker Compose Security Template

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
      # Use secrets for production, never hardcode
      WORDPRESS_DB_HOST: db
      WORDPRESS_DB_NAME: ${WORDPRESS_DB_NAME}
      WORDPRESS_DB_USER: ${WORDPRESS_DB_USER}
      WORDPRESS_DB_PASSWORD: ${WORDPRESS_DB_PASSWORD}

  db:
    image: mysql:8.0
    read_only: true
    tmpfs:
      - /tmp
      - /run/mysqld
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETGID
      - SETUID
      - DAC_OVERRIDE
    security_opt:
      - no-new-privileges:true
    volumes:
      - db_data:/var/lib/mysql
    environment:
      # Use secrets for production, never hardcode
      MYSQL_DATABASE: ${WORDPRESS_DB_NAME}
      MYSQL_USER: ${WORDPRESS_DB_USER}
      MYSQL_PASSWORD: ${WORDPRESS_DB_PASSWORD}
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}

volumes:
  wordpress_data:
  db_data:
```

### Backup & Maintenance
```bash
# Database backup
docker-compose exec db mysqldump -u wordpress -ppassword wordpress > backup.sql

# File backup
docker-compose exec wordpress tar -czf /tmp/wp-backup.tar.gz /var/www/html
```

## Building

```bash
# Build container
./make build wordpress

# Build with specific PHP version
docker build --build-arg PHP_VERSION=8.2-apache -t wordpress:php8.2 .

# Check versions
./version.sh current
./version.sh latest
```

---

**Last Updated**: July 2025
