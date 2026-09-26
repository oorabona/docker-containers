---
layout: post
title: "The precise PostgreSQL tags that stopped shipping"
description: "From June to September, the postgres image published only its major tags. 18-alpine kept working, so nothing looked broken. How the gap was found, why the rule meant to keep old precise tags protected none of them, and how the cleanup that followed was run."
date: 2026-09-27 06:00:00 +0000
tags: [docker, postgresql, ci, registry, ghcr, docker-hub]
---

The postgres image publishes two kinds of tags per flavor: a major tag such as `18-alpine-vector`, which moves with every minor release, and a precise tag such as `18.6-alpine-vector`, which stays on one minor release. From 2026-06-10 to 2026-09-25, the build published only the first kind. Anyone who pulled the major tag got current images. Anyone who pinned a precise tag stayed on 18.3, 17.9 or 16.13, the last precise tags pushed on 2026-05-13.

| Date | Event |
|---|---|
| 2026-05-13 | Last precise tags published: `18.3-alpine*`, `17.9-alpine*`, `16.13-alpine*` |
| 2026-06-10 | The postgres final image moves to Docker Bake (#707); precise tags stop |
| 2026-09-25 | Found while planning the Docker Hub tag cleanup |
| 2026-09-25 | Precise tags published again (#1975): `18.6`, `17.11`, `16.15` |
| 2026-09-25 | Retention rule fixed so superseded precise tags are kept (#1976) |

## How the tags were lost

Before June, each postgres cell was built by a per-image job that computed the precise version and passed it to the manifest step, which added the precise tag next to the major one.

The move to Bake (#707) replaced that job with one Bake invocation per architecture and a merge step that assembles the multi-arch manifests. The plan that feeds Bake is produced by `list_build_matrix`, and Bake called it without the upstream version. The `full_version` field it returned was empty for every postgres cell. The merge step only adds a precise tag when that field is set, so it added none, and it did not report the absence.

Every check still passed. The major tags were pushed, the images ran, the e2e suite tested `18-alpine-full`, and the dashboard listed the major tags. Nothing in the pipeline asserted that a precise tag existed.

## How it was found

The trigger was unrelated work: deleting obsolete tags from Docker Hub. The rule for that cleanup takes GHCR as the source of truth. A Docker Hub tag is a deletion candidate only if no current build declares its name and its digest matches no tagged image on GHCR.

The first read-only plan put postgres precise tags such as `18.3-alpine` among the candidates, because no current build declared them. Postgres was held out of the Docker Hub cleanup until the question was answered. Reading the Bake plan for a postgres cell showed an empty `full_version`, and the call that dropped it came from #707.

## Publishing them again

#1975 takes the precise version from the upstream version detector's plan and passes it to Bake. Before adding a precise alias, the merge step reads `PG_VERSION` from the built image on both architectures and refuses the alias if either disagrees with the plan. The Docker Hub mirror now copies only the tags the merge step approved.

After the next build, `18.6-alpine`, `17.11-alpine` and `16.15-alpine` and their flavors existed on GHCR and Docker Hub, each on the same digest as its major tag.

## The rule that protected nothing

With precise tags back, the cleanup needed a retention rule: a superseded precise tag such as `17.9-alpine` stays as long as its major version is still declared. The first version of that rule, in #1975, derived the set of declared majors from the `.tag` field of each build record, keeping values that are a bare number.

`make list-builds postgres` emits records like this one:

```json
{"tag": "16-alpine", "version": "16", "variant": "vector"}
```

No `.tag` is a bare number, so the set was always empty and the rule protected no tag. The unit tests passed because their fixtures used an unrealistic `"tag": "16"`. Nothing had been deleted yet: GHCR only held current precise tags, and postgres was still excluded from the Docker Hub cleanup. The next minor release would have removed the previous one.

#1976 reads `.version` instead, and its tests use records copied from real `make list-builds` output. Run against real postgres data, the rule keeps `16.13-alpine-vector`, `17.9-alpine` and `18.3-alpine-full`, and still selects `16-full-alpine` (an old naming scheme) and `15.9-alpine` (a retired major) for deletion.

## Running the cleanup

The first deletion run for postgres was dispatched by hand, after a dry run of the same filter.

| Registry | Dry run | Real run |
|---|---|---|
| Docker Hub | 36 candidates, all old naming (`16-full-alpine`, `18-arm64`, ...); 109 kept | 36 deleted, 0 failures |
| GHCR | 190 kept, 0 obsolete, 357 orphans | 357 orphans deleted, 0 failures |

The GHCR postgres package went from about 4,400 versions on the morning of 2026-09-25 to 547 after the daily runs, and to 190 after this one. The 84 untagged versions left are the architecture manifests and attestations of tagged images. After the run, `16.15-alpine`, `17.11-alpine-vector`, `18.6-alpine-full` and `18-alpine` were checked on both registries.

## What changed

- Bake passes the precise version, and the merge step checks it against `PG_VERSION` in the image before tagging (#1975).
- The retention rule reads the declared version, with tests built from real records (#1976).
- Postgres is back in the daily Docker Hub cleanup.

The gap lasted three and a half months: every check in the pipeline tested an image that ran, and no check tested that a precise tag was published. The precise alias now depends on a version read from the image itself.
