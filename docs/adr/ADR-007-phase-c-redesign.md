# ADR-007: Dashboard Phase C Redesign — Token Foundation, Trust-Strip Identity, Provenance Section

**Status:** Accepted
**Date:** 2026-05-04

## Context

Phase B (PR #329, Apr 2026) shipped the trust-strip data pipeline — SBOM attestation via Sigstore, Trivy CRITICAL scan history, multi-arch manifest verification. The plumbing works (verified end-to-end on 13 containers).

A live UX audit (2026-05-01, dashboard at `https://oorabona.github.io/docker-containers/`) surfaced 3 CRITICAL + 5 MAJOR + 10 MINOR findings. Most are symptoms of three missing design-system layers:

1. **No token system** — 61 ad-hoc `rgba(255, 255, 255, 0.X)` calls across 4 CSS files; existing `--accent-{green,blue,…}` are flat hex with no tonal scale; `--text-secondary: rgba(255,255,255,0.7)` and `--text-muted: rgba(255,255,255,0.5)` fail WCAG AA contrast on the darkest navy tile.
2. **No reusable component patterns** — the SBOM badge is `display:none` site-wide because `data-digest` is never wired to the template; the Trivy "Security scan details" section is plain text with no card structure; `<version-tabs>` (postgres has 21 entries × 3 versions) is undiscoverable.
3. **No layout primitives** — container detail pages have no `<site-nav>`; `/blog/` and `/verify-images/` have no `<footer>`; `.container { margin: 20px }` left-aligns the dashboard at viewports > 1440px.

Phase B's investment in supply-chain trust artifacts is not surfaced to the audit-flow user. Heuristic personas (`design:research` skill) identify the primary as Camille — an AppSec engineer who screenshots the trust-strip + Provenance section into a Confluence page to justify org-wide image adoption. Her current-state journey shows an emotional curve `Awareness 0 → Triage −2 → Deep dive −1 → Verification +1 → Decision +2` — the Triage trough is a trust-or-leave moment, and the SBOM badge being invisible is the largest contributor.

## Decision

Adopt a **3-tier W3C Design Token Community Group** taxonomy (primitive → semantic → trust-domain) and ship the redesign in **3 PRs of monotonic scope**:

- **PR1 — Foundation** (~300 LOC): `tokens.css` NEW (full primitive + semantic + light-mode-prep) + `theme.css` refactored to deprecated aliases pointing at new tokens + targeted patches in `dashboard.css` / `container-detail.css` / `blog.css` to fix CSS findings (`.container` centering, `.tag-pill` spacing, contrast bumps via tokens, font-family + type classes, motion variables, 3% noise overlay on the existing navy gradient).
- **PR2 — Components** (~400 LOC): SBOM data wiring (Liquid template populates `data-digest`), `<security-scan-card>` web component (replaces plain-text Trivy section), `<version-tabs>` accessible component (`role="tablist"` keyboard-navigable), consolidated **Provenance section** with definition-list semantics + mono code blocks + copy buttons (the artifact Camille screenshots).
- **PR3 — Layout primitives** (~150 LOC): shared `_includes/site-nav.html` + `_includes/site-footer.html` used by all layouts; replace the page-bespoke "CONTAINER MANAGEMENT SYSTEM" eyebrow on container detail; iconography lockdown (Tabler Icons single set, 1.5px stroke).

### Token decisions (PR1)

| Layer | Approach |
|-------|----------|
| Primitive palette | Navy tonal scale (950 → 500), blue/green/amber/red functional scales (300-600), neutral scale (50 → 900), **trust-domain hues**: teal #2DD4BF (SBOM, Sigstore-adjacent), cyan #22D3EE (Verify CTA, distinct from primary blue), violet #A78BFA (multi-arch, architectural identity) |
| Semantic | `--color-surface-*`, `--color-text-*` (contrast-validated AA on the darkest tile), `--color-action-*`, `--color-feedback-*` (generic state), `--color-trust-*-fg/bg/border` (identity, distinct from generic feedback) |
| Type scale | Modular Major Third (1.250) base 16px, weight 400-700, line-height 1.2 / 1.5 / 1.75 |
| Spacing | 8px Material grid, semantic aliases for inset / stack / inline |
| Typography signature | Inter (`ss01`, `cv11` features + per-weight tracking tweaks) for body/headlines; **JetBrains Mono on trust-strip badges + eyebrow labels** — the memorable typographic signature, not a third font |

### Trust-strip 3-hue + mono signature

The trust strip is the project's non-substitutable visual signature (Phase B investment). The chosen palette + typography combination is unique on the OSS Docker landscape: a 3-distinct-hue (teal/cyan/violet) + monospaced uppercase typography badge grid. This creates a recognizable artifact across pages and across-time — an audit performed in Q1 vs Q3 will visually match in the screenshot Camille pastes into Confluence.

## Options Considered

| Option | Outcome |
|--------|---------|
| **A.** Big-bang rewrite with Tailwind / styled-components / a CSS-in-JS framework | ✗ Rejected — Jekyll on GitHub Pages with hand-authored CSS works; adding a build step is bundle bloat for ~300 LOC of tokens. |
| **B.** Item-by-item finding fixes (one PR per audit finding) | ✗ Rejected — 13 findings × 1 PR each = 13 small CSS patches with no shared system; reproduces the divergence we are trying to remove. |
| **C.** Token-foundation-first, monotonic-scope 3 PRs (chosen) | ✓ Accepted — PR1 establishes the system once; PR2/PR3 consume it without redefining. Each PR is mergeable independently and ~150-400 LOC (audit-friendly). |

## Evidence

- UX audit (2026-05-01): 3 CRITICAL + 5 MAJOR + 10 MINOR findings on the live site, captured at `1440×900` desktop and `390×844` mobile viewports (24 screenshots).
- Personas + journey map (`design:research` skill, 2026-05-03): heuristic Cooper-style behavioral personas — primary = Camille (AppSec evaluator), secondary = Yaël (SRE), supplemental = Sam (indie). Triage trough is the trust-or-leave moment.
- Catalog validation (`ui-ux-pro-max` skill, 2026-05-04): Swiss Modernism 2.0 + "Modern Dark Cinema (Inter System)" + Developer Tool / IDE palette templates independently match the locked spec; tracking values for Inter weights match catalog recommendations within 0.5pt.
- Industry references: Stripe Docs (institutional API documentation), pkg.go.dev (mono-confident package metadata), Sigstore website (teal-accented supply-chain UI), Vercel Docs (Inter-confident dark mode), Anthropic docs (refined typography, restrained palette), Linear (density + warm editorial type).
- WCAG 2.2 AA: required body 4.5:1 / large text 3:1 / non-text UI 3:1. Current `--text-muted` fails at ~2.1:1 on the darkest tile; PR1 token replacement targets ≥ 4.6:1.

## Trade-offs

- **Light-mode toggle UI is parked** as a TODO entry. Light-mode tokens are defined in `tokens.css` (≈12 LOC marginal cost) so future work is just a button + persistence + `prefers-color-scheme` sync. Decision: ship light-mode UI only when a persona signal warrants it (no live user data yet).
- **49 of the 61 ad-hoc rgba calls remain** after PR1 — the 12 selectors named in the audit get patched; the rest are deferred to a tech-debt sweep PR (PR4) to keep PR1 reviewable.
- **`<security-scan-card>` and `<version-tabs>` are net-new web components** — more code surface to maintain than reusing an existing pattern. Justification: the plain-text Trivy section and the undiscoverable postgres version-switch are documented usability blockers for the primary persona; components are the durable fix.
- **Existing `--accent-{green,blue,…}` tokens are kept as deprecated aliases** for one release cycle (point at the new tokens). Avoids a single-PR breaking change to `dashboard.css` / `container-detail.css` / `blog.css` selectors that reference them.
- **No third typeface** despite the `frontend-design` skill's default reject-Inter-as-display rule. Pushback resolved by deploying JetBrains Mono on the trust strip and eyebrow labels — those carry the distinctive identity that a third font would have provided, with zero additional font-file weight.

## Validation

- **Pre-merge gate (every PR)**: `wcag-a11y` skill audit on contrast pairs introduced or modified by the PR. PR1 specifically validates `--color-text-{primary,secondary,muted}` against `--color-surface-{base,raised,overlay}` and the trust-domain `*-fg` tokens against their `*-bg` companions.
- **Live verification (post-merge each PR)**: re-run the UX audit-style probe on `https://oorabona.github.io/docker-containers/` for the findings the PR closes. Findings are expected to graduate from CRITICAL → resolved across PR1 (C1, C2, M2, M3, m8), PR2 (C3, M4, user-noted Trivy plain-text), PR3 (M1, M5, m3, m4, m10).
- **Camille screenshot test (PR2 acceptance)**: render the Provenance section at 1440×900, export to PDF, paste into a markdown table — all evidence rows (build commit, manifest digest, base image origin, deps pinned, SBOM attestation link, Trivy scan timestamp, signature command) must remain legible at the PDF default zoom.
- **Trigger to revisit the design system**: > 5 NEW MAJOR or > 1 NEW CRITICAL finding from a future audit pass on the redesigned surface, OR a new persona signal that materially changes the primary archetype.

## References

- **Design system spec** (3-tier W3C DTCG taxonomy): primitive palette (navy tonal scale, functional blue/green/amber/red, trust-domain teal/cyan/violet), semantic layer (`--color-surface-*`, `--color-text-*`, `--color-feedback-*`, `--color-trust-*`), spacing (8px Material grid, semantic aliases), type scale (Major Third 1.250, base 16px).
- **Persona research**: 3 Cooper-style behavioral personas — primary = Camille (AppSec evaluator, screenshots trust-strip into Confluence), secondary = Yaël (SRE, needs depth), supplemental = Sam (indie, self-serve). Journey map: Awareness 0 → Triage −2 → Deep dive −1 → Verification +1 → Decision +2. Triage trough is the design moment being resolved.
- **Aesthetic direction** (4 gates locked): dashboard+docs hybrid / refined-authoritative-proof-forward direction / trust-strip 3-hue+mono as visual signature / Jekyll + dark default + Inter+JetBrains Mono only + WCAG 2.2 AA strict. JetBrains Mono on trust-strip badges + `.eyebrow` labels is the memorable typographic identity.
- **Catalog validation**: Swiss Modernism 2.0 + Modern Dark Cinema (Inter System) + Developer Tool/IDE palette templates independently match the locked spec. Industry references: Stripe Docs, pkg.go.dev, Sigstore website, Vercel Docs, Anthropic Docs, Linear.
- **Skills used to produce the spec**: `design:research` (personas, journey map), `design:systems` (token taxonomy), `frontend-design` (4-gates lock + brand voice + motion ethos), `ui-ux-pro-max` (catalog validation), `design:ops` (this ADR + handoff).
