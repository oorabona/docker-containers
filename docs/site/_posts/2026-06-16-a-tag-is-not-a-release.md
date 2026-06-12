---
layout: post
title: "A tag is not a release"
description: "A routine dependency bump turned every Terraform build red with a 404 — for a version that existed. The tag existed; the release didn't. The build had been asking Git for the latest tag when it should have been asking GitHub for the latest release."
date: 2026-06-16 06:00:00 +0000
tags: [ci, github-actions, docker, dependencies, supply-chain, lessons-learned]
---

A dependency-bump PR merged — a tool version baked into the Terraform image moved up a patch. The kind of change that builds itself. Minutes later every Terraform flavor was red at once: `base`, `aws`, `azure`, `gcp`, `full`, on both architectures. When one flavor fails, you suspect the flavor. When all of them fail in the same step, you suspect something they share.

## A 404 on a version that exists

The shared step installs the tooling layer into the image. The log:

```
#20 1.192 curl: (22) The requested URL returned error: 404
```

on:

```
https://github.com/aquasecurity/trivy/releases/download/v0.71.1/trivy_0.71.1_Linux-64bit.tar.gz
```

A bad version, then — probably a typo in the bump. Except `v0.71.1` wasn't a typo: the tag is real. And the version pinned in the image's config was `0.71.0`, which is also real. Two questions stacked up: where did `0.71.1` come from when the pin said `0.71.0`, and why does a real version 404?

I pasted both URLs into my own shell:

```
$ curl -sI -o /dev/null -w '%{http_code}\n' \
    .../releases/download/v0.71.1/trivy_0.71.1_Linux-64bit.tar.gz
404
$ curl -sI -o /dev/null -w '%{http_code}\n' \
    .../releases/download/v0.71.0/trivy_0.71.0_Linux-64bit.tar.gz
200
```

So the asset for `0.71.1` genuinely doesn't exist, and `0.71.0`'s does. This wasn't a transient blip — the build was asking for a file that was never published. Which sharpened the first question: the config pinned `0.71.0`, so why was the build downloading `0.71.1`?

## A tag is not a release

The image's build had a convenience I'd long stopped thinking about: before building, it re-resolved each bundled tool to its newest version and used that instead of the pin. The resolver was one line:

```bash
git ls-remote --tags https://github.com/aquasecurity/trivy.git \
  | grep -oE 'v[0-9]+(\.[0-9]+)+' | sort -V | tail -1
```

"Give me the highest version tag." That day it returned `v0.71.1`, which then quietly overwrote the pinned `0.71.0` for the rest of the build.

Here's what it handed back that I hadn't accounted for. `git ls-remote --tags` lists *every tag in the repository*. A tag is just a named pointer to a commit. It says nothing about whether a GitHub **release** was cut for it, and nothing about whether release **assets** — the actual `.tar.gz` you download — were ever uploaded. Upstream had pushed the `v0.71.1` tag ahead of publishing its release: the tag was live, the binaries weren't there yet, and by the time I looked there was still no release behind it. The build had grabbed the tag the moment it appeared and run straight at a download that didn't exist.

The releases API knew this the whole time:

```
$ curl -s https://api.github.com/repos/aquasecurity/trivy/releases/latest \
    | jq -r .tag_name
v0.71.0
```

`/releases/latest` returns the latest *published, non-draft, non-prerelease* release — the kind that has assets behind it. "Latest tag" and "latest release" are different questions, and that day they had different answers. My build asked Git for the latest tag; it should have been asking GitHub for the latest release. The tag existed. The release didn't.

## The fix: ask the right question

The re-resolution was redundant in the first place. The version was already pinned in config, and that pin is maintained by an automated monitor that *does* discover through the releases API — so a tag without a release never reaches the pin. The build had no reason to re-discover anything at build time; it just had to use the pin, the way every other image in the catalog already did. So I deleted the resolver and let the build read the pinned version.

If you genuinely need to resolve at build time — no pin, just a script — ask the endpoint that only knows about *published* releases instead of the one that knows about tags:

```bash
VERSION=$(curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" \
  https://api.github.com/repos/aquasecurity/trivy/releases/latest | jq -r .tag_name)
```

`/releases/latest` skips drafts, pre-releases, and tags-without-a-release by construction. Send the token even in CI: unauthenticated, this endpoint allows 60 requests an hour, and a matrix of tools × flavors × arches burns through that before lunch. (On GitLab or Gitea the endpoint differs, but the same split holds — ask for releases, not tags. If a forge has no notion of a release, that's your signal to pin and let a human or a monitor move the pin.)

I did consider a smaller patch: keep the resolver, but check that the release exists before building. I'm glad I didn't. Verifying that an asset exists and then downloading it are two separate moments, and anything can change between them — a release can be yanked, re-tagged, or have its assets replaced while your build is mid-flight. A pre-flight "does this file exist?" check is a guarantee with a shelf life of zero. The durable fix isn't to validate the artifact you're about to fetch; it's to bind on the thing that *carries* the artifact — a published release — and let the download be the only time you reach for the file.

## What I'd tell past-me

- **A tag is not a release.** `git ls-remote --tags` will hand you versions with nothing downloadable behind them. If you're going to fetch release assets, discover versions from the releases API, not from tags.
- **"Latest" is ambiguous.** Latest tag, latest release, latest published-with-assets release — these can disagree. Pick the one whose contract matches what you do next.
- **A 404 is not a flake.** `403` and `429` mean "come back later"; `404` means "this was never here." Retrying a 404 just fails more slowly — I had retries on that download, and they retried four times and 404'd four times.
- **Don't pre-validate the artifact you're about to fetch.** It's a race you can't win. Bind on the release; make the download the only fetch.
