# Jekyll Static Site Generator
# Lightweight container for building and serving Jekyll sites
ARG RUBY_VERSION
ARG ALPINE_VERSION
ARG BASE_IMAGE

FROM ${BASE_IMAGE}:${RUBY_VERSION}-alpine${ALPINE_VERSION}

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

# Create working directory
# Note: Running as root for compatibility with mounted volumes
# For production, consider using --user flag with matching UID
WORKDIR /site

# Default: serve with live reload
EXPOSE 4000 35729

ENTRYPOINT ["jekyll"]
CMD ["serve", "--host", "0.0.0.0", "--livereload"]
