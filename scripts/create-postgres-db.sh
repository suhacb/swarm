#!/usr/bin/env bash
# Provisions a dedicated Postgres role + database for one service on the
# shared postgres server (data-stack.yml), following the convention: role
# name == database name == service name (e.g. "keycloak"). Also creates the
# matching <service>_db_password Docker secret for that service's own stack
# to consume.
#
# Usage: ./scripts/create-postgres-db.sh <service-name>
#
# Idempotent: does nothing if the role, database, and secret all already
# exist. Errors out (rather than guessing) if only some of them exist.
set -euo pipefail

SERVICE="${1:?Usage: $0 <service-name>}"
SECRET_NAME="${SERVICE}_db_password"

CONTAINER=$(docker ps --filter "label=com.docker.swarm.service.name=data_postgres" --format '{{.ID}}' | head -1)
if [ -z "$CONTAINER" ]; then
  echo "Error: no running data_postgres container found. Is the data stack deployed?" >&2
  exit 1
fi

ROLE_EXISTS=$(docker exec "$CONTAINER" psql -U postgres -tAc \
  "SELECT 1 FROM pg_roles WHERE rolname = '$SERVICE'")
if docker secret inspect "$SECRET_NAME" >/dev/null 2>&1; then
  SECRET_EXISTS=1
else
  SECRET_EXISTS=""
fi

if [ -n "$ROLE_EXISTS" ] && [ -n "$SECRET_EXISTS" ]; then
  echo "Role, database, and secret for '$SERVICE' already exist — nothing to do."
  exit 0
fi

if [ -n "$ROLE_EXISTS" ] || [ -n "$SECRET_EXISTS" ]; then
  echo "Error: inconsistent state for '$SERVICE' — role exists: ${ROLE_EXISTS:+yes}, secret exists: ${SECRET_EXISTS:+yes}." >&2
  echo "Resolve manually (drop the role, or remove the secret) before re-running." >&2
  exit 1
fi

PASSWORD=$(openssl rand -base64 32)

docker exec -i "$CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 <<SQL
CREATE ROLE "$SERVICE" LOGIN PASSWORD '$PASSWORD';
CREATE DATABASE "$SERVICE" OWNER "$SERVICE";
REVOKE ALL ON DATABASE "$SERVICE" FROM PUBLIC;
SQL

printf '%s' "$PASSWORD" | docker secret create "$SECRET_NAME" - >/dev/null

echo "Created role, database, and secret '$SECRET_NAME' for service '$SERVICE'."
