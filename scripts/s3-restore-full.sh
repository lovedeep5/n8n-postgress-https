#!/bin/bash
# Restore full n8n volume from R2 backup
# Usage: s3-restore-full.sh <presigned-get-url> [encryption_key]
# If encryption_key is provided, updates .env before starting n8n

set -e

PRESIGNED_URL="$1"
NEW_ENCRYPTION_KEY="$2"

if [ -z "$PRESIGNED_URL" ]; then
  echo "ERROR: missing presigned URL"
  echo "Usage: s3-restore-full.sh <presigned-get-url> [encryption_key]"
  exit 1
fi

COMPOSE_DIR="/opt/n8n"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
ENV_FILE="$COMPOSE_DIR/.env"
RESTORE_FILE="/tmp/n8n_restore_$(date +%s).tar.gz"
VOLUME_NAME="n8n_n8n_data"

echo "Downloading backup from R2..."
HTTP_CODE=$(curl -s -o "$RESTORE_FILE" -w "%{http_code}" "$PRESIGNED_URL")
if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
  echo "ERROR: download failed with HTTP $HTTP_CODE"
  rm -f "$RESTORE_FILE"
  exit 1
fi

FILESIZE=$(du -sh "$RESTORE_FILE" | cut -f1)
echo "Downloaded: $FILESIZE"

echo "Stopping n8n..."
docker compose -f "$COMPOSE_FILE" stop n8n 2>&1

echo "Clearing existing volume data..."
docker run --rm -v "${VOLUME_NAME}:/data" alpine sh -c "rm -rf /data/* /data/.[!.]*" 2>&1

echo "Restoring volume from backup..."
docker run --rm \
  -v "${VOLUME_NAME}:/target" \
  -v "/tmp:/backup" \
  alpine tar xzf "/backup/$(basename "$RESTORE_FILE")" -C /target

rm -f "$RESTORE_FILE"

# Restore encryption key — prefer embedded key from backup, fallback to passed argument
VOLUME_DATA="/var/lib/docker/volumes/${VOLUME_NAME}/_data"
EMBEDDED_KEY=$(cat "$VOLUME_DATA/.backup_encryption_key" 2>/dev/null | tr -d '[:space:]' || echo "")
RESTORE_KEY="${EMBEDDED_KEY:-$NEW_ENCRYPTION_KEY}"
if [ -n "$RESTORE_KEY" ]; then
  echo "Restoring ENCRYPTION_KEY..."
  sed -i "s|^ENCRYPTION_KEY=.*|ENCRYPTION_KEY=${RESTORE_KEY}|" "$ENV_FILE"
fi

echo "Starting n8n..."
docker compose -f "$COMPOSE_FILE" start n8n 2>&1

echo "RESTORE_OK|$(date +%Y-%m-%d_%H-%M-%S)"
