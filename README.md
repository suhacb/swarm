# swarm

Single-node Docker Swarm home lab (`suhac.eu`), running on an 8GB Intel Mac
Mini. Domain/DNS/TLS are provisioned outside this repo (Cloudflare + certbot
on the host); this repo covers the Swarm side: overlay networks, stacks, and
service configs.

## Layout

```
├── networks/
│   └── deploy-networks.sh     # creates the 3 encrypted overlay networks
├── images/
│   └── keycloak/Dockerfile    # pre-built ("optimized") Keycloak image
├── config/
│   ├── nginx/                 # bind-mounted into the proxy stack
│   └── gitlab/gitlab.rb.template  # copied (not mounted) to /opt/swarm-data/gitlab
├── scripts/
│   ├── bootstrap-keycloak-admin.sh    # forces password reset + TOTP on admin
│   ├── create-postgres-db.sh          # provisions a role+db+secret per service
│   ├── setup-gitlab-keycloak.sh       # realm/groups/users/MFA/OIDC client for GitLab
│   ├── bootstrap-gitlab-admin.sh      # promotes a user to GitLab admin
│   ├── configure-gitlab-sso-logout.sh # GitLab sign-out also ends the Keycloak session
│   ├── configure-gitlab-oidc-only.sh  # disables local password login + signup for GitLab
│   ├── harden-gitlab-web-ide.sh       # disables the Web IDE's single-origin fallback
│   ├── enable-gitlab-import-sources.sh # enables project import sources (none on by default)
│   ├── harden-keycloak-brute-force.sh # enables lockout on login failures (off by default)
│   └── certbot-deploy-hook.sh         # keeps the readable cert copy in sync
├── stacks/
│   ├── data-stack.yml            # shared Postgres server (+ planned MySQL/phpMyAdmin)
│   ├── infrastructure-stack.yml  # Keycloak
│   ├── gitlab-stack.yml          # GitLab CE
│   ├── proxy-stack.yml           # Nginx reverse proxy / TLS termination
│   ├── search-stack.yml          # (planned) ZincSearch, Qdrant
│   └── apps-stack.yml            # (planned) Angular/Vue/Laravel/.NET apps
└── docs/
    └── DEPLOY.md               # step-by-step deploy runbook
```

## Network tiers

Three encrypted overlay networks, tiered by trust:

- `public-ingress` — Nginx, Keycloak (needs public reachability for login)
- `app-mesh` — frontends, backends, Keycloak (token validation)
- `data-mesh` — backends, Keycloak, all databases (never reaches public-ingress)

## Shared Postgres

One Postgres server (`data-stack.yml`) hosts a separate database + role per
service — cheaper on 8GB than a dedicated instance each. Convention: role
name == database name == service name (e.g. `keycloak`). Provision a new
service with `./scripts/create-postgres-db.sh <service-name>`.

## Getting started

See [docs/DEPLOY.md](docs/DEPLOY.md). Work is tracked via GitHub issues, one
per phase — see the [issue tracker](https://github.com/suhacb/swarm/issues).

All persistent data (DB volumes, etc.) is bind-mounted from
`/opt/swarm-data/<service>` on the host, kept out of this repo. Secrets are
created directly with `docker secret create` — never committed as plaintext.
