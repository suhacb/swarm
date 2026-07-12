#!/usr/bin/env bash
# Enables GitLab project import sources — a fresh instance ships with none
# enabled at all ("No import options available" in the UI until this is
# run). Database-backed Application Setting, not a gitlab.rb/Omnibus key.
#
# Usage: ./scripts/enable-gitlab-import-sources.sh github git ...
# Valid values: github, bitbucket, bitbucket_server, fogbugz, git,
# gitlab_project, gitea, manifest, gitlab_built_in_project_template
#
# Idempotent: merges into whatever's already enabled rather than
# replacing it, so re-running with a different source doesn't disable
# ones enabled by an earlier run.
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "Usage: $0 <source> [<source> ...]" >&2
  echo "Valid: github, bitbucket, bitbucket_server, fogbugz, git, gitlab_project, gitea, manifest" >&2
  exit 1
fi

CONTAINER=$(docker ps --filter "label=com.docker.swarm.service.name=gitlab_gitlab" --format '{{.ID}}' | head -1)
if [ -z "$CONTAINER" ]; then
  echo "Error: no running gitlab_gitlab container found. Is the gitlab stack deployed?" >&2
  exit 1
fi

SOURCES_RUBY_ARRAY=$(printf "'%s', " "$@" | sed 's/, $//')

docker exec "$CONTAINER" gitlab-rails runner "
  requested = [${SOURCES_RUBY_ARRAY}]
  valid = Gitlab::ImportSources.values
  invalid = requested - valid
  raise \"Invalid import source(s): #{invalid.join(', ')}. Valid: #{valid.join(', ')}\" if invalid.any?

  new_sources = (ApplicationSetting.current.import_sources + requested).uniq
  ApplicationSetting.current.update!(import_sources: new_sources)
  puts ApplicationSetting.current.import_sources.inspect
"
