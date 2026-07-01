#!/usr/bin/env bash
# Usage: ./deploy.sh <instance-name> <last-ip-octet> [agent|manager]
# Example: ./deploy.sh node1 10 agent
#          ./deploy.sh node-mgr 20 manager
set -euo pipefail

NAME="${1:?instance name required}"
OCTET="${2:?last IP octet required (e.g. 10 for 10.0.143.10)}"
ROLE="${3:-agent}"

IP="10.0.143.${OCTET}"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$ROLE" != "agent" && "$ROLE" != "manager" ]]; then
  echo "Role must be 'agent' or 'manager'" >&2
  exit 1
fi

NET_CONFIG="$(mktemp)"
trap 'rm -f "$NET_CONFIG"' EXIT
sed "s/{{IP}}/${IP}/" "${BASE_DIR}/network-config-template.yaml" > "${NET_CONFIG}"

USERDATA="${BASE_DIR}/user-data-${ROLE}.yaml"

echo "Launching '${NAME}' (${ROLE}) at ${IP} ..."

incus launch images:ubuntu/24.04/cloud "${NAME}" \
  --profile default \
  --profile docker \
  --config=cloud-init.user-data="$(cat "${USERDATA}")" \
  --config=cloud-init.network-config="$(cat "${NET_CONFIG}")"

# --- Per-node bind mounts (host paths depend on instance name, so these are
# added per-instance rather than baked into the shared profile) ---
APPDATA_HOST="/opt/appdata/${NAME}"
STORAGE_HOST="/mnt/storage-hdd/${NAME}"
mkdir -p "${APPDATA_HOST}" "${STORAGE_HOST}"

incus config device add "${NAME}" appdata disk \
  source="${APPDATA_HOST}" path=/mnt/appdata

incus config device add "${NAME}" storage disk \
  source="${STORAGE_HOST}" path=/mnt/storage

echo "Done. Watch progress with: incus exec ${NAME} -- tail -f /var/log/cloud-init-output.log"