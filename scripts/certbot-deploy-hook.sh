#!/usr/bin/env bash
# Certbot deploy-hook: copies the renewed wildcard cert to a location owned
# by a regular user with normal permissions, since Docker Desktop's file
# sharing bridge runs as that user (not root) and can never read Certbot's
# root-only 0700 live/archive directories directly.
#
# Wire this into your EXISTING certbot renewal setup (this script does not
# modify /Library/LaunchDaemons/eu.suhac.certbot-renew.plist itself):
#   sudo certbot renew --deploy-hook /path/to/this/script
# or add `--deploy-hook /path/to/this/script` to the command the
# LaunchDaemon already runs, then `sudo launchctl kickstart -k
# system/eu.suhac.certbot-renew` to pick up the change.
#
# Runs as root (certbot's deploy-hooks always do), hence chown by name here.
set -euo pipefail

TARGET_USER="blazsuhac"
DEST="/opt/swarm-data/certs/live/suhac.eu"

mkdir -p "$DEST"
cp /etc/letsencrypt/live/suhac.eu/fullchain.pem /etc/letsencrypt/live/suhac.eu/privkey.pem "$DEST/"
chown -R "$TARGET_USER" /opt/swarm-data/certs
chmod 644 "$DEST"/*.pem

# Nginx doesn't need a config reload for new file *contents* at these same
# paths, but the running container's TLS context is still the one loaded at
# startup — reload nginx so it actually picks up the renewed cert.
docker service update --force proxy_nginx >/dev/null 2>&1 || true
