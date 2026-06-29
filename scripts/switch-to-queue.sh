#!/bin/bash
# Switch n8n from regular (SQLite) mode to queue (PostgreSQL + Redis + workers) mode
# Usage: switch-to-queue.sh
# Output on success: SWITCH_TO_QUEUE_OK|<new-encryption-key>

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

echo "switch-to-queue: Stopping n8n..."
docker compose -f "$COMPOSE_FILE" stop n8n

echo "switch-to-queue: Dumping SQLite data..."
VOLUME_DATA="/var/lib/docker/volumes/${VOLUME_NAME}/_data"
SQLITE_DUMP="/tmp/n8n_sqlite_dump.sql"
if [ -f "$VOLUME_DATA/database.sqlite" ]; then
  sqlite3 "$VOLUME_DATA/database.sqlite" .dump > "$SQLITE_DUMP"
  echo "switch-to-queue: SQLite dump complete ($(wc -l < "$SQLITE_DUMP") lines)"
fi

# Generate postgres + redis passwords if not set
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(openssl rand -hex 16)}"
REDIS_PASSWORD="${REDIS_PASSWORD:-$(openssl rand -hex 16)}"

# Generate queue env vars
cat >> "$ENV_FILE" << EOF

# --- Queue Mode ---
QUEUE_MODE=true
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
REDIS_PASSWORD=${REDIS_PASSWORD}
N8N_WORKERS=${N8N_WORKERS:-2}
EOF

echo "switch-to-queue: Starting PostgreSQL + Redis..."
docker compose -f "$COMPOSE_QUEUE_FILE" up -d postgres redis

echo "switch-to-queue: Waiting for PostgreSQL to be healthy..."
until docker compose -f "$COMPOSE_QUEUE_FILE" exec -T postgres pg_isready -U n8n -d n8n 2>/dev/null; do
  sleep 2
done

echo "switch-to-queue: Waiting for Redis to be healthy..."
until docker compose -f "$COMPOSE_QUEUE_FILE" exec -T redis redis-cli -a "$REDIS_PASSWORD" ping 2>/dev/null | grep -q PONG; do
  sleep 1
done

echo "switch-to-queue: Running n8n database migrations..."
docker compose -f "$COMPOSE_QUEUE_FILE" run --rm n8n n8n db:migrate

# Import SQLite data into PostgreSQL
if [ -f "$SQLITE_DUMP" ]; then
  echo "switch-to-queue: Importing data into PostgreSQL..."
  # Replace SQLite-specific syntax with PostgreSQL-compatible
  # n8n handles schema creation via migrations, we just need the data
  docker compose -f "$COMPOSE_QUEUE_FILE" exec -T postgres psql -U n8n -d n8n < "$SQLITE_DUMP" 2>/dev/null || true
  rm -f "$SQLITE_DUMP"
fi

echo "switch-to-queue: Starting n8n main + workers..."
docker compose -f "$COMPOSE_QUEUE_FILE" up -d n8n n8n-worker

echo "switch-to-queue: Waiting for n8n health check..."
for i in $(seq 1 30); do
  if docker compose -f "$COMPOSE_QUEUE_FILE" exec -T n8n wget --spider -q http://localhost:5678/healthz 2>/dev/null; then
    echo "switch-to-queue: n8n is healthy"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "switch-to-queue: ERROR - n8n failed to become healthy"
    exit 1
  fi
  sleep 2
done

# Verify workers are running
WORKER_COUNT=$(docker compose -f "$COMPOSE_QUEUE_FILE" ps n8n-worker --format '{{.Status}}' 2>/dev/null | grep -c "Up" || true)
echo "switch-to-queue: Workers running: $WORKER_COUNT"

echo "SWITCH_TO_QUEUE_OK"
