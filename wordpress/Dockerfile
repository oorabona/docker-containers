# WordPress container based on our PHP image
# All PHP extensions (gd, mysqli, opcache, zip) are already included
ARG PHP_IMAGE=ghcr.io/oorabona/php:latest
FROM ${PHP_IMAGE}

# Switch to root for installation
USER root

# Install WordPress-specific dependencies (Alpine packages)
RUN set -ex; \
    apk add --no-cache \
        sudo \
        mariadb-client \
        bash \
    ; \
    # Create wordpress user with sudo access
    adduser -D -s /bin/bash wordpress; \
    echo "wordpress ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# WordPress-specific opcache settings (override defaults if needed)
RUN { \
        echo 'opcache.memory_consumption=128'; \
        echo 'opcache.interned_strings_buffer=8'; \
        echo 'opcache.max_accelerated_files=4000'; \
        echo 'opcache.revalidate_freq=2'; \
        echo 'opcache.fast_shutdown=1'; \
        echo 'opcache.enable_cli=1'; \
    } > /usr/local/etc/php/conf.d/opcache-wordpress.ini

# Install WP-CLI
RUN set -ex; \
    curl -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar; \
    chmod +x /usr/local/bin/wp; \
    # Verify WP-CLI works
    wp --info --allow-root

# Copy entrypoint scripts
COPY *.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/*.sh

# Setup directories
RUN mkdir -p /var/www/html && chown -R wordpress:wordpress /var/www/

VOLUME /var/www/
WORKDIR /var/www/

EXPOSE 9000

# Healthcheck
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD php-fpm -t || exit 1

USER wordpress

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["php-fpm"]
