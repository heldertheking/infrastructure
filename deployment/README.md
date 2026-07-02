# Incus + Docker + Swarm cloud-init setup

Files:
- `incus-profile.yaml` — Incus profile enabling Docker-in-container (nesting). Unchanged from before.
- `network-config-template.yaml` — static IP template (`{{IP}}` placeholder), on `10.0.143.0/24`, gateway `10.0.143.1`. Unchanged.
- `user-data.yaml` — cloud-init for every node: Docker + native Glances only. **Portainer, Swarm init/join, and node labeling all moved out of cloud-init and into `deploy.sh`**, run post-boot via `incus exec`. This replaces the old separate `user-data-agent.yaml` / `user-data-manager.yaml` (now identical for every node - the Portainer/Swarm role is decided by `deploy.sh` flags, not baked into the image).
- `deploy.sh` — launches an instance, attaches bind mounts, waits for cloud-init, then (optionally) bootstraps/joins the swarm and starts the right Portainer container.

## 1. Create the Docker-capable profile (once, if not already done)

```bash
incus profile create docker
incus profile edit docker < incus-profile.yaml
```

## 2. Deploy nodes - order matters

The node that runs `--swarm init` must exist before any `--swarm join` node,
since joining reads the manager's IP + join token from `.swarm-state/`
(created next to `deploy.sh` on first init).

```bash
chmod +x deploy.sh

./deploy.sh core     10 manager --swarm init
./deploy.sh services 20 agent   --swarm join --general
./deploy.sh games    30 agent   --swarm join
```

What each flag does:
- 3rd argument (`agent`/`manager`) is the **Portainer** role - exactly one node should be `manager` (runs Portainer EE).
- `--swarm init` - this node creates the swarm and becomes its (sole) manager. Also deploys a cluster-wide Portainer Agent as a `global` service (see below).
- `--swarm join` - joins the swarm `init` created.
- `--general` - marks this node as the **unrestricted default target** for stacks (see Placement, below). Only put this on one node - `services` in this example.

You can still deploy a node without `--swarm` at all (falls back to the old standalone-Agent-container behavior), if you ever want a one-off node outside the cluster.

## 3. Why Portainer Agent is no longer per-node

Swarm exposes the entire cluster's state through **any single node's** Docker
API - so Portainer doesn't need one Agent connection per host anymore. `--swarm
init` deploys one Agent as a `mode: global` service, meaning Swarm
automatically runs a replica on every current *and future* node. Point
Portainer at any one node's IP on port `9001` and it sees the whole cluster.
This also means adding a 4th node later needs no extra Portainer
configuration - it just needs `--swarm join`.

## 4. Placement: keeping `core`/`games` opt-in only

**What Swarm actually guarantees:** placement constraints are fully
enforced for the *positive* case. A stack with
`node.labels.role==core` is 100% guaranteed to only ever land on `core` -
this is engine-enforced, not a convention.

**What Swarm does *not* have:** a "default-deny" scheduling mode. There is
no setting that makes an *unconstrained* stack refuse to land on
`core`/`games` automatically - Swarm's scheduler is free to place
unconstrained work on any active node. (Node "Drain"/"Pause" availability
looks like it might help here, but it doesn't: those states block *all* new
task assignment unconditionally, including tasks explicitly targeted at that
node via a constraint - so they're useless for "opt-in only" and are really
just for maintenance mode.)

So the actual mechanism is a **constraint you always include**, backed by
labels `deploy.sh` already sets for you:

- Every node gets `role=<name>` (`role=core`, `role=services`, `role=games`).
- Every node *except* the one deployed with `--general` also gets `restricted=true`.

**Default stack** (lands on `services` only, by convention):
```yaml
services:
  my-app:
    image: whatever
    deploy:
      placement:
        constraints:
          - node.labels.restricted != true
```

**Explicitly targeting `core` or `games`:**
```yaml
services:
  my-core-only-app:
    image: whatever
    deploy:
      placement:
        constraints:
          - node.labels.role == core
