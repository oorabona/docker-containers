# OpenResty - High Performance Web Platform

OpenResty is a full-fledged web platform that integrates the standard Nginx core, LuaJIT, and many carefully written Lua libraries. This container provides a flexible, high-performance web platform for modern applications.

## Features

- **Nginx + Lua**: Combines Nginx's performance with Lua's flexibility
- **High Performance**: Optimized for high-concurrency applications
- **Extensible**: Rich ecosystem of Lua modules
- **API Gateway**: Perfect for microservices and API management
- **Dynamic Configuration**: Runtime configuration changes with Lua

## Usage

### With Docker Compose

```yaml
version: '3.8'
services:
  openresty:
    build: .
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./conf.d:/usr/local/openresty/nginx/conf/conf.d
      - ./lua:/usr/local/openresty/lualib/app
    environment:
      - RESTY_CONFIG_OPTIONS=--with-luajit
```

### Direct Docker Run

```bash
docker run -d \
  --name openresty \
  -p 80:80 \
  -p 443:443 \
  -v ./conf.d:/usr/local/openresty/nginx/conf/conf.d \
  oorabona/openresty
```

## Configuration

### Nginx Configuration

Place your nginx configuration files in `conf.d/`:

```nginx
server {
    listen 80;
    server_name example.com;
    
    location / {
        content_by_lua_block {
            ngx.say("Hello from OpenResty + Lua!")
        }
    }
}
```

### Lua Modules

Add custom Lua modules in the `lua/` directory:

```lua
-- lua/hello.lua
local _M = {}

function _M.say_hello(name)
    return "Hello, " .. (name or "World") .. "!"
end

return _M
```

## Common Use Cases

1. **API Gateway**: Route and transform API requests
2. **Web Application Firewall**: Security filtering with Lua
3. **Load Balancer**: Advanced load balancing algorithms
4. **Caching Proxy**: Intelligent caching strategies
5. **Microservices**: Service mesh components

## Build Arguments

- `RESTY_IMAGE_BASE` - Base image (default: alpine)
- `RESTY_IMAGE_TAG` - Image tag version
- `RESTY_CONFIG_OPTIONS` - OpenResty build options

## Building

```bash
cd openresty
./build  # Uses custom build script
# or
docker build -t openresty .
```

## Version Management

This container tracks OpenResty releases:

```bash
./version.sh          # Current version
./version.sh latest    # Latest available version
```

## Performance Tips

- Use Lua shared dictionaries for caching
- Leverage OpenResty's connection pooling
- Optimize Lua code for the LuaJIT compiler
- Use nginx's upstream module for load balancing

## Security

- Regular security updates through automated rebuilds
- Minimal attack surface with Alpine base
- Lua sandbox for safe code execution
- Built-in request filtering capabilities
