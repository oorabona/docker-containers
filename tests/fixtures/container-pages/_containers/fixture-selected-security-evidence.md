---
layout: container-detail
name: fixture-selected-security-evidence
current_version: selected-evidence-alpine
current_version_confirmed: false
github_username: fixture-owner
dockerhub_username: fixture-owner
has_variants: true
versions:
  - tag: selected-evidence
    base_tag: selected-evidence
    variants:
      - name: alpine
        tag: selected-evidence-alpine
        trivy_summary:
          display_source: code-scanning
          as_of: "2026-09-12"
          counts:
            critical: 0
            high: 0
            medium: 0
            low: 0
            info: 0
          top_advisories: []
      - name: sibling
        tag: selected-evidence-sibling
        attestation_url: https://example.test/attestations/selected-evidence-sibling
        attestation_id: selected-evidence-sibling-attestation
        trivy_summary:
          display_source: scan-record
          as_of: "2026-09-11"
          counts:
            critical: 1
            high: 2
            medium: 3
            low: 4
            info: 5
          top_advisories: []
---
# Fixture: selected evidenced variant
