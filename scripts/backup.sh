#!/bin/bash
# Pre-update full volume backup to R2 via pre-signed URL
# Usage: backup.sh <presigned-put-url>
# Output on success: BACKUP_FULL_OK|<timestamp>|<encryption_key>|<size>

set -e

PRESIGNED_URL="$1"
if [ -z "$PRESIGNED_URL" ]; then
  echo "BACKUP_ERROR|missing presigned URL argument"
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

TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
BACKUP_FILE="/tmp/n8n_update_backup_${TIMESTAMP}.tar.gz"
VOLUME_NAME="n8n_n8n_data"
VOLUME_PATH="/var/lib/docker/volumes/${VOLUME_NAME}/_data"

# Read encryption key
ENCRYPTION_KEY=$(grep '^ENCRYPTION_KEY=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]')
if [ -z "$ENCRYPTION_KEY" ]; then
  echo "BACKUP_ERROR|could not read ENCRYPTION_KEY from $ENV_FILE"
  exit 1
fi

# Get current version BEFORE stopping
VERSION=$(docker compose -f "$COMPOSE_FILE" exec -T n8n n8n --version 2>/dev/null || echo "unknown")
mkdir -p "$COMPOSE_DIR/backups"
echo "$VERSION" > "$COMPOSE_DIR/backups/last_update_version.txt"

echo "Stopping n8n for backup..."
docker compose -f "$COMPOSE_FILE" stop $N8N_SERVICES 2>&1

# Embed version + encryption key into volume so rollback can restore both correctly
echo "$VERSION" > "$VOLUME_PATH/.backup_n8n_version" 2>/dev/null || true
echo "$ENCRYPTION_KEY" > "$VOLUME_PATH/.backup_encryption_key" 2>/dev/null || true

# Queue mode: dump PostgreSQL database into the volume before tarring
if [ -f /opt/n8n/.queue_mode ]; then
  echo "Dumping PostgreSQL database..."
  docker compose -f "$COMPOSE_FILE" exec -T postgres pg_dump -U n8n -d n8n > "$VOLUME_PATH/.queue_pg_dump.sql" 2>/dev/null || echo "WARNING: pg_dump failed" >&2
fi

# Reclaim SQLite pages (only for regular mode — queue mode uses PostgreSQL)
if [ -f /opt/n8n/.queue_mode ]; then
  echo "Skipping SQLite VACUUM (queue mode — PostgreSQL)"
elif command -v sqlite3 >/dev/null 2>&1 && [ -f "$VOLUME_PATH/database.sqlite" ]; then
  echo "Compacting SQLite database..."
  sqlite3 "$VOLUME_PATH/database.sqlite" "PRAGMA wal_checkpoint(TRUNCATE); VACUUM;" 2>&1 || echo "VACUUM warning (continuing with backup)"
fi

echo "Creating volume snapshot..."
docker run --rm \
  -v "${VOLUME_NAME}:/source:ro" \
  -v "/tmp:/backup" \
  alpine tar czf "/backup/$(basename "$BACKUP_FILE")" -C /source .

echo "Starting n8n..."
docker compose -f "$COMPOSE_FILE" start $N8N_SERVICES 2>&1

FILESIZE=$(du -sh "$BACKUP_FILE" | cut -f1)
echo "Backup size: $FILESIZE"

echo "Uploading to R2..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
  -H "Content-Type: application/gzip" \
  -T "$BACKUP_FILE" \
  "$PRESIGNED_URL")

rm -f "$BACKUP_FILE"

if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
  echo "BACKUP_FULL_OK|${TIMESTAMP}|${ENCRYPTION_KEY}|${FILESIZE}"
else
  echo "BACKUP_ERROR|upload failed with HTTP $HTTP_CODE"
  exit 1
fi