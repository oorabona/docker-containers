#!/usr/bin/env bash
# lineage-utils.sh — Shared predicates and helpers for .build-lineage/*.json files.
#
# Single source of truth for identifying lineage sidecar files so that all
# consumers (enrich-lineage.sh, detect-base-digest-drift.sh, etc.) agree on
# which files to skip.
#
# Usage (source this file):
#   source helpers/lineage-utils.sh
#
# Then use:
#   is_lineage_sidecar "foo-1.0-alpine.sbom.json"  # returns 0 (true) for sidecars

# ---------------------------------------------------------------------------
# is_lineage_sidecar <basename>
#
# Returns 0 (true) if the given filename is a lineage sidecar that should be
# skipped by consumers walking .build-lineage/*.json.
#
# Sidecar patterns:
#   *.sbom.json       — SPDX SBOM data (anchore/syft output)
#   *.changelog.json  — package delta between consecutive builds
#   *.history.json    — monotonic build history log
#   ext-*.json        — per-extension lineage fragments (merged into main entry)
#
# Usage:
#   if is_lineage_sidecar "$basename"; then continue; fi
# ---------------------------------------------------------------------------
is_lineage_sidecar() {
    local f="${1:-}"
    case "$f" in
        *.sbom.json|*.changelog.json|*.history.json) return 0 ;;
        ext-*.json) return 0 ;;
        *) return 1 ;;
    esac
}
