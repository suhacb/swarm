#!/usr/bin/env bash
# Promotes a GitLab user (default: gitlab-admin) to Administrator.
#
# Run this AFTER that user has logged into GitLab via Keycloak SSO at least
# once — GitLab only creates the local user record on first login, so
# there's nothing to promote before that.
#
# GitLab CE doesn't reliably auto-promote admins from an OIDC group claim
# (group-based admin sync is a SAML/paid-tier feature) — this is the
# guaranteed-to-work alternative. Safe to re-run.
set -euo pipefail

USERNAME="${1:-gitlab-admin}"

CONTAINER=$(docker ps --filter "label=com.docker.swarm.service.name=gitlab_gitlab" --format '{{.ID}}' | head -1)
if [ -z "$CONTAINER" ]; then
  echo "Error: no running gitlab_gitlab container found. Is the gitlab stack deployed?" >&2
  exit 1
fi

docker exec "$CONTAINER" gitlab-rails runner "
  user = User.find_by(username: '$USERNAME')
  if user.nil?
    puts \"Error: no GitLab user '$USERNAME' found — have they logged in via Keycloak at least once?\"
    exit 1
  elsif user.admin?
    puts \"'$USERNAME' is already a GitLab admin.\"
  else
    user.update!(admin: true)
    puts \"'$USERNAME' is now a GitLab admin.\"
  end
"
