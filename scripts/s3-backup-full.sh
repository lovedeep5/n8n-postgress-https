#!/bin/bash
# Full n8n volume backup to R2 via pre-signed URL
# Usage: s3-backup-full.sh <presigned-put-url>
# Output on success: S3_BACKUP_FULL_OK|<timestamp>|<encryption_key>

set -e

PRESIGNED_URL="$1"
if [ -z "$PRESIGNED_URL" ]; then
  echo "S3_BACKUP_FULL_ERROR|missing presigned URL argument"
  exit 1
fi

COMPOSE_DIR="/opt/n8n"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
ENV_FILE="$COMPOSE_DIR/.env"
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
BACKUP_FILE="/tmp/n8n_full_backup_${TIMESTAMP}.tar.gz"
VOLUME_NAME="n8n_n8n_data"

# Read encryption key
ENCRYPTION_KEY=$(grep '^ENCRYPTION_KEY=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]')
if [ -z "$ENCRYPTION_KEY" ]; then
  echo "S3_BACKUP_FULL_ERROR|could not read ENCRYPTION_KEY from $ENV_FILE"
  exit 1
fi

echo "Stopping n8n..."
docker compose -f "$COMPOSE_FILE" stop n8n 2>&1

echo "Creating volume snapshot..."
docker run --rm \
  -v "${VOLUME_NAME}:/source:ro" \
  -v "/tmp:/backup" \
  alpine tar czf "/backup/$(basename "$BACKUP_FILE")" -C /source .

echo "Starting n8n..."
docker compose -f "$COMPOSE_FILE" start n8n 2>&1

FILESIZE=$(du -sh "$BACKUP_FILE" | cut -f1)
echo "Backup size: $FILESIZE"

echo "Uploading to R2..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
  -H "Content-Type: application/gzip" \
  -T "$BACKUP_FILE" \
  "$PRESIGNED_URL")

rm -f "$BACKUP_FILE"

if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
  echo "S3_BACKUP_FULL_OK|${TIMESTAMP}|${ENCRYPTION_KEY}|${FILESIZE}"
else
  echo "S3_BACKUP_FULL_ERROR|upload failed with HTTP $HTTP_CODE"
  exit 1
fi
