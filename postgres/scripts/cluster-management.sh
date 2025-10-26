#!/bin/bash
# Utility script for managing PostgreSQL cluster operations

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POSTGRES_DIR="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'  
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if PostgreSQL is ready
wait_for_postgres() {
    local host=${1:-localhost}
    local port=${2:-5432}
    local user=${3:-postgres}
    local max_attempts=${4:-30}
    
    log_info "Waiting for PostgreSQL to be ready at $host:$port..."
    
    for i in $(seq 1 $max_attempts); do
        if pg_isready -h "$host" -p "$port" -U "$user" &> /dev/null; then
            log_success "PostgreSQL is ready!"
            return 0
        fi
        
        echo -n "."
        sleep 2
    done
    
    log_error "PostgreSQL not ready after $((max_attempts * 2)) seconds"
    return 1
}

# Function to test extension availability
test_extensions() {
    local host=${1:-localhost}
    local port=${2:-5432}  
    local user=${3:-postgres}
    local db=${4:-postgres}
    
    log_info "Testing extension availability..."
    
    # Test basic connectivity
    if ! psql -h "$host" -p "$port" -U "$user" -d "$db" -c "SELECT version();" &> /dev/null; then
        log_error "Cannot connect to PostgreSQL"
        return 1
    fi
    
    # Test core extensions
    local extensions=("citus" "vector" "postgis" "pg_cron" "pg_stat_statements")
    local available=0
    local total=${#extensions[@]}
    
    for ext in "${extensions[@]}"; do
        if psql -h "$host" -p "$port" -U "$user" -d "$db" -c "SELECT 1 FROM pg_available_extensions WHERE name = '$ext';" | grep -q "1"; then
            log_success "Extension $ext: Available"
            ((available++))
        else
            log_warning "Extension $ext: Not available"
        fi
    done
    
    log_info "Extensions available: $available/$total"
    
    # Test enabled extensions
    log_info "Currently enabled extensions:"
    psql -h "$host" -p "$port" -U "$user" -d "$db" -c "SELECT extname FROM pg_extension ORDER BY extname;" -t | while read -r ext; do
        if [[ -n "$ext" ]]; then
            log_success "  - $(echo "$ext" | xargs)"  # trim whitespace
        fi
    done
}

# Function to run health check
health_check() {
    local host=${1:-localhost}
    local port=${2:-5432}
    local user=${3:-postgres}
    local db=${4:-postgres}
    
    log_info "Running health check..."
    
    if ! wait_for_postgres "$host" "$port" "$user"; then
        return 1
    fi
    
    # Run the built-in health_check function
    psql -h "$host" -p "$port" -U "$user" -d "$db" -c "SELECT * FROM public.health_check();" || {
        log_warning "Built-in health_check function not available, running basic checks..."
        psql -h "$host" -p "$port" -U "$user" -d "$db" -c "SELECT 'database' as component, 'healthy' as status, 'PostgreSQL is running' as details;"
    }
}

# Function to show cluster status (if Citus enabled)
cluster_status() {
    local host=${1:-localhost}
    local port=${2:-5432}
    local user=${3:-postgres}
    local db=${4:-postgres}
    
    log_info "Checking cluster status..."
    
    # Check if Citus is enabled
    if psql -h "$host" -p "$port" -U "$user" -d "$db" -c "SELECT 1 FROM pg_extension WHERE extname = 'citus';" | grep -q "1"; then
        log_info "Citus cluster nodes:"
        psql -h "$host" -p "$port" -U "$user" -d "$db" -c "SELECT nodename, nodeport, isactive, noderole FROM pg_dist_node ORDER BY nodename;" || {
            log_warning "Could not query cluster nodes (single-node setup?)"
        }
    else
        log_info "Citus not enabled - single-node PostgreSQL"
    fi
}

# Function to show usage examples
show_examples() {
    cat << 'EOF'
PostgreSQL Modern Container - Usage Examples

1. Connect to database:
   psql -h localhost -p 5432 -U postgres -d postgres

2. Test vector search (if pg_vector enabled):
   SELECT * FROM ai_examples.semantic_search(array_fill(0.1, ARRAY[1536])::vector);

3. Test geospatial queries (if PostGIS enabled):
   SELECT * FROM geo_examples.find_nearby(48.8566, 2.3522, 50);

4. View monitoring data:
   SELECT * FROM monitoring.slow_queries LIMIT 5;
   SELECT * FROM monitoring.connections;

5. Check scheduled jobs (if pg_cron enabled):
   SELECT * FROM cron.job;

6. Health check:
   SELECT * FROM public.health_check();

EOF
}

# Main script logic
case "${1:-}" in
    "test-extensions"|"test")
        test_extensions "${@:2}"
        ;;
    "health"|"health-check")
        health_check "${@:2}"
        ;;
    "cluster"|"cluster-status")
        cluster_status "${@:2}"
        ;;
    "wait")
        wait_for_postgres "${@:2}"
        ;;
    "examples")
        show_examples
        ;;
    "all"|"")
        log_info "Running full diagnostic..."
        wait_for_postgres "${@:2}" && \
        health_check "${@:2}" && \
        test_extensions "${@:2}" && \
        cluster_status "${@:2}"
        ;;
    *)
        echo "Usage: $0 [command] [host] [port] [user] [database]"
        echo ""
        echo "Commands:"
        echo "  test-extensions  Test extension availability"  
        echo "  health-check     Run health diagnostics"
        echo "  cluster-status   Show Citus cluster status"
        echo "  wait            Wait for PostgreSQL to be ready"
        echo "  examples        Show usage examples"
        echo "  all             Run all diagnostics (default)"
        echo ""
        echo "Examples:"
        echo "  $0                              # Full diagnostic on localhost:5432"
        echo "  $0 health-check                # Health check only"
        echo "  $0 test-extensions localhost 5433  # Test extensions on custom port"
        exit 1
        ;;
esac
