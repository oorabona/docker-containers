---
name: project-gotchas
description: Project-specific gotchas, workarounds, and common pitfalls
updated: 2026-01-16
---

# Project Gotchas

_Capture gotchas discovered while working on this project._
_Each gotcha should follow the format below._

---

## Format

### [Error/Issue Title] (YYYY-MM)

**Symptom:** _What you see / error message_

**Cause:** _Root cause explanation_

**Fix:**
```
_Solution code or steps_
```

**Prevention:** _How to avoid in the future (if applicable)_

---

## Gotchas

### Make script must run from project root (2026-01)

**Symptom:** `./make` fails with "source: not found" or path errors

**Cause:** The make script uses relative paths to source helper scripts

**Fix:**
```bash
# Always cd to project root first
cd /path/to/docker-containers
./make build <target>
```

**Prevention:** CLAUDE.local.md already has this rule: "Always return to the root directory to call make"

---

### Dashboard index.md is auto-generated (2026-01)

**Symptom:** Manual changes to `index.md` are overwritten

**Cause:** `generate-dashboard.sh` regenerates the file on schedule

**Fix:**
```bash
# Edit generate-dashboard.sh to change dashboard content
# Or edit _layouts/ and _includes/ for structure changes
```

**Prevention:** Add comment at top of index.md noting it's generated

---

### GitHub API rate limits (2026-01)

**Symptom:** Version discovery fails with 403 or empty responses

**Cause:** GitHub API has rate limits (60/hour unauthenticated)

**Fix:**
```bash
# Use authenticated requests in CI
curl -H "Authorization: token $GITHUB_TOKEN" ...
```

**Prevention:** Always use `$GITHUB_TOKEN` in workflows

---

### Secrets cannot be used in GitHub Actions if conditions (2026-01)

**Symptom:** Workflow fails with "workflow file issue" and 0s runtime

**Cause:** GitHub Actions doesn't allow `secrets` context in `if` conditions
```yaml
# WRONG - will cause parsing error
if: ${{ secrets.SOME_SECRET != '' }}
```

**Fix:**
```yaml
# CORRECT - use continue-on-error instead
- name: Optional step
  uses: some-action@v1
  with:
    secret: ${{ secrets.SOME_SECRET }}
  continue-on-error: true  # Will fail gracefully if secret missing
```

**Prevention:** Never use `secrets.*` in `if:` conditions. Use `continue-on-error` or environment variables for conditional logic.

---

### Docker Hub rate limits (2026-01)

**Symptom:** Build fails with "429 Too Many Requests" or "toomanyrequests"

**Cause:** Docker Hub limits pulls: 100/6h anonymous, 200/6h authenticated

**Fix:**
```yaml
# Cache base images to GHCR with multi-arch support
# Use buildx imagetools to preserve all platform manifests
docker buildx imagetools create \
  --tag ghcr.io/owner/postgres-base:17-alpine \
  docker.io/library/postgres:17-alpine

# Use cached images in Dockerfile
ARG BASE_IMAGE=ghcr.io/owner/postgres-base
FROM ${BASE_IMAGE}:${VERSION}
```

**Prevention:** Always cache frequently-pulled images to GHCR. Use `--build-arg BASE_IMAGE=postgres` for local builds.

---

### Multi-arch image copy requires buildx imagetools (2026-01)

**Symptom:** `exec format error` when running arm64 builds after caching images

**Cause:** `docker pull` + `docker tag` + `docker push` only copies single-platform image

**Fix:**
```bash
# WRONG - only copies current platform (usually amd64)
docker pull postgres:17-alpine
docker tag postgres:17-alpine ghcr.io/owner/postgres-base:17-alpine
docker push ghcr.io/owner/postgres-base:17-alpine

# CORRECT - copies full multi-arch manifest
docker buildx imagetools create \
  --tag ghcr.io/owner/postgres-base:17-alpine \
  docker.io/library/postgres:17-alpine
```

**Prevention:** Always use `docker buildx imagetools create` to copy images between registries when multi-arch support is needed.

---

## Gotcha: `set -euo pipefail` propagates from sourced files

**Discovered:** 2026-01-31
**Symptom:** Build silently exits after sourcing a helper. No error message, no stack trace.
**Root cause:** `helpers/variant-utils.sh` has `set -euo pipefail` at line 8. When sourced by `scripts/build-container.sh` (which is sourced by `make`), the `set -e` propagates to the entire shell. Any function returning non-zero (even as a "no match" signal) kills the script immediately.
**Example:** `resolve_major_version()` returned 1 when no version tag matched (e.g., terraform's `1.14.4-alpine` vs `latest` in variants.yaml). The function still echoed a valid fallback, but `set -e` terminated before `do_buildx` could use it.
**Fix:** Functions that return a valid result should `return 0`, not `return 1`. Reserve non-zero for actual failures.
**Prevention:** When writing shell functions in sourced files with `set -e`, use `return 0` for "success with fallback" and `return 1` only for hard failures. Test with `bash -x` to trace silent exits.

---

## `gh pr checks --fail-cycle` doesn't exist (2026-01)

**Symptom:** `unknown flag: --fail-cycle` in GitHub Actions workflow

**Cause:** `gh pr checks` only supports `--watch`, `--fail-fast`, and `--interval`. There is no built-in timeout flag.

**Fix:**
```bash
# Use timeout command wrapper instead
MERGE_TIMEOUT=300
if timeout "$MERGE_TIMEOUT" gh pr checks "$PR_NUMBER" --watch; then
  gh pr merge "$PR_NUMBER" --squash
else
  exit_code=$?
  if [ "$exit_code" -eq 124 ]; then
    echo "::warning::CI checks timed out"
  else
    echo "::warning::CI checks failed"
  fi
fi
```

**Prevention:** Always verify CLI flags with `gh <command> --help` before using them in workflows. Don't trust LLM-generated flag names.

---

_Add new gotchas below as they are discovered._
