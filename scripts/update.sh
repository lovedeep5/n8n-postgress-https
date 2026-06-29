#!/bin/bash
# Update n8n to latest version
# Usage: update.sh
# Output on success: UPDATE_OK|<new_version>

set -e

COMPOSE_DIR="/opt/n8n"
ENV_FILE="$COMPOSE_DIR/.env"

# Detect mode
QUEUE_MODE=$(grep '^QUEUE_MODE=' "$ENV_FILE" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')

if [ "$QUEUE_MODE" = "true" ]; then
  COMPOSE_FILE="$COMPOSE_DIR/docker-compose.queue.yml"
  IMAGES="n8n n8n-worker"
else
  COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
  IMAGES="n8n"
fi

echo "Pulling latest images ($IMAGES)..."
for IMAGE in $IMAGES; do
  for attempt in 1 2 3; do
    if docker compose -f "$COMPOSE_FILE" pull "$IMAGE" 2>&1; then
      break
    fi
    if [ "$attempt" -lt 3 ]; then
      echo "Pull attempt $attempt for $IMAGE failed, retrying in 15s..."
      sleep 15
    else
      echo "Pull failed for $IMAGE after 3 attempts"
      exit 1
    fi
  done
done

echo "Restarting services..."
docker compose -f "$COMPOSE_FILE" up -d 2>&1

sleep 8
VERSION=$(docker compose -f "$COMPOSE_FILE" exec -T n8n n8n --version 2>/dev/null || echo "unknown")

# Clean up old n8n image versions — keeps :latest and the most recent tagged version (for rollback)
PREV_VERSION=$(cat "$COMPOSE_DIR/backups/last_update_version.txt" 2>/dev/null | tr -d '[:space:]' || echo "")
docker images docker.n8n.io/n8nio/n8n --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -v ':latest$' | while read -r ref; do
  TAG="${ref##*:}"
  if [ "$TAG" != "$PREV_VERSION" ]; then
    docker rmi "$ref" 2>/dev/null || true
  fi
done
docker image prune -f 2>/dev/null || true

echo "UPDATE_OK|${VERSION}"