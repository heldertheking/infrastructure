#!/usr/bin/env bash
# Usage: ./deploy.sh <instance-name> <last-ip-octet> <agent|manager> [--swarm init|join] [--general]
#
# Examples (deploy in this order - core must exist before services/games can join):
#   ./deploy.sh core     10 manager --swarm init
#   ./deploy.sh services 20 agent   --swarm join --general
#   ./deploy.sh games    30 agent   --swarm join
#
# <agent|manager> is the PORTAINER role: exactly one node should be "manager"
# (runs Portainer EE); the rest are "agent" (no longer run a standalone Agent
# container when swarm is used - see below).
#
# --swarm init   : this node creates the swarm. Run this ONCE, on your first node.
# --swarm join   : this node joins the swarm created by --swarm init. Requires
#                  the init node to have already been deployed (reads its
#                  state from .swarm-state/ next to this script).
# --general      : marks this node as the swarm's *unrestricted* default
#                  target - see "Placement" in README.md. Omit this flag on
#                  any node you want to require explicit targeting for
#                  (e.g. core, games).
#
# Every swarm node is automatically labeled role=<instance-name> (e.g.
# role=core, role=services, role=games), and nodes WITHOUT --general also get
# restricted=true. Use these in a stack's deploy.placement.constraints.
set -euo pipefail

NAME="${1:?instance name required}"
OCTET="${2:?last IP octet required (e.g. 10 for 10.0.143.10)}"
PORTAINER_ROLE="${3:-agent}"
shift 3 || true

SWARM_MODE=""
GENERAL="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --swarm)
      SWARM_MODE="${2:?--swarm requires init or join}"
      shift 2
      ;;
    --general)
      GENERAL="true"
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ "$PORTAINER_ROLE" != "agent" && "$PORTAINER_ROLE" != "manager" ]]; then
  echo "Portainer role (3rd argument) must be 'agent' or 'manager'" >&2
  exit 1
fi
if [[ -n "$SWARM_MODE" && "$SWARM_MODE" != "init" && "$SWARM_MODE" != "join" ]]; then
  echo "--swarm must be 'init' or 'join'" >&2
  exit 1
fi

IP="10.0.143.${OCTET}"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${BASE_DIR}/.swarm-state"

NET_CONFIG="$(mktemp)"
trap 'rm -f "$NET_CONFIG"' EXIT
sed "s/{{IP}}/${IP}/" "${BASE_DIR}/network-config-template.yaml" > "${NET_CONFIG}"

echo "Launching '${NAME}' at ${IP} (portainer: ${PORTAINER_ROLE}${SWARM_MODE:+, swarm: $SWARM_MODE}${GENERAL:+, general: $GENERAL}) ..."

incus launch images:ubuntu/24.04/cloud "${NAME}" \
  --profile default \
  --profile docker \
  --config=cloud-init.user-data="$(cat "${BASE_DIR}/user-data.yaml")" \
  --config=cloud-init.network-config="$(cat "${NET_CONFIG}")"

# --- Bind mounts ---
# Both appdata and storage are intentionally the SAME host path for every
# node (not per-node): core/services/games all run on one physical host, so
# a stack constrained to one node today and moved to another later still
# sees its data. Scoping to a specific stack/service folder happens one
# layer down, in each stack's own compose file (e.g.
# ${PATH_APPDATA}/ingress/traefik or ${PATH_STORAGE}/media/movies) - never
# mount the whole /mnt/appdata or /mnt/storage tree into an individual
# service container.
APPDATA_HOST="/opt/appdata"
STORAGE_HOST="/mnt/storage-hdd"
mkdir -p "${APPDATA_HOST}" "${STORAGE_HOST}"

incus config device add "${NAME}" appdata disk \
  source="${APPDATA_HOST}" path=/mnt/appdata

incus config device add "${NAME}" storage disk \
  source="${STORAGE_HOST}" path=/mnt/storage

echo "Waiting for cloud-init to finish (Docker + Glances install) ..."
incus exec "${NAME}" -- cloud-init status --wait >/dev/null

