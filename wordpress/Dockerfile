# WordPress container based on our PHP image.
# Every PHP extension is inherited from the base image; none is installed here.
# test.sh asserts the ones WordPress actually needs — mysqli, json, curl, gd,
# zip, apcu and OPcache — so that list is checked rather than merely claimed.
# OPcache is statically built in the base, so `php -m` spells it `Zend OPcache`
# and never `opcache`, which is what made it look absent in #1017.
ARG REMOTE_CR=ghcr.io/oorabona
ARG PHP_TAG
FROM ${REMOTE_CR}/php:${PHP_TAG}

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

# No opcache-wordpress.ini: the base image's conf.d/php.ini sets every key this
# file used to set, and PHP reads conf.d alphabetically — "php.ini" after
# "opcache-wordpress.ini" — so none of it ever applied. Verified on the published
# image: it wrote memory_consumption=128 and the runtime reported 512.
#
# Nothing is lost by dropping it. The base is more generous everywhere the two
# disagreed (512MB against 128, 20000 accelerated files against 4000) and
# opcache.fast_shutdown, the one setting unique in spirit, has been a no-op since
# PHP 7.2. If WordPress ever does need to override the base, the file has to sort
# after php.ini to have any effect at all.

# Install WP-CLI. Its bundled react/promise emits a PHP 8.5 deprecation warning
# on every invocation. The wrapper is a process-level suppression for WP-CLI,
# not a production error-reporting policy: PHP-FPM keeps the base configuration.
# The base policy is E_ALL & ~E_NOTICE; preserve that decision and subtract only
# E_DEPRECATED rather than replacing the complete error-reporting mask.
#
# One thing this costs: `php /usr/local/bin/wp` stops working, that path being a
# shell script now. Callers use `wp`, which is unaffected.
#
# `wp cli update` is unchanged by the wrapper and worth stating precisely, since
# it is easy to get backwards: WP-CLI replaces realpath($_SERVER['argv'][0]),
# which through the wrapper is the phar and not the wrapper (measured). So the
# pinned phar stays as replaceable as it was before, no more and no less, and
# for the same reason as before — `wordpress` may run it under passwordless
# sudo. Run the container read-only if that matters to you; nothing about this
# change makes it easier or harder.
#
# When a supported WP-CLI release stops emitting the warning, remove the wrapper
# and move the phar back to /usr/local/bin/wp.
ARG WPCLI_VERSION

# Validate required build args
RUN : "${WPCLI_VERSION:?required}"

# The phar is fetched over TLS and then executed as root two lines later, so TLS
# is authenticating the CDN rather than the artifact. Upstream publishes a
# SHA-512 beside every release asset; check it before the file is ever run, and
# fail the build if it does not match.
#
# Be clear about what that buys, because it is not everything: the digest comes
# from the SAME release authority as the phar, so it catches a truncated or
# corrupted download and an attacker who can alter one file but not the other —
# and it does NOT survive a compromise of the release itself, which could serve
# a matching pair. Closing that needs the signature upstream also publishes
# (.asc) verified against a fingerprint pinned in this repository, the way #918
# does for EasyRSA. Tracked in #1025.
RUN set -ex; \
    rm -f /usr/local/etc/php/conf.d/cli-no-deprecated.ini; \
    curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 30 -o /usr/local/bin/wp-cli.phar https://github.com/wp-cli/wp-cli/releases/download/v${WPCLI_VERSION}/wp-cli-${WPCLI_VERSION}.phar; \
    curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 30 -o /tmp/wp-cli.phar.sha512 https://github.com/wp-cli/wp-cli/releases/download/v${WPCLI_VERSION}/wp-cli-${WPCLI_VERSION}.phar.sha512; \
    expected_sha512="$(cat /tmp/wp-cli.phar.sha512)"; \
    case "$expected_sha512" in \
        *[!0-9a-fA-F]* | "") echo "wp-cli sha512 asset is not a hex digest" >&2; exit 1 ;; \
    esac; \
    echo "${expected_sha512}  /usr/local/bin/wp-cli.phar" | sha512sum -c -; \
    rm -f /tmp/wp-cli.phar.sha512; \
    printf '%s\n' \
        '#!/bin/sh' \
        'exec /usr/local/bin/php -d "error_reporting=E_ALL & ~E_NOTICE & ~E_DEPRECATED" \' \
        '    /usr/local/bin/wp-cli.phar "$@"' \
        > /usr/local/bin/wp; \
    chown root:root /usr/local/bin/wp /usr/local/bin/wp-cli.phar; \
    chmod 755 /usr/local/bin/wp /usr/local/bin/wp-cli.phar; \
    # Verify WP-CLI works through the wrapper
    /usr/local/bin/wp --info --allow-root

# Copy entrypoint scripts
# Named rather than globbed. This directory also holds test.sh, which the e2e
# harness runs from the host against a running container, and version.sh, which
# the build system runs to discover the upstream release. Neither has a role
# inside the image, and the glob shipped both — putting test code in a published
# image, and making every edit to either one rebuild that image.
COPY --chmod=755 docker-entrypoint.sh /usr/local/bin/

# Setup directories and download WordPress core + SQLite drop-in
ARG VERSION
ARG SQLITE_PLUGIN_VERSION

# Validate required build args
RUN : "${VERSION:?required}" "${SQLITE_PLUGIN_VERSION:?required}"

RUN set -ex; \
    mkdir -p /var/www/html; \
    WP_VERSION="${VERSION%%-*}"; \
    wp core download --path=/var/www/html --version="$WP_VERSION" --allow-root; \
    # Pre-install SQLite Database Integration plugin (used when WP_DB_TYPE=sqlite)
    curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 30 -o /tmp/sqlite-plugin.zip \
        "https://downloads.wordpress.org/plugin/sqlite-database-integration.${SQLITE_PLUGIN_VERSION}.zip"; \
    unzip -qo /tmp/sqlite-plugin.zip -d /var/www/html/wp-content/plugins/; \
    rm /tmp/sqlite-plugin.zip; \
    chown -R wordpress:wordpress /var/www/

LABEL org.opencontainers.image.title="WordPress" \
      org.opencontainers.image.description="WordPress with PHP-FPM, WP-CLI, and SQLite support" \
      org.opencontainers.image.source="https://github.com/oorabona/docker-containers" \
      org.opencontainers.image.vendor="oorabona" \
      org.opencontainers.image.licenses="MIT"

WORKDIR /var/www/html

EXPOSE 9000

# Healthcheck
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD php-fpm -t || exit 1

USER wordpress

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["php-fpm"]
