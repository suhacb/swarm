#!/usr/bin/env bash
# Makes GitLab sign-out also end the Keycloak SSO session (RP-initiated
# / "single" logout), instead of just destroying GitLab's own session
# cookie and leaving Keycloak's session alive — which otherwise means
# "sign in with Keycloak" again silently re-authenticates as whoever was
# last logged in, without asking.
#
# "After sign-out path" is a database-backed Application Setting, NOT a
# gitlab.rb/Omnibus key — setting gitlab_rails['after_sign_out_path'] in
# gitlab.rb looks plausible but silently does nothing. This has to be
# applied via gitlab-rails against the running instance instead.
#
# Requires scripts/setup-gitlab-keycloak.sh to have already run at least
# once (registers the client's post.logout.redirect.uris Keycloak needs to
# accept this without an id_token_hint). Safe to re-run.
set -euo pipefail

REALM="suhacb"
CLIENT_ID="gitlab"
GITLAB_HOSTNAME="gitlab.suhac.eu"
KEYCLOAK_HOSTNAME="keycloak.suhac.eu"

CONTAINER=$(docker ps --filter "label=com.docker.swarm.service.name=gitlab_gitlab" --format '{{.ID}}' | head -1)
if [ -z "$CONTAINER" ]; then
  echo "Error: no running gitlab_gitlab container found. Is the gitlab stack deployed?" >&2
  exit 1
fi

LOGOUT_URL="https://${KEYCLOAK_HOSTNAME}/realms/${REALM}/protocol/openid-connect/logout?client_id=${CLIENT_ID}&post_logout_redirect_uri=https%3A%2F%2F${GITLAB_HOSTNAME}%2Fusers%2Fsign_in"

docker exec "$CONTAINER" gitlab-rails runner "
  ApplicationSetting.current.update!(after_sign_out_path: '${LOGOUT_URL}')
  puts 'after_sign_out_path set to: ' + ApplicationSetting.current.after_sign_out_path
"
