# 🏠 Homelab Infrastructure

A Docker Compose-based homelab split into independent, purpose-built stacks. All stacks connect through a shared `public-net` Docker network and are exposed via a centralised Traefik reverse proxy with a Cloudflare Tunnel for external access.

---

## Architecture Overview

```
Internet
   │
   ▼
Cloudflare Tunnel (cloudflared)
   │
   ▼
Traefik (reverse proxy, HTTP :80)
   │ public-net (external Docker network)
   ├── Homepage        → homepage.<domain>
   ├── Uptime Kuma     → uptime.<domain>
   ├── Beszel Hub      → monitoring.<domain>
   ├── Portainer       → containers.<domain>
   ├── n8n             → automation.<domain>
   ├── Jellyfin        → watch.<domain>
   ├── Seerr           → media.<domain>
   ├── Pelican Panel   → pelican.<domain>
   └── Pelican Wings   → wings.<domain>
```

---

## Stacks

| Stack | Services | README |
|-------|----------|--------|
| [`ingress`](stacks/ingress/) | Traefik, Cloudflared, docker-socket-proxy | [→](stacks/ingress/README.md) |
| [`base`](stacks/base/) | Portainer, Beszel agent | [→](stacks/base/README.md) |
| [`monitoring`](stacks/monitoring/) | Homepage, Uptime Kuma, Watchtower, Beszel hub, docker-socket-proxy | [→](stacks/monitoring/README.md) |
| [`medialab`](stacks/medialab/) | Jellyfin, Seerr, Prowlarr, Radarr, Sonarr, Bazarr, SABnzbd | [→](stacks/medialab/README.md) |
| [`automation`](stacks/automation/) | n8n, Ollama, docker-socket-proxy | [→](stacks/automation/README.md) |
| [`pelican`](stacks/pelican/) | Pelican panel + wings, MariaDB, Redis | [→](stacks/pelican/README.md) |

---

## Network Topology

| Network | Type | Purpose |
|---------|------|---------|
| `public-net` | External (shared) | Cross-stack connectivity; Traefik discovers containers here |
| `ingress-net` | Internal bridge | Traefik ↔ docker-socket-proxy (isolated) |
| `base-net` | Bridge | Portainer internal services |
| `monitoring-net` | Bridge | Monitoring-stack internal services |
| `media-net` | Bridge | Media-stack internal services |
| `automation-net` | Bridge | Automation-stack internal services |
| `pelican-net` | Bridge | Pelican-stack internal services |

> **Note:** `public-net` must be created before starting any stack:
> ```bash
> docker network create public-net
> ```

---

## Storage Layout

| Type | Host Path | Purpose |
|------|-----------|---------|
| SSD (OS) | `/opt/appdata` | App config, databases, certificates |
| HDD | `/mnt/storage-hdd` | Media, backups, game server assets |

Each stack uses:
- `PATH_APPDATA` → `/opt/appdata/<stack-name>`
- `PATH_STORAGE` → `/mnt/storage-hdd/<stack-name>`
- `PATH_LOGS` → `/opt/appdata/<stack-name>/logs` (where applicable)

---

## Quick Start

### Prerequisites

- Docker + Docker Compose v2
- `make` (standard on Linux/macOS)
- A domain managed through Cloudflare

### 1. Create the shared network

```bash
docker network create public-net
```

### 2. Set up environment files

Copy the example env file for each stack you want to deploy and fill in the values:

```bash
make setup
```

Or manually:

```bash
cp stacks/.env.example stacks/ingress/.env
# edit stacks/ingress/.env
```

### 3. Deploy stacks (recommended order)

```bash
make up STACK=ingress
make up STACK=base
make up STACK=monitoring
make up STACK=medialab
make up STACK=automation
make up STACK=pelican
```

### Useful commands

```bash
make up    STACK=<name>   # Start a stack
make down  STACK=<name>   # Stop a stack
make logs  STACK=<name>   # Follow logs
make pull  STACK=<name>   # Pull latest images for a stack
make pull                  # Pull latest images for ALL stacks
```

---

## Incus Cheat Sheet

![img.png](img.png)