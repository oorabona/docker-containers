---
layout: container-detail
name: fixture-detail-summary-metrics
current_version: summary-metrics-alpine
current_version_confirmed: true
github_username: fixture-owner
dockerhub_username: fixture-owner
has_variants: true
build_digest: per-variant
versions:
  - tag: summary-metrics
    base_tag: summary-metrics
    variants:
      - name: alpine
        tag: summary-metrics-alpine
        build_digest: sha256:1b56ba6ead9da693b67297de02170d9241656e92321502f106752bf37e70b16c
        sbom_summary:
          apk: 52
          generic: 2
          oci: 1
          total: 55
        changelog:
          generated_at: "2026-09-26T10:00:00Z"
          summary:
            added: 2
            removed: 1
            updated: 3
          changes:
            - type: added
              name: added-package-one
              version: 1.0.0
            - type: added
              name: added-package-two
              version: 2.0.0
            - type: removed
              name: removed-package
              version: 3.0.0
            - type: updated
              name: updated-package-one
              from: 1.0.0
              to: 1.1.0
            - type: updated
              name: updated-package-two
              from: 2.0.0
              to: 2.1.0
            - type: updated
              name: updated-package-three
              from: 3.0.0
              to: 3.1.0
        build_history:
          - built_at: "2026-09-26T10:00:00Z"
            version: summary-metrics-alpine
            build_digest: sha256:1b56ba6ead9da693b67297de02170d9241656e92321502f106752bf37e70b16c
            packages_total: 55
          - built_at: "2026-09-25T10:00:00Z"
            version: summary-metrics-alpine
            build_digest: sha256:2b56ba6ead9da693b67297de02170d9241656e92321502f106752bf37e70b16c
            packages_total: 54
---
# Fixture: detail summary metrics
