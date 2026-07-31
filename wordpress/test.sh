#!/bin/bash
# E2E test for the wordpress container.
#
# Uses the repository's test harness so the exit code is the verdict. The runner
# starts the image's PHP-FPM command, so this suite verifies the usable WordPress
# core and the long-running FPM process rather than only files and binaries.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../test-harness/test-harness.sh
source "${SCRIPT_DIR}/../test-harness/test-harness.sh"

CONTAINER_NAME="${CONTAINER_NAME:-e2e-wordpress}"

th_init --name "WordPress E2E" --report "${REPORT_FORMAT:-table}"

th_group "WordPress"

# `wp core version` loads the installed tree through WP-CLI. It works without a
# configured database, which matches the harness run profile, while a plain
# `wp --version` only proves that the phar is on PATH.
if th_capture "WP-CLI loads the installed WordPress core" \
        docker exec "$CONTAINER_NAME" wp core version --path=/var/www/html --allow-root; then
    reported_core="$TH_OUTPUT"
    # Anchored at both ends: "6.9-corrupt-output" satisfies a leading-anchor-only
    # pattern, and this is the only assertion about the core's identity.
    th_assert_matches "WP-CLI reports the installed WordPress core version" \
        "$reported_core" '^[0-9]+\.[0-9]+(\.[0-9]+)?$'

    # A well-formed version is not the RIGHT version: the tag says which release
    # this image is, so a 7.0.2 build shipping 6.9.4 has to fail rather than pass
    # for looking version-shaped.
    expected_core=""
    if [ -n "${E2E_IMAGE:-}" ]; then
        expected_core="${E2E_IMAGE##*:}"
        expected_core="${expected_core%%-*}"
    fi
    if [[ "$expected_core" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
        th_assert_eq "the core version matches the image tag ($expected_core)" \
            "$reported_core" "$expected_core"
    else
        th_skip "the core version matches the image tag" \
            "tag '${expected_core:-none}' carries no version"
    fi
fi

# `wp core version` is a before_wp_load command: it reads wp-includes/version.php
# and never loads WordPress, so it answers for a tree that is missing most of
# core. The file check is what covers that, which is why it stays alongside.
if docker exec "$CONTAINER_NAME" test -f /var/www/html/wp-settings.php >/dev/null 2>&1; then
    th_pass "the WordPress core files are in place"
else
    th_fail "the WordPress core files are in place" "/var/www/html/wp-settings.php is absent"
fi

th_group "PHP-FPM"

# docker-entrypoint.sh ends with `exec "$@"`, so PID 1 is the PHP-FPM master
# process when the image's default command is healthy. This verifies the service
# the run profile actually starts; it avoids inventing an HTTP check for an image
# that exposes FastCGI only and has no host port published by the runner.
# The first argv token, not a substring of the whole vector: `sh -c 'sleep inf
# # php-fpm'` contains the word while no FPM exists anywhere.
# Resolved through /proc/1/exe, not the name PID 1 was invoked under: a prefix
# match on argv accepts `php-fpm-placeholder`, and argv is whatever the process
# chose to call itself.
if docker exec "$CONTAINER_NAME" sh -c \
    'exe=$(readlink /proc/1/exe 2>/dev/null) && [ "${exe##*/}" = "php-fpm" ]'; then
    th_pass "PHP-FPM is running as the container's master process"
else
    th_fail "PHP-FPM is running as the container's master process" \
        "PID 1 is not php-fpm"
fi

th_group "Extensions"

# Kept alongside the runtime checks above, not replaced by them: a WordPress that
# answers `wp core version` still fails at runtime if an extension it needs went
# missing, and an install list that silently drops one is not hypothetical — it
# happened to the php image, where asking for OPcache dropped zip and apcu (#996).
# A `php -m` that did not run says nothing about which extensions are loaded, so
# its failure is recorded once and the per-extension checks are skipped rather
# than reported as three separate absences.
if th_capture "php -m lists the loaded extensions" \
        docker exec "$CONTAINER_NAME" php -m; then
    # Everything the Dockerfile promises and a current build carries. `zip` and
    # `apcu` are here because a freshly pulled image has them — they were missing
    # only from an older pinned tag, so asserting them catches the silent-drop
    # class (#996) rather than encoding a stale observation.
    #
    # OPcache is deliberately absent from this list and is NOT an oversight: the
    # base has not shipped it since #996 removed it, while this image's Dockerfile
    # still claims it and writes an opcache ini that configures nothing. Asserting
    # it would fail every build until that contradiction is settled, which is
    # #1017's job; asserting nothing at all is what let it go unnoticed.
    for ext in mysqli json curl gd zip apcu; do
        if grep -qix "$ext" <<< "$TH_OUTPUT"; then
            th_pass "extension $ext is loaded"
        else
            th_fail "extension $ext is loaded" "not present in php -m"
        fi
    done
else
    th_skip "the required extensions are loaded" "php -m did not run"
fi

th_summary
