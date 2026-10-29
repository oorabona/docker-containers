#!/usr/bin/env bats

load "../test_helper"

setup() {
    VALUES="$PROJECT_ROOT/github-runner/examples/arc-values.yaml"
    setup_temp_dir
}

teardown() {
    teardown_temp_dir
}

@test "ARC values run the immutable amd64 image directly from its writable runner layout" {
    [ "$(yq -r '.githubConfigUrl' "$VALUES")" = 'https://github.com/OWNER/PRIVATE-REPOSITORY' ]
    [ "$(yq -r '.githubConfigSecret | type' "$VALUES")" = '!!str' ]
    [ "$(yq -r '.minRunners' "$VALUES")" = 0 ]
    [ "$(yq -r '.maxRunners' "$VALUES")" = 1 ]
    [ "$(yq -r '.template.spec.nodeSelector."kubernetes.io/os"' "$VALUES")" = linux ]
    [ "$(yq -r '.template.spec.nodeSelector."kubernetes.io/arch"' "$VALUES")" = amd64 ]

    runner=$(yq -o=json '.template.spec.containers[] | select(.name == "runner")' "$VALUES")
    [ "$(jq -r '.image' <<< "$runner")" = 'ghcr.io/oorabona/github-runner:2.338.2@sha256:9df91c26565854fc5966ff98285789787d8e4aad0c2e3f60bc4076432d2a1877' ]
    [ "$(jq -c '.command' <<< "$runner")" = '["/home/runner/actions-runner/run.sh"]' ]
    [ "$(jq -r '.workingDir' <<< "$runner")" = /home/runner/actions-runner/_work ]
    [ "$(jq -r '.env[] | select(.name == "HOME") | .value' <<< "$runner")" = /home/runner ]
    [ "$(jq -r '.env[] | select(.name == "RUNNER_TOOL_CACHE") | .value' <<< "$runner")" = /home/runner/actions-runner/_tool ]
    [ "$(jq -r '.volumeMounts[] | select(.name == "work") | .mountPath' <<< "$runner")" = /home/runner/actions-runner/_work ]
    [ "$(yq -r '.template.spec.volumes | length' "$VALUES")" = 1 ]
    [ "$(yq -r '.template.spec.volumes[0].name' "$VALUES")" = work ]
    [ "$(yq -r '.template.spec.volumes[0].emptyDir | type' "$VALUES")" = '!!map' ]
}

@test "ARC values keep pod and runner-container restrictions in their Kubernetes fields" {
    [ "$(yq -r '.template.spec.automountServiceAccountToken' "$VALUES")" = false ]
    [ "$(yq -r '.template.spec.securityContext.runAsNonRoot' "$VALUES")" = true ]
    [ "$(yq -r '.template.spec.securityContext.runAsUser' "$VALUES")" = 1001 ]
    [ "$(yq -r '.template.spec.securityContext.runAsGroup' "$VALUES")" = 1001 ]
    [ "$(yq -r '.template.spec.securityContext.fsGroup' "$VALUES")" = 1001 ]
    [ "$(yq -r '.template.spec.securityContext.seccompProfile.type' "$VALUES")" = RuntimeDefault ]

    runner=$(yq -o=json '.template.spec.containers[] | select(.name == "runner")' "$VALUES")
    [ "$(jq -r '.securityContext.allowPrivilegeEscalation' <<< "$runner")" = false ]
    [ "$(jq -r '.securityContext.privileged' <<< "$runner")" != true ]
    [ "$(jq -c '.securityContext.capabilities.drop' <<< "$runner")" = '["ALL"]' ]
    [ "$(yq -r 'has("containerMode")' "$VALUES")" = false ]
    [ "$(yq -r '[.template.spec.volumes[]? | has("hostPath")] | any' "$VALUES")" = false ]
    [ "$(yq -r '[.template.spec.containers[]?.volumeMounts[]?.mountPath | select(. == "/var/run/docker.sock")] | length' "$VALUES")" = 0 ]
}

@test "ARC values reject unsafe mutations in an isolated copy" {
    cp "$VALUES" "$TEST_TEMP_DIR/unsafe.yaml"
    yq -i '.template.spec.containers[0].command = ["/entrypoint.sh"] | .template.spec.containers[0].workingDir = "/home/runner/actions-runner" | .template.spec.securityContext.runAsUser = 0 | .template.spec.containers[0].securityContext.privileged = true | .template.spec.volumes += [{"name": "socket", "hostPath": {"path": "/var/run/docker.sock"}}] | .githubConfigSecret = {"github_token": "plaintext"}' "$TEST_TEMP_DIR/unsafe.yaml"

    run yq -e '.template.spec.containers[] | select(.name == "runner") | (.command == ["/home/runner/actions-runner/run.sh"] and .workingDir == "/home/runner/actions-runner/_work" and .securityContext.privileged != true)' "$TEST_TEMP_DIR/unsafe.yaml"
    [ "$status" -ne 0 ]
    run yq -e '(.template.spec.securityContext.runAsUser == 1001) and ([.template.spec.volumes[]? | has("hostPath")] | any | not) and (.githubConfigSecret | type == "!!str")' "$TEST_TEMP_DIR/unsafe.yaml"
    [ "$status" -ne 0 ]
}
