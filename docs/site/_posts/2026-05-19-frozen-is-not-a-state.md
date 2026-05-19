---
layout: post
title: "'Frozen' is not a state, it's a deferred decision"
description: "openresty:1.29.2.4-alpine was broken for six days — not a regression: the OpenSSL 1.1.1w tarball we had pinned simply stopped existing. A post-mortem of a deliberate freeze that rotted, the migration to OpenSSL 3.5 LTS, and the design flaw behind 'frozen'."
date: 2026-05-19 10:00:00 +0000
tags: [ci, openssl, openresty, dependencies, supply-chain, post-mortem, docker]
---

For about six days, `openresty:1.29.2.4-alpine` would not build. Nothing in this repository had changed to cause it — no commit touched the OpenSSL build, no version drifted. The build broke because a file we had pinned, on purpose, stopped existing on the internet. This is the account of how a deliberate, defensible decision turned into a latent failure, what we changed, and the part we have not fixed yet.

## The freeze that made sense at the time

On 2026-02-06, commit `437f8c7` introduced third-party dependency monitoring. As part of it, `openresty/config.yaml` declared OpenSSL out of scope for that monitoring:

```yaml
RESTY_OPENSSL_VERSION:
  monitor: false
  reason: "OpenSSL 1.1.1 is EOL, frozen"
RESTY_OPENSSL_PATCH_VERSION:
  monitor: false
  reason: "OpenSSL 1.1.1 is EOL, frozen"
```

This was not an oversight. OpenResty does not link the system OpenSSL; it compiles its own from source, and it requires a specific OpenResty patch (`sess_set_get_cb_yield`, which lets Lua coroutines yield inside session callbacks) applied per OpenSSL version. The Dockerfile's patch logic was branch-keyed:

```dockerfile
&& if [ $(echo ${RESTY_OPENSSL_VERSION} | cut -c 1-5) = "1.1.1" ] ; then ...
&& if [ $(echo ${RESTY_OPENSSL_VERSION} | cut -c 1-5) = "1.1.0" ] ; then ...
```

There was no `3.x` branch. Moving off 1.1.1 was therefore not a version-number bump: OpenSSL 3.x changed APIs, and OpenResty ships a *different* patch set for it. Pinning to the final 1.1.1 release (`1.1.1w`) and excluding it from automated bump PRs was the correct call to keep daily monitoring from proposing a change that could not be applied mechanically. The reasoning was sound. The state it created was not stable — it only looked stable.

## The day the source vanished

OpenSSL 1.1.1 reached end of life on 2023-09-11. Per its retention policy, openssl.org eventually removed the EOL source tarballs. The Dockerfile fetches OpenSSL from source:

```dockerfile
&& curl -fSL "${RESTY_OPENSSL_URL_BASE}/openssl-${RESTY_OPENSSL_VERSION}.tar.gz" ...
```

Once `openssl-1.1.1w.tar.gz` was gone, that `curl -fSL` returned HTTP 404, the `RUN` aborted, and every `openresty:1.29.2.4-alpine` build failed identically on `amd64` and `arm64`. It was the only never-built tag across all 13 containers — 78 of 79 tags healthy, this one a hard zero. Three upstream-monitor bump PRs (`#444`, `#451`, `#460`) tried and failed in turn over roughly six days before the cause was understood.

The important detail: the build did not fail because the version was *old* — it failed because the artifact *disappeared*. We had compiled `1.1.1w` successfully for months, and it remained buildable for over two years after its 2023 EOL; the build broke only on the day the tarball was removed. The trigger was not age; it was source availability — and we have the months of green builds on the same pinned version to show the difference is observed, not merely argued.

## "Frozen" meant "never look again"

`scripts/check-dependency-versions.sh` reads each dependency's `monitor` flag and skips the entry when it is `false`. The frozen OpenSSL entry existed purely to satisfy an invariant — every build arg must declare a source — while opting out of every check.

That is the design flaw, stated plainly: `monitor: false` conflated two different intentions — *"this is intentionally pinned, the source is stable"* and *"this branch is EOL and will need a manual migration someday"* — into one silent skip. There was no failure mode for *"a pinned dependency's upstream source has been removed."* The only mechanism that could have warned us — version monitoring — was, by the definition of the freeze, the mechanism we had turned off for exactly these dependencies. A freeze that suppresses its own alarm is not a freeze; it is a deferred decision with the reminder deleted.

## An LTS label is not a support runway

The migration target needed care, because the obvious choice would have re-created the same bug. OpenSSL's release strategy designates some series as LTS. As of this writing:

- **3.0** is LTS — and reaches EOL on **2026-09-07**, weeks away. Pinning to 3.0 would have set the identical trap with a months-long fuse.
- **3.5** is the current LTS, EOL **2030-04-08** — roughly four years of runway.
- **4.0** was rejected: OpenResty publishes no patch for it yet, and it carries only a one-year support window.

The pin we wanted was not "an LTS" — it was "the release with the longest *verified* runway." That distinction is the load-bearing one: an LTS label tells you a branch was designated long-term; it does not tell you how much of that term is left. The check that matters is the branch's own EOL date, not its tier name.

One thing de-risked the migration substantially: the official `openresty/docker-openresty` image already shipped exactly `RESTY_OPENSSL_VERSION=3.5.6` with `RESTY_OPENSSL_PATCH_VERSION=3.5.5` in production. An API-breaking dependency migration is normally a heavyweight change; an exact, authoritative upstream precedent let us treat it as a routine version-and-patch change — without dropping any of the quality gates (the pre-merge orthogonal review still ran twice, and acceptance was still proven on a real build, not asserted).

