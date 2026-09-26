# Jekyll Static Site Generator
# Lightweight container for building and serving Jekyll sites
ARG REMOTE_CR=ghcr.io/oorabona
ARG RUBY_VERSION
ARG ALPINE_VERSION

FROM ${REMOTE_CR}/library/ruby:${RUBY_VERSION}-alpine${ALPINE_VERSION}

ARG JEKYLL_VERSION
ARG BUNDLER_VERSION
ARG WEBRICK_VERSION
ARG JEKYLL_FEED_VERSION
ARG JEKYLL_SEO_TAG_VERSION
ARG JEKYLL_SITEMAP_VERSION

# Validate required build args
RUN : "${JEKYLL_VERSION:?required}" "${BUNDLER_VERSION:?required}" "${WEBRICK_VERSION:?required}" "${JEKYLL_FEED_VERSION:?required}" "${JEKYLL_SEO_TAG_VERSION:?required}" "${JEKYLL_SITEMAP_VERSION:?required}"

# Install build dependencies and Jekyll with common plugins
RUN --mount=type=cache,target=/usr/local/bundle/cache \
    apk add --no-cache \
        build-base \
        git \
        nodejs \
        npm \
    && gem install \
        jekyll:${JEKYLL_VERSION} \
        bundler:${BUNDLER_VERSION} \
        webrick:${WEBRICK_VERSION} \
        jekyll-feed:${JEKYLL_FEED_VERSION} \
        jekyll-seo-tag:${JEKYLL_SEO_TAG_VERSION} \
        jekyll-sitemap:${JEKYLL_SITEMAP_VERSION} \
    && apk del build-base \
    && rm -rf /root/.gem /root/.bundle

LABEL org.opencontainers.image.title="Jekyll" \
      org.opencontainers.image.description="Jekyll static site generator with common plugins" \
      org.opencontainers.image.source="https://github.com/oorabona/docker-containers" \
      org.opencontainers.image.vendor="oorabona" \
      org.opencontainers.image.licenses="MIT"

# Runtime contract: the default image user is jekyll (uid/gid 1000), /site is
# writable by that user, and HOME/cache state uses /tmp so an arbitrary Docker
# uid without a passwd entry can run Jekyll as well. Gems remain system-wide.
ENV HOME=/tmp \
    BUNDLE_APP_CONFIG=/tmp \
    BUNDLE_USER_HOME=/tmp \
    BUNDLE_USER_CACHE=/tmp \
    XDG_CACHE_HOME=/tmp

RUN addgroup -g 1000 -S jekyll \
    && adduser -S -D -H -u 1000 -h /tmp -s /sbin/nologin -G jekyll -g jekyll jekyll \
    && mkdir -p /site \
    && chown jekyll:jekyll /site \
    && chmod 1777 /tmp

WORKDIR /site

# Default: serve with live reload
EXPOSE 4000 35729

ENTRYPOINT ["jekyll"]
CMD ["serve", "--host", "0.0.0.0", "--livereload"]

USER jekyll
