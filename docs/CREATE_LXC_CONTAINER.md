# Incus Homelab Cheatsheet
> Ubuntu host · Wi-Fi (`wlp0s20f3`) · Incus bridge `br0` (`10.145.236.0/24`)

---

## 1. Host Prerequisites

### Install Incus (no snap)
```bash
sudo apt install -y incus
sudo adduser $USER incus-admin
newgrp incus-admin
```

### Initialize Incus
```bash
sudo incus admin init
# Clustering: no
# Storage pool name: homelab-storage
# Storage backend: dir
# Create new local bridge: yes
# Bridge name: br0
# IPv4 address: auto
# IPv6 address: auto
# Available over network: no
# Auto-update images: yes
```

### Fix iptables for WiFi NAT (run after every reboot unless persisted)
```bash
sudo iptables -t nat -A POSTROUTING -s 10.145.236.0/24 -o wlp0s20f3 -j MASQUERADE
sudo iptables -I FORWARD 1 -i br0 -o wlp0s20f3 -j ACCEPT
sudo iptables -I FORWARD 2 -i wlp0s20f3 -o br0 -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo iptables -I FORWARD 3 -i br0 -o br0 -j ACCEPT

# Persist across reboots
sudo apt install -y iptables-persistent
sudo netfilter-persistent save
```

### Fix QUIC buffer (prevents cloudflared warning)
```bash
sudo sysctl -w net.core.rmem_max=7500000
sudo sysctl -w net.core.wmem_max=7500000
echo "net.core.rmem_max=7500000" | sudo tee -a /etc/sysctl.conf
echo "net.core.wmem_max=7500000" | sudo tee -a /etc/sysctl.conf
```

---

## 2. Cloud-Init Profiles

### Create the base privileged profile (Docker-capable)
Shared across all nodes — handles security, nesting, and networking only.
```bash
incus profile create docker-lxc
incus profile edit docker-lxc << 'EOF'
config:
  security.privileged: "true"
  security.nesting: "true"
  linux.kernel_modules: ip_tables,ip6_tables,netlink_diag,nf_nat,overlay
  # This tells the host to pass cloud-init configurations via the LXC directory template
  cloud-init.vendor-data: |
    #cloud-config
    package_upgrade: true
  raw.lxc: |
    lxc.apparmor.profile=unconfined
    lxc.cgroup.devices.allow=a
    lxc.mount.auto=proc:rw sys:rw cgroup:rw
description: Docker-capable privileged LXC profile
devices:
  eth0:
    name: eth0
    network: br0
    type: nic
  root:
    path: /
    pool: homelab-storage
    type: disk
name: docker-lxc
EOF
```

### Create per-node profiles (bind mounts baked in)
Each node gets its own profile that layers on top of `docker-lxc` with the correct host paths.
Run this once on the host before launching containers:

```bash
# Create host directories first
sudo mkdir -p /opt/appdata/node-core /opt/appdata/node-services /opt/appdata/node-games
sudo mkdir -p /mnt/storage-hdd/node-core /mnt/storage-hdd/node-services /mnt/storage-hdd/node-games

# node-core profile
incus profile create node-core
incus profile edit node-core << 'EOF'
config: {}
description: node-core bind mounts
devices:
  appdata:
    path: /opt/appdata
    source: /opt/appdata/node-core
    type: disk
  storage:
    path: /mnt/storage-hdd
    source: /mnt/storage-hdd/node-core
    type: disk
name: node-core
EOF

# node-services profile
incus profile create node-services
incus profile edit node-services << 'EOF'
config: {}
description: node-services bind mounts
devices:
  appdata:
    path: /opt/appdata
    source: /opt/appdata/node-services
    type: disk
  storage:
    path: /mnt/storage-hdd
    source: /mnt/storage-hdd/node-services
    type: disk
name: node-services
EOF

# node-games profile
incus profile create node-games
incus profile edit node-games << 'EOF'
config: {}
description: node-games bind mounts
devices:
  appdata:
    path: /opt/appdata
    source: /opt/appdata/node-games
    type: disk
  storage:
    path: /mnt/storage-hdd
    source: /mnt/storage-hdd/node-games
    type: disk
name: node-games
EOF
```

### Cloud-init user-data template (per node)

Cloud-init for each node can be found under [deployment](../deployment).

---

## 3. Launch Containers

