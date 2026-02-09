# Web Terminal

Secure browser-based terminal access via [web-shell](../../web-shell/) (ttyd) behind an OpenResty reverse proxy with HTTP basic authentication.

## When to use this

- Remote server administration from a browser
- Shared development environments
- Training labs or workshops
- Quick SSH alternative when only HTTP/S is available

## Architecture

```
               :8080
┌──────────────────────────────────────┐
│  OpenResty (reverse proxy)           │
│  Basic auth + WebSocket proxy        │
├──────────────────────────────────────┤
│  Web Shell (ttyd)                    │
│  Browser-based terminal emulator     │
└──────────────────────────────────────┘
```

The web-shell container is not exposed directly — all access goes through OpenResty with authentication.

## Quick start

```bash
docker compose up -d
# Open http://localhost:8080
# Credentials: admin / admin_change_me
```

## Production notes

- Replace basic auth with OAuth2 Proxy, Authelia, or similar
- Add TLS termination at the OpenResty layer
- Restrict network access to trusted IPs
- Set strong passwords via environment variables

## Testing

```bash
bash test.sh
```
