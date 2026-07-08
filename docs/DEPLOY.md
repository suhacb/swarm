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
sudo mkdir -p /opt/swarm-data/keycloak-db
sudo chown "$(whoami)" /opt/swarm-data/keycloak-db
```

## 4. Create secrets

Run these by hand — the values never get typed into a file or committed.

```bash
openssl rand -base64 32 | docker secret create keycloak_db_password -
openssl rand -base64 32 | docker secret create keycloak_admin_password -
```

To rotate a secret later: create a new one with a version suffix (Swarm
secrets are immutable — you can't update in place), e.g.
`keycloak_admin_password_v2`, update the stack file to reference it, then
`docker stack deploy` again.

## 5. Build the optimized Keycloak image

```bash
docker build -t local/keycloak:26.0-optimized -f images/keycloak/Dockerfile .
```

Re-run this whenever `images/keycloak/Dockerfile` changes or you bump the
Keycloak version — check
[quay.io/repository/keycloak/keycloak?tab=tags](https://quay.io/repository/keycloak/keycloak?tab=tags)
for the current release before bumping.

## 6. Deploy the stacks

```bash
docker stack deploy -c stacks/infrastructure-stack.yml infra
docker stack deploy -c stacks/proxy-stack.yml proxy
```

## 7. Verify

```bash
docker service ls
docker service logs -f infra_keycloak
docker service logs -f proxy_nginx
```

Then browse to `https://keycloak.suhac.eu` and `https://keycloak.lan.suhac.eu`
— both should hit the same Keycloak instance. Log in to the admin console at
`/admin` with user `admin` and the password you put in
`keycloak_admin_password`.

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
