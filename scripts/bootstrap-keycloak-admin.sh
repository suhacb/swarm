#!/usr/bin/env bash
# Run once after the FIRST deploy of infrastructure-stack.yml (i.e. right
# after the keycloak_admin_password secret's value has actually been used to
# create the account). Forces the suhacb admin account to set its own
# password and enroll TOTP (Google Authenticator, or any RFC 6238 app) on
# its next login. Safe to re-run — it just re-applies the same two required
# actions.
set -euo pipefail

ADMIN_USER="suhacb"

CONTAINER=$(docker ps --filter "label=com.docker.swarm.service.name=infra_keycloak" --format '{{.ID}}' | head -1)
if [ -z "$CONTAINER" ]; then
  echo "Error: no running infra_keycloak container found. Is the infra stack deployed?" >&2
  exit 1
fi

read -rsp "Current password for '$ADMIN_USER' (the one in the keycloak_admin_password secret): " ADMIN_PASSWORD
echo

docker exec "$CONTAINER" /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 --realm master \
  --user "$ADMIN_USER" --password "$ADMIN_PASSWORD"

USER_ID=$(docker exec "$CONTAINER" /opt/keycloak/bin/kcadm.sh get users \
  -r master -q "username=$ADMIN_USER" --fields id --format csv --noquotes | tail -n1)

if [ -z "$USER_ID" ]; then
  echo "Error: could not find user '$ADMIN_USER' in the master realm." >&2
  exit 1
fi

docker exec "$CONTAINER" /opt/keycloak/bin/kcadm.sh update "users/$USER_ID" -r master \
  -s 'requiredActions=["UPDATE_PASSWORD","CONFIGURE_TOTP"]'

echo "Done. '$ADMIN_USER' will be required to set a new password and enroll TOTP on next login."
