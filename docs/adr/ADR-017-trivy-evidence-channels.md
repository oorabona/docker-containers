# ADR-017: Trivy Evidence Channels — Two Observations, One Named Display Source

**Status:** Accepted
**Date:** 2026-09-05
**Supersedes (in part):** ADR-008's side-channel overlay merge

## Context

ADR-008 shipped an overlay: the Code Scanning API result was the base, and a scan-history record
overlaid `last_scan` and `counts` onto it when a timestamp comparison showed the record was at least
as recent. Advisory rows were kept from the API regardless.

The two sources state different things:

- a scan-history record says *this image scan found these results at this time*;
- the Code Scanning API says *these alerts are open when it was asked*.

The API's timestamp is the newest alert-instance `created_at`, which is not evidence that a scan
completed. Comparing it against a record's scan instant compares two clocks measuring two different
events, and merging the results produced three defects that were reported independently:

- a displayed count could change basis without the display saying so, because dismissing an alert
  lowers the API count with no scan having run (oorabona/docker-containers#1707);
- counts from a record could be shown beside advisory rows from a different snapshot, which ordinary
  Code Scanning indexing lag is enough to produce (#1692);
- an absent API entry was treated as licence to publish a record of any age, because the API is
  queried for open alerts only, so "no entry" and "no open alerts" are one observation (#1716).

Measured on 2026-09-05: 288 scan-history records against 71 categories holding open alerts, so
*record present, API silent* is the dominant path; and of 9703 alerts, 2899 were `fixed` and 14
`dismissed`, so alerts genuinely close and dismissal without a scan genuinely happens here.

## Decision

`get_trivy_summary` returns both observations independently and names which one is displayed.

- `scan_record` — `scan_at` and counts, or `null` when no usable record exists.
- `code_scanning` — `fetched_at`, counts and `top_advisories`, or `null` when the fetch produced no
  trustworthy observation. Advisories live **inside** this channel, so a record can neither inherit
  nor clear them.
- `display_source` — `code-scanning`, `scan-record`, or `unavailable`.

The displayed `counts`, `top_advisories` and `as_of` are derived from the named channel in exactly one
place. `last_scan` keeps its original meaning — the instant a scan completed — and is `null` when no
record exists; it never holds a fetch time.

A successful fetch is an observation **including when it finds nothing**, so it takes the display
whenever it succeeded. A record takes the display only when the API produced no trustworthy
observation. When neither does, `display_source` is `unavailable`, and that state is rendered
explicitly: neutral, carrying no number, and never readable as a clean result.

The API-versus-record freshness comparison goes. The protection it was added for — a stale clean
record must not hide a live finding — then holds by construction, because a successful observation
always takes the display without any comparison.

## Consequences

**Positive:**

- A reader can tell an open-alert count from a recorded-scan count, and both from "we could not
  establish this". None of the three is distinguishable under the overlay.
- Counts and the advisories beside them always share one source.
- No code compares two clocks that measure different events.
- The detail page can show both observations at once, so a successful `0 open alerts` beside an older
  record reporting findings is visible rather than reconciled into one number.

**Negative (accepted trade-offs):**

- Every variant carries an evidence block, including an empty one, so `containers.yml` grows and
  every renderer must handle three states rather than a present/absent pair.
- A variant whose evidence cannot be established shows a visible "no evidence" badge where it
  currently shows nothing. This is the point, and it costs dashboard surface.

## What this ADR does not decide

Naming the source does not establish that a record describes the image currently published, and it
does not bound a record's age. #1716 stays open for record→image identity binding.

Choosing between two scan-history records carrying the same instant and different content happens
during workflow hydration merge, not in this function; #1696 stays open and unchanged.

## References

- `helpers/trivy-utils.sh` — where the two channels and the sole display resolver go
- `docs/adr/ADR-008-trivy-severity-policy.md` — the overlay merge this supersedes
- `scripts/verify-dashboard-data.sh` — where an evidence gap is reported from `display_source`
