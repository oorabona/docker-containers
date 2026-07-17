# OpenResty

High-performance web platform combining Nginx with LuaJIT for dynamic, programmable request handling.

[![Docker Hub](https://img.shields.io/docker/v/oorabona/openresty?sort=semver&label=Docker%20Hub)](https://hub.docker.com/r/oorabona/openresty)
[![GHCR](https://img.shields.io/badge/GHCR-oorabona%2Fopenresty-blue)](https://ghcr.io/oorabona/openresty)
[![Build](https://github.com/oorabona/docker-containers/actions/workflows/auto-build.yaml/badge.svg)](https://github.com/oorabona/docker-containers/actions/workflows/auto-build.yaml)

## Verify this image

Every build ships a Sigstore-signed SBOM and a full Trivy scan — verify them yourself, no login required:

```bash
gh attestation verify oci://ghcr.io/oorabona/openresty:latest --owner oorabona
```

Full walkthrough (SBOM payload, Trivy findings, multi-arch manifest inspection, upstream dependency tracking) → <https://oorabona.github.io/docker-containers/verify-images/>

## Quick Start

```bash
# Pull from GitHub Container Registry
docker pull ghcr.io/oorabona/openresty:latest

# Pull from Docker Hub
docker pull oorabona/openresty:latest

# Run with custom configuration
docker run -d \
  --name openresty \
  -p 8080:8080 \
  -p 8443:8443 \
  -v ./conf.d:/usr/local/openresty/nginx/conf/conf.d:ro \
  -v ./lua:/usr/local/openresty/lualib/app:ro \
  ghcr.io/oorabona/openresty:latest
```

## Features

- **Nginx + LuaJIT**: Full Nginx functionality with embedded LuaJIT for dynamic scripting
- **Built from Source**: Compiled with optimized configuration, not based on official image
- **Optional Proxy Connect**: Includes ngx_http_proxy_connect_module for forward proxy support
- **LuaRocks**: Lua package manager included for easy module installation
- **Extensive Modules**: Pre-compiled with HTTP/2, SSL, streaming, and dynamic modules
- **Production Ready**: Includes healthcheck, non-root worker processes, and security hardening

## Usage

### Docker Compose

```yaml
services:
  openresty:
    image: ghcr.io/oorabona/openresty:latest
    ports:
      - "8080:8080"
      - "8443:8443"
    volumes:
      - ./conf.d:/usr/local/openresty/nginx/conf/conf.d:ro
      - ./lua:/usr/local/openresty/lualib/app:ro
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
```

### Basic Lua Example

Place your nginx configuration in `conf.d/`:

```nginx
# conf.d/default.conf
server {
    listen 8080;
    server_name localhost;

    location / {
        content_by_lua_block {
            ngx.say("Hello from OpenResty + Lua!")
        }
    }

    location /api {
        access_by_lua_file /usr/local/openresty/lualib/app/auth.lua;
        proxy_pass http://backend;
    }
}
```

### Custom Lua Modules

Create Lua modules in the `lua/` directory:

```lua
-- lua/auth.lua
local jwt = require "resty.jwt"

local token = ngx.var.http_authorization
if not token then
    ngx.status = 401
    ngx.say("Missing Authorization header")
    return ngx.exit(401)
end

-- Validate JWT token
local jwt_obj = jwt:verify("secret-key", token)
if not jwt_obj.verified then
    ngx.status = 403
    ngx.say("Invalid token")
    return ngx.exit(403)
end
```

### Installing Lua Packages

The image runs as the non-root `nginx` user, which can't write the system
LuaRocks tree under `/usr/local`. Install packages **at build time in a
derived Dockerfile** — reset to `USER root` first, since the base image's
final `USER nginx` otherwise carries into your `RUN` steps:

```dockerfile
FROM ghcr.io/oorabona/openresty:latest
USER root
RUN luarocks install lua-resty-jwt   # into the system tree, on OpenResty's lua_package_path
USER nginx
```

Runtime `luarocks install --local` also works, but it installs into the
nginx user's home tree, which is not on OpenResty's default
`lua_package_path` — you'd have to extend `lua_package_path` /
`lua_package_cpath` in your nginx config for `require` to find it. Build-time
install into the system tree is the simpler path.

## Build Arguments

| Argument | Description | Default |
|----------|-------------|---------|
| `VERSION` | OpenResty version | latest |
| `RESTY_IMAGE_BASE` | Base image name | alpine |
| `RESTY_IMAGE_TAG` | Base image tag | latest |
| `RESTY_VERSION` | OpenResty version (same as VERSION) | ${VERSION} |
| `RESTY_OPENSSL_VERSION` | OpenSSL version (3.5 LTS) | 3.5.6 |
| `RESTY_OPENSSL_PATCH_VERSION` | OpenResty OpenSSL patch version | 3.5.5 |
| `RESTY_PCRE_VERSION` | PCRE2 version | 10.47 |
| `RESTY_PCRE_SHA256` | SHA256 digest for the PCRE2 .tar.gz (must match `RESTY_PCRE_VERSION`; update both together) | (see config.yaml) |
| `RESTY_J` | Parallel build jobs | 4 |
| `RESTY_CONFIG_OPTIONS` | Nginx build options | (see Dockerfile) |
| `RESTY_CONFIG_OPTIONS_MORE` | Additional configure options | -j${RESTY_J} |
| `RESTY_LUAJIT_OPTIONS` | LuaJIT compile options | (see Dockerfile) |
| `RESTY_ADD_PACKAGE_BUILDDEPS` | Additional build dependencies | |
| `RESTY_ADD_PACKAGE_RUNDEPS` | Additional runtime dependencies | |
| `RESTY_EVAL_PRE_CONFIGURE` | Commands before configure | |
| `RESTY_EVAL_POST_MAKE` | Commands after make | |
| `LUAROCKS_VERSION` | LuaRocks version | 3.13.0 |
| `ENABLE_HTTP_PROXY_CONNECT` | Enable proxy connect module | false |
| `NGX_PROXY_CONNECT_VERSION` | Proxy connect module version | 0.0.7 |

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `PATH` | Includes OpenResty binaries | /usr/local/openresty/... |

OpenResty uses standard Nginx environment variables:

- Configure via nginx.conf or environment-specific conf files
- Use `envsubst` in config files for dynamic variables
- See [Nginx documentation](https://nginx.org/en/docs/) for configuration options

## Volumes

| Path | Description |
|------|-------------|
| `/usr/local/openresty/nginx/conf/conf.d` | Nginx configuration files (mount read-only) |
| `/usr/local/openresty/lualib/app` | Custom Lua modules (mount read-only) |
| `/var/run/openresty` | Runtime files (use tmpfs) |
| `/var/cache/nginx` | Cache directory (use tmpfs) |
| `/var/log/nginx` | Log files (logs to stdout/stderr by default) |

## Ports

| Port | Protocol | Description |
|------|----------|-------------|
| 8080 | HTTP | Default HTTP port |
| 8443 | HTTPS | Conventional non-root HTTPS port (opt-in — provide a cert + `listen 8443 ssl;`) |

The image runs fully as the non-root `nginx` user, which cannot bind a
privileged port, so it listens on 8080 by default (8443 for TLS). Publish
these to any host port you like; if you mount your own config, listen on a
port ≥ 1024.

## Security

### Process Security

- **Master and Worker Processes**: Both run as the non-root `nginx` user (uid 101, gid 101). The stock config listens on the unprivileged port 8080 (8443 is the conventional, opt-in HTTPS port), so the image needs no capabilities at all — compatible with `cap_drop: ALL` and `no-new-privileges`.
- **No Shell**: nginx user has `/sbin/nologin` shell
- **Signal Handling**: Uses SIGQUIT for clean shutdown

### Runtime Hardening

The included docker-compose.yml demonstrates security best practices — a
non-root image on unprivileged ports, zero capabilities, and an immutable
root filesystem:

```yaml
services:
  openresty:
    image: ghcr.io/oorabona/openresty:latest
    read_only: true              # Immutable root filesystem
    volumes:
      # nginx (non-root) writes its pid/cache/temp files into image-created
      # dirs; a tmpfs over an existing dir isn't reliably writable by the
      # non-root user with the short-form `tmpfs:` list (it can't set a mode),
      # so use the long-form with an octal `mode: 01777` (some Compose versions
      # accept it only as an unquoted integer). One per writable dir:
      - { type: tmpfs, target: /var/run/openresty, tmpfs: { mode: 01777 } }
      - { type: tmpfs, target: /var/cache/nginx, tmpfs: { mode: 01777 } }
      - { type: tmpfs, target: /tmp, tmpfs: { mode: 01777 } }
      - { type: tmpfs, target: /usr/local/openresty/nginx/client_body_temp, tmpfs: { mode: 01777 } }
      - { type: tmpfs, target: /usr/local/openresty/nginx/proxy_temp, tmpfs: { mode: 01777 } }
      - { type: tmpfs, target: /usr/local/openresty/nginx/fastcgi_temp, tmpfs: { mode: 01777 } }
      - { type: tmpfs, target: /usr/local/openresty/nginx/uwsgi_temp, tmpfs: { mode: 01777 } }
      - { type: tmpfs, target: /usr/local/openresty/nginx/scgi_temp, tmpfs: { mode: 01777 } }
    cap_drop:
      - ALL                      # Drop all capabilities (none are needed)
    security_opt:
      - no-new-privileges:true   # Prevent privilege escalation
    ports:
      - "8080:8080"              # HTTP
      - "8443:8443"              # HTTPS — nothing listens here until you add a
                                 #         `listen 8443 ssl;` server + a cert
```

On a normal (writable) rootfs the tmpfs mounts aren't needed — the image
writes only to its own already-chowned dirs — so `read_only` plus the tmpfs
block is the extra step for an immutable filesystem.

Because it runs as a non-root user, binds only unprivileged ports, and needs
no capabilities, the image is a good fit for **Kubernetes' restricted Pod
Security Standard** — set the corresponding pod `securityContext`
(`runAsNonRoot: true`, `runAsUser: 101`, `allowPrivilegeEscalation: false`,
`capabilities.drop: ["ALL"]`, and a `seccompProfile`); a Compose
`cap_drop`/`security_opt` is not itself a Kubernetes manifest.

### Healthcheck

The built-in healthcheck verifies OpenResty is responding. It uses
BusyBox `wget` (curl is not in the runtime image) against `/` on the
non-privileged port the non-root server listens on:

```dockerfile
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD wget -q -O /dev/null http://localhost:8080/ || exit 1
```

The built-in check targets `:8080` — the port the stock config listens on.
If you mount a config that listens only on a different port (e.g. `8443`,
or another unprivileged port), override the healthcheck to match, or the
container will report unhealthy even while serving.

If you'd rather probe a dedicated status endpoint, add one to your nginx
configuration and point a custom healthcheck at it:

```nginx
location /nginx_status {
    stub_status on;
    access_log off;
    allow 127.0.0.1;
    deny all;
}
```

## Dependencies

This container includes the following pinned dependencies:

| Dependency | Version | Monitoring Status | Notes |
|------------|---------|-------------------|-------|
| Alpine Linux | latest | Active | Base image |
| OpenResty | (from version.sh) | Active | Main application |
| OpenSSL | 3.5.6 | Pinned (3.5 LTS) | LTS, supported to 2030-04-08; migrated from EOL 1.1.1w (#448) |
| PCRE2 | 10.47 | Active (pinned) | Migrated from EOL PCRE1 8.45 (#453 volet 1); tracked-source monitoring redesign tracked in #453 |
| LuaRocks | 3.13.0 | Active | Lua package manager |
| ngx_http_proxy_connect_module | 0.0.7 | Active | Optional forward proxy support |

**Note on pinned dependencies:**

- **OpenSSL 3.5.6**: Pinned to the OpenSSL 3.5 LTS series (supported to 2030-04-08). Migrated from the EOL 1.1.1w pin after openssl.org removed the 1.1.1w tarball and broke the build (#448). OpenResty's `sess_set_get_cb_yield` patch (version 3.5.5) is applied for Lua coroutine session-callback yield. `monitor: false` is retained for now; the tracked-source monitoring redesign is tracked in #453.
- **PCRE2 10.47**: Migrated from EOL PCRE1 8.45 (#453 volet 1). Downloaded from `github.com/PCRE2Project/pcre2/releases` and integrity-verified via SHA256 (`RESTY_PCRE_SHA256`) before extraction. `RESTY_PCRE_VERSION` now refers to a PCRE2 version (PCRE1 is retired). When bumping the version, update both `RESTY_PCRE_VERSION` and `RESTY_PCRE_SHA256` together — they are coupled to the same `.tar.gz` asset. `monitor:false` is retained; tracked-source monitoring redesign is tracked in #453.

## Architecture

### Build Process

1. **Bootstrap**: Downloads and compiles OpenSSL 3.5.x with OpenResty patches
2. **PCRE2 Compilation**: Downloads, SHA256-verifies, and builds PCRE2 10.47 with JIT support
3. **Optional Module**: Downloads ngx_http_proxy_connect_module if enabled
4. **OpenResty Build**: Configures and compiles OpenResty with all modules
5. **LuaRocks Installation**: Installs Lua package manager
6. **Cleanup**: Removes build dependencies to minimize image size

### Included Nginx Modules

**Core HTTP Modules:**
- http_ssl_module - HTTPS support
- http_v2_module - HTTP/2 protocol
- http_realip_module - Client IP from proxy headers
- http_addition_module - Add text before/after responses
- http_sub_module - Response substitution
- http_dav_module - WebDAV methods
- http_flv_module - FLV streaming
- http_mp4_module - MP4 streaming
- http_gunzip_module - Decompress responses
- http_gzip_static_module - Serve pre-compressed files
- http_auth_request_module - External authentication
- http_random_index_module - Random directory index
- http_secure_link_module - Signed URL validation
- http_slice_module - Range request slicing
- http_stub_status_module - Basic status page

**Dynamic Modules:**
- http_geoip_module - Geolocation based on IP
- http_image_filter_module - Image transformation
- http_xslt_module - XSLT transformations

**Stream Modules:**
- stream_core_module - TCP/UDP load balancing
- stream_ssl_module - TLS for stream

**Mail Modules:**
- mail_core_module - Mail proxy
- mail_ssl_module - SMTP/IMAP/POP3 SSL

### Directory Structure

```
/usr/local/openresty/
├── bin/
│   ├── openresty           # OpenResty binary
│   ├── resty               # Resty CLI
│   └── restydoc            # Documentation viewer
├── luajit/
│   └── bin/
│       ├── luajit          # LuaJIT interpreter
│       └── luarocks        # Lua package manager
├── lualib/                 # Lua libraries
│   ├── resty/              # OpenResty Lua modules
│   └── app/                # Custom modules (mount here)
├── nginx/
│   ├── conf/
│   │   ├── nginx.conf      # Main configuration
│   │   └── conf.d/         # Additional configs (mount here)
│   ├── html/               # Default web root
│   └── logs/               # Logs (symlinked to stdout/stderr)
├── openssl/                # OpenSSL libraries
└── pcre2/                  # PCRE2 libraries
```

## Common Use Cases

### API Gateway

```nginx
upstream backend {
    server api1:3000;
    server api2:3000;
    keepalive 32;
}

server {
    listen 8080;

    location /api/v1 {
        access_by_lua_block {
            -- Rate limiting
            local limit = require "resty.limit.req"
            local lim = limit.new("limit_store", 100, 50)
            local key = ngx.var.remote_addr
            local delay, err = lim:incoming(key, true)
            if not delay then
                if err == "rejected" then
                    return ngx.exit(429)
                end
            end
        }

        proxy_pass http://backend;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
    }
}
```

### Web Application Firewall

```lua
-- lua/waf.lua
local rules = {
    sql_injection = [[(\%27)|(\')|(\-\-)|(\%23)|(#)]],
    xss = [[(\%3C)|(<)|(\%3E)|(>)|(\%3c)|(\%3e)]],
}

local uri = ngx.var.uri
local args = ngx.var.args or ""

for rule_name, pattern in pairs(rules) do
    if string.match(uri, pattern) or string.match(args, pattern) then
        ngx.log(ngx.ERR, "WAF: Blocked ", rule_name, " attempt")
        return ngx.exit(403)
    end
end
```

### Caching Proxy

```nginx
proxy_cache_path /var/cache/nginx levels=1:2 keys_zone=cache:10m max_size=1g inactive=60m;

server {
    listen 8080;

    location / {
        proxy_cache cache;
        proxy_cache_valid 200 60m;
        proxy_cache_valid 404 1m;
        proxy_cache_key "$scheme$request_method$host$request_uri";
        proxy_cache_bypass $http_cache_control;
        add_header X-Cache-Status $upstream_cache_status;

        proxy_pass http://origin;
    }
}
```

### Dynamic Load Balancing

```lua
-- lua/balancer.lua
local balancer = require "ngx.balancer"
local redis = require "resty.redis"

-- Get healthy backends from Redis
local red = redis:new()
red:connect("redis", 6379)
local backends = red:smembers("healthy_backends")

-- Round-robin selection
local current = ngx.shared.balance:incr("counter", 1, 0)
local index = (current % #backends) + 1
local backend = backends[index]

-- Set upstream server
local ok, err = balancer.set_current_peer(backend)
if not ok then
    ngx.log(ngx.ERR, "failed to set peer: ", err)
    return ngx.exit(500)
end
```

## Performance Tips

- **Connection Pooling**: Use keepalive upstream connections
- **Lua Shared Dictionaries**: Cache data across workers with `lua_shared_dict`
- **LuaJIT Optimization**: Profile code with `-jdump` for hotspots
- **Worker Processes**: Set to number of CPU cores
- **Sendfile**: Enable for static file serving
- **TCP Nopush**: Reduce network overhead
- **Gzip**: Compress responses (or use gzip_static)

## Version Management

```bash
# Check current version
./version.sh

# Check latest upstream version
./version.sh latest

# Output JSON for automation
./version.sh --json
```

## Building Locally

```bash
# From repository root
./make build openresty

# With specific version
./make build openresty 1.25.3.2

# With proxy connect module
docker build \
  --build-arg ENABLE_HTTP_PROXY_CONNECT=true \
  -t openresty:latest .
```

## Links

- [OpenResty Official Site](https://openresty.org/)
- [OpenResty GitHub](https://github.com/openresty/openresty)
- [Lua Nginx Module Documentation](https://github.com/openresty/lua-nginx-module)
- [LuaJIT](https://luajit.org/)
- [LuaRocks](https://luarocks.org/)
- [awesome-resty](https://github.com/bungle/awesome-resty) - Curated Lua libraries
- [Docker Hub Repository](https://hub.docker.com/r/oorabona/openresty)
- [GitHub Container Registry](https://ghcr.io/oorabona/openresty)
- [Source Repository](https://github.com/oorabona/docker-containers)
