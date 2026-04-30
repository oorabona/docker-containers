---
name: Bug report
about: Something visible is broken or behaving unexpectedly
title: "fix(<scope>): "
labels: bug
---

<!--
Title format: fix(<scope>): <short summary>
Scope examples: dashboard, ci, postgres, terraform, web-shell, github-runner, blog
Add a scope label too (postgres, terraform, ci-related, etc.) so /next can rank it.
-->

## Symptom

What's visible / broken from a user-facing perspective. Include the URL, the container, or the workflow that surfaces the bug.

## Reproduction

<!--
For container-runtime bugs, fill these inline (delete what doesn't apply):
  **Image tag:**    e.g. `ghcr.io/oorabona/postgres:18-alpine-vector`
  **Host:**         e.g. Docker 27.5 on Ubuntu 24.04 / WSL2
For CI bugs:
  **Workflow run:** e.g. https://github.com/oorabona/docker-containers/actions/runs/...
For dashboard / docs bugs:
  **URL + browser:** e.g. https://oorabona.github.io/docker-containers/ on Firefox 132
-->

Steps to observe the bug. Reference exact commit SHA, branch, image tag, or live URL.

```
1.
2.
3.
```

## Expected vs actual

- Expected: …
- Actual: …

## Root cause (if known)

1–3 lines linking to the offending file/line. If unknown, leave blank — the maintainer (or an automated triage agent) will fill this during investigation.

## Acceptance

A concrete, observable check that proves the bug is fixed. e.g. *"the X badge shows `🏗 amd64 + arm64` after clicking a variant tag on the postgres card"*.

## Related

PRs, commits, sibling issues, ADRs, or memory snapshots that contextualize this bug. Use `#N` for sibling issues, full URL for external refs.

## Logs / output (optional)

<details>
<summary>Click to expand</summary>

```
<!-- paste error logs, stack traces, container output here -->
```

</details>
