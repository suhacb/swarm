# Deployment Runbook

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

## Phase 1: Keycloak + Nginx

## 4. Deploy the shared Postgres server

One Postgres process hosts a separate database + role per service (Keycloak
first, GitLab's shared app databases later — GitLab itself uses its own
bundled Postgres, not this one, see Phase 2 below) — see
`stacks/data-stack.yml` for why. It needs its own superuser secret:

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

Keycloak's built-in second-factor options, for when other apps get their own
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

The steps above force MFA on the `suhacb` master-realm account specifically.
Phase 2 below does the same thing realm-wide, for every user of a given
realm — the mechanism is the same authentication-flow change, just applied
once per realm instead of once per user.

## Known follow-ups from Phase 1 (not blocking, but worth doing)

- **Wire up the certbot deploy-hook** (step 3.5) so the cert copy doesn't go
  stale after the first renewal — a manual copy only lasts until then.
- **Keycloak memory headroom**: 750M is tight for Keycloak. Watch
  `docker service logs infra_keycloak` and `docker stats` after first deploy,
  especially during realm imports or heavy admin console use, for OOM kills.

## Phase 2: GitLab with Keycloak SSO

Real GitLab CE (not Gitea — revisited from the original plan; see issue #2).
Reachable at `gitlab.suhac.eu` / `gitlab.lan.suhac.eu`. This is the dominant
memory consumer on the box once running — see the numbers at the end of this
section.

### 1. Bootstrap a Keycloak automation client (one-time, manual)

`kcadm.sh`'s direct-grant login can't supply a live TOTP code, so once the
`suhacb` master-realm admin actually has MFA enrolled (Phase 1, step 9),
scripted `kcadm` access breaks. The fix is a dedicated service-account
client that authenticates via client credentials instead of a human
password — this has to be created once through the Admin Console (browser
handles MFA fine; `kcadm` direct-grant doesn't), since creating it via
`kcadm` would itself need an already-authenticated session.

1. Log into `https://keycloak.lan.suhac.eu/admin`, **master** realm.
2. **Clients → Create client**. OpenID Connect, Client ID: `automation-cli`. Next.
3. Turn **on** "Client authentication" and "Service accounts roles"; turn
   **off** "Standard flow" and "Direct access grants". Save.
4. Open the client → **Service accounts roles** tab → **Assign role**.
   - Filter by clients → `master-realm` → select all its roles.
   - Filter by realm roles → select `create-realm` (a separate mechanism —
     master-realm client roles alone aren't enough to create new realms).
5. **Credentials** tab → copy the client secret.

```bash
printf '%s' '<the secret from step 5>' | docker secret create keycloak_automation_client_secret -
```

Add it to `infrastructure-stack.yml`'s `keycloak` service secrets (already
done in this repo) and redeploy so it's mounted into the container:

```bash
docker stack deploy -c stacks/infrastructure-stack.yml infra
```

Every `scripts/*.sh` that talks to `kcadm` now authenticates as
`automation-cli` by reading this secret from inside the Keycloak container —
no more interactive password/TOTP prompts, and it never touches the human
admin's MFA-protected login path.

### 2. Provision the Keycloak side

```bash
./scripts/setup-gitlab-keycloak.sh
```

Idempotent — creates (or confirms) all of:

- Realm `suhacb`, separate from `master`
- A reordered copy of the realm's browser flow (`browser-suhacb`), fixing a
  real bug in this Keycloak version: new realms get "Browser - Conditional
  OTP" ordered *before* "Username Password Form", so the OTP condition
  tries to check a user that doesn't exist yet and throws a
  NullPointerException before the login form even renders. Built-in flows
  can't be reordered directly, hence the duplicate-and-swap.
- MFA (TOTP) required for every user this script creates — via the
  `CONFIGURE_TOTP` required action on each one, not a flow-level change.
  (An earlier version of this script instead flipped the "Browser -
  Conditional OTP" subflow itself to `REQUIRED`, which caused the *same*
  premature-evaluation crash as the ordering bug above. The required action
  alone gets the same practical outcome — forced enrollment on first login,
  required on every login after — without touching the flow.)
- Groups `gitlab-admins`, `gitlab-users`
- Users `gitlab-admin` (in gitlab-admins) and `suhacb` (in gitlab-users)
  — prints a temporary password for each, shown once, forcing password
  reset + TOTP enrollment on first login
- OIDC client `gitlab`, with a `groups` claim mapper, and the
  `gitlab_oidc_client_secret` Docker secret

### 3. Host directories and remaining secrets

```bash
sudo mkdir -p /opt/swarm-data/gitlab/config /opt/swarm-data/gitlab/logs /opt/swarm-data/gitlab/data
sudo chown -R "$(whoami)" /opt/swarm-data/gitlab
cp config/gitlab/gitlab.rb.template /opt/swarm-data/gitlab/config/gitlab.rb

openssl rand -base64 24 | docker secret create gitlab_root_password -
```

`gitlab.rb` is **copied**, not bind-mounted read-only like `nginx.conf` —
GitLab writes other files into `/etc/gitlab` as it runs (secrets, SSH host
keys), so it needs to be a real persistent directory. Editing it later means
editing `/opt/swarm-data/gitlab/config/gitlab.rb` directly, then
`gitlab-ctl reconfigure` inside the container — the template in this repo
won't re-apply itself.

### 4. Deploy

```bash
docker stack deploy -c stacks/gitlab-stack.yml gitlab
docker stack deploy -c stacks/proxy-stack.yml proxy   # picks up conf.d/gitlab.conf + the new nginx network aliases
```

First boot runs a full `gitlab-ctl reconfigure` — expect several minutes,
watch with `docker service logs -f gitlab_gitlab`.

### 5. First login and admin promotion

Browse to `https://gitlab.suhac.eu` (or the `.lan` hostname), click "Sign in
with Keycloak", and log in as `gitlab-admin` with the temporary password
from step 2 — you'll be walked through setting a new password and enrolling
TOTP, same flow as Phase 1.

GitLab only creates its local user record on first login, so **after** that
first login:

```bash
./scripts/bootstrap-gitlab-admin.sh gitlab-admin
```

GitLab CE doesn't reliably auto-promote admins from an OIDC group claim
(group-based admin sync is gated to SAML/paid tiers) — this script is the
guaranteed-to-work alternative. The built-in `root` account (password in the
`gitlab_root_password` secret) stays available independently, for
break-glass access if Keycloak itself is ever unreachable.

### 6. Single logout + Keycloak-only login

Two more real-world gaps beyond just wiring up login:

- **Logout didn't mean logout**: GitLab sign-out only destroyed GitLab's own
  session cookie. Keycloak's SSO session (a separate cookie on a different
  hostname) stayed alive, so clicking "sign in with Keycloak" again just
  silently re-authenticated as whoever was last logged in, without asking.
- **A local admin nobody wanted**: the bootstrap `root` account is a normal
  GitLab user with a password, independent of Keycloak entirely.

```bash
./scripts/configure-gitlab-sso-logout.sh
./scripts/configure-gitlab-oidc-only.sh
```

The first makes GitLab's sign-out redirect through Keycloak's own logout
endpoint (`client_id` + `post_logout_redirect_uri`, no `id_token_hint`
needed — registered on the client as `post.logout.redirect.uris` by
`setup-gitlab-keycloak.sh`) before returning to GitLab, so it actually ends
the SSO session. The second disables local username/password login (both
web and git-over-HTTP; Personal Access Tokens are unaffected) via
`ApplicationSetting` — **not** a `gitlab.rb` key, an easy mix-up since it
looks exactly like the settings that are.

`gitlab.rb` also sets `omniauth_auto_sign_in_with_provider = 'openid_connect'`
so unauthenticated visits skip GitLab's own sign-in page entirely and go
straight to Keycloak (implemented as a tiny auto-submitting form, not an
HTTP redirect — if you curl `/users/sign_in` expecting a 302 you'll get a
200 with a 10-line HTML page instead; a real browser executes it instantly).

`root` is not deleted — once password auth is off it's simply unreachable
from the web, but stays available via `gitlab-rails console`/`runner`
directly on the server as a break-glass path independent of Keycloak.

### Known limitations

- **One hostname in generated links**: unlike Keycloak, GitLab bakes
  `external_url` into clone URLs, notification emails, and webhook payloads
  — there's no per-request dynamic hostname. `gitlab.lan.suhac.eu` still
  works fine for browsing and git clone/push either way; anything GitLab
  itself generates will just always show `gitlab.suhac.eu` regardless of
  which hostname you're actually using.
- **Bundled Postgres/Redis**: GitLab uses its own internal database, not the
  shared `data_postgres` server, to avoid GitLab's specific extension/version
  requirements colliding with what other services expect from that instance.
- **OIDC redirect_uri always targets the public hostname**: because of the
  first limitation above, the browser-facing redirect back from Keycloak
  after login always goes to `gitlab.suhac.eu`'s callback, even if you
  started at `gitlab.lan.suhac.eu`. If the public hostname isn't reachable
  from inside your LAN, this hangs partway through login. `dig` resolving
  it correctly isn't sufficient proof it'll work — browsers increasingly
  default to their own DNS-over-HTTPS resolver (Cloudflare, Google),
  bypassing router-local DNS overrides entirely and getting the real public
  IP instead. A genuine NAT hairpin/loopback fix on the router is more
  robust than a DNS override for this reason — it works regardless of which
  resolver answered. As of this writing this is still being tracked down;
  see issue #2.
