#!/bin/bash

# E2E Container Tests
# Builds and validates all containers using existing build system + custom tests
#
# Usage:
#   ./e2e-test.sh                          # Test all containers (non-variant only)
#   ./e2e-test.sh postgres:16              # Test all variants for postgres v16
#   ./e2e-test.sh postgres:16-full-alpine  # Test specific variant
#   ./e2e-test.sh --no-build               # Skip build, use existing images
#
# For containers with variants, version is required (e.g., postgres:16)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers/logging.sh"
source "$SCRIPT_DIR/helpers/variant-utils.sh"

BUILD=true
CONTAINERS=""
FAILED=()
PASSED=()
GITHUB_REPOSITORY_OWNER="${GITHUB_REPOSITORY_OWNER:-oorabona}"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-build)
            BUILD=false
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS] [CONTAINER...]"
            echo ""
            echo "Options:"
            echo "  --no-build    Skip building images"
            echo "  -h, --help    Show this help"
            echo ""
            echo "Examples:"
            echo "  $0                    # Test all containers"
            echo "  $0 postgres openresty # Test specific containers"
            echo "  $0 --no-build         # Test with existing images"
            exit 0
            ;;
        *)
            CONTAINERS="$CONTAINERS $1"
            shift
            ;;
    esac
done

# Get list of containers to test
if [ -z "$CONTAINERS" ]; then
    CONTAINERS=$(./make list 2>/dev/null)
fi

echo ""
echo "🧪 E2E Container Tests"
echo "======================"
echo ""

# Test a single container (or variant)
# Usage: test_container <container> [image_tag]
test_container() {
    local container="$1"
    local image_tag="${2:-}"
    local container_name="e2e-$container"
    local test_script="$SCRIPT_DIR/$container/test.sh"

    # Build test name for display
    local test_name="$container"
    [[ -n "$image_tag" ]] && test_name="$container:$image_tag"

    log_step "Testing $test_name..."

    # Build if requested (only for non-variant tests or when no tag specified)
    if [ "$BUILD" = true ] && [ -z "$image_tag" ]; then
        log_info "Building $container..."
        if ! ./make build "$container" 2>&1 | tail -5; then
            log_error "Build failed for $container"
            return 1
        fi
    fi

    # Determine image name
    local image
    if [ -n "$image_tag" ]; then
        # Use specific tag provided
        image="docker.io/$GITHUB_REPOSITORY_OWNER/$container:$image_tag"
    else
        # Find the most recently built image for this container
        image=$(docker images --format '{{.Repository}}:{{.Tag}}' --filter "reference=*/$container:*" | head -1) || true
        if [ -z "$image" ]; then
            # Fallback: try local name
            image=$(docker images --format '{{.Repository}}:{{.Tag}}' --filter "reference=$container:*" | head -1) || true
        fi
    fi
    if [ -z "$image" ]; then
        log_error "No image found for $test_name"
        return 1
    fi
    log_info "Using image: $image"

    # Clean up any existing test container
    docker rm -f "$container_name" 2>/dev/null || true

    # Start container with appropriate options
    log_info "Starting $container..."
    local run_opts="--rm -d --name $container_name"

    # Container-specific run options and command
    local run_cmd=""
    case "$container" in
        postgres)
            run_opts="$run_opts -e POSTGRES_PASSWORD=test -e POSTGRES_USER=test -e POSTGRES_DB=test"
            ;;
        openvpn)
            run_opts="$run_opts --cap-add NET_ADMIN --device /dev/net/tun:/dev/net/tun"
            ;;
        ansible|debian)
            # These need a command to stay running
            run_cmd="sleep infinity"
            ;;
        sslh)
            # SSLH needs explicit config to start - use test mode
            run_cmd="sslh-ev --foreground -p 0.0.0.0:8443 --ssh 127.0.0.1:22 --tls 127.0.0.1:443"
            ;;
    esac

    if ! docker run $run_opts "$image" $run_cmd; then
        log_error "Failed to start $container"
        return 1
    fi

    # Wait for container to be ready (healthcheck or basic startup)
    log_info "Waiting for $container to be ready..."
    local max_wait=60
    local waited=0
    local ready=false

    while [ $waited -lt $max_wait ]; do
        # Check if container is still running
        if ! docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
            log_error "$container exited unexpectedly"
            docker logs "$container_name" 2>&1 | tail -20
            return 1
        fi

        # Check health status if available
        local health
        health=$(docker inspect --format='{{.State.Health.Status}}' "$container_name" 2>/dev/null) || health="none"

        case "$health" in
            healthy)
                ready=true
                break
                ;;
            unhealthy)
                log_error "$container is unhealthy"
                docker logs "$container_name" 2>&1 | tail -20
                docker rm -f "$container_name" 2>/dev/null || true
                return 1
                ;;
            starting)
                ;;
            none)
                # No healthcheck, give processes time to initialize
                sleep 3
                ready=true
                break
                ;;
        esac

        sleep 2
        waited=$((waited + 2))
        printf "\r    ⏳ Waiting... (%ds)" "$waited"
    done
    echo ""

    if [ "$ready" != true ]; then
        log_error "$container did not become ready in time"
        docker logs "$container_name" 2>&1 | tail -20
        docker rm -f "$container_name" 2>/dev/null || true
        return 1
    fi

    # Run custom test script if exists
    if [ -x "$test_script" ]; then
        log_info "Running custom tests for $container..."
        if ! CONTAINER_NAME="$container_name" "$test_script"; then
            log_error "Custom tests failed for $container"
            docker rm -f "$container_name" 2>/dev/null || true
            return 1
        fi
    fi

    # Cleanup
    docker rm -f "$container_name" 2>/dev/null || true

    log_success "$container passed ✅"
    return 0
}

