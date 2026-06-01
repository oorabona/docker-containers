---
layout: post
title: "Turning on arm64 found three bugs. None of them were about arm64."
description: "Shipping a Postgres extension feature and enabling arm64 surfaced three latent bugs — a workflow that wouldn't compile, a build that only worked from cache, and an amd64-only compiler flag — that a clean review, green tests, and CodeQL all missed."
date: 2026-06-01 10:00:00 +0000
tags: [postgres, arm64, multi-arch, docker, github-actions, buildkit, ci, lessons-learned]
---

I maintain a small fleet of custom container images that track their upstream releases automatically. Last week I shipped a feature into the [PostgreSQL one](/docker-containers/container/postgres/): per-major TimescaleDB version retention. The problem it solves is narrow and nasty. TimescaleDB's loader `dlopen`s the *exact* `timescaledb-<version>.so` recorded in a database's catalog, so the day you bump the extension, every persisted volume created on the old version refuses to start — `FATAL: could not access file`. The fix is to ship a window of recent `.so` files in the image, not just the current one.

The feature itself went smoothly. It passed review, the tests were green, I merged it. Then the first real CI build — a full multi-arch build-and-push on `master` — went red.

It stayed red for three rounds. Not once was the feature the problem.

## Bug #1: the workflow that never ran

The first red build had no failing job. It had *no jobs at all* — a run marked "failure" with an empty job list, and, weirder, a `push`-event run on a branch the `push` trigger explicitly excludes.

That shape is a GitHub Actions **startup_failure**: the workflow file didn't *compile*, so nothing got scheduled. The cause was one line I'd added to a job:

```yaml
env:
  REBUILD: ${{ env.REBUILD_MODE }}
```

The `env` context isn't available inside a job-level `env:` block — the block is what *defines* `env`, so it can't reference itself. GitHub couldn't evaluate the expression, refused to compile the workflow, and — this is the part that cost me an hour — the `pull_request` build *silently never ran*. The only trace was a phantom red X on an unrelated event.

Here's the uncomfortable bit: the diff had been reviewed and looked fine, the tests were green, and CodeQL's "Analyze (actions)" job passed. None of them catch a workflow that won't compile, because none of them *run* it — they read the diff. `actionlint`, run locally, found it in about a second:

```
auto-build.yaml:763:20: context "env" is not allowed here.
available contexts are "github", "inputs", "matrix", "needs", "secrets", "strategy", "vars"
```

A build that never ran is not a passing build. And the fix that matters isn't finding it once — it's making `actionlint` a gate, so a workflow that won't compile can't masquerade as "no failures" ever again.

## Bug #2: postgis "compiled" — from a cache

With the workflow compiling, the build got far enough to actually build extensions. postgis died:

```
No yacc found, cannot build parser
make[1]: *** [Makefile:238: lwin_wkt_parse.c] Error 1
```

postgis builds from a git checkout — `git clone --branch <ver> && ./autogen.sh` — and a checkout doesn't ship the generated WKT parser the way a release tarball does. You need `yacc` (bison) to regenerate it. Except `bison` was nowhere in postgis's build dependencies, and `git log -S bison` proved it had *never* been there.

So how had postgis ever built?

This was the *Unforeseen Consequences* moment — pull one innocuous lever and the cascade that follows has nothing to do with the lever you pulled. (Half-Life fans know the chapter.) Because the published image already existed — the registry had it, with a build date:

```
$ gh api .../packages/container/ext-postgis/versions   # list published tags
pg17-3.6.3      # built 2026-04-29
pg18-3.6.3      # built 2026-05-15
```

postgis 3.6.3 had built fine back in April. My code never touched postgis. What changed was the *substrate*: the `postgres:alpine` base image it builds `FROM` had been rebased since — by my own drift detection, a job that rebases the base when its upstream digest moves — and the new base quietly stopped carrying `yacc` transitively. Nothing I wrote broke. The ground under the build moved.

