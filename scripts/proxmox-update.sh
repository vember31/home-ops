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

    # Capture package versions before upgrade
    BEFORE_UPGRADE=$(ssh root@"$NODE" "dpkg-query -W -f='\${Package} \${Version}\n'")

    # Perform updates
    ssh root@"$NODE" "apt update && apt full-upgrade -y"

    # Capture package versions after upgrade
    AFTER_UPGRADE=$(ssh root@"$NODE" "dpkg-query -W -f='\${Package} \${Version}\n'")

    # Determine which packages were updated
    UPDATED_PACKAGES=$(diff <(echo "$BEFORE_UPGRADE") <(echo "$AFTER_UPGRADE") | grep "^>" | awk '{print $2 " (" $3 ")"}' | paste -sd ', ' -)

    if [ -n "$UPDATED_PACKAGES" ]; then
        UPDATE_STATUS="⚠️ Updates installed."
        INSTALLED_PACKAGES="$UPDATED_PACKAGES"
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
