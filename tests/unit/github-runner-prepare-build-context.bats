#!/usr/bin/env bats

# Unit tests for github-runner/prepare-build-context.sh download retry.
# A transient 504 from github.com failed the windows build on 2026-10-01;
# the runner-agent download must now survive transient failures.

load "../test_helper"

setup() {
    setup_temp_dir
    mkdir -p "$TEST_TEMP_DIR/github-runner" "$TEST_TEMP_DIR/helpers" "$TEST_TEMP_DIR/bin"
    cp "$PROJECT_ROOT/github-runner/prepare-build-context.sh" "$TEST_TEMP_DIR/github-runner/"
    cp "$HELPERS_DIR/logging.sh" "$HELPERS_DIR/retry.sh" "$TEST_TEMP_DIR/helpers/"

    # curl stub: fail with exit 22 (HTTP error) for the first $CURL_FAILURES
    # calls that download the runner archive, then succeed.
    echo 0 > "$TEST_TEMP_DIR/curl-calls"
    cat > "$TEST_TEMP_DIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
out=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    [[ "${args[$i]}" == "-o" ]] && out="${args[$((i + 1))]}"
done
[[ -n "$out" ]] || exit 22   # SHA probes (no -o) always miss
n=$(cat "$CURL_COUNT_FILE")
echo $((n + 1)) > "$CURL_COUNT_FILE"
if (( n < CURL_FAILURES )); then
    exit 22
fi
printf 'fake-runner-archive' > "$out"
STUB
    chmod +x "$TEST_TEMP_DIR/bin/curl"

    export CURL_COUNT_FILE="$TEST_TEMP_DIR/curl-calls"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export RUNNER_FETCH_DELAY=0
    unset GITHUB_TOKEN
}

teardown() {
    teardown_temp_dir
}

@test "prepare-build-context: retries a transient download failure then succeeds" {
    export CURL_FAILURES=2
    run bash "$TEST_TEMP_DIR/github-runner/prepare-build-context.sh" 9.9.9 amd64 windows
    [ "$status" -eq 0 ]
    [ "$(cat "$CURL_COUNT_FILE")" -eq 3 ]
    [ -s "$TEST_TEMP_DIR/github-runner/runner.zip" ]
    [ -s "$TEST_TEMP_DIR/github-runner/runner.sha256" ]
}

@test "prepare-build-context: fails after exhausting the download attempts" {
    export CURL_FAILURES=99
    export RUNNER_FETCH_ATTEMPTS=3
    run bash "$TEST_TEMP_DIR/github-runner/prepare-build-context.sh" 9.9.9 amd64 windows
    [ "$status" -ne 0 ]
    [ "$(cat "$CURL_COUNT_FILE")" -eq 3 ]
}