### With cloud-init (recommended)
Each container gets two profiles — `docker-lxc` (base) and its node-specific profile (bind mounts).
```bash
# node-core — Portainer server, Traefik, Cloudflare, Pelican panel
incus launch images:ubuntu/24.04/cloud node-core \
  --profile docker-lxc \
  --profile node-core \
  --config user.user-data="$(cat cloud-init.core.yaml)"

# node-services
incus launch images:ubuntu/24.04/cloud node-services \
  --profile docker-lxc \
  --profile node-services \
  --config user.user-data="$(cat cloud-init.services.yaml)"

# node-games
incus launch images:ubuntu/24.04/cloud node-games \
  --profile docker-lxc \
  --profile node-games \
  --config user.user-data="$(cat cloud-init.games.yaml)"

# Watch cloud-init progress
incus exec <node-name> -- cloud-init status --wait
```

### Manual (fallback without cloud-init)
```bash
incus launch images:ubuntu/24.04 node-core --profile docker-lxc --profile node-core
incus launch images:ubuntu/24.04 node-services --profile docker-lxc --profile node-services
incus launch images:ubuntu/24.04 node-games --profile docker-lxc --profile node-games
```

---

## 4. Host Directory Structure & Bind Mounts

Each node gets isolated directories on the host, but sees identical paths inside the container.
This means compose files are node-agnostic — `${PATH_APPDATA}` always resolves to `/opt/appdata`
and `${PATH_STORAGE}` always resolves to `/mnt/storage-hdd` inside any container.

```
Host                                  Container
/opt/appdata/node-core/       →       /opt/appdata/
/opt/appdata/node-services/   →       /opt/appdata/
/opt/appdata/node-games/      →       /opt/appdata/

/mnt/storage-hdd/node-core/       →       /mnt/storage-hdd/
/mnt/storage-hdd/node-services/   →       /mnt/storage-hdd/
/mnt/storage-hdd/node-games/      →       /mnt/storage-hdd/
```

### Create host directories
```bash
sudo mkdir -p /opt/appdata/node-core
sudo mkdir -p /opt/appdata/node-services
sudo mkdir -p /opt/appdata/node-games
sudo mkdir -p /mnt/storage-hdd/node-core
sudo mkdir -p /mnt/storage-hdd/node-services
sudo mkdir -p /mnt/storage-hdd/node-games
```

### Attach bind mounts to each LXC
```bash
# node-core
sudo incus config device add node-core appdata disk \
  source=/opt/appdata/node-core \
  path=/opt/appdata

sudo incus config device add node-core storage disk \
  source=/mnt/storage-hdd/node-core \
  path=/mnt/storage-hdd

# node-services
sudo incus config device add node-services appdata disk \
  source=/opt/appdata/node-services \
  path=/opt/appdata

sudo incus config device add node-services storage disk \
  source=/mnt/storage-hdd/node-services \
  path=/mnt/storage-hdd

# node-games
sudo incus config device add node-games appdata disk \
  source=/opt/appdata/node-games \
  path=/opt/appdata

sudo incus config device add node-games storage disk \
  source=/mnt/storage-hdd/node-games \
  path=/mnt/storage-hdd
```

### Verify mounts are live
```bash
for name in node-core node-services node-games; do
  echo "=== $name ==="
  sudo incus exec $name -- ls -a /opt/appdata/
  sudo incus exec $name -- ls -a /mnt/storage-hdd/
done
```

### Inspect or remove a device
```bash
sudo incus config device show node-core
sudo incus config device remove node-core appdata
```

---

## 5. Static IPs (manual fallback)

Only needed if not using cloud-init:

```bash
# node-core → 10.145.236.10
incus exec node-core -- bash -c "cat > /etc/netplan/10-eth0.yaml << 'EOF'
network:
  version: 2
  ethernets:
    eth0:
      addresses: [10.145.236.10/24]
      routes:
        - to: default
          via: 10.145.236.1
      nameservers:
        addresses: [1.1.1.1, 8.8.8.8]
EOF
netplan apply"

# node-services → 10.145.236.20
incus exec node-services -- bash -c "cat > /etc/netplan/10-eth0.yaml << 'EOF'
network:
  version: 2
  ethernets:
    eth0:
      addresses: [10.145.236.20/24]
      routes:
        - to: default
          via: 10.145.236.1
      nameservers:
        addresses: [1.1.1.1, 8.8.8.8]
EOF
netplan apply"

# node-games → 10.145.236.30
incus exec node-games -- bash -c "cat > /etc/netplan/10-eth0.yaml << 'EOF'
network:
  version: 2
  ethernets:
    eth0:
      addresses: [10.145.236.30/24]
      routes:
        - to: default
          via: 10.145.236.1
      nameservers:
        addresses: [1.1.1.1, 8.8.8.8]
EOF
netplan apply"
```

---

