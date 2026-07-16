# Tor Playground

A single [tor](../../tor/) container (monitoring flavor) for trying out the control port hands-on — SOCKS proxy, Nyx, `SIGNAL NEWNYM`, exit-country steering. Companion to the ["Tor control port" blog post](https://oorabona.github.io/docker-containers/blog/the-tor-control-port-circuits-cookies-and-newnym/).

## When to use this

- Learning the Tor control protocol (`AUTHENTICATE`, `SIGNAL`, `GETINFO`) without touching a production setup
- Trying `SIGNAL NEWNYM` and watching circuits rotate in Nyx
- Testing an app's behavior across different exit countries via `EXIT_NODES`

## Quick start

```bash
docker compose up -d
docker compose exec tor nyx
```

Inside Nyx, press `m` for the page menu and select *Interpreter* (or `h` on any page for the current keybinding reference), then:

```
SIGNAL NEWNYM
GETINFO circuit-status
```

## Checking the effect from outside

```bash
curl --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip
# send SIGNAL NEWNYM via nyx, then:
curl --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip
```

Both should report a US exit (this stack sets `EXIT_NODES=US`) — the circuit ID from `GETINFO circuit-status` is the reliable signal that a new circuit was built, since exit selection is weighted and repeating the same IP occasionally is normal.

## Scripting it without Nyx

```bash
COOKIE=$(docker compose exec -T tor cat /var/lib/tor/control_auth_cookie | xxd -p | tr -d '\n')
docker compose exec -T tor sh -c "printf 'AUTHENTICATE %s\r\nSIGNAL NEWNYM\r\nQUIT\r\n' '$COOKIE' | nc 127.0.0.1 9051"
```

The container only does what only it can do — read the cookie file, reach the loopback-only control port. Hex-encoding happens on your own machine (`xxd -p`, or `od -An -tx1 | tr -d ' \n'` if you don't have `xxd`).

## Notes

- The control port stays loopback-only and cookie-authenticated — this playground doesn't open external control access. See [tor/README.md](../../tor/README.md#opt-in-external-control) for that.
- `EXIT_NODES=US` is a playground choice so the exit-country effect is easy to observe; drop or change it freely.

## Testing

```bash
bash test.sh
```
