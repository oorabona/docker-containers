#!/bin/bash
# E2E test for the terraform container.
#
# Uses the repository's test harness so the exit code is the verdict. This suite
# previously had no failure path at all: every check warned, and the final line
# announced success unconditionally, so it passed against an empty container.
#
# The image is a CLI with no long-running process, so the harness starts it with
# its entrypoint overridden — see the terraform case in tests/e2e-test.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../test-harness/test-harness.sh
source "${SCRIPT_DIR}/../test-harness/test-harness.sh"
# shellcheck source=../test-harness/image-identity.sh
source "${SCRIPT_DIR}/../test-harness/image-identity.sh"

CONTAINER_NAME="${CONTAINER_NAME:-e2e-terraform}"

th_init --name "Terraform E2E" --report "${REPORT_FORMAT:-table}"

th_group "Binary"

th_assert_cmd_contains "terraform reports its version" "Terraform" \
    docker exec "$CONTAINER_NAME" terraform version

th_group "Configuration handling"

# The old check wrote `{}` into main.tf and treated the failure as "may need
# providers". A .tf file is HCL, not JSON, so `{}` is a syntax error — the
# warning was hiding a malformed fixture rather than a limitation. With a valid
# empty configuration, init and validate both succeed.
if docker exec "$CONTAINER_NAME" sh -c \
    'rm -rf /tmp/e2e-tf && mkdir -p /tmp/e2e-tf && cd /tmp/e2e-tf &&
     printf "terraform {}\n" > main.tf &&
     terraform init -backend=false >/dev/null 2>&1 && terraform validate >/dev/null 2>&1' \
    >/dev/null 2>&1; then
    th_pass "init and validate accept a minimal configuration"
else
    th_fail "init and validate accept a minimal configuration" \
        "terraform init -backend=false && terraform validate failed on 'terraform {}'"
fi

th_group "Entrypoint"

# tests/e2e-test.sh overrides this image's entrypoint so the CLI container stays
# alive. Invoke the shipped entrypoint explicitly: rendering a template and then
# reaching `terraform version` proves both halves of its normal execution path.
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
    th_pass "entrypoint renders a Terraform template before running Terraform"
else
    th_fail "entrypoint renders a Terraform template before running Terraform" \
        "the rendered .tf file or entrypoint Terraform invocation failed"
fi

th_group "Flavor-specific cloud tooling"

# TERRAFORM_FLAVOR is the image's account of its flavor.  The harness supplies
# the independently resolved declared cell, so a locally discovered image gets
# the same assertion as an E2E_IMAGE run.

if th_capture "Terraform image declares its flavor" \
        docker exec "$CONTAINER_NAME" sh -c 'printf %s "$TERRAFORM_FLAVOR"'; then
    flavor="$TH_OUTPUT"

    e2e_assert_declared_flavor "$flavor"
    flavor_tools=()

    case "$flavor" in
        base) ;;  # nothing to provide; the exclusion loop below is its contract
        aws) flavor_tools=(aws) ;;
        azure) flavor_tools=(az) ;;
        gcp) flavor_tools=(gcloud) ;;
        full) flavor_tools=(aws az gcloud) ;;
        *) th_fail "Terraform image declares a supported flavor" \
               "expected base, aws, azure, gcp, or full; got '$flavor'" ;;
    esac

    # Run each CLI rather than locating it: a launcher can be on PATH and still
    # fail on its first call because its interpreter, a Python module or a shared
    # library did not come with it. `--version` is the cheapest call that proves
    # the thing actually starts, and it touches no network.
    for tool in "${flavor_tools[@]}"; do
        if docker exec "$CONTAINER_NAME" sh -c '"$1" --version >/dev/null 2>&1' _ "$tool"; then
            th_pass "$flavor flavor provides a working $tool"
        else
            th_fail "$flavor flavor provides a working $tool" \
                "$tool is missing, or it is on PATH but does not run"
        fi
    done

    # The reduced flavors exist to be smaller and expose less, so the CLIs they
    # exclude are part of the contract too — without this, a build that quietly
    # shipped all three would pass every flavor.
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

# Promised by every flavor in the README, and dropping one is exactly the kind of
# silent regression a flavor rebuild can introduce.
for tool in git curl jq; do
    # `command -v` is a POSIX shell builtin; `which` is a separate package that
    # RHEL-family minimal images do not ship.
    if docker exec "$CONTAINER_NAME" sh -c 'command -v "$1" >/dev/null 2>&1' _ "$tool"; then
        th_pass "$tool is on PATH"
    else
        th_fail "$tool is on PATH" "command -v $tool found nothing"
    fi
done

th_summary
