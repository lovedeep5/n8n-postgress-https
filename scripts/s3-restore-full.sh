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

# Safety net: if this script is killed/interrupted after n8n was stopped but
# before it was started back up, restart it on exit instead of leaving the
# customer's instance down until someone notices. Also removes the
# downloaded restore tarball on any exit path, so an abnormal termination
# doesn't orphan a multi-GB file in /tmp (the same bug class that filled a
# droplet's disk and crashed n8n via SQLITE_IOERR - see backup.sh).
N8N_DOWN=0
TRAP_LOG="/opt/n8n/backups/backup_trap.log"
cleanup_on_exit() {
  set +e
  [ -n "$RESTORE_FILE" ] && rm -f "$RESTORE_FILE" 2>/dev/null
  if [ "$N8N_DOWN" = "1" ]; then
    mkdir -p "$(dirname "$TRAP_LOG")" >/dev/null 2>&1
    echo "$(date -u +%FT%TZ) Script exiting while n8n was stopped - restarting as a safety net..." >> "$TRAP_LOG" 2>/dev/null
    docker compose -f "$COMPOSE_FILE" start n8n >> "$TRAP_LOG" 2>&1
    N8N_DOWN=0
  fi
}
trap cleanup_on_exit EXIT
trap 'cleanup_on_exit; exit 1' HUP TERM INT

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
N8N_DOWN=1
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
N8N_DOWN=0

echo "RESTORE_OK|$(date +%Y-%m-%d_%H-%M-%S)"
