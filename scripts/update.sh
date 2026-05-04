#!/bin/bash
# Update n8n to latest version
# Usage: update.sh
# Output on success: UPDATE_OK|<new_version>

set -e

COMPOSE_DIR="/opt/n8n"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"

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
docker compose -f "$COMPOSE_FILE" up -d n8n 2>&1

sleep 8
VERSION=$(docker compose -f "$COMPOSE_FILE" exec -T n8n n8n --version 2>/dev/null || echo "unknown")

# Clean up old n8n image versions — keeps :latest and the most recent tagged version (for rollback).
# The most recent tagged version is the one backup.sh tagged before this update.
PREV_VERSION=$(cat "$COMPOSE_DIR/backups/last_update_version.txt" 2>/dev/null | tr -d '[:space:]' || echo "")
docker images docker.n8n.io/n8nio/n8n --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -v ':latest$' | while read -r ref; do
  TAG="${ref##*:}"
  if [ "$TAG" != "$PREV_VERSION" ]; then
    docker rmi "$ref" 2>/dev/null || true
  fi
done
docker image prune -f 2>/dev/null || true

echo "UPDATE_OK|${VERSION}"
