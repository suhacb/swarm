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
- **Keycloak admin console + Admin REST API, LAN-only** (`location /admin`
  in `keycloak.conf`) — blocked entirely unless accessed via
  `keycloak.lan.suhac.eu`. Real users only ever need `/realms/*` (login,
  OIDC); this repo's own automation scripts talk to Keycloak directly
  inside the container (`docker exec`), never through this proxy, so
  they're unaffected. This was a judgment call the user made explicitly —
  the tradeoff is losing admin console access from outside the LAN
  entirely (no VPN currently), in exchange for meaningfully shrinking the
  attack surface of the most sensitive interface on the box.

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
  started at `gitlab.lan.suhac.eu`. This previously hung partway through
  login from inside the LAN — `dig` resolving the hostname correctly wasn't
  sufficient proof it'd work, since browsers increasingly default to their
  own DNS-over-HTTPS resolver (Cloudflare, Google), bypassing router-local
  DNS overrides entirely and getting the real public IP instead. Resolved by
  adding an explicit Local DNS Record override on the router (UDR7) for
  `gitlab.suhac.eu` → the box's LAN IP, the same fix already in place for
  `keycloak.suhac.eu`, so both hostnames now behave identically from inside
  the LAN regardless of which resolver answers. **Under reconsideration**:
  the `.lan.suhac.eu` hostnames may be dropped entirely — with the router
  override in place, the public hostname already works fine from the LAN, so
  the second hostname isn't adding real value, just extra surface area in
  redirects/env vars/configs to keep in sync.

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

`registry.suhac.eu` / `registry.lan.suhac.eu` need no new DNS or cert work —
both are one level deep, already covered by the existing wildcard record and
cert.

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
