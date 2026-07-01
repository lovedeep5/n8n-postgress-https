#!/bin/bash
# Rollback n8n from full R2 backup
# Usage: rollback.sh <presigned-get-url>
# Output on success: ROLLBACK_OK|<version>

set -e

PRESIGNED_URL="$1"

if [ -z "$PRESIGNED_URL" ]; then
  echo "ROLLBACK_ERROR|missing presigned URL"
  exit 1
fi

COMPOSE_DIR="/opt/n8n"
if [ -f /opt/n8n/.queue_mode ]; then
  COMPOSE_FILE="$COMPOSE_DIR/n8n-queue/docker-compose.yml"
  ENV_FILE="$COMPOSE_DIR/n8n-queue/.env"
  N8N_SERVICES="n8n n8n-worker"
else
  COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
  ENV_FILE="$COMPOSE_DIR/.env"
  N8N_SERVICES="n8n"
fi

RESTORE_FILE="/tmp/n8n_rollback_$(date +%s).tar.gz"
VOLUME_NAME="n8n_n8n_data"
VOLUME_PATH="/var/lib/docker/volumes/${VOLUME_NAME}/_data"

echo "Downloading backup from R2..."
HTTP_CODE=$(curl -s -o "$RESTORE_FILE" -w "%{http_code}" "$PRESIGNED_URL")
if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
  echo "ROLLBACK_ERROR|download failed with HTTP $HTTP_CODE"
  rm -f "$RESTORE_FILE"
  exit 1
fi

FILESIZE=$(du -sh "$RESTORE_FILE" | cut -f1)
echo "Downloaded: $FILESIZE"

echo "Stopping n8n..."
docker compose -f "$COMPOSE_FILE" stop $N8N_SERVICES 2>&1

# Queue mode: ensure postgres+redis are running for pg restore
if [ -f /opt/n8n/.queue_mode ]; then
  echo "Ensuring PostgreSQL and Redis are running..."
  docker compose -f "$COMPOSE_FILE" up -d postgres redis 2>&1
  echo "Waiting for PostgreSQL..."
  for i in $(seq 1 30); do
    docker compose -f "$COMPOSE_FILE" exec -T postgres pg_isready -U n8n -d n8n 2>/dev/null && break
    sleep 2
  done
fi

echo "Clearing existing volume..."
docker run --rm -v "${VOLUME_NAME}:/data" alpine sh -c "rm -rf /data/* /data/.[!.]*" 2>&1

echo "Restoring volume from backup..."
docker run --rm \
  -v "${VOLUME_NAME}:/target" \
  -v "/tmp:/backup" \
  alpine tar xzf "/backup/$(basename "$RESTORE_FILE")" -C /target

rm -f "$RESTORE_FILE"

# Queue mode: restore PostgreSQL database from the pg_dump embedded in the volume
# The n8n/n8n-worker containers are stopped, but postgres keeps running and its own
# volume is never wiped, so the target DB still has all post-backup mutations. Drop
# and recreate it for a clean slate before replaying the dump, otherwise the plain
# (non --clean) pg_dump conflicts with existing rows and psql's errors go unseen.
if [ -f /opt/n8n/.queue_mode ] && [ -f "$VOLUME_PATH/.queue_pg_dump.sql" ]; then
  if ! grep -q "PostgreSQL database dump complete" "$VOLUME_PATH/.queue_pg_dump.sql"; then
    echo "ROLLBACK_ERROR|backed-up pg_dump is missing or truncated, refusing to drop live database"
    exit 1
  fi
  echo "Restoring PostgreSQL database..."
  docker compose -f "$COMPOSE_FILE" exec -T postgres psql -U n8n -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'n8n' AND pid <> pg_backend_pid();" 2>&1
  docker compose -f "$COMPOSE_FILE" exec -T postgres psql -U n8n -d postgres -c "DROP DATABASE IF EXISTS n8n;" 2>&1
  docker compose -f "$COMPOSE_FILE" exec -T postgres psql -U n8n -d postgres -c "CREATE DATABASE n8n OWNER n8n;" 2>&1
  docker compose -f "$COMPOSE_FILE" exec -T postgres psql -U n8n -d n8n -v ON_ERROR_STOP=1 < "$VOLUME_PATH/.queue_pg_dump.sql"
  rm -f "$VOLUME_PATH/.queue_pg_dump.sql"
fi

# Restore encryption key from backup
BACKUP_ENCRYPTION_KEY=$(cat "$VOLUME_PATH/.backup_encryption_key" 2>/dev/null | tr -d '[:space:]' || echo "")
if [ -n "$BACKUP_ENCRYPTION_KEY" ]; then
  echo "Restoring ENCRYPTION_KEY from backup..."
  sed -i "s|^ENCRYPTION_KEY=.*|ENCRYPTION_KEY=${BACKUP_ENCRYPTION_KEY}|" "$ENV_FILE"
fi

# Read the n8n version that was running when backup was taken
BACKUP_VERSION=$(cat "$VOLUME_PATH/.backup_n8n_version" 2>/dev/null | tr -d '[:space:]' || echo "")

if [ -n "$BACKUP_VERSION" ] && [ "$BACKUP_VERSION" != "unknown" ]; then
  echo "Pinning n8n to v${BACKUP_VERSION}..."
  sed -i "s|image:.*n8nio/n8n.*|image: docker.n8n.io/n8nio/n8n:${BACKUP_VERSION}|" "$COMPOSE_FILE"
  docker compose -f "$COMPOSE_FILE" pull n8n 2>&1
fi

echo "Starting n8n..."
docker compose -f "$COMPOSE_FILE" up -d $N8N_SERVICES 2>&1

waited=0
VERSION=""
while [ $waited -lt 90 ]; do
  VERSION=$(docker compose -f "$COMPOSE_FILE" exec -T n8n n8n --version 2>/dev/null || echo "")
  if [ -n "$VERSION" ]; then
    break
  fi
  sleep 3
  waited=$((waited + 3))
done
[ -z "$VERSION" ] && VERSION="unknown"

# Reset compose file back to latest for future updates
sed -i "s|image:.*n8nio/n8n:.*|image: docker.n8n.io/n8nio/n8n:latest|" "$COMPOSE_FILE"

echo "ROLLBACK_OK|${VERSION}"