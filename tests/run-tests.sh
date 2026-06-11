#!/usr/bin/env bash

# Test runner for docker-containers build scripts
# Uses bats-core for unit testing

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Use shared logging utilities
source "$PROJECT_ROOT/helpers/logging.sh"

# Check for bats
check_bats() {
    if command -v bats &>/dev/null; then
        log_success "bats found: $(bats --version)"
        return 0
    fi

    # Check for local bats installation
    if [[ -x "$SCRIPT_DIR/bats/bin/bats" ]]; then
        export PATH="$SCRIPT_DIR/bats/bin:$PATH"
        log_success "Using local bats installation"
        return 0
    fi

    log_warning "bats not found. Installing locally..."
    install_bats
}

# Install bats-core locally
install_bats() {
    log_info "Installing bats-core..."

    cd "$SCRIPT_DIR"

    # Clone bats-core
    if [[ ! -d "bats" ]]; then
        git clone --depth 1 https://github.com/bats-core/bats-core.git bats 2>/dev/null || {
            log_error "Failed to clone bats-core"
            log_info "Install manually: sudo apt install bats"
            exit 1
        }
    fi

    # Clone bats-support and bats-assert for better assertions
    if [[ ! -d "test_helper/bats-support" ]]; then
        mkdir -p test_helper
        git clone --depth 1 https://github.com/bats-core/bats-support.git test_helper/bats-support 2>/dev/null || true
    fi

    if [[ ! -d "test_helper/bats-assert" ]]; then
        git clone --depth 1 https://github.com/bats-core/bats-assert.git test_helper/bats-assert 2>/dev/null || true
    fi

    export PATH="$SCRIPT_DIR/bats/bin:$PATH"
    log_success "bats installed locally"
}

# Run a single bats invocation with retry-on-flake protection.
#
# A "flake" is defined as: exit code != 0 AND zero "^not ok" lines in the
# captured output.  That matches the known bats-core-under-load crashes:
#   - "Executed N instead of expected M tests"
#   - "printf: not a valid identifier"
#   - Python/generator segfault (status 139)
# All of these produce no assertion failures — they abort before any test
# completes.  A run with >=1 "not ok" line is a GENUINE failure and is
# surfaced immediately without retrying.
#
# Usage: _bats_with_retry <bats_args...>
_bats_with_retry() {
    local max_retries=2
    local retry_delay=3
    local attempt=0
    local bats_rc
    local not_ok_count
    local out_file
    out_file="$(mktemp /tmp/bats-run-XXXXXX.tap)"

    while true; do
        attempt=$(( attempt + 1 ))

        # Run bats, capturing both stdout and stderr; stream to terminal too.
        bats "$@" 2>&1 | tee "$out_file"; bats_rc=${PIPESTATUS[0]}

        if [[ $bats_rc -eq 0 ]]; then
            rm -f "$out_file"
            return 0
        fi

        # Count genuine assertion failures in the captured output.
        not_ok_count=$(grep -c '^not ok' "$out_file" 2>/dev/null || true)

        if [[ "$not_ok_count" -gt 0 ]]; then
            # Real failures present — do NOT retry, propagate immediately.
            rm -f "$out_file"
            return "$bats_rc"
        fi

        # Zero "not ok" lines + non-zero exit → flake signature.
        if [[ $attempt -le $max_retries ]]; then
            log_warning "bats exited $bats_rc with 0 assertion failures (suspected flake). Retry $attempt/$max_retries in ${retry_delay}s..."
            sleep "$retry_delay"
        else
            log_error "bats flake persisted after $max_retries retries (exit $bats_rc, 0 not-ok lines). Suspected-flake exhaustion — treating as failure."
            rm -f "$out_file"
            return "$bats_rc"
        fi
    done
}

# Run tests
run_tests() {
    local test_pattern="${1:-}"

    cd "$PROJECT_ROOT"

    echo ""
    echo "🧪 Running Build Script Unit Tests"
    echo "==================================="
    echo ""

    if [[ -n "$test_pattern" ]]; then
        log_info "Running tests matching: $test_pattern"
        _bats_with_retry --tap --jobs 4 "$SCRIPT_DIR/unit/"*"$test_pattern"*.bats
    else
        log_info "Running all unit tests..."
        _bats_with_retry --tap --jobs 4 "$SCRIPT_DIR/unit/"*.bats
    fi
}

# Show usage
show_usage() {
    echo "Usage: $0 [OPTIONS] [TEST_PATTERN]"
    echo ""
    echo "Options:"
    echo "  -h, --help     Show this help message"
    echo "  -v, --verbose  Run with verbose output"
    echo "  -i, --install  Install bats dependencies only"
    echo ""
    echo "Examples:"
    echo "  $0              Run all tests"
    echo "  $0 logging      Run tests matching 'logging'"
    echo "  $0 build        Run tests matching 'build'"
    echo "  $0 -i           Install bats only"
}

# Main
main() {
    local verbose=false
    local install_only=false
    local test_pattern=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_usage
                exit 0
                ;;
            -v|--verbose)
                verbose=true
                shift
                ;;
            -i|--install)
                install_only=true
                shift
                ;;
            *)
                test_pattern="$1"
                shift
                ;;
        esac
    done

    check_bats

    if [[ "$install_only" == "true" ]]; then
        log_success "bats installation complete"
        exit 0
    fi

    if [[ "$verbose" == "true" ]]; then
        run_tests "$test_pattern" 2>&1
    else
        run_tests "$test_pattern"
    fi
}

main "$@"
