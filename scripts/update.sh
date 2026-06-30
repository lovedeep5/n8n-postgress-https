#!/bin/bash
# Update n8n to latest version
# Usage: update.sh
# Output on success: UPDATE_OK|<new_version>

set -e

COMPOSE_DIR="/opt/n8n"
if [ -f /opt/n8n/.queue_mode ]; then
  COMPOSE_FILE="$COMPOSE_DIR/n8n-queue/docker-compose.yml"
  N8N_SERVICES="n8n n8n-worker"
else
  COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
  N8N_SERVICES="n8n"
fi

echo "Pulling latest n8n image..."
for attempt in 1 2 3; do
  if docker compose -f "$COMPOSE_FILE" pull n8n 2>&1; then
    break
  fi
  if [ "$attempt" -lt 3 ]; then
    echo "Pull attempt $attempt failed, retrying in 15s..."
    sleep 15
  else
    echo "Pull failed after 3 attempts"
    exit 1
  fi
done

echo "Restarting n8n..."
docker compose -f "$COMPOSE_FILE" up -d $N8N_SERVICES 2>&1

# Queue mode: run database migrations after update
if [ -f /opt/n8n/.queue_mode ]; then
  echo "Running n8n database migrations..."
  docker compose -f "$COMPOSE_FILE" run --rm n8n n8n db:migrate 2>&1 || echo "Migration done"
fi

waited=0
VERSION=""
while [ $waited -lt 90 ]; do
  VERSION=$(docker compose -f "$COMPOSE_FILE" exec -T n8n n8n --version 2>/dev/null || echo "")
  if [ -n "$VERSION" ]; then
    break
  fi
  sleep 3
  waited=$((waited + 3))
done
[ -z "$VERSION" ] && VERSION="unknown"

# Clean up old n8n image versions — keeps :latest (just pulled), removes older tagged versions
# Preserves alpine, caddy, and anything outside the n8nio/n8n repo.
docker images docker.n8n.io/n8nio/n8n --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -v ':latest$' | while read -r ref; do
  docker rmi "$ref" 2>/dev/null || true
done
docker image prune -f 2>/dev/null || true

echo "UPDATE_OK|${VERSION}"