# Incus Setup & Deployment

<!-- TOC -->
* [Incus Setup & Deployment](#incus-setup--deployment)
  * [Installation](#installation)
  * [Setup](#setup)
    * [User Permissions](#user-permissions)
    * [Configuration](#configuration)
      * [Admin Initialization](#admin-initialization)
      * [Iptables Setup for Wi-Fi NAT](#iptables-setup-for-wi-fi-nat)
      * [QUIC Buffer Fix (Cloudflared only)](#quic-buffer-fix-cloudflared-only)
  * [Profiles](#profiles)
    * [Base Docker-Capable Profile](#base-docker-capable-profile)
  * [Host Directory Setup](#host-directory-setup)
    * [Create Host Directories](#create-host-directories)
    * [Directory Structure](#directory-structure)
  * [Container Deployment](#container-deployment)
    * [Launch with Cloud-Init (Recommended)](#launch-with-cloud-init-recommended)
    * [Watch Cloud-Init Progress](#watch-cloud-init-progress)
    * [Attach Per-Node Bind Mounts](#attach-per-node-bind-mounts)
    * [Verify Mounts Are Live](#verify-mounts-are-live)
  * [Manual Fallback Procedures](#manual-fallback-procedures)
    * [Static IP Configuration](#static-ip-configuration)
    * [DNS Resolution Fix](#dns-resolution-fix)
    * [Manual Docker Installation](#manual-docker-installation)
  * [Verification Commands](#verification-commands)
    * [Container Status](#container-status)
    * [Connectivity Tests](#connectivity-tests)
    * [Docker Health](#docker-health)
    * [Mount Verification](#mount-verification)
    * [Iptables NAT Rules](#iptables-nat-rules)
  * [Node IP Reference](#node-ip-reference)
  * [Device Management](#device-management)
    * [Inspect Container Devices](#inspect-container-devices)
    * [Remove a Device](#remove-a-device)
  * [Troubleshooting & Lessons Learned](#troubleshooting--lessons-learned)
    * [Cloud-Init Debugging](#cloud-init-debugging)
    * [Verify Device Attachment](#verify-device-attachment)
  * [Quick Start Checklist](#quick-start-checklist)
<!-- TOC -->

## Installation

To install `incus`, use the following commands:

```bash
sudo apt install -y incus
```

---

## Setup

### User Permissions

To use incus without sudo:

```bash
sudo adduser $USER incus-admin
newgrp incus-admin
```

### Configuration

#### Admin Initialization

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

#### Iptables Setup for Wi-Fi NAT

```bash
sudo iptables -t nat -A POSTROUTING -s 10.145.236.0/24 -o wlp0s20f3 -j MASQUERADE
sudo iptables -I FORWARD 1 -i br0 -o wlp0s20f3 -j ACCEPT
sudo iptables -I FORWARD 2 -i wlp0s20f3 -o br0 -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo iptables -I FORWARD 3 -i br0 -o br0 -j ACCEPT

# Persist across reboots
sudo apt install -y iptables-persistent
sudo netfilter-persistent save
```

_Note: Run after reboot if not persisted_

#### QUIC Buffer Fix (Cloudflared only)

```bash
sudo sysctl -w net.core.rmem_max=7500000
sudo sysctl -w net.core.wmem_max=7500000
echo "net.core.rmem_max=7500000" | sudo tee -a /etc/sysctl.conf
echo "net.core.wmem_max=7500000" | sudo tee -a /etc/sysctl.conf
```

---

## Profiles

### Base Docker-Capable Profile

Create the base profile that all containers will use:

```bash
incus profile create docker-lxc
incus profile edit docker-lxc << 'EOF'
config:
  security.privileged: "true"
  security.nesting: "true"
  linux.kernel_modules: ip_tables,ip6_tables,netlink_diag,nf_nat,overlay
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
  mnt-root:
    source: /
    path: /mnt/root
    readonly: "true"
    type: disk
  mnt-storage:
    source: /mnt/storage-hdd
    path: /mnt/storage
    type: disk
  mnt-appdata:
    source: /opt/appdata
    path: /mnt/appdata
    type: disk
name: docker-lxc
EOF
```

---

## Host Directory Setup

### Create Host Directories

Before launching containers, create the isolated host directories:

```bash
# Create appdata directories
sudo mkdir -p /opt/appdata/core
sudo mkdir -p /opt/appdata/services
sudo mkdir -p /opt/appdata/games

# Create storage directories
sudo mkdir -p /mnt/storage-hdd/core
sudo mkdir -p /mnt/storage-hdd/services
sudo mkdir -p /mnt/storage-hdd/games
```

### Directory Structure

Each node gets isolated directories on the host, but sees identical paths inside the container:

```
Host                              Container
/opt/appdata/core/       →        /opt/appdata/
/opt/appdata/services/   →        /opt/appdata/
/opt/appdata/games/      →        /opt/appdata/

/mnt/storage-hdd/core/       →    /mnt/storage-hdd/
/mnt/storage-hdd/services/   →    /mnt/storage-hdd/
/mnt/storage-hdd/games/      →    /mnt/storage-hdd/
```

This allows compose files to be node-agnostic — `${PATH_APPDATA}` always resolves to `/opt/appdata` and `${PATH_STORAGE}` always resolves to `/mnt/storage-hdd` inside any container.

---

## Container Deployment

### Launch with Cloud-Init (Recommended)

Each container is launched with the base `docker-lxc` profile and its cloud-init configuration:

```bash
# node-core — Portainer server, Traefik, Cloudflare, services
incus launch images:ubuntu/24.04/cloud core \
  --profile docker-lxc \
  --config user.user-data="$(cat cloud-init.core.yaml)"

# node-services — Service containers
incus launch images:ubuntu/24.04/cloud services \
  --profile docker-lxc \
  --config user.user-data="$(cat cloud-init.services.yaml)"

# node-games — Game servers, Wings, SFTP
incus launch images:ubuntu/24.04/cloud games \
  --profile docker-lxc \
  --config user.user-data="$(cat cloud-init.games.yaml)"
```

### Watch Cloud-Init Progress

Monitor cloud-init execution:

```bash
incus exec core -- cloud-init status --wait
incus exec services -- cloud-init status --wait
incus exec games -- cloud-init status --wait
```

### Attach Per-Node Bind Mounts

After containers are running, attach the isolated bind mounts:

```bash
# core node
incus config device add core appdata disk \
  source=/opt/appdata/core \
  path=/opt/appdata

incus config device add core storage disk \
  source=/mnt/storage-hdd/core \
  path=/mnt/storage-hdd

# services node
incus config device add services appdata disk \
  source=/opt/appdata/services \
  path=/opt/appdata

incus config device add services storage disk \
  source=/mnt/storage-hdd/services \
  path=/mnt/storage-hdd

# games node
incus config device add games appdata disk \
  source=/opt/appdata/games \
  path=/opt/appdata

incus config device add games storage disk \
  source=/mnt/storage-hdd/games \
  path=/mnt/storage-hdd
```

### Verify Mounts Are Live

Check that bind mounts are accessible inside containers:

```bash
for name in core services games; do
  echo "=== $name ==="
  incus exec $name -- ls -la /mnt/appdata/
  incus exec $name -- ls -la /mnt/storage/
done
```

---

## Manual Fallback Procedures

### Static IP Configuration

Only needed if cloud-init fails to set static IPs. Apply to each container:

```bash
# core → 10.145.236.10
incus exec core -- bash -c "cat > /etc/netplan/10-eth0.yaml << 'EOF'
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

# services → 10.145.236.20
incus exec services -- bash -c "cat > /etc/netplan/10-eth0.yaml << 'EOF'
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

# games → 10.145.236.30
incus exec games -- bash -c "cat > /etc/netplan/10-eth0.yaml << 'EOF'
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

### DNS Resolution Fix

If containers can ping IPs but DNS resolution fails:

```bash
for name in core services games; do
  incus exec $name -- bash -c "
    echo 'nameserver 1.1.1.1' > /etc/resolv.conf
    echo 'nameserver 8.8.8.8' >> /etc/resolv.conf
  "
done
```

Also verify iptables rules are in place (see Iptables Setup section).

### Manual Docker Installation

If cloud-init doesn't install Docker:

```bash
for name in core services games; do
  incus exec $name -- bash -c "
    apt-get update && apt-get install -y ca-certificates curl gnupg &&
    install -m 0755 -d /etc/apt/keyrings &&
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg &&
    chmod a+r /etc/apt/keyrings/docker.gpg &&
    echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable' > /etc/apt/sources.list.d/docker.list &&
    apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin &&
    systemctl enable --now docker && echo 'DOCKER OK'
  "
done
```

---

## Verification Commands

### Container Status

```bash
# List all containers and IPs
incus list

# Check specific container status
incus info core
incus info services
incus info games
```

### Connectivity Tests

```bash
# Cross-container connectivity
incus exec core -- ping -c2 10.145.236.20
incus exec core -- ping -c2 10.145.236.30

# Internet connectivity from containers
incus exec core -- curl -s --max-time 5 http://archive.ubuntu.com > /dev/null && echo "Internet OK"
```

### Docker Health

```bash
# Check Docker is running in all nodes
for name in core services games; do
  echo -n "$name: "
  incus exec $name -- docker info --format 'Docker {{.ServerVersion}}' || echo "Docker not running"
done
```

### Mount Verification

```bash
# Verify appdata mounts
for name in core services games; do
  echo "=== $name appdata ==="
  incus exec $name -- mount | grep appdata
done

# Verify storage mounts
for name in core services games; do
  echo "=== $name storage ==="
  incus exec $name -- mount | grep storage
done
```

### Iptables NAT Rules

```bash
# Verify NAT rule for WiFi bridge
sudo iptables -t nat -L POSTROUTING -v | grep 10.145.236

# Full rule verification
sudo iptables -L FORWARD -v | grep br0
```

---

## Node IP Reference

| Container  | IP              | Cloud-Init File          | Key Ports                                         |
|------------|-----------------|--------------------------|---------------------------------------------------|
| `core`     | `10.145.236.10` | cloud-init.core.yaml     | 80 (Traefik), 8000 (Portainer HTTPS)              |
| `services` | `10.145.236.20` | cloud-init.services.yaml | 9001 (Portainer Agent)                            |
| `games`    | `10.145.236.30` | cloud-init.games.yaml    | 9001 (Portainer Agent), 8080 (Wings), 2022 (SFTP) |

---

## Device Management

### Inspect Container Devices

```bash
# Show all devices attached to a container
incus config device show core
incus config device show services
incus config device show games
```

### Remove a Device

```bash
# Remove a specific device
incus config device remove core appdata
incus config device remove core storage
```

---

## Troubleshooting & Lessons Learned

| Problem                                           | Cause                                             | Solution                                                   |
|---------------------------------------------------|---------------------------------------------------|------------------------------------------------------------|
| **No internet in containers**                     | Missing iptables MASQUERADE rule                  | Re-run iptables setup (Iptables Setup section)             |
| **DNS works (ping) but curl/apt fails**           | systemd-resolved degraded in LXC                  | Manually overwrite `/etc/resolv.conf` (DNS Resolution Fix) |
| **Container can't find other containers by name** | Docker DNS broken in privileged LXC               | Use container IPs instead of hostnames in config           |
| **Container IPs change on restart**               | No static IP assigned at Incus level              | Cloud-init sets static IPs via netplan                     |
| **Mounts not visible in container**               | Device not attached after container creation      | Use `incus config device add` after launching              |
| **Permission denied on appdata/storage**          | Container user UID doesn't match host permissions | Run `sudo chown 1000:1000 /opt/appdata/[node]` on host     |
| **Cloud-init didn't run**                         | Image doesn't have cloud-init pre-installed       | Manually install: `apt-get install -y cloud-init`          |
| **Docker won't start in privileged LXC**          | Missing kernel modules or cgroup permissions      | Verify `docker-lxc` profile applied (security settings)    |
| **Portainer Agent can't connect to engine**       | Docker socket not mounted or permissions wrong    | Verify bind mount of `/var/run/docker.sock`                |
| **Glances systemd service fails**                 | Python3-pip not installed before pip3 install     | Install pip3 first in cloud-init (included in config)      |
| **Env vars not passed to Docker Compose**         | Env file not loaded by compose command            | Ensure cloud-init creates `/opt/compose/.env` with vars    |
| **Container shows IPv6 only, no IPv4**            | br0 bridge not configured with IPv4               | Re-run `incus admin init` and check bridge IPv4 settings   |

### Cloud-Init Debugging

If cloud-init doesn't complete successfully:

```bash
# Check cloud-init status
incus exec core -- cloud-init status

# View cloud-init logs
incus exec core -- tail -100 /var/log/cloud-init-output.log

# Force re-run cloud-init
incus exec core -- bash -c "
  cloud-init clean --logs --seed
  cloud-init init --local
  cloud-init init
"

# Restart container after cleanup
incus restart core
```

### Verify Device Attachment

If bind mounts aren't showing up:

```bash
# List all devices on a container
incus config device list core

# Check specific device details
incus config device get core appdata path
incus config device get core storage source

# Verify mount inside container
incus exec core -- df -h | grep -E "appdata|storage"
```

---

## Quick Start Checklist

- [ ] Install Incus and configure user permissions
- [ ] Run `incus admin init` with specified settings
- [ ] Apply iptables rules for WiFi NAT
- [ ] Apply QUIC buffer sysctl settings (if using Cloudflared)
- [ ] Create base `docker-lxc` profile
- [ ] Create host directories (`/opt/appdata/{core,services,games}` and `/mnt/storage-hdd/{core,services,games}`)
- [ ] Prepare cloud-init YAML files for each node
- [ ] Launch containers with cloud-init
- [ ] Monitor cloud-init progress with `cloud-init status --wait`
- [ ] Attach per-node bind mounts with `incus config device add`
- [ ] Verify mounts and Docker are working
- [ ] Run connectivity and iptables verification commands