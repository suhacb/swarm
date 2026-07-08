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
│   └── nginx/                 # bind-mounted into the proxy stack
├── stacks/
│   ├── infrastructure-stack.yml  # Keycloak + its Postgres DB
│   ├── proxy-stack.yml           # Nginx reverse proxy / TLS termination
│   ├── data-stack.yml            # (planned) shared Postgres/MySQL/phpMyAdmin
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

## Getting started

See [docs/DEPLOY.md](docs/DEPLOY.md). Work is tracked via GitHub issues, one
per phase — see the [issue tracker](https://github.com/suhacb/swarm/issues).

All persistent data (DB volumes, etc.) is bind-mounted from
`/opt/swarm-data/<service>` on the host, kept out of this repo. Secrets are
created directly with `docker secret create` — never committed as plaintext.