```

Since this relies on the constraint actually being present, the practical
way to not have to remember it every time is to save the "default stack"
snippet above as a **Portainer Custom Template**, so new stacks start from
it pre-filled. Nothing stops a stack from omitting the constraint entirely
and landing anywhere - that's a discipline/template thing, not something
`deploy.sh` or Swarm can force.

## 5. Resilience characteristics of this setup

Single-manager swarm (just `core`) is a deliberate tradeoff for a 3-node
homelab: if `core` goes down, `services`/`games` keep running whatever
they were already running - Swarm workers cache desired state and don't
need the manager to keep existing tasks alive. What you lose while `core`
is down is the ability to *change* anything (deploy, scale, update) until
it's back, since only managers can schedule. This matches the resilience
goal from earlier (services/games staying reachable if core crashes)
without needing a 3-manager quorum setup, which is arguably overkill here.

## 6. Networking - already handled

Swarm needs `2377/tcp` (control), `7946/tcp+udp` (gossip), and `4789/udp`
(overlay data plane) open between nodes. The `ufw route allow in/out on
incusbr0` rules from earlier already cover all traffic across the bridge,
so no additional firewall changes are needed for Swarm specifically.

## 7. Shared appdata/storage (not per-node)

`core`, `services`, and `games` are all Incus containers on the **same
physical host** - so `/opt/appdata` and `/mnt/storage-hdd` aren't distributed
storage, they're one disk. `deploy.sh` mounts the *same* host path into
every node's `/mnt/appdata` and `/mnt/storage` (not a per-node subfolder like
before). This matters for Swarm specifically: a stack constrained to
`services` today and moved to `games` tomorrow still sees its data, since
every node's mount points at the identical host directory. No node-specific
data bookkeeping needed.

The trade-off is that this mount is deliberately broad at the Incus level
(host → Incus container), since Incus doesn't know in advance what stacks
will run there. The actual scoping happens one layer down, in each stack's
own compose file - never mount the whole `/mnt/appdata` tree into an
individual service container, only that stack's own subfolder:

```yaml
# .env for the "ingress" stack
PATH_APPDATA=/mnt/appdata/ingress
PATH_STORAGE=/mnt/storage/ingress
```
```yaml
# docker-compose.yml
services:
  traefik:
    image: traefik:latest
    volumes:
      - ${PATH_APPDATA}/traefik:/etc/traefik   # only this stack's own folder
```

Like the placement constraints in section 4, this is a convention backed by
how you write compose files, not something Docker enforces on its own - a
container running as root could still technically browse the wider tree if
a stack's compose file carelessly mounts more than its own subfolder.

Because the `docker` profile runs `security.privileged: "true"`, there's no
Incus UID mapping/shift happening - root inside any container is root on the
host, so file ownership stays consistent across nodes without extra
reconciliation.

**Migrating existing data**: if you already have per-node folders from the
earlier scheme (e.g. `/opt/appdata/core`, `/opt/appdata/services`, and the
equivalent under `/mnt/storage-hdd/<node>`), you'll want to consolidate them
into the new stack-based layout before switching over, e.g.:
```bash
mkdir -p /opt/appdata/ingress
mv /opt/appdata/core/traefik /opt/appdata/ingress/traefik

mkdir -p /mnt/storage-hdd/media
mv /mnt/storage-hdd/services/movies /mnt/storage-hdd/media/movies
```
Do this per-app, since the old layout was organized by *node* and the new
one is organized by *stack* - there's no automatic 1:1 mapping between them.

## 8. First login / everything else

Unchanged from before:
- **Portainer EE UI**: `http://10.0.143.10:9000` (or whichever node is `manager`) - plain HTTP, TLS handled externally by Traefik/cloudflared. Set the admin password within ~5 minutes of first boot.
- **Glances web UI**: `http://<node-ip>:61208` on every node.
- Docker installed from Docker's own apt repo; `docker compose` plugin included.
- OS is `images:ubuntu/24.04/cloud`.
- The `docker` profile runs privileged + AppArmor-unconfined - required for Docker-in-Incus to work (see `raw.lxc` in `incus-profile.yaml`).
- If a node is taking a long time on `apt-get update`/mirrors, check `incus network unset incusbr0 ipv6.address` and the `Acquire::ForceIPv4` file in `user-data.yaml` (both already applied here).
