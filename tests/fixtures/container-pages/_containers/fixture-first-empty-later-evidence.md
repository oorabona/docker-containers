---
layout: container-detail
name: fixture-first-empty-later-evidence
current_version: current-without-variant
current_version_confirmed: true
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
      - name: sibling
        tag: retained-evidence-sibling
        attestation_url: https://example.test/attestations/retained-evidence-sibling
        attestation_id: retained-evidence-sibling-attestation
        trivy_summary:
          display_source: code-scanning
          as_of: "2026-09-11"
          counts:
            critical: 1
            high: 0
            medium: 2
            low: 3
            info: 4
          top_advisories: []
---
# Fixture: selected later evidenced variant
