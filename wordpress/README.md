# WordPress Container

A production-ready WordPress container with PHP optimization, security enhancements, and flexible configuration options. Built on official PHP images with WordPress-specific optimizations.

## Features

- **Multi-PHP Support**: Configurable PHP versions for compatibility
- **Performance Optimized**: OPcache, memory optimization, and caching
- **Security Hardened**: Security best practices and regular updates
- **Development Friendly**: Easy local development setup
- **Production Ready**: Optimized for production deployments

## Usage

### With Docker Compose

```yaml
version: '3.8'
services:
  wordpress:
    build:
      context: .
      args:
        PHP_VERSION: 8.1-apache
    environment:
      - WORDPRESS_DB_HOST=db
      - WORDPRESS_DB_NAME=wordpress
      - WORDPRESS_DB_USER=wordpress
      - WORDPRESS_DB_PASSWORD=password
    ports:
      - "8080:80"
    volumes:
      - wordpress_data:/var/www/html
      - ./themes:/var/www/html/wp-content/themes
      - ./plugins:/var/www/html/wp-content/plugins
    depends_on:
      - db

  db:
    image: mysql:8.0
    environment:
      - MYSQL_DATABASE=wordpress
      - MYSQL_USER=wordpress
      - MYSQL_PASSWORD=password
      - MYSQL_ROOT_PASSWORD=rootpassword
    volumes:
      - db_data:/var/lib/mysql

volumes:
  wordpress_data:
  db_data:
```

### Direct Docker Run

```bash
# Start MySQL first
docker run -d \
  --name wordpress-db \
  -e MYSQL_DATABASE=wordpress \
  -e MYSQL_USER=wordpress \
  -e MYSQL_PASSWORD=password \
  -e MYSQL_ROOT_PASSWORD=rootpassword \
  mysql:8.0

# Start WordPress
docker run -d \
  --name wordpress-site \
  --link wordpress-db:mysql \
  -p 8080:80 \
  -e WORDPRESS_DB_HOST=mysql \
  -e WORDPRESS_DB_NAME=wordpress \
  -e WORDPRESS_DB_USER=wordpress \
  -e WORDPRESS_DB_PASSWORD=password \
  oorabona/wordpress
```

## Configuration

### Environment Variables

- `WORDPRESS_DB_HOST` - Database hostname
- `WORDPRESS_DB_NAME` - Database name
- `WORDPRESS_DB_USER` - Database username
- `WORDPRESS_DB_PASSWORD` - Database password
- `WORDPRESS_TABLE_PREFIX` - Database table prefix (default: wp_)
- `WORDPRESS_DEBUG` - Enable debug mode (default: false)

### Build Arguments

- `PHP_VERSION` - PHP version (default: 8.1-apache)

## Development Workflow

### Local Development

```bash
# Start services
docker-compose up -d

# Access WordPress
open http://localhost:8080

# View logs
docker-compose logs -f wordpress
```

### Plugin/Theme Development

```bash
# Mount local theme directory
volumes:
  - ./my-theme:/var/www/html/wp-content/themes/my-theme
  - ./my-plugin:/var/www/html/wp-content/plugins/my-plugin
```

### WP-CLI Access

```bash
# Execute WP-CLI commands
docker-compose exec wordpress wp --info

# Install plugins
docker-compose exec wordpress wp plugin install contact-form-7 --activate

# Update WordPress
docker-compose exec wordpress wp core update
```

## Performance Optimizations

### PHP Configuration

The container includes optimized PHP settings:

```ini
; OPcache settings
opcache.enable=1
opcache.memory_consumption=256
opcache.max_accelerated_files=20000
opcache.revalidate_freq=2

; Memory settings
memory_limit=512M
upload_max_filesize=64M
post_max_size=64M
max_execution_time=300
```

### Caching

Consider adding caching plugins and configurations:

```bash
# Object caching with Redis
docker-compose exec wordpress wp plugin install redis-cache --activate
docker-compose exec wordpress wp redis enable
```

## Security Features

- Regular security updates through automated rebuilds
- Proper file permissions
- Disabled file editing in admin
- Security headers configuration
- Non-root process execution where possible

## Backup and Maintenance

### Database Backup

```bash
# Backup database
docker-compose exec db mysqldump -u wordpress -ppassword wordpress > backup.sql

# Restore database
docker-compose exec -T db mysql -u wordpress -ppassword wordpress < backup.sql
```

### File Backup

```bash
# Backup WordPress files
docker-compose exec wordpress tar -czf /tmp/wp-backup.tar.gz /var/www/html

# Extract backup
docker cp wordpress_container:/tmp/wp-backup.tar.gz ./wp-backup.tar.gz
```

## Building

```bash
cd wordpress
docker-compose build

# Build with specific PHP version
docker build --build-arg PHP_VERSION=8.2-apache -t wordpress:php8.2 .
```

## Version Management

This container tracks WordPress core versions:

```bash
./version.sh          # Current WordPress version
./version.sh latest    # Latest available version
```

## Production Deployment

### Recommended Setup

- Use managed database service (RDS, Cloud SQL)
- Implement proper backup strategy
- Configure SSL/TLS termination
- Use CDN for static assets
- Implement monitoring and logging
- Regular security updates

### Environment Variables for Production

```bash
WORDPRESS_CONFIG_EXTRA="
define('WP_DEBUG', false);
define('DISALLOW_FILE_EDIT', true);
define('AUTOMATIC_UPDATER_DISABLED', true);
define('WP_AUTO_UPDATE_CORE', false);
"
```
