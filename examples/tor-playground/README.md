# Tor Playground

A single [tor](../../tor/) container (monitoring flavor) for trying out the control port hands-on — SOCKS proxy, Nyx, `SIGNAL NEWNYM`, exit-country steering. Companion to the ["Tor control port" blog post](https://oorabona.github.io/docker-containers/blog/the-tor-control-port-circuits-cookies-and-newnym/).

## When to use this

- Learning the Tor control protocol (`AUTHENTICATE`, `SIGNAL`, `GETINFO`) without touching a production setup
- Trying `SIGNAL NEWNYM` and seeing how a new connection's circuit differs in Nyx
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
# send SIGNAL NEWNYM via nyx, then open a NEW connection (the check above
# reused the old one) to see what circuit it lands on:
curl --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip
```

That endpoint only confirms `IsTor` and the exit `IP`, not country — `EXIT_NODES=US` prefers US relays for exit selection, but confirming that from the outside needs an IP-geolocation lookup, and it's always a preference, never a hard guarantee — Tor's own manual is explicit that `StrictNodes` doesn't apply to `ExitNodes` at all (see the blog post's torrc section). `GETINFO circuit-status` in Nyx is worth exploring, but NEWNYM only marks *existing* circuits dirty for future streams — it doesn't force an immediate rebuild, so the reliable way to observe the effect is opening a genuinely new connection (like the second `curl` above) and seeing what it gets, not just re-reading the circuit table right after sending the signal.

## Scripting it without Nyx

```bash
COOKIE=$(docker compose exec -T tor cat /var/lib/tor/control_auth_cookie | xxd -p | tr -d '\n')
printf 'AUTHENTICATE %s\r\nSIGNAL NEWNYM\r\nQUIT\r\n' "$COOKIE" | docker compose exec -T tor nc 127.0.0.1 9051
```

The container only does what only it can do — read the cookie file, reach the loopback-only control port. Hex-encoding happens on your own machine (`xxd -p`, or `od -An -tx1 | tr -d ' \n'` if you don't have `xxd`). The `AUTHENTICATE`/`SIGNAL` line is piped into `nc` as stdin rather than embedded in the command itself, so the cookie is never visible in a process listing inside the container.

## Notes

- The control port stays loopback-only and cookie-authenticated — this playground doesn't open external control access. See [tor/README.md](../../tor/README.md#opt-in-external-control) for that.
- `EXIT_NODES=US` is a playground default, not something this stack proves from the outside on its own (see the note above) — drop or change it freely.

## Testing

```bash
bash test.sh
```

Unlike this project's other example stacks, this one can't be smoke-tested without touching the real network — the whole point is a working Tor circuit, and there's no way to prove that without actually reaching the Tor network and `check.torproject.org`. Expect it to be slower and occasionally flakier than a fully self-contained test on a restricted, offline, or firewalled connection, or during a Tor/endpoint outage. Requires Docker Compose v2.24+ (uses the `!override` YAML tag to isolate the test's own port binding from your `docker compose up -d` session).
