#!/bin/bash
# E2E test for the OpenTofu container.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../test-harness/test-harness.sh
source "${SCRIPT_DIR}/../test-harness/test-harness.sh"
# shellcheck source=../test-harness/image-identity.sh
source "${SCRIPT_DIR}/../test-harness/image-identity.sh"

CONTAINER_NAME="${CONTAINER_NAME:-e2e-opentofu}"

th_init --name "OpenTofu E2E" --report "${REPORT_FORMAT:-table}"

th_group "Binary"

th_assert_cmd_contains "tofu reports its version" "OpenTofu" \
    docker exec "$CONTAINER_NAME" tofu version

th_group "Configuration handling"

if docker exec "$CONTAINER_NAME" sh -c \
    'rm -rf /tmp/e2e-tf && mkdir -p /tmp/e2e-tf && cd /tmp/e2e-tf &&
     printf "terraform {}\n" > main.tf &&
     tofu init -backend=false >/dev/null 2>&1 && tofu validate >/dev/null 2>&1' \
    >/dev/null 2>&1; then
    th_pass "init and validate accept a minimal configuration"
else
    th_fail "init and validate accept a minimal configuration" \
        "tofu init -backend=false && tofu validate failed on 'terraform {}'"
fi

th_group "Entrypoint"

# tests/e2e-test.sh overrides this image's entrypoint so the CLI container stays
# alive. Invoke the shipped entrypoint explicitly: rendering a template and then
# reaching `tofu version` proves both halves of its normal execution path.
if docker exec "$CONTAINER_NAME" sh -c '
    work=$(mktemp -d) &&
    cd "$work" &&
    printf "%s\\n" "{\"message\": \"rendered-by-entrypoint\"}" > config.json &&
    printf "%s\\n" \
        "output \"message\" {" \
        "  value = \"{{ message }}\"" \
        "}" > generated.tf.j2 &&
    /docker-entrypoint.sh version >/dev/null &&
    test -f generated.tf &&
    grep -Fqx "  value = \"rendered-by-entrypoint\"" generated.tf
'; then
    th_pass "entrypoint renders an OpenTofu template before running OpenTofu"
else
    th_fail "entrypoint renders an OpenTofu template before running OpenTofu" \
        "the rendered .tf file or entrypoint OpenTofu invocation failed"
fi

th_group "Flavor-specific cloud tooling"

if th_capture "OpenTofu image declares its flavor" \
        docker exec "$CONTAINER_NAME" sh -c 'printf %s "$TOFU_FLAVOR"'; then
    flavor="$TH_OUTPUT"

    e2e_assert_declared_flavor "$flavor"
    flavor_tools=()

    case "$flavor" in
        base) ;;
        aws) flavor_tools=(aws) ;;
        azure) flavor_tools=(az) ;;
        gcp) flavor_tools=(gcloud) ;;
        full) flavor_tools=(aws az gcloud) ;;
        *) th_fail "OpenTofu image declares a supported flavor" \
               "expected base, aws, azure, gcp, or full; got '$flavor'" ;;
    esac

    for tool in "${flavor_tools[@]}"; do
        if docker exec "$CONTAINER_NAME" sh -c '"$1" --version >/dev/null 2>&1' _ "$tool"; then
            th_pass "$flavor flavor provides a working $tool"
        else
            th_fail "$flavor flavor provides a working $tool" \
                "$tool is missing, or it is on PATH but does not run"
        fi
    done

    for tool in aws az gcloud; do
        case " ${flavor_tools[*]} " in
            *" $tool "*) continue ;;
        esac
        if docker exec "$CONTAINER_NAME" sh -c 'command -v "$1" >/dev/null 2>&1' _ "$tool"; then
            th_fail "$flavor flavor excludes $tool" "$tool is present in a flavor that should not carry it"
        else
            th_pass "$flavor flavor excludes $tool"
        fi
    done
fi

th_group "Base utilities"

for tool in git curl jq; do
    if docker exec "$CONTAINER_NAME" sh -c 'command -v "$1" >/dev/null 2>&1' _ "$tool"; then
        th_pass "$tool is on PATH"
    else
        th_fail "$tool is on PATH" "command -v $tool found nothing"
    fi
done

th_summary
