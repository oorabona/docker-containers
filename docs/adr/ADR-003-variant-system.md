# ADR-003: Declarative Variant System via variants.yaml

**Status:** Accepted
**Date:** 2026-01-31

## Context

Some containers (postgres, terraform) need multiple variants (e.g., postgres: base, vector, analytics, timeseries, full). Initially each variant had its own Dockerfile, leading to duplication and maintenance burden.

## Decision

Use a single Dockerfile with build-arg-driven variants, configured declaratively via `variants.yaml`:

```yaml
base_suffix: "-alpine"
variants:
  vector:
    flavor: vector
    description: "PostgreSQL with pgvector"
  full:
    flavor: full
    description: "PostgreSQL with all extensions"
```

The variant system (`helpers/variant-utils.sh`) provides:
- `list_variants()` — Enumerate variants for a container
- `variant_image_tag()` — Compute output tag (e.g., `17-alpine-full`)
- `variant_property()` — Read arbitrary variant properties

## Consequences

- **Single Dockerfile**: One file per container, variants via `FLAVOR` build arg
- **Declarative config**: Adding a variant is a YAML change, not a Dockerfile change
- **CI integration**: `auto-build.yaml` iterates variants automatically
- **Dashboard**: `generate-dashboard.sh` renders per-variant build status
- **Constraint**: All variants must share the same base Dockerfile structure
