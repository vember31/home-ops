#!/bin/bash

# Define variables
WEBHOOK_URL="[]"
NODES=("pve1.${SECRET_DOMAIN}" "pve2.${SECRET_DOMAIN}" "pve3.${SECRET_DOMAIN}" "pve4.${SECRET_DOMAIN}")

# Initialize the embed fields array
FIELDS=""

for NODE in "${NODES[@]}"; do
    SUBDOMAIN=$(echo "$NODE" | cut -d'.' -f1)
    UPDATE_STATUS="✅ No updates installed."
    REBOOT_STATUS="🔄 No reboot required."
    INSTALLED_PACKAGES="None"

    # Perform updates
    ssh root@"$NODE" "apt update && apt full-upgrade -y"

    # Check for installed packages after upgrade
    UPDATES=$(ssh root@"$NODE" "apt list --upgradable 2>/dev/null | tail -n +2")
    if [ -n "$UPDATES" ]; then
        UPDATE_STATUS="⚠️ Updates installed."
        INSTALLED_PACKAGES=$(echo "$UPDATES" | awk '{print $1}' | paste -sd ', ' -)
    fi

    # Check if a reboot is required
    if ssh root@"$NODE" "[ -f /var/run/reboot-required ]"; then
        REBOOT_STATUS="⚠️ Reboot required."
    fi

    # Check if a new kernel is installed but not running
    LATEST_KERNEL=$(ssh root@$NODE "ls -1 /boot/vmlinuz-* | sed 's|/boot/vmlinuz-||' | sort -V | tail -n 1")
    CURRENT_KERNEL=$(ssh root@"$NODE" "uname -r")

    if [ "$CURRENT_KERNEL" != "$LATEST_KERNEL" ]; then
        REBOOT_STATUS="⚠️ Reboot required (New Kernel Installed: $LATEST_KERNEL)."
    fi

    # Append data to the fields
    FIELDS+="
        {\"name\":\"🔹 Node\",\"value\":\"$SUBDOMAIN\",\"inline\":true},
        {\"name\":\"🔄 Update Status\",\"value\":\"$UPDATE_STATUS\",\"inline\":true},
        {\"name\":\"📦 Installed Packages\",\"value\":\"$INSTALLED_PACKAGES\",\"inline\":false},
        {\"name\":\"🔄 Reboot Status\",\"value\":\"$REBOOT_STATUS\",\"inline\":false},"
done

# Remove the last comma to ensure valid JSON
FIELDS="${FIELDS%,}"

# Construct the final JSON payload
JSON_PAYLOAD=$(cat <<EOF
{
    "embeds": [{
        "title": "Proxmox Update Report",
        "color": 16776960,
        "fields": [$FIELDS]
    }]
}
EOF
)

# Send to Discord
curl -X POST -H "Content-Type: application/json" -d "$JSON_PAYLOAD" "$WEBHOOK_URL"
