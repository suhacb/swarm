#!/usr/bin/env bash
# Creates the encrypted overlay networks used by every stack in this repo.
# Safe to re-run: skips networks that already exist.
set -euo pipefail

if ! docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q active; then
  echo "Error: this node is not part of an active Swarm. Run 'docker swarm init --advertise-addr <ip>' first." >&2
  exit 1
fi

NETWORKS=(public-ingress app-mesh data-mesh)

for net in "${NETWORKS[@]}"; do
  if docker network inspect "$net" >/dev/null 2>&1; then
    echo "Network '$net' already exists, skipping."
    continue
  fi
  echo "Creating encrypted overlay network '$net'..."
  docker network create \
    --driver overlay \
    --opt encrypted \
    --attachable=false \
    "$net"
done

echo
docker network ls --filter driver=overlay
