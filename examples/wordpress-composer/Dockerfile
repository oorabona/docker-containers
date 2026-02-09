# WordPress via Composer — multi-stage build
# Based on cloudrly/wordpress project structure:
#   public/wp/          WordPress core (roots/wordpress)
#   public/wp-content/  Themes & plugins (composer/installers)
#   vendor/             PHP dependencies (autoloader)

# Stage 1: Resolve Composer dependencies
FROM composer:2 AS builder

WORKDIR /app

COPY composer.json ./
RUN composer update --no-dev --optimize-autoloader --no-interaction

# Overlay project files onto Composer-generated structure
COPY public/ /app/public/
COPY wp-cli.yml /app/

# Stage 2: Runtime image
FROM ghcr.io/oorabona/php:latest

USER root

RUN set -ex; \
    apk add --no-cache sudo mariadb-client bash; \
    adduser -D -s /bin/bash wordpress; \
    echo "wordpress ALL=(ALL) NOPASSWD: /usr/local/bin/wp" > /etc/sudoers.d/wordpress; \
    chmod 440 /etc/sudoers.d/wordpress

# Install WP-CLI (for site management and testing)
ARG WPCLI_VERSION=2.12.0
RUN set -ex; \
    curl -fsSL -o /usr/local/bin/wp \
        "https://github.com/wp-cli/wp-cli/releases/download/v${WPCLI_VERSION}/wp-cli-${WPCLI_VERSION}.phar"; \
    chmod +x /usr/local/bin/wp

# Copy built application from Composer stage
COPY --from=builder /app/vendor   /var/www/vendor
COPY --from=builder /app/public   /var/www/public
COPY --from=builder /app/wp-cli.yml /var/www/

# Ensure wp-content directories exist for volumes
RUN set -ex; \
    mkdir -p /var/www/public/wp-content/uploads; \
    mkdir -p /var/www/public/wp-content/upgrade; \
    chown -R wordpress:wordpress /var/www

WORKDIR /var/www

USER wordpress

EXPOSE 9000

CMD ["php-fpm"]
