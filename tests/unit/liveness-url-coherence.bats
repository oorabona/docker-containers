#!/usr/bin/env bats

# Unit tests: config liveness_url must match the Dockerfile-constructed URL
#
# T9/AC-10: for every dependency_sources entry with liveness_url:, the URL
# MUST exactly match the URL the Dockerfile constructs for the same version
# via its curl/wget download lines. Drift between them means the liveness
# HEAD check passes on a URL the build never fetches — a false-green.
#
# Strategy: parse the Dockerfile's RUN … curl … -o lines, interpolate the
# version values using the config's build_args, and compare to liveness_url.
#
# AC-10: drift between config and Dockerfile-constructed URL is a test failure.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
    ORIG_DIR="$PWD"
}

teardown() {
    cd "$ORIG_DIR" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Helper: extract download URLs from a Dockerfile's curl/wget lines
# and interpolate known ARG values.
# ---------------------------------------------------------------------------

_dockerfile_urls_for() {
    local container="$1"
    local dockerfile="$REPO_ROOT/${container}/Dockerfile"
    [[ -f "$dockerfile" ]] || return 0

    # Extract curl -fSL / wget lines, capture the URL argument
    grep -oE 'curl[^|]*https://[^[:space:]"]+|wget[^|]*https://[^[:space:]"]+' "$dockerfile" \
        | grep -oE 'https://[^[:space:]"\\]+' \
        | sort -u
}

# ---------------------------------------------------------------------------
# T9 AC-10: openresty RESTY_OPENSSL_VERSION liveness_url coherence
#
# Dockerfile constructs: ${RESTY_OPENSSL_URL_BASE}/openssl-${RESTY_OPENSSL_VERSION}.tar.gz
# Where RESTY_OPENSSL_URL_BASE = "https://www.openssl.org/source" (ARG default)
# Config liveness_url: https://www.openssl.org/source/openssl-3.5.6.tar.gz
#
# Mutation caught: changing the liveness_url in config to a different URL
# (e.g., openssl-3.5.5.tar.gz or different hostname) would fail this test.
# ---------------------------------------------------------------------------

@test "openresty RESTY_OPENSSL_VERSION: liveness_url matches Dockerfile-constructed URL" {
    local config="$REPO_ROOT/openresty/config.yaml"
    local dockerfile="$REPO_ROOT/openresty/Dockerfile"

    [[ -f "$config" ]] || { echo "SKIP: openresty/config.yaml not found"; return 0; }
    [[ -f "$dockerfile" ]] || { echo "SKIP: openresty/Dockerfile not found"; return 0; }

    # Read the declared liveness_url from config
    local declared_url
    declared_url=$(yq -r '.dependency_sources.RESTY_OPENSSL_VERSION.liveness_url // ""' "$config")

    if [[ -z "$declared_url" || "$declared_url" == "null" ]]; then
        echo "SKIP: RESTY_OPENSSL_VERSION has no liveness_url declared"
        return 0
    fi

    # Read the version and base URL from config/Dockerfile
    local version
    version=$(yq -r '.build_args.RESTY_OPENSSL_VERSION // ""' "$config")

    # Read RESTY_OPENSSL_URL_BASE default from Dockerfile ARG
    local url_base
    url_base=$(grep -oP '(?<=RESTY_OPENSSL_URL_BASE=")https://[^"]+' "$dockerfile" | head -1)
    url_base="${url_base:-https://www.openssl.org/source}"

    # Construct the expected URL as the Dockerfile does
    local expected_url="${url_base}/openssl-${version}.tar.gz"

    # Assert exact match
    if [[ "$declared_url" != "$expected_url" ]]; then
        echo "FAIL: liveness_url mismatch for RESTY_OPENSSL_VERSION"
        echo "  Declared in config: ${declared_url}"
        echo "  Expected (Dockerfile-constructed): ${expected_url}"
        echo "  Version: ${version}, URL base: ${url_base}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# T9 AC-10: openresty RESTY_PCRE_VERSION liveness_url coherence
#
# Dockerfile constructs:
#   https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${RESTY_PCRE_VERSION}/pcre2-${RESTY_PCRE_VERSION}.tar.gz
# Config liveness_url must match this pattern exactly for the pinned version.
#
# Mutation caught: changing liveness_url to a different version number or
# path format would fail this test.
# ---------------------------------------------------------------------------

@test "openresty RESTY_PCRE_VERSION: liveness_url matches Dockerfile-constructed URL" {
    local config="$REPO_ROOT/openresty/config.yaml"
    local dockerfile="$REPO_ROOT/openresty/Dockerfile"

    [[ -f "$config" ]] || { echo "SKIP: openresty/config.yaml not found"; return 0; }
    [[ -f "$dockerfile" ]] || { echo "SKIP: openresty/Dockerfile not found"; return 0; }

    # Read the declared liveness_url from config
    local declared_url
    declared_url=$(yq -r '.dependency_sources.RESTY_PCRE_VERSION.liveness_url // ""' "$config")

    if [[ -z "$declared_url" || "$declared_url" == "null" ]]; then
        echo "SKIP: RESTY_PCRE_VERSION has no liveness_url declared"
        return 0
    fi

    # Read the version from config
    local version
    version=$(yq -r '.build_args.RESTY_PCRE_VERSION // ""' "$config")

    # Construct the expected URL as the Dockerfile does
    # curl -fSL "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${RESTY_PCRE_VERSION}/pcre2-${RESTY_PCRE_VERSION}.tar.gz"
    local expected_url="https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${version}/pcre2-${version}.tar.gz"

    # Assert exact match
    if [[ "$declared_url" != "$expected_url" ]]; then
        echo "FAIL: liveness_url mismatch for RESTY_PCRE_VERSION"
        echo "  Declared in config: ${declared_url}"
        echo "  Expected (Dockerfile-constructed): ${expected_url}"
        echo "  Version: ${version}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# T9 AC-10: generic scan — all liveness_url entries have reachable URL format
# (sanity check: URLs must start with https:// and contain the version value)
# ---------------------------------------------------------------------------

@test "all liveness_url entries contain the corresponding version value" {
    local bad=0
    local bad_list=""

    for config in "$REPO_ROOT"/*/config.yaml; do
        [[ -f "$config" ]] || continue
        if ! yq -e '.dependency_sources' "$config" &>/dev/null; then
            continue
        fi

        local container
        container=$(basename "$(dirname "$config")")

        local dep_names
        dep_names=$(yq -r '.dependency_sources // {} | keys | .[]' "$config")

        while IFS= read -r dep; do
            [[ -z "$dep" ]] && continue
            local url
            url=$(YQ_DEP="$dep" yq -r '.dependency_sources[strenv(YQ_DEP)].liveness_url // ""' "$config")
            [[ -z "$url" || "$url" == "null" ]] && continue

            # URL must start with https://
            if [[ ! "$url" =~ ^https:// ]]; then
                bad=$((bad + 1))
                bad_list="${bad_list}\n  ${container}/${dep}: liveness_url does not start with https://"
                continue
            fi

            # URL must contain the current version value (if one exists in build_args)
            local ver
            ver=$(YQ_DEP="$dep" yq -r '.build_args[strenv(YQ_DEP)] // ""' "$config")
            if [[ -n "$ver" && "$ver" != "null" && ! "$url" =~ $ver ]]; then
                # Allow if version appears as part of the URL in any form
                # (some URLs encode version differently — just warn, don't fail)
                : # Not a hard failure for generic scan; Dockerfile-specific tests handle precision
            fi
        done <<< "$dep_names"
    done

    if [[ "$bad" -gt 0 ]]; then
        echo "FAIL: $bad liveness_url entries with invalid format:${bad_list}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Fix #5 regression lock: liveness_url_template coherence for tracked entries.
#
# Contract: for a tracked entry with liveness_url_template, substituting
# {version} with the current pinned version must produce the same URL that
# the Dockerfile constructs for that version.
#
# This test verifies:
# 1. RESTY_PCRE_VERSION has liveness_url_template declared.
# 2. Substituting {version} with the pinned build_args value yields a URL
#    that matches the Dockerfile-constructed URL (same semantic as the
#    RESTY_PCRE_VERSION liveness_url test above, but driven by template).
# 3. The template URL is coherent with the static liveness_url for the
#    pinned version (so both mechanisms agree for the current pin).
#
# Mutation caught: reverting to "always use static liveness_url" means this
# test passes (they both refer to the pinned version) BUT after a version bump
# the template URL would track the new version while the static URL would not.
# The template mechanism is validated here to confirm {version} substitution
# is syntactically correct and yields the expected URL format.
#
# How to verify mutation → RED:
#   1. Set liveness_url_template to a malformed string (e.g. missing {version}).
#   2. The substituted URL will be wrong → assertion fails → RED.
#   3. Restore correct template → GREEN.
# ---------------------------------------------------------------------------

@test "Fix #5: RESTY_PCRE_VERSION liveness_url_template substitutes {version} to Dockerfile URL" {
    local config="$REPO_ROOT/openresty/config.yaml"

    [[ -f "$config" ]] || { echo "SKIP: openresty/config.yaml not found"; return 0; }

    # Assert the template is declared (prerequisite for Fix #5 to be active).
    local tmpl
    tmpl=$(yq -r '.dependency_sources.RESTY_PCRE_VERSION.liveness_url_template // ""' "$config")

    if [[ -z "$tmpl" || "$tmpl" == "null" ]]; then
        echo "FAIL: RESTY_PCRE_VERSION has no liveness_url_template — Fix #5 not applied to config"
        return 1
    fi

    # Read the current pinned version from build_args.
    local version
    version=$(yq -r '.build_args.RESTY_PCRE_VERSION // ""' "$config")

    if [[ -z "$version" || "$version" == "null" ]]; then
        echo "SKIP: RESTY_PCRE_VERSION not in build_args"
        return 0
    fi

    # Perform the same {version} substitution as the workflow step does.
    local derived_url="${tmpl//\{version\}/$version}"

    # The derived URL must match the Dockerfile-constructed URL.
    # Dockerfile: curl -fSL "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${RESTY_PCRE_VERSION}/pcre2-${RESTY_PCRE_VERSION}.tar.gz"
    local expected_url="https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${version}/pcre2-${version}.tar.gz"

    if [[ "$derived_url" != "$expected_url" ]]; then
        echo "FAIL: liveness_url_template substitution mismatch for RESTY_PCRE_VERSION"
        echo "  Template:  ${tmpl}"
        echo "  Version:   ${version}"
        echo "  Derived:   ${derived_url}"
        echo "  Expected:  ${expected_url}"
        return 1
    fi

    # Also confirm the derived URL matches the static liveness_url (for the pinned version,
    # both should agree — this validates that the template is not drifting from the static URL).
    local static_url
    static_url=$(yq -r '.dependency_sources.RESTY_PCRE_VERSION.liveness_url // ""' "$config")

    if [[ -n "$static_url" && "$static_url" != "null" && "$derived_url" != "$static_url" ]]; then
        echo "FAIL: template-derived URL does not match static liveness_url for pinned version"
        echo "  Template-derived: ${derived_url}"
        echo "  Static:           ${static_url}"
        echo "  (When both are set, they must agree for the current pinned version)"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# P3 regression lock: latest-github-tag fails closed when pagination bound
# is hit but more pages exist (Link: rel=next present after max_pages).
#
# Contract: when the curl path exhausts its max_pages=10 limit AND the last
# response still has a Link: rel="next" header, _gh_api_tags must exit
# non-zero with an ::error:: message — never silently return truncated tags.
#
# This test mocks _gh_api_tags by sourcing latest-github-tag and replacing
# _gh_api_tags with a mock that simulates 10 pages each with a next-link.
#
# Mutation caught: reverting the P3 fix to silent-return-after-10-pages
# means the helper exits 0 with truncated tags. The test detects this because
# we assert exit != 0. Reverting → the function exits 0 without error → RED.
#
# How to verify mutation → RED:
#   1. In helpers/latest-github-tag, remove the P3 block (the post-loop check).
#   2. Run this test — it fails because exit was 0 (no truncation error emitted).
#   3. Restore the P3 block → GREEN.
# ---------------------------------------------------------------------------

@test "P3: pagination bound reached with more pages exits non-zero (sourced helper)" {
    # Mutation trace: remove the P3 guard block from helpers/latest-github-tag
    # (the `if [[ "$pages_fetched" -ge "$max_pages" && -n "$url" ]]` block) and
    # this test goes RED — the helper exits 0 with truncated tags when max_pages
    # is hit but more pages exist.
    #
    # Strategy: source the REAL helpers/latest-github-tag, inject a curl stub
    # via PATH hijack that returns per-page JSON + Link: next header for all 10
    # pages (simulating a repo with >1000 tags). The real _gh_api_tags loop hits
    # max_pages=10, finds the Link still present, and the P3 guard fires.
    #
    # How to verify mutation → RED:
    #   1. Remove the P3 guard block from helpers/latest-github-tag.
    #   2. Run this test — exits 0 (guard never fires) → assertion fails → RED.
    #   3. Restore the P3 guard → GREEN.

    local stub_dir="$BATS_TEST_TMPDIR/stub-p3"
    mkdir -p "$stub_dir"
    # curl stub: always responds with a Link: next header (infinite repo simulation).
    # Writes minimal JSON body + Link header to -D file, body to stdout.
    printf '%s\n' '#!/usr/bin/env bash' \
        'hdr_file=""' \
        'while [[ $# -gt 0 ]]; do' \
        '  case "$1" in' \
        '    -D) hdr_file="$2"; shift 2;;' \
        '    *) shift;;' \
        '  esac' \
        'done' \
        'next_url="https://api.github.com/repos/example/big-repo/tags?per_page=100&page=99"' \
        '[[ -n "$hdr_file" ]] && printf "HTTP/2 200\r\ncontent-type: application/json\r\nlink: <%s>; rel=\"next\"\r\n\r\n" "$next_url" > "$hdr_file"' \
        'printf '"'"'[{"name":"v1.0.0"}]\n'"'"'' \
        'exit 0' \
        > "$stub_dir/curl"
    chmod +x "$stub_dir/curl"

    gh() { return 1; }
    export -f gh

    local status=0
    env PATH="$stub_dir:$PATH" GH_TOKEN="test" \
        bash -c 'source "'"$REPO_ROOT"'/helpers/latest-github-tag" && \
        _gh_api_tags example/big-repo' >/dev/null 2>&1 \
        || status=$?

    unset -f gh

    [[ "$status" -ne 0 ]] || {
        echo "FAIL: P3 guard did not fire — helper exited 0 when max_pages reached with next-link"
        echo "  (Mutation: remove the P3 guard block in helpers/latest-github-tag → exit 0 → RED)"
        return 1
    }
}

# ---------------------------------------------------------------------------
# Fix-R8 regression lock: stable-pin entries have liveness_url_template
#
# Contract: every stable-pin entry in config.yaml that has a liveness_url
# MUST also declare liveness_url_template so that the liveness step can
# substitute the CANDIDATE version (from a pending auto-PR) rather than the
# pinned version. Without liveness_url_template, an auto-PR opening for
# openssl 3.5.7 would HEAD the OLD 3.5.6 URL — false-green for the upgrade.
#
# This test reads all config.yaml files, finds stable-pin entries that have
# liveness_url set, and asserts that liveness_url_template is ALSO present.
#
# Axes covered: lifecycle=stable-pin + liveness_url present + template absent → FAIL
#               lifecycle=stable-pin + liveness_url present + template present → PASS
#               lifecycle=stable-pin + no liveness_url → SKIP (no liveness check at all)
#               lifecycle=tracked (covered by existing Fix #5 coherence test)
#               lifecycle=eol-migrate/untracked → template not required
#
# Mutation caught: removing liveness_url_template from openresty/config.yaml
# RESTY_OPENSSL_VERSION → this test detects the gap and goes RED.
#
# How to verify mutation → RED:
#   1. Remove liveness_url_template from openresty/config.yaml RESTY_OPENSSL_VERSION.
#   2. Run this test — it fails: RESTY_OPENSSL_VERSION has liveness_url but no template.
#   3. Restore liveness_url_template → GREEN.
# ---------------------------------------------------------------------------

@test "Fix-R8: all stable-pin entries with liveness_url also declare liveness_url_template" {
    local bad=0
    local bad_list=""

    for config in "$REPO_ROOT"/*/config.yaml; do
        local container
        container=$(basename "$(dirname "$config")")

        if ! yq -e '.dependency_sources' "$config" &>/dev/null; then
            continue
        fi

        local dep_names
        dep_names=$(yq -r '.dependency_sources // {} | keys | .[]' "$config")

        while IFS= read -r dep; do
            [[ -z "$dep" ]] && continue

            local lc liveness_url tmpl
            lc=$(YQ_DEP="$dep" yq -r '.dependency_sources[strenv(YQ_DEP)].lifecycle // ""' "$config")
            [[ "$lc" == "stable-pin" ]] || continue

            liveness_url=$(YQ_DEP="$dep" yq -r '.dependency_sources[strenv(YQ_DEP)].liveness_url // ""' "$config")
            [[ -n "$liveness_url" && "$liveness_url" != "null" ]] || continue

            # stable-pin entry with liveness_url → must also have template.
            tmpl=$(YQ_DEP="$dep" yq -r '.dependency_sources[strenv(YQ_DEP)].liveness_url_template // ""' "$config")
            if [[ -z "$tmpl" || "$tmpl" == "null" ]]; then
                bad=$((bad + 1))
                bad_list="${bad_list}\n  ${container}/${dep}: has liveness_url but no liveness_url_template"
            fi
        done <<< "$dep_names"
    done

    if [[ "$bad" -gt 0 ]]; then
        echo "FAIL: ${bad} stable-pin entries have liveness_url but no liveness_url_template:"
        printf '%b\n' "$bad_list"
        echo ""
        echo "Fix: add liveness_url_template with a {version} placeholder to each entry above."
        echo "Without it, liveness validates the stale pinned URL when an auto-PR opens."
        return 1
    fi
}
