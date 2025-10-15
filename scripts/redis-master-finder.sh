#!/usr/bin/env bash
set -euo pipefail

# Defaults (override via env)
NS="${NS:-database}"                       # namespace
REDIS_POD="${REDIS_POD:-redis-0}"          # pod to exec into
SENTINEL_SVC="${SENTINEL_SVC:-redis-sentinel}"
SENTINEL_PORT="${SENTINEL_PORT:-26379}"
MASTER_NAME="${MASTER_NAME:-redis-master}"
HEADLESS_SVC="${HEADLESS_SVC:-redis-headless}"
PRINT_PORT="${PRINT_PORT:-false}"          # set to "true" to append :port

# 1) Ask Sentinel from inside redis-0
out="$(kubectl -n "$NS" exec "$REDIS_POD" -- sh -lc \
  "redis-cli -h $SENTINEL_SVC -p $SENTINEL_PORT SENTINEL get-master-addr-by-name $MASTER_NAME | tr -d '\r'")"

MASTER_IP="$(printf '%s\n' "$out" | sed -n '1p')"
MASTER_PORT="$(printf '%s\n' "$out" | sed -n '2p')"

if [[ -z "${MASTER_IP:-}" || -z "${MASTER_PORT:-}" ]]; then
  echo "ERROR: could not get master from Sentinel ($SENTINEL_SVC:$SENTINEL_PORT name=$MASTER_NAME) via $NS/$REDIS_POD" >&2
  exit 1
fi

# 2) Map IP -> pod name
POD_NAME="$(kubectl -n "$NS" get pods -o wide --no-headers \
  | awk -v ip="$MASTER_IP" '$6==ip {print $1; exit}')"

# 3) Print FQDN (or raw IP as fallback)
if [[ -z "${POD_NAME:-}" ]]; then
  [[ "$PRINT_PORT" == "true" ]] && echo "${MASTER_IP}:${MASTER_PORT}" || echo "${MASTER_IP}"
  exit 0
fi

FQDN="${POD_NAME}.${HEADLESS_SVC}.${NS}.svc.cluster.local"
[[ "$PRINT_PORT" == "true" ]] && echo "${FQDN}:${MASTER_PORT}" || echo "${FQDN}"
