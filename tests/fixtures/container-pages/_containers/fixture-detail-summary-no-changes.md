---
layout: container-detail
name: fixture-detail-summary-no-changes
current_version: summary-no-changes-alpine
current_version_confirmed: true
github_username: fixture-owner
dockerhub_username: fixture-owner
has_variants: true
build_digest: per-variant
versions:
  - tag: summary-no-changes
    base_tag: summary-no-changes
    variants:
      - name: alpine
        tag: summary-no-changes-alpine
        sbom_summary:
          apk: 1
          total: 1
        changelog:
          generated_at: "2026-09-26T10:00:00Z"
          summary:
            added: 0
            removed: 0
            updated: 0
          changes: []
        build_history:
          - built_at: "2026-09-26T10:00:00Z"
            version: summary-no-changes-alpine
            build_digest: sha256:3b56ba6ead9da693b67297de02170d9241656e92321502f106752bf37e70b16c
            packages_total: 1
---
# Fixture: detail summary with no package changes
