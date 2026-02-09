FROM ghcr.io/oorabona/php:latest
USER root
RUN apk add --no-cache --virtual .build-deps postgresql-dev \
    && docker-php-ext-install pdo_pgsql \
    && apk del --no-network .build-deps \
    && apk add --no-cache libpq
USER nobody
