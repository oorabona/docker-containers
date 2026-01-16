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

_Add new gotchas below as they are discovered._
