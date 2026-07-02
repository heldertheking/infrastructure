# Deploying a New Swarm Stack

This guide covers the full lifecycle of adding a new service to the homelab:
setting up a new stack file, routing it through Traefik, deploying via Portainer,
and running the bootstrap agent on every node.

---

## Table of Contents

1. [Concepts](#1-concepts)
2. [Stack file anatomy](#2-stack-file-anatomy)
3. [Traefik routing with labels](#3-traefik-routing-with-labels)
4. [Deploying through Portainer](#4-deploying-through-portainer)
5. [Bootstrap (beszel-agent) on every node](#5-bootstrap-beszel-agent-on-every-node)
6. [First-time cluster setup order](#6-first-time-cluster-setup-order)
7. [Checklist](#7-checklist)

---

## 1. Concepts

### Swarm vs standalone compose
All production stacks are deployed with **`docker stack deploy`** (swarm mode), not
`docker compose up`. This means:

| Compose feature | Swarm equivalent / note |
|---|---|
| `restart:` | `deploy.restart_policy:` |
| `container_name:` | Not supported — omit it |
| `depends_on:` | Ignored — services must handle startup ordering themselves |
| `labels:` (service level) | **`deploy.labels:`** — top-level `labels:` are ignored by Swarm |
| `build:` | Not supported — use a pre-built image |
| `network_mode: host` | Not supported — use overlay networks |

The **bootstrap** stack (`stacks/bootstrap/`) is the only exception — it runs as a
plain `docker compose` on each node individually, because beszel-agent needs a
per-node token.

### Networks
Two shared overlay networks govern traffic flow:

| Network | Owner | Purpose |
|---|---|---|
| `traefik-public` | `stacks/ingress/` | Traefik routes **to** any service on this network |
| `ingress-internal` | `stacks/ingress/` | Traefik ↔ docker-proxy ↔ cloudflared only |

Services that need to be reachable from the outside world must join `traefik-public`.
Services that are purely internal (databases, caches) stay on their own stack-local
overlay and are never added to `traefik-public`.

### Placement constraints
Every service needs a `deploy.placement.constraints` entry, otherwise Swarm will
schedule it on any available node:

| Target | Constraint |
|---|---|
| Any unrestricted node (`services`) | `node.labels.restricted != true` |
| Specifically `core` | `node.labels.role == core` |
| Specifically `games` | `node.labels.role == games` |

---

## 2. Stack file anatomy

Create `stacks/<stack-name>/compose.yaml` and `stacks/<stack-name>/.env`.

```yaml
# stacks/my-app/compose.yaml
services:
  my-app:
    image: example/my-app:latest
    environment:
      TZ: ${TZ}
      SOME_VAR: ${SOME_VAR}
    volumes:
      - ${PATH_APPDATA}/my-app:/data
    networks:
      - traefik-public   # only if this service needs external routing
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.labels.restricted != true   # pin to services node
      labels:
        - "traefik.enable=true"
        - "traefik.http.routers.my-app.rule=Host(`my-app.heldertheking.com`)"
        - "traefik.http.routers.my-app.entrypoints=web"
        - "traefik.http.services.my-app.loadbalancer.server.port=8080"

  my-app-db:
    image: postgres:16-alpine
    environment:
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - ${PATH_APPDATA}/my-app-db:/var/lib/postgresql/data
    networks:
      - my-app-internal   # internal only — NOT on traefik-public
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.labels.restricted != true

networks:
  traefik-public:
    name: traefik-public
    driver: overlay
    external: true          # owned by ingress stack, referenced here
  my-app-internal:
    name: my-app-internal
    driver: overlay
    internal: true          # no external routing
```

```bash
# stacks/my-app/.env
STACK_NAME="my-app"
PATH_APPDATA="/mnt/appdata/${STACK_NAME}"
TZ=Europe/Zurich
DB_PASSWORD=""
SOME_VAR=""
```

### Rules for volumes
- Always scope to the stack's own subfolder: `${PATH_APPDATA}/my-app`, never `/mnt/appdata` directly.
- `PATH_APPDATA` should be `/mnt/appdata/<stack-name>` — set this in the `.env`.
- Host bind mounts (e.g. `/var/run/docker.sock`) only bind on the node where the
  container runs — make sure the service has a matching placement constraint.

---

## 3. Traefik routing with labels

All Traefik labels **must** be inside `deploy.labels:`, not at the top-level `labels:`
key. Swarm ignores top-level labels for service discovery.

### Minimal label set
```yaml
deploy:
  labels:
    - "traefik.enable=true"
    - "traefik.http.routers.<name>.rule=Host(`subdomain.internal.heldertheking.com`)"
    - "traefik.http.routers.<name>.entrypoints=web"
    - "traefik.http.services.<name>.loadbalancer.server.port=<container-port>"
```

Replace `<name>` with a short unique identifier (e.g. `homepage`, `uptime-kuma`).

### Service on multiple networks
If your service joins both `traefik-public` and an internal stack network, add an
explicit network hint so Traefik knows which one to use for routing:

```yaml
deploy:
  labels:
    - "traefik.enable=true"
    - "traefik.docker.network=traefik-public"
    # ... rest of routing labels
```

### Router naming convention
Use the service name as the router/service name, matching the `deploy.labels` key.
Keep it lowercase with hyphens. Router names must be unique across **all stacks** —
Swarm's service discovery is cluster-wide.

---

## 4. Deploying through Portainer

### Prerequisites
- The **ingress** stack must already be deployed (it creates the `traefik-public`
  network that other stacks reference as `external: true`).
- Your `.env` file has the real secrets filled in (never commit secrets).

### Steps

1. **Open Portainer** at `http://10.0.143.10:9000`.

2. Go to **Stacks → Add stack**.

3. Set the **Name** (e.g. `my-app` — must match the folder name and `STACK_NAME`
   in `.env` for path consistency).

4. Choose **Upload** or **Git repository**, then provide the `compose.yaml`.

5. Under **Environment variables**, click **Load variables from .env file** and
   upload your `.env`, or enter them manually. Portainer stores these as stack
   env vars — they do not need to be on the server filesystem.

6. Click **Deploy the stack**.

7. **Verify** — go to **Stacks → my-app → Services** and confirm all replicas are
   running (green). Click a service to see its task logs if something fails.

### Updating an existing stack
- Edit the compose file or env vars in Portainer under **Stacks → my-app → Editor**.
- Click **Update the stack** — Portainer runs `docker stack deploy` with the new
  definition, rolling-updating only changed services.

### Removing a stack
- **Stacks → my-app → Delete this stack** removes all services and stack-local
  networks. `traefik-public` is not removed (it is `external: true` and owned by
  the ingress stack).

---

## 5. Bootstrap (beszel-agent) on every node

The bootstrap stack is **not** a swarm stack. It must be run individually on each
node because beszel-agent uses a per-node token issued by the beszel Hub.

### Get the token for a node
1. Open beszel Hub at `https://monitoring.heldertheking.com`.
2. Go to **Systems → Add system**.
3. Note the **Token** and **Key** shown for that agent.

### Run on each node
SSH into the node (or use `incus exec <node> -- bash`) and run:

```bash
# Create the appdata directory for this node's agent data
mkdir -p /mnt/appdata/bootstrap/beszel_agent

# Copy or create the .env — fill in the node-specific values
cat > /opt/stacks/bootstrap/.env <<EOF
STACK_NAME="bootstrap"
PATH_APPDATA="/mnt/appdata/bootstrap"
NODE_NAME="<node-name>"          # e.g. core, services, games
BESZEL_TOKEN="<token-from-hub>"
BESZEL_KEY="<key-from-hub>"
EOF

# Deploy
cd /opt/stacks/bootstrap
docker compose up -d
```

Repeat for **core**, **services**, and **games**. Each node has its own token.

> **Note:** You can store the compose file on the node at `/opt/stacks/bootstrap/`
> or pull it from this repo. The `.env` file must stay local to the node (it contains
> the per-node secret).

### Verify
```bash
docker compose -f /opt/stacks/bootstrap/compose.yaml ps
```
The agent should show as `running`. In the beszel Hub, the system should appear
online within a few seconds.

---

## 6. First-time cluster setup order

When provisioning from scratch, deploy in this order:

```
1. ./deployment/deploy.sh core     10 manager --swarm init
2. ./deployment/deploy.sh services 20 agent   --swarm join --general
3. ./deployment/deploy.sh games    30 agent   --swarm join

4. Portainer EE first login → http://10.0.143.10:9000  (set admin password within ~5 min)

5. Deploy ingress stack  →  creates traefik-public network + starts Traefik + cloudflared
   └─ Set CF_TUNNEL_TOKEN in the stack env
   └─ Update Cloudflare Tunnel origin URL to http://traefik:80
      (Cloudflare Zero Trust → Networks → Tunnels → <tunnel> → Configure)

6. Deploy monitoring stack
7. Deploy pelican stack
8. Run bootstrap compose on each node (see section 5)
```

Steps 5–8 have no strict ordering relative to each other beyond ingress first
(other stacks need `traefik-public` to exist before they can reference it as external).

---

## 7. Checklist

Use this before deploying any new stack:

- [ ] `compose.yaml` uses `deploy.labels:` — **not** top-level `labels:`
- [ ] Every service has `deploy.placement.constraints`
- [ ] Services needing external routing are on `traefik-public` (`external: true`)
- [ ] Internal-only services (databases, caches) are **not** on `traefik-public`
- [ ] Services on multiple networks have `traefik.docker.network=traefik-public` label
- [ ] No `container_name:`, `restart:`, `depends_on:`, or `network_mode:` keys
- [ ] `PATH_APPDATA` scoped to this stack: `/mnt/appdata/<stack-name>`
- [ ] Router/service names in labels are unique across the whole cluster
- [ ] `.env` has real secrets filled in (never commit actual secret values)
- [ ] `traefik-public` referenced as `external: true` (not re-created)
