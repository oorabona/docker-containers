---
layout: post
title: "The e2e suite that never ran in CI"
description: "We had a container e2e test suite. It had not run in CI for months, and it had also stopped working entirely — it would have failed on its second line. Neither fact was visible, because nothing executed it. What it caught on the first real run is the point."
date: 2026-07-19 06:00:00 +0000
tags: [docker, ci, testing, github-actions, containers]
---

We had a container e2e test suite. It had not run in CI for months, and at some point it had stopped working entirely — it would have failed on its second line. Neither fact was visible, because nothing executed it. Wiring it back in was straightforward. What it caught on the first real run is the reason to write this down.

## The suite that was never wired in

The repository has `tests/e2e-test.sh`. It builds a container image, `docker run`s it, waits for the container to report healthy, and then runs a per-container `test.sh` smoke check inside it. For example, `openvpn/test.sh` asserts that every OpenVPN server process has dropped to the unprivileged `nobody` user with no capabilities — a regression lock for a security property, not a "does it start" check.

A grep of `.github/` for that script returns one hit: a shellcheck lint step. Nothing executes it. The per-container `bats` tests do run in CI, but only when a `run_tests` input is `true`, and it defaults to `false`, so ordinary pull-request builds never trigger them either.

The consequence is that any assertion added to the e2e layer passes review, merges, and then never runs. It reads as covered. It is not.

## It was also broken

Before wiring it in, running it once locally failed immediately:

```
tests/helpers/logging.sh: No such file or directory
```

The script computes its own directory and sources helpers relative to it:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers/logging.sh"
```

`SCRIPT_DIR` resolves to `tests/`, and there is no `tests/helpers/`. The helpers live at the repository root, in `helpers/`. Under `set -euo pipefail`, the missing source aborts the script on line 17, before it parses a single argument.

Git history explains it. A repository-cleanup commit had done `git mv e2e-test.sh tests/e2e-test.sh` with no change to the file's contents. Moving it one directory down broke every `SCRIPT_DIR`-relative path in it — including the one that looked for the per-container test at `tests/<container>/test.sh` instead of `<container>/test.sh`. The move was months old. Nothing had run the script since, so nothing reported the breakage.

## Why the unit tests were not enough

The suite has unit tests: `bats` over shell functions, plus per-container `bats` that stub `docker`. Those pass. They did not, and could not, catch what was broken, because the failures only exist when a real container boots on a real Docker daemon.

Two things made local verification unreliable. The `docker` command on the development machine is a Podman shim; its `--load`, capability, and user-namespace behavior differ from the Docker Engine on a GitHub-hosted runner. And a stubbed `docker` in a unit test returns whatever the stub is told to return — it never boots anything. The only faithful runtime for this layer is the CI runner.

## Wiring it in

One constraint shaped the design: on a pull request, the primary build path (bake) builds to cache only. It does not load the image into the local daemon, so there is nothing to `docker run`. The e2e job therefore builds its own loadable image with the existing build action and runs the harness against it.

The rest of the wiring:

- A per-container opt-in flag, `tests.e2e.enabled` in `variants.yaml`, surfaced as an output on the container-detection action, so a run is scoped to changed, eligible containers only.
- The job runs on non-fork pull requests. It boots images under elevated runtime options — OpenVPN needs `/dev/net/tun` and specific capabilities — which is not something to grant to code from an untrusted fork.
- A small aggregator job is the check that can be marked required. It passes on a real green run or a legitimate skip (a fork PR, or a PR that changed no eligible container) and fails only on an actual e2e failure. Without it, a required check that is skipped for a skipped job would leave unrelated pull requests waiting indefinitely.

The first increment covers four containers that already had tailored run profiles: openvpn, ansible, debian, sslh.

## What the first run caught

Three of the four passed. `sslh` failed, and the aggregator went red — the behavior the change exists to produce.

`sslh` had two latent problems, both invisible until a container actually booted.

First, the container came up `unhealthy` and was torn down. The image sets `ENTRYPOINT ["/usr/local/bin/sslh-ev"]`, so the run command is a list of *arguments*, not a fresh command line. The harness passed `sslh-ev --foreground -p 0.0.0.0:8443 …`, which runs `sslh-ev sslh-ev --foreground …` with a bogus first argument. Separately, the image's `HEALTHCHECK` probes port 443 while the run command listened on 8443, so even a correctly started daemon would never have become healthy. And the image runs as `nobody`, so binding 443 requires `NET_BIND_SERVICE`. The fix was to pass arguments only, listen on 443, and add the capability.

Second, once the container did become healthy, `sslh/test.sh` would have failed anyway. It checked for a running process with `pgrep`. The `sslh` image is built `FROM scratch` and copies only the sslh binaries and a static `busybox` — there is no `pgrep`, no shell, no `PATH`. The check now uses `/bin/busybox nc -z 127.0.0.1 443`, the same tool the image's healthcheck uses.

None of this was reachable from the unit tests. The run command is only exercised against a real image with a real entrypoint and a real healthcheck; the missing `pgrep` only matters when the command runs inside a scratch container.

## Where it stands

The suite runs on pull requests, scoped to changed containers, and blocks the PR when a container fails to boot or a smoke assertion fails. The four wired containers pass on the CI runner. The build action gained an option to read the shared registry cache without writing it, so a throwaway PR build cannot write into the canonical build cache. Postgres, and making the aggregator a formally enforced required check, are follow-ups.

The point is narrow. A test that does not run is not coverage, and a test that runs only against mocks is not coverage of the thing the mocks stand in for. The e2e layer had both problems at once, and neither showed up until it ran on the real runtime.
