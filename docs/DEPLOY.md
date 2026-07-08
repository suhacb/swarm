# Deploying Phase 1 (Keycloak + Nginx)

All commands assume you're running them **on the Mac Mini** (`10.10.10.202`),
in the repo root (`/Users/blazsuhac/Documents/projects/swarm`), via Screen
Sharing.

## 0. One-time Docker Desktop settings

- **Settings → Resources → Memory**: check the VM's allocation leaves enough
  headroom for macOS itself on an 8GB box (e.g. 5–6GB to the VM, not 8GB).
- **Settings → Resources → File Sharing**: add `/opt` if it's not already
  covered (see step 3.5 below for why it's `/opt`, not `/etc/letsencrypt`).

## 1. Initialize the swarm (first time only)

```bash
docker swarm init --advertise-addr 10.10.10.202
```

## 2. Create the overlay networks

```bash
./networks/deploy-networks.sh
```

## 3. Create host directories for bind-mounted data

```bash
sudo mkdir -p /opt/swarm-data/postgres
sudo chown "$(whoami)" /opt/swarm-data/postgres
```

## 3.5. Make the wildcard cert readable by the proxy stack

Certbot locks `/etc/letsencrypt/live/` and `archive/` down to `root:wheel`
mode `0700`. Docker Desktop's file-sharing bridge on macOS runs as your own
user, not root — it cannot read those paths **at any container privilege
level**, including a container running as root. The fix is a plain-permission
copy the proxy stack reads instead of the original:

```bash
sudo mkdir -p /opt/swarm-data/certs/live/suhac.eu
sudo cp /etc/letsencrypt/live/suhac.eu/fullchain.pem /etc/letsencrypt/live/suhac.eu/privkey.pem /opt/swarm-data/certs/live/suhac.eu/
sudo chown -R "$(whoami)" /opt/swarm-data/certs
chmod 644 /opt/swarm-data/certs/live/suhac.eu/*.pem
```

This copy goes stale on each renewal (twice daily, per the existing
LaunchDaemon). To keep it in sync automatically, wire
`scripts/certbot-deploy-hook.sh` into your **existing** certbot renewal setup
yourself (this repo doesn't touch
`/Library/LaunchDaemons/eu.suhac.certbot-renew.plist`):

```bash
sudo certbot renew --deploy-hook /Users/blazsuhac/Documents/projects/swarm/scripts/certbot-deploy-hook.sh
```

Run that once to confirm it works, then add the same `--deploy-hook` flag to
whatever command the LaunchDaemon already runs, and `sudo launchctl kickstart
-k system/eu.suhac.certbot-renew` to pick up the change.

## 4. Deploy the shared Postgres server

One Postgres process hosts a separate database + role per service (Keycloak
first, Gitea/apps later) — see `stacks/data-stack.yml` for why. It needs its
own superuser secret:

```bash
openssl rand -base64 32 | docker secret create postgres_admin_password -
docker stack deploy -c stacks/data-stack.yml data
```

## 5. Provision Keycloak's database

```bash
./scripts/create-postgres-db.sh keycloak
```

This creates a `keycloak` role + database on the shared Postgres server
(convention: role name == database name == service name) and the
`keycloak_db_password` secret Keycloak's own stack expects. Re-run for any
future service the same way — it's idempotent.

## 6. Create the remaining secrets

```bash
openssl rand -base64 32 | docker secret create keycloak_admin_password -
```

To rotate a secret later: create a new one with a version suffix (Swarm
secrets are immutable — you can't update in place), e.g.
`keycloak_admin_password_v2`, update the stack file to reference it, then
`docker stack deploy` again.

**`keycloak_db_password` is a special case**: rotating it and redeploying
Keycloak does **not** change the password Postgres actually has for that
role — Keycloak will get `FATAL: password authentication failed for user
"keycloak"` because it's presenting a password Postgres was never told
about. To rotate it for real, also run `ALTER ROLE keycloak WITH PASSWORD
'<new password>';` inside the `data_postgres` container (`docker exec -it
<container> psql -U postgres`) so both sides agree.

## 7. Build the optimized Keycloak image

```bash
docker build -t local/keycloak:26.0-optimized -f images/keycloak/Dockerfile .
```

Re-run this whenever `images/keycloak/Dockerfile` changes or you bump the
Keycloak version — check
[quay.io/repository/keycloak/keycloak?tab=tags](https://quay.io/repository/keycloak/keycloak?tab=tags)
for the current release before bumping.

## 8. Deploy Keycloak and the proxy

```bash
docker stack deploy -c stacks/infrastructure-stack.yml infra
docker stack deploy -c stacks/proxy-stack.yml proxy
```

## 9. Force a password reset + MFA enrollment on the admin account

Run this once, right after the *first* deploy (i.e. while the password you
put in `keycloak_admin_password` is still the one that actually works):

```bash
./scripts/bootstrap-keycloak-admin.sh
```

It flags the `suhacb` admin account so its next login requires setting a new
password and enrolling TOTP (Google Authenticator or any RFC 6238 app —
Keycloak's default OTP policy already matches Google Authenticator's
settings, no changes needed). Safe to re-run.

## 10. Verify

```bash
docker service ls
docker service logs -f infra_keycloak
docker service logs -f proxy_nginx
```

Then browse to `https://keycloak.suhac.eu` and `https://keycloak.lan.suhac.eu`
— both should hit the same Keycloak instance. Log in to the admin console at
`/admin` with user `suhacb` and the password you put in
`keycloak_admin_password`. You should immediately be prompted to set a new
password and scan a QR code to enroll Google Authenticator.

Also confirm plain `http://` requests always redirect to `https://`,
including hostnames Nginx doesn't otherwise recognize:

```bash
curl -I http://keycloak.suhac.eu/          # expect 301 -> https://keycloak.suhac.eu/
curl -I http://anything-else.suhac.eu/     # expect 301 -> https://anything-else.suhac.eu/
```

## MFA options (for later realms too)

Keycloak's built-in second-factor options, for when Gitea/apps get their own
realms:

- **TOTP** (what's enabled above) — works with Google Authenticator, Authy,
  FreeOTP, Microsoft Authenticator, etc. Default policy (SHA1, 6 digits, 30s)
  is already Google Authenticator-compatible.
- **WebAuthn/FIDO2** — hardware keys, Touch ID, Windows Hello. Built in, but
  more setup (Authentication → WebAuthn Policy) and less relevant for a
  single-admin home lab.
- **Recovery codes** — self-service backup codes, users can enable via the
  Account Console once TOTP is set up.
- **SMS/email OTP** — *not* built into core Keycloak, needs a third-party SPI
  provider. Skip unless there's a real need.

The steps above force MFA on the `suhacb` account specifically. To make TOTP
mandatory for *all* users of a given realm, change the "OTP Form" execution
in that realm's browser authentication flow from `CONDITIONAL` to
`REQUIRED` (Authentication → browser flow, in the admin console) — worth
doing per-realm once Gitea/apps are wired up to Keycloak, not before.

## Known follow-ups (not blocking, but worth doing)

- **Wire up the certbot deploy-hook** (step 3.5) so the cert copy doesn't go
  stale after the first renewal — a manual copy only lasts until then.
- **Keycloak memory headroom**: 750M is tight for Keycloak. Watch
  `docker service logs infra_keycloak` and `docker stats` after first deploy,
  especially during realm imports or heavy admin console use, for OOM kills.
