# ADR-008: Trivy Severity Policy — Option C (Full Scan, All Severities, CRITICAL = Actionable)

**Status:** Accepted
**Date:** 2026-05-07

## Context

Phase B (PR #329, Apr 2026) shipped the trust-strip data pipeline including Trivy scan history.
The pipeline was wired with `vulnerability_severity: CRITICAL` — scanning only CRITICAL findings,
uploading only CRITICAL findings to SARIF, and writing a side-channel file that set only
`counts.critical` from `alert_count`.

Meanwhile, the dashboard detail page (`docs/site/_layouts/container-detail.html`) renders a
**5-cell severity grid** (CRITICAL / HIGH / MEDIUM / LOW / INFO), a design decision established
in ADR-007 (Phase C trust-strip identity) to serve persona Camille (AppSec engineer — primary
persona, screenshots the trust-strip into Confluence to justify org-wide image adoption).

The structural mismatch: the CRITICAL-only pipeline made the 4 non-critical cells permanently
zero. The docs (`docs/site/verify-images.md:55-64`, `docs/GITHUB_ACTIONS.md:340`) stated the
CRITICAL-only policy explicitly, but the UI implied full-severity coverage. Neither the docs nor
the UI told the truth about the other.

## Decision

Adopt **Option C**: scan all severities, upload all severities to SARIF, surface all severities
in the dashboard. CRITICAL remains the primary **actionable** threshold — it gets the strongest visual
emphasis (red ring, `.nonzero` class). HIGH also receives a warning emphasis. MEDIUM,
LOW, and INFO render as advisory context with neutral styling.

Blocking semantics are **unchanged**: `continue-on-error: true` on Trivy steps is permanent
policy; no severity level blocks the build or the push. This is not a change to build policy —
it is a change to what evidence the trust-strip surface presents.

Specific changes (PR implementing this ADR):

- `vulnerability_severity` input default changed from `CRITICAL` to `UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL`.
- SARIF generation step wired to the same input (no longer hardcoded to `CRITICAL`).
- Scan-history file format extended: `counts` object (all 5 severities) + `scanned_severities`
  array replace the old `scanned_severity: "CRITICAL"` scalar.
- `helpers/trivy-utils.sh` side-channel merge rewritten as **overlay-not-replace**: the API
  result is the base; side-channel overlays `last_scan` and `counts` (authoritative for
  pipeline-fresh data). Legacy files without `counts` fall back to the `alert_count` → critical
  back-compat path with no migration required.

## Consequences

**Positive:**
- The 5-cell severity grid shows real numbers — the Phase B trust-strip investment is fully
  utilised for persona Camille's evidence-led triage workflow.
- Docs, CI configuration, and dashboard UI are now consistent.
- Non-CRITICAL findings become queryable from the dashboard surface, not just via `gh api`.

**Field semantics:**
- `alert_count` in scan-history files now represents total findings across all surfaced
  severities, not the CRITICAL count it represented in the pre-Option-C era. The
  `helpers/trivy-utils.sh` legacy back-compat branch detects pre-Option-C files via the
  absence of the new `counts` field and treats `alert_count` as `counts.critical` (which
  it was, by definition, in that era).

**Negative (accepted trade-offs):**
- GitHub Code Scanning Security tab fills with HIGH/MEDIUM/LOW alerts that are not actionable
  by the maintainer (upstream base-image advisories). Accepted: transparency-first is the
  project's stated brand value.
- SARIF uploads are approximately 30% larger (more rules + results). Accepted: the upload step
  already runs `continue-on-error: true`; size increase has no operational impact on builds.
- Code Scanning indexing lag for non-CRITICAL alerts is longer. Mitigated: the side-channel
  file is written in-pipeline and is always the authoritative source for dashboard counts.

## Alternatives Rejected

| Option | Reason rejected |
|--------|----------------|
| **A. Docs-aligned CRITICAL-only** — keep pipeline as-is, remove the 4 non-critical cells from the UI | UI becomes deceptive UX: the 5-cell grid is Phase B's trust-strip identity per ADR-007; removing cells discards the design investment and misleads Camille about scan depth. |
| **B. UI-aligned, hide non-zero cells** — keep CRITICAL scan, conditionally render only the CRITICAL cell | Same problem as A: wastes Phase B's pipeline investment in scan data and contradicts the evidence-led brand voice ("no marketing fluff → show what was scanned"). |

## References

- `docs/adr/ADR-007-phase-c-redesign.md` — trust-strip identity, persona Camille, Phase B pipeline
- `helpers/trivy-utils.sh` — side-channel overlay merge implementation
- `.github/actions/build-container/action.yaml` — `vulnerability_severity` input, scan-history writer
- `docs/site/verify-images.md` — public-facing severity policy documentation
