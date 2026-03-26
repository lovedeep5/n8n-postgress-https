#!/bin/bash
set -e
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
COMPOSE="docker compose -f /opt/n8n/simple_docker-compose.yml"
CONTAINER=$($COMPOSE ps -q n8n 2>/dev/null)
VERSION=$($COMPOSE exec -T n8n n8n --version 2>/dev/null || echo unknown)
IMAGE=$(docker inspect "$CONTAINER" --format '{{.Config.Image}}' 2>/dev/null || echo "docker.n8n.io/n8nio/n8n:latest")
BACKUP_DIR="/opt/n8n/backups/backup_${TIMESTAMP}_v${VERSION}"
mkdir -p "$BACKUP_DIR"

# Export workflows using n8n CLI (inside running container)
$COMPOSE exec -T n8n n8n export:workflow --all --pretty --output=/home/node/.n8n/_backup_workflows.json 2>/dev/null
docker cp "$CONTAINER:/home/node/.n8n/_backup_workflows.json" "$BACKUP_DIR/workflows.json" 2>/dev/null

# Export credentials
$COMPOSE exec -T n8n n8n export:credentials --all --pretty --output=/home/node/.n8n/_backup_credentials.json 2>/dev/null || true
docker cp "$CONTAINER:/home/node/.n8n/_backup_credentials.json" "$BACKUP_DIR/credentials.json" 2>/dev/null || true

# Save version and image for rollback
echo "$VERSION" > "$BACKUP_DIR/version.txt"
echo "$IMAGE" > "$BACKUP_DIR/image.txt"

# Cleanup temp files inside container
$COMPOSE exec -T n8n rm -f /home/node/.n8n/_backup_workflows.json /home/node/.n8n/_backup_credentials.json 2>/dev/null || true

# Keep only last 2 backups
cd /opt/n8n/backups && ls -dt backup_*/ 2>/dev/null | tail -n +3 | xargs rm -rf 2>/dev/null || true
echo "BACKUP_OK|$BACKUP_DIR|$VERSION"
