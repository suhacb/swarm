# swarm

Single-node Docker Swarm home lab (`suhac.eu`), running on an 8GB Intel Mac
Mini. Domain/DNS/TLS are provisioned outside this repo (Cloudflare + certbot
on the host); this repo covers the Swarm side: overlay networks, stacks, and
service configs.

## Layout

```
├── networks/
│   └── deploy-networks.sh     # creates the encrypted overlay networks
├── images/
│   └── keycloak/Dockerfile    # pre-built ("optimized") Keycloak image
├── config/
│   ├── nginx/                 # bind-mounted into the proxy stack
│   ├── gitlab/gitlab.rb.template  # copied (not mounted) to /opt/swarm-data/gitlab
│   ├── garage/garage.toml.template   # copied ONCE to /opt/swarm-data/garage/garage.toml
│   │                                 # (real secrets baked in, host-only — Garage's image
│   │                                 # has no shell to do runtime substitution itself)
│   ├── pgadmin/config_local.py.template # bind-mounted, secret rendered in at container start
│   └── princess/test-users.csv    # gitignored — 11 princess-test realm test users, never committed
├── scripts/
│   ├── bootstrap-keycloak-admin.sh    # forces password reset + TOTP on admin
│   ├── create-postgres-db.sh          # provisions a role+db+secret per service
│   ├── create-princess-databases.sh   # one role (princess) across 4 databases
│   ├── setup-gitlab-keycloak.sh       # realm/groups/users/MFA/OIDC client for GitLab
│   ├── setup-princess-keycloak.sh     # suhacb realm additions + new princess-test realm
│   ├── setup-pgadmin-keycloak.sh      # OIDC client for pgAdmin, in the suhacb realm
│   ├── setup-garage.sh                # bucket + scoped-key bootstrap for princess
│   ├── bootstrap-gitlab-admin.sh      # promotes a user to GitLab admin
│   ├── configure-gitlab-sso-logout.sh # GitLab sign-out also ends the Keycloak session
│   ├── configure-gitlab-oidc-only.sh  # disables local password login + signup for GitLab
│   ├── harden-gitlab-web-ide.sh       # disables the Web IDE's single-origin fallback
│   ├── enable-gitlab-import-sources.sh # enables project import sources (none on by default)
│   ├── harden-keycloak-brute-force.sh # enables lockout on login failures (off by default)
│   └── certbot-deploy-hook.sh         # keeps the readable cert copy in sync
├── stacks/
│   ├── data-stack.yml            # shared Postgres server + pgAdmin4 (Keycloak SSO)
│   ├── infrastructure-stack.yml  # Keycloak
│   ├── gitlab-stack.yml          # GitLab CE (+ bundled Container Registry)
│   ├── gitlab-runner-stack.yml   # GitLab Runner, Docker executor
│   ├── proxy-stack.yml           # Nginx reverse proxy / TLS termination
│   ├── shared-services-stack.yml # Qdrant, ZincSearch, Garage, OnlyOffice (all internal-only)
│   └── apps-stack.yml            # princess frontend/backend, prod + staging
└── docs/
    └── DEPLOY.md               # step-by-step deploy runbook
```

## Network tiers

Encrypted overlay networks, tiered by trust:

- `public-ingress` — Nginx, Keycloak (needs public reachability for login)
- `app-mesh` — frontends, backends, Keycloak (token validation), plus
  Qdrant/ZincSearch/Garage/OnlyOffice — deliberately internal-only, no
  public hostname or admin UI exposed for any of them (see "Admin UI
  access" below for why)
- `data-mesh` — backends, Keycloak, all databases (never reaches public-ingress)
- `ci-mesh` — the one attachable exception: GitLab Runner's Docker executor
  creates job containers via plain `docker run`, not Swarm services, so they
  can only join a network that allows that

## Shared Postgres

One Postgres server (`data-stack.yml`) hosts a separate database + role per
service — cheaper on 8GB than a dedicated instance each. Convention: role
name == database name == service name (e.g. `keycloak`). Provision a new
service with `./scripts/create-postgres-db.sh <service-name>`.

## Shared Qdrant / ZincSearch / Garage

`shared-services-stack.yml` runs one instance of each, used by any service
that needs a vector index, full-text index, or S3-compatible object storage —
same reasoning as the shared Postgres server. Naming convention: production
names are bare (`princess` bucket, `princess_*` collections/indices), every
other environment prefixes its own name — hyphenated for Garage buckets
(`staging-princess`, `e2e-princess`, `test-princess`; Garage enforces S3
bucket-naming rules, which reject underscores), underscored everywhere else
(`staging_princess_*`, `e2e_princess_*`, `test_princess_*` collections/
indices). Only Garage enforces this server-side (via scoped access keys, see
`scripts/setup-garage.sh`); Qdrant/ZincSearch naming is up to the consuming
app's own config.

## Admin UI access (pgAdmin, Qdrant, ZincSearch, Garage)

**pgAdmin** is gated behind Keycloak SSO (`suhacb` realm), a dedicated
non-obvious-username account (`corvid`) in its own `pgadmin-admins`
group — enforced both by a pre-provisioned pgAdmin account and a real
`OAUTH2_ADDITIONAL_CLAIMS` group check in its own native OIDC config.

**Qdrant, ZincSearch, and Garage have no admin UI exposed at all** — a
Keycloak+`oauth2-proxy` gate for them was built and verified working,
then deliberately reverted. The original ask was LAN-only access, which
is impossible on this Docker Desktop for Mac host regardless of what
auth sits behind it (its VM-boundary NAT rewrites every client's source
IP before any container sees it). Once "reachable from the whole
internet, gated by login" was the only real option, native logins
turned out not to exist for two of the three (Qdrant only supports an
API key, not an interactive login; Garage's web UI has no auth at all),
so the simplest genuinely-secure answer was to just not expose any of
them externally — see `docs/DEPLOY.md`'s Phase 3 section for the full
story. All three are `app-mesh` only; internal backends reach them
directly by service name, unaffected.

## Getting started

See [docs/DEPLOY.md](docs/DEPLOY.md). Work is tracked via GitHub issues, one
per phase — see the [issue tracker](https://github.com/suhacb/swarm/issues).

All persistent data (DB volumes, etc.) is bind-mounted from
`/opt/swarm-data/<service>` on the host, kept out of this repo. Secrets are
created directly with `docker secret create` — never committed as plaintext.
