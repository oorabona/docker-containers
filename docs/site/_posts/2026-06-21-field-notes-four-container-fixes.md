---
layout: post
title: "Field Notes: Four Container Fixes and the Gotcha Behind Each"
description: "A round-up of recent fixes across these images — a 24× smaller OpenResty, healthchecks that actually run, and a PostgreSQL extension toolchain that stops drifting — with the root cause behind each."
date: 2026-06-21 09:00:00 +0000
tags: [docker, alpine, openresty, postgresql, php, healthcheck, multi-stage]
---

Most posts here are a single deep dive. This one is different: a changelog with teeth. Four problems shipped fixes this week, and each had a root cause worth writing down — the kind of thing that's invisible until a rebuild surfaces it. If you run these images, here's what changed and why.

## 1. OpenResty: 3.7 GB → 151 MB

The OpenResty image was **3.7 GB**. It should be ~150 MB. The build compiles OpenSSL, PCRE2, OpenResty and LuaRocks from source, then runs `apk del .build-deps` and `rm -rf` to clean up — so where did the bulk come from?

The cleanup ran in a *later* `RUN` layer than the one that added the build toolchain. In a Docker image, deleting a file in a later layer only writes a *whiteout* — the bytes still ship in the earlier layer. ~400 MB of compilers and headers were being "removed" into a tombstone and shipped anyway.

The fix is a multi-stage build: a `builder` stage compiles everything into `/usr/local`, and the final stage copies just that tree onto a clean base:

```dockerfile
FROM ${base} AS builder
# ... compile OpenSSL, PCRE2, OpenResty, LuaRocks into /usr/local ...

FROM ${base}
RUN apk add --no-cache gd geoip libgcc libxslt zlib perl
COPY --from=builder /usr/local /usr/local
```

One subtlety: LuaRocks installs to `/usr/local`, *not* `/usr/local/openresty`. Copying only the latter would silently drop the `luarocks` CLI. Copying all of `/usr/local` (empty on a fresh base) captures everything and nothing else.

**Result: 3.67 GB → 151 MB**, byte-for-byte the same runtime.

## 2. Healthchecks that reference a binary you don't ship

Two images had a `HEALTHCHECK` that could never pass — because the binary it called wasn't in the final image.

- **OpenResty** ran `curl -f http://localhost/nginx_status`. `curl` lived in the build deps and got removed; `/nginx_status` isn't in the stock config either. Fixed by probing `/` with BusyBox `wget` (already in the base) — no extra dependency.
- **PHP-FPM** ran the well-known `php-fpm-healthcheck` script, which needs `cgi-fcgi`. The `fcgi` package was never installed, so the probe aborted with exit 4 and the container was *permanently* `unhealthy`. One line — `apk add fcgi` — and the FPM status probe works (the `/status` endpoint was already configured).

The lesson is boring and universal: **a `HEALTHCHECK` is code too.** If it shells out to `curl`, `cgi-fcgi`, or anything else, that thing has to exist in the runtime image — not just the builder.

## 3. The OpenResty `resty` CLI needs Perl

While fixing the healthcheck, the bundled `resty` CLI turned up broken: `resty -e 'print(1+1)'` errored with `can't execute 'perl'`. `resty` is a Perl script, and Perl had gone out with the build deps. If you ship a tool, ship what it needs — `apk add perl`, and the CLI works again. (~42 MB; a debug CLI that can't run is worse than the size.)

## 4. PostgreSQL extensions: stop pinning the compiler

Every PostgreSQL extension build started failing:

```
apk add ... clang19 ... llvm19-dev
ERROR: unable to select packages: clang19 (no such package)
```

The extension Dockerfiles pinned `clang19`/`llvm19-dev`. But the `postgres:18-alpine` base had rolled forward to Alpine 3.24, which dropped `clang19` — and PostgreSQL's JIT now wants `clang-21`. The pin was frozen to a version the moving base no longer had.

Re-pinning to `clang21` would just set up the next break. PostgreSQL already records the exact compiler it expects, in PGXS's `Makefile.global`:

```
CLANG = clang-21
with_llvm = yes
```

So instead of pinning, **derive it from the base at build time**:

```dockerfile
RUN pg_clang_major="$(grep -oE 'clang-[0-9]+' \
        "$(dirname "$(pg_config --pgxs)")/../Makefile.global" | head -1 | grep -oE '[0-9]+')" \
    && apk add --no-cache "clang${pg_clang_major}" "llvm${pg_clang_major}-dev"
```

Now the JIT toolchain tracks whatever PostgreSQL itself was built against. When the base bumps to clang-22, the extensions follow automatically — no more "rebuilt six months later, now it's broken."

## The common thread

Three of these four are the same shape: **a value frozen at write-time that the world moved out from under** — a cleanup in the wrong layer, a healthcheck naming a binary that left, a compiler pinned to a version the base dropped. The durable fix is rarely "bump the number." It's "stop hardcoding the thing that drifts, and derive it from the source of truth."
