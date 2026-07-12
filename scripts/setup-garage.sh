#!/usr/bin/env bash
# Bootstraps Garage for the princess service: creates the 4 per-environment
# buckets plus one shared cross-environment bucket (princess-templates —
# per the princess_backend repo's own .env.example/.testing.env.example,
# both reference the SAME literal bucket name regardless of environment,
# unlike the per-env buckets below), and ONE access key scoped to exactly
# those 5 (mirrors the princess Postgres role's "scoped to only those 4
# databases" pattern — see create-princess-databases.sh). Layout itself is
# handled by the `--single-node` server flag (shared-services-stack.yml),
# not this script.
#
# Usage: ./scripts/setup-garage.sh
# Idempotent: skips any bucket/key that already exists.
set -euo pipefail

# Hyphens, not underscores: confirmed live — Garage enforces S3 bucket
# naming rules, which reject underscores ("Invalid bucket name"). This is
# a Garage/S3-only exception to the repo-wide underscore convention used
# for Postgres databases and Qdrant/ZincSearch naming, neither of which
# has this restriction.
BUCKETS=(princess staging-princess e2e-princess test-princess princess-templates)
KEY_NAME="princess"

CONTAINER=$(docker ps --filter "label=com.docker.swarm.service.name=shared-services_garage" --format '{{.ID}}' | head -1)
if [ -z "$CONTAINER" ]; then
  echo "Error: no running shared-services_garage container found. Is the shared-services stack deployed?" >&2
  exit 1
fi

garage() {
  # Config defaults to /etc/garage.toml (the real rendered file mounted
  # there, see shared-services-stack.yml) — no -c flag needed.
  docker exec "$CONTAINER" /garage "$@"
}

# `garage bucket list`'s columnar output puts the bucket name under
# "Global aliases", not as a standalone line — grep -w for it anywhere in
# the table rather than an exact-line match.
for BUCKET in "${BUCKETS[@]}"; do
  if garage bucket list | grep -qw "$BUCKET"; then
    echo "Bucket '$BUCKET' already exists."
  else
    garage bucket create "$BUCKET"
    echo "Created bucket '$BUCKET'."
  fi
done

if garage key list | grep -qw "$KEY_NAME"; then
  echo "Key '$KEY_NAME' already exists — leaving its secret alone."
else
  KEY_OUTPUT=$(garage key create "$KEY_NAME")
  # "Key ID:              GK..." / "Secret key:          <hex>" — colon is
  # followed by variable padding, not a single space, so grab the last
  # whitespace-separated field rather than splitting on ": ".
  KEY_ID=$(echo "$KEY_OUTPUT" | grep "Key ID:" | awk '{print $NF}')
  KEY_SECRET=$(echo "$KEY_OUTPUT" | grep "Secret key:" | awk '{print $NF}')
  printf '%s' "$KEY_ID" | docker secret create princess_garage_key_id -
  printf '%s' "$KEY_SECRET" | docker secret create princess_garage_secret_key -
  echo "Created key '$KEY_NAME' and secrets 'princess_garage_key_id' / 'princess_garage_secret_key'."
fi

for BUCKET in "${BUCKETS[@]}"; do
  # "==== KEYS FOR THIS BUCKET ====" is followed by a row per granted key,
  # e.g. "RWO  GK...  princess" — check for the key name anywhere after
  # that header.
  if garage bucket info "$BUCKET" | grep -A20 "KEYS FOR THIS BUCKET" | grep -qw "$KEY_NAME"; then
    echo "Key '$KEY_NAME' already has read/write/owner on '$BUCKET'."
  else
    garage bucket allow --read --write --owner "$BUCKET" --key "$KEY_NAME"
    echo "Granted '$KEY_NAME' read/write/owner on '$BUCKET'."
  fi
done

echo "Done."
