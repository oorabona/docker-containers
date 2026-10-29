# Use the published GitHub runner image with ARC

[Data, local] The existing Linux images decode ARC's JIT input without image changes in offline tests. GitHub-issued registration, job execution, and pod deletion still require a trusted-private ARC canary. Integration belongs to [o2csi/infra#372](https://github.com/o2csi/infra/issues/372), within [o2csi/infra#371](https://github.com/o2csi/infra/issues/371); image qualification is tracked by [oorabona/docker-containers#2192](https://github.com/oorabona/docker-containers/issues/2192).

Use [`github-runner/examples/arc-values.yaml`](../../github-runner/examples/arc-values.yaml) with the ARC `gha-runner-scale-set` chart at `0.15.1`. The sample pins the tested linux/amd64 child manifest for `ghcr.io/oorabona/github-runner:2.338.2`; its tag is not a multi-platform index digest. It sets the runner container name to `runner`, which ARC uses when adding JIT configuration and related runner environment variables in [`newEphemeralRunnerPod`](https://github.com/actions/actions-runner-controller/blob/23159a8e2d70ca4cece740fe43a8d9eb0c2818de/controllers/actions.github.com/resourcebuilder.go#L876-L939).

## What the sample does

The runner process starts from `/home/runner/actions-runner/run.sh` with `_work` as both its Kubernetes working directory and mounted work volume. The absolute path matters because `run.sh` resolves its own location, while [ARC copies `workingDir` into the JIT `WorkFolder`](https://github.com/actions/actions-runner-controller/blob/23159a8e2d70ca4cece740fe43a8d9eb0c2818de/controllers/actions.github.com/ephemeralrunner_controller.go#L842-L853). The image's standalone [`entrypoint.sh`](../../github-runner/entrypoint.sh#L21-L38) performs root-time ownership repair before dropping privileges, so ARC bypasses it and sets `HOME` and `RUNNER_TOOL_CACHE` to runner-writable paths instead. ARC also supplies JIT credentials; the standalone `config.sh --ephemeral` registration must not run in this pod.

[Data, source] ARC injects `ACTIONS_RUNNER_INPUT_JITCONFIG` from its JIT secret, `GITHUB_ACTIONS_RUNNER_EXTRA_USER_AGENT`, and `ACTIONS_RUNNER_RETURN_VERSION_DEPRECATED_EXIT_CODE=1` into the container named `runner`. The JIT value is base64-encoded JSON mapping filenames to base64-encoded file contents. The real listener reads this environment variable and writes the files under `/home/runner/actions-runner`; no extra registration token or `--jitconfig` argument is needed. These are [controller](https://github.com/actions/actions-runner-controller/blob/23159a8e2d70ca4cece740fe43a8d9eb0c2818de/controllers/actions.github.com/resourcebuilder.go#L876-L939) and [runner](https://github.com/actions/runner/blob/d1eb12d4b115c301201de27d667284e1a80f2ab5/src/Runner.Listener/Runner.cs#L234-L270) contracts.

The pod security context supplies UID, GID, and filesystem group `1001`, and the runner container drops every Linux capability and disallows privilege escalation. The image root filesystem remains writable: the runner writes its JIT configuration at the runner root, as shown in [`Runner.cs`](https://github.com/actions/runner/blob/d1eb12d4b115c301201de27d667284e1a80f2ab5/src/Runner.Listener/Runner.cs#L234-L267), and it also needs writable helper, diagnostic, and cache paths. The sample disables service-account token automount and retains ARC's default no-permission service account by not naming one.

`containerMode` is absent. Do not add Docker sockets, host paths, privileged containers, DinD, or Kubernetes hooks to this values file. [ARC's Kubernetes mode](https://github.com/actions/actions-runner-controller/blob/23159a8e2d70ca4cece740fe43a8d9eb0c2818de/charts/gha-runner-scale-set/templates/_helpers.tpl#L454-L535) expects `/home/runner/k8s/index.js`, work at `/home/runner/_work`, and Kubernetes permissions. This image has no hook bundle, and its runner and `externals` live under `/home/runner/actions-runner`. Selecting that mode alone will not supply the missing files or reconcile the paths. With the sample restrictions, `sudo` is unavailable, and Docker build, service-container, and container-job workflows need separately approved builder, hosted-runner, or hooks qualification. Talos uses containerd; the standalone Compose Docker socket cannot be reused as a Docker API endpoint there.

`minRunners: 0` and `maxRunners: 1` limit idle capacity and concurrency. They do not size CPU, memory, ephemeral storage, quotas, log retention, or egress. Set resource requests/limits and any `emptyDir.sizeLimit` only after workload measurement and platform approval.

## Render and inspect before a canary

Create the named GitHub configuration secret in the target namespace through the platform's approved secret workflow. Do not put a PAT, GitHub App key, or plaintext token in the values file.

This command renders the pinned chart without installing it or contacting a Kubernetes API. It may download the chart if it is not already cached.

```bash
helm template trusted-private-arc \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --version 0.15.1 \
  --namespace arc-runners \
  --set controllerServiceAccount.namespace=arc-system \
  --set controllerServiceAccount.name=arc-gha-rs-controller \
  -f github-runner/examples/arc-values.yaml
```

The chart's `template.spec` is a runner PodSpec, and its documented `containerMode` options modify that PodSpec. Review the rendered `AutoscalingRunnerSet` against the [0.15.1 values contract](https://github.com/actions/actions-runner-controller/blob/23159a8e2d70ca4cece740fe43a8d9eb0c2818de/charts/gha-runner-scale-set/values.yaml#L1-L65) and its [template behavior](https://github.com/actions/actions-runner-controller/blob/23159a8e2d70ca4cece740fe43a8d9eb0c2818de/charts/gha-runner-scale-set/values.yaml#L341-L445).

For an existing local image runtime, pull the exact platform manifest and run the opt-in, no-network image test. It uses a synthetic invalid JIT payload, never registers a runner, and requires the image to be pre-pulled when Bats starts.

```bash
podman pull --platform linux/amd64 \
  ghcr.io/oorabona/github-runner:2.338.2@sha256:9df91c26565854fc5966ff98285789787d8e4aad0c2e3f60bc4076432d2a1877

ARC_RUNTIME_TESTS=1 \
ARC_TEST_RUNTIME=podman \
ARC_TEST_IMAGE=ghcr.io/oorabona/github-runner:2.338.2@sha256:9df91c26565854fc5966ff98285789787d8e4aad0c2e3f60bc4076432d2a1877 \
bats github-runner/tests/test-runner-arc.bats
```

The test establishes local image/JIT behavior only. ARC injects JIT configuration into the `runner` container, and the runner writes that input under its installation root; the controller source establishes those contracts. The runner and controller sources also describe one-job cleanup and controller cleanup, but neither fact proves a real job, pod deletion, or scale-down in a target cluster. See [`Runner.cs`](https://github.com/actions/runner/blob/d1eb12d4b115c301201de27d667284e1a80f2ab5/src/Runner.Listener/Runner.cs#L568-L602) and ARC's [`cleanupResources`](https://github.com/actions/actions-runner-controller/blob/23159a8e2d70ca4cece740fe43a8d9eb0c2818de/controllers/actions.github.com/ephemeralrunner_controller.go#L569-L610).

## Local results and remaining checks

[Data, local, 2026-10-29] Rootless Podman `4.9.3` ran the published Linux/amd64 images unchanged, without network access or runner capabilities. All four contained runner `2.338.2` and working bundled glibc Node `20.20.2` and `24.22.1`; Node is not a global `PATH` command.

| Published tag | Measured UID:GID | JIT file written, then deliberate invalid AgentId rejected | Malformed JIT creates no `.runner` |
|---|---|---|---|
| `2.338.2` | `1001:1001` | Passed | Passed |
| `2.338.2-dev` | `1001:1001` | Passed | Passed |
| `2.338.2-debian-trixie` | `1000:1000` | Passed | Passed |
| `2.338.2-debian-trixie-dev` | `1000:1000` | Passed | Passed |

[Data, local] These eight probes consumed `ACTIONS_RUNNER_INPUT_JITCONFIG` with no command arguments. The synthetic `.runner` uses an intentionally invalid `AgentId` so the listener stops before registration. Both error cases can return `0` through `run.sh`: the tests check the saved file and explicit parse error, not only the exit code. UID `1001` failed with `Permission denied` on Debian. Group-only work-volume writes and the `_tool` cache override succeeded with each image's actual user. The reusable Bats suite above additionally exercises the sample's absolute work path. Its volume initialization runs separately as root with only `CHOWN`; the tested runner remains non-root. Kubernetes `fsGroup`, ARM64, Windows execution, and Docker runtime execution were not tested here.

## Cache and canary boundaries

For dependency caches, use `actions/cache` for selected workflow paths. Do not cache the runner root, `.runner`, credentials, `_work`, or a shared catch-all PVC. The image layer and the pod's `_work` emptyDir disappear with each pod; any tool or package cache not restored by the workflow also disappears.

The following is an inert workflow example for a manually approved trusted-private canary. It belongs in the consuming private repository only after the platform has installed ARC and approved its secret, cluster capacity, namespace, RBAC, egress, and retention policy. This repository does not add a workflow or deploy anything.

```yaml
name: trusted-private ARC canary

on:
  workflow_dispatch:

jobs:
  canary:
    runs-on: trusted-private-arc
    steps:
      - run: |
          id
          test -w "$RUNNER_TEMP"
          test -w "$GITHUB_WORKSPACE"
```

Before approving that canary, capture evidence for a real JIT session and job, exactly one runner at a time, runner and pod deletion, return to zero runners, maximum-one enforcement, expected authentication and injected environment, no service-account token or socket mount, work-directory cleanup, capacity/quota behavior, log retention, egress, and a rollback to the previous execution path. These are cluster checks; none are satisfied by the values file or the offline image test.

The Ubuntu sample uses UID/GID `1001` because that identity was measured for this pinned manifest. Do not transfer that number to Debian variants: their runner identity differs. Windows remains a Windows-host deployment choice and is outside this Linux ARC sample. Base and `-dev` tags provide only their declared image dependencies; they do not imply Rust, Python, Playwright, or other language runtime availability.
