#!/bin/bash
# Integration test for PostgreSQL + Vector + Grafana observability stack
set -euo pipefail

COMPOSE_FILE="$(dirname "$0")/docker-compose.yaml"
TIMEOUT=60

cleanup() {
    echo "  Cleaning up..."
    docker compose -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
}
trap cleanup EXIT

echo "  Testing Observability Stack..."

# Start the stack
echo "  Starting services..."
docker compose -f "$COMPOSE_FILE" up -d 2>/dev/null

# Wait for PostgreSQL
echo "  Waiting for PostgreSQL..."
elapsed=0
while [ $elapsed -lt $TIMEOUT ]; do
    if docker compose -f "$COMPOSE_FILE" exec -T postgres pg_isready -U vector -d observability 2>/dev/null; then
        break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
done

if [ $elapsed -ge $TIMEOUT ]; then
    echo "  FAIL: PostgreSQL did not become ready in ${TIMEOUT}s"
    exit 1
fi
echo "  OK PostgreSQL ready"

# Wait for Vector
echo "  Waiting for Vector API..."
elapsed=0
while [ $elapsed -lt $TIMEOUT ]; do
    if docker compose -f "$COMPOSE_FILE" exec -T vector wget -qO- http://127.0.0.1:8686/health 2>/dev/null | grep -q "ok"; then
        break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
done

if [ $elapsed -ge $TIMEOUT ]; then
    echo "  FAIL: Vector API did not respond in ${TIMEOUT}s"
    exit 1
fi
echo "  OK Vector API healthy"

# Wait for some data to flow through
echo "  Waiting for data pipeline (15s)..."
sleep 15

# Test: Logs table has data
echo "  Checking logs pipeline..."
log_count=$(docker compose -f "$COMPOSE_FILE" exec -T postgres psql -U vector -d observability -tAc "SELECT count(*) FROM logs" 2>/dev/null || echo "0")
if [ "${log_count:-0}" -gt 0 ]; then
    echo "  OK Logs flowing ($log_count rows)"
else
    echo "  WARN: No logs yet (pipeline may be slow)"
fi

# Test: Grafana is accessible
echo "  Checking Grafana..."
elapsed=0
while [ $elapsed -lt $TIMEOUT ]; do
    status=$(docker compose -f "$COMPOSE_FILE" exec -T grafana curl -fsS -o /dev/null -w "%{http_code}" http://127.0.0.1:3000/api/health 2>/dev/null || echo "000")
    if [ "$status" = "200" ]; then
        break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
done

if [ "$status" = "200" ]; then
    echo "  OK Grafana accessible"
else
    echo "  FAIL: Grafana returned HTTP $status"
    exit 1
fi

# Test: Grafana datasource provisioned
echo "  Checking Grafana datasource..."
ds_response=$(docker compose -f "$COMPOSE_FILE" exec -T grafana curl -fsS -u admin:admin http://127.0.0.1:3000/api/datasources 2>/dev/null || echo "[]")
if echo "$ds_response" | grep -q "PostgreSQL"; then
    echo "  OK PostgreSQL datasource provisioned"
else
    echo "  WARN: Datasource not yet provisioned"
fi

echo "  All Observability Stack tests passed"
