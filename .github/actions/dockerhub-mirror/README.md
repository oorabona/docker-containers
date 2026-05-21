# dockerhub-mirror

Composite action that starts a per-job `registry:2` pull-through proxy sidecar, routing
`docker.io` base-image pulls through a local cache at `127.0.0.1:<port>`. Eliminates
`docker.io HTTP 429` on the `docker buildx build` base-image pull path without modifying
Dockerfiles. Implements ADR-009 / issue #488.

**Linux-only.** All steps are no-ops on `runner.os == Windows` (Windows base images are
not the docker.io 429 source).

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `dockerhub_username` | yes | — | Docker Hub username (proxy backend credentials) |
| `dockerhub_token` | yes | — | Docker Hub token (proxy backend credentials) |
| `port` | no | `5000` | Host port for the proxy (bound to `127.0.0.1` only) |
| `registry_image` | no | `ghcr.io/<owner>/registry:2` | Proxy sidecar image (GHCR copy preferred) |
| `cache_key_prefix` | no | `dockerhub-mirror` | `actions/cache` key prefix for the proxy store |
| `allow_self_hosted` | no | `false` | Explicit opt-in to run on a self-hosted runner despite `REGISTRY_PROXY_PASSWORD` being visible via `docker inspect`. Only set to `true` on a trusted single-tenant ephemeral runner. The action fails-closed by default on any non-GitHub-hosted environment. |

## Usage

Call in this order at each build site: docker.io login → this action → setup-buildx.

```yaml
- name: Log in to Docker Hub
  uses: ./.github/actions/docker-login
  with:
    ghcr_username: ${{ github.actor }}
    ghcr_password: ${{ secrets.GITHUB_TOKEN }}
    dockerhub_username: ${{ secrets.DOCKERHUB_USERNAME }}
    dockerhub_token: ${{ secrets.DOCKERHUB_TOKEN }}

- name: Start Docker Hub mirror
  uses: ./.github/actions/dockerhub-mirror
  with:
    dockerhub_username: ${{ secrets.DOCKERHUB_USERNAME }}
    dockerhub_token: ${{ secrets.DOCKERHUB_TOKEN }}

- name: Set up Docker Buildx
  uses: docker/setup-buildx-action@<SHA> # v4
  with:
    driver: docker-container
    driver-opts: network=host
    buildkitd-config: .github/buildkitd-mirror.toml
```

## Security note (GH-hosted runners only)

`REGISTRY_PROXY_PASSWORD` is passed as a container environment variable and is readable
via `docker inspect dockerhub-mirror` by other processes within the same job. The action
**enforces** this boundary: it checks `$RUNNER_ENVIRONMENT` at startup and fails-closed
with `::error::` if the runner is not `github-hosted`, unless `allow_self_hosted: true`
is set as an explicit opt-in. Use `allow_self_hosted: true` only on a trusted single-tenant
ephemeral self-hosted runner where co-tenancy risk is absent. Use a least-privilege Docker
Hub account (no private-repo access). The proxy port is bound to `127.0.0.1` (loopback)
only — not exposed to the network.

The action is **always fail-closed** on an unhealthy proxy: there is no escape hatch.
`setup-buildx` (run after this action) applies the `buildkitd-config` pointing at the
proxy — so a dead proxy cannot be transparently bypassed; any attempt to continue would
silently route pulls through a broken mirror. A healthcheck failure emits `::error::` and
exits non-0, causing the job to fail loudly.

## Architecture

The `registry:2` sidecar is pulled from a GHCR copy (`registry_image` default) to keep
bootstrap intra-GitHub. The fallback `registry:2@sha256:...` (digest-pinned docker.io)
is used only when the GHCR copy is absent (first run before B5 seeds it). The proxy
store (`$RUNNER_TEMP/registry-mirror`) is persisted via `actions/cache` with a per-job
save key (avoids parallel-matrix collision) and a broad restore prefix (warms from any
prior same-OS job). `REGISTRY_PROXY_TTL=168h` lets the proxy serve cached manifests for
a week without revalidating against docker.io.

See `docs/adr/ADR-009-dockerhub-pullthrough-mirror.md` for the design rationale.
