#!/usr/bin/env bash

# Shared retry utilities for docker-containers repository
# Provides generic retry functions with backoff strategies

# Source logging if not already loaded
if ! declare -F log_error &>/dev/null; then
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logging.sh"
fi

# Retry a command with exponential backoff
# Usage: retry_with_backoff <max_attempts> <initial_delay> <command...>
# Example: retry_with_backoff 3 2 docker push myimage:latest
retry_with_backoff() {
    local max_attempts=$1
    local delay=$2
    shift 2
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        if "$@"; then
            return 0
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            log_warning "Attempt $attempt/$max_attempts failed, retrying in ${delay}s..."
            sleep "$delay"
            delay=$((delay * 2))  # Exponential backoff
        fi
        ((attempt++))
    done

    log_error "All $max_attempts attempts failed"
    return 1
}

# Retry a command with fixed delay
# Usage: retry_with_delay <max_attempts> <delay> <command...>
retry_with_delay() {
    local max_attempts=$1
    local delay=$2
    shift 2
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        if "$@"; then
            return 0
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            log_warning "Attempt $attempt/$max_attempts failed, retrying in ${delay}s..."
            sleep "$delay"
        fi
        ((attempt++))
    done

    log_error "All $max_attempts attempts failed"
    return 1
}
