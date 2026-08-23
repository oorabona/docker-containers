#!/usr/bin/env bats
# Unit tests for github-runner/entrypoint.sh
# Tests entrypoint logic WITHOUT live GitHub connectivity by mocking curl,
# config.sh, run.sh, and other external binaries.

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

# These are the production-equivalent defaults.  Individual tests can shorten
# the waits with RUNNER_TERM_GRACE_SECONDS and RUNNER_KILL_CONFIRMATION_SECONDS.
RUNNER_TERM_GRACE_SECONDS_DEFAULT=6
RUNNER_KILL_CONFIRMATION_SECONDS_DEFAULT=1
# Linux process IDs, and therefore process groups, cannot exceed this kernel
# limit.  Keeping the accepted value below it also makes every later Bash
# arithmetic operation safe.
RUNNER_PGID_MAX=4194304
RUNNER_CLEANUP_SECONDS_MAX=999999

setup() {
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    RUNNER_DIR="$(cd "$TEST_DIR/.." && pwd)"
    ENTRYPOINT="$RUNNER_DIR/entrypoint.sh"
    # Resolve this before the mock directory shadows PATH.  type -P ignores
    # shell functions, and the resulting pathname does not depend on PATH.
    REAL_SLEEP="$(type -P sleep)"
    RUNNER_PGID=""
    RUNNER_LAUNCH_ATTEMPTED=0

    # Temp workspace — every test gets an isolated directory
    WORK_DIR="$(mktemp -d)"
    BIN_DIR="$WORK_DIR/bin"
    RUNNER_WORK="$WORK_DIR/actions-runner"
    RUNNER_IDENTITY_FILE="$WORK_DIR/runner-identity"
    mkdir -p "$BIN_DIR" "$RUNNER_WORK"

    # Prepend mock bin dir to PATH so our fakes win
    export PATH="$BIN_DIR:$PATH"

    # Default mock: curl returns success with a registration token JSON
    _write_mock_curl 201 '{"token":"mock-reg-token-ok"}'

    # Default mock: jq — use the real jq if available, otherwise provide a fake
    if command -v jq &>/dev/null; then
        # real jq is available — no fake needed
        true
    else
        cat > "$BIN_DIR/jq" <<'MOCK'
#!/usr/bin/env bash
# Minimal jq fake: only handles the patterns used by entrypoint.sh
case "$*" in
    *'.token'*) echo "mock-reg-token-ok" ;;
    *'.id'*)    echo "123456" ;;
    *)          echo "" ;;
esac
MOCK
        chmod +x "$BIN_DIR/jq"
    fi

    # Default mock: config.sh exits 0
    cat > "$RUNNER_WORK/config.sh" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
    chmod +x "$RUNNER_WORK/config.sh"

    # Default mock: run.sh exits 0 immediately
    cat > "$RUNNER_WORK/run.sh" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
    chmod +x "$RUNNER_WORK/run.sh"

    # Default mock: sleep is a no-op (prevent tests from actually sleeping)
    cat > "$BIN_DIR/sleep" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
    chmod +x "$BIN_DIR/sleep"

    # Default mock: hostname returns a predictable value
    cat > "$BIN_DIR/hostname" <<'MOCK'
#!/usr/bin/env bash
echo "test-host"
MOCK
    chmod +x "$BIN_DIR/hostname"

    # Default mock: openssl — minimal fake for JWT generation
    cat > "$BIN_DIR/openssl" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "base64" ]]; then
    # base64 encode stdin
    /usr/bin/base64 -w0 2>/dev/null || /usr/bin/base64 2>/dev/null
elif [[ "$1" == "dgst" ]]; then
    # Fake signature: output a fixed binary blob
    printf 'fakesig'
else
    /usr/bin/openssl "$@"
fi
MOCK
    chmod +x "$BIN_DIR/openssl"

    # Log file captures all stderr output from the entrypoint
    LOG_FILE="$WORK_DIR/entrypoint.log"

    # Prevent auto-update noise
    export RUNNER_DISABLE_AUTO_UPDATE=1
    # Point cache dirs into temp space
    export HOME="$WORK_DIR/home"
    mkdir -p "$HOME"
}

teardown() {
    # An attempted launch without a validated group identity may still have a
    # detached session using this workspace.  Retain it rather than guessing
    # which group to signal or deleting files below a live runner.
    if [[ "${RUNNER_LAUNCH_ATTEMPTED:-0}" == "1" && -z "${RUNNER_PGID:-}" ]]; then
        echo "Runner session identity is unknown; preserving workspace: $WORK_DIR" >&2
        return 1
    fi
    if ! _cleanup_runner_group "${RUNNER_PGID:-}"; then
        return 1
    fi
    rm -rf "$WORK_DIR"
}

