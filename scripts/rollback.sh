#!/bin/bash
BACKUP_DIR="$1"
if [ -z "$BACKUP_DIR" ] || [ ! -f "$BACKUP_DIR/workflows.json" ]; then
  echo "ROLLBACK_ERROR|Backup not found: $BACKUP_DIR"
  exit 1
fi

COMPOSE="docker compose -f /opt/n8n/simple_docker-compose.yml"
cd /opt/n8n

# Get the old image from backup (for version rollback)
OLD_IMAGE=$(cat "$BACKUP_DIR/image.txt" 2>/dev/null || echo "")

# Step 1: If backup has a different image, downgrade n8n version
if [ -n "$OLD_IMAGE" ]; then
  CURRENT_IMAGE=$(docker inspect "$($COMPOSE ps -q n8n 2>/dev/null)" --format '{{.Config.Image}}' 2>/dev/null || echo "")
  if [ "$OLD_IMAGE" != "$CURRENT_IMAGE" ] && [ "$OLD_IMAGE" != "docker.n8n.io/n8nio/n8n:latest" ]; then
    echo "Rolling back n8n image to $OLD_IMAGE..."
    $COMPOSE stop n8n 2>/dev/null
    # Temporarily pin the old image
    sed -i "s|image:.*n8nio/n8n.*|image: $OLD_IMAGE|g" simple_docker-compose.yml
    docker pull "$OLD_IMAGE" 2>/dev/null
    $COMPOSE up -d n8n 2>/dev/null
    # Reset to latest tag
    sed -i "s|image:.*n8nio/n8n.*|image: docker.n8n.io/n8nio/n8n:latest|g" simple_docker-compose.yml
    sleep 5
  fi
fi

# Step 2: Stop n8n and import workflows using one-off container
$COMPOSE stop n8n 2>/dev/null

# Copy backup files into the volume
DATA_PATH=$(docker inspect "$($COMPOSE ps -aq n8n 2>/dev/null | head -1)" --format '{{range .Mounts}}{{if eq .Destination "/home/node/.n8n"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)
if [ -z "$DATA_PATH" ]; then
  DATA_PATH="/var/lib/docker/volumes/n8n_n8n_data/_data"
fi
cp "$BACKUP_DIR/workflows.json" "$DATA_PATH/_restore_workflows.json"
cp "$BACKUP_DIR/credentials.json" "$DATA_PATH/_restore_credentials.json" 2>/dev/null || true

# Get the n8n image to use for import
N8N_IMAGE=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep n8nio/n8n | head -1)
[ -z "$N8N_IMAGE" ] && N8N_IMAGE="docker.n8n.io/n8nio/n8n:latest"

# Import workflows using standalone container (no task runner hang)
docker run --rm \
  -v n8n_n8n_data:/home/node/.n8n \
  --entrypoint n8n \
  -e N8N_RUNNERS_DISABLED=true \
  "$N8N_IMAGE" \
  import:workflow --input=/home/node/.n8n/_restore_workflows.json 2>&1

# Import credentials if they exist
if [ -f "$BACKUP_DIR/credentials.json" ]; then
  docker run --rm \
    -v n8n_n8n_data:/home/node/.n8n \
    --entrypoint n8n \
    -e N8N_RUNNERS_DISABLED=true \
    "$N8N_IMAGE" \
    import:credentials --input=/home/node/.n8n/_restore_credentials.json 2>&1 || true
fi

# Cleanup temp files
rm -f "$DATA_PATH/_restore_workflows.json" "$DATA_PATH/_restore_credentials.json"

# Step 3: Start n8n
$COMPOSE start n8n 2>/dev/null
sleep 3

VERSION=$($COMPOSE exec -T n8n n8n --version 2>/dev/null || echo unknown)
echo "ROLLBACK_OK|$VERSION"
