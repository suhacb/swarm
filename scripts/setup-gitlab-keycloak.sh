#!/usr/bin/env bash
# Provisions the Keycloak side of GitLab SSO: a dedicated realm (separate
# from master), two groups, two users with mandatory MFA, and a confidential
# OIDC client GitLab logs in against.
#
# Usage: ./scripts/setup-gitlab-keycloak.sh
# Idempotent: skips anything that already exists. Prints the initial
# (temporary) password for any user it creates — write it down, it's shown
# once.
#
# Authenticates as the automation-cli service account (master realm), not a
# human admin — kcadm's direct-grant login can't supply a live TOTP code, so
# it can't be used once an admin account actually has MFA enrolled. See
# docs/DEPLOY.md for how automation-cli was bootstrapped.
set -euo pipefail

REALM="suhacb"

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

# --- Realm ---
if kcadm get "realms/$REALM" >/dev/null 2>&1; then
  echo "Realm '$REALM' already exists."
else
  kcadm create realms -s realm="$REALM" -s enabled=true
  echo "Created realm '$REALM'."
fi

# --- MFA ---
# Deliberately NOT touching the "Browser - Conditional OTP" subflow here.
# It's a CONDITIONAL subflow gated by a "Condition - user configured OTP"
# check — that check only makes sense once a user has been identified
# (i.e. after username/password), so flipping the subflow itself to
# REQUIRED breaks the gate: Keycloak then tries to evaluate "does the user
# have OTP" before any user exists yet, throwing invalid_user_credentials
# on the very first request, before the login form even renders. (Found
# this the hard way — see commit history.)
#
# The CONFIGURE_TOTP required action set on every user below already gets
# the same practical outcome without touching the flow at all: it forces
# MFA enrollment on that user's first login, and once they have OTP
# configured, the existing conditional check requires it on every login
# after that — which is the standard, correct mechanism.

# --- Fix a real ordering bug in this Keycloak version's new-realm browser
# flow: "Browser - Conditional OTP" is ordered BEFORE "Username Password
# Form" in the "forms" subflow (master realm has them the other way
# around) — meaning the OTP condition tries to check a user that doesn't
# exist yet, throwing a NullPointerException before the login form even
# renders. The built-in flow can't be reordered directly (Keycloak refuses
# to restructure built-in flows), so this duplicates it into an editable
# custom flow, fixes the order there, and points the realm at the copy. ---
CUSTOM_BROWSER_FLOW="browser-$REALM"
CURRENT_BROWSER_FLOW=$(kcadm get "realms/$REALM" --fields browserFlow --format csv --noquotes)
if [ "$CURRENT_BROWSER_FLOW" = "$CUSTOM_BROWSER_FLOW" ]; then
  echo "Realm '$REALM' already uses the reordered browser flow '$CUSTOM_BROWSER_FLOW'."
else
  kcadm create authentication/flows/browser/copy -r "$REALM" -s newName="$CUSTOM_BROWSER_FLOW"
  PWD_FORM_EXEC_ID=$(kcadm get "authentication/flows/$CUSTOM_BROWSER_FLOW/executions" -r "$REALM" \
    --fields id,displayName --format csv --noquotes | awk -F, '$2=="Username Password Form" {print $1}')
  kcadm create "authentication/executions/$PWD_FORM_EXEC_ID/raise-priority" -r "$REALM" -b '{}'
  kcadm update "realms/$REALM" -s browserFlow="$CUSTOM_BROWSER_FLOW"
  echo "Created and activated reordered browser flow '$CUSTOM_BROWSER_FLOW' for realm '$REALM'."
fi

# --- Groups ---
get_group_id() {
  kcadm get groups -r "$REALM" -q "search=$1" --fields id,name --format csv --noquotes \
    | awk -F, -v n="$1" '$2==n {print $1}'
}

for GROUP in gitlab-admins gitlab-users; do
  if [ -n "$(get_group_id "$GROUP")" ]; then
    echo "Group '$GROUP' already exists."
  else
    kcadm create groups -r "$REALM" -s name="$GROUP"
    echo "Created group '$GROUP'."
  fi
done

# --- Users (username -> group) ---
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
    # Set and print the password immediately — if anything below this point
    # fails, the account still has a known, usable password rather than a
    # generated one nobody ever saw.
    kcadm set-password -r "$REALM" --userid "$USER_ID" --new-password "$TEMP_PASSWORD" --temporary
    echo "Created user '$USERNAME'. Temporary password: $TEMP_PASSWORD"
    echo "  (forced password reset + TOTP enrollment on first login)"
  else
    echo "User '$USERNAME' already exists."
  fi

  # Checked even for a pre-existing user: guards against a prior run having
  # created the user but failed before reaching group assignment.
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

create_user_if_missing gitlab-admin gitlab-admins
create_user_if_missing suhacb gitlab-users

# --- OIDC client for GitLab ---
CLIENT_ID="gitlab"
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

  # Exposes group membership (gitlab-admins/gitlab-users) as a "groups"
  # claim — GitLab CE doesn't reliably auto-promote admins from this (that's
  # a SAML/paid-tier feature), but it's useful for anything else that reads
  # it later, and cheap to have.
  kcadm create "clients/$CLIENT_UUID/protocol-mappers/models" -r "$REALM" \
    -s name=groups \
    -s protocol=openid-connect \
    -s protocolMapper=oidc-group-membership-mapper \
    -s 'config."full.path"=false' \
    -s 'config."id.token.claim"=true' \
    -s 'config."access.token.claim"=true' \
    -s 'config."userinfo.token.claim"=true' \
    -s 'config."claim.name"=groups'

  CLIENT_SECRET=$(kcadm get "clients/$CLIENT_UUID/client-secret" -r "$REALM" --fields value --format csv --noquotes | tail -n1)
  printf '%s' "$CLIENT_SECRET" | docker secret create gitlab_oidc_client_secret -
  echo "Created client '$CLIENT_ID' and secret 'gitlab_oidc_client_secret'."
fi

# Always enforced (not just at creation) so re-running this script fixes
# an existing client too — e.g. dropping a hostname requires updating this
# regardless of whether the client already existed.
kcadm update "clients/$CLIENT_UUID" -r "$REALM" \
  -s 'redirectUris=["https://gitlab.suhac.eu/users/auth/openid_connect/callback"]' \
  -s 'webOrigins=["https://gitlab.suhac.eu"]'

# Lets Keycloak's logout endpoint accept client_id + post_logout_redirect_uri
# without needing an id_token_hint — used by gitlab.rb's after_sign_out_path
# to make GitLab's sign-out also end the Keycloak SSO session, instead of
# leaving it alive so the next "sign in with Keycloak" silently
# re-authenticates as whoever was last logged in without asking.
kcadm update "clients/$CLIENT_UUID" -r "$REALM" \
  -s 'attributes."post.logout.redirect.uris"="https://gitlab.suhac.eu/users/sign_in"'

echo "Done."
