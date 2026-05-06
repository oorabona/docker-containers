#!/usr/bin/env bats

# Unit tests for helpers/attestation-utils.sh
#
# Focus: get_attestation_id MUST extract the numeric attestation ID from the
# bundle_url field returned by the GitHub Attestations API. The previous
# implementation looked for a top-level .id and .created_at — neither field
# exists on the response objects, so every dashboard variant rendered as
# PENDING (issue #393).
#
# These tests stub `gh` to return canned API responses so the parser is
# exercised without requiring network access or auth.

setup() {
  ATTESTATION_FIXTURE_DIR="$(mktemp -d -t att-utils.XXXXXX)"
  export ATTESTATION_FIXTURE_DIR
  export PATH="$ATTESTATION_FIXTURE_DIR:$PATH"

  # Create a stub `gh` that prints whichever JSON the test put under
  # $ATTESTATION_FIXTURE_DIR/response.json. Any flag/argument is ignored.
  # Inline the fixture path so the stub does not depend on env propagation
  # through the helper's pipeline.
  cat > "$ATTESTATION_FIXTURE_DIR/gh" <<STUB
#!/usr/bin/env bash
cat "$ATTESTATION_FIXTURE_DIR/response.json" 2>/dev/null
STUB
  chmod +x "$ATTESTATION_FIXTURE_DIR/gh"

  # Source the helper after PATH is doctored so its `gh api` calls hit the stub
  HELPER_PATH="$(cd "$BATS_TEST_DIRNAME/../../helpers" && pwd)/attestation-utils.sh"
  # shellcheck source=/dev/null
  source "$HELPER_PATH"

  # Reset memoization between tests so cached results don't leak
  unset _ATTESTATION_CACHE
  declare -gA _ATTESTATION_CACHE=()
}

teardown() {
  rm -rf "$ATTESTATION_FIXTURE_DIR"
}

# ------------------------------------------------------------------
# get_attestation_id
# ------------------------------------------------------------------

@test "get_attestation_id extracts the numeric ID from bundle_url" {
  cat > "$ATTESTATION_FIXTURE_DIR/response.json" <<'JSON'
{
  "attestations": [
    {
      "bundle_url": "https://tmaproduction.blob.core.windows.net/attestations/68518664/2026/05/06/26573851.json.sn?se=2026-05-06T09%3A19%3A37Z&sig=stub",
      "initiator": "user",
      "bundle": {},
      "repository_id": 68518664
    }
  ]
}
JSON

  run get_attestation_id "sha256:c86e34e20b3ca1cef663a969f1f3e6535a670cb96993b2fb3a3affc24f92410b"
  [ "$status" -eq 0 ]
  [ "$output" = "26573851" ]
}

@test "get_attestation_id returns 1 when the API response has an empty attestations array" {
  cat > "$ATTESTATION_FIXTURE_DIR/response.json" <<'JSON'
{ "attestations": [] }
JSON

  # `output` may include the helper's log_warning on stderr when DASHBOARD_DEBUG
  # is unset; only the exit status is asserted here.
  run get_attestation_id "sha256:0000000000000000000000000000000000000000000000000000000000000000"
  [ "$status" -eq 1 ]
}

@test "get_attestation_id returns 1 when bundle_url has no parseable ID" {
  cat > "$ATTESTATION_FIXTURE_DIR/response.json" <<'JSON'
{
  "attestations": [
    { "bundle_url": "https://elsewhere.example.com/no-trailing-id-here?x=1" }
  ]
}
JSON

  run get_attestation_id "sha256:abc"
  [ "$status" -eq 1 ]
}

@test "get_attestation_id rejects empty/null/unknown digests without calling gh" {
  for d in "" "null" "unknown"; do
    run get_attestation_id "$d"
    [ "$status" -eq 1 ]
  done
}

@test "get_attestation_id memoizes a hit so repeated calls don't re-run gh api" {
  cat > "$ATTESTATION_FIXTURE_DIR/response.json" <<'JSON'
{
  "attestations": [
    { "bundle_url": "https://x/attestations/1/2026/05/06/42.json.sn?sig=z" }
  ]
}
JSON

  # Memoization is a same-shell optimisation; bats `run` and `$(...)` both spawn
  # subshells that would break the cache assertion, so write the function output
  # to a file and read it afterwards.
  get_attestation_id "sha256:cached" > "$ATTESTATION_FIXTURE_DIR/r1"
  [ "$(cat "$ATTESTATION_FIXTURE_DIR/r1")" = "42" ]
  [ "${_ATTESTATION_CACHE[sha256:cached]}" = "42" ]

  # Truncate the response so a second uncached call would fail; cache must serve it.
  : > "$ATTESTATION_FIXTURE_DIR/response.json"
  get_attestation_id "sha256:cached" > "$ATTESTATION_FIXTURE_DIR/r2"
  [ "$(cat "$ATTESTATION_FIXTURE_DIR/r2")" = "42" ]
}

@test "get_attestation_id memoizes a miss so repeated calls don't re-run gh api" {
  cat > "$ATTESTATION_FIXTURE_DIR/response.json" <<'JSON'
{ "attestations": [] }
JSON

  if get_attestation_id "sha256:missing" >/dev/null 2>&1; then
    fail "expected non-zero exit on empty attestations"
  fi
  [ "${_ATTESTATION_CACHE[sha256:missing]}" = "__MISS__" ]

  # Replace with a hit; cache should still report MISS.
  cat > "$ATTESTATION_FIXTURE_DIR/response.json" <<'JSON'
{ "attestations": [ { "bundle_url": "https://x/99.json.sn?s=z" } ] }
JSON

  if get_attestation_id "sha256:missing" >/dev/null 2>&1; then
    fail "cache MISS should not be re-queried"
  fi
}

# ------------------------------------------------------------------
# get_attestation_url
# ------------------------------------------------------------------

@test "get_attestation_url builds the public viewer URL from an ID" {
  run get_attestation_url 26573851
  [ "$status" -eq 0 ]
  [ "$output" = "https://github.com/oorabona/docker-containers/attestations/26573851" ]
}

@test "get_attestation_url returns 1 when the ID is empty" {
  run get_attestation_url ""
  [ "$status" -eq 1 ]
}
