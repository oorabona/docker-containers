# Jekyll Static Site Generator

Lightweight Alpine-based Jekyll container for building and serving static sites.

## Quick Start

### Serve a Jekyll site with live reload

```bash
docker run --rm -it \
  -v "$(pwd):/site" \
  -p 4000:4000 \
  -p 35729:35729 \
  ghcr.io/oorabona/jekyll:latest
```

Then open http://localhost:4000

### Build a Jekyll site

```bash
docker run --rm \
  -v "$(pwd):/site" \
  ghcr.io/oorabona/jekyll:latest \
  build
```

Output will be in `_site/` directory.

### Build with custom destination

```bash
docker run --rm \
  -v "$(pwd):/site" \
  ghcr.io/oorabona/jekyll:latest \
  build --destination /site/public
```

## Usage with this repository

To preview the dashboard locally:

```bash
cd docs/site
docker run --rm -it \
  -v "$(pwd):/site" \
  -p 4000:4000 \
  -p 35729:35729 \
  ghcr.io/oorabona/jekyll:latest
```

## Features

- **Ruby 3.3** on Alpine Linux (minimal footprint)
- **Jekyll 4.3.x** with Bundler
- **Live reload** enabled by default
- **Non-root user** for security
- **WebRick** server included

## Environment

| Component | Version |
|-----------|---------|
| Base | Alpine Linux 3.21 |
| Ruby | 3.3 |
| Jekyll | 4.3.4+ |

## Building locally

```bash
./make build jekyll
```

## Exposed ports

| Port | Purpose |
|------|---------|
| 4000 | Jekyll server |
| 35729 | LiveReload |
