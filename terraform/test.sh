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

CONTAINER_NAME="${CONTAINER_NAME:-e2e-terraform}"

th_init --name "Terraform E2E" --report "${REPORT_FORMAT:-table}"

th_group "Binary"

version=$(docker exec "$CONTAINER_NAME" terraform version 2>/dev/null | head -1)
th_assert_contains "terraform reports its version" "$version" "Terraform"

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

th_group "Entrypoint dependencies"

# The image entrypoint renders *.tf.j2 through jinja2 before running terraform,
# so a missing jinja2 breaks every templated configuration while `terraform
# version` still answers.
if docker exec "$CONTAINER_NAME" sh -c 'command -v jinja2 >/dev/null 2>&1'; then
    th_pass "jinja2 is installed for the entrypoint's template rendering"
else
    th_fail "jinja2 is installed for the entrypoint's template rendering" "command -v jinja2 found nothing"
fi

th_group "Tools"

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
