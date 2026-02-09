ARG VERSION
ARG COMPOSER_VERSION
FROM composer:${COMPOSER_VERSION} AS composer
FROM php:${VERSION} AS php

COPY --from=composer /usr/bin/composer /usr/bin/composer

ARG APCU_VERSION

RUN set -ex \
    && apk add --update libzip freetype libpng libjpeg-turbo git shadow \
    && apk add --update --no-cache --virtual .build-deps \
        $PHPIZE_DEPS \
        icu-dev \
        libzip-dev \
		freetype-dev \
		libjpeg-turbo-dev \
		libpng-dev \
	&& docker-php-ext-configure gd --with-freetype --with-jpeg \
	&& docker-php-ext-install -j$(nproc) gd mysqli opcache zip \
	&& pecl install apcu-${APCU_VERSION} && docker-php-ext-enable apcu \
# - Detect Runtime Dependencies of the installed extensions. \
# - src: https://github.com/docker-library/wordpress/blob/master/latest/php8.0/fpm-alpine/Dockerfile \
    && out="$(php -r 'exit(0);')"; \
		[ -z "$out" ]; err="$(php -r 'exit(0);' 3>&1 1>&2 2>&3)"; \
		[ -z "$err" ]; extDir="$(php -r 'echo ini_get("extension_dir");')"; \
		[ -d "$extDir" ]; \
		runDeps="$( \
			scanelf --needed --nobanner --format '%n#p' --recursive "$extDir" \
				| tr ',' '\n' | sort -u | awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
		)"; \
		# Save Runtime Deps in a virtual deps
		apk add --no-network --virtual .php-extensions-rundeps $runDeps; \
		# Uninstall Everything we Installed (minus the runtime Deps)
		apk del --no-network .build-deps; \
		# check for output like "PHP Warning:  PHP Startup: Unable to load dynamic library 'foo' (tried: ...)
		err="$(php --version 3>&1 1>&2 2>&3)"; 	[ -z "$err" ] \
	&& rm -rf /var/cache/apk/* /tmp/* /var/tmp/* \
	&& rm -f /usr/local/etc/php-fpm.d/*

# PHP Config
# see https://secure.php.net/manual/en/opcache.installation.php
COPY conf/php.ini	$PHP_INI_DIR/conf.d/

# PHP-FPM config
COPY conf/fpm.conf  /usr/local/etc/php-fpm.d/
# Some helper scripts
COPY scripts/* /usr/local/bin/

# Common PHP Frameworks Env Variables
ENV APP_ENV=prod
ENV APP_DEBUG=0
ENV APP_BASE_PATH=/var/www/app/

# A Json Object with remote repository token to clone private Repos with composer
# Reference: https://getcomposer.org/doc/03-cli.md#composer-auth
# Note: This is for build-time use only, not recommended for sensitive data in production
ARG COMPOSER_AUTH=""
ENV COMPOSER_AUTH=${COMPOSER_AUTH}
ENV COMPOSER_CACHE_DIR=/var/www/.composer/

# We do not want the www-data user anymore, we can stick with the default user nobody
RUN deluser --remove-home www-data \
    && mkdir -p ${COMPOSER_CACHE_DIR} /var/log/shared && chown -R nobody:nobody /var/www/ /var/log/shared \
	&& mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini" \
	&& chmod +x /usr/local/bin/* \
	&& chown -R nobody:nobody /usr/local/etc/php-fpm.d \
	&& usermod -d /var/www/ nobody

# Validate FPM config (must use the non-root user)
USER nobody
RUN php-fpm -t

HEALTHCHECK CMD ["healthcheck-fpm"]

ENTRYPOINT ["entrypoint-fpm"]

WORKDIR /var/www/

EXPOSE 9000

CMD ["php-fpm"]