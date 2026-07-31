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
# shellcheck source=../test-harness/image-identity.sh
source "${SCRIPT_DIR}/../test-harness/image-identity.sh"

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

    # A well-formed version is not the RIGHT version.  The identity assertion
    # comes from the harness's declared-cell resolver, never from splitting a tag.
    e2e_assert_reported_component_version "$reported_core"
fi

# `wp core version` succeeds without a database, making it a real WP-CLI probe
# whose stderr contains only diagnostics rather than the version it prints.
if th_capture "WP-CLI command runs while diagnostics are captured" \
        docker exec "$CONTAINER_NAME" sh -c \
        'wp core version --path=/var/www/html --allow-root 2>&1 >/dev/null'; then
    wp_stderr="$TH_OUTPUT"
    # The wrapper exists to keep the react/promise PHP 8.5 deprecation out of
    # the user-visible WP-CLI command, so any diagnostic is a regression.
    th_assert_eq "WP-CLI writes no diagnostics to stderr" "$wp_stderr" ""
else
    th_skip "WP-CLI writes no diagnostics to stderr" \
        "WP-CLI diagnostic probe did not run"
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
    # class (#996) rather than encoding a stale observation. OPcache is inherited
    # from the base image as a static build and `php -m` spells it `Zend OPcache`.
    for ext in mysqli json curl gd zip apcu sodium; do
        # The module list is line-oriented, so each ordinary extension must
        # appear as its own complete line rather than as an incidental substring.
        if grep -qix "$ext" <<< "$TH_OUTPUT"; then
            th_pass "extension $ext is loaded"
        else
            th_fail "extension $ext is loaded" "not present in php -m"
        fi
    done

    # OPcache uses PHP's `Zend OPcache` module name, not the `opcache` spelling
    # used in configuration, so it needs an explicit whole-line check.
    if grep -qix "Zend OPcache" <<< "$TH_OUTPUT"; then
        th_pass "extension Zend OPcache is loaded"
    else
        th_fail "extension Zend OPcache is loaded" "not present in php -m"
    fi
else
    th_skip "the required extensions are loaded" "php -m did not run"
fi

th_group "WP-CLI error reporting"

# This derives the expected WP-CLI mask from the live base PHP policy instead
# of freezing an integer that would conceal a legitimate base-image policy change.
if th_capture "PHP reports the base error-reporting mask" \
        docker exec "$CONTAINER_NAME" php -r 'echo error_reporting() & ~E_DEPRECATED;'; then
    expected_error_reporting="$TH_OUTPUT"

    # The wrapper must remove deprecations from that live base policy and leave
    # every other reporting bit unchanged.
    if th_capture "WP-CLI reports its error-reporting mask" \
            docker exec "$CONTAINER_NAME" wp eval 'echo error_reporting();' \
            --skip-wordpress --allow-root; then
        actual_error_reporting="$TH_OUTPUT"
        th_assert_eq "WP-CLI subtracts only deprecations from the base policy" \
            "$actual_error_reporting" "$expected_error_reporting"
    else
        th_skip "WP-CLI subtracts only deprecations from the base policy" \
            "WP-CLI error-reporting probe did not run"
    fi
else
    th_skip "WP-CLI subtracts only deprecations from the base policy" \
        "base PHP error-reporting probe did not run"
fi

# The shared PHP configuration serves PHP-FPM too, so deprecations must remain
# enabled for a plain PHP process. This is what fails if anyone reaches for the
# `zz-` rename instead of the wrapper.
#
# PHP decides and reports through its EXIT STATUS rather than printing a number
# for the host to compare. `th_assert_ge`/`th_assert_gt` evaluate their operand
# in a Bash arithmetic context, where a value like `x[$(cmd)0]` coming out of
# the container would run `cmd` on the host running this suite. Nothing here
# needs a number, so nothing here produces one.
if docker exec "$CONTAINER_NAME" \
        php -r 'exit((error_reporting() & E_DEPRECATED) ? 0 : 1);' >/dev/null 2>&1; then
    th_pass "shared PHP configuration still reports deprecations"
else
    th_fail "shared PHP configuration still reports deprecations" \
        "a plain php process does not report E_DEPRECATED"
fi

# The two files this container used to write into conf.d both configured a PHP
# that the base image's php.ini configures again afterwards, php.ini sorting
# later. Their absence is the fix, so it is asserted by name.
#
# By NAME is the whole bound: this catches those two files coming back, not the
# behaviour they had. A reintroduction under a name sorting after php.ini —
# `zz-opcache.ini`, say — would actually take effect and would pass here. What
# covers that case is the assertion below on an effective value, plus the mask
# assertion above; between them the settings this image is documented to have
# are checked directly rather than inferred from a directory listing.
if th_capture "the container lists its PHP configuration directory" \
        docker exec "$CONTAINER_NAME" ls -1 /usr/local/etc/php/conf.d/; then
    conf_d_listing="$TH_OUTPUT"
    for dead_ini in opcache-wordpress.ini cli-no-deprecated.ini; do
        if grep -qix "$dead_ini" <<< "$conf_d_listing"; then
            th_fail "conf.d carries no $dead_ini" "the file is back in conf.d"
        else
            th_pass "conf.d carries no $dead_ini"
        fi
    done
else
    th_skip "conf.d carries neither dead override" "the conf.d listing did not run"
fi

# README and the 2026-05-08 post both tell readers that changed code is picked
# up on restart rather than on save. That is only true while the base keeps
# opcache.validate_timestamps at 0, and nothing else in this suite would notice
# it changing — so the documented promise is asserted here.
if th_capture "PHP reports opcache.validate_timestamps" \
        docker exec "$CONTAINER_NAME" php -r 'echo ini_get("opcache.validate_timestamps");'; then
    th_assert_eq "opcache.validate_timestamps is 0, as the docs promise" \
        "$TH_OUTPUT" "0"
else
    th_skip "opcache.validate_timestamps is 0, as the docs promise" \
        "the opcache.validate_timestamps probe did not run"
fi

# Both probes above ask PHP-CLI, while what the documentation describes is
# WordPress served through PHP-FPM. The two agree only because nothing overrides
# these settings per pool — and the pool file DOES use that mechanism, carrying
# php_admin_flag entries for log_errors and fastcgi.logging today. One line for
# error_reporting or any opcache key would contradict the docs while every CLI
# probe above stayed green, so the pool config is checked for exactly that
# rather than left to a FastCGI request this suite has no client for.
if th_capture "the pool configuration is readable" \
        docker exec "$CONTAINER_NAME" sh -c \
        'cat /usr/local/etc/php-fpm.conf /usr/local/etc/php-fpm.d/*.conf'; then
    if grep -qiE '^[[:space:]]*php_(admin_)?(value|flag)\[[[:space:]]*(error_reporting|opcache\.)' \
            <<< "$TH_OUTPUT"; then
        th_fail "no pool override contradicts the CLI-probed settings" \
            "the FPM pool sets error_reporting or an opcache key per pool"
    else
        th_pass "no pool override contradicts the CLI-probed settings"
    fi
else
    th_skip "no pool override contradicts the CLI-probed settings" \
        "the pool configuration did not read"
fi

th_summary
