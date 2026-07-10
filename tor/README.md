# Tor — SOCKS Proxy, Relay, Bridge, and Hidden-Service Container

[![Docker Pulls](https://img.shields.io/docker/pulls/oorabona/tor)](https://hub.docker.com/r/oorabona/tor)
[![Docker Image Size](https://img.shields.io/docker/image-size/oorabona/tor)](https://hub.docker.com/r/oorabona/tor)
[![GHCR](https://img.shields.io/badge/GHCR-oorabona%2Ftor-blue)](https://ghcr.io/oorabona/tor)
[![GitHub Stars](https://img.shields.io/github/stars/oorabona/docker-containers?style=social)](https://github.com/oorabona/docker-containers)

Tor with a secure default control-port setup: SOCKS on 9050, cookie authentication for local control, Lyrebird for pluggable transports, and an optional Nyx monitoring flavor.

## Why this image

The Tor Docker landscape already has several images, each making a different trade-off:

| Image | Strength | Gap |
|---|---|---|
| [dperson/torproxy](https://hub.docker.com/r/dperson/torproxy) | Most widely pulled | Unmaintained since 2021 |
| [peterdavehello/tor-socks-proxy](https://hub.docker.com/r/peterdavehello/tor-socks-proxy) | Actively updated | No arm64 on `latest`; a healthcheck bug has been open since 2023 |
| [dockur/tor](https://github.com/dockur/tor) | Full feature breadth — relay, exit, bridge, hidden-service, Lyrebird, Nyx | No SBOM/CVE scanning; ships `PASSWORD=password` as a control-port default, and its own compose example maps that port to the host |
| [leplusorg/docker-tor](https://github.com/leplusorg/docker-tor) | Clear supply-chain documentation | Deliberately SOCKS5-only — no relay, bridge, or hidden-service support |

This image is the combination none of them cover: dockur's feature breadth, wrapped in this fleet's supply-chain pipeline (multi-arch builds, a Sigstore-attested SBOM, a Trivy scan on every image, daily upstream version tracking) — with a control port that is loopback-bound and cookie-authenticated by default, never a shipped password.

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

**Lyrebird** is the Tor Project's pluggable-transport binary, the maintained successor to `obfs4proxy`. It disguises Tor traffic as something else — plain-looking TLS, depending on the transport — so a bridge stays usable on networks where Tor's normal traffic pattern is blocked or fingerprinted. It's installed in every tag; it does nothing unless a mounted torrc sets a `ClientTransportPlugin` or `ServerTransportPlugin` line.

**Nyx** is a terminal UI for a running Tor process — live bandwidth graphs, circuit and connection listings, log tailing — talking to Tor over the control port via the Python `stem` library. It's the standard monitor endorsed by the Tor Project and the only widely known tool of its kind, but it's effectively dormant upstream: no PyPI release since 2019, no GitHub commit since 2022 (`stem`, its own dependency, last changed in 2024). It stays in this fleet as an opt-in flavor rather than the default for that reason — Alpine still packages and patches it, this pipeline's own Trivy scan covers it on every build regardless of upstream release cadence, and it's only reachable via `docker exec`, never a network-exposed service.

## Versioning

Tor, Lyrebird, and Nyx are installed from Alpine packages. The image records the actual installed package versions in `/usr/local/share/tor/package-versions.env`.

Lyrebird and Nyx remain tracked against upstream releases as an advisory traceability signal. A PR such as `LYREBIRD_VERSION: 0.8.1 -> 0.9.0` means upstream released a new version and Alpine should be checked; merging that PR updates the declared signal, but the running image changes only after Alpine repackages and the image is rebuilt.

## Basic SOCKS Proxy

```bash
docker run -d \
  --name tor \
  -p 127.0.0.1:9050:9050 \
  -v tor-data:/var/lib/tor \
  ghcr.io/oorabona/tor:latest
```

This publishes SOCKS on host loopback only. Broader host-interface exposure should be an explicit operator choice, paired with appropriate network controls.

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
| `PASSWORD_FILE` | unset | Optional Docker-secret file for external control authentication, pre-hashed or plaintext |
| `CONTROL_PORT_BIND` | `127.0.0.1` | Control port bind address; non-loopback requires `PASSWORD_FILE` |
| `CONTROL_PORT` | `9051` | Control port listen port |
| `CHECK` | `false` | When true, healthcheck verifies Tor exit status through check.torproject.org |

Default control access uses `CookieAuthentication 1` and binds `ControlPort 127.0.0.1:9051`. The image does not expose the control port.

The default healthcheck first verifies that the Tor process is alive. For the generated simple torrc path it also confirms the configured SOCKS listener is open; for mounted torrc deployments it does not assume SOCKS exists. Set `CHECK=true` only when readiness must confirm a working SOCKS circuit through check.torproject.org.

### Opt-In External Control

For password-authenticated external control, set `PASSWORD_FILE` to a Docker secret and bind `CONTROL_PORT_BIND` deliberately. The recommended secret content is a pre-hashed Tor control password in `16:<58 hex characters>` `HashedControlPassword` format, generated outside the container, for example with `tor --hash-password` on a trusted host or a throwaway container. The entrypoint uses that value directly and never handles the plaintext.

For compatibility, `PASSWORD_FILE` may also contain a plaintext password. In that path the entrypoint hashes it at startup with `tor --hash-password`; Tor does not provide stdin or file input for this operation, so the plaintext is briefly visible in that helper process's argv inside the container PID namespace.

**Generating the password file (one-shot):**

```bash
# One-shot: hash a password using the same image, nothing persists
docker run --rm ghcr.io/oorabona/tor:latest \
  tor --hash-password 'correct horse battery staple' \
  | awk '/^16:/ {print; exit}' > control_password_hash

# Long-running container: opt in to external control with that hash
docker run -d \
  --name tor \
  -p 127.0.0.1:9050:9050 \
  -p 127.0.0.1:9051:9051 \
  -v "$PWD/control_password_hash:/run/secrets/tor_control_password:ro" \
  -e PASSWORD_FILE=/run/secrets/tor_control_password \
  -e CONTROL_PORT_BIND=0.0.0.0 \
  -v tor-data:/var/lib/tor \
  ghcr.io/oorabona/tor:latest
```

`CONTROL_PORT_BIND=0.0.0.0` is the address Tor binds *inside* the container — Docker can only forward a published port to an address the process is actually listening on there. The `-p 127.0.0.1:9051:9051` publish is what actually restricts host reachability to loopback; without `PASSWORD_FILE` set, the entrypoint refuses to start rather than open an unauthenticated control port on anything wider than the container's own loopback.

### Mounted torrc Path

For relay, bridge, exit, and hidden-service deployments, mount a full torrc:

```bash
docker run -d \
  --name tor-relay \
  -p 127.0.0.1:9050:9050 \
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
  -p 127.0.0.1:9050:9050 \
  -v tor-data:/var/lib/tor \
  ghcr.io/oorabona/tor:latest-monitoring

docker exec -it tor nyx
```

Or with Compose:

```yaml
services:
  tor:
    image: ghcr.io/oorabona/tor:latest-monitoring
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    ports:
      - "127.0.0.1:9050:9050"
    volumes:
      - tor-data:/var/lib/tor
    restart: unless-stopped

volumes:
  tor-data:
```

```bash
docker compose up -d
docker compose exec tor nyx
```

Nyx runs as the `tor` user and reads `/var/lib/tor/control_auth_cookie`; no password is generated or printed in the default path. It's a terminal application, not a background metrics exporter — there is no dashboard or scrape endpoint to point Prometheus at. Each `nyx` session is a live, interactive view for as long as the terminal stays attached.

## Persistence

`/var/lib/tor` is optional for a disposable SOCKS proxy and required for identity-bearing modes:

- relay fingerprint continuity
- bridge identity continuity
- hidden-service private keys and `.onion` address continuity

The data directory is fixed at `/var/lib/tor`; persist it by mounting a named volume or bind mount at that path.

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
      - "127.0.0.1:9050:9050"
    volumes:
      - tor-data:/var/lib/tor
    restart: unless-stopped

volumes:
  tor-data:
```

Relay mode still does not need extra Linux capabilities when using an unprivileged ORPort such as `9001`.

## Building

Build all variants, including the monitoring flavor, through the normal variant pipeline:

```bash
./make build tor
```

## License

MIT
