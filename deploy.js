#!/usr/bin/env node
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { execSync } = require("child_process");

const IP = process.argv[2] || "167.71.167.228";
const SSH_KEY = path.resolve(__dirname, "../../n8nautomation.cloud/.ssh_temp");
const EXP = __dirname;

function run(cmd, opts = {}) {
  try {
    return execSync(cmd, { stdio: "pipe", timeout: opts.timeout || 120000, ...opts }).toString().trim();
  } catch (e) {
    if (opts.ignoreError) return "";
    throw e;
  }
}

function ssh(cmd, opts = {}) {
  return run(`ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i "${SSH_KEY}" root@${IP} ${JSON.stringify(cmd)}`, opts);
}

function scp(local, remote) {
  run(`scp -o StrictHostKeyChecking=no -i "${SSH_KEY}" "${local}" root@${IP}:"${remote}"`);
}

async function main() {
  console.log(`\n=== Deploying to ${IP} ===\n`);

  // 1. Create directories
  console.log("1/8 Creating directories...");
  ssh("mkdir -p /opt/n8n/scripts");

  // 2. Get droplet IP and create .env locally
  console.log("2/8 Creating .env...");
  const publicIp = ssh("curl -s http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address");
  const env = [
    `ENCRYPTION_KEY=${crypto.randomBytes(32).toString("hex")}`,
    `POSTGRES_PASSWORD=${crypto.randomBytes(16).toString("hex")}`,
    `REDIS_PASSWORD=${crypto.randomBytes(16).toString("hex")}`,
    "TZ=UTC",
    "GENERIC_TIMEZONE=UTC",
    "N8N_VERSION=latest",
    "QUEUE_MODE=true",
    "N8N_WORKERS=2",
    "SUB_DOMAIN=n8n",
    `DOMAIN=${publicIp}`,
  ].join("\n");
  fs.writeFileSync(path.join(EXP, ".env.tmp"), env, "utf-8");

  // 3. Create Caddyfile with IP
  console.log("3/8 Creating Caddyfile...");
  fs.writeFileSync(path.join(EXP, "Caddyfile.tmp"),
    `{\n  email admin@n8nautomation.cloud\n}\n${publicIp} {\n    reverse_proxy n8n:5678 {\n      flush_interval -1\n    }\n}\n`,
    "utf-8"
  );

  // 4. Transfer files
  console.log("4/8 Transferring files...");
  scp(path.join(EXP, "docker-compose.queue.yml"), "/opt/n8n/docker-compose.queue.yml");
  scp(path.join(EXP, ".env.tmp"), "/opt/n8n/.env");
  scp(path.join(EXP, "Caddyfile.tmp"), "/opt/n8n/Caddyfile");
  scp(path.join(EXP, "scripts/switch-to-queue.sh"), "/opt/n8n/scripts/switch-to-queue.sh");
  scp(path.join(EXP, "scripts/switch-to-regular.sh"), "/opt/n8n/scripts/switch-to-regular.sh");

  // 5. Chmod scripts
  ssh("chmod +x /opt/n8n/scripts/*.sh");

  // 6. Pull images (slow)
  console.log("5/8 Pulling images (5-10 min)...");
  ssh("cd /opt/n8n && docker compose -f docker-compose.queue.yml pull");

  // 7. Start all services
  console.log("6/8 Starting services...");
  ssh("cd /opt/n8n && docker compose -f docker-compose.queue.yml up -d");

  // 8. Wait for health
  console.log("7/8 Waiting for n8n...");
  for (let i = 0; i < 12; i++) {
    const code = ssh("curl -s -o /dev/null -w '%{http_code}' http://localhost:5678/healthz", { ignoreError: true });
    if (code === "200") { console.log("n8n is healthy!"); break; }
    if (i < 11) { process.stdout.write("."); ssh("sleep 10"); }
  }
  console.log();

  // 9. Verify
  console.log("8/8 Verification...\n");
  const ps = ssh("docker ps --format 'table {{.Names}}\t{{.Status}}'");
  console.log("Containers:\n" + ps);

  console.log(`\n=== Done ===`);
  console.log(`n8n: http://${publicIp}`);
  console.log(`Logs: ssh -i "${SSH_KEY}" root@${IP} 'docker compose -f /opt/n8n/docker-compose.queue.yml logs --tail=50'`);

  // Cleanup temp files
  fs.unlinkSync(path.join(EXP, ".env.tmp"));
  fs.unlinkSync(path.join(EXP, "Caddyfile.tmp"));
}

main().catch((err) => {
  console.error("Deploy failed:", err.message);
  process.exit(1);
});