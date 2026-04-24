---
layout: post
title: "From Bare Metal to Container: The export.sh Tool for Host-to-Docker Migration"
description: "A Debian base image with a companion script that converts an existing Linux host — packages, /etc, /home — into a reproducible container. 80 MB and genuinely useful."
date: 2026-05-10 10:00:00 +0000
tags: [debian, docker, migration, containerization, homelab]
---

The official `debian` image has billions of pulls. Why would you need another one?

You wouldn't — unless you want to **migrate an existing Debian host into a container** without rewriting the deploy from scratch. The `oorabona/debian` image exists for exactly that. It's a thin wrapper around the official Debian slim with three additions: a migration tool called `export.sh`, multi-locale support, and a non-root user with sudo scoped to container-appropriate tasks.

This is a narrow use case. If you're building a Dockerfile from scratch, use `debian:slim` directly. If you want to take an existing Debian 12 host (homelab server, legacy VM, on-prem machine) and turn it into a container, read on.

## What's in the image

```bash
docker pull ghcr.io/oorabona/debian:latest
# 80 MB compressed, amd64 + arm64
```

- **Debian 12 / 13** (trixie) base, with `slim` variant support
- **Non-root `debian` user** (uid 1000) with passwordless sudo
- **Multi-locale support** via `ARG LOCALES="en_US,fr_FR,..."`
- **`export.sh`** — the interesting bit (200 lines, in `/usr/local/bin/`)
- **Healthcheck** via `whoami`

It also serves as the base for [oorabona/web-shell](/docker-containers/container/web-shell/), giving that image a stable "Debian base with sensible defaults."

## The export.sh workflow

Let's say you have a Debian 12 host at `server.example.com` that you want to containerize. It runs:

- A custom Python service in `/opt/myservice`
- A systemd unit managing it
- Some configs in `/etc/myservice/`
- Some state in `/var/lib/myservice/`
- A dozen apt packages you lost track of over the years

The canonical answer is "write a Dockerfile from scratch, copy what you need." In practice, you forget an apt package, a config file, a symlink, and the container starts but behaves subtly wrong for two days.

`export.sh` automates the observation step:

```bash
# On the source host
curl -O https://raw.githubusercontent.com/oorabona/docker-containers/master/debian/export.sh
chmod +x export.sh

# Generate a Dockerfile from the running system
sudo ./export.sh \
  --output myservice.Dockerfile \
  --packages auto \
  --include /etc/myservice /var/lib/myservice /opt/myservice \
  --user myservice
```

What it does:

1. **Enumerates installed packages** via `dpkg --get-selections` and filters out the base OS set. You get a minimal apt install list.
2. **Bundles the paths you list** (`--include`) into a layer, preserving ownership and permissions.
3. **Detects running services** via systemd and emits ENTRYPOINT hints for the one(s) you specify with `--user`.
4. **Outputs a Dockerfile** you can tune.

The output looks like:

```dockerfile
FROM ghcr.io/oorabona/debian:trixie

# Auto-detected packages (beyond Debian base)
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3-venv \
    postgresql-client \
    nginx-light \
    && rm -rf /var/lib/apt/lists/*

# User
RUN useradd -m -s /bin/bash myservice && \
    echo "myservice ALL=(ALL) NOPASSWD:/usr/bin/systemctl" >> /etc/sudoers.d/myservice

# Bundled paths
COPY --chown=myservice:myservice myservice-bundle/etc/myservice /etc/myservice
COPY --chown=myservice:myservice myservice-bundle/var/lib/myservice /var/lib/myservice
COPY --chown=myservice:myservice myservice-bundle/opt/myservice /opt/myservice

USER myservice
WORKDIR /opt/myservice

# Detected: systemd unit myservice.service wanted
# (you'll need to adapt ExecStart to a foreground form)
CMD ["python3", "/opt/myservice/main.py"]
```

That's not production-ready — no Dockerfile auto-generator will ever produce truly production-ready output. But it captures 80% of the "what does this host actually have installed" question that used to require two days of detective work.

