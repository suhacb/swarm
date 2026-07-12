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

Then browse to `https://keycloak.suhac.eu`. Log in to the admin console at
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
Reachable at `gitlab.suhac.eu`. This is the dominant memory consumer on the
box once running — see the numbers at the end of this section.

### 1. Bootstrap a Keycloak automation client (one-time, manual)

`kcadm.sh`'s direct-grant login can't supply a live TOTP code, so once the
`suhacb` master-realm admin actually has MFA enrolled (Phase 1, step 9),
scripted `kcadm` access breaks. The fix is a dedicated service-account
client that authenticates via client credentials instead of a human
password — this has to be created once through the Admin Console (browser
handles MFA fine; `kcadm` direct-grant doesn't), since creating it via
`kcadm` would itself need an already-authenticated session.

1. Log into `https://keycloak.suhac.eu/admin` (from the LAN — see the
   perimeter hardening section below), **master** realm.
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
web and git-over-HTTP; Personal Access Tokens are unaffected) *and* open
self-registration (GitLab warns about open signup by default anyway, and
it's pointless once no self-set password can log in) via
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

Also worth running once, unrelated to auth: GitLab's admin dashboard flags
"Web IDE single origin fallback" as a high-severity risk by default (it
serves VS Code assets from GitLab's own origin — defeating the point of
sandboxing extension code on a separate origin — if that separate domain
is ever unreachable). Disabling the fallback is GitLab's own recommended
fix:

```bash
./scripts/harden-gitlab-web-ide.sh
```

### 7. Importing existing projects

A fresh instance ships with **no** project import sources enabled at all
("No import options available" in New project → Import project until this
runs):

```bash
./scripts/enable-gitlab-import-sources.sh github
```

Valid sources: `github`, `bitbucket`, `bitbucket_server`, `fogbugz`, `git`
(generic git URL), `gitlab_project` (GitLab export file), `gitea`,
`manifest`. Merges into whatever's already enabled rather than replacing
it, so re-running to add another source later doesn't disable this one.

For GitHub specifically: New project → Import project → GitHub, paste a
GitHub Personal Access Token (classic, `repo` scope), pick the repo. Pulls
branches/commits/tags plus issues, PRs (as merge requests), comments,
labels, and milestones in one pass — a real git-level mirror would only
get the git data, not the GitHub-specific metadata. GitHub usernames only
map to GitLab accounts that already exist with a matching identity, so
expect most historical authorship to just show as whoever ran the import.

### 8. Perimeter hardening

Once the box is genuinely internet-facing, it starts getting hit by normal
background scanning/crawling within hours — none of this is a response to
an actual incident, just baseline hardening for that reality. Real
firewall/network-level protection is out of scope here by design (handled
upstream, on the router).

```bash
./scripts/harden-keycloak-brute-force.sh master suhacb
```

Both realms shipped with `bruteForceProtected` **off**. Enables it with
`failureFactor=5` (Keycloak's own default is 30) — since MFA is already
required realm-wide, this only protects the password step, and 5 failed
attempts is enough margin for a real user who knows their own password.
Temporary lockout, not permanent (`permanentLockout=false`), so a
legitimate lockout self-resolves rather than needing admin intervention.
Re-run for any future realm.

Nginx also gets two rate-limit zones (`config/nginx/nginx.conf`): `general`
(10r/s, burst 20) applied to every vhost, and a tighter `auth` zone (2r/s,
burst 5) applied specifically to Keycloak's login form submission
(`/realms/*/login-actions/authenticate`) as defense in depth alongside the
brute-force lockout above. The general zone matters less for security than
for protecting GitLab's tight memory budget from being hammered by
scanner/bot traffic. Verified live by actually flooding both endpoints and
confirming `503`s appear, not just checked for valid syntax.

A few more, applied directly (no script — small, one-off ApplicationSetting/
realm changes):

- **GitLab Admin Mode** (`admin_mode: true`) — the Admin Area now requires
  re-authentication even if already logged in, protecting against session
  hijacking or an unlocked laptop. Was off by default.
- **GitLab system hooks** can no longer reach the local network
  (`allow_local_requests_from_system_hooks: false`) — unused feature, no
  reason to leave it able to. Webhook SSRF protection
  (`allow_local_requests_from_web_hooks_and_services`) was already off by
  default; nothing to do there.
- **Keycloak password policy** — `length(12) and notUsername and notEmail`
  on both realms. MFA already covers most of the real risk here, but there
  was no policy at all before, so a self-set one-character password was
  technically possible.
- **Nginx TLS ciphers** — Mozilla's "Intermediate" cipher list for TLS 1.2
  (TLS 1.3 always uses its own strong, fixed suite regardless). Verified
  live: forcing `-tls1_2` negotiates a cipher straight from the configured
  list, not just whatever OpenSSL happened to default to.
- **Keycloak admin console LAN-only restriction was tried and dropped.** It
  originally worked by gating on a second hostname (`keycloak.lan.suhac.eu`)
  — removed along with that hostname (see "Single hostname" below). The
  replacement attempt, source-IP filtering (`allow 10.10.10.0/24; deny
  all;`), turned out to be impossible on Docker Desktop for Mac: confirmed
  live that Docker Desktop's own VM-boundary NAT rewrites *every* client's
  source IP to its internal gateway address before any container sees it —
  LAN, WAN, and even the host machine's own requests all become
  indistinguishable — regardless of Swarm's publish mode. `/admin` is
  reachable from `keycloak.suhac.eu` from anywhere now; MFA, the password
  policy, and brute-force lockout are the real protections left on it. A
  real fix (VPN, or a router-level firewall rule ahead of the Mac Mini
  entirely) is a separate, bigger undertaking if this needs revisiting.

### Known limitations

- **Bundled Postgres/Redis**: GitLab uses its own internal database, not the
  shared `data_postgres` server, to avoid GitLab's specific extension/version
  requirements colliding with what other services expect from that instance.
- **Single hostname, no `.lan` variant**: `gitlab.suhac.eu` and
  `keycloak.suhac.eu` are the only hostnames — no `.lan.suhac.eu` duality.
  There used to be one: a second hostname existed specifically so a router
  DNS override could point it at the box's LAN IP, working around real
  browsers increasingly defaulting to their own DNS-over-HTTPS resolver
  (Cloudflare, Google) for the public hostname, bypassing router-local DNS
  overrides and hitting a NAT hairpin from inside the LAN. In practice the
  second hostname just added confusion (which one do you use where) without
  adding capability — a Local DNS Record override on the router (UDR7) for
  the **same** public hostname → the box's LAN IP achieves the identical
  outcome with one name instead of two. If you're setting this up fresh and
  hit the hairpin/DoH issue, that's the fix — not a second hostname.

## Phase 2b: CI/CD — GitLab Runner + Container Registry

GitLab Runner (Docker executor) plus GitLab's bundled Container Registry, for
MR pipelines and "build once, promote many" image deploys. The runner manager
itself has no persistent footprint beyond its config — every job runs in its
own ephemeral sibling container, created via the host's Docker socket (not
Docker-in-Docker), removed once the job finishes.

### 1. Container Registry

Already enabled in `config/gitlab/gitlab.rb.template` (`registry['enable']`,
`registry_external_url 'https://registry.suhac.eu'`, `registry_nginx[...]`
mirroring the same "our own Nginx terminates TLS, Omnibus's internal nginx
only speaks plain HTTP" pattern as the main GitLab vhost). For an existing
deployment, apply it the same way any other `gitlab.rb` change is applied —
edit `/opt/swarm-data/gitlab/config/gitlab.rb` directly, then
`gitlab-ctl reconfigure` inside the container.

`registry.suhac.eu` needs no new DNS or cert work — one level deep, already
covered by the existing wildcard record and cert. If it's unreachable from
inside the LAN, add the same router Local DNS Record override already used
for `gitlab.suhac.eu`/`keycloak.suhac.eu` (see the "Single hostname" note
above) rather than a separate `.lan` hostname.

### 2. Deploy the registry's Nginx vhost and `ci-mesh`

```bash
docker stack deploy -c stacks/proxy-stack.yml proxy
```

Picks up `config/nginx/conf.d/registry.conf` (new vhost) and the `ci-mesh`
network membership on `nginx` (aliases `gitlab.suhac.eu` and
`registry.suhac.eu`) — the same alias trick already used for
`public-ingress`, extended so CI job containers (which only ever join
`ci-mesh`, never `public-ingress`) can still reach both over real TLS.
GitLab and the registry itself don't need to join `ci-mesh` for this — Nginx
already resolves `gitlab:80`/`gitlab:5050` via its own `public-ingress`
membership regardless of which network the inbound request arrived on.

### 3. Get a runner authentication token

Admin Area → CI/CD → Runners → **New instance runner**. Pick tags (e.g.
`docker`, `swarm-homelab`) and whether to run untagged jobs, then copy the
`glrt-…` authentication token shown (this is the new token-based flow —
GitLab 19.x removed the old shared registration token entirely).

```bash
sudo mkdir -p /opt/swarm-data/gitlab-runner/config
sudo chown -R "$(whoami)" /opt/swarm-data/gitlab-runner
printf '%s' '<the glrt-... token>' | docker secret create gitlab_runner_token -
```

### 4. Deploy the runner

```bash
docker stack deploy -c stacks/gitlab-runner-stack.yml gitlab-runner
```

First start runs `gitlab-runner register` once (idempotent — skipped on
every later restart once `config.toml` exists on the bind-mounted config
dir) using the token secret, Docker executor, `docker:24-cli` as the default
job image, `network_mode=ci-mesh`, and the host's Docker socket mounted into
job containers too (so a job's own `docker build`/`docker push` steps talk
to the same host daemon). `concurrent = 1` matches the tight RAM budget —
one job at a time.

### 5. Verify

```bash
docker service logs -f gitlab-runner_gitlab-runner
```

Should show `Runner registered successfully` then start polling for jobs.
Confirm in the UI (Admin Area → CI/CD → Runners) that it shows **online**,
or via `gitlab-rails runner "puts Ci::Runner.find(1).online?"` inside the
GitLab container.

A minimal `.gitlab-ci.yml` smoke test that actually exercises the full
path — clone, Docker executor, build, registry auth, push:

```yaml
build:
  stage: build
  image: docker:24-cli
  tags: [docker]
  script:
    - docker build -t "$CI_REGISTRY_IMAGE:$CI_COMMIT_SHORT_SHA" .
    - echo "$CI_REGISTRY_PASSWORD" | docker login -u "$CI_REGISTRY_USER" --password-stdin "$CI_REGISTRY"
    - docker push "$CI_REGISTRY_IMAGE:$CI_COMMIT_SHORT_SHA"
```

### Known limitations

- **Nginx's ports publish in `mode: host`, not Swarm's default routing
  mesh** — bypasses one real layer of IP-masking (Swarm's ingress mode SNATs
  every connection to a generic overlay address; verified live, a request
  from the host itself showed up in nginx's logs as `10.0.0.2`). No downside
  on a single-node Swarm (the mesh only matters for balancing across nodes),
  so left in place even though it turned out not to be sufficient on its
  own — see the next point.
- **Per-client rate limiting (`limit_req_zone $binary_remote_addr ...`) is
  not actually per-client on this Docker Desktop for Mac setup.** `mode:
  host` above fixes Swarm's own SNAT, but Docker Desktop for Mac has a
  second, deeper NAT layer at the macOS-host/Linux-VM boundary that rewrites
  *every* client's source IP to its internal gateway address (confirmed
  live while investigating a LAN-only admin-console restriction — see
  Phase 2's "Known limitations"). Nothing in this stack can bypass that
  layer; on a real Linux host (no Docker Desktop VM in between) this
  wouldn't be an issue and `mode: host` alone would be sufficient. Until
  then, rate limiting still blunts aggregate flooding, just not per-visitor.
- **Sidekiq can silently wedge under this Docker Desktop setup**: seen twice
  — once after a `gitlab-ctl reconfigure` restarted Sidekiq but its paired
  log/rotation process didn't cleanly restart alongside it (fixed with
  `kill -9` on the stuck log process to force runit to respawn it cleanly);
  once as a live 500 on a real project caused by the same underlying
  `application_json.log` file transiently disappearing out from under an
  open file handle (self-resolved when Docker's own healthcheck killed and
  Swarm auto-restarted the container). Root cause looks like Docker
  Desktop's virtiofs bind-mount layer occasionally hiccupping on fresh file
  opens under this bind-mounted logs directory specifically — the same class
  of issue as the certs-mount fix in step 3.5, not something fixable from
  inside the container. If GitLab seems wedged (Sidekiq queue not draining,
  random 500s) with `gitlab-ctl status` still showing everything "run:",
  check `Sidekiq::ProcessSet.new.size` via `gitlab-rails runner` — `0` means
  it's lost its Redis heartbeat despite the process being alive, and a full
  Docker Desktop restart is the most reliable fix found so far.

## Phase 3: Princess service

Angular SPA + Laravel API, `princess.suhac.eu` (prod) and
`staging.princess.suhac.eu` (staging), path-routed at the Nginx layer —
no Traefik, no `api.*` subdomain (no CORS config exists in the backend
repo, and same-origin avoids ever needing one). Tracked in
[issue #8](https://github.com/suhacb/swarm/issues/8), supersedes #3/#4/#5.

### 1. Postgres: one role, four databases

```bash
./scripts/create-princess-databases.sh
```

Creates role `princess` and databases `princess` (prod), `stage_princess`
(staging), `e2e_princess` (frontend-driven E2E — see step 5 below),
`test_princess` (CI), plus the `princess_db_password` secret shared across
all four. `test_princess`'s credentials additionally need adding as a
masked/protected GitLab CI/CD variable on the `princess_backend` project —
a GitLab project setting, not scriptable from here.

### 2. Keycloak

```bash
./scripts/setup-princess-keycloak.sh
```

Idempotent — creates (or confirms) all of:

- `suhacb` realm (prod): realm roles `princess-admin`/`princess-user`,
  groups `princess-admins`/`princess-users` with the matching role
  attached via group role-mapping, `suhacb` added to `princess-users`,
  confidential client `princess-client` (redirect
  `https://princess.suhac.eu/*`) → secret `princess_keycloak_client_secret`
- New `princess-test` realm (staging): password policy `length(12) and
  upperCase(1) and digits(1)`, the same browser-flow reorder fix from
  Phase 2 (a bug in this Keycloak version's default new-realm flow
  ordering — applies regardless of whether MFA is required), same
  roles/groups as prod, confidential client `princess-client` (redirect
  `https://staging.princess.suhac.eu/*`) →  secret
  `princess_test_keycloak_client_secret`, and 11 test users from
  `config/princess/test-users.csv` (gitignored — create it yourself from
  the princess team's table before running this script; it's never
  committed since this repo is public). Their passwords are set directly
  and permanent, no forced reset, no TOTP — this realm has no MFA
  anywhere, deliberately, for frictionless repeat manual testing.

### 3. Shared services: Qdrant, ZincSearch, Garage

Neither ZincSearch's nor Garage's image has a shell at all (confirmed
live — no `/bin/sh`, no busybox), which rules out two patterns used
elsewhere in this repo: the entrypoint-wrapper trick that turns a mounted
Docker secret file into an env var (Keycloak/GitLab), and CMD-SHELL
healthchecks (also need a shell). Each service's credentials are handled
differently as a result:

```bash
sudo mkdir -p /opt/swarm-data/qdrant /opt/swarm-data/zincsearch /opt/swarm-data/garage/meta /opt/swarm-data/garage/data
sudo chown -R "$(whoami)" /opt/swarm-data/qdrant /opt/swarm-data/zincsearch /opt/swarm-data/garage

# Garage: render a REAL config once, secrets baked directly into a
# host-only file — same "copied, not bind-mounted, never committed"
# pattern already used for gitlab.rb (no shell inside the container to do
# runtime substitution, unlike Keycloak/GitLab's wrapper trick).
cp config/garage/garage.toml.template /opt/swarm-data/garage/garage.toml
sed -i '' "s/__RPC_SECRET__/$(openssl rand -hex 32)/" /opt/swarm-data/garage/garage.toml
sed -i '' "s/__ADMIN_TOKEN__/$(openssl rand -hex 32)/" /opt/swarm-data/garage/garage.toml
sed -i '' "s/__METRICS_TOKEN__/$(openssl rand -hex 32)/" /opt/swarm-data/garage/garage.toml

# ZincSearch: no shell and no *_FILE-style env convention either, so the
# bootstrap admin password comes from `docker stack deploy`'s own ${VAR}
# interpolation (confirmed live — it substitutes from the deploying
# shell's environment, same as docker-compose) instead of a Docker
# secret file. The secret below is still created purely as a durable
# record of the value; the container never reads it directly.
ZINC_PW=$(openssl rand -base64 24)
printf '%s' "$ZINC_PW" | docker secret create zincsearch_admin_password -
export ZINC_FIRST_ADMIN_PASSWORD="$ZINC_PW"

docker stack deploy -c stacks/shared-services-stack.yml shared-services
```

`ZINC_FIRST_ADMIN_PASSWORD` must be exported in the **same shell** that
runs `docker stack deploy` — interpolation happens client-side at parse
time, so re-deploying this stack later without re-exporting it will blank
the value out. Qdrant's image does have a shell, but it's not bash (no
`/dev/tcp` support) — its healthcheck explicitly invokes `/usr/bin/bash`
rather than relying on `CMD-SHELL`'s default `/bin/sh`.

Then bootstrap Garage's buckets and princess's scoped access key (layout
itself is handled by the `--single-node` server flag, not this script):

```bash
./scripts/setup-garage.sh
```

Creates buckets `princess`/`staging-princess`/`e2e-princess`/`test-princess`
— **hyphens**, confirmed live that Garage enforces S3 bucket-naming rules
(underscores are rejected) — and one key (`princess`) with read/write/owner
on exactly those four, secrets `princess_garage_key_id` /
`princess_garage_secret_key`. Qdrant collection/ZincSearch index naming
follows the usual underscore convention (unaffected by this — it's not
enforced server-side either) — see the README's "Shared Qdrant /
ZincSearch / Garage" section.

### 4. Postgres web manager: pgAdmin4

```bash
sudo mkdir -p /opt/swarm-data/pgadmin
sudo chown -R "$(whoami)" /opt/swarm-data/pgadmin

./scripts/setup-pgadmin-keycloak.sh
openssl rand -base64 24 | docker secret create pgadmin_admin_password -

docker stack deploy -c stacks/data-stack.yml data
```

Gated on Keycloak SSO only (`AUTHENTICATION_SOURCES=['oauth2']` in
`config/pgadmin/config_local.py.template`, `OAUTH2_AUTO_CREATE_USER=False`)
— a LAN-only alternative (the team's "Plan B") was ruled out: this Docker
Desktop for Mac host can't do IP-based gating at all (see Phase 2's "Known
limitations" — the same VM-boundary NAT issue that killed Keycloak's own
admin-console LAN gate). `suhacb` already has TOTP enrolled from Phase 1,
so this login is already MFA-covered without any extra work.

Three things confirmed live and worth knowing before touching this
service again:

- **pgAdmin 8.14's OAuth2 code reads `OAUTH2_TOKEN_URL`/
  `OAUTH2_AUTHORIZATION_URL`/`OAUTH2_API_BASE_URL`/`OAUTH2_USERINFO_ENDPOINT`
  directly** — `OAUTH2_SERVER_METADATA_URL` alone (what most docs show)
  isn't enough on this version despite being accepted too; all five are
  set in `config/pgadmin/config_local.py.template`.
- **`/pgadmin4` isn't writable by the image's default non-root user** —
  the entrypoint wrapper that renders `config_local.py` runs as `user:
  "0:0"` in `data-stack.yml` for that reason. This is a documented-
  supported mode for this image: its own `/entrypoint.sh` detects it's
  running as root and re-execs the actual gunicorn process as a non-root
  user via `su-exec`, so the real server still ends up unprivileged.
- **This image's `/bin/sh` isn't bash** (same gotcha as Qdrant below) —
  the healthcheck invokes `/bin/bash` explicitly rather than relying on
  `CMD-SHELL`'s default shell.

After first deploy, pre-provision the owner's account — `OAUTH2_AUTO_CREATE_USER=False`
means nobody logs in until an account exists for their exact email
(pgAdmin derives the login username from the `email` claim, no
`OAUTH2_USERNAME_CLAIM` configured):

```bash
docker exec <data_pgadmin container> /venv/bin/python3 /pgadmin4/setup.py \
  add-external-user suhacb@suhac.eu --auth-source oauth2 --email suhacb@suhac.eu --admin --active
```

Then log in once via `https://pg.suhac.eu` to confirm the OIDC round-trip
end to end, and manually add the "Shared Postgres" server connection
inside pgAdmin's UI — its superuser password is whatever was put in
`postgres_admin_password` back in Phase 1; retrieve it if needed with
`docker exec <data_postgres container> cat /run/secrets/postgres_admin_password`.
It's deliberately never baked into any pgAdmin config file.

### 5. Nginx: path-priority routing

```bash
docker stack deploy -c stacks/proxy-stack.yml proxy
```

Picks up `config/nginx/conf.d/princess.conf` (prod + staging, each with a
`location ^~ /api/` prefix match that wins over the plain `location /`
catch-all — same "the SPA never sees API traffic" property Traefik would
give, without adding Traefik), `config/nginx/conf.d/pgadmin.conf`, and the
new `public-ingress` aliases (`princess.suhac.eu`,
`staging.princess.suhac.eu`, `pg.suhac.eu`) on `nginx` itself.

Two new DNS entries needed (Cloudflare, outside this repo, same wildcard
cert covers all of it): `princess.suhac.eu`, `staging.princess.suhac.eu`.
`pg.suhac.eu` is a third, beyond what the princess team originally scoped.

The frontend's E2E suite needs no separate `e2e.*` hostname or deployment
at all — it hits `staging.princess.suhac.eu` with an `X-E2E-Token` header,
and the backend's own `E2eAuth` middleware transparently switches that
request onto the isolated `e2e_princess` database.

### 6. Apps: princess frontend + backend

`stacks/apps-stack.yml` is written and ready (services `princess-backend`,
`princess-backend-staging`, `princess-frontend`, `princess-frontend-staging`)
but its image path (`registry.suhac.eu/princess/...`) is a placeholder —
`docker stack deploy -c stacks/apps-stack.yml apps` will fail to pull until
the princess team's own GitLab project actually exists and pushes images
there. Confirm the Container Registry is enabled for that project (already
enabled instance-wide, see Phase 2b) once it's created, adjust the image
path in the stack file to match, then deploy.

### 7. CI/CD deploy trigger

Lives entirely in the princess team's own `.gitlab-ci.yml`, not in this
repo — their runner job containers already reach the host Docker daemon
(the same `gitlab-runner` from Phase 2b, `docker.sock` already mounted, no
change needed here), so a deploy stage is just:

```yaml
deploy:
  stage: deploy
  image: docker:24-cli
  tags: [docker]
  script:
    - docker service update --image "$CI_REGISTRY_IMAGE:$CI_COMMIT_SHORT_SHA" apps_princess-backend
```

No SSH keypair, no webhook endpoint needed — this is strictly less
infrastructure than either alternative the princess team proposed, for
the same result, on a single-node swarm.

### Known limitations

- **Memory is tight.** Current service memory *limits* already summed to
  ~6.1GB out of the VM's ~7.75GB total before this phase (GitLab alone
  budgeted 4.88GB, actual usage ~2.7GB). This phase adds ~2GB more in
  limits (shared services + princess frontend/backend ×2 envs + pgAdmin).
  Watch `docker stats` closely after each new stack deploy; GitLab's limit
  has real slack to reclaim (actual usage is well under half its limit) if
  something else needs the headroom.
- **`apps-stack.yml`'s image path and a few backend env var names are
  placeholders** (search for "ADJUST") pending the princess team's actual
  GitLab group/project path and confirmed app config keys.
- **Qdrant's `/bin/sh` isn't bash either** — same as pgAdmin above,
  confirmed live (`cannot create /dev/tcp/...: Directory nonexistent`
  under `/bin/sh`, works fine under `/bin/bash`). Its healthcheck in
  `shared-services-stack.yml` invokes `/usr/bin/bash` explicitly via
  `CMD`, not `CMD-SHELL`, for that reason.
- **Redeploying `data-stack.yml` restarted `data_postgres` briefly**, the
  first time this phase's changes went in — unrelated to anything in this
  phase: `postgres:16-alpine` is an unpinned floating tag, and it had
  moved to a new image digest upstream since Phase 1. `docker stack
  deploy` re-resolves and updates on any digest change regardless of
  which service in the file you actually touched. Recovered cleanly with
  no data loss (bind-mounted volume, unaffected by the image swap), but
  worth knowing before redeploying this file again — any future digest
  drift will do the same thing.
