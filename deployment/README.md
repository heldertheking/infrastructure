# Incus + Docker cloud-init setup

Files:
- `incus-profile.yaml` — Incus profile enabling Docker-in-container (nesting).
- `network-config-template.yaml` — static IP template (`{{IP}}` placeholder), on the `10.0.143.0/24` range, gateway `10.0.143.1`.
- `user-data-agent.yaml` — Docker + native Glances service + Portainer **Agent** container. Use for all worker nodes.
- `user-data-manager.yaml` — Docker + native Glances service + Portainer **EE** container. Use for exactly one node.
- `deploy.sh` — launches an instance, substituting the IP and picking the right user-data file.

## 0. One-time host-side prerequisites (already done)

Your bridge is already configured correctly:

```
ipv4.address: 10.0.143.1/24
ipv4.dhcp: "false"
ipv4.nat: "true"
```

This is exactly what's needed — NAT enabled, DHCP off (since you're assigning
static IPs), gateway at `.1`. The netplan config in these files also sets an
explicit default route and DNS on each container, which was the other
common cause of blocked outbound traffic (static IP applied by hand with no
gateway/DNS ever set).

## 1. Create the Docker-capable profile (once)

```bash
incus profile create docker
incus profile edit docker < incus-profile.yaml
```

> If your bridge isn't named `incusbr0`, edit the `network:` value inside
> `incus-profile.yaml` before running the above.

## 2. Launch nodes

```bash
chmod +x deploy.sh

# workers (Portainer Agent + Glances)
./deploy.sh node1 10 agent
./deploy.sh node2 11 agent
./deploy.sh node3 12 agent

# the one manager (Portainer EE + Glances)
./deploy.sh node-mgr 20 manager
```

This gives you `10.0.143.10`, `.11`, `.12`, `.20` etc., each with:

- `/opt/appdata/<node>` (host) → `/mnt/appdata` (container)
- `/mnt/storage-hdd/<node>` (host) → `/mnt/storage` (container)

created and attached automatically by `deploy.sh`. Because the host-side path
depends on the instance name, these are added as per-instance disk devices
after `incus launch`, not baked into the shared `docker` profile (a profile
value is identical for every instance that uses it, so `<node>` can't live
there). If `/opt` or `/mnt/storage-hdd` require root to create subdirectories
on your host, run `deploy.sh` with `sudo` or pre-create the two node
directories yourself before launching.

Watch progress on any node with:

```bash
incus exec node1 -- tail -f /var/log/cloud-init-output.log
```

_If it is taking really long for each line, disable `ipv6.address` using `incus network unset incusbr0 ipv6.address`._

## 3. First login

- **Portainer EE UI**: `http://10.0.143.20:9000` — plain HTTP, since TLS is
  handled externally by Traefik/cloudflared. You must set the admin
  password within ~5 minutes of first boot or the instance locks and needs
  a container restart (`docker restart portainer`).
- **Connect agents to EE**: in Portainer, *Environments → Add environment →
  Agent*, and point it at each worker's IP on port `9001`. This channel
  stays TLS internally (it's Portainer's own control connection to the
  agent, not something Traefik/cloudflared need to see) — nothing to
  change there.
- **Glances web UI**: `http://<node-ip>:61208` on every node (manager included)
  — already plain HTTP.

## Behind Traefik / cloudflared

Since TLS termination happens at Traefik + the cloudflared tunnel, nothing
inside these containers needs certs or HTTPS listeners. Point Traefik's
routers at:

- `http://10.0.143.20:9000` — Portainer EE UI
- `http://<node-ip>:61208` — Glances, per node

No extra flags or config were needed to get Portainer onto plain HTTP; it
serves both `9000` (HTTP) and `9443` (HTTPS) by default, so this setup just
publishes/uses `9000` and skips `9443` entirely.

## Notes / things you may want to tweak

- Docker is installed from Docker's own apt repo (not Ubuntu's), so you get
  current releases and `docker compose` (plugin) out of the box.
- Glances runs as the distro's `glances.service`, started in web mode
  (`-w --bind 0.0.0.0`) via `/etc/default/glances` — nothing containerized.
- Portainer is a single `docker run` container in both cases, per your
  preference — agent on workers, portainer-ee on the manager.
- OS is `images:ubuntu/24.04/cloud` (Incus's default `images:` remote, cloud-init-enabled variant — the plain `ubuntu/24.04` alias has no cloud-init and won't work here), a minimal cloud image — no GUI,
  small footprint, and matches your host distro so behavior stays
  consistent. Debian 12 (`images:debian/12/cloud`) is a solid lighter-weight
  alternative if you want to trim further; the cloud-init here works
  unchanged on it (just swap the docker apt repo URL from `/ubuntu/` to
  `/debian/`).
- The `docker` profile is currently running in privileged mode. This is required so that docke can run containers.
- If glances is running in `server/client` mode you can run the following one-liner to change the binding to `0.0.0.0` and change into `-w (web mode)`:
  ```bash
  incus exec <node> -- bash -c "sudo sed -i 's|^ExecStart=.*|ExecStart=/usr/bin/glances -w -B 0.0.0.0|' /lib/systemd/system/glances.service && sudo systemctl daemon-reload && sudo systemctl restart glances.service"
  ```
