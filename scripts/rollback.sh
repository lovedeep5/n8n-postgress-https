#!/bin/bash
# Rollback n8n from full R2 backup
# Usage: rollback.sh <presigned-get-url>
# Output on success: ROLLBACK_OK|<timestamp>

set -e

PRESIGNED_URL="$1"

if [ -z "$PRESIGNED_URL" ]; then
  echo "ROLLBACK_ERROR|missing presigned URL"
  exit 1
fi

COMPOSE_DIR="/opt/n8n"
ENV_FILE="$COMPOSE_DIR/.env"
RESTORE_FILE="/tmp/n8n_rollback_$(date +%s).tar.gz"

# Detect mode
QUEUE_MODE=$(grep '^QUEUE_MODE=' "$ENV_FILE" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')

if [ "$QUEUE_MODE" = "true" ]; then
  COMPOSE_FILE="$COMPOSE_DIR/docker-compose.queue.yml"
  VOLUME_NAME="n8n_n8n_data"
else
  COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
  VOLUME_NAME="n8n_n8n_data"
fi

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
docker compose -f "$COMPOSE_FILE" stop n8n 2>&1

if [ "$QUEUE_MODE" = "true" ]; then
  # --- Queue mode restore ---
  echo "Queue mode: extracting backup..."
  mkdir -p /tmp/n8n_restore
  tar xzf "$RESTORE_FILE" -C /tmp/n8n_restore
  rm -f "$RESTORE_FILE"

  # Restore PostgreSQL dump
  if [ -f "/tmp/n8n_restore/n8n_backup_data/n8n_pg_dump.sql.gz" ]; then
    echo "Queue mode: restoring PostgreSQL..."
    gunzip -c "/tmp/n8n_restore/n8n_backup_data/n8n_pg_dump.sql.gz" | \
      docker compose -f "$COMPOSE_FILE" exec -T postgres psql -U n8n -d n8n 2>/dev/null || true
  fi

  # Restore encryption key
  if [ -f "/tmp/n8n_restore/n8n_backup_data/.backup_encryption_key" ]; then
    BACKUP_KEY=$(cat "/tmp/n8n_restore/n8n_backup_data/.backup_encryption_key" | tr -d '[:space:]')
    if [ -n "$BACKUP_KEY" ]; then
      sed -i "s|^ENCRYPTION_KEY=.*|ENCRYPTION_KEY=${BACKUP_KEY}|" "$ENV_FILE"
    fi
  fi

  rm -rf /tmp/n8n_restore
else
  # --- Regular mode restore (existing logic) ---
  echo "Clearing existing volume..."
  docker run --rm -v "${VOLUME_NAME}:/data" alpine sh -c "rm -rf /data/* /data/.[!.]*" 2>&1

  echo "Restoring volume from backup..."
  docker run --rm \
    -v "${VOLUME_NAME}:/target" \
    -v "/tmp:/backup" \
    alpine tar xzf "/backup/$(basename "$RESTORE_FILE")" -C /target

  rm -f "$RESTORE_FILE"

  VOLUME_DATA="/var/lib/docker/volumes/${VOLUME_NAME}/_data"

  # Restore encryption key from backup
  BACKUP_ENCRYPTION_KEY=$(cat "$VOLUME_DATA/.backup_encryption_key" 2>/dev/null | tr -d '[:space:]' || echo "")
  if [ -n "$BACKUP_ENCRYPTION_KEY" ]; then
    echo "Restoring ENCRYPTION_KEY from backup..."
    sed -i "s|^ENCRYPTION_KEY=.*|ENCRYPTION_KEY=${BACKUP_ENCRYPTION_KEY}|" "$ENV_FILE"
  fi

  # Pin compose to the version tagged at backup time
  BACKUP_VERSION=$(cat "$VOLUME_DATA/.backup_n8n_version" 2>/dev/null | tr -d '[:space:]' || echo "")
  if [ -n "$BACKUP_VERSION" ] && [ "$BACKUP_VERSION" != "unknown" ]; then
    echo "Pinning n8n to v${BACKUP_VERSION}..."
    sed -i "s|image:.*n8nio/n8n.*|image: docker.n8n.io/n8nio/n8n:${BACKUP_VERSION}|" "$COMPOSE_FILE"
  fi
fi

echo "Starting n8n..."
docker compose -f "$COMPOSE_FILE" up -d n8n 2>&1

# Reset compose file back to latest
if [ -z "$QUEUE_MODE" ] || [ "$QUEUE_MODE" != "true" ]; then
  sed -i "s|image:.*n8nio/n8n:.*|image: docker.n8n.io/n8nio/n8n:latest|" "$COMPOSE_FILE"
fi

echo "ROLLBACK_OK|$(date +%Y-%m-%d_%H-%M-%S)"