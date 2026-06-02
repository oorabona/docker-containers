# .githooks

Local Git hooks committed to the repository.

## `pre-commit` — actionlint workflow gate

Runs [`actionlint`](https://github.com/rhysd/actionlint) on any staged
`.github/workflows/*.{yaml,yml}` files before a commit is recorded. Gives
instant (~1 s) feedback on workflow grammar errors — the same class of bugs
that cause GitHub Actions "startup_failure" at parse time.

Behavior:

| Situation | Outcome |
|-----------|---------|
| No workflow files staged | Exits silently (0 ms overhead) |
| `actionlint` not on PATH | Prints a yellow warning, exits 0 — commit proceeds |
| `actionlint` finds errors | Prints findings, exits 1 — commit blocked |
| `actionlint` reports clean | Prints one success line, exits 0 |

**This hook is a complement, not a replacement, for the `Actionlint` CI job.**
Because hooks are opt-in per clone, bypassable with `--no-verify`, and never
run for bot PRs, the CI job remains the authoritative enforcement gate.

---

## Activation

Hooks committed to `.githooks/` require a one-time opt-in per clone:

```bash
git config core.hooksPath .githooks
```

This redirects Git to look in `.githooks/` instead of `.git/hooks/`.
Only `pre-commit` exists here, so no other hooks are affected.

---

## Installing actionlint

See the official install guide:
<https://github.com/rhysd/actionlint/blob/main/docs/install.md>

Quick options:

```bash
# Homebrew (macOS / Linux)
brew install actionlint

# Go install
go install github.com/rhysd/actionlint/cmd/actionlint@latest

# Script (Linux/macOS, installs to current directory)
bash <(curl https://raw.githubusercontent.com/rhysd/actionlint/main/scripts/download-actionlint.bash)
```

---

## Emergency bypass

```bash
git commit --no-verify
```

The CI `Actionlint` job will still run on the PR or push and will block
merge if workflows contain errors.
