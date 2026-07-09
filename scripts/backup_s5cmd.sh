#!/bin/bash
# Pre-update full volume backup to R2 via s5cmd (credentialed multipart upload).
# Usage: backup_s5cmd.sh <presigned-put-url|unused, kept for arg parity with backup.sh> <r2-bucket> <r2-key>
# Requires AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / R2_ENDPOINT in the environment.
# Output on success: BACKUP_FULL_OK|<timestamp>|<encryption_key>|<size>

set -e

# Safety net: if this script is killed/interrupted (deploy, crashed worker,
# dropped SSH session, etc.) after n8n was stopped but before it was started
# back up, restart it on exit instead of leaving the customer's instance down
# until someone notices. No-op if n8n was never stopped, or already restarted.
N8N_DOWN=0
TRAP_LOG="/opt/n8n/backups/backup_trap.log"
restore_n8n_on_exit() {
  # A dropped SSH session (the exact case this exists for) leaves stdout/stderr
  # as a broken pipe. Under `set -e`, writing to it would abort this handler
  # before it ever reaches `docker compose start` - so disable -e here and log
  # to a local file instead of the (possibly-dead) SSH stdout/stderr.
  set +e
  if [ "$N8N_DOWN" = "1" ]; then
    mkdir -p "$(dirname "$TRAP_LOG")" >/dev/null 2>&1
    echo "$(date -u +%FT%TZ) Script exiting while n8n was stopped - restarting as a safety net..." >> "$TRAP_LOG" 2>/dev/null
    docker compose -f "$COMPOSE_FILE" start $N8N_SERVICES >> "$TRAP_LOG" 2>&1
    N8N_DOWN=0
  fi
}
# EXIT alone does not fire on an untrapped signal - bash applies the kernel's
# default disposition (immediate termination) and never reaches the trap. HUP
# in particular is exactly what a dropped SSH session delivers, so it must be
# trapped explicitly, not just EXIT.
trap restore_n8n_on_exit EXIT
trap 'restore_n8n_on_exit; exit 1' HUP TERM INT

R2_BUCKET="$2"
R2_KEY="$3"
if [ -z "$R2_BUCKET" ] || [ -z "$R2_KEY" ]; then
  echo "BACKUP_ERROR|missing r2 bucket or key argument"
  exit 1
fi
if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ] || [ -z "$R2_ENDPOINT" ]; then
  echo "BACKUP_ERROR|missing R2 credentials or endpoint in environment"
  exit 1
fi
if ! command -v s5cmd >/dev/null 2>&1; then
  echo "s5cmd not found, installing..."
  S5CMD_VERSION="2.3.0"
  S5CMD_DEB="s5cmd_${S5CMD_VERSION}_linux_amd64.deb"
  S5CMD_SHA256="81d02a17a13797dc5949adb99734ad4217d005638a7827f36d435945527b2e69"
  TMP_DEB="/tmp/${S5CMD_DEB}"
  if ! curl -sL -o "$TMP_DEB" \
      "https://github.com/peak/s5cmd/releases/download/v${S5CMD_VERSION}/${S5CMD_DEB}"; then
    echo "BACKUP_ERROR|failed to download s5cmd"
    exit 1
  fi
  if ! echo "${S5CMD_SHA256}  ${TMP_DEB}" | sha256sum -c - >/dev/null 2>&1; then
    rm -f "$TMP_DEB"
    echo "BACKUP_ERROR|s5cmd checksum verification failed"
    exit 1
  fi
  if ! dpkg -i "$TMP_DEB" >/dev/null 2>&1; then
    rm -f "$TMP_DEB"
    echo "BACKUP_ERROR|s5cmd install failed"
    exit 1
  fi
  rm -f "$TMP_DEB"
  echo "s5cmd installed"
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
N8N_DOWN=1
docker compose -f "$COMPOSE_FILE" stop $N8N_SERVICES 2>&1

# Embed version + encryption key into volume so rollback can restore both correctly
echo "$VERSION" > "$VOLUME_PATH/.backup_n8n_version" 2>/dev/null || true
echo "$ENCRYPTION_KEY" > "$VOLUME_PATH/.backup_encryption_key" 2>/dev/null || true

# Queue mode: dump PostgreSQL database into the volume before tarring
if [ -f /opt/n8n/.queue_mode ]; then
  echo "Dumping PostgreSQL database..."
  if ! docker compose -f "$COMPOSE_FILE" exec -T postgres pg_dump -U n8n -d n8n > "$VOLUME_PATH/.queue_pg_dump.sql" 2>/dev/null || ! grep -q "PostgreSQL database dump complete" "$VOLUME_PATH/.queue_pg_dump.sql"; then
    rm -f "$VOLUME_PATH/.queue_pg_dump.sql"
    echo "Starting n8n..."
    docker compose -f "$COMPOSE_FILE" start $N8N_SERVICES 2>&1
    N8N_DOWN=0
    echo "BACKUP_ERROR|pg_dump failed or produced a truncated dump"
    exit 1
  fi
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
N8N_DOWN=0

FILESIZE=$(du -sh "$BACKUP_FILE" | cut -f1)
echo "Backup size: $FILESIZE"

echo "Uploading to R2 via s5cmd..."
if ! s5cmd --endpoint-url "$R2_ENDPOINT" cp "$BACKUP_FILE" "s3://${R2_BUCKET}/${R2_KEY}"; then
  rm -f "$BACKUP_FILE"
  echo "BACKUP_ERROR|s5cmd upload failed"
  exit 1
fi

rm -f "$BACKUP_FILE"
echo "BACKUP_FULL_OK|${TIMESTAMP}|${ENCRYPTION_KEY}|${FILESIZE}"
