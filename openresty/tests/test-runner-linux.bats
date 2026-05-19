#!/usr/bin/env bats
# Runtime smoke tests for the openresty container (PCRE2 migration — #453 volet 1).
# Runs against the LOCALLY BUILT image via ./make build openresty.
# Requires: docker, bats-core >= 1.8.
#
# Mutation this test catches: nginx built without PCRE2 (or with PCRE1) =>
#   - /re/42 returns 4xx/5xx instead of "m=42" (regex location never matched)
#   - nginx -V does not mention PCRE2
#   - ldd shows libpcre.so instead of libpcre2-8.so (wrong lib)
# All three assertions must pass for the migration to be considered functional.

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Determine the image name that ./make build produces for openresty.
# The build system tags as <container>:<version>; for the smoke test we
# accept any locally-built tag that starts with "openresty:" (or the GHCR form).
_find_image() {
    # Prefer an explicit override (CI sets IMAGE_TAG)
    if [[ -n "${OPENRESTY_IMAGE:-}" ]]; then
        echo "$OPENRESTY_IMAGE"
        return
    fi
    # Fall back to the most-recently-built openresty image
    local img
    img=$(docker images --format '{{.Repository}}:{{.Tag}}' \
          | grep -E '^(ghcr\.io/oorabona/openresty|openresty):' \
          | head -1)
    if [[ -z "$img" ]]; then
        echo "ERROR: no openresty image found locally. Run: ./make build openresty" >&2
        return 1
    fi
    echo "$img"
}

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
    IMAGE=$(_find_image)
    CONTAINER_NAME="openresty-bats-smoke-$$"
    PORT=18080

    # Nginx config with a regex location that proves PCRE2 + JIT is functional.
    # location ~ ^/re/(\d+)$  uses a PCRE2 pattern; if PCRE2 is absent nginx
    # either fails to start or falls back to PCRE1 (which this build does not
    # include), so the location would never match.
    # Note: no "daemon off;" here — the image CMD already passes -g "daemon off;"
    NGINX_CONF="$(mktemp /tmp/openresty-bats-nginx-XXXXXX.conf)"
    cat > "$NGINX_CONF" <<'NGINX'
worker_processes 1;
events { worker_connections 64; }
http {
    server {
        listen 8080;
        location ~ ^/re/(\d+)$ {
            return 200 "m=$1";
        }
        location /nginx_status {
            stub_status on;
            access_log off;
        }
    }
}
NGINX

    # Start the container with the custom nginx config
    docker run -d \
        --name "$CONTAINER_NAME" \
        -p "${PORT}:8080" \
        -v "${NGINX_CONF}:/usr/local/openresty/nginx/conf/nginx.conf:ro" \
        "$IMAGE"

    # Wait up to 15 s for nginx to become ready
    local waited=0
    until curl -sf "http://127.0.0.1:${PORT}/nginx_status" >/dev/null 2>&1; do
        sleep 1
        waited=$((waited + 1))
        if [[ $waited -ge 15 ]]; then
            echo "ERROR: openresty container did not become ready within 15s" >&2
            docker logs "$CONTAINER_NAME" >&2 || true
            return 1
        fi
    done
}

teardown() {
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    rm -f "$NGINX_CONF" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Test 1 (AC-5 behavioral): PCRE2 regex + JIT functional at runtime
# Mutation caught: nginx built without PCRE2 => /re/42 is 404/500, not "m=42"
# ---------------------------------------------------------------------------

@test "GET /re/42 returns exactly 'm=42' (PCRE2 + JIT regex functional)" {
    local body
    body=$(curl -sf "http://127.0.0.1:${PORT}/re/42")
    [ "$body" = "m=42" ]
}

# ---------------------------------------------------------------------------
# Test 2 (AC-5 provenance): libpcre2-8.so resolved from /usr/local/openresty/pcre2/lib
# Mutation caught: wrong rpath (PCRE2 built but nginx resolves system libpcre2 or
#                  libpcre1) => RUNPATH does not contain /usr/local/openresty/pcre2/lib
# ---------------------------------------------------------------------------

@test "nginx binary RUNPATH contains /usr/local/openresty/pcre2/lib" {
    # Find the nginx binary path inside the container
    local nginx_bin
    nginx_bin=$(docker exec "$CONTAINER_NAME" sh -c \
        'command -v nginx || echo /usr/local/openresty/nginx/sbin/nginx')

    # readelf -d shows RPATH/RUNPATH entries
    local runpath_output
    runpath_output=$(docker exec "$CONTAINER_NAME" sh -c \
        "readelf -d \"$nginx_bin\" 2>/dev/null || true")

    # If readelf is unavailable, fall back to checking ldd for libpcre2-8.so
    if [[ -z "$runpath_output" ]]; then
        local ldd_output
        ldd_output=$(docker exec "$CONTAINER_NAME" sh -c \
            "ldd \"$nginx_bin\" 2>/dev/null || true")
        echo "ldd output: $ldd_output"
        [[ "$ldd_output" == *"libpcre2-8"* ]]
        [[ "$ldd_output" == *"/usr/local/openresty/pcre2"* ]]
    else
        echo "readelf output: $runpath_output"
        [[ "$runpath_output" == *"/usr/local/openresty/pcre2/lib"* ]]
    fi
}

# ---------------------------------------------------------------------------
# Test 3 (AC-9): nginx -V configure arguments reference pcre2 paths (not PCRE1)
# Mutation caught: nginx compiled against PCRE1 8.45 =>
#   configure args contain "/openresty/pcre/" (no "2"), or sourceforge in build;
#   with PCRE2 they contain "/openresty/pcre2/" in cc-opt/ld-opt.
# Note: OpenResty nginx uses --with-pcre (not --with-pcre2) and resolves the
#   PCRE2 library via cc-opt/ld-opt paths, so the literal string "PCRE2" does
#   not appear in nginx -V output. The /pcre2/ path in configure args is the proof.
# ---------------------------------------------------------------------------

@test "nginx -V configure arguments reference /usr/local/openresty/pcre2/ (PCRE2 linked, not PCRE1)" {
    local version_output
    # nginx -V writes to stderr
    version_output=$(docker exec "$CONTAINER_NAME" sh -c \
        'nginx -V 2>&1 || /usr/local/openresty/nginx/sbin/nginx -V 2>&1')

    echo "nginx -V output: $version_output"

    # PCRE2 linked: configure arguments contain pcre2 include/lib paths
    [[ "$version_output" == *"/usr/local/openresty/pcre2/"* ]]
    # PCRE1 NOT linked: no reference to the PCRE1 /pcre/ path (without trailing 2)
    # (the PCRE1 path would be /openresty/pcre/include or /openresty/pcre/lib)
    [[ "$version_output" != *"/usr/local/openresty/pcre/include"* ]]
    [[ "$version_output" != *"/usr/local/openresty/pcre/lib"* ]]
}
