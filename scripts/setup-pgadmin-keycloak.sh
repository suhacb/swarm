#!/usr/bin/env bash
# Provisions the Keycloak side of pgAdmin's SSO gate: a confidential OIDC
# client in the EXISTING suhacb realm. Deliberately its own script, not
# folded into setup-princess-keycloak.sh — pgAdmin gates access to the
# whole shared Postgres server, not just princess's databases, so it's a
# general-infra client, not a princess-specific one.
#
# Usage: ./scripts/setup-pgadmin-keycloak.sh
# Idempotent: leaves an existing client's secret alone, always re-enforces
# its redirect URI.
set -euo pipefail

REALM="suhacb"
CLIENT_ID="pgadmin"
# Exact match, not a wildcard: pgAdmin only ever redirects back to this one
# fixed OAuth2 callback path (per pgAdmin4's docs), no reason to allow more.
REDIRECT="https://pg.suhac.eu/oauth2/authorize"

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

CLIENT_UUID=$(kcadm get clients -r "$REALM" -q "clientId=$CLIENT_ID" --fields id --format csv --noquotes | tail -n1)
if [ -n "$CLIENT_UUID" ]; then
  echo "Client '$CLIENT_ID' already exists in realm '$REALM' — leaving its secret alone."
else
  CLIENT_UUID=$(kcadm create clients -r "$REALM" -i \
    -s clientId="$CLIENT_ID" \
    -s protocol=openid-connect \
    -s publicClient=false \
    -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=false)
  CLIENT_SECRET=$(kcadm get "clients/$CLIENT_UUID/client-secret" -r "$REALM" --fields value --format csv --noquotes | tail -n1)
  printf '%s' "$CLIENT_SECRET" | docker secret create pgadmin_keycloak_client_secret -
  echo "Created client '$CLIENT_ID' and secret 'pgadmin_keycloak_client_secret'."
fi

kcadm update "clients/$CLIENT_UUID" -r "$REALM" \
  -s "redirectUris=[\"$REDIRECT\"]" \
  -s 'webOrigins=["https://pg.suhac.eu"]'

# Lets Keycloak's logout endpoint accept client_id + post_logout_redirect_uri
# without needing an id_token_hint — used by config/pgadmin's
# OAUTH2_LOGOUT_URL so pgAdmin's own Sign Out also ends the Keycloak SSO
# session, instead of leaving it alive (same gap GitLab had — see
# configure-gitlab-sso-logout.sh — confirmed live: without this, switching
# between pgAdmin/Qdrant/ZincSearch/Garage's separate dedicated accounts in
# one browser silently kept reusing whichever was logged in last).
kcadm update "clients/$CLIENT_UUID" -r "$REALM" \
  -s 'attributes."post.logout.redirect.uris"="https://pg.suhac.eu/*"'

echo "Done."
