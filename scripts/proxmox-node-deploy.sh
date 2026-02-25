#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$SCRIPT_DIR/proxmox-node-automation.sh"
REMOTE_TMP="/tmp/pve-node-automation-install.sh"
SSH_USER="root"

# Nodes in deployment order with their staggered upgrade times
NODES=(
  192.168.2.3
  192.168.2.10
  192.168.2.2
  192.168.2.18
)

TIMES=(
  "Sun *-*-* 03:00:00"
  "Sun *-*-* 03:15:00"
  "Sun *-*-* 03:30:00"
  "Sun *-*-* 03:45:00"
)

tmpfile=""
cleanup() { rm -f "$tmpfile"; }
trap cleanup EXIT

for i in "${!NODES[@]}"; do
  node="${NODES[$i]}"
  time="${TIMES[$i]}"

  echo "==> [${node}] deploying (timer: ${time})"

  tmpfile="$(mktemp)"
  sed "s|^TIMER_ONCALENDAR=.*|TIMER_ONCALENDAR=\"${time}\"|" "$INSTALLER" > "$tmpfile"

  scp -q "$tmpfile" "${SSH_USER}@${node}:${REMOTE_TMP}"
  ssh "${SSH_USER}@${node}" "bash ${REMOTE_TMP} && rm -f ${REMOTE_TMP}"

  echo "==> [${node}] done"
  echo
done

echo "All nodes deployed."
