#!/bin/bash
# E2E test for the jekyll container.
#
# Uses the repository's test harness so the exit code is the verdict. Bundler was
# a warning; it holds on the published image, and a Jekyll image without it
# cannot install a site's gems, so it is asserted.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../test-harness/test-harness.sh
source "${SCRIPT_DIR}/../test-harness/test-harness.sh"

CONTAINER_NAME="${CONTAINER_NAME:-e2e-jekyll}"

th_init --name "Jekyll E2E" --report "${REPORT_FORMAT:-table}"

th_group "Ruby toolchain"

# Was printed and never read, so an image with no ruby reached the end.
th_assert_cmd_contains "ruby reports its version" "ruby" \
    docker exec "$CONTAINER_NAME" ruby --version

# Bundler 4 prints a bare version number — no "Bundler" anywhere in it — so the
# assertion is on the shape of what it prints, not on a word.
th_capture "bundler reports a version" docker exec "$CONTAINER_NAME" bundle --version &&
    th_assert_matches "bundler reports a version" "$TH_OUTPUT" '[0-9]+\.[0-9]+'

th_group "Jekyll"

th_assert_cmd_contains "jekyll reports its version" "jekyll" \
    docker exec "$CONTAINER_NAME" jekyll --version

th_summary
