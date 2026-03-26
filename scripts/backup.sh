#!/bin/bash
set -e
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
COMPOSE="docker compose -f /opt/n8n/simple_docker-compose.yml"
VERSION=$($COMPOSE exec -T n8n n8n --version 2>/dev/null || echo unknown)
BACKUP_DIR="/opt/n8n/backups/backup_${TIMESTAMP}_v${VERSION}"
CONTAINER=$($COMPOSE ps -q n8n 2>/dev/null)
DATA_PATH=$(docker inspect "$CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/home/node/.n8n"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)
mkdir -p "$BACKUP_DIR"
# Flush WAL into main DB while n8n is still running (uses sqlite3 inside the container)
docker exec "$CONTAINER" sqlite3 /home/node/.n8n/database.sqlite "PRAGMA wal_checkpoint(TRUNCATE);" 2>/dev/null || true
$COMPOSE stop n8n
if [ -n "$DATA_PATH" ] && [ -f "$DATA_PATH/database.sqlite" ]; then
  cp "$DATA_PATH/database.sqlite" "$BACKUP_DIR/database.sqlite"
else
  docker cp "$CONTAINER:/home/node/.n8n/database.sqlite" "$BACKUP_DIR/database.sqlite"
fi
echo "$VERSION" > "$BACKUP_DIR/version.txt"
$COMPOSE start n8n
cd /opt/n8n/backups && ls -dt backup_*/ 2>/dev/null | tail -n +3 | xargs rm -rf 2>/dev/null || true
echo "BACKUP_OK|$BACKUP_DIR|$VERSION"
