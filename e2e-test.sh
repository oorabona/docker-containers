#!/bin/bash

# E2E Container Tests
# Builds and validates all containers pass their health checks
#
# Usage:
#   ./e2e-test.sh              # Test all containers
#   ./e2e-test.sh postgres     # Test specific container
#   ./e2e-test.sh --no-build   # Skip build, use existing images

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers/logging.sh"

COMPOSE_FILE="$SCRIPT_DIR/docker-compose.e2e.yaml"
TIMEOUT=300  # 5 minutes max wait for health checks
BUILD=true
CONTAINERS=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-build)
            BUILD=false
            shift
            ;;
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS] [CONTAINER...]"
            echo ""
            echo "Options:"
            echo "  --no-build    Skip building images"
            echo "  --timeout N   Health check timeout in seconds (default: 300)"
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

# Cleanup function
cleanup() {
    log_info "Cleaning up containers..."
    docker compose -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
}

# Set up trap for cleanup
trap cleanup EXIT

echo ""
echo "🧪 E2E Container Tests"
echo "======================"
echo ""

# Check docker compose
if ! docker compose version &>/dev/null; then
    log_error "docker compose not found"
    exit 1
fi

# Build images if requested
if [ "$BUILD" = true ]; then
    log_step "Building container images..."
    if [ -n "$CONTAINERS" ]; then
        docker compose -f "$COMPOSE_FILE" build $CONTAINERS
    else
        docker compose -f "$COMPOSE_FILE" build
    fi
    log_success "Build completed"
fi

# Start containers
log_step "Starting containers..."
if [ -n "$CONTAINERS" ]; then
    docker compose -f "$COMPOSE_FILE" up -d $CONTAINERS
else
    docker compose -f "$COMPOSE_FILE" up -d
fi

# Wait for health checks
log_step "Waiting for health checks (timeout: ${TIMEOUT}s)..."

START_TIME=$(date +%s)
ALL_HEALTHY=false

while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))

    if [ $ELAPSED -ge $TIMEOUT ]; then
        log_error "Timeout waiting for health checks"
        break
    fi

    # Get container health status
    UNHEALTHY=0
    HEALTHY=0
    STARTING=0

    while IFS= read -r line; do
        NAME=$(echo "$line" | awk '{print $1}')
        HEALTH=$(echo "$line" | awk '{print $2}')

        case "$HEALTH" in
            healthy)
                HEALTHY=$((HEALTHY + 1))
                ;;
            unhealthy)
                UNHEALTHY=$((UNHEALTHY + 1))
                log_error "$NAME is unhealthy"
                ;;
            starting|"")
                STARTING=$((STARTING + 1))
                ;;
        esac
    done < <(docker compose -f "$COMPOSE_FILE" ps --format '{{.Name}} {{.Health}}' 2>/dev/null | grep -v "^$")

    TOTAL=$((HEALTHY + UNHEALTHY + STARTING))

    # Progress update
    printf "\r  ⏳ Progress: %d/%d healthy, %d starting, %d unhealthy (%ds elapsed)" \
        "$HEALTHY" "$TOTAL" "$STARTING" "$UNHEALTHY" "$ELAPSED"

    # Check if done
    if [ $UNHEALTHY -gt 0 ]; then
        echo ""
        log_error "Some containers are unhealthy"
        break
    fi

    if [ $STARTING -eq 0 ] && [ $HEALTHY -gt 0 ]; then
        echo ""
        ALL_HEALTHY=true
        break
    fi

    sleep 5
done

echo ""

# Show final status
log_step "Final container status:"
docker compose -f "$COMPOSE_FILE" ps

echo ""

# Report results
if [ "$ALL_HEALTHY" = true ]; then
    log_success "All containers passed health checks! ✅"
    echo ""

    # Show health check details
    log_info "Health check details:"
    docker compose -f "$COMPOSE_FILE" ps --format '{{.Name}}: {{.Health}} ({{.Status}})' | while read line; do
        echo "  $line"
    done

    exit 0
else
    log_error "E2E tests failed ❌"
    echo ""

    # Show logs for unhealthy containers
    log_info "Logs from unhealthy containers:"
    docker compose -f "$COMPOSE_FILE" ps --format '{{.Name}} {{.Health}}' | grep -v healthy | awk '{print $1}' | while read container; do
        echo ""
        echo "=== $container ==="
        docker logs "$container" 2>&1 | tail -20
    done

    exit 1
fi
