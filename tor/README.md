# Tor — SOCKS Proxy, Relay, Bridge, and Hidden-Service Container

[![Docker Pulls](https://img.shields.io/docker/pulls/oorabona/tor)](https://hub.docker.com/r/oorabona/tor)
[![Docker Image Size](https://img.shields.io/docker/image-size/oorabona/tor)](https://hub.docker.com/r/oorabona/tor)
[![GHCR](https://img.shields.io/badge/GHCR-oorabona%2Ftor-blue)](https://ghcr.io/oorabona/tor)
[![GitHub Stars](https://img.shields.io/github/stars/oorabona/docker-containers?style=social)](https://github.com/oorabona/docker-containers)

Tor with a secure default control-port setup: SOCKS on 9050, cookie authentication for local control, Lyrebird for pluggable transports, and an optional Nyx monitoring flavor.

## Verify this image

Every build ships a Sigstore-signed SBOM and a full Trivy scan — verify them yourself, no login required:

```bash
gh attestation verify oci://ghcr.io/oorabona/tor:latest --owner oorabona
```

Full walkthrough (SBOM payload, Trivy findings, multi-arch manifest inspection, upstream dependency tracking) → <https://oorabona.github.io/docker-containers/verify-images/>

## Platforms

- **amd64** - x86_64 systems
- **arm64** - ARM 64-bit systems

## Tags

- `latest`, `0.4.9.11-alpine` - Tor + Lyrebird
- `latest-monitoring`, `0.4.9.11-alpine-monitoring` - Tor + Lyrebird + Nyx + py3-stem

## Versioning

Tor, Lyrebird, and Nyx are installed from Alpine packages. The image records the actual installed package versions in `/usr/local/share/tor/package-versions.env`.

Lyrebird and Nyx remain tracked against upstream releases as an advisory traceability signal. A PR such as `LYREBIRD_VERSION: 0.8.1 -> 0.9.0` means upstream released a new version and Alpine should be checked; merging that PR updates the declared signal, but the running image changes only after Alpine repackages and the image is rebuilt.

## Basic SOCKS Proxy

```bash
docker run -d \
  --name tor \
  -p 9050:9050 \
  -v tor-data:/var/lib/tor \
  ghcr.io/oorabona/tor:latest
```

Use `socks5h://`, not plain `socks5://`, when the client supports it:

```bash
curl --proxy socks5h://127.0.0.1:9050 https://check.torproject.org/api/ip
```

The `h` means hostname resolution happens through Tor. Many clients using plain `socks5://` resolve DNS locally before connecting to the proxy, which leaks the destination hostname outside the Tor circuit.

## Configuration

### Simple Environment Path

The image generates a minimal torrc when `/etc/tor/torrc` is absent, empty, or contains only whitespace/comments.

| Variable | Default | Effect |
|---|---:|---|
| `SOCKS_BIND` | `0.0.0.0` | SOCKS listen address inside the container |
| `SOCKS_PORT` | `9050` | SOCKS listen port |
| `EXIT_NODES` | unset | Comma-separated country codes rendered as Tor `{cc}` entries |
| `EXCLUDE_EXIT_NODES` | unset | Comma-separated country codes to avoid |
| `PASSWORD_FILE` | unset | Optional Docker-secret file for external control authentication |
| `CONTROL_PORT_BIND` | `127.0.0.1` | Control port bind address; non-loopback requires `PASSWORD_FILE` |
| `CONTROL_PORT` | `9051` | Control port listen port |
| `CHECK` | `false` | When true, healthcheck verifies Tor exit status through check.torproject.org |

Default control access uses `CookieAuthentication 1` and binds `ControlPort 127.0.0.1:9051`. The image does not expose the control port.

The default healthcheck first verifies that the Tor process is alive. For the generated simple torrc path it also confirms the configured SOCKS listener is open; for mounted torrc deployments it does not assume SOCKS exists. Set `CHECK=true` only when readiness must confirm a working SOCKS circuit through check.torproject.org.

### Mounted torrc Path

For relay, bridge, exit, and hidden-service deployments, mount a full torrc:

```bash
docker run -d \
  --name tor-relay \
  -p 9050:9050 \
  -p 9001:9001 \
  -v "$PWD/torrc:/etc/tor/torrc:ro" \
  -v tor-data:/var/lib/tor \
  ghcr.io/oorabona/tor:latest
```

When `/etc/tor/torrc` contains at least one non-comment directive, it owns Tor's behavior-affecting configuration. The container supplies only `DataDirectory`, `PidFile`, and `Log` through Tor's defaults file. If simple environment variables are also set, startup logs a warning because those variables have no effect in this mode.

## Relay Example

Minimal relay torrc:

```torrc
Nickname ExampleRelay
ContactInfo admin@example.com
ORPort 9001
ExitRelay 0
SocksPort 0
```

Publish `9001` for relay and bridge mode. Without an inbound ORPort mapping, other Tor nodes cannot reach the relay even if the process starts cleanly.

## Monitoring Flavor

Run the monitoring tag, then attach Nyx from inside the container:

```bash
docker run -d \
  --name tor \
  -p 9050:9050 \
  -v tor-data:/var/lib/tor \
  ghcr.io/oorabona/tor:latest-monitoring

docker exec -it tor nyx
```

Nyx runs as the `tor` user and reads `/var/lib/tor/control_auth_cookie`; no password is generated or printed in the default path.

## Persistence

`/var/lib/tor` is optional for a disposable SOCKS proxy and required for identity-bearing modes:

- relay fingerprint continuity
- bridge identity continuity
- hidden-service private keys and `.onion` address continuity

The entrypoint warns when a mounted torrc defines `HiddenServiceDir` or `ORPort` and `/var/lib/tor` does not look like a mounted volume. This is a best-effort heuristic; the absence of the warning is not proof that persistence is configured correctly.

Named Docker volumes are prepared by the root-to-`tor` startup path. If `/var/lib/tor` is a bind mount and the container is not started with `--user 0`, pre-own the host directory as uid `100` so the `tor` user can write it.

## Security

- Runs as the named `tor` user by default
- Uses Tor cookie authentication by default
- Binds the control port to loopback by default
- Does not declare `EXPOSE 9051`
- Does not ship a default control password

### Runtime Hardening

```yaml
services:
  tor:
    image: ghcr.io/oorabona/tor:latest
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    ports:
      - "9050:9050"
    volumes:
      - tor-data:/var/lib/tor
    restart: unless-stopped

volumes:
  tor-data:
```

Relay mode still does not need extra Linux capabilities when using an unprivileged ORPort such as `9001`.

## Building

```bash
./make build tor
```

Build the monitoring flavor through the normal variant pipeline:

```bash
./make build tor latest monitoring
```

## License

MIT