# Run tests
for arg in $CONTAINERS; do
    # Check if argument contains a tag (container:tag format)
    if [[ "$arg" == *":"* ]]; then
        container="${arg%%:*}"
        tag_part="${arg#*:}"
        container_dir="$SCRIPT_DIR/$container"

        # Determine if tag_part is a version (e.g., "16") or a full tag (e.g., "16-full-alpine")
        if [[ "$tag_part" =~ ^[0-9]+$ ]]; then
            # It's a version number - test all variants for this version
            local_version="$tag_part"

            if has_variants "$container_dir"; then
                log_info "$container:$local_version - testing all variants..."

                # Build all variants if requested
                if [ "$BUILD" = true ]; then
                    log_info "Building all variants for $container v$local_version..."
                    if ! ./make build "$container" "$local_version" 2>&1 | tail -10; then
                        log_error "Build failed for $container v$local_version"
                        FAILED+=("$container:$local_version")
                        continue
                    fi
                fi

                # Test each variant
                while IFS= read -r variant_name; do
                    [[ -z "$variant_name" ]] && continue

                    variant_tag=$(variant_image_tag "$local_version" "$variant_name" "$container_dir")
                    echo ""

                    if test_container "$container" "$variant_tag"; then
                        PASSED+=("$container:$variant_tag")
                    else
                        FAILED+=("$container:$variant_tag")
                    fi
                done < <(list_variants "$container_dir" "$local_version")
            else
                # No variants - test single image with this version
                echo ""
                if test_container "$container" "$local_version"; then
                    PASSED+=("$container:$local_version")
                else
                    FAILED+=("$container:$local_version")
                fi
            fi
        else
            # It's a full tag - test specific variant
            echo ""
            log_info "Testing specific variant: $container:$tag_part"

            if test_container "$container" "$tag_part"; then
                PASSED+=("$container:$tag_part")
            else
                FAILED+=("$container:$tag_part")
            fi
        fi
    else
        container="$arg"
        container_dir="$SCRIPT_DIR/$container"

        # Check if container has variants
        if has_variants "$container_dir"; then
            log_error "$container has variants - please specify version (e.g., $container:16)"
            FAILED+=("$container")
            continue
        else
            # No variants - test single image
            echo ""
            if test_container "$container"; then
                PASSED+=("$container")
            else
                FAILED+=("$container")
            fi
        fi
    fi
done

# Summary
echo ""
echo "========================================"
echo "E2E Test Summary"
echo "========================================"
echo ""

if [ ${#PASSED[@]} -gt 0 ]; then
    log_success "Passed (${#PASSED[@]}): ${PASSED[*]}"
fi

if [ ${#FAILED[@]} -gt 0 ]; then
    log_error "Failed (${#FAILED[@]}): ${FAILED[*]}"
    echo ""
    exit 1
fi

log_success "All ${#PASSED[@]} containers passed! 🎉"
exit 0
