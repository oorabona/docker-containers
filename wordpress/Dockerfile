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
    # Create wordpress user with limited sudo access (wp-cli only)
    adduser -D -s /bin/bash wordpress; \
    echo "wordpress ALL=(ALL) NOPASSWD: /usr/local/bin/wp" > /etc/sudoers.d/wordpress; \
    chmod 440 /etc/sudoers.d/wordpress

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
# Note: WP-CLI's bundled php-cli-tools triggers PHP 8.5 deprecation warnings
# (upstream: github.com/wp-cli/php-cli-tools/issues/162).
# Suppress E_DEPRECATED globally — standard practice for WordPress production
# (WP core and plugins routinely emit deprecation notices).
ARG WPCLI_VERSION
RUN set -ex; \
    curl -fsSL -o /usr/local/bin/wp https://github.com/wp-cli/wp-cli/releases/download/v${WPCLI_VERSION}/wp-cli-${WPCLI_VERSION}.phar; \
    chmod +x /usr/local/bin/wp; \
    # Suppress deprecation warnings for CLI only (E_ALL & ~E_DEPRECATED = 22527)
    echo 'error_reporting = E_ALL & ~E_DEPRECATED' > /usr/local/etc/php/conf.d/cli-no-deprecated.ini; \
    # Verify WP-CLI works
    wp --info --allow-root

# Copy entrypoint scripts
COPY *.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/*.sh

# Setup directories and download WordPress core + SQLite drop-in
ARG VERSION
ARG SQLITE_PLUGIN_VERSION
RUN set -ex; \
    mkdir -p /var/www/html; \
    WP_VERSION="${VERSION%%-*}"; \
    wp core download --path=/var/www/html --version="$WP_VERSION" --allow-root; \
    # Pre-install SQLite Database Integration plugin (used when WP_DB_TYPE=sqlite)
    curl -fsSL -o /tmp/sqlite-plugin.zip \
        "https://downloads.wordpress.org/plugin/sqlite-database-integration.${SQLITE_PLUGIN_VERSION}.zip"; \
    unzip -qo /tmp/sqlite-plugin.zip -d /var/www/html/wp-content/plugins/; \
    rm /tmp/sqlite-plugin.zip; \
    chown -R wordpress:wordpress /var/www/

WORKDIR /var/www/html

EXPOSE 9000

# Healthcheck
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD php-fpm -t || exit 1

USER wordpress

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["php-fpm"]
