#!/usr/bin/env bash
# github-runner/entrypoint.sh
# Linux entrypoint for the self-hosted GitHub Actions runner container.
# Handles: root check, volume permissions, auth (PAT or GitHub App),
# runner registration (with retry), signal handling, and launch.
set -euo pipefail

# ---------------------------------------------------------------------------
# Logging helpers (stderr only — stdout must remain clean for callers)
# ---------------------------------------------------------------------------
log_info()    { echo "[INFO]  $*" >&2; }
log_warn()    { echo "[WARN]  $*" >&2; }
log_error()   { echo "[ERROR] $*" >&2; }

# ---------------------------------------------------------------------------
# 1. Root check
# ---------------------------------------------------------------------------
check_not_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    if [[ "${ALLOW_ROOT:-false}" != "true" ]]; then
      log_error "Running as root is not supported."
      log_error "Set ALLOW_ROOT=true to override (security risk — only for testing)."
      exit 1
    fi
    log_warn "Running as root. ALLOW_ROOT=true is set. This is a security risk."
  fi
}

# ---------------------------------------------------------------------------
# 2. Disable runner auto-update (prevents crash loop in containers)
# ---------------------------------------------------------------------------
export RUNNER_DISABLE_AUTO_UPDATE=1

# ---------------------------------------------------------------------------
# 3. Volume permission fix
# ---------------------------------------------------------------------------
fix_volume_permissions() {
  local current_uid
  current_uid="$(id -u)"

  local cache_dirs=(
    "${RUNNER_TOOL_CACHE:-${HOME}/.cache}"
    "${HOME}/.cargo"
    "${HOME}/.npm"
    "${HOME}/.nuget"
    "${HOME}/.pnpm-store"
  )

  for dir in "${cache_dirs[@]}"; do
    if [[ -e "$dir" ]] && [[ ! -w "$dir" ]]; then
      log_warn "Cache directory not writable: $dir — attempting permission fix"
      if mkdir -p "$dir" 2>/dev/null && chown "${current_uid}" "$dir" 2>/dev/null; then
        log_info "Fixed permissions on: $dir"
      else
        log_warn "Could not fix permissions on $dir (owner: $(stat -c '%U' "$dir" 2>/dev/null || echo 'unknown')). Runner will still work but this cache will be unavailable."
      fi
    elif [[ ! -e "$dir" ]]; then
      # Pre-create the directory so Docker volumes are accessible
      mkdir -p "$dir" 2>/dev/null || true
    fi
  done
}

# ---------------------------------------------------------------------------
# 4. Environment validation
# ---------------------------------------------------------------------------
validate_env() {
  # Determine scope (repo or org)
  if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
    RUNNER_SCOPE="repo"
    RUNNER_URL="https://github.com/${GITHUB_REPOSITORY}"
    local owner_repo="${GITHUB_REPOSITORY}"
    REG_TOKEN_API="${GITHUB_API_URL:-https://api.github.com}/repos/${owner_repo}/actions/runners/registration-token"
    REMOVAL_TOKEN_API="${GITHUB_API_URL:-https://api.github.com}/repos/${owner_repo}/actions/runners/remove-token"
    INSTALLATION_API="${GITHUB_API_URL:-https://api.github.com}/repos/${owner_repo}/installation"
  elif [[ -n "${GITHUB_ORG:-}" ]]; then
    RUNNER_SCOPE="org"
    RUNNER_URL="https://github.com/${GITHUB_ORG}"
    REG_TOKEN_API="${GITHUB_API_URL:-https://api.github.com}/orgs/${GITHUB_ORG}/actions/runners/registration-token"
    REMOVAL_TOKEN_API="${GITHUB_API_URL:-https://api.github.com}/orgs/${GITHUB_ORG}/actions/runners/remove-token"
    INSTALLATION_API="${GITHUB_API_URL:-https://api.github.com}/orgs/${GITHUB_ORG}/installation"
  else
    log_error "Must set GITHUB_REPOSITORY (owner/repo) or GITHUB_ORG (myorg)."
    exit 1
  fi
  export RUNNER_SCOPE RUNNER_URL REG_TOKEN_API REMOVAL_TOKEN_API INSTALLATION_API

  # Determine auth mode
  if [[ -n "${RUNNER_TOKEN:-}" ]]; then
    AUTH_MODE="token"
  elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
    AUTH_MODE="pat"
  elif [[ -n "${APP_ID:-}" ]] && { [[ -n "${APP_PRIVATE_KEY:-}" ]] || [[ -n "${APP_PRIVATE_KEY_FILE:-}" ]]; }; then
    AUTH_MODE="app"
  else
    log_error "Authentication not configured. Provide one of:"
    log_error "  Token mode:    RUNNER_TOKEN=<registration-token-from-github-ui>"
    log_error "  PAT mode:      GITHUB_TOKEN=<pat-with-repo-or-admin:org-scope>"
    log_error "  App mode:      APP_ID=<id> APP_PRIVATE_KEY=<pem> (or APP_PRIVATE_KEY_FILE=<path>)"
    exit 1
  fi
  export AUTH_MODE
}

