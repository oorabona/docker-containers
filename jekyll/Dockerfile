# Jekyll Static Site Generator
# Lightweight container for building and serving Jekyll sites
ARG RUBY_VERSION=3.3
ARG ALPINE_VERSION=3.21

FROM ruby:${RUBY_VERSION}-alpine${ALPINE_VERSION}

ARG JEKYLL_VERSION=4.4.1
ARG BUNDLER_VERSION=4.0.6
ARG WEBRICK_VERSION=1.9.2
ARG JEKYLL_FEED_VERSION=0.17.0
ARG JEKYLL_SEO_TAG_VERSION=2.8.0
ARG JEKYLL_SITEMAP_VERSION=1.4.0

# Install build dependencies and Jekyll with common plugins
RUN apk add --no-cache \
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
    && rm -rf /root/.gem /root/.bundle /usr/local/bundle/cache

# Create working directory
# Note: Running as root for compatibility with mounted volumes
# For production, consider using --user flag with matching UID
WORKDIR /site

# Default: serve with live reload
EXPOSE 4000 35729

ENTRYPOINT ["jekyll"]
CMD ["serve", "--host", "0.0.0.0", "--livereload"]
