#!/bin/bash
# E2E test for the jekyll container.
#
# Uses the repository's test harness so the exit code is the verdict. The suite
# builds a tiny site instead of treating the presence of Ruby binaries as proof
# that the static-site generator works.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../test-harness/test-harness.sh
source "${SCRIPT_DIR}/../test-harness/test-harness.sh"

CONTAINER_NAME="${CONTAINER_NAME:-e2e-jekyll}"

th_init --name "Jekyll E2E" --report "${REPORT_FORMAT:-table}"

# Bundler 4 prints a bare version number — no "Bundler" anywhere in it — so the
# assertion is on the shape of what it prints, not on a word. Kept because the
# image advertises Bundler, and the build below uses the global jekyll rather
# than a Gemfile, so nothing else here would notice its absence.
th_capture "bundler reports a version" docker exec "$CONTAINER_NAME" bundle --version &&
    th_assert_matches "bundler reports a version" "$TH_OUTPUT" '[0-9]+\.[0-9]+'

th_group "Site build"

# Use a self-contained site so no networked gem resolution or repository fixture
# is required. The generated page uses Liquid, which distinguishes a real Jekyll
# build from copying source files into _site.
if docker exec "$CONTAINER_NAME" sh -c '
    rm -rf /tmp/e2e-jekyll &&
    mkdir -p /tmp/e2e-jekyll &&
    cd /tmp/e2e-jekyll &&
    printf "%s\\n" "title: Harness Site" > _config.yml &&
    printf "%s\\n" "---" "---" "Rendered: {{ site.title }}" > index.md &&
    jekyll build --source . --destination _site >/dev/null
'; then
    th_pass "Jekyll builds a minimal site"
else
    th_fail "Jekyll builds a minimal site" "jekyll build failed for the minimal site"
fi

if docker exec "$CONTAINER_NAME" sh -c \
    'test -f /tmp/e2e-jekyll/_site/index.html && grep -Fq "Rendered: Harness Site" /tmp/e2e-jekyll/_site/index.html'; then
    th_pass "Jekyll output contains rendered source content"
else
    th_fail "Jekyll output contains rendered source content" \
        "the generated index.html is missing or did not render the site title"
fi

th_group "Server"

# The image's default command is `jekyll serve --host 0.0.0.0`, which builds
# /site into /site/_site and keeps watching /site. So the page is written to the
# SOURCE and the rebuild is what publishes it: copying into /site/_site instead
# races the watcher, which owns that directory and regenerates it.
#
# Only a page is written, never _config.yml — Jekyll does not reload its config
# while watching, so a title taken from the config would never appear. Reading it
# from the page's own front matter still requires Liquid to have run, which a
# copied file would not prove.
#
# A uniquely named page, never index.md: jekyll/docker-compose.yml bind-mounts a
# real site into /site read-write, so this suite pointed at that container with
# CONTAINER_NAME would otherwise overwrite the user's own page. It is removed
# again below, and even a failed cleanup leaves their content untouched.
# Per run, not a constant: two runs against the same container would otherwise
# write and delete each other's page, and a stale page left by an interrupted run
# could satisfy the assertion below without this run's write ever succeeding.
probe_page="e2e-harness-probe-$$-${RANDOM}"
probe_token="harness-${probe_page}"

# Creation is asserted, not attempted: `|| true` here means a failed write is
# indistinguishable from a served page, which is the false green this check
# exists to avoid. `set -C` refuses to clobber an existing file.
if docker exec "$CONTAINER_NAME" sh -c \
    'set -C; printf "%s\n" "---" "title: {{ page.token }}" "token: $2" "---" "Rendered: {{ page.token }}" > "/site/$1.md"' \
    _ "$probe_page" "$probe_token" >/dev/null 2>&1; then
    th_pass "the probe page is created in the watched source"
else
    th_fail "the probe page is created in the watched source" \
        "could not write /site/$probe_page.md"
fi

# The runner does not publish 4000 to the host, but the Ruby runtime inside can
# make the request. Retrying keeps this about the server rather than a race with
# the rebuild it triggers.
th_assert_cmd_contains "Jekyll serves the generated page on port 4000" "Rendered: $probe_token" \
    docker exec "$CONTAINER_NAME" ruby -rnet/http -e '
        page = ARGV[0]
        # The timeouts are why this uses the start form: Net::HTTP defaults are
        # around a minute each, so a server that accepts the connection and then
        # says nothing would keep this loop alive for ten minutes, not ten seconds.
        10.times do
          begin
            Net::HTTP.start("127.0.0.1", 4000, open_timeout: 2, read_timeout: 2) do |http|
              response = http.get("/#{page}.html")
              if response.is_a?(Net::HTTPSuccess) && response.body.include?("Rendered: #{ARGV[1]}")
                puts response.body
                exit 0
              end
            end
          rescue StandardError
          end
          sleep 1
        end
        exit 1
    ' "$probe_page" "$probe_token"

# The page belongs to the harness, not to the site: remove it whether or not the
# assertion above passed.
docker exec "$CONTAINER_NAME" sh -c \
    'rm -f "/site/$1.md" "/site/_site/$1.html"' _ "$probe_page" >/dev/null 2>&1 || true

th_summary
