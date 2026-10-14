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

# Safety net: if this script is killed/interrupted (deploy, crashed worker,
# dropped SSH session, etc.) after n8n was stopped but before it was started
# back up, restart it on exit instead of leaving the customer's instance down
# until someone notices. Also removes the backup tarball on any exit path -
# the happy-path rm further down already does this, but an abnormal
# termination skips straight past it, orphaning a multi-GB file in /tmp that
# eventually fills the disk and takes n8n down with a SQLITE_IOERR.
N8N_DOWN=0
TRAP_LOG="/opt/n8n/backups/backup_trap.log"
cleanup_on_exit() {
  set +e
  [ -n "$BACKUP_FILE" ] && rm -f "$BACKUP_FILE" 2>/dev/null
  if [ "$N8N_DOWN" = "1" ]; then
    mkdir -p "$(dirname "$TRAP_LOG")" >/dev/null 2>&1
    echo "$(date -u +%FT%TZ) Script exiting while n8n was stopped - restarting as a safety net..." >> "$TRAP_LOG" 2>/dev/null
    docker compose -f "$COMPOSE_FILE" start n8n >> "$TRAP_LOG" 2>&1
    N8N_DOWN=0
  fi
}
trap cleanup_on_exit EXIT
trap 'cleanup_on_exit; exit 1' HUP TERM INT

# Read encryption key
ENCRYPTION_KEY=$(grep '^ENCRYPTION_KEY=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]')
if [ -z "$ENCRYPTION_KEY" ]; then
  echo "S3_BACKUP_FULL_ERROR|could not read ENCRYPTION_KEY from $ENV_FILE"
  exit 1
fi

echo "Stopping n8n..."
N8N_DOWN=1
docker compose -f "$COMPOSE_FILE" stop n8n 2>&1

echo "Creating volume snapshot..."
docker run --rm \
  -v "${VOLUME_NAME}:/source:ro" \
  -v "/tmp:/backup" \
  alpine tar czf "/backup/$(basename "$BACKUP_FILE")" -C /source .

echo "Starting n8n..."
docker compose -f "$COMPOSE_FILE" start n8n 2>&1
N8N_DOWN=0

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