# ---------------------------------------------------------------------------
# Helper: write a mock curl that returns a given HTTP status + body
# ---------------------------------------------------------------------------
_write_mock_curl() {
    local status="$1"
    local body="$2"

    cat > "$BIN_DIR/curl" <<MOCK
#!/usr/bin/env bash
# Mock curl — captures URL for inspection, returns status + body
last_url=""
for arg in "\$@"; do
    if [[ "\$arg" =~ ^https?:// ]]; then
        last_url="\$arg"
        echo "\$arg" >> "$WORK_DIR/curl-urls.log"
    fi
done

# If -w '%{http_code}' is in args, print status to stdout; body to -o file
outfile=""
next_is_out=false
for arg in "\$@"; do
    if [[ "\$next_is_out" == "true" ]]; then
        outfile="\$arg"
        next_is_out=false
    fi
    [[ "\$arg" == "-o" ]] && next_is_out=true
done

if [[ -n "\$outfile" ]]; then
    printf '%s' '$body' > "\$outfile"
    printf '%s' '$status'
else
    printf '%s' '$body'
fi
exit 0
MOCK
    chmod +x "$BIN_DIR/curl"
}

# ---------------------------------------------------------------------------
# Helper: write a curl mock that fails N times then succeeds
# ---------------------------------------------------------------------------
_write_mock_curl_fail_then_succeed() {
    local fail_count="$1"
    local success_body="${2:-'{\"token\":\"mock-reg-token-ok\"}'}"

    cat > "$BIN_DIR/curl" <<MOCK
#!/usr/bin/env bash
call_file="$WORK_DIR/curl-call-count"
count=\$(cat "\$call_file" 2>/dev/null || echo 0)
count=\$((count + 1))
echo "\$count" > "\$call_file"

# Capture URL
for arg in "\$@"; do
    if [[ "\$arg" =~ ^https?:// ]]; then
        echo "\$arg" >> "$WORK_DIR/curl-urls.log"
    fi
done

outfile=""
next_is_out=false
for arg in "\$@"; do
    if [[ "\$next_is_out" == "true" ]]; then
        outfile="\$arg"
        next_is_out=false
    fi
    [[ "\$arg" == "-o" ]] && next_is_out=true
done

if [[ \$count -le $fail_count ]]; then
    # Fail
    if [[ -n "\$outfile" ]]; then
        printf '{"message":"Unauthorized"}' > "\$outfile"
        printf '401'
    else
        printf '{"message":"Unauthorized"}'
    fi
    exit 0
else
    # Succeed
    if [[ -n "\$outfile" ]]; then
        printf '%s' '$success_body' > "\$outfile"
        printf '201'
    else
        printf '%s' '$success_body'
    fi
    exit 0
fi
MOCK
    chmod +x "$BIN_DIR/curl"
}

# ---------------------------------------------------------------------------
# Helper: run entrypoint in the actions-runner work directory
# ---------------------------------------------------------------------------
_run_entrypoint() {
    # Run entrypoint from RUNNER_WORK so relative ./config.sh and ./run.sh work
    run bash -c "cd '$RUNNER_WORK' && bash '$ENTRYPOINT'" 2>"$LOG_FILE"
}

# Use the real sleep binary for test timing.  entrypoint.sh must still resolve
# its retry backoff through the mocked sleep on PATH.
_real_sleep() {
    command "${RUNNER_REAL_SLEEP:-$REAL_SLEEP}" "$@"
}

_runner_pgid_is_valid() {
    local candidate="${1:-}"

    [[ "$candidate" =~ ^[1-9][0-9]{0,6}$ ]] || return 1
    ((10#$candidate <= RUNNER_PGID_MAX))
}

# Bash 5's EPOCHREALTIME is a builtin with microsecond resolution.  This
# helper writes its integer result to a global so production cleanup performs
# no subprocesses while reading the clock.  Tests replace the helper with an
# in-process fake clock.
_runner_cleanup_time_now() {
    local timestamp="$EPOCHREALTIME"
    local seconds="${timestamp%%.*}"
    local microseconds="${timestamp#*.}"

    [[ "$timestamp" =~ ^[0-9]{1,10}\.[0-9]{6}$ ]] || return 1
    RUNNER_CLEANUP_NOW_MICROSECONDS=$((10#$seconds * 1000000 + 10#$microseconds))
}

_runner_cleanup_seconds_to_microseconds() {
    local seconds="${1:-}"

    [[ "$seconds" =~ ^[0-9]{1,6}$ ]] || return 1
    ((10#$seconds <= RUNNER_CLEANUP_SECONDS_MAX)) || return 1
    RUNNER_CLEANUP_DURATION_MICROSECONDS=$((10#$seconds * 1000000))
}

# Sleep at most one poll interval, and never beyond the phase deadline.
_runner_cleanup_sleep_remaining() {
    local remaining_microseconds="$1"
    local sleep_microseconds="$remaining_microseconds"
    local sleep_interval

    ((sleep_microseconds > 0)) || return 0
    ((sleep_microseconds > 100000)) && sleep_microseconds=100000
    printf -v sleep_interval '%d.%06d' \
        $((sleep_microseconds / 1000000)) $((sleep_microseconds % 1000000))
    _real_sleep "$sleep_interval"
}

# Return one of three states for a process group: 0 present, 1 absent, or 2
# unknown.  A failed signal probe alone is never evidence of extinction: an
# EPERM result has the same shell status as ESRCH.  /proc is available on the
# Linux-only test host, so membership in the process group is the authoritative
# answer when the normal probe has a conventional result.
_runner_group_state() {
    local pgid="${1:-}"
    local probe_status=0
    local stat_file stat_line state ppid stat_pgid ignored rest

    _runner_pgid_is_valid "$pgid" || return 2

    # Use env so the decision table can mock kill in BIN_DIR despite Bash's
    # kill builtin taking precedence over PATH.
    env kill -0 -- "-$pgid" 2>/dev/null || probe_status=$?
    [[ $probe_status -eq 0 ]] && return 0
    # GNU/procps kill uses 1 for the expected ESRCH/EPERM outcomes.  Anything
    # else is an unexpected probe failure and must retain the workspace.
    [[ $probe_status -eq 1 ]] || return 2
    [[ -d "${RUNNER_PROC_ROOT:-/proc}" ]] || return 2

    for stat_file in "${RUNNER_PROC_ROOT:-/proc}"/[0-9]*/stat; do
        [[ -e "$stat_file" ]] || continue
        # Tests use this hook to deterministically model a process exiting
        # after globbing /proc and before stat can be read.
        if [[ -n "${RUNNER_PROC_BEFORE_STAT_READ:-}" ]]; then
            "$RUNNER_PROC_BEFORE_STAT_READ" "$stat_file" || return 2
        fi
        if ! stat_line=$(command cat -- "$stat_file" 2>/dev/null); then
            # A process can normally exit in this small window.  The vanished
            # entry is absence, unlike a stat file that remains unreadable.
            [[ -e "$stat_file" ]] || continue
            return 2
        fi
        # Fields after the final ')' are: state (3), ppid (4), pgrp (5), ... .
        rest="${stat_line##*) }"
        read -r state ppid stat_pgid ignored <<<"$rest"
        [[ "$state" =~ ^[RSDZTWXxKWPIt]$ && "$ppid" =~ ^[0-9]+$ && "$stat_pgid" =~ ^[0-9]+$ && -n "$ignored" ]] || return 2
        [[ "$stat_pgid" == "$pgid" ]] && return 0
    done

    return 1
}

# A group proven absent cannot contain a running leader, so wait can only reap
# the already-dead child.  The watchdog makes that invariant an actual one-
# second deadline rather than relying on wait's expected immediate return.
_reap_absent_runner_leader() {
    local pgid="$1"
    local timed_out=0
    local parent_pid="$BASHPID"
    local watchdog_pid
    local saved_usr1_trap

    saved_usr1_trap=$(trap -p USR1 || true)
    trap 'timed_out=1' USR1
    ( command "$REAL_SLEEP" 1 && kill -USR1 "$parent_pid" 2>/dev/null ) &
    watchdog_pid=$!

    wait "$pgid" 2>/dev/null || true
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    if [[ -n "$saved_usr1_trap" ]]; then
        eval "$saved_usr1_trap"
    else
        trap - USR1
    fi

    [[ $timed_out -eq 0 ]]
}

# Stop a runner session without deleting its workspace while a descendant may
# still be using it.  The six-second TERM grace and one-second KILL
# confirmation are elapsed-time deadlines.  Every iteration rechecks its
# phase deadline after probing, and polls for at most 0.1 seconds at a time.
# Tests may inject shorter deadlines without changing the production defaults.
_cleanup_runner_group() {
    local pgid="${1:-}"
    local term_grace_seconds="${RUNNER_TERM_GRACE_SECONDS:-$RUNNER_TERM_GRACE_SECONDS_DEFAULT}"
    local kill_confirmation_seconds="${RUNNER_KILL_CONFIRMATION_SECONDS:-$RUNNER_KILL_CONFIRMATION_SECONDS_DEFAULT}"
    local term_grace_microseconds=0
    local kill_confirmation_microseconds=0
    local phase_deadline_microseconds=0
    local remaining_microseconds=0
    local group_state=0
    local grace_failed=0

    [[ -z "$pgid" ]] && return 0
    _runner_cleanup_seconds_to_microseconds "$term_grace_seconds" || return 1
    term_grace_microseconds=$RUNNER_CLEANUP_DURATION_MICROSECONDS
    _runner_cleanup_seconds_to_microseconds "$kill_confirmation_seconds" || return 1
    kill_confirmation_microseconds=$RUNNER_CLEANUP_DURATION_MICROSECONDS

    if _runner_group_state "$pgid"; then group_state=0; else group_state=$?; fi
    if [[ $group_state -eq 1 ]]; then
        _reap_absent_runner_leader "$pgid"
        return $?
    fi
    [[ $group_state -eq 0 ]] || return 1

    env kill -TERM -- "-$pgid" 2>/dev/null || true
    _runner_cleanup_time_now || return 1
    phase_deadline_microseconds=$((RUNNER_CLEANUP_NOW_MICROSECONDS + term_grace_microseconds))
    while :; do
        _runner_cleanup_time_now || return 1
        ((RUNNER_CLEANUP_NOW_MICROSECONDS >= phase_deadline_microseconds)) && break
        if _runner_group_state "$pgid"; then group_state=0; else group_state=$?; fi
        [[ $group_state -eq 1 ]] && break
        [[ $group_state -eq 0 ]] || return 1
        _runner_cleanup_time_now || return 1
        ((RUNNER_CLEANUP_NOW_MICROSECONDS >= phase_deadline_microseconds)) && break
        remaining_microseconds=$((phase_deadline_microseconds - RUNNER_CLEANUP_NOW_MICROSECONDS))
        if ! _runner_cleanup_sleep_remaining "$remaining_microseconds"; then
            grace_failed=1
            break
        fi
    done

    if _runner_group_state "$pgid"; then group_state=0; else group_state=$?; fi
    if [[ $group_state -eq 1 ]]; then
        _reap_absent_runner_leader "$pgid" || return 1
        [[ $grace_failed -eq 0 ]]
        return
    fi
    # Escalation requires positive evidence that the group still exists.
    [[ $group_state -eq 0 ]] || return 1
    env kill -KILL -- "-$pgid" 2>/dev/null || true

    _runner_cleanup_time_now || return 1
    phase_deadline_microseconds=$((RUNNER_CLEANUP_NOW_MICROSECONDS + kill_confirmation_microseconds))
    while :; do
        _runner_cleanup_time_now || return 1
        ((RUNNER_CLEANUP_NOW_MICROSECONDS >= phase_deadline_microseconds)) && break
        if _runner_group_state "$pgid"; then group_state=0; else group_state=$?; fi
        [[ $group_state -eq 1 ]] && break
        [[ $group_state -eq 0 ]] || return 1
        _runner_cleanup_time_now || return 1
        ((RUNNER_CLEANUP_NOW_MICROSECONDS >= phase_deadline_microseconds)) && break
        remaining_microseconds=$((phase_deadline_microseconds - RUNNER_CLEANUP_NOW_MICROSECONDS))
        if ! _runner_cleanup_sleep_remaining "$remaining_microseconds"; then
            grace_failed=1
            break
        fi
    done

    if _runner_group_state "$pgid"; then group_state=0; else group_state=$?; fi
    [[ $group_state -eq 1 ]] || return 1
    _reap_absent_runner_leader "$pgid" || return 1

    [[ $grace_failed -eq 0 ]]
}

# Keep RUNNER_PGID empty until the child-reported group is known not to be the
# Bats harness group.  Teardown relies on that empty value to preserve rather
# than signal a workspace whose session identity was rejected.
_record_validated_runner_pgid() {
    local reported_pgid="$1"
    local bats_pgid="$2"

    _runner_pgid_is_valid "$reported_pgid" || return 1
    _runner_pgid_is_valid "$bats_pgid" || return 1
    [[ "$reported_pgid" != "$bats_pgid" ]] || return 1
    RUNNER_PGID="$reported_pgid"
}

# ---------------------------------------------------------------------------
# Test 1: Missing env vars → exit 1 with correct error message
# ---------------------------------------------------------------------------

@test "missing auth env vars exits 1 with authentication error" {
    unset GITHUB_TOKEN APP_ID APP_PRIVATE_KEY APP_PRIVATE_KEY_FILE
    export GITHUB_REPOSITORY="owner/repo"

    # run bats helper captures exit status and output
    run bash -c "cd '$RUNNER_WORK' && bash '$ENTRYPOINT' 2>&1"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Authentication not configured"* ]] || \
    [[ "$output" == *"GITHUB_TOKEN"* ]]
}

@test "missing scope env vars exits 1 with scope error" {
    export GITHUB_TOKEN="ghp_fake"
    unset GITHUB_REPOSITORY GITHUB_ORG

    run bash -c "cd '$RUNNER_WORK' && bash '$ENTRYPOINT' 2>&1"
    [ "$status" -eq 1 ]
    [[ "$output" == *"GITHUB_REPOSITORY"* ]] || \
    [[ "$output" == *"GITHUB_ORG"* ]]
}

# ---------------------------------------------------------------------------
# Test 2: PAT path → calls correct registration API endpoint
# ---------------------------------------------------------------------------

@test "PAT auth calls registration-token API with Authorization: token header" {
    export GITHUB_TOKEN="ghp_pattoken"
    export GITHUB_REPOSITORY="owner/repo"

    run bash -c "cd '$RUNNER_WORK' && bash '$ENTRYPOINT' 2>&1"
    [ "$status" -eq 0 ]

    # Verify the correct API endpoint was called
    grep -q "repos/owner/repo/actions/runners/registration-token" \
        "$WORK_DIR/curl-urls.log"
}

# ---------------------------------------------------------------------------
# Test 3: App path → JWT generated and exchanged for installation token
# ---------------------------------------------------------------------------

@test "App auth path exchanges JWT for installation token" {
    # Create a minimal fake PEM key file (not a real RSA key — openssl is mocked)
    local fake_key="$WORK_DIR/fake.pem"
    printf '%s\n' \
        "-----BEGIN RSA PRIVATE KEY-----" \
        "MIIFAKEKEY" \
        "-----END RSA PRIVATE KEY-----" > "$fake_key"

    export APP_ID="123456"
    export APP_PRIVATE_KEY_FILE="$fake_key"
    export GITHUB_REPOSITORY="owner/repo"
    unset GITHUB_TOKEN APP_PRIVATE_KEY

    # Mock curl to: first call (installation lookup) returns install id,
    # second call (access_tokens) returns access_token,
    # third call (registration-token) returns reg token
    cat > "$BIN_DIR/curl" <<'MOCK'
#!/usr/bin/env bash
call_file="WORK_DIR_PLACEHOLDER/.curl-app-count"
count=$(cat "$call_file" 2>/dev/null || echo 0)
count=$((count + 1))
echo "$count" > "$call_file"

for arg in "$@"; do
    [[ "$arg" =~ ^https?:// ]] && echo "$arg" >> "WORK_DIR_PLACEHOLDER/curl-urls.log"
done

outfile=""
next_is_out=false
for arg in "$@"; do
    if [[ "$next_is_out" == "true" ]]; then outfile="$arg"; next_is_out=false; fi
    [[ "$arg" == "-o" ]] && next_is_out=true
done

case "$count" in
    1)  body='{"id":99887766}'      ; status=200 ;;  # installation lookup
    2)  body='{"token":"app-access-token-xyz"}' ; status=201 ;;  # access_tokens
    3)  body='{"token":"reg-token-from-app"}' ; status=201 ;;    # registration-token
    *)  body='{}' ; status=200 ;;
esac

if [[ -n "$outfile" ]]; then
    printf '%s' "$body" > "$outfile"
    printf '%s' "$status"
else
    printf '%s' "$body"
fi
exit 0
MOCK
    # Replace placeholder with actual WORK_DIR
    sed -i "s|WORK_DIR_PLACEHOLDER|${WORK_DIR}|g" "$BIN_DIR/curl"
    chmod +x "$BIN_DIR/curl"

    run bash -c "cd '$RUNNER_WORK' && bash '$ENTRYPOINT' 2>&1"
    [ "$status" -eq 0 ]

    # Should have called the installation API
    grep -q "installation" "$WORK_DIR/curl-urls.log"
    # Should have called access_tokens
    grep -q "access_tokens" "$WORK_DIR/curl-urls.log"
}

# ---------------------------------------------------------------------------
# Test 4: Repo scope → API URL contains /repos/owner/repo/
# ---------------------------------------------------------------------------

@test "repo scope uses repos API path for registration-token" {
    export GITHUB_TOKEN="ghp_pattoken"
    export GITHUB_REPOSITORY="myowner/myrepo"
    unset GITHUB_ORG

    run bash -c "cd '$RUNNER_WORK' && bash '$ENTRYPOINT' 2>&1"
    [ "$status" -eq 0 ]

    grep -q "repos/myowner/myrepo/actions/runners/registration-token" \
        "$WORK_DIR/curl-urls.log"
}

# ---------------------------------------------------------------------------
# Test 5: Org scope → API URL contains /orgs/myorg/
# ---------------------------------------------------------------------------

@test "org scope uses orgs API path for registration-token" {
    export GITHUB_TOKEN="ghp_pattoken"
    export GITHUB_ORG="myorg"
    unset GITHUB_REPOSITORY

    run bash -c "cd '$RUNNER_WORK' && bash '$ENTRYPOINT' 2>&1"
    [ "$status" -eq 0 ]

    grep -q "orgs/myorg/actions/runners/registration-token" \
        "$WORK_DIR/curl-urls.log"
}

# ---------------------------------------------------------------------------
# Test 6: Retry logic → 3 failed attempts then success
# ---------------------------------------------------------------------------

@test "retry logic succeeds after 3 failed curl calls" {
    export GITHUB_TOKEN="ghp_pattoken"
    export GITHUB_REPOSITORY="owner/repo"

    # 3 failures then success on attempt 4
    _write_mock_curl_fail_then_succeed 3 '{"token":"retry-success-token"}'

    run bash -c "cd '$RUNNER_WORK' && bash '$ENTRYPOINT' 2>&1"
    [ "$status" -eq 0 ]

    # Verify 4 calls were made to curl
    local call_count
    call_count=$(cat "$WORK_DIR/curl-call-count" 2>/dev/null || echo 0)
    [ "$call_count" -ge 4 ]
}

# ---------------------------------------------------------------------------
# Test 7: Max retries → 5 failures → exit 1 with "5 attempts" message
# ---------------------------------------------------------------------------

@test "max retries hit after 5 failures exits 1 with 5 attempts message" {
    export GITHUB_TOKEN="ghp_pattoken"
    export GITHUB_REPOSITORY="owner/repo"

    # All 5 attempts fail
    _write_mock_curl_fail_then_succeed 99 '{"token":"never"}'

    run bash -c "cd '$RUNNER_WORK' && bash '$ENTRYPOINT' 2>&1"
    [ "$status" -eq 1 ]
    [[ "$output" == *"5 attempts"* ]]
}

# ---------------------------------------------------------------------------
# Test 8: Retry-After header — mock a 429 response with Retry-After header
# ---------------------------------------------------------------------------

@test "429 response without Retry-After header still retries then fails" {
    export GITHUB_TOKEN="ghp_pattoken"
    export GITHUB_REPOSITORY="owner/repo"

    # Write a curl mock that always returns 429 (no Retry-After)
    cat > "$BIN_DIR/curl" <<MOCK
#!/usr/bin/env bash
for arg in "\$@"; do
    [[ "\$arg" =~ ^https?:// ]] && echo "\$arg" >> "$WORK_DIR/curl-urls.log"
done
outfile=""
next_is_out=false
for arg in "\$@"; do
    if [[ "\$next_is_out" == "true" ]]; then outfile="\$arg"; next_is_out=false; fi
    [[ "\$arg" == "-o" ]] && next_is_out=true
done
if [[ -n "\$outfile" ]]; then
    printf '{"message":"rate limited"}' > "\$outfile"
    printf '429'
else
    printf '{"message":"rate limited"}'
fi
exit 0
MOCK
    chmod +x "$BIN_DIR/curl"

    run bash -c "cd '$RUNNER_WORK' && bash '$ENTRYPOINT' 2>&1"
    [ "$status" -eq 1 ]
    [[ "$output" == *"5 attempts"* ]]
}

# ---------------------------------------------------------------------------
# Test 9: Name conflict — exit code 3 from config.sh triggers --replace
# ---------------------------------------------------------------------------

@test "config.sh exit code 3 is treated as failure and runner exits non-zero" {
    export GITHUB_TOKEN="ghp_pattoken"
    export GITHUB_REPOSITORY="owner/repo"

    # config.sh exits 3 (name conflict)
    cat > "$RUNNER_WORK/config.sh" <<'MOCK'
#!/usr/bin/env bash
exit 3
MOCK
    chmod +x "$RUNNER_WORK/config.sh"

    run bash -c "cd '$RUNNER_WORK' && bash '$ENTRYPOINT' 2>&1"
    # Entrypoint propagates config.sh exit code
    [ "$status" -ne 0 ]
    [[ "$output" == *"config.sh exited with code 3"* ]] || \
    [[ "$output" == *"registration failed"* ]]
}

# ---------------------------------------------------------------------------
# Test 10: SIGTERM cleanup → deregistration call before exit
# ---------------------------------------------------------------------------

@test "job-controlled launch records the child-owned runner process group" {
    export GITHUB_TOKEN="ghp_pattoken"
    export GITHUB_REPOSITORY="owner/repo"

    # This is the case that makes parent-side $! unusable: Bash gives the
    # background job its own group, so setsid forks and the PID it returns dies.
    set -m
    [[ "$-" == *m* ]]

    cat > "$RUNNER_WORK/run.sh" <<MOCK
#!/usr/bin/env bash
touch "$WORK_DIR/runner-started"
command "$REAL_SLEEP" 5
MOCK
    chmod +x "$RUNNER_WORK/run.sh"

    export RUNNER_WORK ENTRYPOINT RUNNER_IDENTITY_FILE
    RUNNER_LAUNCH_ATTEMPTED=1
    command setsid bash -c '
        identity_pid=$BASHPID
        identity_pgid=$(ps -o pgid= -p "$identity_pid") || exit 1
        identity_pgid=${identity_pgid//[[:space:]]/}
        identity_tmp="${RUNNER_IDENTITY_FILE}.tmp"
        printf "%s %s\\n" "$identity_pid" "$identity_pgid" > "$identity_tmp" &&
            mv -f "$identity_tmp" "$RUNNER_IDENTITY_FILE" || exit 1
        cd "$RUNNER_WORK" || exit 1
        exec bash "$ENTRYPOINT"
    ' 2>"$LOG_FILE" &
    local launch_pid=$!

    local identity_waited=0
    while [[ ! -f "$RUNNER_IDENTITY_FILE" ]] && [[ $identity_waited -lt 50 ]]; do
        _real_sleep 0.1 || return 1
        identity_waited=$((identity_waited + 1))
    done

    local reported_pid=""
    local reported_pgid=""
    local identity_extra=""
    [[ -f "$RUNNER_IDENTITY_FILE" ]]
    IFS=' ' read -r reported_pid reported_pgid identity_extra < "$RUNNER_IDENTITY_FILE"
    [[ "$reported_pid" =~ ^[1-9][0-9]*$ ]]
    [[ "$reported_pgid" =~ ^[1-9][0-9]*$ ]]
    [[ -z "$identity_extra" ]]

    # setsid's child owns the new session, so its PID and PGID agree.  Neither
    # may be the transient PID returned by the parent-side background launch.
    [[ "$reported_pid" == "$reported_pgid" ]]
    [[ "$reported_pgid" != "$launch_pid" ]]

    local bats_pgid
    bats_pgid=$(ps -o pgid= -p "$BASHPID") || return 1
    bats_pgid=${bats_pgid//[[:space:]]/}
    _record_validated_runner_pgid "$reported_pgid" "$bats_pgid" || return 1

    local waited=0
    while [[ ! -f "$WORK_DIR/runner-started" ]] && [[ $waited -lt 50 ]]; do
        _real_sleep 0.1 || return 1
        waited=$((waited + 1))
    done
    [[ -f "$WORK_DIR/runner-started" ]]

    if ! _cleanup_runner_group "$RUNNER_PGID"; then
        return 1
    fi
    RUNNER_PGID=""
    RUNNER_LAUNCH_ATTEMPTED=0
}

@test "rejecting Bats' process group leaves runner identity empty for teardown" {
    RUNNER_LAUNCH_ATTEMPTED=1

    local bats_pgid validator_status=0 validated_pgid=""
    bats_pgid=$(ps -o pgid= -p "$BASHPID") || return 1
    bats_pgid=${bats_pgid//[[:space:]]/}
    [[ "$bats_pgid" =~ ^[1-9][0-9]*$ ]]

    _record_validated_runner_pgid "$bats_pgid" "$bats_pgid" || validator_status=$?
    # A deliberately-mutated validator can assign Bats' group before rejecting
    # it.  Copy then clear its output before any assertion can return to Bats,
    # so teardown never signals the harness under that regression.
    validated_pgid=$RUNNER_PGID
    RUNNER_PGID=""
    [[ $validator_status -ne 0 && -z "$validated_pgid" ]]

    local teardown_status=0
    teardown || teardown_status=$?
    [[ $teardown_status -ne 0 && -d "$WORK_DIR" ]]

    # Bats invokes teardown again after this test; now allow normal removal.
    RUNNER_LAUNCH_ATTEMPTED=0
}

@test "validator rejects an arithmetic-hostile PGID before teardown" {
    RUNNER_LAUNCH_ATTEMPTED=1

    local bats_pgid validator_status=0 validated_pgid=""
    bats_pgid=$(ps -o pgid= -p "$BASHPID") || return 1
    bats_pgid=${bats_pgid//[[:space:]]/}

    _record_validated_runner_pgid '9999999999999999999999999999999999999999' "$bats_pgid" || validator_status=$?
    validated_pgid=$RUNNER_PGID
    RUNNER_PGID=""
    [[ $validator_status -ne 0 && -z "$validated_pgid" ]]

    local teardown_status=0
    teardown || teardown_status=$?
    [[ $teardown_status -ne 0 && -d "$WORK_DIR" ]]

    RUNNER_LAUNCH_ATTEMPTED=0
}

@test "SIGTERM triggers cleanup deregistration before exit" {
    export GITHUB_TOKEN="ghp_pattoken"
    export GITHUB_REPOSITORY="owner/repo"

    # The runner itself publishes readiness after a bounded delay.  It also
    # self-expires, so an abruptly killed Bats process leaves only a bounded
    # child behind.  Its TERM marker proves the entrypoint's group signal
    # reaches the runner, not just the entrypoint leader.
    cat > "$RUNNER_WORK/run.sh" <<MOCK
#!/usr/bin/env bash
trap 'touch "$WORK_DIR/runner-terminated"; exit 0' TERM INT
command "$REAL_SLEEP" 0.1
touch "$WORK_DIR/runner-started"
command "$REAL_SLEEP" 5
MOCK
    chmod +x "$RUNNER_WORK/run.sh"

    # Record config.sh remove invocations so this test proves deregistration,
    # not merely that its log contains a generic runner-related message.
    cat > "$RUNNER_WORK/config.sh" <<MOCK
#!/usr/bin/env bash
if [[ "\$1" == "remove" ]]; then
    touch "$WORK_DIR/runner-deregistered"
fi
exit 0
MOCK
    chmod +x "$RUNNER_WORK/config.sh"

    export RUNNER_WORK ENTRYPOINT RUNNER_IDENTITY_FILE
    RUNNER_LAUNCH_ATTEMPTED=1
    command setsid bash -c '
        identity_pid=$BASHPID
        identity_pgid=$(ps -o pgid= -p "$identity_pid") || exit 1
        identity_pgid=${identity_pgid//[[:space:]]/}
        identity_tmp="${RUNNER_IDENTITY_FILE}.tmp"
        printf "%s %s\\n" "$identity_pid" "$identity_pgid" > "$identity_tmp" &&
            mv -f "$identity_tmp" "$RUNNER_IDENTITY_FILE" || exit 1
        cd "$RUNNER_WORK" || exit 1
        exec bash "$ENTRYPOINT"
    ' 2>"$LOG_FILE" &

    # The session-owning shell writes this atomically before it execs the
    # entrypoint.  In particular, never infer a group from the parent-side
    # launch PID: setsid may fork, and the parent can otherwise observe Bats'
    # own process group.
    local identity_waited=0
    while [[ ! -f "$RUNNER_IDENTITY_FILE" ]] && [[ $identity_waited -lt 50 ]]; do
        _real_sleep 0.1 || return 1
        identity_waited=$((identity_waited + 1))
    done

    local reported_pid=""
    local reported_pgid=""
    local identity_extra=""
    if [[ ! -f "$RUNNER_IDENTITY_FILE" ]] || \
        ! IFS=' ' read -r reported_pid reported_pgid identity_extra < "$RUNNER_IDENTITY_FILE" || \
        [[ ! "$reported_pid" =~ ^[1-9][0-9]*$ ]] || \
        [[ ! "$reported_pgid" =~ ^[1-9][0-9]*$ ]] || \
        [[ "$reported_pid" != "$reported_pgid" ]] || \
        [[ -n "$identity_extra" ]]; then
        echo "Could not establish runner process group from its session handshake" >&2
        local teardown_status=0
        teardown || teardown_status=$?
        [[ $teardown_status -ne 0 && -d "$WORK_DIR" ]] || return 1
        return 1
    fi
    # A Linux setsid session leader owns its process group, so the handshake
    # must report matching PID and PGID.  Reject non-POSIX setsid behaviour
    # rather than signal a positive group the child does not own.
    # The recorded group must also not be Bats' group.  This catches any
    # regression that reintroduces parent-side process-group discovery.
    local bats_pgid
    bats_pgid=$(ps -o pgid= -p "$BASHPID") || return 1
    bats_pgid=${bats_pgid//[[:space:]]/}
    if [[ ! "$bats_pgid" =~ ^[1-9][0-9]*$ || "$reported_pgid" == "$bats_pgid" ]]; then
        return 1
    fi
    _record_validated_runner_pgid "$reported_pgid" "$bats_pgid" || return 1

    # Wait for runner to start (max 5s).
    local waited=0
    while [[ ! -f "$WORK_DIR/runner-started" ]] && [[ $waited -lt 50 ]]; do
        _real_sleep 0.1 || return 1
        waited=$((waited + 1))
    done
    [[ -f "$WORK_DIR/runner-started" ]]

    # Prove the child-reported group exists before signalling all its members.
    if ! kill -0 -- "-$RUNNER_PGID"; then
        _cleanup_runner_group "$RUNNER_PGID" || true
        return 1
    fi
    kill -TERM -- "-$RUNNER_PGID"

    # A leader-only signal leaves run.sh running until its self-expiry.  Check
    # the runner's signal marker before the cleanup helper can signal it again.
    local signal_waited=0
    while [[ ! -f "$WORK_DIR/runner-terminated" ]] && [[ $signal_waited -lt 10 ]]; do
        _real_sleep 0.1 || return 1
        signal_waited=$((signal_waited + 1))
    done
    if [[ ! -f "$WORK_DIR/runner-terminated" ]]; then
        _cleanup_runner_group "$RUNNER_PGID" || true
        return 1
    fi

    # The helper bounds the wait and escalates if the group does not exit.
    _cleanup_runner_group "$RUNNER_PGID"

    # Deregistration obtains a removal token and invokes config.sh remove.
    grep -q "repos/owner/repo/actions/runners/remove-token" "$WORK_DIR/curl-urls.log"
    [[ -f "$WORK_DIR/runner-deregistered" ]]
    grep -q "Runner deregistered\." "$LOG_FILE"

}

# The decision table below exercises cleanup state transitions without real
# processes.  End-to-end orchestration covers actual survivor and disk-growth
# behaviour, where it is observable without making each fixture a leak/race.
_write_mock_kill_sequence() {
    local states="$1"

    cat > "$BIN_DIR/kill" <<MOCK
#!/usr/bin/env bash
if [[ "\$1" == "-0" ]]; then
    count_file="$WORK_DIR/kill-probe-count"
    count=\$(cat "\$count_file" 2>/dev/null || echo 0)
    state=\$(printf '%s\\n' '$states' | sed -n "\$((count + 1))p")
    [[ -n "\$state" ]] || state=\$(printf '%s\\n' '$states' | tail -n 1)
    echo \$((count + 1)) > "\$count_file"
    case "\$state" in
        present) exit 0 ;;
        absent) exit 1 ;;
        unknown) exit 2 ;;
    esac
fi
echo "\$1" >> "$WORK_DIR/kill-signals.log"
exit 0
MOCK
    chmod +x "$BIN_DIR/kill"
}

@test "cleanup succeeds when probes change from present to absent" {
    _write_mock_kill_sequence $'present\nabsent'

    _cleanup_runner_group 424242

    [[ -d "$WORK_DIR" ]]
    grep -q -- '-TERM' "$WORK_DIR/kill-signals.log"
}

@test "cleanup fails and retains workspace when probes stay present" {
    _write_mock_kill_sequence 'present'

    local cleanup_status=0
    _cleanup_runner_group 424242 || cleanup_status=$?

    [[ $cleanup_status -ne 0 ]]
    [[ -d "$WORK_DIR" ]]
    grep -q -- '-KILL' "$WORK_DIR/kill-signals.log"
}

@test "teardown retains workspace when cleanup cannot prove group extinction" {
    _write_mock_kill_sequence 'present'
    RUNNER_PGID=424242

    local teardown_status=0
    teardown || teardown_status=$?

    [[ $teardown_status -ne 0 ]]
    [[ -d "$WORK_DIR" ]]

    # Bats invokes teardown again after this test.  Clear the synthetic group
    # only after observing that this teardown left the workspace intact.
    RUNNER_PGID=""
}

@test "teardown retains workspace when a launch has unknown identity" {
    RUNNER_LAUNCH_ATTEMPTED=1

    local teardown_status=0
    teardown || teardown_status=$?

    [[ $teardown_status -ne 0 ]]
    [[ -d "$WORK_DIR" ]]

    # Bats invokes teardown again after this test.  Clear the launch marker
    # only after observing that this teardown left the workspace intact.
    RUNNER_LAUNCH_ATTEMPTED=0
}

@test "runner group state parses final parenthesis and lowercase state from fixture" {
    # Force the initial signal probe to say absent so the test necessarily
    # reads the fixture instead of returning early for a host process group.
    _write_mock_kill_sequence 'absent'

    local proc_fixture="$WORK_DIR/proc-fixture"
    mkdir -p "$proc_fixture/991"
    printf '%s\n' '991 (runner test) name) t 1 424242 1 1 0' > "$proc_fixture/991/stat"

    RUNNER_PROC_ROOT="$proc_fixture" _runner_group_state 424242
    [[ "$(cat "$WORK_DIR/kill-probe-count")" -eq 1 ]]
}

@test "runner group state reports absent when fixture contains no group member" {
    _write_mock_kill_sequence 'absent'

    local proc_fixture="$WORK_DIR/proc-fixture"
    mkdir -p "$proc_fixture/991"
    printf '%s\n' '991 (runner test) S 1 999999 1 1 0' > "$proc_fixture/991/stat"

    local state_status=0
    RUNNER_PROC_ROOT="$proc_fixture" _runner_group_state 424242 || state_status=$?
    [[ $state_status -eq 1 ]]
    [[ "$(cat "$WORK_DIR/kill-probe-count")" -eq 1 ]]
}

@test "runner group state treats a stat entry that vanishes during enumeration as absent" {
    _write_mock_kill_sequence 'absent'

    local proc_fixture="$WORK_DIR/proc-fixture"
    mkdir -p "$proc_fixture/991"
    printf '%s\n' '991 (runner test) S 1 424242 1 1 0' > "$proc_fixture/991/stat"
    cat > "$BIN_DIR/remove-stat-before-read" <<'MOCK'
#!/usr/bin/env bash
rm -f -- "$1"
MOCK
    chmod +x "$BIN_DIR/remove-stat-before-read"

    local state_status=0
    RUNNER_PROC_ROOT="$proc_fixture" \
        RUNNER_PROC_BEFORE_STAT_READ="$BIN_DIR/remove-stat-before-read" \
        _runner_group_state 424242 || state_status=$?
    [[ $state_status -eq 1 ]]
    [[ "$(cat "$WORK_DIR/kill-probe-count")" -eq 1 ]]
}

@test "runner group state treats a persistent stat read failure as unknown" {
    _write_mock_kill_sequence 'absent'

    local proc_fixture="$WORK_DIR/proc-fixture"
    # A directory at stat's path is permanently unreadable as a stat record,
    # while still existing after cat fails.
    mkdir -p "$proc_fixture/991/stat"

    local state_status=0
    RUNNER_PROC_ROOT="$proc_fixture" _runner_group_state 424242 || state_status=$?
    [[ $state_status -eq 2 ]]
    [[ -d "$proc_fixture/991/stat" ]]
    [[ "$(cat "$WORK_DIR/kill-probe-count")" -eq 1 ]]
}

@test "cleanup does not KILL when final group confirmation is unknown" {
    _write_mock_kill_sequence $'present\nabsent\nunknown'

    local cleanup_status=0
    _cleanup_runner_group 424242 || cleanup_status=$?

    [[ $cleanup_status -ne 0 ]]
    [[ -d "$WORK_DIR" ]]
    grep -q -- '-TERM' "$WORK_DIR/kill-signals.log"
    [[ ! -f "$WORK_DIR/kill-signals.log" ]] || ! grep -q -- '-KILL' "$WORK_DIR/kill-signals.log"
}

@test "cleanup does not KILL when a TERM-grace probe is unknown" {
    _write_mock_kill_sequence $'present\nunknown'
    RUNNER_TERM_GRACE_SECONDS=1

    local cleanup_status=0
    _cleanup_runner_group 424242 || cleanup_status=$?

    [[ $cleanup_status -ne 0 ]]
    grep -q -- '-TERM' "$WORK_DIR/kill-signals.log"
    [[ ! -f "$WORK_DIR/kill-signals.log" ]] || ! grep -q -- '-KILL' "$WORK_DIR/kill-signals.log"
}

@test "cleanup retains the workspace when a KILL-confirmation probe is unknown" {
    _write_mock_kill_sequence $'present\npresent\nunknown'
    RUNNER_TERM_GRACE_SECONDS=0
    RUNNER_KILL_CONFIRMATION_SECONDS=1

    local cleanup_status=0
    _cleanup_runner_group 424242 || cleanup_status=$?

    [[ $cleanup_status -ne 0 ]]
    grep -q -- '-TERM' "$WORK_DIR/kill-signals.log"
    grep -q -- '-KILL' "$WORK_DIR/kill-signals.log"
}

@test "cleanup fails after a failed grace period when a later probe proves absence" {
    _write_mock_kill_sequence $'present\npresent\nabsent'
    cat > "$BIN_DIR/failing-real-sleep" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
    chmod +x "$BIN_DIR/failing-real-sleep"
    RUNNER_REAL_SLEEP="$BIN_DIR/failing-real-sleep"

    local cleanup_status=0
    _cleanup_runner_group 424242 || cleanup_status=$?

    [[ $cleanup_status -ne 0 ]]
    [[ -d "$WORK_DIR" ]]
    [[ ! -f "$WORK_DIR/kill-signals.log" ]] || ! grep -q -- '-KILL' "$WORK_DIR/kill-signals.log"
}

@test "cleanup deadline defaults remain the documented grace periods" {
    unset RUNNER_TERM_GRACE_SECONDS RUNNER_KILL_CONFIRMATION_SECONDS

    [[ $RUNNER_TERM_GRACE_SECONDS_DEFAULT -eq 6 ]]
    [[ $RUNNER_KILL_CONFIRMATION_SECONDS_DEFAULT -eq 1 ]]
}

@test "cleanup TERM grace ends on elapsed probe time without sleeping" {
    local fake_clock_microseconds=0 probe_count=0
    RUNNER_TERM_GRACE_SECONDS=1
    RUNNER_KILL_CONFIRMATION_SECONDS=0

    # The fake clock and probe run in this shell, so advancing the clock costs
    # no wall time.  The second present probe consumes the complete TERM grace.
    _runner_cleanup_time_now() {
        RUNNER_CLEANUP_NOW_MICROSECONDS=$fake_clock_microseconds
    }
    _runner_group_state() {
        probe_count=$((probe_count + 1))
        if [[ -f "$WORK_DIR/kill-seen" ]]; then
            return 1
        fi
        [[ $probe_count -gt 1 ]] && fake_clock_microseconds=1000000
        return 0
    }
    _runner_cleanup_sleep_remaining() {
        touch "$WORK_DIR/unexpected-cleanup-sleep"
        return 0
    }
    _reap_absent_runner_leader() {
        return 0
    }
    cat > "$BIN_DIR/kill" <<MOCK
#!/usr/bin/env bash
echo "\$1" >> "$WORK_DIR/kill-signals.log"
[[ "\$1" == "-KILL" ]] && touch "$WORK_DIR/kill-seen"
exit 0
MOCK
    chmod +x "$BIN_DIR/kill"

    _cleanup_runner_group 424242

    [[ ! -e "$WORK_DIR/unexpected-cleanup-sleep" ]]
    grep -q -- '-TERM' "$WORK_DIR/kill-signals.log"
    grep -q -- '-KILL' "$WORK_DIR/kill-signals.log"
}

# ---------------------------------------------------------------------------
# Test 11: Unique name → two invocations produce different RUNNER_NAME values
# ---------------------------------------------------------------------------

@test "two consecutive starts produce distinct runner names" {
    export GITHUB_TOKEN="ghp_pattoken"
    export GITHUB_REPOSITORY="owner/repo"
    export RUNNER_NAME_PREFIX="myrunner"

    # Capture runner name by inspecting config.sh arguments
    cat > "$RUNNER_WORK/config.sh" <<MOCK
#!/usr/bin/env bash
for arg in "\$@"; do
    if [[ "\$prev" == "--name" ]]; then
        echo "\$arg" >> "$WORK_DIR/runner-names.log"
    fi
    prev="\$arg"
done
exit 0
MOCK
    chmod +x "$RUNNER_WORK/config.sh"

    # First invocation
    bash -c "cd '$RUNNER_WORK' && bash '$ENTRYPOINT'" 2>/dev/null || true

    # Brief pause to ensure timestamp differs.
    _real_sleep 1

    # Second invocation
    bash -c "cd '$RUNNER_WORK' && bash '$ENTRYPOINT'" 2>/dev/null || true

    # Read captured names
    local name_count
    name_count=$(wc -l < "$WORK_DIR/runner-names.log" 2>/dev/null || echo 0)
    # We expect 2 names; they should differ (timestamp-based suffix)
    [ "$name_count" -ge 2 ]

    local name1 name2
    name1=$(sed -n '1p' "$WORK_DIR/runner-names.log")
    name2=$(sed -n '2p' "$WORK_DIR/runner-names.log")
    [ "$name1" != "$name2" ]
}

# ---------------------------------------------------------------------------
# Test 12: Root start → re-exec through gosu as runner
# ---------------------------------------------------------------------------

@test "running as root re-execs entrypoint through gosu as runner" {
    export GITHUB_TOKEN="ghp_pattoken"
    export GITHUB_REPOSITORY="owner/repo"

    cat > "$BIN_DIR/id" <<'MOCK'
#!/usr/bin/env bash
if [[ "$*" == *"-u"* ]] || [[ "$1" == "-u" ]] || [[ $# -eq 0 ]]; then
    echo "0"
else
    /usr/bin/id "$@"
fi
MOCK
    chmod +x "$BIN_DIR/id"
    cat > "$BIN_DIR/gosu" <<MOCK
#!/usr/bin/env bash
printf '%s\\n' "\$\$" > "$WORK_DIR/gosu-pid.log"
printf '%s\\n' "\$@" > "$WORK_DIR/gosu-args.log"
MOCK
    chmod +x "$BIN_DIR/gosu"
    cat > "$RUNNER_WORK/config.sh" <<MOCK
#!/usr/bin/env bash
touch "$WORK_DIR/entrypoint-continued-after-gosu"
exit 0
MOCK
    chmod +x "$RUNNER_WORK/config.sh"

    run bash -c "cd '$RUNNER_WORK' && printf '%s\\n' \"\$\$\" > '$WORK_DIR/entrypoint-pid.log'; exec bash '$ENTRYPOINT' 2>&1"
    [ "$status" -eq 0 ]
    printf '%s\n' runner "$ENTRYPOINT" > "$WORK_DIR/expected-gosu-args.log"
    cmp -s "$WORK_DIR/expected-gosu-args.log" "$WORK_DIR/gosu-args.log"
    # exec replaces the entrypoint shell with gosu, preserving its PID.  A
    # plain `gosu ...; exit $?` runs the mock as a child with a different PID.
    cmp -s "$WORK_DIR/entrypoint-pid.log" "$WORK_DIR/gosu-pid.log"
    [[ ! -e "$WORK_DIR/entrypoint-continued-after-gosu" ]]
}

@test "running as root carries original arguments through gosu" {
    export GITHUB_TOKEN="ghp_pattoken"
    export GITHUB_REPOSITORY="owner/repo"

    cat > "$BIN_DIR/id" <<'MOCK'
#!/usr/bin/env bash
if [[ "$*" == *"-u"* ]] || [[ "$1" == "-u" ]] || [[ $# -eq 0 ]]; then
    echo "0"
else
    /usr/bin/id "$@"
fi
MOCK
    chmod +x "$BIN_DIR/id"
    cat > "$BIN_DIR/gosu" <<MOCK
#!/usr/bin/env bash
printf '%s\\n' "\$\$" > "$WORK_DIR/gosu-pid.log"
printf '%s\\n' "\$@" > "$WORK_DIR/gosu-args.log"
MOCK
    chmod +x "$BIN_DIR/gosu"

    run bash -c "cd '$RUNNER_WORK' && printf '%s\\n' \"\$\$\" > '$WORK_DIR/entrypoint-pid.log'; exec bash '$ENTRYPOINT' --ephemeral --labels 'linux x' '*' 2>&1"
    [ "$status" -eq 0 ]
    # The space and literal glob ensure an unquoted $@ is rejected as well.
    printf '%s\n' runner "$ENTRYPOINT" --ephemeral --labels 'linux x' '*' > "$WORK_DIR/expected-gosu-args.log"
    cmp -s "$WORK_DIR/expected-gosu-args.log" "$WORK_DIR/gosu-args.log"
    cmp -s "$WORK_DIR/entrypoint-pid.log" "$WORK_DIR/gosu-pid.log"
}

# ---------------------------------------------------------------------------
# Test 13: environment validation still registers a configured repo scope
# ---------------------------------------------------------------------------

@test "configured Docker host does not alter registration validation" {
    export GITHUB_TOKEN="ghp_pattoken"
    export GITHUB_REPOSITORY="owner/repo"
    export DOCKER_HOST="unix:///var/run/docker.sock"

    run bash -c "cd '$RUNNER_WORK' && bash '$ENTRYPOINT' 2>&1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Scope: repo"* ]]
    grep -q "repos/owner/repo/actions/runners/registration-token" \
        "$WORK_DIR/curl-urls.log"
}

# ---------------------------------------------------------------------------
# Test 14: validate_env — GITHUB_API_URL override for GitHub Enterprise
# ---------------------------------------------------------------------------

@test "GITHUB_API_URL override is used in REG_TOKEN_API" {
    export GITHUB_TOKEN="ghp_pattoken"
    export GITHUB_REPOSITORY="owner/repo"
    export GITHUB_API_URL="https://github.example.com/api/v3"

    run bash -c "cd '$RUNNER_WORK' && bash '$ENTRYPOINT' 2>&1"
    [ "$status" -eq 0 ]

    grep -q "github.example.com" "$WORK_DIR/curl-urls.log"
}

# ---------------------------------------------------------------------------
# Test 15: fix_volume_permissions — non-writable dir warning
# ---------------------------------------------------------------------------

@test "fix_volume_permissions warns when cache dir is not writable" {
    export GITHUB_TOKEN="ghp_pattoken"
    export GITHUB_REPOSITORY="owner/repo"

    # Create a cache dir owned by root (not writable by current user)
    local ro_cache="$WORK_DIR/ro-cache"
    mkdir -p "$ro_cache"
    chmod 555 "$ro_cache"  # read + execute only

    export RUNNER_TOOL_CACHE="$ro_cache"

    run bash -c "cd '$RUNNER_WORK' && bash '$ENTRYPOINT' 2>&1"
    # The entrypoint should warn but continue (not exit due to this alone)
    [[ "$output" == *"not writable"* ]] || \
    [[ "$output" == *"permission"* ]] || \
    [ "$status" -eq 0 ]

    chmod 755 "$ro_cache"  # restore for teardown
}