# ---------------------------------------------------------------------------
# 5. JWT generation (pure bash + openssl, no external deps)
# ---------------------------------------------------------------------------
# Usage: generate_jwt <app_id> <path-to-pem-key-file>
# Outputs: <header>.<payload>.<sig>  (RS256 JWT)
generate_jwt() {
  local app_id="$1"
  local key_file="$2"
  local header payload sig

  header=$(printf '{"alg":"RS256","typ":"JWT"}' \
    | openssl base64 -A | tr '+/' '-_' | tr -d '=')

  local now
  now=$(date +%s)
  payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' \
    "$((now - 60))" "$((now + 540))" "$app_id" \
    | openssl base64 -A | tr '+/' '-_' | tr -d '=')

  sig=$(printf '%s.%s' "$header" "$payload" \
    | openssl dgst -sha256 -sign "$key_file" \
    | openssl base64 -A | tr '+/' '-_' | tr -d '=')

  printf '%s.%s.%s' "$header" "$payload" "$sig"
}

# ---------------------------------------------------------------------------
# 6. Get GitHub App installation access token
# ---------------------------------------------------------------------------
get_app_access_token() {
  local jwt="$1"

  # Get installation ID
  local install_response install_id
  install_response=$(curl -sf \
    -H "Authorization: Bearer ${jwt}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${INSTALLATION_API}")
  install_id=$(printf '%s' "$install_response" | jq -r '.id')

  if [[ -z "$install_id" || "$install_id" == "null" ]]; then
    log_error "Could not retrieve installation ID for this repository/org."
    log_error "Ensure the GitHub App is installed on the target repository or organisation."
    return 1
  fi

  # Exchange installation ID for access token
  local token_response access_token
  token_response=$(curl -sf -X POST \
    -H "Authorization: Bearer ${jwt}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${GITHUB_API_URL:-https://api.github.com}/app/installations/${install_id}/access_tokens")
  access_token=$(printf '%s' "$token_response" | jq -r '.token')

  if [[ -z "$access_token" || "$access_token" == "null" ]]; then
    log_error "Could not obtain installation access token."
    return 1
  fi

  printf '%s' "$access_token"
}

