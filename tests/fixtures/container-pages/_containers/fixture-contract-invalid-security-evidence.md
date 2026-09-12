---
layout: container-detail
name: fixture-contract-invalid-security-evidence
current_version: bogus-source-alpine
current_version_confirmed: false
github_username: fixture-owner
dockerhub_username: fixture-owner
has_variants: true
versions:
  - tag: bogus-source
    base_tag: bogus-source
    variants:
      - name: alpine
        tag: bogus-source-alpine
        attestation_url: https://example.test/attestations/bogus-source-alpine
        attestation_id: bogus-source-alpine-attestation
        trivy_summary:
          display_source: bogus
          as_of: "2026-09-10"
          counts:
            critical: 9
            high: 8
            medium: 7
            low: 6
            info: 5
          top_advisories: []
---
# Fixture: contract-invalid security evidence
