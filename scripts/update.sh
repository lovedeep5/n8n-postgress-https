#!/bin/bash
# Update n8n to latest version
# Usage: update.sh
# Output on success: UPDATE_OK|<new_version>

set -e

COMPOSE_DIR="/opt/n8n"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"

echo "Pulling latest n8n image..."
docker compose -f "$COMPOSE_FILE" pull n8n 2>&1

echo "Restarting n8n..."
docker compose -f "$COMPOSE_FILE" up -d n8n 2>&1

sleep 8
VERSION=$(docker compose -f "$COMPOSE_FILE" exec -T n8n n8n --version 2>/dev/null || echo "unknown")

echo "UPDATE_OK|${VERSION}"
