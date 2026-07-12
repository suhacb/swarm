#!/usr/bin/env bash
# Provisions the Keycloak side of the princess service:
#
# Production — additions to the EXISTING suhacb realm:
#   - Realm roles princess-admin, princess-user
#   - Groups princess-admins, princess-users, each with the matching realm
#     role attached via group role-mapping (so membership grants the role,
#     surfaced in realm_access.roles via the default "roles" client scope)
#   - suhacb added to princess-users only
#   - Confidential client princess-client, redirect https://princess.suhac.eu/*
#
# Staging — a NEW princess-test realm:
#   - Password policy: length(12) and upperCase(1) and digits(1)
#   - No MFA anywhere in this realm (test users need frictionless repeat
#     logins) — but STILL needs the same browser-flow reorder fix as
#     setup-gitlab-keycloak.sh, because that NPE is a bug in this Keycloak
#     version's default new-realm flow ordering, unrelated to whether MFA
#     is actually required. Skipping it would break every login, MFA or not.
#   - Same princess-admin/princess-user roles + groups as prod
#   - Confidential client princess-client, redirect https://staging.princess.suhac.eu/*
#   - 11 test users from config/princess/test-users.csv (gitignored — real
#     credentials never enter git on this public repo), passwords set
#     directly and PERMANENT (no forced reset, no TOTP) since these need to
#     be reusable across many manual test sessions, not one-time bootstrap
#     accounts.
#
# Usage: ./scripts/setup-princess-keycloak.sh
# Idempotent: skips anything that already exists. Prints any client secret
# it generates — write it down, it's shown once.
#
# Authenticates as the automation-cli service account (master realm), same
# as setup-gitlab-keycloak.sh — see docs/DEPLOY.md for how that was
# bootstrapped.
set -euo pipefail

PROD_REALM="suhacb"
TEST_REALM="princess-test"
TEST_USERS_CSV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config/princess/test-users.csv"

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
  local REALM="$1" NAME="$2"
  kcadm get groups -r "$REALM" -q "search=$NAME" --fields id,name --format csv --noquotes \
    | awk -F, -v n="$NAME" '$2==n {print $1}'
}

ensure_role() {
  local REALM="$1" ROLE="$2"
  if kcadm get "roles/$ROLE" -r "$REALM" >/dev/null 2>&1; then
    echo "Role '$ROLE' already exists in realm '$REALM'."
  else
    kcadm create roles -r "$REALM" -s name="$ROLE"
    echo "Created role '$ROLE' in realm '$REALM'."
  fi
}

ensure_group_with_role() {
  local REALM="$1" GROUP="$2" ROLE="$3" GROUP_ID
  GROUP_ID=$(get_group_id "$REALM" "$GROUP")
  if [ -z "$GROUP_ID" ]; then
    GROUP_ID=$(kcadm create groups -r "$REALM" -s name="$GROUP" -i)
    echo "Created group '$GROUP' in realm '$REALM'."
  else
    echo "Group '$GROUP' already exists in realm '$REALM'."
  fi

  local CURRENT_ROLES
  CURRENT_ROLES=$(kcadm get "groups/$GROUP_ID/role-mappings/realm" -r "$REALM" --fields name --format csv --noquotes)
  if echo "$CURRENT_ROLES" | grep -qx "$ROLE"; then
    echo "Group '$GROUP' already has role '$ROLE'."
  else
    # kcadm's "-o" flag hits a CLI bug ("Missing required parameter for
    # option '--offset'") on this endpoint in this Keycloak version — build
    # the role-mappings body manually from id+name instead of relying on it.
    local ROLE_ID
    ROLE_ID=$(kcadm get "roles/$ROLE" -r "$REALM" --fields id --format csv --noquotes)
    kcadm create "groups/$GROUP_ID/role-mappings/realm" -r "$REALM" \
      -b "[{\"id\":\"$ROLE_ID\",\"name\":\"$ROLE\"}]"
    echo "Attached role '$ROLE' to group '$GROUP'."
  fi
}

add_user_to_group() {
  local REALM="$1" USERNAME="$2" GROUP="$3" USER_ID GROUP_ID CURRENT_GROUPS
  USER_ID=$(kcadm get users -r "$REALM" -q "username=$USERNAME" --fields id --format csv --noquotes | tail -n1)
  if [ -z "$USER_ID" ]; then
    echo "Error: user '$USERNAME' not found in realm '$REALM'." >&2
    exit 1
  fi
  GROUP_ID=$(get_group_id "$REALM" "$GROUP")
  CURRENT_GROUPS=$(kcadm get "users/$USER_ID/groups" -r "$REALM" --fields name --format csv --noquotes)
  if echo "$CURRENT_GROUPS" | grep -qx "$GROUP"; then
    echo "User '$USERNAME' already in group '$GROUP'."
  else
    kcadm update "users/$USER_ID/groups/$GROUP_ID" -r "$REALM" -b '{}'
    echo "Added '$USERNAME' to group '$GROUP'."
  fi
}

