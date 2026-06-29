# Test: n8n Queue Mode on DigitalOcean Droplet

## Prerequisites
- A DigitalOcean account with API token
- A domain (optional, can skip and use IP directly)
- SSH key registered with DO

---

## 1. Prepare the local repo

Push `D:\Projects\experiments\n8n-with-queue` to the upstream GitHub repo:

```bash
# From the experiment directory
git init
git add .
git commit -m "queue mode setup"
git remote add origin https://github.com/lovedeep5/n8n-postgress-queue-test.git
git push -u origin main
```

Alternatively, the cloud-init script below clones from the test repo.

---

## 2. Create a droplet via DO control panel

### Settings:
- **Size**: s-2vcpu-4gb (minimum for queue mode)
- **Region**: nyc3 (or closest)
- **OS**: Ubuntu 22.04 (LTS) or 24.04
- **Authentication**: SSH key
- **Advanced options**: Paste the user_data script below

### Cloud-init user_data:

```yaml
#cloud-config
package_update: true
packages:
  - git
  - ca-certificates
  - curl
  - gnupg
  - sqlite3

runcmd:
  # Install Docker
  - curl -fsSL https://get.docker.com | sh
  - systemctl enable --now docker
  - usermod -aG docker root

  # Clone the test repo
  - mkdir -p /opt/n8n
  - git clone https://github.com/lovedeep5/n8n-postgress-queue-test.git /opt/n8n

  # Configure .env
  - |
    cat > /opt/n8n/.env << 'ENVEOF'
    SUB_DOMAIN=n8n
    DOMAIN=YOUR_DOMAIN_OR_IP_HERE
    ENCRYPTION_KEY=$(openssl rand -hex 32)
    POSTGRES_PASSWORD=$(openssl rand -hex 16)
    REDIS_PASSWORD=$(openssl rand -hex 16)
    TZ=UTC
    GENERIC_TIMEZONE=UTC
    N8N_VERSION=latest
    QUEUE_MODE=true
    N8N_WORKERS=2
    ENVEOF
  - sed -i "s/YOUR_DOMAIN_OR_IP_HERE/$(curl -s http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address)/" /opt/n8n/.env

  # Replace Caddyfile domain with IP or domain
  - PUBLIC_IP=$(curl -s http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address)
  - sed -i "s/\${SUB_DOMAIN}\.\${DOMAIN}/$PUBLIC_IP/" /opt/n8n/Caddyfile

  # Pull images
  - cd /opt/n8n && docker compose -f docker-compose.queue.yml pull

  # Start all services
  - cd /opt/n8n && docker compose -f docker-compose.queue.yml up -d

  # Verify health
  - sleep 15
  - curl -s http://localhost:5678/healthz || echo "n8n health check failed"
```

> **Note**: Replace `YOUR_DOMAIN_OR_IP_HERE` with your actual setup. If using a domain, update DOMAIN and keep the Caddyfile template as `{SUB_DOMAIN}.{DOMAIN}`.

---

## 3. Verify services

Once the droplet is running, SSH in and run:

```bash
docker ps
```

Expected output (6 containers):
- n8n-postgres
- n8n-redis
- n8n-main
- n8n-worker (×2 = N8N_WORKERS count)
- n8n-caddy

### Check health of each:

```bash
# PostgreSQL
docker compose -f /opt/n8n/docker-compose.queue.yml exec postgres pg_isready -U n8n

# Redis
docker compose -f /opt/n8n/docker-compose.queue.yml exec redis redis-cli ping

# n8n main
curl -s http://localhost:5678/healthz

# n8n worker
docker compose -f /opt/n8n/docker-compose.queue.yml ps n8n-worker

# Verify worker count
docker compose -f /opt/n8n/docker-compose.queue.yml ps n8n-worker --format '{{.ID}} {{.Name}} {{.Status}}'
```

### Check logs:

