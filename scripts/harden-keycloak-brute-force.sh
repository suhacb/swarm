#!/usr/bin/env bash
# Enables Keycloak's brute-force detection for a realm, with a tighter
# failureFactor than Keycloak's default (30 -> 5). With MFA already
# required realm-wide, this only protects the password step — 5 failed
# attempts is enough margin for a real user who knows their own password,
# without leaving much room for sustained guessing.
#
# Usage: ./scripts/harden-keycloak-brute-force.sh <realm> [<realm> ...]
# Idempotent — safe to re-run.
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "Usage: $0 <realm> [<realm> ...]" >&2
  exit 1
fi

CONTAINER=$(docker ps --filter "label=com.docker.swarm.service.name=infra_keycloak" --format '{{.ID}}' | head -1)
if [ -z "$CONTAINER" ]; then
  echo "Error: no running infra_keycloak container found." >&2
  exit 1
fi

kcadm() {
  docker exec "$CONTAINER" /opt/keycloak/bin/kcadm.sh "$@"
}

AUTOMATION_SECRET=$(docker exec "$CONTAINER" cat /run/secrets/keycloak_automation_client_secret)
kcadm config credentials --server http://localhost:8080 --realm master \
  --client automation-cli --secret "$AUTOMATION_SECRET"

for REALM in "$@"; do
  kcadm update "realms/$REALM" -s bruteForceProtected=true -s permanentLockout=false -s failureFactor=5
  echo "Brute-force protection enabled for realm '$REALM' (failureFactor=5, temporary lockout)."
done
