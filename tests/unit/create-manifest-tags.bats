#!/usr/bin/env bats
#
# Regression lock for create-manifest.sh tag computation.
# Guards the "version-specific tag" block against emitting a CROSS-VERSION,
# base-suffix-stripped alias for full-version-tag containers (terraform), while
# preserving postgres's legitimate major->specific version tag (18 -> 18.3).

setup() {
  ROOT_DIR="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  # shellcheck source=/dev/null
  source "$ROOT_DIR/helpers/create-manifest.sh"
}

# ── terraform: full-version tags, version.sh returns latest for every cell ──

@test "terraform retained cell does NOT get a cross-version stripped tag" {
  # 1.15.4 retained cell built with FULL_VERSION = latest (1.15.6) — the bug case.
  export TAG="1.15.4-alpine-base" VERSION="1.15.4-alpine" FULL_VERSION="1.15.6-alpine"
  export VARIANT="base" IS_DEFAULT="false" IS_LATEST_VERSION="false"
  run _compute_tag_args "ghcr.io/o/terraform"
  [ "$status" -eq 0 ]
  # must NOT alias the latest version onto this retained image
  [[ "$output" != *"1.15.6"* ]]
  # must NOT emit a base-suffix-stripped tag of this version either
  [[ "$output" != *":1.15.4-base"* ]]
  # the correct versioned tag is still present
  [[ "$output" == *"-t ghcr.io/o/terraform:1.15.4-alpine-base"* ]]
}

@test "terraform latest cell does NOT get a base-stripped tag" {
  export TAG="1.15.6-alpine-base" VERSION="1.15.6-alpine" FULL_VERSION="1.15.6-alpine"
  export VARIANT="base" IS_DEFAULT="false" IS_LATEST_VERSION="true"
  run _compute_tag_args "ghcr.io/o/terraform"
  [ "$status" -eq 0 ]
  [[ "$output" != *":1.15.6-base"* ]]
  [[ "$output" == *"-t ghcr.io/o/terraform:1.15.6-alpine-base"* ]]
}

@test "_compute_version_specific_tag_args (fallback) skips cross-version for terraform" {
  export TAG="1.15.4-alpine-base" VERSION="1.15.4-alpine" FULL_VERSION="1.15.6-alpine"
  run _compute_version_specific_tag_args "ghcr.io/o/terraform"
  [ "$status" -eq 0 ]
  [[ "$output" != *"1.15.6"* ]]
  # Path C: TAG itself is the version-specific form
  [[ "$output" == "-t ghcr.io/o/terraform:1.15.4-alpine-base" ]]
}

# ── postgres: legitimate major -> specific version tag must be preserved ──

@test "postgres rolling major cell still gets the specific version tag" {
  # 18-alpine-vector rolling tag, FULL_VERSION 18.3-alpine -> add 18.3-alpine-vector
  export TAG="18-alpine-vector" VERSION="18" FULL_VERSION="18.3-alpine"
  export VARIANT="vector" IS_DEFAULT="false" IS_LATEST_VERSION="true"
  run _compute_tag_args "ghcr.io/o/postgres"
  [ "$status" -eq 0 ]
  [[ "$output" == *"-t ghcr.io/o/postgres:18.3-alpine-vector"* ]]
  [[ "$output" == *"-t ghcr.io/o/postgres:18-alpine-vector"* ]]
}
