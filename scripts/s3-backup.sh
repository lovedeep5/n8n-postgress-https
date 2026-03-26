#!/bin/bash
# Cloud backup: export workflows + credentials, upload via pre-signed URL
# Usage: s3-backup.sh <presigned-put-url>
set -e

PRESIGNED_URL="$1"
if [ -z "$PRESIGNED_URL" ]; then
  echo "S3_BACKUP_ERROR|missing presigned URL argument"
  exit 1
fi

TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
COMPOSE="docker compose -f /opt/n8n/simple_docker-compose.yml"
CONTAINER=$($COMPOSE ps -q n8n 2>/dev/null)
VERSION=$($COMPOSE exec -T n8n n8n --version 2>/dev/null || echo unknown)
BACKUP_FILE="/tmp/n8n_cloud_backup_${TIMESTAMP}.json"

# Export workflows using n8n CLI (no downtime)
$COMPOSE exec -T n8n n8n export:workflow --all --pretty --output=/home/node/.n8n/_cloud_backup.json 2>/dev/null
docker cp "$CONTAINER:/home/node/.n8n/_cloud_backup.json" "$BACKUP_FILE" 2>/dev/null
$COMPOSE exec -T n8n rm -f /home/node/.n8n/_cloud_backup.json 2>/dev/null || true

# Upload to cloud storage via pre-signed URL
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT -T "$BACKUP_FILE" "$PRESIGNED_URL")

# Clean up temp file
rm -f "$BACKUP_FILE"

if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
  echo "S3_BACKUP_OK|$VERSION|$TIMESTAMP"
else
  echo "S3_BACKUP_ERROR|upload failed with HTTP $HTTP_CODE|$VERSION|$TIMESTAMP"
  exit 1
fi
