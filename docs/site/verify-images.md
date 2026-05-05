---
layout: verify
title: How we verify images
description: Reproduce every trust signal yourself — SBOM, Trivy, multi-arch, dependency monitoring.
permalink: /verify-images/
nav_active: verify
---

## Why this page exists

The trust badges on each container card link here so anyone can replicate every check independently. We surface SBOM attestations, Trivy scan results, multi-arch manifests, and upstream dependency tracking — not to ask you to trust a badge, but to give you the exact commands to verify them yourself.

## Verifying the SBOM attestation

Each container's SBOM is signed via Sigstore using `actions/attest-sbom`. The attestation is anchored to the image digest and recorded in the GitHub attestations API, which is publicly accessible without authentication. To verify locally using the GitHub CLI:

<div class="code-block" data-copy="gh attestation verify oci://ghcr.io/oorabona/&lt;container&gt;:&lt;tag&gt; --owner oorabona">
  <div class="code-block__header">
    <span class="code-block__lang">bash</span>
    <button class="code-block__copy" type="button" data-copy-button aria-label="Copy command"><i class="ti ti-copy" aria-hidden="true"></i><span class="copy-label">Copy</span></button>
  </div>
  <pre><code><span class="prompt">$</span> gh attestation verify oci://ghcr.io/oorabona/&lt;container&gt;:&lt;tag&gt; --owner oorabona</code></pre>
</div>

The SBOM badge in each container card opens the public attestation viewer directly in your browser — no login required. For example, a direct URL looks like `https://github.com/oorabona/docker-containers/attestations/<id>`. The viewer shows the SBOM payload, the Sigstore bundle, and the signing certificate chain.

<a id="trivy"></a>

## Reading Trivy scan results

Trivy scans run on every build in advisory mode: findings do not block the build, but they are surfaced. Results are uploaded to GitHub via `github/codeql-action/upload-sarif`, which populates the Code Scanning API. Note that the Security tab UI in GitHub requires authentication even for public repos — that is why each container's detail page embeds the scan summary directly. To query findings programmatically with any authenticated GitHub session (`gh auth login` is enough; no special scope is required):

<div class="code-block" data-copy="gh api repos/oorabona/docker-containers/code-scanning/alerts --paginate -q '.[] | {rule_id: .rule.id, severity: .rule.severity, category: .most_recent_instance.category, package: .most_recent_instance.location.path}'">
  <div class="code-block__header">
    <span class="code-block__lang">bash</span>
    <button class="code-block__copy" type="button" data-copy-button aria-label="Copy command"><i class="ti ti-copy" aria-hidden="true"></i><span class="copy-label">Copy</span></button>
  </div>
  <pre><code><span class="prompt">$</span> gh api repos/oorabona/docker-containers/code-scanning/alerts \
  --paginate \
  -q '.[] | {rule_id: .rule.id, severity: .rule.severity, category: .most_recent_instance.category, package: .most_recent_instance.location.path}'</code></pre>
</div>

To filter findings to a single container variant, match on the `category` field, which encodes the container name and platform:

<div class="code-block" data-copy="gh api repos/oorabona/docker-containers/code-scanning/alerts --paginate -q '.[] | select(.most_recent_instance.category == &quot;container-postgres-18-alpine-linux/amd64&quot;)'">
  <div class="code-block__header">
    <span class="code-block__lang">bash</span>
    <button class="code-block__copy" type="button" data-copy-button aria-label="Copy command"><i class="ti ti-copy" aria-hidden="true"></i><span class="copy-label">Copy</span></button>
  </div>
  <pre><code><span class="prompt comment">#</span> Replace the category value with the variant you want to inspect
<span class="prompt">$</span> gh api repos/oorabona/docker-containers/code-scanning/alerts --paginate \
  -q '.[] | select(.most_recent_instance.category == "container-postgres-18-alpine-linux/amd64")'</code></pre>
</div>

### Why the dashboard only highlights CRITICAL counts

Each container card's Trivy badge surfaces the count of **CRITICAL**-severity findings only. High, medium, low, and informational findings are still scanned, still uploaded to GitHub Code Scanning, and still queryable through the API command above — they are intentionally not promoted to the dashboard headline.

Two reasons for this choice:

- **Signal vs noise.** A solo-maintained container catalog routinely carries dozens of low/medium advisories that originate in upstream base images and that the maintainer cannot fix directly. Showing the full count on the dashboard would normalize a constantly red badge and erode the meaning of "go look at this image's security posture." CRITICAL is the cut-off where downstream consumers should pause and verify before pulling.
- **Defense in depth, not single source of truth.** GitHub's Security tab (and the `gh api` query above) remains the authoritative full-detail view for anyone running their own risk assessment. The dashboard is a glanceable surface, not a replacement for the Code Scanning UI.