```bash
# All logs
docker compose -f /opt/n8n/docker-compose.queue.yml logs --tail=50

# Specific services
docker compose -f /opt/n8n/docker-compose.queue.yml logs n8n --tail=50
docker compose -f /opt/n8n/docker-compose.queue.yml logs n8n-worker --tail=50
docker compose -f /opt/n8n/docker-compose.queue.yml logs postgres --tail=30
docker compose -f /opt/n8n/docker-compose.queue.yml logs redis --tail=30
docker compose -f /opt/n8n/docker-compose.queue.yml logs caddy --tail=30
```

### Check queue mode is active:

```bash
# Check env
grep QUEUE_MODE /opt/n8n/.env

# n8n logs should show queue initialisation
docker compose -f /opt/n8n/docker-compose.queue.yml logs n8n --tail=30 | grep -i queue

# n8n-worker logs should show it picking up jobs
docker compose -f /opt/n8n/docker-compose.queue.yml logs n8n-worker --tail=30 | grep -i "worker\|job\|execution"
```

---

## 4. Test Workflows

### 4a. Access n8n UI
- Open `http://<DROPLET_IP>` (or `https://<DOMAIN>` if DNS is set up)
- Create an owner account

### 4b. Create a webhook test workflow
1. Add **Webhook** node (trigger on GET)
2. Add **Set** node with a static response: `{ "status": "ok", "mode": "queue", "timestamp": "{{ $now }}" }`
3. Add **Respond to Webhook** node
4. Activate the workflow
5. Open the webhook URL in browser → should return JSON

### 4c. Create a heavy workload test (custom code loop)
1. New workflow: **Schedule Trigger** (every 1 minute)
2. Add **Code** node with:
   ```javascript
   // Simulate heavy processing — loops to test worker offloading
   const items = [];
   for (let i = 0; i < 100; i++) {
     items.push({
       json: {
         iteration: i,
         result: Math.random().toString(36).substring(7),
         processed: new Date().toISOString()
       }
     });
   }
   return items;
   ```
3. Add **Wait** node (1 second) to simulate processing time
4. Add **Set** node: `{ "summary": "Processed {{ $json.iteration }} of 100" }`
5. Run workflow a few times manually (click Execute Workflow button)

### 4d. Verify execution on workers
After running workflows:

```bash
# Check workers processed executions
docker compose -f /opt/n8n/docker-compose.queue.yml logs n8n-worker --tail=50 | grep -c "execution\|start\|finished\|success"

# Check n8n main logs for queue-related activity
docker compose -f /opt/n8n/docker-compose.queue.yml logs n8n --tail=50 | grep "queue\|bull\|worker\|job"
```

### 4e. Metrics endpoint
If metrics are enabled:
```bash
curl -s http://localhost:5678/metrics | grep -i "queue\|worker\|execution"
```

---

## 5. Test Migration (queue → regular and back)

### Test switch-to-regular.sh:

```bash
# Dump current state first
docker compose -f /opt/n8n/docker-compose.queue.yml exec -T postgres pg_dump -U n8n -d n8n > /tmp/pre_migration_backup.sql

# Run the switch
bash /opt/n8n/scripts/switch-to-regular.sh

# Verify n8n is running in regular mode
docker ps
# Should show: n8n-1 (no workers, no postgres, no redis)
curl -s http://localhost:5678/healthz

# Verify data survived
# Access UI → check workflows still exist
```

### Test switch-to-queue.sh:

```bash
# Run the switch back
bash /opt/n8n/scripts/switch-to-queue.sh

# Verify full stack is back
docker ps
# Should show all 6 containers
curl -s http://localhost:5678/healthz
```

---

## 6. Test Backup & Restore

### Backup (queue mode):
```bash
# Generate a presigned URL (simulate what Lambda does)
# For testing, just backup locally:
docker compose -f /opt/n8n/docker-compose.queue.yml exec -T postgres pg_dump -U n8n -d n8n | gzip > /tmp/test_backup.sql.gz

# Test the backup script with a local file (no R2):
# Modify backup.sh to skip upload, or test with a local file
bash /opt/n8n/scripts/backup.sh "file:///tmp/test_backup.tar.gz" 2>&1 || true
```

---

## 7. Cleanup

When done testing:
1. Delete the droplet from DO control panel
2. Delete the test repo from GitHub
3. Remove the branch (`git branch -D feature/queue-mode`)
