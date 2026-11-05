# Use the published GitHub runner image with ARC

[Data, 2026-11-01] The unchanged pinned Ubuntu `github-runner:2.338.2` image passed [trusted-private ARC canary 41301908715](https://github.com/o2csi/infra/actions/runs/41301908715). Its logs verify UID `1001`, runner group `o2csi-trusted-private`, GitHub HTTP200 and blocked IMDS. Runner Pod, EphemeralRunner and JIT Secret deletion is recorded in [o2csi/infra#372](https://github.com/o2csi/infra/issues/372#issuecomment-6550406312), with `minRunners: 0` and `maxRunners: 1`. Image qualification is complete in [oorabona/docker-containers#2192](https://github.com/oorabona/docker-containers/issues/2192); further platform acceptance remains tracked in [o2csi/infra#372](https://github.com/o2csi/infra/issues/372) and [o2csi/infra#371](https://github.com/o2csi/infra/issues/371).

Use [`github-runner/examples/arc-values.yaml`](../../github-runner/examples/arc-values.yaml) with the ARC `gha-runner-scale-set` chart at `0.15.1`. The sample pins the tested linux/amd64 child manifest for `ghcr.io/oorabona/github-runner:2.338.2`; its tag is not a multi-platform index digest. It sets the runner container name to `runner`, which ARC uses when adding JIT configuration and related runner environment variables in [`newEphemeralRunnerPod`](https://github.com/actions/actions-runner-controller/blob/23159a8e2d70ca4cece740fe43a8d9eb0c2818de/controllers/actions.github.com/resourcebuilder.go#L876-L939).

## What the sample does

The runner process starts from `/home/runner/actions-runner/run.sh` with `_work` as both its Kubernetes working directory and mounted work volume. The absolute path matters because `run.sh` resolves its own location, while [ARC copies `workingDir` into the JIT `WorkFolder`](https://github.com/actions/actions-runner-controller/blob/23159a8e2d70ca4cece740fe43a8d9eb0c2818de/controllers/actions.github.com/ephemeralrunner_controller.go#L842-L853). The sample sets `RUNNER_MANUALLY_TRAP_SIG: "1"` so `run.sh` uses its signal-forwarding path for the runner helper. The image's standalone [`entrypoint.sh`](../../github-runner/entrypoint.sh#L21-L38) performs root-time ownership repair before dropping privileges, so ARC bypasses it and sets `HOME` and `RUNNER_TOOL_CACHE` to runner-writable paths instead. ARC also supplies JIT credentials; the standalone `config.sh --ephemeral` registration must not run in this pod.

[Data, source] ARC injects `ACTIONS_RUNNER_INPUT_JITCONFIG` from its JIT secret, `GITHUB_ACTIONS_RUNNER_EXTRA_USER_AGENT`, and `ACTIONS_RUNNER_RETURN_VERSION_DEPRECATED_EXIT_CODE=1` into the container named `runner`. The JIT value is base64-encoded JSON mapping filenames to base64-encoded file contents. The real listener reads this environment variable and writes the files under `/home/runner/actions-runner`; no extra registration token or `--jitconfig` argument is needed. These are [controller](https://github.com/actions/actions-runner-controller/blob/23159a8e2d70ca4cece740fe43a8d9eb0c2818de/controllers/actions.github.com/resourcebuilder.go#L876-L939) and [runner](https://github.com/actions/runner/blob/d1eb12d4b115c301201de27d667284e1a80f2ab5/src/Runner.Listener/Runner.cs#L234-L270) contracts.

The pod security context supplies UID, GID, and filesystem group `1001`, and the runner container drops every Linux capability and disallows privilege escalation. The image root filesystem remains writable: the runner writes its JIT configuration at the runner root, as shown in [`Runner.cs`](https://github.com/actions/runner/blob/d1eb12d4b115c301201de27d667284e1a80f2ab5/src/Runner.Listener/Runner.cs#L234-L267), and it also needs writable helper, diagnostic, and cache paths. The sample disables service-account token automount and retains ARC's default no-permission service account by not naming one.

`containerMode` is absent. Do not add Docker sockets, host paths, privileged containers, DinD, or Kubernetes hooks to this values file. [ARC's Kubernetes mode](https://github.com/actions/actions-runner-controller/blob/23159a8e2d70ca4cece740fe43a8d9eb0c2818de/charts/gha-runner-scale-set/templates/_helpers.tpl#L454-L535) expects `/home/runner/k8s/index.js`, work at `/home/runner/_work`, and Kubernetes permissions. This image has no hook bundle, and its runner and `externals` live under `/home/runner/actions-runner`. Selecting that mode alone will not supply the missing files or reconcile the paths. With the sample restrictions, `sudo` is unavailable, and Docker build, service-container, and container-job workflows need separately approved builder, hosted-runner, or hooks qualification. Talos uses containerd; the standalone Compose Docker socket cannot be reused as a Docker API endpoint there.

`minRunners: 0` and `maxRunners: 1` limit idle capacity and concurrency. They do not size CPU, memory, ephemeral storage, quotas, log retention, or egress. Set resource requests/limits and any `emptyDir.sizeLimit` only after workload measurement and platform approval.

## Render and inspect before a canary

Before a platform canary, replace `OWNER/PRIVATE-REPOSITORY` in your local `github-runner/examples/arc-values.yaml` with the selected trusted-private repository. Set `githubConfigSecret` to the existing secret's name in the target namespace. Keep `runnerScaleSetName` and the workflow's `runs-on` identical if renamed. Review those values before passing them to the platform integration.

Create the named GitHub configuration secret through the platform's approved secret workflow. Do not put a PAT, GitHub App key, or plaintext token in the values file.

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

For an existing local image runtime, pull the exact platform manifest and run the opt-in, no-network image test. The local test host needs Bats Core, `jq`, Mike Farah `yq` v4, `tr`, `grep`, `base64` (GNU or BSD), and a `tar` that lists with `-tv` and accepts `--numeric-owner` (GNU tar or bsdtar), plus a pre-pulled image available to Podman or Docker. It also requires GNU `timeout` or `gtimeout` with `--kill-after`; every runtime call uses `ARC_TEST_TIMEOUT` positive seconds (default 120) and a fixed five-second force-kill grace. The test's [`setup()` and `require_unused_name()`](../../github-runner/tests/test-runner-arc.bats) label containers and volumes and check new names; `remove_owned()` checks the inspected label against this run, then issues a separate removal call. A second actor can replace the resource between inspection and removal; that limitation is tracked in [oorabona/docker-containers#2223](https://github.com/oorabona/docker-containers/issues/2223). The mount of the controlled helper uses the `z` relabel option for SELinux-enforcing hosts. The `2026-11-05` results below qualify the two measured Podman hosts. Docker execution and macOS/BSD tool paths remain unqualified. Test-host evidence is tracked in [oorabona/docker-containers#2193](https://github.com/oorabona/docker-containers/issues/2193). The test uses a synthetic invalid JIT payload, never registers a runner, and requires the image to be pre-pulled when Bats starts.

[`prepare_runtime_timeout()`](../../github-runner/tests/test-runner-arc.bats) uses jq to parse and numerically normalize `ARC_TEST_TIMEOUT` as finite, strictly positive base-ten seconds, accepting optional plus signs, leading or trailing decimal points, surrounding whitespace, and decimal exponents; unset or empty input defaults to 120 seconds. `prepare_runtime_timeout()` rejects suffixes, hexadecimal forms, and values normalizing to zero or a nonfinite number; jq normalization is subject to numeric precision and rounding. [`rt()`](../../github-runner/tests/test-runner-arc.bats) uses the normalized value.

```bash
podman pull --platform linux/amd64 \
  ghcr.io/oorabona/github-runner:2.338.2@sha256:9df91c26565854fc5966ff98285789787d8e4aad0c2e3f60bc4076432d2a1877

ARC_RUNTIME_TESTS=1 \
ARC_TEST_RUNTIME=podman \
ARC_TEST_IMAGE=ghcr.io/oorabona/github-runner:2.338.2@sha256:9df91c26565854fc5966ff98285789787d8e4aad0c2e3f60bc4076432d2a1877 \
bats github-runner/tests/test-runner-arc.bats
```

The test establishes local image/JIT behavior only. Its controlled-helper case runs the real `run.sh` as PID 1 and observes TERM forwarding to that helper; it does not prove ARC job execution or cancellation. ARC injects JIT configuration into the `runner` container, and the runner writes that input under its installation root; the controller source establishes those contracts. The runner and controller sources also describe one-job cleanup and controller cleanup, but neither fact proves a real job, pod deletion, or scale-down in a target cluster. See [`Runner.cs`](https://github.com/actions/runner/blob/d1eb12d4b115c301201de27d667284e1a80f2ab5/src/Runner.Listener/Runner.cs#L568-L602) and ARC's [`cleanupResources`](https://github.com/actions/actions-runner-controller/blob/23159a8e2d70ca4cece740fe43a8d9eb0c2818de/controllers/actions.github.com/ephemeralrunner_controller.go#L569-L610).

## Local results and remaining checks

[Data, local, 2026-11-05] The command above executed all five image tests against the pinned Ubuntu manifest on both Linux/amd64 hosts. Both used Bats Core `1.14.0`, Mike Farah `yq` `4.53.3`, GNU tar and rootless Podman.

| Host | Podman | SELinux | Image tests |
|---|---|---|---|
| Ubuntu `24.04.5` LTS | `4.9.3` | Podman labeling disabled | 5/5 passed |
| Fedora CoreOS `44.20261023.3.1`, disposable KVM guest | `5.8.9` | `Enforcing`, Podman labeling enabled | 5/5 passed |

[Data, local, 2026-10-29] Rootless Podman `4.9.3` ran the published Linux/amd64 images unchanged, without network access or runner capabilities. All four contained runner `2.338.2` and working bundled glibc Node `20.20.2` and `24.22.1`; Node is not a global `PATH` command.

| Published tag | Measured UID:GID | JIT file written, then deliberate invalid AgentId rejected | Malformed JIT creates no `.runner` |
|---|---|---|---|
| `2.338.2` | `1001:1001` | Passed | Passed |
| `2.338.2-dev` | `1001:1001` | Passed | Passed |
| `2.338.2-debian-trixie` | `1000:1000` | Passed | Passed |
| `2.338.2-debian-trixie-dev` | `1000:1000` | Passed | Passed |

[Data, local] These eight probes consumed `ACTIONS_RUNNER_INPUT_JITCONFIG` with no command arguments. The synthetic `.runner` uses an intentionally invalid `AgentId` so the listener stops before registration. Both error cases can return `0` through `run.sh`: the tests check the saved file and explicit parse error, not only the exit code. UID `1001` failed with `Permission denied` on Debian. Group-only work-volume writes and the `_tool` cache override succeeded with each image's actual user. The reusable Bats suite above additionally exercises the sample's absolute work path. Its volume initialization runs separately as root with only `CHOWN`; the tested runner remains non-root. Kubernetes `fsGroup`, ARM64, Windows execution, and Docker runtime execution were not tested here.

## Qualify separate rootless accounts on one Linux host

Use fresh unprivileged `arc-a`/`arc-b` logins in a disposable Linux guest; trust its kernel and administrator. Same-UID adversaries and shared daemon/socket credentials remain unsupported. Require `0700` homes/runtime parents, separate local rootless stores, subordinate UID/GID ranges disjoint from each other and real IDs, and no accessible privileged API. An inaccessible `/var/run/docker.sock` may remain.

An administrator supplies root-owned, non-user-writable `/opt/arc-source` and preloads the pinned image into both stores. Use each login's environment; add no service, privilege or harness flag. Capture under both logins:

```bash
id
getent passwd; getent group
cat /etc/subuid /etc/subgid
stat -c '%U:%G:%a %n' "$HOME" "$XDG_RUNTIME_DIR" /opt/arc-source
printf 'CONTAINER_HOST=%q CONTAINER_CONNECTION=%q DOCKER_HOST=%q\n' "${CONTAINER_HOST-}" "${CONTAINER_CONNECTION-}" "${DOCKER_HOST-}"
podman system connection list --format json
podman info --format json | jq '.host.security, .host.serviceIsRemote, .store'
```

Require `rootless=true`, `.host.serviceIsRemote=false`, private graphroot/runroot/volume paths and `[]` connections. Record `getenforce`, kernel/tool versions, source commit/hash and image digest.

Choose the same fresh `name` under both logins. Set `image` to the pinned reference above:

```bash
name=arc-isolation-check
podman volume create --label "arc-isolation-owner=$USER" "$name"
podman run -d --name "$name" --label "arc-isolation-owner=$USER" --pull=never --network=none --cap-drop=ALL --security-opt=no-new-privileges --volume "$name:/probe" --entrypoint /bin/bash "$image" -c 'printf "%s\n" "$1" > /probe/owner; exec sleep infinity' -- "$USER"
podman inspect "$name"
podman volume inspect "$name"
podman exec "$name" cat /probe/owner
```

Exchange full container IDs and inspection receipts. Under A, remove only A's resources:

```bash
podman rm -f "$name"
podman volume rm "$name"
podman container inspect "$name"
podman volume inspect "$name"
```

Require A's lookups to report absence and B's ID, labels, volume metadata/content to remain unchanged. Recreate after each removal; reverse A/B. Use volume metadata/labels/content, not an immutable volume ID.

Create foreign-only `arc-isolation-only-a`/`arc-isolation-only-b`; exchange IDs, names and private paths. Run under both logins:

```bash
podman inspect "$foreign_container_id"
podman rm "$foreign_container_id"
podman volume inspect "$foreign_volume"
podman volume rm "$foreign_volume"
ls -ld "$foreign_graphroot" "$foreign_runroot"
podman --remote --url "unix://$foreign_socket" info
```

Require foreign lookup/removal failure, private-path/socket permission denial, successful own-resource controls, and unchanged owner receipts. A generic runtime failure alone proves nothing.

Keep the other account’s `$name` container and volume present; run under each login:

```bash
cd /opt/arc-source
TMPDIR=$(mktemp -d) || exit 1; export TMPDIR
ARC_RUNTIME_TESTS=1 ARC_TEST_RUNTIME=podman ARC_TEST_IMAGE="$image" bats github-runner/tests/test-runner-arc.bats >"$TMPDIR/arc.tap" 2>&1
bats_status=$?
printf 'bats_status=%s\n' "$bats_status"; cat "$TMPDIR/arc.tap"
podman ps -a --filter label=arc-offline-test --format json
podman volume ls --filter label=arc-offline-test --format json
```

Require exit `0`, five passes, zero skips, `[]` harness resources and unchanged peer receipts. Preserve existing image assertions: `.runner` content/numeric owner and work-directory `0:1001:2770`.

Copy commands, statuses and receipts outside the guest before deleting its identified resources. Publish measured results in [oorabona/docker-containers#2223](https://github.com/oorabona/docker-containers/issues/2223); the existing host table supplies no two-account result.

## Cache and canary boundaries

For dependency caches, use `actions/cache` for selected workflow paths. Do not cache the runner root, `.runner`, credentials, `_work`, or a shared catch-all PVC. The container's writable layer and the pod's `_work` emptyDir disappear when the pod is removed; cached OCI image layers may remain on the node. Any tool or package cache not restored by the workflow also disappears.

The following is an inert workflow example for a manually approved trusted-private canary. It belongs in the consuming private repository only after the platform has installed ARC and approved its secret, cluster capacity, namespace, RBAC, egress, and retention policy. This repository does not add a workflow or deploy anything.

```yaml
name: trusted-private ARC canary

on:
  workflow_dispatch:

permissions: {}

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
