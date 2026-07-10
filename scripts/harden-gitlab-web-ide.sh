#!/usr/bin/env bash
# Disables the VS Code extension marketplace's "single origin fallback".
#
# GitLab's Web IDE normally loads its extension host from a separate
# origin, for the same reason browser extensions get sandboxed away from
# the page they run on. If that separate domain is ever unreachable,
# GitLab falls back to serving those assets from GitLab's own origin —
# which defeats the isolation and is exactly what GitLab's own admin
# dashboard flags as a high-severity risk. Turning the fallback off is
# GitLab's own recommended fix (the alternative being to guarantee the
# extension host domain is always reachable instead).
#
# Database-backed Application Setting, not a gitlab.rb/Omnibus key. Safe
# to re-run.
set -euo pipefail

CONTAINER=$(docker ps --filter "label=com.docker.swarm.service.name=gitlab_gitlab" --format '{{.ID}}' | head -1)
if [ -z "$CONTAINER" ]; then
  echo "Error: no running gitlab_gitlab container found. Is the gitlab stack deployed?" >&2
  exit 1
fi

docker exec "$CONTAINER" gitlab-rails runner "
  ApplicationSetting.current.update!(vscode_extension_marketplace_single_origin_fallback_enabled: false)
  puts 'vscode_extension_marketplace_single_origin_fallback_enabled: ' + ApplicationSetting.current.vscode_extension_marketplace_single_origin_fallback_enabled.to_s
"
