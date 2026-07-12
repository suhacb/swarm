#!/usr/bin/env bash
# Provisions the princess service's Postgres footprint: ONE role scoped to
# FOUR databases (prod, staging, e2e, CI test) — unlike
# create-postgres-db.sh's 1 role == 1 database == service name convention,
# princess needs a single role that can move between environments without
# juggling separate credentials per env.
#
# Usage: ./scripts/create-princess-databases.sh
#
# Idempotent: does nothing if the role, all four databases, and the secret
# already exist. Errors out (rather than guessing) if only some exist.
set -euo pipefail

ROLE="princess"
DATABASES=(princess stage_princess e2e_princess test_princess)
SECRET_NAME="princess_db_password"

CONTAINER=$(docker ps --filter "label=com.docker.swarm.service.name=data_postgres" --format '{{.ID}}' | head -1)
if [ -z "$CONTAINER" ]; then
  echo "Error: no running data_postgres container found. Is the data stack deployed?" >&2
  exit 1
fi

ROLE_EXISTS=$(docker exec "$CONTAINER" psql -U postgres -tAc \
  "SELECT 1 FROM pg_roles WHERE rolname = '$ROLE'")

DB_COUNT=0
for DB in "${DATABASES[@]}"; do
  if [ -n "$(docker exec "$CONTAINER" psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$DB'")" ]; then
    DB_COUNT=$((DB_COUNT + 1))
  fi
done

if docker secret inspect "$SECRET_NAME" >/dev/null 2>&1; then
  SECRET_EXISTS=1
else
  SECRET_EXISTS=""
fi

if [ -n "$ROLE_EXISTS" ] && [ "$DB_COUNT" -eq "${#DATABASES[@]}" ] && [ -n "$SECRET_EXISTS" ]; then
  echo "Role '$ROLE', all ${#DATABASES[@]} databases, and secret already exist — nothing to do."
  exit 0
fi

if [ -n "$ROLE_EXISTS" ] || [ "$DB_COUNT" -gt 0 ] || [ -n "$SECRET_EXISTS" ]; then
  if [ -z "$ROLE_EXISTS" ] || [ "$DB_COUNT" -ne "${#DATABASES[@]}" ] || [ -z "$SECRET_EXISTS" ]; then
    echo "Error: inconsistent state for '$ROLE' — role exists: ${ROLE_EXISTS:+yes}, databases present: $DB_COUNT/${#DATABASES[@]}, secret exists: ${SECRET_EXISTS:+yes}." >&2
    echo "Resolve manually (drop the role/databases, or remove the secret) before re-running." >&2
    exit 1
  fi
fi

PASSWORD=$(openssl rand -base64 32)

docker exec -i "$CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 <<SQL
CREATE ROLE "$ROLE" LOGIN PASSWORD '$PASSWORD';
SQL

for DB in "${DATABASES[@]}"; do
  docker exec -i "$CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 <<SQL
CREATE DATABASE "$DB" OWNER "$ROLE";
REVOKE ALL ON DATABASE "$DB" FROM PUBLIC;
SQL
done

printf '%s' "$PASSWORD" | docker secret create "$SECRET_NAME" - >/dev/null

echo "Created role '$ROLE', databases (${DATABASES[*]}), and secret '$SECRET_NAME'."
echo
echo "test_princess also needs this same password added as a masked/protected"
echo "GitLab CI/CD variable (e.g. PRINCESS_TEST_DB_PASSWORD) on the princess_backend"
echo "project, for the CI test suite to reach it — that's a GitLab project setting,"
echo "not something this script can provision."
