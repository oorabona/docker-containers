---
layout: post
title: "Field notes: a golden test, an empty digest, OpenTofu, and a root check"
description: "Four fixes from late September: a test that blocked every version bump, a dashboard metric that always read sha256:, a new OpenTofu image and why it has its own directory, and an e2e rule that refuses root images."
date: 2026-09-30 06:00:00 +0000
tags: [docker, ci, testing, dashboard, opentofu, terraform, security]
---

Four changes from the last week of September, each with the cause behind it.

| Change | Symptom | Cause | PR |
|---|---|---|---|
| Digest pin test | Every terraform and postgres bump PR failed `unit-tests` | The test read live container files | #1977 |
| Dashboard metrics | Build lineage showed `sha256:` with no value | A 7-character slice of a prefixed digest | #1982 |
| OpenTofu image | New container | The binary is not on Docker Hub; detection is per directory | #1979 |
| Runtime user rule | jekyll ran as root | No check read the image's user | #1985 |

## 1. A golden test that read live inputs

When the `yq` fallback was removed from the build digest code on 2026-09-20, a test was added to prove the serialization had not changed: it computed the digest of seven postgres flavors and five terraform flavors and compared each with a value recorded that day.

It computed them from `postgres/` and `terraform/` as they are in the checkout. The next terraform release changed `terraform/variants.yaml`, the digest changed, and the test failed. So did every dependency bump for either container. Four update PRs (#1946, #1930, #1948, #1926) sat with a red `unit-tests`, and the dashboard showed terraform one version behind.

The fix copies the files the digest reads, as they were at the recording commit, into `tests/fixtures/build-digest/`, and points the test there. Computing the digests on that tree reproduces all twelve values. The test now passes after a bump of the live `terraform/config.yaml` and fails after the same edit to the fixture. It also clears `CUSTOM_BUILD_ARGS` and `DIGEST_DEBUG`, which otherwise change the result.

A golden value checks one input. When the input is a file that other automation edits, the test has to own a copy of it.

## 2. The digest that always read `sha256:`

Each container page has four collapsible sections with a short metric in their title. On all fifteen pages:

- Build lineage showed `sha256:` and nothing else.
- Package summary and Recent changes showed `n/a — runtime parsed`.
- Build history showed `n/a — runtime fetched`.

The lineage metric was `build_digest | slice: 0, 7`, written when digests were stored without their prefix. Digests are now stored as `sha256:<hex>`, so the first seven characters are the prefix. The three `n/a` strings came from a layout refactor and were never replaced: the page script fills the section bodies and never touches the titles.

The data was on every page already, per variant. The titles now show the first 12 hex characters of the digest, the package count, `+added −removed ~updated`, and the build count. Each is hidden when its section has no data, and updated when another variant is selected. The rendered-site check run at deploy fails if a page shows an `n/a — runtime` string or a bare `sha256:`.

## 3. OpenTofu, and why it has its own directory

The new `opentofu` image carries the same tools as `terraform` (TFLint, Trivy, Terragrunt, terraform-docs, Infracost, the GitHub CLI and the cloud CLIs) in the same five flavors, with `tofu` instead of `terraform`.

Sharing one Dockerfile between the two looked cheaper. Build detection rules it out: a changed path is mapped to a container by its first segment (`container="${file%%/*}"`), so a Dockerfile in `terraform/` symlinked from `opentofu/` rebuilds only terraform when it changes, and a file under a shared directory rebuilds neither. With its own directory, `version.sh` and `dependency_sources`, an OpenTofu release changes `opentofu/` only and rebuilds only that image. The cost is a duplicated Dockerfile.

OpenTofu publishes no image on Docker Hub, and the base-image mirror syncs from Docker Hub only. The binary therefore comes from the release tarball for the build architecture. The build fails unless the release's `SHA256SUMS` holds exactly one line for that file and its hash matches. Terragrunt runs `tofu` through `TG_TF_PATH=tofu`. The first build published `1.12.6-alpine` and its four flavors on GHCR and Docker Hub.

## 4. A rule for the image user

A census of the fifteen images found five whose effective user is root. Four are deliberate:

- postgres: the upstream entrypoint drops to `postgres`.
- github-runner: starts as root to fix volume ownership, then `exec gosu runner`.
- openvpn: needs root for network setup, then drops to `nobody`.
- web-shell: a root supervisor for `sshd`, with the shell running as the shell user.

The fifth was jekyll, which ran as root and wrote `_site/` and `.jekyll-cache/` into the mounted source as root.

jekyll now runs as `jekyll` (uid 1000). `HOME` and Bundler state live in `/tmp`, so an arbitrary `--user` uid without a passwd entry also works, and the compose file takes `LOCAL_UID`/`LOCAL_GID` so generated files belong to the host user.

The e2e harness now reads `.Config.User` from each image it tests and fails on root (empty, `root`, or any decimal spelling of 0) unless the container is one of the four above. Run against the previously published jekyll image, it failed with `jekyll image has root effective user`.

Compose capabilities, `no-new-privileges` and read-only root filesystems stay per deployment profile. The compose files are documentation, and several containers document their runtime in `examples/`, so a repository-wide rule on them would check files no test runs.

## Where it stands

All four changes are merged. The decision behind the fourth is recorded in `docs/decisions.md` under "Runtime user baseline".
