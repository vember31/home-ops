#!/bin/bash
set -Eeuo pipefail

exec > >(tee /tmp/apply-preferences.log) 2>&1

# Configuration
QBT_HOST="localhost"
QBT_PORT="8080"
QBT_BASE_URL="http://${QBT_HOST}:${QBT_PORT}"
QBT_USER="${QBITTORRENT_USERNAME}"
QBT_PASS="${QBITTORRENT_PASSWORD}"
OVERRIDES_FILE="/scripts/overrides.json"
MAX_RETRIES=60
RETRY_DELAY=2

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

trap 'rc=$?; log "ERROR: apply-preferences.sh failed with exit code ${rc}"' ERR

curl_common_args=(
    -sS
    -H "Origin: ${QBT_BASE_URL}"
    -H "Referer: ${QBT_BASE_URL}/"
)

# Wait for qBittorrent to be ready
log "Waiting for qBittorrent to be ready..."
for i in $(seq 1 $MAX_RETRIES); do
    if curl "${curl_common_args[@]}" -fsS "${QBT_BASE_URL}/api/v2/app/version" > /dev/null 2>&1; then
        log "qBittorrent is ready"
        break
    fi
    if [ "$i" -eq "$MAX_RETRIES" ]; then
        log "ERROR: qBittorrent did not become ready in time"
        exit 1
    fi
    sleep $RETRY_DELAY
done

# Authenticate and get cookie
log "Authenticating with qBittorrent API..."
COOKIE_JAR=$(mktemp)
trap "rm -f $COOKIE_JAR" EXIT

for i in $(seq 1 $MAX_RETRIES); do
    HTTP_CODE=$(curl "${curl_common_args[@]}" \
        -o /dev/null \
        -w "%{http_code}" \
        -c "$COOKIE_JAR" \
        --data-urlencode "username=${QBT_USER}" \
        --data-urlencode "password=${QBT_PASS}" \
        "${QBT_BASE_URL}/api/v2/auth/login" || true)

    if [ "$HTTP_CODE" = "200" ]; then
        log "Authentication successful"
        break
    fi

    if [ "$i" -eq "$MAX_RETRIES" ]; then
        log "ERROR: Authentication failed after $MAX_RETRIES attempts (last HTTP status: $HTTP_CODE)"
        exit 1
    fi

    log "Authentication not ready yet (HTTP $HTTP_CODE); retrying..."
    sleep "$RETRY_DELAY"
done

# Read and process overrides file
if [ ! -f "$OVERRIDES_FILE" ]; then
    log "ERROR: Overrides file not found: $OVERRIDES_FILE"
    exit 1
fi

log "Reading overrides from $OVERRIDES_FILE"
log "Applying preferences to qBittorrent..."

# Apply preferences using the API
# The setPreferences endpoint expects JSON with key-value pairs
RESPONSE=$(curl -s -b "$COOKIE_JAR" \
    -X POST \
    --data-urlencode "json@${OVERRIDES_FILE}" \
    "${curl_common_args[@]}" \
    "${QBT_BASE_URL}/api/v2/app/setPreferences" || true)

# Check if the request was successful
if [ "$RESPONSE" = "Ok." ] || [ -z "$RESPONSE" ]; then
    log "Preferences applied successfully"
else
    log "WARNING: Unexpected response from API: $RESPONSE"
fi

log "Configuration update complete"