You can't foresee an upstream behaviour change. You can only stop *depending* on luck — declare what you actually need instead of inheriting it by accident:

```yaml
build_deps:
  - build-base
  - bison   # yacc — regenerates the WKT parser
  - flex    # lex
  - geos-dev
  # ...
```

## Bug #3: pgvector was amd64-only the whole time

Next red, on the arm64 leg only:

```
pgvector 0.8.2 (arm64): make OPTFLAGS="-march=x86-64-v2 -O3" … exit code 2
```

`-march=x86-64-v2` is an x86-64-only microarchitecture level. gcc on arm64 takes one look and quits. pgvector had hardcoded it for *years* — and it had never mattered, because we'd never built arm64. A latent bug with no trigger.

Now it had one. buildx hands you `TARGETARCH` for free, so pick the baseline per target:

```dockerfile
ARG TARGETARCH
RUN case "${TARGETARCH}" in \
      amd64) OPTFLAGS="-march=x86-64-v2 -O3" ;; \
      arm64) OPTFLAGS="-march=armv8-a -O3" ;; \
      *)     OPTFLAGS="-O3" ;; \
    esac && \
    make OPTFLAGS="$OPTFLAGS" PG_CONFIG=/usr/local/bin/pg_config && \
    make install DESTDIR=/install
```

## The one change that lit it all up

Step back: none of the three were the feature. Its logic was fine. What set them all off was a single, boring infrastructure detail buried inside it — to support multi-arch, the per-version extension images gained a `-amd64` / `-arm64` tag suffix. That changed the build-cache key. Every existing cache missed. Every extension rebuilt **cold**, many for the first time in months.

Cold builds are where latent debt lives. The cache had been answering "does it build?" with "here's a layer from the last time it did" — a different question. Bust the cache and add a second architecture, and you've effectively run a fuzzer over every assumption your build has ever made: every `-march`, every dependency inherited by luck, every "works on our runner."

## What I'd tell past-me

- **A green pipeline can lie about reproducibility.** "It builds" sometimes means "it builds from a cache seeded under conditions that no longer exist." Bust the cache on purpose, on a schedule.
- **Lint your workflows.** One that fails to compile produces a build that never runs — and that reads as "no failures," not "failure." `actionlint` is a second well spent.
- **A second architecture is the cheapest fuzzer you'll ever run.** It votes on every hidden assumption at once.
- **Declare your dependencies; don't inherit them.** Transitive base-image deps are regressions on a delay fuse — the day the base rebases, they go off.
- **Staying current cuts both ways.** The same drift detection that keeps the base fresh is what pulled `yacc` out from under postgis. Worth it — but plan for it. My follow-up is a guard that asserts the published version matches the declared one, so the next substrate shift can't pass quietly.

Three commits later the build went green — every flavour, both architectures, all the way through to the multi-arch manifests. None of these bugs were about arm64. arm64 just turned the lights on.

## Postscript: it un-bricked a real database

The feature under all this — shipping a *window* of retained TimescaleDB `.so` files instead of just the current one — wasn't abstract. A Postgres container of mine had been half-dead for weeks: the volume's catalog recorded TimescaleDB **2.25.2**, the image had long since moved to **2.27.1**, and every query touching the extension died with `could not access file "timescaledb-2.25.2"`. The server reported *healthy* the entire time — its healthcheck only runs `pg_isready`, which never loads the extension.

The fix was undramatic, which is the point. Pull the new image (it now ships 2.23.1 through 2.27.1 side by side), recreate the container against the **same volume** — the backend found the exact `.so` its catalog asked for, the extension loaded, and a single `ALTER EXTENSION timescaledb UPDATE` walked it up to 2.27.1. Same data, no dump/restore, no surgery.

That's the whole detour paying for itself: three bugs surfaced on the way to shipping it, none of them about arm64 — and at the end, a database that had been stuck for weeks just came back.
