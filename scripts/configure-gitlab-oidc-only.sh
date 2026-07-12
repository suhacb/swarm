#!/usr/bin/env bash
# Makes Keycloak the only way to get into or onto GitLab: disables local
# username/password authentication for both the web UI and git-over-HTTP
# (Personal Access Tokens are a separate mechanism and are NOT affected —
# this only turns off literal password-based auth), and disables open
# self-registration (GitLab warns about this by default; also pointless
# once nothing can log in with a self-set password anyway). All three are
# database-backed Application Settings, not gitlab.rb/Omnibus keys.
#
# The built-in `root` account is NOT deleted or blocked — it becomes
# unreachable from the web (nothing to log into with, once password auth
# is off) but remains available as a break-glass account via
# `gitlab-rails console`/`runner` directly on the server, independent of
# Keycloak. Recommended to keep rather than delete, in case Keycloak
# itself is ever unreachable.
#
# gitlab_rails['omniauth_auto_sign_in_with_provider'] in gitlab.rb (applied
# separately via gitlab-ctl reconfigure) skips GitLab's own sign-in page
# entirely, going straight to Keycloak. Safe to re-run.
set -euo pipefail

CONTAINER=$(docker ps --filter "label=com.docker.swarm.service.name=gitlab_gitlab" --format '{{.ID}}' | head -1)
if [ -z "$CONTAINER" ]; then
  echo "Error: no running gitlab_gitlab container found. Is the gitlab stack deployed?" >&2
  exit 1
fi

docker exec "$CONTAINER" gitlab-rails runner "
  ApplicationSetting.current.update!(
    password_authentication_enabled_for_web: false,
    password_authentication_enabled_for_git: false,
    signup_enabled: false
  )
  s = ApplicationSetting.current
  puts 'password_authentication_enabled_for_web: ' + s.password_authentication_enabled_for_web.to_s
  puts 'password_authentication_enabled_for_git: ' + s.password_authentication_enabled_for_git.to_s
  puts 'signup_enabled: ' + s.signup_enabled.to_s
"

echo "Also confirm gitlab_rails['omniauth_auto_sign_in_with_provider'] = 'openid_connect' is set in"
echo "/opt/swarm-data/gitlab/config/gitlab.rb and run 'gitlab-ctl reconfigure' inside the container —"
echo "that part is a gitlab.rb key, not something this script can apply from the outside."
