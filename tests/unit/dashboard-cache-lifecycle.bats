#!/usr/bin/env bats

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

@test "sourcing generate-dashboard.sh does not allocate a Trivy cache or install an EXIT trap" {
    local cache_dir="$BATS_TEST_TMPDIR/trivy-cache"
    mkdir -p "$cache_dir"

    run env -u TRIVY_CACHE_FILE TMPDIR="$cache_dir" bash -c '
        cd "$2"
        trap ":" EXIT
        trap_before=$(trap -p EXIT)
        source "$1"
        trap_after=$(trap -p EXIT)
        [[ "$trap_before" == "$trap_after" ]] &&
            [[ -z "${TRIVY_CACHE_FILE+x}" ]] &&
            [[ -z "$(find "$TMPDIR" -maxdepth 1 -type f -name "trivy-summary-cache.*" -print -quit)" ]]
    ' _ "$PROJECT_ROOT/generate-dashboard.sh" "$PROJECT_ROOT"

    [ "$status" -eq 0 ]
}
