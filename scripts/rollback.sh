#!/bin/bash
BACKUP_DIR="$1"
if [ -z "$BACKUP_DIR" ] || [ ! -f "$BACKUP_DIR/database.sqlite" ]; then
  echo "ROLLBACK_ERROR|Backup not found: $BACKUP_DIR"
  exit 1
fi
CONTAINER=$(docker ps -a --filter "label=com.docker.compose.service=n8n" --format "{{.Names}}" | head -1)
[ -z "$CONTAINER" ] && CONTAINER="n8n-n8n-1"
DATA_PATH=$(docker inspect "$CONTAINER" --format "{{range .Mounts}}{{if eq .Destination \"/home/node/.n8n\"}}{{.Source}}{{end}}{{end}}")
cd /opt/n8n
docker compose -f simple_docker-compose.yml stop n8n
if [ -n "$DATA_PATH" ]; then
  rm -f "$DATA_PATH/database.sqlite-wal" "$DATA_PATH/database.sqlite-shm"
  cp "$BACKUP_DIR/database.sqlite" "$DATA_PATH/database.sqlite"
  chown 1000:1000 "$DATA_PATH/database.sqlite"
  chmod 644 "$DATA_PATH/database.sqlite"
else
  docker cp "$BACKUP_DIR/database.sqlite" "$CONTAINER:/home/node/.n8n/database.sqlite"
fi
docker compose -f simple_docker-compose.yml start n8n
VERSION=$(docker compose -f simple_docker-compose.yml exec -T n8n n8n --version 2>/dev/null || echo unknown)
echo "ROLLBACK_OK|$VERSION"
