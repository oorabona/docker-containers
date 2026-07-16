---
layout: post
title: "The Tor control port: circuits, cookies, and NEWNYM"
description: "Most people only ever talk to Tor through its SOCKS port. There's a second port that lets you ask Tor questions and give it orders — including \"get me a new circuit.\" A hands-on tour of the control protocol, using our tor container as a playground."
date: 2026-07-15 06:00:00 +0000
tags: [tor, networking, security, docker, tutorial]
---

If you've used Tor at all, you've used its SOCKS port: point a client at `127.0.0.1:9050`, and your traffic comes out the other end of a three-hop circuit. That's the whole interaction most people ever have with it. But Tor exposes a second port that has nothing to do with carrying traffic — it's a command channel. You can ask it questions ("what circuits are open right now?") and give it orders ("throw away the current one and build a new one"). That second port is what this post is about, using our [`tor` container](https://github.com/oorabona/docker-containers/tree/master/tor) as a place to actually try it rather than just read about it.

## Two ports, two jobs

The **SOCKS port** (9050 by default) is where your traffic goes in. Whatever you point at it — a browser, `curl`, an app — gets proxied out through a Tor circuit. It doesn't understand commands; it only understands connections.

The **control port** (9051 by default) is a completely separate listener with a completely different job: it speaks a line-based text protocol that lets a client — a script, a monitoring tool, an interactive console — inspect and steer the running Tor process. Circuit status, bandwidth stats, log events, and the command we care about here, `SIGNAL NEWNYM`, all go through this port. Nothing you send it ever touches your anonymized traffic; it's a management interface, not a proxy.

Our container starts both by default. The control port, specifically, starts bound to loopback only — which is deliberate, and worth understanding before you go looking for how to open it up.

## Auth: cookie vs password

Anyone who can talk to the control port can tell your Tor process what to do — including asking it to hand over a lot of information about your circuits. So the control port requires authentication before it'll accept anything past `AUTHENTICATE`.

Tor supports two authentication methods, and the container defaults to the one that needs no configuration:

- **Cookie authentication** (the default here): Tor writes a random cookie file to disk (`/var/lib/tor/control_auth_cookie`) that only processes with filesystem access to the container can read. Authenticating means reading that file and presenting its contents. There's no password to set, lose, or leak into a shell history — but it only makes sense when the client and the control port are on the same trust boundary, which is exactly the loopback-only default.
- **Password authentication**: you set a password (as a pre-hashed value or, less ideally, plaintext) via a `PASSWORD_FILE`, and clients authenticate with it. This is what you need if the control port has to be reachable from *outside* the container — and the entrypoint enforces that ordering: if you try to bind the control port to a non-loopback address without also providing a password, Tor refuses to start rather than come up with an unauthenticated control port sitting on a real network interface. That's a fail-closed default, not an oversight.

For everything in this post, you don't need to touch either setting — cookie auth on loopback is exactly what you want for talking to your own container from inside it.

## The control protocol, briefly

The control protocol is plain text, one command per line, closer in spirit to SMTP than to anything binary. A session looks like this:

```
AUTHENTICATE 2A3B4C...
250 OK
SIGNAL NEWNYM
250 OK
GETINFO circuit-status
250+circuit-status=
  4 BUILT ...
  .
250 OK
```

Responses start with a three-digit status code (`250` means success), and multi-line responses use a continuation marker ending in a bare `.`. You'll only need three commands for what follows: `AUTHENTICATE` to get past the front door, `SIGNAL` to send Tor a directive, and `GETINFO` to ask it a question. The full command set is documented in Tor's [control-spec](https://github.com/torproject/torspec/blob/main/control-spec.txt) if you want to go further than this post does.

## What NEWNYM actually does

A Tor circuit, for ordinary web traffic, is three relays: a **guard** (entry), a **middle**, and an **exit** — your traffic's actual path only exists for the lifetime of that circuit, and only the guard ever sees your real IP.

`SIGNAL NEWNYM` tells Tor: stop reusing existing circuits for *new* connections, and clear the client-side DNS cache. It's worth being precise about what that does and doesn't do:

- It does **not** tear down circuits that are already carrying an open connection — those keep running until they close naturally.
- It marks current circuits "dirty" for future streams, so the *next* connection you open gets routed onto a freshly built circuit — new middle, new exit.
- The **guard relay is the one thing that deliberately doesn't rotate on NEWNYM.** Tor picks a small set of guards and sticks with them for weeks at a time by design — that's a defense against certain long-term correlation and guard-discovery attacks, not a limitation. If you're expecting NEWNYM to change *everything* about your circuit and it doesn't, this is why: the part most people actually notice change is the exit IP, because the exit is what a destination server sees.
- Tor enforces roughly a 10-second cooldown between NEWNYM signals — hammering it doesn't get you a new circuit any faster.

There's also a torrc setting, `MaxCircuitDirtiness` (600 seconds by default), that does automatically what NEWNYM does manually: after that many seconds, a circuit is retired for new streams on its own. NEWNYM is the on-demand version of the same mechanism.

## Steering exit country via torrc

NEWNYM gets you *a* new circuit, but not a *chosen* one. If you want to constrain where the exit relay is, that's a different, complementary directive — and our container has a shortcut for the common case.

Two environment variables map straight to Tor's country-based exit filtering:

```bash
docker run -d --name tor \
  -e EXIT_NODES=US \
  -p 127.0.0.1:9050:9050 \
  ghcr.io/oorabona/tor:latest
```

`EXIT_NODES=US` becomes `ExitNodes {US}` in the generated torrc; `EXCLUDE_EXIT_NODES=CN,RU` becomes `ExcludeExitNodes {CN},{RU}`. Both accept comma-separated country codes.

That covers "prefer/avoid these countries," which is most of what people actually want. If you need more — `StrictNodes` (hard-fail instead of falling back when your preferred exits are unreachable), `ExcludeNodes` (excluding relays anywhere in the path, not just the exit), relay or hidden-service configuration — none of that has an environment-variable shortcut. You supply your own `torrc` instead:

```bash
docker run -d --name tor \
  -v "$PWD/torrc:/etc/tor/torrc:ro" \
  ghcr.io/oorabona/tor:latest
```

**The gotcha**: the moment the container detects a non-empty custom `torrc`, it treats that file as the *complete* configuration and ignores every simple environment variable — `EXIT_NODES` included — logging a warning rather than silently merging the two. If you're mounting a custom torrc for one specific directive, anything you were setting via env vars needs to move into that file too, or it stops applying. Going from `EXIT_NODES=US` to a custom file that also wants `StrictNodes` means writing both directives yourself:

```
# torrc
ExitNodes {US}
StrictNodes 1
```

Drop the `EXIT_NODES` env var once you do this — it's ignored anyway, and leaving it set is just noise that no longer does anything.

## Playground walkthrough

Time to actually do this. There's a ready-to-run [`tor-playground`](https://github.com/oorabona/docker-containers/tree/master/examples/tor-playground) example in the project repo — it's exactly the setup below, already wired with `EXIT_NODES=US` and the monitoring flavor, so you don't have to copy commands out of a blog post one at a time:

```bash
git clone https://github.com/oorabona/docker-containers.git
cd docker-containers/examples/tor-playground
docker compose up -d
docker compose exec tor nyx
```

Or, if you'd rather not clone the repo, the same thing as a standalone `docker run`:

```bash
docker run -d --name tor \
  -e EXIT_NODES=US \
  -p 127.0.0.1:9050:9050 \
  -v tor-data:/var/lib/tor \
  ghcr.io/oorabona/tor:latest-monitoring

docker exec -it tor nyx
```

Nyx's main screen shows live bandwidth, connections, and log lines — useful, but not what we're after. Get to the **interpreter** panel (Nyx's raw-controller access, built on Stem) by pressing `m` for the page menu and selecting *Interpreter* — if your Nyx version lays its menu out differently, press `h` on any page for the full, current keybinding reference. Once you're there, you can type control-protocol commands directly and see the response inline:

```
SIGNAL NEWNYM
250 OK
```

Check what changed:

```
GETINFO circuit-status
```

You'll see new circuit IDs after the signal — same guard as before, different middle and exit. If you want to see the effect from the outside rather than just the circuit table, check the exit IP through the SOCKS proxy before and after:

```bash
curl --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip
# send SIGNAL NEWNYM via nyx, wait a few seconds, then:
curl --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip
```

That endpoint returns a small JSON body (`{"IsTor":true,"IP":"..."}`) — the `IP` field is what to diff between the two calls. With `EXIT_NODES=US` set, both requests should report a US exit — just not necessarily a *different* IP every time. Exit selection is weighted, not round-robin, so getting the same exit twice in a row occasionally is normal, not a sign NEWNYM didn't work; the circuit ID from `GETINFO circuit-status` is the reliable signal that a new circuit was actually built.

## Scripted alternative

Nyx is convenient, but everything above is just text over a socket, which means it's trivial to script without any extra tooling — useful if you want to trigger a circuit rotation from a cron job or a CI step rather than a human at a terminal:

```bash
COOKIE=$(docker exec tor cat /var/lib/tor/control_auth_cookie | xxd -p | tr -d '\n')
docker exec tor sh -c "printf 'AUTHENTICATE %s\r\nSIGNAL NEWNYM\r\nQUIT\r\n' '$COOKIE' | nc 127.0.0.1 9051"
```

The cookie file is raw bytes, but `AUTHENTICATE` wants it as a hex string. Rather than lean on whichever hex tool happens to be compiled into this particular image's busybox build, split the work at the boundary that actually matters: the container does only what only it *can* do — `cat` the cookie out, and, in the second command, talk to the loopback-only control port with `nc`. Turning those bytes into hex happens on your own machine with `xxd` (or `od -An -tx1 | tr -d ' \n'` if you don't have `xxd` handy) — ordinary host tooling, not something you need to hope is in the container.

## When you'd actually reach for this

NEWNYM is not an "instant new identity" button, and treating it like one is the most common misunderstanding about it. The guard doesn't rotate; a destination that's tracking you by anything other than IP won't be fooled; and existing connections don't get torn down. What it's actually good for is more specific:

- **Testing** — verifying your app behaves correctly across different exit IPs, or across different exit countries with `EXIT_NODES`.
- **Troubleshooting a bad relay** — if a circuit is timing out or an exit is blocked by your destination, NEWNYM gets you off it without restarting the whole container.
- **Automated rotation** — the scripted version above, wired into whatever needs a fresh circuit on a schedule, rather than waiting out `MaxCircuitDirtiness`.

For anything more elaborate than that — building your own control logic around circuit selection — [Stem](https://stem.torproject.org/) (the Python library Nyx itself is built on) is the next step past raw `nc` commands.
