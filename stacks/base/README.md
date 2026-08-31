# Stack: base

Foundation management services — container administration and system-level metrics collection.

## Services

| Service | Image | Purpose |
|---------|-------|---------|
| `portainer` | `portainer/portainer-ee:latest` | Web UI for managing Docker containers, images, and stacks |
| `beszel-agent` | `henrygd/beszel-agent:alpine` | Lightweight agent that reports system and container metrics to the Beszel hub (monitoring stack) |

### Interactions

```
portainer      → public-net   → exposed via Traefik (containers.<domain>)
               → base-net     → internal network

beszel-agent   → host network → reads /var/run/docker.sock, NVMe & SATA device stats
               → reports to https://monitoring.<domain> (Beszel hub in monitoring stack)
```

The Beszel agent runs in `network_mode: host` and requires `SYS_ADMIN` + `SYS_RAWIO` capabilities to read SMART data from disk devices. Adjust the `devices` list in `compose.yaml` to match your hardware.

## Prerequisites

- Docker networks `public-net` and `base-net` (base-net is created automatically by Compose)
- `public-net` must already exist: `docker network create public-net`
- The `monitoring` stack must be running so the Beszel hub is reachable for `HUB_URL`
- `BESZEL_TOKEN` and `BESZEL_KEY` obtained from the Beszel hub UI after adding this host

## Setup

```bash
cp stacks/.env.example stacks/base/.env
# Fill in the required variables (see below)
docker compose -f stacks/base/compose.yaml --env-file stacks/base/.env up -d
```

Or with the root Makefile:

```bash
make up STACK=base
```

Alternatively, stacks can be deployed and managed via **Portainer** (itself part of this stack) using its GitOps / Stack feature — point it at this repository and select the relevant `compose.yaml`.

## Configuration Variables

See [`.env.base.example`](.env.base.example) for a ready-to-copy template.

| Variable | Description | Example |
|----------|-------------|---------|
| `STACK_NAME` | Compose project name | `base` |
| `PATH_APPDATA` | App data directory | `/opt/appdata/base` |
| `TZ` | Timezone | `Europe/Zurich` |
| `DOMAIN` | Primary domain | `example.com` |
| `BESZEL_TOKEN` | Beszel agent token (from hub UI) | *(secret — never commit)* |
| `BESZEL_KEY` | Beszel agent key (from hub UI) | *(secret — never commit)* |
