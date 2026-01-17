# PHP Development Container

A comprehensive PHP development container with Composer integration, designed for modern PHP applications. Built on the official Composer image for optimal dependency management.

## Features

- **Composer Integration**: Built on official Composer image
- **Multi-PHP Support**: Configurable PHP versions
- **Development Tools**: Pre-configured for PHP development
- **Healthcheck**: Built-in health monitoring
- **Volume Support**: Easy code mounting and development

## Usage

### With Docker Compose

```yaml
version: '3.8'
services:
  php-app:
    build: .
    ports:
      - "8000:8000"
    volumes:
      - ./src:/app
      - composer-cache:/tmp/composer-cache
    working_dir: /app
    command: php -S 0.0.0.0:8000
volumes:
  composer-cache:
```

### Direct Docker Run

```bash
# Development server
docker run -d \
  --name php-dev \
  -p 8000:8000 \
  -v $(pwd):/app \
  -w /app \
  oorabona/php \
  php -S 0.0.0.0:8000

# Composer operations
docker run --rm \
  -v $(pwd):/app \
  -w /app \
  oorabona/php \
  composer install
```

## Development Workflow

### Install Dependencies

```bash
# Using docker-compose
docker-compose run --rm php composer install

# Using docker directly
docker run --rm -v $(pwd):/app -w /app oorabona/php composer install
```

### Run Development Server

```bash
# Using docker-compose
docker-compose up

# Using docker directly
docker run -p 8000:8000 -v $(pwd):/app -w /app oorabona/php php -S 0.0.0.0:8000
```

### Execute PHP Scripts

```bash
# Run PHP scripts
docker-compose run --rm php php script.php

# Interactive PHP
docker-compose run --rm php php -a
```

## Configuration

### Environment Variables

- `PHP_VERSION` - PHP version (controlled by base image)
- `COMPOSER_CACHE_DIR` - Composer cache directory
- `APP_ENV` - Application environment (development/production)

### Volumes

- `/app` - Application code directory
- `/tmp/composer-cache` - Composer cache for faster builds

## Common Use Cases

1. **Laravel/Symfony Development**: Full-featured PHP frameworks
2. **API Development**: REST/GraphQL API backends
3. **Package Development**: Composer package creation
4. **Legacy Application**: Modernizing older PHP applications
5. **Testing Environment**: Isolated testing environment

## Health Check

The container includes a built-in health check that verifies PHP is running correctly:

```bash
# Check container health
docker inspect --format='{{.State.Health.Status}}' php-container
```

## Building

```bash
cd php
docker-compose build

# Or directly
docker build -t php-dev .
```

## Version Management

This container uses automated version detection:

```bash
./version.sh          # Current version
./version.sh latest    # Latest available version
```

## Best Practices

- Use Composer for dependency management
- Mount your code as volumes during development
- Use environment variables for configuration
- Leverage PHP-FPM for production deployments
- Keep composer.lock in version control

## Performance Tips

- Use Composer's optimize-autoloader in production
- Enable OPcache for better performance
- Use volume mounts for faster development cycles
- Consider using PHP-FPM + Nginx for production

## Security

### Base Security
- **Multi-stage build**: Build dependencies removed from final image
- **Alpine-based**: Minimal attack surface
- **Non-root by default**: Runs as `nobody` user

### Runtime Hardening (Recommended)

```bash
# Secure runtime configuration
docker run --rm \
  --read-only \
  --tmpfs /tmp \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  -v $(pwd):/app:ro \
  oorabona/php php script.php
```

### Docker Compose Security Template

```yaml
services:
  php:
    image: ghcr.io/oorabona/php:latest
    read_only: true
    tmpfs:
      - /tmp
      - /run
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    volumes:
      - ./src:/app:ro
      - composer-cache:/home/nobody/.composer/cache
    user: "nobody:nobody"

volumes:
  composer-cache:
```

### PHP-FPM Security
When using PHP-FPM in production:
- Use unix sockets instead of TCP when possible
- Configure `pm.max_children` appropriately
- Enable `open_basedir` restrictions
- Disable dangerous functions in `php.ini`
