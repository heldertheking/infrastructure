# Stack: monitoring

Observability, uptime tracking, dashboard, and automatic container updates.

## Services

| Service | Image | Purpose |
|---------|-------|---------|
| `homepage` | `ghcr.io/gethomepage/homepage:latest` | Customisable homelab dashboard |
| `uptime-kuma` | `louislam/uptime-kuma:2` | Service uptime monitoring with alerting |
| `beszel` | `henrygd/beszel:latest` | System resource monitoring hub (pairs with `beszel-agent` in the `base` stack) |
| `watchtower` | `nickfedor/watchtower:latest` | Automatically updates container images on a schedule (Saturdays 05:00) |
| `docker-proxy-monitoring` | `tecnativa/docker-socket-proxy` | Read-only Docker API proxy for safe container inspection by monitoring services |

### Interactions

```
homepage         → public-net    → exposed via Traefik (homepage.<domain>)
                 → monitoring-net → reads /mnt/storage (RO) for disk widget

uptime-kuma      → public-net    → exposed via Traefik (uptime.<domain>)
                 → pings HC_PING_UUID endpoint on Healthchecks.io for dead-man's switch

beszel           → public-net    → exposed via Traefik (monitoring.<domain>)
                 → receives metrics from beszel-agent (base stack)

watchtower       → monitoring-net → reads Docker socket via docker-proxy-monitoring
                 → sends notifications via NOTIFY_URL (Shoutrrr-compatible)

docker-proxy-monitoring → monitoring-net (internal only)
```

## Prerequisites

- `public-net` must exist: `docker network create public-net`
- `NOTIFY_URL` must be a [Shoutrrr](https://containrrr.dev/shoutrrr/v0.8/services/overview/) compatible URL (e.g. Discord, Telegram, Gotify)
- `HC_PING_UUID` is a [Healthchecks.io](https://healthchecks.io) check UUID used as a dead-man's switch for Uptime Kuma
- Homepage configuration files must be placed in `PATH_APPDATA/homepage/`

## Setup

```bash
cp stacks/.env.example stacks/monitoring/.env
# Fill in the required variables (see below)
docker compose -f stacks/monitoring/compose.yaml --env-file stacks/monitoring/.env up -d
```

Or with the root Makefile:

```bash
make up STACK=monitoring
```

## Configuration Variables

See [`.env.monitoring.example`](.env.monitoring.example) for a ready-to-copy template.

| Variable | Description | Example |
|----------|-------------|---------|
| `STACK_NAME` | Compose project name | `monitoring` |
| `PATH_APPDATA` | App data directory | `/opt/appdata/monitoring` |
| `PATH_STORAGE` | Storage path mounted read-only by homepage | `/mnt/storage-hdd` |
| `PATH_LOGS` | Log directory | `/opt/appdata/monitoring/logs` |
| `TZ` | Timezone | `Europe/Zurich` |
| `DOMAIN` | Primary domain | `example.com` |
| `NOTIFY_URL` | Shoutrrr notification URL for Watchtower | *(secret — never commit)* |
| `HC_PING_UUID` | Healthchecks.io check UUID (dead-man's switch) | *(secret — never commit)* |

## Internal Port Range

`10 000 – 10 004` (reserved for medialab stack direct-port services)
