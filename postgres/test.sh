#!/bin/bash
# E2E test for postgres container

set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-e2e-postgres}"

echo "  Testing PostgreSQL connectivity..."

# Wait for postgres to accept connections
for i in {1..30}; do
    if docker exec "$CONTAINER_NAME" pg_isready -U test -d test &>/dev/null; then
        break
    fi
    sleep 1
done

# Test basic query
echo "  Running test query..."
result=$(docker exec "$CONTAINER_NAME" psql -U test -d test -t -c "SELECT 1 + 1 AS result;" 2>/dev/null | tr -d ' ')

if [ "$result" != "2" ]; then
    echo "  ❌ Query test failed: expected '2', got '$result'"
    exit 1
fi

echo "  ✅ PostgreSQL query test passed"

# Test extension availability (if any are installed)
echo "  Checking installed extensions..."
docker exec "$CONTAINER_NAME" psql -U test -d test -c "SELECT extname FROM pg_extension;" 2>/dev/null

echo "  ✅ All PostgreSQL tests passed"