## 6. DNS Fix (manual fallback)

If containers can ping IPs but can't resolve hostnames:

```bash
for name in node-core node-services node-games; do
  incus exec $name -- bash -c "
    echo 'nameserver 1.1.1.1' > /etc/resolv.conf
    echo 'nameserver 8.8.8.8' >> /etc/resolv.conf
  "
done

# Also fix the iptables rules (see section 1)
```

_Note: This should be solved with [section 1](#1-host-prerequisites)_

---

## 7. Install Docker (manual fallback)

Run per container if not using cloud-init:

```bash
incus exec node-core -- bash -c "
  apt update &&
  apt install -y ca-certificates curl gnupg &&
  install -m 0755 -d /etc/apt/keyrings &&
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg &&
  chmod a+r /etc/apt/keyrings/docker.gpg &&
  echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable' > /etc/apt/sources.list.d/docker.list &&
  apt update &&
  apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin &&
  systemctl enable --now docker &&
  echo 'DOCKER OK'
"
```

---

## 8. Portainer Agent (native systemd)

Run on `node-services` and `node-games` — not in Docker:

```bash
# Install Portainer Agent on node-services and node-games
# Fix because portainer does not append binaries to github release anymore
for name in node-services node-games; do
  echo "=== Starting Portainer Agent Container on $name ==="
  sudo incus exec $name -- docker run -d \
    -p 9001:9001 \
    --name portainer_agent \
    --restart always \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /var/lib/docker/volumes:/var/lib/docker/volumes \
    portainer/agent:2.21.5
done
```

---

## 9. Node IP Reference

| Container       | IP              | Key Ports                                         |
|-----------------|-----------------|---------------------------------------------------|
| `node-core`     | `10.145.236.10` | 80 (Traefik), 9443 (Portainer UI)                 |
| `node-services` | `10.145.236.20` | 9001 (Portainer agent)                            |
| `node-games`    | `10.145.236.30` | 9001 (Portainer agent), 8080 (Wings), 2022 (SFTP) |

---

## 10. Verification Commands

```bash
# Check all containers and IPs
sudo incus list

# Test cross-container connectivity
sudo incus exec node-core -- ping -c2 10.145.236.20
sudo incus exec node-core -- ping -c2 10.145.236.30

# Test internet from container
sudo incus exec node-core -- curl -s --max-time 5 http://archive.ubuntu.com > /dev/null && echo OK

# Check Docker is healthy in each node
for name in node-core node-services node-games; do
  echo -n "$name: "
  sudo incus exec $name -- docker info --format 'Docker {{.ServerVersion}}'
done

# Check iptables NAT rule exists
sudo iptables -t nat -L POSTROUTING -v | grep 10.145.236
```

---

## 11. Gotchas & Lessons Learned

| Problem                                 | Cause                                                 | Fix                                                  |
|-----------------------------------------|-------------------------------------------------------|------------------------------------------------------|
| Containers have no internet             | Missing MASQUERADE rule for WiFi NAT                  | Add iptables rules (section 1)                       |
| DNS works for ping but not curl/apt     | systemd-resolved degraded in LXC                      | Overwrite `/etc/resolv.conf` directly                |
| Docker proxy unreachable by name        | Docker DNS broken in privileged LXC                   | Use container IP instead of name in Traefik endpoint |
| Container IP changes on redeploy        | No static IP assigned to Docker containers            | Set `ipv4_address` in compose + `ipam` on network    |
| Portainer env vars not passed to stacks | GitOps stacks don't read `.env` from disk             | Set all vars in Portainer stack UI environment tab   |
| Pelican panel permission denied         | Wrong UID — panel runs as `82`, not `1000`            | `chown -R 82:82 /pelican-data` mount dir             |
| Pelican ignores DB env vars             | Entrypoint reads `/pelican-data/.env`, not Docker env | Mount `/pelican-data`, set `BEHIND_PROXY=true`       |
| UFW binary missing but rules intact     | Package removed without disabling first               | `apt install -y ufw` restores binary, rules survive  |

Manual Fix for cloud-init not being installed: 
```bash
# Update and install cloud-init in node-services
sudo incus exec node-services -- apt-get update
sudo incus exec node-services -- apt-get install -y cloud-init

# Update and install cloud-init in node-games
sudo incus exec node-games -- apt-get update
sudo incus exec node-games -- apt-get install -y cloud-init
```

```bash
# For node-services
sudo incus exec node-services -- cloud-init clean --logs
sudo incus restart node-services

# For node-games
sudo incus exec node-games -- cloud-init clean --logs
sudo incus restart node-games
```