#!/bin/bash
# E2E test for the ansible container.
#
# Uses the repository's test harness so the exit code is the verdict: every check
# is recorded, the run continues past a failure so all of them are reported, and
# th_summary returns non-zero if any failed. The previous version printed
# "All Ansible tests passed" unconditionally.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../test-harness/test-harness.sh
source "${SCRIPT_DIR}/../test-harness/test-harness.sh"

CONTAINER_NAME="${CONTAINER_NAME:-e2e-ansible}"

th_init --name "Ansible E2E" --report "${REPORT_FORMAT:-table}"

th_group "Interpreter and tooling"

# The version banner used to be printed and never read, so an image with no
# ansible at all still reached the end of the script.
version=$(docker exec "$CONTAINER_NAME" ansible --version 2>/dev/null | head -1)
th_assert_contains "ansible reports its version" "$version" "ansible"

playbook=$(docker exec "$CONTAINER_NAME" ansible-playbook --version 2>/dev/null | head -1)
th_assert_contains "ansible-playbook is installed" "$playbook" "ansible-playbook"

th_group "Module execution"

# What the image is for: run a module against localhost over the local
# connection, which needs the interpreter, the module path and the config to be
# right at once.
ping=$(docker exec "$CONTAINER_NAME" ansible localhost -m ping -c local 2>/dev/null | grep -c SUCCESS)
th_assert_ge "the ping module reports SUCCESS" "${ping:-0}" 1

th_summary
