#!/bin/bash
cd /opt/n8n
docker compose -f simple_docker-compose.yml pull
docker compose -f simple_docker-compose.yml up -d
