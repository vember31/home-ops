#!/bin/bash
set -euo pipefail

# Configuration
QBT_HOST="qbittorrent.downloads.svc.cluster.local"
QBT_PORT="8080"
QBT_USER="{{ .QBITTORRENT_USERNAME }}"
QBT_PASS="{{ .QBITTORRENT_PASSWORD }}"
OVERRIDES_FILE="/config/overrides.json"
MAX_RETRIES=30
RETRY_DELAY=2

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

# Wait for qBittorrent to be ready
log "Waiting for qBittorrent to be ready..."
for i in $(seq 1 $MAX_RETRIES); do
    if curl -s -f "http://${QBT_HOST}:${QBT_PORT}/api/v2/app/version" > /dev/null 2>&1; then
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

if ! curl -s -i -c "$COOKIE_JAR" \
    --data-urlencode "username=${QBT_USER}" \
    --data-urlencode "password=${QBT_PASS}" \
    "http://${QBT_HOST}:${QBT_PORT}/api/v2/auth/login" | grep -q "200 OK"; then
    log "ERROR: Authentication failed"
    exit 1
fi

log "Authentication successful"

# Read and process overrides file
if [ ! -f "$OVERRIDES_FILE" ]; then
    log "ERROR: Overrides file not found: $OVERRIDES_FILE"
    exit 1
fi

log "Reading overrides from $OVERRIDES_FILE"

# Validate JSON
if ! jq empty "$OVERRIDES_FILE" 2>/dev/null; then
    log "ERROR: Invalid JSON in $OVERRIDES_FILE"
    exit 1
fi

log "Applying preferences to qBittorrent..."

# Apply preferences using the API
# The setPreferences endpoint expects JSON with key-value pairs
RESPONSE=$(curl -s -b "$COOKIE_JAR" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "json=$(cat "$OVERRIDES_FILE")" \
    "http://${QBT_HOST}:${QBT_PORT}/api/v2/app/setPreferences")

# Check if the request was successful
if [ "$RESPONSE" = "Ok." ] || [ -z "$RESPONSE" ]; then
    log "Preferences applied successfully"
else
    log "WARNING: Unexpected response from API: $RESPONSE"
fi

log "Configuration update complete"
