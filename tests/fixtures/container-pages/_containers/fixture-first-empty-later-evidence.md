---
layout: container-detail
name: fixture-first-empty-later-evidence
current_version: current-without-variant
current_version_confirmed: false
github_username: fixture-owner
dockerhub_username: fixture-owner
has_variants: true
versions:
  - tag: current-without-variant
    base_tag: current-without-variant
    variants: []
  - tag: retained-evidence
    base_tag: retained-evidence
    variants:
      - name: alpine
        tag: retained-evidence-alpine
        trivy_summary:
          display_source: scan-record
          as_of: "2026-09-12"
          counts:
            critical: 0
            high: 1
            medium: 0
            low: 0
            info: 0
          top_advisories: []
---
# Fixture: selected later evidenced variant
