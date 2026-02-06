# Jekyll

Lightweight Alpine-based container for building and serving Jekyll static sites with live reload support.

[![Docker Hub](https://img.shields.io/docker/v/oorabona/jekyll?sort=semver&label=Docker%20Hub)](https://hub.docker.com/r/oorabona/jekyll)
[![GHCR](https://img.shields.io/badge/GHCR-oorabona%2Fjekyll-blue)](https://ghcr.io/oorabona/jekyll)
[![Build](https://github.com/oorabona/docker-containers/actions/workflows/auto-build.yaml/badge.svg)](https://github.com/oorabona/docker-containers/actions/workflows/auto-build.yaml)

## Quick Start

### Docker Run

```bash
# Serve a site with live reload
docker run --rm -it \
  -v "$(pwd):/site" \
  -p 4000:4000 \
  -p 35729:35729 \
  ghcr.io/oorabona/jekyll:latest

# Build only (no server)
docker run --rm \
  -v "$(pwd):/site" \
  ghcr.io/oorabona/jekyll:latest \
  build

# Build to custom destination
docker run --rm \
  -v "$(pwd):/site" \
  ghcr.io/oorabona/jekyll:latest \
  build --destination /site/public
```

### Docker Compose

```yaml
services:
  jekyll:
    image: ghcr.io/oorabona/jekyll:latest
    ports:
      - "4000:4000"
      - "35729:35729"
    volumes:
      - ./site:/site
    command: ["serve", "--host", "0.0.0.0", "--livereload", "--force_polling"]
```

Then run:
```bash
docker compose up
```

Site available at: http://localhost:4000

## Features

- **Ruby 3.3** on Alpine Linux (minimal footprint)
- **Jekyll 4.4.1** with live reload
- **Bundler** for dependency management
- **Node.js** for JavaScript processing
- **Pre-installed plugins:**
  - `jekyll-feed` - RSS/Atom feed generation
  - `jekyll-seo-tag` - SEO optimization meta tags
  - `jekyll-sitemap` - XML sitemap generation
- **WebRick server** included
- **Git support** for themes and plugins

## Build Arguments

All dependency versions are pinned for reproducible builds:

| Argument | Default | Description |
|----------|---------|-------------|
| `RUBY_VERSION` | `3.3` | Ruby major version |
| `ALPINE_VERSION` | `3.21` | Alpine Linux version |
| `JEKYLL_VERSION` | `4.4.1` | Jekyll core version |
| `BUNDLER_VERSION` | `4.0.6` | Bundler dependency manager |
| `WEBRICK_VERSION` | `1.9.2` | WebRick HTTP server |
| `JEKYLL_FEED_VERSION` | `0.17.0` | RSS/Atom feed plugin |
| `JEKYLL_SEO_TAG_VERSION` | `2.8.0` | SEO meta tags plugin |
| `JEKYLL_SITEMAP_VERSION` | `1.4.0` | Sitemap generation plugin |

## Ports

| Port | Purpose |
|------|---------|
| `4000` | Jekyll development server |
| `35729` | LiveReload websocket |

## Volumes

Mount your Jekyll site directory to `/site`:

```bash
-v "$(pwd):/site"
```

### Directory Structure

```
your-site/
├── _config.yml          # Jekyll configuration
├── _posts/              # Blog posts
├── _layouts/            # HTML templates
├── _includes/           # Reusable components
├── assets/              # CSS, JS, images
├── Gemfile              # Additional gem dependencies
└── _site/               # Generated output (auto-created)
```

### Using a Gemfile

If your site requires additional gems, create a `Gemfile`:

```ruby
source 'https://rubygems.org'

gem 'jekyll', '~> 4.4'
gem 'jekyll-theme-minimal'
gem 'jekyll-paginate'
```

The container will automatically run `bundle install` if it detects a `Gemfile`.

## Security

### Volume Permissions

The container runs as root by default for volume mount compatibility. For production deployments:

```bash
# Run as specific user (match host UID)
docker run --user $(id -u):$(id -g) \
  -v "$(pwd):/site" \
  ghcr.io/oorabona/jekyll:latest build
```

### Production Deployment

For serving Jekyll sites in production:

1. **Build static files locally:**
   ```bash
   docker run --rm -v "$(pwd):/site" ghcr.io/oorabona/jekyll:latest build
   ```

2. **Serve with a dedicated web server:**
   Use nginx, Apache, or a CDN to serve the `_site/` directory. The Jekyll container is intended for development only.

### Network Security

- Bind to `127.0.0.1` for local-only access:
  ```bash
  -p 127.0.0.1:4000:4000
  ```
- Never expose port `4000` to the public internet
- Use environment-specific `_config.yml` files to prevent sensitive data leaks

## Dependencies

All Ruby gem versions are pinned and monitored for updates:

| Gem | Version | Purpose |
|-----|---------|---------|
| bundler | 4.0.6 | Dependency management |
| webrick | 1.9.2 | HTTP server |
| jekyll-feed | 0.17.0 | RSS/Atom feed generation |
| jekyll-seo-tag | 2.8.0 | SEO meta tags |
| jekyll-sitemap | 1.4.0 | XML sitemap generation |

### Adding Custom Dependencies

Use a `Gemfile` in your site directory to add gems not included in the image:

```ruby
# Gemfile
source 'https://rubygems.org'

gem 'jekyll', '~> 4.4'
gem 'jekyll-theme-cayman'
gem 'jekyll-redirect-from'
gem 'jemoji'
```

The container will install these automatically on startup.

## Architecture

```
jekyll/
├── Dockerfile           # Alpine-based build
├── config.yaml          # Dependency versions
├── version.sh           # Upstream version checker
├── docker-compose.yml   # Local development setup
└── README.md            # This file
```

### Build Process

The Dockerfile uses a single-stage build:

1. Start from `ruby:{RUBY_VERSION}-alpine{ALPINE_VERSION}`
2. Install build dependencies (build-base, git, nodejs)
3. Install Jekyll and plugins at pinned versions
4. Remove build dependencies to reduce image size
5. Set working directory to `/site`
6. Configure default command: `serve --host 0.0.0.0 --livereload`

### Building Locally

```bash
# Build with default versions
./make build jekyll

# Build with specific Jekyll version
./make build jekyll 4.4.1

# Build with custom arguments
docker build \
  --build-arg JEKYLL_VERSION=4.4.0 \
  --build-arg RUBY_VERSION=3.2 \
  -t jekyll:custom .
```

## Version Management

```bash
# Check current version
cd jekyll && ./version.sh

# Check latest upstream version
cd jekyll && ./version.sh latest

# JSON output for automation
cd jekyll && ./version.sh --json
```

## Links

- **Jekyll Documentation:** https://jekyllrb.com/docs/
- **Docker Hub:** https://hub.docker.com/r/oorabona/jekyll
- **GitHub Container Registry:** https://ghcr.io/oorabona/jekyll
- **Source Repository:** https://github.com/oorabona/docker-containers
- **Issue Tracker:** https://github.com/oorabona/docker-containers/issues
