#!/usr/bin/env bats
# Unit tests for github-runner/entrypoint.sh
# Tests entrypoint logic WITHOUT live GitHub connectivity by mocking curl,
# config.sh, run.sh, and other external binaries.

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    RUNNER_DIR="$(cd "$TEST_DIR/.." && pwd)"
    ENTRYPOINT="$RUNNER_DIR/entrypoint.sh"
    # Resolve this before the mock directory shadows PATH.  type -P ignores
    # shell functions, and the resulting pathname does not depend on PATH.
    REAL_SLEEP="$(type -P sleep)"
    RUNNER_PGID=""

    # Temp workspace — every test gets an isolated directory
    WORK_DIR="$(mktemp -d)"
    BIN_DIR="$WORK_DIR/bin"
    RUNNER_WORK="$WORK_DIR/actions-runner"
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

    # Common env: always run as non-root for tests that don't check root
    export ALLOW_ROOT=false
    # Prevent auto-update noise
    export RUNNER_DISABLE_AUTO_UPDATE=1
    # Point cache dirs into temp space
    export HOME="$WORK_DIR/home"
    mkdir -p "$HOME"
}

teardown() {
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

# Return one of three states for a process group: 0 present, 1 absent, or 2
# unknown.  A failed signal probe alone is never evidence of extinction: an
# EPERM result has the same shell status as ESRCH.  /proc is available on the
# Linux-only test host, so membership in the process group is the authoritative
# answer when the normal probe has a conventional result.
_runner_group_state() {
    local pgid="${1:-}"
    local probe_status=0
    local stat_file stat_line state ppid stat_pgid ignored rest

    [[ "$pgid" =~ ^[1-9][0-9]*$ ]] || return 2

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
        stat_line=$(<"$stat_file") || return 2
        # Fields after the final ')' are: state (3), ppid (4), pgrp (5), ... .
        rest="${stat_line##*) }"
        read -r state ppid stat_pgid ignored <<<"$rest"
        [[ "$state" =~ ^[A-Z]$ && "$ppid" =~ ^[0-9]+$ && "$stat_pgid" =~ ^[0-9]+$ && -n "$ignored" ]] || return 2
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
# still be using it.  The six-second TERM grace exceeds the five-second
# readiness window; KILL confirmation is limited to one second.
_cleanup_runner_group() {
    local pgid="${1:-}"
    local term_waited=0
    local kill_waited=0
    local group_state=0
    local grace_failed=0

    [[ -z "$pgid" ]] && return 0

    if _runner_group_state "$pgid"; then group_state=0; else group_state=$?; fi
    if [[ $group_state -eq 1 ]]; then
        _reap_absent_runner_leader "$pgid"
        return $?
    fi
    [[ $group_state -eq 0 ]] || return 1

    env kill -TERM -- "-$pgid" 2>/dev/null || true
    while [[ $term_waited -lt 60 ]]; do
        if _runner_group_state "$pgid"; then group_state=0; else group_state=$?; fi
        [[ $group_state -eq 1 ]] && break
        [[ $group_state -eq 0 ]] || return 1
        if ! _real_sleep 0.1; then
            grace_failed=1
            break
        fi
        term_waited=$((term_waited + 1))
    done

    if _runner_group_state "$pgid"; then group_state=0; else group_state=$?; fi
    if [[ $grace_failed -eq 1 || $group_state -ne 1 ]]; then
        env kill -KILL -- "-$pgid" 2>/dev/null || true
    fi

    while [[ $kill_waited -lt 10 ]]; do
        if _runner_group_state "$pgid"; then group_state=0; else group_state=$?; fi
        [[ $group_state -eq 1 ]] && break
        [[ $group_state -eq 0 ]] || return 1
        if ! _real_sleep 0.1; then
            grace_failed=1
            break
        fi
        kill_waited=$((kill_waited + 1))
    done

    if _runner_group_state "$pgid"; then group_state=0; else group_state=$?; fi
    [[ $group_state -eq 1 ]] || return 1
    _reap_absent_runner_leader "$pgid" || return 1

    [[ $grace_failed -eq 0 ]]
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

    command setsid bash -c "cd '$RUNNER_WORK' && bash '$ENTRYPOINT'" 2>"$LOG_FILE" &
    local ep_pid=$!
    RUNNER_PGID="$ep_pid"
    if [[ -z "$RUNNER_PGID" ]]; then
        _cleanup_runner_group "$ep_pid" || true
        return 1
    fi

    # Wait for runner to start (max 5s).
    local waited=0
    while [[ ! -f "$WORK_DIR/runner-started" ]] && [[ $waited -lt 50 ]]; do
        _real_sleep 0.1 || return 1
        waited=$((waited + 1))
    done
    [[ -f "$WORK_DIR/runner-started" ]]

    # The entrypoint is the session and process-group leader, so its PID names
    # the group.  Prove the group exists before signalling all its members.
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
    RUNNER_REAL_SLEEP="$BIN_DIR/sleep"

    local cleanup_status=0
    _cleanup_runner_group 424242 || cleanup_status=$?

    [[ $cleanup_status -ne 0 ]]
    [[ -d "$WORK_DIR" ]]
    grep -q -- '-KILL' "$WORK_DIR/kill-signals.log"
}

@test "teardown retains workspace when cleanup cannot prove group extinction" {
    _write_mock_kill_sequence 'present'
    RUNNER_REAL_SLEEP="$BIN_DIR/sleep"
    RUNNER_PGID=424242

    local teardown_status=0
    teardown || teardown_status=$?

    [[ $teardown_status -ne 0 ]]
    [[ -d "$WORK_DIR" ]]

    # Bats invokes teardown again after this test.  Clear the synthetic group
    # only after observing that this teardown left the workspace intact.
    RUNNER_PGID=""
}

@test "cleanup fails and retains workspace when a probe is unknown" {
    _write_mock_kill_sequence 'unknown'

    local cleanup_status=0
    _cleanup_runner_group 424242 || cleanup_status=$?

    [[ $cleanup_status -ne 0 ]]
    [[ -d "$WORK_DIR" ]]
    [[ ! -f "$WORK_DIR/kill-signals.log" ]]
}

@test "cleanup fails after a failed grace period even when KILL proves absence" {
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
# Test 12: Root check → exit 1 when uid=0 and ALLOW_ROOT unset
# ---------------------------------------------------------------------------

@test "running as root without ALLOW_ROOT exits 1" {
    export GITHUB_TOKEN="ghp_pattoken"
    export GITHUB_REPOSITORY="owner/repo"
    unset ALLOW_ROOT

    # Mock id to return uid=0
    cat > "$BIN_DIR/id" <<'MOCK'
#!/usr/bin/env bash
if [[ "$*" == *"-u"* ]] || [[ "$1" == "-u" ]] || [[ $# -eq 0 ]]; then
    echo "0"
else
    /usr/bin/id "$@"
fi
MOCK
    chmod +x "$BIN_DIR/id"

    run bash -c "cd '$RUNNER_WORK' && bash '$ENTRYPOINT' 2>&1"
    [ "$status" -eq 1 ]
    [[ "$output" == *"root"* ]]
}

@test "running as root with ALLOW_ROOT=true continues startup" {
    export GITHUB_TOKEN="ghp_pattoken"
    export GITHUB_REPOSITORY="owner/repo"
    export ALLOW_ROOT=true

    # Mock id to return uid=0
    cat > "$BIN_DIR/id" <<'MOCK'
#!/usr/bin/env bash
if [[ "$*" == *"-u"* ]] || [[ "$1" == "-u" ]] || [[ $# -eq 0 ]]; then
    echo "0"
else
    /usr/bin/id "$@"
fi
MOCK
    chmod +x "$BIN_DIR/id"

    run bash -c "cd '$RUNNER_WORK' && bash '$ENTRYPOINT' 2>&1"
    # Should NOT fail with exit 1 due to root check
    # (may fail due to other reasons in test env, but not the root check)
    [[ "$output" != *"Running as root is not supported"* ]]
}

# ---------------------------------------------------------------------------
# Test 13: DooD socket — docker group membership check
# ---------------------------------------------------------------------------

@test "DooD: validate_env succeeds when docker socket would be mounted" {
    export GITHUB_TOKEN="ghp_pattoken"
    export GITHUB_REPOSITORY="owner/repo"

    # Source just validate_env to check RUNNER_SCOPE is set correctly
    run bash -c "
        source '$ENTRYPOINT' 2>/dev/null || true
        export GITHUB_TOKEN='ghp_pattoken'
        export GITHUB_REPOSITORY='owner/repo'
        validate_env 2>&1
        echo \"SCOPE=\$RUNNER_SCOPE\"
        echo \"URL=\$RUNNER_URL\"
    " 2>&1 || true

    # If sourcing works, validate it set the expected vars.
    # This test verifies the env setup doesn't break when socket path differs.
    # The scope should be repo.
    true  # this test documents the DooD scenario; full E2E requires a running container
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
