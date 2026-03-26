#!/bin/bash
# Cloud backup: stop n8n, copy SQLite, restart n8n, upload via pre-signed URL
# Usage: s3-backup.sh <presigned-put-url>
set -e

PRESIGNED_URL="$1"
if [ -z "$PRESIGNED_URL" ]; then
  echo "S3_BACKUP_ERROR|missing presigned URL argument"
  exit 1
fi

TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
COMPOSE="docker compose -f /opt/n8n/simple_docker-compose.yml"
VERSION=$($COMPOSE exec -T n8n n8n --version 2>/dev/null || echo unknown)
CONTAINER=$($COMPOSE ps -q n8n 2>/dev/null)
DATA_PATH=$(docker inspect "$CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/home/node/.n8n"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)
BACKUP_FILE="/tmp/n8n_cloud_backup_${TIMESTAMP}.sqlite"

# Flush WAL into main DB while n8n is still running (uses sqlite3 inside the container)
docker exec "$CONTAINER" sqlite3 /home/node/.n8n/database.sqlite "PRAGMA wal_checkpoint(TRUNCATE);" 2>/dev/null || true

# Stop n8n to get a consistent snapshot
$COMPOSE stop n8n

# Copy the database
if [ -n "$DATA_PATH" ] && [ -f "$DATA_PATH/database.sqlite" ]; then
  cp "$DATA_PATH/database.sqlite" "$BACKUP_FILE"
else
  docker cp "$CONTAINER:/home/node/.n8n/database.sqlite" "$BACKUP_FILE"
fi

# Restart n8n immediately (minimize downtime)
$COMPOSE start n8n

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
