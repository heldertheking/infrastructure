# Infrastructure Recommendations

This document lists missing infrastructure essentials identified during the repository audit. Each item is structured as an actionable task/ticket.

---

## [REC-01] Enable TLS / HTTPS on Traefik

**Priority:** High  
**Stack:** `ingress`

**Problem:** Traefik currently only defines the `web` HTTP entrypoint on port 80. All traffic — including authenticated UIs (Portainer, n8n, Pelican) — is served over plain HTTP. Even behind Cloudflare Tunnel, internal traffic is unencrypted.

**Actions:**
- Add a `websecure` entrypoint (port 443) to `traefik.yaml`.
- Configure ACME/Let's Encrypt with the Cloudflare DNS challenge for automatic certificate provisioning.
- Add an HTTP → HTTPS redirect middleware.
- Update all Traefik labels in every stack to use `entrypoints=websecure` and `tls.certresolver=letsencrypt`.

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

## [REC-07] Remove Direct Host Port Exposure for Media Services

**Priority:** Medium  
**Stack:** `medialab`

**Problem:** Prowlarr, Radarr, Sonarr, Bazarr, and SABnzbd expose ports directly on the host (`10000–10004`). These services should only be accessible internally or through Traefik, not bound to all host interfaces.

**Actions:**
- Remove the `ports:` blocks from Prowlarr, Radarr, Sonarr, Bazarr, and SABnzbd.
- Add Traefik labels to each service so they are accessible via reverse proxy only.
- If local LAN access is needed without Traefik, bind ports to `127.0.0.1` (e.g. `127.0.0.1:10001:7878`).

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

## [REC-09] Pin Container Image Versions

**Priority:** Low  
**Stack:** All

**Problem:** Almost all images use the `:latest` tag. Watchtower may pull a breaking update on a Saturday night. If a rollback is needed, there is no record of what version was previously running.

**Actions:**
- Pin each image to a specific version tag or digest after verifying stability (e.g. `traefik:v3.1`, `mariadb:11.4`).
- Review and update pinned versions as part of a regular maintenance cycle (monthly/quarterly).
- Document the current pinned versions in each stack's README.
- Note: `WATCHTOWER_ROLL_BACK_ON_FAILURE: true` is already set, which mitigates — but does not eliminate — the risk.