ensure_client() {
  # Creates (or leaves alone) a confidential OIDC client, always enforcing
  # redirect/web-origin so re-running fixes an existing client too — same
  # pattern as setup-gitlab-keycloak.sh.
  local REALM="$1" CLIENT_ID="$2" REDIRECT="$3" ORIGIN="$4" SECRET_NAME="$5" CLIENT_UUID
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
    local CLIENT_SECRET
    CLIENT_SECRET=$(kcadm get "clients/$CLIENT_UUID/client-secret" -r "$REALM" --fields value --format csv --noquotes | tail -n1)
    printf '%s' "$CLIENT_SECRET" | docker secret create "$SECRET_NAME" -
    echo "Created client '$CLIENT_ID' in realm '$REALM' and secret '$SECRET_NAME'."
  fi
  kcadm update "clients/$CLIENT_UUID" -r "$REALM" \
    -s "redirectUris=[\"$REDIRECT\"]" \
    -s "webOrigins=[\"$ORIGIN\"]"
}

ensure_reordered_browser_flow() {
  # Same fix as setup-gitlab-keycloak.sh: new realms get "Browser -
  # Conditional OTP" ordered BEFORE "Username Password Form", which throws
  # a NullPointerException checking a not-yet-identified user's OTP config
  # before the login form even renders. Applies regardless of whether MFA
  # is actually required in this realm.
  local REALM="$1"
  local CUSTOM_FLOW="browser-$REALM" CURRENT_FLOW
  CURRENT_FLOW=$(kcadm get "realms/$REALM" --fields browserFlow --format csv --noquotes)
  if [ "$CURRENT_FLOW" = "$CUSTOM_FLOW" ]; then
    echo "Realm '$REALM' already uses the reordered browser flow '$CUSTOM_FLOW'."
  else
    kcadm create "authentication/flows/browser/copy" -r "$REALM" -s newName="$CUSTOM_FLOW"
    local PWD_FORM_EXEC_ID
    PWD_FORM_EXEC_ID=$(kcadm get "authentication/flows/$CUSTOM_FLOW/executions" -r "$REALM" \
      --fields id,displayName --format csv --noquotes | awk -F, '$2=="Username Password Form" {print $1}')
    kcadm create "authentication/executions/$PWD_FORM_EXEC_ID/raise-priority" -r "$REALM" -b '{}'
    kcadm update "realms/$REALM" -s browserFlow="$CUSTOM_FLOW"
    echo "Created and activated reordered browser flow '$CUSTOM_FLOW' for realm '$REALM'."
  fi
}

# ============================================================
# Production: suhacb realm additions
# ============================================================

ensure_role "$PROD_REALM" princess-admin
ensure_role "$PROD_REALM" princess-user
ensure_group_with_role "$PROD_REALM" princess-admins princess-admin
ensure_group_with_role "$PROD_REALM" princess-users princess-user
add_user_to_group "$PROD_REALM" suhacb princess-users
ensure_client "$PROD_REALM" princess-client \
  "https://princess.suhac.eu/*" "https://princess.suhac.eu" \
  princess_keycloak_client_secret

# ============================================================
# Staging: new princess-test realm
# ============================================================

if kcadm get "realms/$TEST_REALM" >/dev/null 2>&1; then
  echo "Realm '$TEST_REALM' already exists."
else
  kcadm create realms -s realm="$TEST_REALM" -s enabled=true
  echo "Created realm '$TEST_REALM'."
fi

kcadm update "realms/$TEST_REALM" -s 'passwordPolicy=length(12) and upperCase(1) and digits(1)'

ensure_reordered_browser_flow "$TEST_REALM"

ensure_role "$TEST_REALM" princess-admin
ensure_role "$TEST_REALM" princess-user
ensure_group_with_role "$TEST_REALM" princess-admins princess-admin
ensure_group_with_role "$TEST_REALM" princess-users princess-user

ensure_client "$TEST_REALM" princess-client \
  "https://staging.princess.suhac.eu/*" "https://staging.princess.suhac.eu" \
  princess_test_keycloak_client_secret

if [ ! -f "$TEST_USERS_CSV" ]; then
  echo "Error: $TEST_USERS_CSV not found — create it before running this script (gitignored, not committed)." >&2
  exit 1
fi

# username,full_name,project_role,group,password
tail -n +2 "$TEST_USERS_CSV" | while IFS=',' read -r USERNAME FULL_NAME PROJECT_ROLE GROUP PASSWORD; do
  [ -z "$USERNAME" ] && continue
  USER_ID=$(kcadm get users -r "$TEST_REALM" -q "username=$USERNAME" --fields id --format csv --noquotes | tail -n1)
  if [ -z "$USER_ID" ]; then
    FIRST_NAME="${FULL_NAME%% *}"
    LAST_NAME="${FULL_NAME#* }"
    USER_ID=$(kcadm create users -r "$TEST_REALM" -i \
      -s username="$USERNAME" \
      -s enabled=true \
      -s firstName="$FIRST_NAME" \
      -s lastName="$LAST_NAME" \
      -s email="${USERNAME}@princess-test.suhac.eu" \
      -s emailVerified=true \
      -s attributes.projectRole="[\"$PROJECT_ROLE\"]")
    # temporary=false and no requiredActions: this realm has no MFA, and
    # these accounts are meant to be reused across many manual test
    # sessions, not reset on first login like the human admin bootstraps.
    kcadm set-password -r "$TEST_REALM" --userid "$USER_ID" --new-password "$PASSWORD"
    echo "Created test user '$USERNAME' ($PROJECT_ROLE)."
  else
    echo "Test user '$USERNAME' already exists."
  fi
  add_user_to_group "$TEST_REALM" "$USERNAME" "$GROUP"
done

echo "Done."
