ARG VERSION=latest
ARG PHP_VERSION=fpm
FROM php:$PHP_VERSION

# install the PHP extensions we need
RUN set -ex; \
	\
	apt-get update; \
	apt-get -y dist-upgrade; \
	apt-get install -y --no-install-recommends \
		sudo \
		mysql-client \
	; \
	\
	savedAptMark="$(apt-mark showmanual)"; \
	\
	apt-get install -y --no-install-recommends \
		libjpeg-dev \
		libpng-dev \
	; \
	\
	docker-php-ext-configure gd --with-png-dir=/usr --with-jpeg-dir=/usr; \
	docker-php-ext-install gd mysqli opcache zip; \
	\
# reset apt-mark's "manual" list so that "purge --auto-remove" will remove all build dependencies
	apt-mark auto '.*' > /dev/null; \
	apt-mark manual $savedAptMark; \
	ldd "$(php -r 'echo ini_get("extension_dir");')"/*.so \
		| awk '/=>/ { print $3 }' \
		| sort -u \
		| xargs -r dpkg-query -S \
		| cut -d: -f1 \
		| sort -u \
		| xargs -rt apt-mark manual; \
	\
	apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
	rm -rf /var/lib/apt/lists/*

# set recommended PHP.ini settings
# see https://secure.php.net/manual/en/opcache.installation.php
RUN { \
		echo 'opcache.memory_consumption=128'; \
		echo 'opcache.interned_strings_buffer=8'; \
		echo 'opcache.max_accelerated_files=4000'; \
		echo 'opcache.revalidate_freq=2'; \
		echo 'opcache.fast_shutdown=1'; \
		echo 'opcache.enable_cli=1'; \
	} > /usr/local/etc/php/conf.d/opcache-recommended.ini

# Install WP CLI
RUN set -ex; \
	curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar; \
	chmod +x wp-cli.phar; \
	mv wp-cli.phar /usr/local/bin/wp; \
# 	curl -o wordpress.tar.gz -fSL "https://wordpress.org/wordpress-${WORDPRESS_VERSION}.tar.gz"; \
# 	echo "$WORDPRESS_SHA1 *wordpress.tar.gz" | sha1sum -c -; \
# # upstream tarballs include ./wordpress/ so this gives us /usr/src/wordpress
# 	tar -xzf wordpress.tar.gz -C /usr/src/; \
# 	rm wordpress.tar.gz; \
	chown -R www-data:www-data /var/www/

RUN useradd -ms /bin/bash -G sudo wordpress   	                        && \
    echo "wordpress ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

COPY *.sh /usr/local/bin/

VOLUME /var/www/
WORKDIR /var/www/

EXPOSE 9000

# Add healthcheck to verify PHP-FPM is running
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD php-fpm -t || exit 1

USER wordpress

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["php-fpm"]