## The migration

`openresty/config.yaml`:

```yaml
RESTY_OPENSSL_VERSION: "3.5.6"          # was 1.1.1w
RESTY_OPENSSL_PATCH_VERSION: "3.5.5"    # was 1.1.1f
```

`openresty/Dockerfile` — the two dead 1.1.x patch branches were replaced by a single 3.x branch, mirroring upstream:

```dockerfile
&& if [ $(echo ${RESTY_OPENSSL_VERSION} | cut -c 1-2) = "3." ] ; then \
    echo 'patching OpenSSL 3.x for OpenResty' \
    && curl -s .../patches/openssl-${RESTY_OPENSSL_PATCH_VERSION}-sess_set_get_cb_yield.patch | patch -p1 ; \
fi \
```

Note what did *not* change: the `sess_set_get_cb_yield` patch is still required on OpenSSL 3.x. OpenResty still needs Lua coroutines to yield inside session callbacks; vanilla OpenSSL 3.x does not provide that. This was the reason the migration was never "mechanical" — and the reason a naive `monitor: true` that simply bumped the version would also have broken the build, just at the patch step instead of the download step. The `dependency_sources` reasons and the container README, which still asserted "OpenSSL 1.1.1 is EOL, frozen," were corrected in the same change — a build that has moved to 3.5 LTS should not ship documentation that says it is frozen on a dead branch.

Acceptance was not assumed. The post-merge master auto-build (run `26093082625`, success) shows `Build openresty (amd64)`, `Build openresty (arm64)`, and `Create Manifest openresty:1.29.2.4-alpine` all green: the tag that was a hard zero for six days now builds and pushes multi-arch.

## What we did not fix

This is where candour matters more than the fix.

The *incident* is closed. The *system* is not. `openresty/config.yaml` still carries `RESTY_PCRE_VERSION: "8.45"` with `monitor: false` and the reason "PCRE 8.x is legacy, frozen." PCRE 8.x ended life on 2023-12-31. It is the exact same shape of latent build-bomb as the OpenSSL pin was on 2026-02-06 — a from-source dependency frozen on an EOL branch whose tarball can be removed at any time. We pinned OpenSSL to a longer runway; we did not remove the *class* of bug.

The real fix is tracked, explicitly, in issue #453, and it is not done:

- Redesign `monitor: false` so a pin distinguishes "stable, intentionally pinned" from "EOL branch, migration required" — the latter must be *surfaced*, never silently skipped.
- Add a source-liveness check: for every pinned from-source dependency, a `HEAD` probe of the artifact URL that fails loudly *before* a build does, not six days after. The shape of the check #453 will add is small — what would have caught this on day zero is one line per pinned source:

  ```bash
  curl -fsI "${RESTY_OPENSSL_URL_BASE}/openssl-${RESTY_OPENSSL_VERSION}.tar.gz" \
    || { echo "::error::pinned source gone: openssl-${RESTY_OPENSSL_VERSION}.tar.gz (EOL artifact removed?)"; exit 1; }
  ```

  It is deliberately not in this change — wiring it across every declared source, in CI, with per-(dependency,container) issue creation, is the systemic work tracked in #453, not an urgent build-unblock. The point is that the missing safeguard is cheap; the reason it was missing was not cost, it was that `monitor: false` had no slot for "still pinned, but check it is still there."
- Auto-open a dedicated issue, one per (dependency, container), when a dependency bump causes a build failure — so the next occurrence is attributed and actionable, not a generic red run.

`monitor: false` was deliberately kept and PCRE deliberately left as-is in this change, because bundling the systemic redesign into an urgent build-unblock would have traded a fast, low-risk fix for a slow, broad one. That is a defensible sequencing decision — but only if it is said out loud, with the follow-up tracked, rather than left to rot the way the original freeze did. Saying "we'll get to it" without a tracked trigger is precisely the failure this post is about.

## Lessons

- **"Frozen" is a deferred decision, not a state.** A pin on an EOL branch carries an implicit "migrate before the source disappears." If that reminder is not recorded with a date and a trigger, the freeze has deleted its own alarm.
- **An LTS label is not a support runway.** Check the EOL date of the *specific* branch you are about to pin. An old LTS can have less remaining life than a current non-LTS.
- **A from-source pin needs source liveness, not just version monitoring.** Version monitoring answers "is there a newer release?" It does not answer "does the thing I pinned still exist?" Those are different questions; the second one is the one that broke this build.
- **The bug class is not OpenSSL-specific.** A dependency fetched at build time from an EOL branch is a latent failure in every ecosystem — a yanked PyPI release, a dropped Alpine apk, a Debian package moved to archive, a retracted Go module, an unpublished npm package, a pruned git tag. We captured it as a reusable engineering gotcha rather than a one-off note.
- **Fix the incident fast, but name the system you did not fix.** The migration unblocked the build in hours. The systemic redesign is harder and is still open. The honest deliverable is both the fix and the explicit, tracked admission of what the fix did not cover.

The build is green again. The reason it broke is not "OpenSSL 1.1.1 was old" — it is that we wrote `frozen` and treated it as a destination instead of a postponement. The follow-up that turns `frozen` into a tracked, liveness-checked decision is issue #453, and until it ships, PCRE 8.45 is sitting exactly where OpenSSL 1.1.1w was on the morning of the day its tarball disappeared.
