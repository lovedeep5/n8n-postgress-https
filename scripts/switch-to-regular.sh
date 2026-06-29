#!/bin/bash
# Switch n8n from queue (PostgreSQL + Redis) mode back to regular (SQLite) mode
# Usage: switch-to-regular.sh
# Output on success: SWITCH_TO_REGULAR_OK

set -e

COMPOSE_DIR="/opt/n8n"
ENV_FILE="$COMPOSE_DIR/.env"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
COMPOSE_QUEUE_FILE="$COMPOSE_DIR/docker-compose.queue.yml"
VOLUME_NAME="n8n_n8n_data"

# Source current env
set -a
source "$ENV_FILE"
set +a

echo "switch-to-regular: Dumping PostgreSQL data..."
PG_DUMP="/tmp/n8n_pg_dump.sql"
if docker compose -f "$COMPOSE_QUEUE_FILE" ps postgres --format '{{.Status}}' 2>/dev/null | grep -q Up; then
  docker compose -f "$COMPOSE_QUEUE_FILE" exec -T postgres pg_dump -U n8n -d n8n > "$PG_DUMP"
  echo "switch-to-regular: PostgreSQL dump complete ($(wc -l < "$PG_DUMP") lines)"
fi

echo "switch-to-regular: Stopping all services..."
docker compose -f "$COMPOSE_QUEUE_FILE" down

echo "switch-to-regular: Removing queue env vars from .env..."
sed -i '/^QUEUE_MODE=/d' "$ENV_FILE"
sed -i '/^POSTGRES_PASSWORD=/d' "$ENV_FILE"
sed -i '/^REDIS_PASSWORD=/d' "$ENV_FILE"
sed -i '/^N8N_WORKERS=/d' "$ENV_FILE"

echo "switch-to-regular: Starting n8n in regular mode..."
docker compose -f "$COMPOSE_FILE" up -d n8n

echo "switch-to-regular: Waiting for n8n health check..."
for i in $(seq 1 30); do
  if docker compose -f "$COMPOSE_FILE" exec -T n8n wget --spider -q http://localhost:5678/healthz 2>/dev/null; then
    echo "switch-to-regular: n8n is healthy"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "switch-to-regular: WARNING - n8n health check timed out, continuing..."
  fi
  sleep 2
done

# Import PostgreSQL data into SQLite
if [ -f "$PG_DUMP" ]; then
  echo "switch-to-regular: Importing data into SQLite..."
  VOLUME_DATA="/var/lib/docker/volumes/${VOLUME_NAME}/_data"
  # n8n creates SQLite schema on startup; we append the data
  # Convert pg dump to SQLite-compatible INSERTs
  grep "^INSERT INTO" "$PG_DUMP" > "/tmp/n8n_sqlite_import.sql" 2>/dev/null || true
  if [ -s "/tmp/n8n_sqlite_import.sql" ]; then
    docker compose -f "$COMPOSE_FILE" exec -T n8n sh -c "cat > /tmp/import.sql" < "/tmp/n8n_sqlite_import.sql"
    docker compose -f "$COMPOSE_FILE" exec -T n8n sh -c "sqlite3 /home/node/.n8n/database.sqlite < /tmp/import.sql" 2>/dev/null || true
    rm -f "/tmp/n8n_sqlite_import.sql"
  fi
  rm -f "$PG_DUMP"
fi

# Clean up queue volumes
echo "switch-to-regular: Cleaning up queue volumes..."
docker volume rm n8n_postgres_data n8n_redis_data 2>/dev/null || true

echo "SWITCH_TO_REGULAR_OK"
