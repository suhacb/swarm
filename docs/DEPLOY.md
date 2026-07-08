# Deploying Phase 1 (Keycloak + Nginx)

All commands assume you're running them **on the Mac Mini** (`10.10.10.202`),
in the repo root (`/Users/blazsuhac/Documents/projects/swarm`), via Screen
Sharing.

## 0. One-time Docker Desktop settings

- **Settings → Resources → Memory**: check the VM's allocation leaves enough
  headroom for macOS itself on an 8GB box (e.g. 5–6GB to the VM, not 8GB).
- **Settings → Resources → File Sharing**: add `/etc/letsencrypt` if it's not
  already covered — the proxy stack bind-mounts it read-only, and Docker
  Desktop won't surface paths outside its shared list.

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

- **Cert permission hardening**: Nginx currently runs its worker processes as
  root so it can read the root-owned `privkey.pem`. Cleaner fix: extend the
  certbot renewal LaunchDaemon with a `--deploy-hook` that copies
  `fullchain.pem`/`privkey.pem` to a location with relaxed permissions (e.g.
  `chmod 644`) and reloads the nginx service
  (`docker service update --force proxy_nginx`), then drop `user root;` from
  `config/nginx/nginx.conf` in favor of the image's default non-root user.
- **Keycloak memory headroom**: 750M is tight for Keycloak. Watch
  `docker service logs infra_keycloak` and `docker stats` after first deploy,
  especially during realm imports or heavy admin console use, for OOM kills.