If you operate this catalog yourself and prefer a different threshold, the SARIF severity filter lives in `.github/actions/build-container/action.yaml` (search for the `trivy-action` step) and the dashboard summary aggregation in `helpers/trivy-utils.sh`. Both are plain code; widening the threshold is a one-line change in each file plus a fresh dashboard regeneration.

## Inspecting multi-arch manifests

Multi-arch images publish a manifest list that references per-platform image manifests. To see which CPU architectures are present for any tag:

<div class="code-block" data-copy="docker manifest inspect ghcr.io/oorabona/&lt;container&gt;:&lt;tag&gt;">
  <div class="code-block__header">
    <span class="code-block__lang">bash</span>
    <button class="code-block__copy" type="button" data-copy-button aria-label="Copy command"><i class="ti ti-copy" aria-hidden="true"></i><span class="copy-label">Copy</span></button>
  </div>
  <pre><code><span class="prompt">$</span> docker manifest inspect ghcr.io/oorabona/&lt;container&gt;:&lt;tag&gt;</code></pre>
</div>

Look at the `manifests` array in the output — each entry's `platform.architecture` field reveals the published architectures. Multi-arch images list both `amd64` and `arm64`; single-arch images list one. The architecture badge on each card reflects this inspection at build time.

## Auditing dependency monitoring

Daily upstream monitoring runs via `.github/workflows/upstream-monitor.yaml`. Each container's `config.yaml` declares `dependency_sources`, which lists the upstream packages to watch. When a new upstream version is available, the workflow opens an automatic pull request with the version bump. To audit the monitoring history and open PRs:

- Workflow run history: <https://github.com/oorabona/docker-containers/actions/workflows/upstream-monitor.yaml>
- The dependency badge on each card shows how many sources are tracked daily and links to that same workflow page.

Nothing in this pipeline is opaque: the `version.sh` script in each container directory implements the upstream query logic, and the workflow YAML is the complete source of truth for scheduling and automation.

## Reproducing builds locally

Every container build is driven by shell scripts with no opaque CI steps. To reproduce a build on your own machine:

<div class="code-block" data-copy="git clone https://github.com/oorabona/docker-containers.git&#10;cd docker-containers&#10;./make build &lt;container&gt; [version]">
  <div class="code-block__header">
    <span class="code-block__lang">bash</span>
    <button class="code-block__copy" type="button" data-copy-button aria-label="Copy command"><i class="ti ti-copy" aria-hidden="true"></i><span class="copy-label">Copy</span></button>
  </div>
  <pre><code><span class="prompt">$</span> git clone https://github.com/oorabona/docker-containers.git
<span class="prompt">$</span> cd docker-containers
<span class="prompt">$</span> ./make build &lt;container&gt; [version]</code></pre>
</div>

BuildKit must be enabled (`DOCKER_BUILDKIT=1` or Docker 23+). The `./make` entry point accepts the same arguments as the CI pipeline. See each container's `README.md` and the top-level `docs/` directory for full build documentation, including multi-variant matrix builds, extension layers, and SBOM generation.

## Frequently asked questions

### Why does the dashboard show "Trivy scan results are advisory"?

Trivy runs as `continue-on-error` in CI. The build does not fail when CVEs are detected; it surfaces the count for the operator to triage. Use the count as input to your image-acceptance policy, not as a blocking gate.

### What does the SBOM badge state mean?

The badge has two states. **ATTESTED** means both `attestation_url` and `attestation_id` are present in the published lineage record — the SBOM has been signed via Sigstore and is verifiable with cosign. **PENDING** covers all other cases (no attestation yet, or partial data) and indicates the image will be re-attested on the next successful build.

### How is the SBOM signed?

Each successful build runs `anchore/sbom-action` to generate an SPDX JSON SBOM, then `actions/attest-sbom` signs it via Sigstore (keyless, OIDC-based) and uploads the attestation to GHCR. You can verify with `gh attestation verify oci://ghcr.io/oorabona/<image>:<tag> --owner oorabona`.

### Can I trust a container that shows "SBOM PENDING"?

It is not a security flag. PENDING means the build pipeline has not yet re-run since the image was published, or the attestation pipeline encountered a transient failure that will be retried. Pull by digest from a previous attested build if you need verifiable SBOM provenance immediately.

### How fresh are the Trivy scan dates shown on the dashboard?

The "SCANNED YYYY-MM-DD" timestamp on each Trivy badge reflects the most recent successful Trivy run for the corresponding image variant. Scans run on every build; if a container has not been rebuilt for an extended period, the date will reflect that staleness.

{% include jsonld-howto-verify.html %}
{% include jsonld-faq.html %}
