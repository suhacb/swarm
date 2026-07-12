#!/usr/bin/env bash
# Provisions the Keycloak side of gating pgAdmin/Qdrant/ZincSearch/Garage's
# admin UIs, in the EXISTING suhacb realm:
#
#   - Confidential client `oauth2-proxy` (the shared gatekeeper in front of
#     Qdrant/ZincSearch/Garage's web UIs — pgAdmin keeps its own native
#     OIDC from Phase 3, doesn't go through oauth2-proxy), redirect URIs
#     for all three /oauth2/callback paths, with a "groups" claim mapper
#     (same oidc-group-membership-mapper pattern as GitLab's client).
#   - A matching "groups" mapper added to the EXISTING pgadmin client,
#     which didn't have one — needed for pgAdmin's own
#     OAUTH2_ADDITIONAL_CLAIMS check (config/pgadmin/config_local.py.template)
#     to actually see group membership.
#   - Four groups (pgadmin-admins, qdrant-admins, zinc-admins,
#     garage-admins) and one dedicated, non-obvious-username user per
#     group — deliberately separate identities per tool, not one shared
#     "infra-admins" group, so a compromised credential for one tool
#     doesn't expose the other three. Nginx enforces which group is
#     required per hostname (see config/nginx/conf.d/infra-tools.conf);
#     oauth2-proxy itself does no group filtering, only authentication.
#   - These are sensitive admin-tool accounts in the same realm as
#     gitlab-admin — same bar applies: forced password reset + mandatory
#     TOTP on first login (NOT the relaxed no-MFA princess-test pattern).
#
# Usage: ./scripts/setup-infra-tools-keycloak.sh
# Idempotent: skips anything that already exists, prints any generated
# password/secret once.
set -euo pipefail

REALM="suhacb"

# "username:group" pairs — not an associative array: the default /bin/bash
# on macOS is 3.2 (no declare -A support, no Homebrew bash installed here).
TOOL_USERS=(
  "corvid:pgadmin-admins"
  "solder:qdrant-admins"
  "lintel:zinc-admins"
  "quern:garage-admins"
)

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

get_group_id() {
  kcadm get groups -r "$REALM" -q "search=$1" --fields id,name --format csv --noquotes \
    | awk -F, -v n="$1" '$2==n {print $1}'
}

add_groups_mapper() {
  # Same oidc-group-membership-mapper used for GitLab's client — exposes
  # group membership (unqualified names, not full paths) as a "groups"
  # claim in the ID token, access token, and userinfo response.
  local CLIENT_UUID="$1"
  local EXISTING
  EXISTING=$(kcadm get "clients/$CLIENT_UUID/protocol-mappers/models" -r "$REALM" \
    --fields name --format csv --noquotes | grep -qx "groups" && echo yes || true)
  if [ -n "$EXISTING" ]; then
    echo "Client already has a 'groups' mapper."
  else
    kcadm create "clients/$CLIENT_UUID/protocol-mappers/models" -r "$REALM" \
      -s name=groups \
      -s protocol=openid-connect \
      -s protocolMapper=oidc-group-membership-mapper \
      -s 'config."full.path"=false' \
      -s 'config."id.token.claim"=true' \
      -s 'config."access.token.claim"=true' \
      -s 'config."userinfo.token.claim"=true' \
      -s 'config."claim.name"=groups'
    echo "Added 'groups' mapper."
  fi
}

ensure_group() {
  local GROUP="$1"
  if [ -n "$(get_group_id "$GROUP")" ]; then
    echo "Group '$GROUP' already exists."
  else
    kcadm create groups -r "$REALM" -s name="$GROUP"
    echo "Created group '$GROUP'."
  fi
}

create_user_if_missing() {
  local USERNAME="$1" GROUP="$2"
  local USER_ID
  USER_ID=$(kcadm get users -r "$REALM" -q "username=$USERNAME" --fields id --format csv --noquotes | tail -n1)

  if [ -z "$USER_ID" ]; then
    local TEMP_PASSWORD
    TEMP_PASSWORD=$(openssl rand -base64 18)
    USER_ID=$(kcadm create users -r "$REALM" -i \
      -s username="$USERNAME" \
      -s enabled=true \
      -s email="${USERNAME}@suhac.eu" \
      -s emailVerified=true \
      -s 'requiredActions=["UPDATE_PASSWORD","CONFIGURE_TOTP"]')
    kcadm set-password -r "$REALM" --userid "$USER_ID" --new-password "$TEMP_PASSWORD" --temporary
    echo "Created user '$USERNAME'. Temporary password: $TEMP_PASSWORD"
    echo "  (forced password reset + TOTP enrollment on first login)"
  else
    echo "User '$USERNAME' already exists."
  fi

  local GROUP_ID CURRENT_GROUPS
  GROUP_ID=$(get_group_id "$GROUP")
  CURRENT_GROUPS=$(kcadm get "users/$USER_ID/groups" -r "$REALM" --fields name --format csv --noquotes)
  if echo "$CURRENT_GROUPS" | grep -qx "$GROUP"; then
    echo "User '$USERNAME' already in group '$GROUP'."
  else
    kcadm update "users/$USER_ID/groups/$GROUP_ID" -r "$REALM" -b '{}'
    echo "Added '$USERNAME' to group '$GROUP'."
  fi
}

# --- oauth2-proxy client ---
CLIENT_ID="oauth2-proxy"
CLIENT_UUID=$(kcadm get clients -r "$REALM" -q "clientId=$CLIENT_ID" --fields id --format csv --noquotes | tail -n1)
if [ -n "$CLIENT_UUID" ]; then
  echo "Client '$CLIENT_ID' already exists — leaving its secret alone."
else
  CLIENT_UUID=$(kcadm create clients -r "$REALM" -i \
    -s clientId="$CLIENT_ID" \
    -s protocol=openid-connect \
    -s publicClient=false \
    -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=false)
  CLIENT_SECRET=$(kcadm get "clients/$CLIENT_UUID/client-secret" -r "$REALM" --fields value --format csv --noquotes | tail -n1)
  printf '%s' "$CLIENT_SECRET" | docker secret create oauth2_proxy_client_secret -
  echo "Created client '$CLIENT_ID' and secret 'oauth2_proxy_client_secret'."
fi
kcadm update "clients/$CLIENT_UUID" -r "$REALM" \
  -s 'redirectUris=["https://zinc.suhac.eu/oauth2/callback","https://qdrant.suhac.eu/oauth2/callback","https://garage.suhac.eu/oauth2/callback"]' \
  -s 'webOrigins=["https://zinc.suhac.eu","https://qdrant.suhac.eu","https://garage.suhac.eu"]'
add_groups_mapper "$CLIENT_UUID"

# --- pgadmin client: add the groups mapper it's missing ---
PGADMIN_CLIENT_UUID=$(kcadm get clients -r "$REALM" -q "clientId=pgadmin" --fields id --format csv --noquotes | tail -n1)
if [ -z "$PGADMIN_CLIENT_UUID" ]; then
  echo "Error: 'pgadmin' client not found — run scripts/setup-pgadmin-keycloak.sh first." >&2
  exit 1
fi
add_groups_mapper "$PGADMIN_CLIENT_UUID"

# --- groups + users ---
for PAIR in "${TOOL_USERS[@]}"; do
  ensure_group "${PAIR#*:}"
done
for PAIR in "${TOOL_USERS[@]}"; do
  create_user_if_missing "${PAIR%:*}" "${PAIR#*:}"
done

echo "Done."