# ---------------------------------------------------------------------------
# 7. Get registration token (with exponential backoff retry)
# ---------------------------------------------------------------------------
# Usage: get_registration_token <bearer-token>
# Outputs: registration token string
get_registration_token() {
  local bearer_token="$1"
  local attempt=1
  local delay=2
  local max_attempts=5

  while (( attempt <= max_attempts )); do
    local http_body http_status response_file headers_file
    response_file=$(mktemp)
    headers_file=$(mktemp)

    # F-002: dump headers to a dedicated file so -w '%{http_code}' returns only
    # the numeric status code.  Previously -D - mixed headers into stdout,
    # causing $http_status to contain the full header block and the "201"
    # comparison to never match.
    http_status=$(curl -s -X POST \
      -H "Authorization: token ${bearer_token}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -D "${headers_file}" \
      -o "${response_file}" \
      -w '%{http_code}' \
      "${REG_TOKEN_API}" 2>/dev/null) || true

    http_body=$(cat "${response_file}")
    rm -f "${response_file}"

    if [[ "$http_status" == "201" ]]; then
      local token
      token=$(printf '%s' "$http_body" | jq -r '.token')
      rm -f "${headers_file}"
      if [[ -n "$token" && "$token" != "null" ]]; then
        printf '%s' "$token"
        return 0
      fi
      log_warn "Attempt ${attempt}/${max_attempts}: received 201 but token field is empty."
    elif [[ "$http_status" == "429" ]]; then
      # F-003: read Retry-After from the headers file, not the response body.
      # The header is part of the HTTP response headers, not the JSON body.
      local retry_after
      retry_after=$(grep -i '^Retry-After:' "${headers_file}" | awk '{print $2}' | tr -d '\r' || true)
      rm -f "${headers_file}"
      if [[ -n "$retry_after" ]] && [[ "$retry_after" =~ ^[0-9]+$ ]]; then
        log_warn "Attempt ${attempt}/${max_attempts}: rate limited (HTTP 429). Sleeping ${retry_after}s (Retry-After header)."
        sleep "$retry_after"
        (( attempt++ ))
        continue
      fi
      log_warn "Attempt ${attempt}/${max_attempts}: rate limited (HTTP 429, no Retry-After). Retrying in ${delay}s."
    else
      rm -f "${headers_file}"
      log_warn "Attempt ${attempt}/${max_attempts}: HTTP ${http_status:-unknown}. Retrying in ${delay}s."
    fi

    if (( attempt < max_attempts )); then
      sleep "$delay"
      (( delay *= 2 ))
    fi
    (( attempt++ ))
  done

  log_error "Failed to obtain registration token after ${max_attempts} attempts."
  exit 1
}

# ---------------------------------------------------------------------------
# 8. Obtain bearer token (PAT or App)
# ---------------------------------------------------------------------------
resolve_bearer_token() {
  if [[ "$AUTH_MODE" == "pat" ]]; then
    printf '%s' "${GITHUB_TOKEN}"
    return 0
  fi

  # App mode: resolve private key to a temp file
  local key_file=""
  local key_file_is_temp=false

  if [[ -n "${APP_PRIVATE_KEY_FILE:-}" ]]; then
    key_file="${APP_PRIVATE_KEY_FILE}"
  else
    # APP_PRIVATE_KEY may contain literal \n sequences — convert to real newlines
    key_file=$(mktemp)
    key_file_is_temp=true
    printf '%s' "${APP_PRIVATE_KEY}" | sed 's/\\n/\n/g' > "$key_file"
    chmod 600 "$key_file"
  fi

  local jwt access_token
  jwt=$(generate_jwt "${APP_ID}" "$key_file")

  # Remove temp key immediately after JWT is signed
  if [[ "$key_file_is_temp" == "true" ]]; then
    rm -f "$key_file"
  fi

  access_token=$(get_app_access_token "$jwt")
  printf '%s' "$access_token"
}

# ---------------------------------------------------------------------------
# 9. Configure runner
# ---------------------------------------------------------------------------
configure_runner() {
  local reg_token="$1"

  RUNNER_NAME="${RUNNER_NAME_PREFIX:-runner}-$(hostname -s)-$(date +%s)"
  local labels="${RUNNER_LABELS:-self-hosted,linux,$(uname -m)}"
  local group="${RUNNER_GROUP:-Default}"

  log_info "Configuring runner: name=${RUNNER_NAME}, url=${RUNNER_URL}, labels=${labels}, group=${group}"

  # --replace is intentional: if the container restarted mid-registration the
  # previous runner record would block re-registration.  Ephemeral runners are
  # single-use, so replacing a stale record is always safe here.
  local config_exit=0
  ./config.sh \
    --url "$RUNNER_URL" \
    --token "$reg_token" \
    --name "$RUNNER_NAME" \
    --labels "$labels" \
    --runnergroup "$group" \
    --ephemeral \
    --unattended \
    --replace || config_exit=$?

  if [[ $config_exit -ne 0 ]]; then
    log_error "config.sh exited with code ${config_exit}. Runner registration failed."
    exit "$config_exit"
  fi

  export RUNNER_NAME
}

# ---------------------------------------------------------------------------
# 10. Cleanup / deregistration (signal handler)
# ---------------------------------------------------------------------------
# shellcheck disable=SC2329  # invoked via trap, not direct call
cleanup() {
  log_info "Received shutdown signal — deregistering runner."
  local removal_token=""

  # Obtain a fresh removal token; ignore errors (best-effort deregistration)
  # RUNNER_TOKEN mode has no bearer token — skip the API removal-token fetch
  local bearer_token=""
  if [[ "${AUTH_MODE:-}" != "token" ]]; then
    bearer_token=$(resolve_bearer_token 2>/dev/null) || true
  fi
  if [[ -n "$bearer_token" ]]; then
    # Swap REG_TOKEN_API for REMOVAL_TOKEN_API temporarily
    local saved_api="$REG_TOKEN_API"
    REG_TOKEN_API="$REMOVAL_TOKEN_API"
    removal_token=$(get_registration_token "$bearer_token" 2>/dev/null) || true
    REG_TOKEN_API="$saved_api"
  fi

  if [[ -n "$removal_token" ]]; then
    ./config.sh remove --token "$removal_token" 2>/dev/null || true
    log_info "Runner deregistered."
  else
    log_warn "Could not obtain removal token — runner will be listed as offline until GitHub cleans it up (14 days)."
  fi
}

trap cleanup SIGTERM SIGINT

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  log_info "GitHub Actions runner entrypoint starting."

  # Step 1: Root check
  check_not_root

  # Step 2: RUNNER_DISABLE_AUTO_UPDATE already exported above

  # Step 3: Fix volume permissions
  fix_volume_permissions

  # Step 4: Validate environment and determine scope/auth mode
  validate_env

  log_info "Auth mode: ${AUTH_MODE}, Scope: ${RUNNER_SCOPE}, URL: ${RUNNER_URL}"

  # Steps 5-8: Obtain registration token
  # RUNNER_TOKEN path: the env var IS the registration token — skip API call entirely
  local reg_token
  if [[ "$AUTH_MODE" == "token" ]]; then
    log_info "Using direct registration token (RUNNER_TOKEN) — skipping API auth."
    reg_token="$RUNNER_TOKEN"
  else
    local bearer_token
    bearer_token=$(resolve_bearer_token)
    reg_token=$(get_registration_token "$bearer_token")
  fi

  # Step 9: Configure runner (registers with GitHub)
  configure_runner "$reg_token"

  # Step 10: Launch the runner agent
  log_info "Starting runner agent (ephemeral — will exit after one job)."
  ./run.sh &
  local runner_pid=$!

  # Wait for the runner agent; signal handler fires on SIGTERM/SIGINT
  wait "$runner_pid"
  local run_exit=$?

  log_info "Runner agent exited with code ${run_exit}."
  exit "$run_exit"
}

main "$@"