# --- Swarm bootstrap ---
if [[ -n "$SWARM_MODE" ]]; then
  mkdir -p "$STATE_DIR"
  case "$SWARM_MODE" in
    init)
      echo "Initializing swarm on ${NAME} (${IP}) ..."
      incus exec "${NAME}" -- docker swarm init --advertise-addr "${IP}"
      echo "${NAME}" > "${STATE_DIR}/manager-name"
      echo "${IP}" > "${STATE_DIR}/manager-ip"
      incus exec "${NAME}" -- docker swarm join-token -q worker > "${STATE_DIR}/worker-token"

      echo "Creating overlay network for Portainer Agent cluster discovery ..."
      incus exec "${NAME}" -- docker network create --driver overlay --attachable portainer_agent_network >/dev/null

      echo "Deploying cluster-wide Portainer Agent (global service - one replica per node, present and future) ..."
      # Use 'docker stack deploy' (the canonical Portainer approach) instead of
      # 'docker service create'. The stack name 'portainer' + service 'agent'
      # produces the full service name 'portainer_agent', while within the
      # stack's overlay DNS the short name 'tasks.agent' resolves reliably on
      # first startup — avoiding the chicken-and-egg crash loop that occurs
      # when 'tasks.portainer_agent' is looked up before any task is Running.
      # --publish mode=host is retained so port 9001 is directly reachable on
      # every node's host IP (no ingress routing mesh needed for Portainer EE).
      incus exec "${NAME}" -- bash -s <<'STACK_EOF'
cat > /tmp/portainer-agent-stack.yml <<'EOF'
version: "3.2"
services:
  agent:
    image: portainer/agent:latest
    environment:
      - AGENT_CLUSTER_ADDR=tasks.agent
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /var/lib/docker/volumes:/var/lib/docker/volumes
    networks:
      - portainer_agent_network
    ports:
      - target: 9001
        published: 9001
        protocol: tcp
        mode: host
    deploy:
      mode: global
networks:
  portainer_agent_network:
    driver: overlay
    attachable: true
    external: true
EOF
docker stack deploy -c /tmp/portainer-agent-stack.yml portainer
rm -f /tmp/portainer-agent-stack.yml
STACK_EOF
      ;;
    join)
      if [[ ! -f "${STATE_DIR}/manager-ip" || ! -f "${STATE_DIR}/worker-token" ]]; then
        echo "No swarm state found in ${STATE_DIR} - run '--swarm init' on your manager node first." >&2
        exit 1
      fi
      MGR_IP="$(cat "${STATE_DIR}/manager-ip")"
      TOKEN="$(cat "${STATE_DIR}/worker-token")"
      echo "Joining swarm at ${MGR_IP}:2377 ..."
      incus exec "${NAME}" -- docker swarm join --token "${TOKEN}" "${MGR_IP}:2377"
      ;;
  esac

  MGR_NAME="$(cat "${STATE_DIR}/manager-name")"
  echo "Labeling node role=${NAME} (docker node commands must run from the manager, '${MGR_NAME}') ..."
  incus exec "${MGR_NAME}" -- docker node update --label-add role="${NAME}" "${NAME}" >/dev/null
  if [[ "$GENERAL" != "true" ]]; then
    incus exec "${MGR_NAME}" -- docker node update --label-add restricted=true "${NAME}" >/dev/null
    echo "  -> restricted=true (this node needs an explicit placement constraint to receive stacks)"
  else
    echo "  -> general (unrestricted default target for stacks with no placement constraint)"
  fi
fi

# --- Portainer EE (manager role only, plain container regardless of swarm) ---
if [[ "$PORTAINER_ROLE" == "manager" ]]; then
  echo "Starting Portainer EE on ${NAME} ..."
  incus exec "${NAME}" -- docker volume create portainer_data >/dev/null
  incus exec "${NAME}" -- docker run -d --name portainer --restart=always \
    -p 9000:9000 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    portainer/portainer-ee:latest
fi

# --- Standalone Portainer Agent (only when NOT using swarm - swarm nodes get
#     the single cluster-wide global service deployed above instead) ---
if [[ "$PORTAINER_ROLE" == "agent" && -z "$SWARM_MODE" ]]; then
  echo "Starting standalone Portainer Agent on ${NAME} ..."
  incus exec "${NAME}" -- docker run -d --name portainer_agent --restart=always -p 9001:9001 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /var/lib/docker/volumes:/var/lib/docker/volumes \
    -v /:/host \
    portainer/agent:latest
fi

echo "Done. Check state with: incus exec ${NAME} -- docker ps"