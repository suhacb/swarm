#!/usr/bin/env bash
# Creates the encrypted overlay networks used by every stack in this repo.
# Safe to re-run: skips networks that already exist.
set -euo pipefail

if ! docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q active; then
  echo "Error: this node is not part of an active Swarm. Run 'docker swarm init --advertise-addr <ip>' first." >&2
  exit 1
fi

# Production tiers stay non-attachable — only services declared in a
# stack file can join, nothing ad hoc. ci-mesh is the deliberate exception:
# GitLab Runner's docker executor creates job containers via plain Docker
# API calls (not Swarm services), so they can only join a network that
# allows that.
NETWORKS=(public-ingress app-mesh data-mesh)
ATTACHABLE_NETWORKS=(ci-mesh)

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

for net in "${ATTACHABLE_NETWORKS[@]}"; do
  if docker network inspect "$net" >/dev/null 2>&1; then
    echo "Network '$net' already exists, skipping."
    continue
  fi
  echo "Creating encrypted attachable overlay network '$net'..."
  docker network create \
    --driver overlay \
    --opt encrypted \
    --attachable=true \
    "$net"
done

echo
docker network ls --filter driver=overlay