You edit the remaining 20% (trim packages you don't need in the container, convert systemd units to foreground processes, add healthchecks, consider secrets), and you have a working starting point.

## Why this approach beats "write Dockerfile from scratch"

It doesn't, always. For a greenfield service with clean dependencies, writing a Dockerfile by hand is better — you understand exactly what's in the image.

For legacy workloads (the VM your predecessor set up in 2019), `export.sh` flips the direction: instead of "what does this need to run?" (unknowable from outside), you get "what's currently installed?" (known from the outside). Much easier starting point.

## Multi-locale support

Stock `debian` images ship with only `C.UTF-8` and `POSIX`. If your app formats dates in French or sorts strings in German, you need `locale-gen fr_FR.UTF-8`. Each locale adds ~5 MB.

Our image accepts `LOCALES` as a build arg:

```bash
docker build --build-arg LOCALES="en_US,fr_FR,de_DE" \
  -t my-debian .
```

The build-time `locale-gen` call creates only those locales. The default is `en_US,C`, which is usually plenty.

## As a base for other images

You'll see `FROM ghcr.io/oorabona/debian:trixie` in a few places:

- **[web-shell](/docker-containers/container/web-shell/)** — terminal-in-browser image, uses this as its Debian variant's base
- **User derivatives** — anything that wants a "Debian slim + non-root user + locale support" starting point

The image is intentionally boring. The `export.sh` script is the differentiator.

## What export.sh doesn't do

Setting expectations:

- **Doesn't convert systemd units automatically.** You still edit `ExecStart` to a foreground form.
- **Doesn't figure out networking.** Host-level iptables rules, openvpn tunnels, kernel modules — all manual.
- **Doesn't migrate secrets.** `/etc/shadow`, SSH host keys, API tokens — deliberately skipped; you handle these via Docker secrets.
- **Doesn't handle device access.** GPUs, USB devices, special hardware — your host setup.
- **Doesn't dedupe layers.** The output is a single RUN + multiple COPYs. You can dockerignore and multi-stage later.

It's a starting point, not a silver bullet. But the starting point is 80% closer than a blank Dockerfile.

## Typical use cases

- **Retiring a VM.** You've been meaning to containerize that Ruby app running on a 2020 Debian VM. `export.sh`, 20 minutes of tuning, deployed.
- **Homelab consolidation.** 5 services on 3 Pis, each with their own OS cruft. Export each, run them as compose services on a single docker host.
- **Pre-acquisition due diligence.** You're acquiring a company with 20 "how do we even deploy this?" servers. Export captures the state before anyone changes anything.
- **Reproducing a legacy environment for debugging.** Something only reproduces on a specific host; export it, debug in the container, fix, redeploy.

## Gotchas

- **Package versions drift.** `export.sh` captures package *names* but uses the image's apt sources for versions. If you need byte-for-byte reproducibility, add `=<version>` pins to the RUN.
- **Root-owned state.** Paths in `/var/lib/` often have root ownership. `export.sh` preserves this via `--chown` in COPY; running as non-root means you need to decide whether to `chown -R` on startup or stay root.
- **Conflicting `/etc`.** Bundling `/etc/nginx` from a host overrides the image's defaults. Usually fine; can surprise you.
- **Binary compatibility.** If the source is amd64 and you build for arm64, any binaries in the bundle break. Keep architecture consistent.

## Running the Debian image standalone

As a base, just like upstream debian:

```bash
docker run -it --rm ghcr.io/oorabona/debian:trixie bash
# You're root. useradd, apt install, build, commit, whatever.

docker run -it --rm \
  -e LOCALES="fr_FR,en_US" \
  ghcr.io/oorabona/debian:trixie bash
# debian user available for sudo-based workflows
```

## TL;DR

```bash
# As a base image
docker pull ghcr.io/oorabona/debian:trixie            # 80 MB

# Download export.sh
curl -O https://raw.githubusercontent.com/oorabona/docker-containers/master/debian/export.sh

# Use it on a host you want to containerize
sudo ./export.sh --output legacy.Dockerfile --include /opt/legacy /etc/legacy
```

Full docs and examples: [container dashboard](/docker-containers/container/debian/).

If `export.sh` saved you from a two-day reverse-engineering session, [⭐ the repo](https://github.com/oorabona/docker-containers). It's the kind of niche tool that only exists because someone needed it; the star count tells us whether to keep building these.
