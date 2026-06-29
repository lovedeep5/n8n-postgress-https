#!/usr/bin/env node
const fs = require("fs");
const path = require("path");

const DO_TOKEN = process.env.DIGITALOCEAN_API_TOKEN;
const SSH_KEY_ID = Number(process.env.DIGITALOCEAN_SSH_KEY_ID || "55178669");

const DROPLET_NAME = `n8n-queue-test-${Date.now().toString(36)}`;
const SIZE = "s-2vcpu-4gb";
const REGION = "nyc3";

async function main() {
  const userDataPath = path.join(__dirname, "cloud-init-queue.yaml");
  const raw = fs.readFileSync(userDataPath, "utf-8");
  const userData = raw;

  console.log(`Creating droplet: ${DROPLET_NAME} (${SIZE}, ${REGION})...`);

  const res = await fetch("https://api.digitalocean.com/v2/droplets", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${DO_TOKEN}`,
    },
    body: JSON.stringify({
      name: DROPLET_NAME,
      size: SIZE,
      image: "docker-20-04",
      region: REGION,
      backups: false,
      monitoring: true,
      ssh_keys: [SSH_KEY_ID],
      user_data: userData,
    }),
  });

  const data = await res.json();
  if (!res.ok) {
    console.error("DO API Error:", JSON.stringify(data, null, 2));
    process.exit(1);
  }

  const droplet = data.droplet;
  console.log(`Droplet created! ID: ${droplet.id}, Name: ${droplet.name}`);
  console.log("Waiting for IP assignment...");

  let ip = null;
  for (let i = 0; i < 30; i++) {
    const r = await fetch(
      `https://api.digitalocean.com/v2/droplets/${droplet.id}`,
      { headers: { Authorization: `Bearer ${DO_TOKEN}` } }
    );
    const d = await r.json();
    if (d.droplet?.networks?.v4?.length) {
      const pub = d.droplet.networks.v4.find((n) => n.type === "public");
      if (pub?.ip_address) {
        ip = pub.ip_address;
        break;
      }
    }
    await new Promise((r) => setTimeout(r, 5000));
    process.stdout.write(".");
  }
  console.log();

  if (!ip) {
    console.error("Failed to get droplet IP");
    process.exit(1);
  }

  console.log(`\nDroplet IP: ${ip}`);
  console.log(`SSH: ssh -o StrictHostKeyChecking=no root@${ip}`);
  console.log(`\nWait ~3 min for cloud-init, then verify:`);
  console.log(`  ssh root@${ip} 'docker ps'`);
  console.log(`  ssh root@${ip} 'curl -s http://localhost:5678/healthz'`);
  console.log(`  ssh root@${ip} 'docker compose -f /opt/n8n/docker-compose.queue.yml logs --tail=30 --no-color'`);
}

main().catch(console.error);