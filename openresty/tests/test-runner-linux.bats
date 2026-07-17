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
    # Deterministic image resolution — fail-closed on 0 or ambiguous images.
    # $OPENRESTY_IMAGE is the explicit override: local runs and CI SHOULD set it
    # (a tracked follow-up will wire it in the upstream workflow).
    if [[ -n "${OPENRESTY_IMAGE:-}" ]]; then
        echo "$OPENRESTY_IMAGE"
        return 0
    fi

    # Enumerate built openresty images by IMAGE ID, deduplicated.
    # A single build produces multiple tag aliases (ghcr.io/…, docker.io/…, :latest)
    # all sharing the SAME image ID — counting tags would wrongly report "multiple".
    # The repo-component filter is anchored to avoid matching base-image cache repos
    # or unrelated images that happen to contain "openresty" in a path component.
    local ids
    ids=$(docker images --format '{{.ID}} {{.Repository}}:{{.Tag}}' \
          | awk '$2 ~ /^(ghcr\.io\/oorabona\/openresty|docker\.io\/oorabona\/openresty|openresty):/ {print $1}' \
          | sort -u)

    local count
    count=$(echo "$ids" | grep -c .) 2>/dev/null || count=0
    # grep -c on empty string returns 1 (the empty line); guard for that:
    if [[ -z "$ids" ]]; then
        count=0
    fi

    if [[ "$count" -eq 0 ]]; then
        echo "ERROR: no built openresty image found (run ./make build openresty, or set OPENRESTY_IMAGE)" >&2
        return 1
    fi

    if [[ "$count" -gt 1 ]]; then
        echo "ERROR: ambiguous — ${count} distinct openresty images present; set OPENRESTY_IMAGE to the one under test" >&2
        return 1
    fi

    # Exactly 1 distinct image ID — return the first matching tag (docker run <tag> works).
    local tag
    tag=$(docker images --format '{{.ID}} {{.Repository}}:{{.Tag}}' \
          | awk -v id="$ids" '$1 == id && $2 ~ /^(ghcr\.io\/oorabona\/openresty|docker\.io\/oorabona\/openresty|openresty):/ {print $2; exit}')
    echo "$tag"
    return 0
}

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
    IMAGE=$(_find_image) || return 1
    CONTAINER_NAME="openresty-bats-smoke-$$"
    PORT=18080

    # Nginx config with a regex location that proves PCRE2 regex matching is functional.
    # location ~ ^/re/(\d+)$  uses a PCRE2 pattern; if PCRE2 is absent nginx
    # either fails to start or falls back to PCRE1 (which this build does not
    # include), so the location would never match.
    # Note: no "daemon off;" here — the image CMD already passes -g "daemon off;"
    NGINX_CONF="$(mktemp /tmp/openresty-bats-nginx-XXXXXX.conf)"
    # mktemp creates 0600; the image runs as the non-root nginx user (uid 101),
    # which must be able to read the bind-mounted config, so make it readable.
    chmod 0644 "$NGINX_CONF"
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
# Test 1 (AC-5 behavioral): PCRE2 regex + capture group functional at runtime
# Mutation caught: nginx built without PCRE2 => /re/42 is 404/500, not "m=42"
# Note: this proves PCRE2 regex matching and capture works at runtime.
#   JIT presence is structurally guaranteed by --enable-jit + --with-pcre-jit
#   configure flags (see Dockerfile) and is not separately asserted here.
# ---------------------------------------------------------------------------

@test "GET /re/42 returns exactly 'm=42' (PCRE2 regex + capture group functional at runtime)" {
    local body
    body=$(curl -sf "http://127.0.0.1:${PORT}/re/42")
    [ "$body" = "m=42" ]
}

# ---------------------------------------------------------------------------
# Test 2 (AC-5 provenance): libpcre2-8.so resolved from /usr/local/openresty/pcre2/lib
# Mutation caught: wrong rpath (PCRE2 built but nginx resolves system libpcre2 or
#                  libpcre1) => RUNPATH does not contain /usr/local/openresty/pcre2/lib
# ---------------------------------------------------------------------------

@test "nginx binary resolves libpcre2-8.so from /usr/local/openresty/pcre2/lib" {
    # Find the nginx binary path inside the container
    local nginx_bin
    nginx_bin=$(docker exec "$CONTAINER_NAME" sh -c \
        'command -v nginx || echo /usr/local/openresty/nginx/sbin/nginx')

    # ldd is the discriminating oracle here.
    # readelf/binutils is stripped from the runtime image (apk del .build-deps),
    # so readelf is never present at runtime — ldd (from musl libc) is always available.
    local ldd_output
    ldd_output=$(docker exec "$CONTAINER_NAME" sh -c \
        "ldd \"$nginx_bin\" 2>/dev/null || true")

    echo "ldd output: $ldd_output"
    # PCRE2 linked: nginx must resolve libpcre2-8.so (not libpcre.so / PCRE1)
    [[ "$ldd_output" == *"libpcre2-8"* ]]
    # Correct rpath: resolved from the bundled pcre2 install, not a system path
    [[ "$ldd_output" == *"/usr/local/openresty/pcre2"* ]]
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
