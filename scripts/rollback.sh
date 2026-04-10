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
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
ENV_FILE="$COMPOSE_DIR/.env"
RESTORE_FILE="/tmp/n8n_rollback_$(date +%s).tar.gz"
VOLUME_NAME="n8n_n8n_data"

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

# Read the n8n version that was running when backup was taken
BACKUP_VERSION=$(cat "$VOLUME_DATA/.backup_n8n_version" 2>/dev/null | tr -d '[:space:]' || echo "")

if [ -n "$BACKUP_VERSION" ] && [ "$BACKUP_VERSION" != "unknown" ]; then
  echo "Pinning n8n to v${BACKUP_VERSION}..."
  sed -i "s|image:.*n8nio/n8n.*|image: docker.n8n.io/n8nio/n8n:${BACKUP_VERSION}|" "$COMPOSE_FILE"
  docker compose -f "$COMPOSE_FILE" pull n8n 2>&1
fi

echo "Starting n8n..."
docker compose -f "$COMPOSE_FILE" up -d n8n 2>&1

sleep 8
VERSION=$(docker compose -f "$COMPOSE_FILE" exec -T n8n n8n --version 2>/dev/null || echo "unknown")

# Reset compose file back to latest for future updates
sed -i "s|image:.*n8nio/n8n:.*|image: docker.n8n.io/n8nio/n8n:latest|" "$COMPOSE_FILE"

echo "ROLLBACK_OK|${VERSION}"
