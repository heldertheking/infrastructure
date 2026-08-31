# Infrastructure Recommendations

This document lists missing infrastructure essentials identified during the repository audit. Each item is structured as an actionable task/ticket.

---

## [REC-01] ~~Enable TLS / HTTPS on Traefik~~ ✅ Handled by Cloudflare

**Status:** Not required — Cloudflare Tunnel terminates TLS at the edge. All public-facing services are served over HTTPS without any additional Traefik configuration.

**Note:** Internal host-to-Traefik traffic (within the homelab) travels over HTTP on `public-net`. This is acceptable for a single-host setup where all containers are co-located, but if the homelab spans multiple physical hosts consider adding a local TLS certificate (e.g. via a self-signed CA or `mkcert`) to encrypt intra-host traffic too.

---

## [REC-02] Implement a Secrets Manager

**Priority:** High  
**Stack:** All

**Problem:** All secrets (API tokens, DB passwords, tunnel tokens) are stored as plain-text values in `.env` files on disk. If the host is compromised, all credentials are immediately exposed. There is no audit trail for secret access.

**Actions:**
- Evaluate [Infisical](https://infisical.com) (self-hosted), [HashiCorp Vault](https://www.vaultproject.io), or Docker Secrets (Swarm) as a replacement.
- At minimum, ensure `.env` files are owned by root and readable only by root (`chmod 600`).
- Consider using [infisical-agent](https://infisical.com/docs/agent/overview) to inject secrets into containers at runtime without storing them in `.env` files.

---

## [REC-03] Centralised Log Aggregation

**Priority:** Medium  
**Stack:** New `logging` stack

**Problem:** Container logs are written to local volume directories per container. There is no centralised log viewer, search, or retention policy. Debugging cross-stack issues requires SSHing in and grepping multiple directories.

**Actions:**
- Add a `logging` stack with [Grafana Loki](https://grafana.com/oss/loki/) + [Grafana](https://grafana.com) + [Promtail](https://grafana.com/docs/loki/latest/send-data/promtail/) (or [Alloy](https://grafana.com/docs/alloy/latest/)).
- Configure Promtail to scrape Docker container logs via the Docker socket proxy.
- Add Grafana as an additional panel in Homepage.
- Define log retention policies (e.g. 30 days).

---

## [REC-04] Automated Backup Strategy

**Priority:** High  
**Stack:** New `backup` stack

**Problem:** There is no automated backup of `/opt/appdata` or `/mnt/storage-hdd`. A disk failure or misconfiguration would result in permanent data loss for all service configurations and media metadata.

**Actions:**
- Add a `backup` stack using [Restic](https://restic.net) or [Borgmatic](https://torsion.org/borgmatic/).
- Schedule nightly backups of `/opt/appdata` (config + databases) to an offsite location (e.g. Backblaze B2, S3-compatible storage).
- For media, evaluate whether a separate cold-storage sync (e.g. rclone) is appropriate.
- Test and document the restore procedure.

---

## [REC-05] Automated Database Backups (Pelican MariaDB)

**Priority:** High  
**Stack:** `pelican`

**Problem:** Pelican's MariaDB container has no scheduled dump or backup job. A database failure would destroy all game server configurations, user accounts, and panel data.

**Actions:**
- Add a `db-backup` sidecar service to the pelican stack using `mariadb-dump` or [MariaDB Backup](https://mariadb.com/kb/en/mariabackup/).
- Schedule daily logical dumps to a persistent volume (e.g. `PATH_STORAGE/db-backups`).
- Include these dumps in the scope of [REC-04] offsite backup.

---

## [REC-06] Centralised Alerting Channel

**Priority:** Medium  
**Stack:** `monitoring`

**Problem:** Watchtower is configured with a `NOTIFY_URL` but this channel is undocumented and not shared across services. Uptime Kuma, Beszel, and other services each have their own notification configurations, which are inconsistent and may not be set up after a fresh deploy.

**Actions:**
- Decide on a single notification channel (e.g. Discord, Telegram, Gotify, ntfy).
- Document the chosen channel URL format in all `.env.<stack>.example` files.
- Add [Gotify](https://gotify.net) or [ntfy](https://ntfy.sh) to the `monitoring` stack as a self-hosted notification hub.
- Ensure Uptime Kuma, Beszel, Watchtower, and any future services all point to this hub.

---

## [REC-07] Restrict Internal-Only Services — Remove Direct Host Port Exposure

**Priority:** Medium  
**Stack:** `medialab`

**Problem:** Prowlarr, Radarr, Sonarr, Bazarr, and SABnzbd bind ports `10000–10004` directly on all host interfaces. This means they are reachable by anything that can reach the host's IP — including other LAN devices and (if the host firewall is misconfigured) the internet. These services have no authentication by default and should never be publicly routable.

**Context:** Unlike the public-facing services (Jellyfin, Seerr, etc.) these tools are operational back-ends. They don't need to be externally accessible — only reachable from the same host or LAN.

### Recommended Approach: Route everything through Traefik + restrict via Cloudflare Access

Since Cloudflare Tunnel is already in place you have two clean options:

#### Option A — Traefik-only, LAN-inaccessible (most secure)

1. Remove the `ports:` blocks entirely from Prowlarr, Radarr, Sonarr, Bazarr, and SABnzbd.
2. Add Traefik labels so they get a subdomain (e.g. `radarr.<domain>`).
3. In the Cloudflare Zero Trust dashboard, add a **Cloudflare Access policy** on those subdomains requiring authentication (e.g. One-Time Pin, GitHub SSO, or an allowed email list) before the tunnel forwards traffic.
4. Services become reachable only via `https://radarr.<domain>` behind Cloudflare Access — zero open ports on the host.

#### Option B — Traefik-only, LAN-accessible without Cloudflare (for offline/local use)

1. Remove the `ports:` blocks.
2. Add Traefik labels pointing to `internal.<domain>` subdomains.
3. Set up a **local DNS override** (e.g. via Pi-hole, AdGuard Home, or your router's DNS) so `*.internal.example.com` resolves to the homelab IP instead of going through Cloudflare.
4. Add a second Traefik entrypoint bound only to the LAN interface IP (e.g. `192.168.x.x:8080`) for these internal routes.

#### Option C — Minimum-effort: bind ports to localhost only

If routing through Traefik is not immediately feasible, at least restrict the bindings to the loopback interface so they cannot be reached from the network:

```yaml
ports:
  - "127.0.0.1:10001:7878"  # Radarr — only accessible from the host itself
```

This prevents LAN/internet exposure while keeping the same URLs for local use (via SSH port-forwarding or when accessing from the host directly).

**Actions:**
- Choose Option A (preferred), B, or C above.
- Remove or update the `ports:` blocks in `stacks/medialab/compose.yaml`.
- Update `stacks/medialab/README.md` to reflect the new access method.
- If using Option A: configure Cloudflare Access policies for the internal subdomains.
- If using Option B: document the local DNS setup in the medialab README.

---

## [REC-08] Add Docker Healthchecks to Critical Services

**Priority:** Low  
**Stack:** All

**Problem:** Most services have no Docker `healthcheck` defined. This means Docker (and Watchtower) cannot distinguish between a container that is running and one that is running but unhealthy, making auto-restart and dependency ordering unreliable.

**Actions:**
- Add `healthcheck` blocks to at minimum: Traefik, Jellyfin, n8n, Pelican panel, MariaDB, Redis.
- Use simple HTTP or TCP checks where possible (e.g. `curl -f http://localhost:PORT/health`).
- Review container startup ordering with `depends_on: condition: service_healthy` where appropriate.

---

## [REC-09] Pin Container Image Versions — Watchtower Interaction

**Priority:** Low  
**Stack:** All

**Problem:** Almost all images use the `:latest` tag. This can lead to unexpected breaking changes when Watchtower pulls a new image on its Saturday schedule.

### How Watchtower behaves with pinned images

| Pin style | Example | Watchtower behaviour |
|-----------|---------|----------------------|
| `:latest` | `traefik:latest` | Updates whenever a new `:latest` is pushed — least predictable |
| Version tag | `traefik:v3.1` | Still updates if the tag is re-pushed with a new digest (maintainers do this for patch releases) |
| Immutable digest | `traefik@sha256:abc…` | Watchtower **cannot** update it — digest is immutable; requires manual update |
| Disabled per-container | label `com.centurylinklabs.watchtower.enable=false` | Watchtower skips this container entirely regardless of tag |

**Recommendation:** Use **minor-version tags** (e.g. `traefik:v3.1`, `mariadb:11.4`) and let Watchtower handle patch updates automatically. For critical stateful services (MariaDB, Redis, Pelican) add `com.centurylinklabs.watchtower.enable=false` and update them manually after reading the changelog.

**Actions:**
- Replace `:latest` with the current stable minor-version tag for each image.
- Add `com.centurylinklabs.watchtower.enable: "false"` label to `pelican-db` (MariaDB) and `pelican-redis` (Redis) to prevent unattended major/minor version bumps.
- Document the current pinned versions in each stack's README under a "Image Versions" section.
- Schedule a monthly review to bump pinned versions.

> `WATCHTOWER_ROLL_BACK_ON_FAILURE: true` is already configured, which automatically reverts a container if the new image fails to start — this is a good safety net but not a substitute for pinning.

