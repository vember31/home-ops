#!/bin/bash

# Note that {$SECRET_DOMAIN} and the discord webhook below need to be updated manually before running.
# Define Proxmox nodes (domains)
NODES=("pve1.${SECRET_DOMAIN}" "pve2.${SECRET_DOMAIN}" "pve3.${SECRET_DOMAIN}" "pve4.${SECRET_DOMAIN}")

# Define the Discord webhook URL
DISCORD_WEBHOOK_URL="[discord webhook here]"

# Function to send a message to Discord as an embed
send_discord_embed() {
  local EMBED=$1

  # Send embed to Discord
  curl -H "Content-Type: application/json" \
       -X POST \
       -d "$EMBED" \
       "$DISCORD_WEBHOOK_URL"
}

# Start building the embed
EMBED_CONTENT="{\"embeds\":[{\"title\":\"Proxmox Update Status\",\"color\":3066993,\"fields\":["

# Iterate over each node
for NODE in "${NODES[@]}"; do
  echo "Checking updates for $NODE..."

  # Extract subdomain
  SUBDOMAIN=$(echo "$NODE" | cut -d '.' -f 1)

  # Run update and capture output
  UPDATE_OUTPUT=$(ssh root@$NODE "apt update && apt full-upgrade -y && apt autoremove -y && apt clean" 2>&1)

  # Determine if updates were applied
  if echo "$UPDATE_OUTPUT" | grep -q "upgraded,"; then
    UPDATE_STATUS="Updates were installed or removed."
  else
    UPDATE_STATUS="No updates were installed or removed."
  fi

  # Check if a reboot is required
  REBOOT_NEEDED=$(ssh root@$NODE "if [ -f /var/run/reboot-required ]; then echo 'yes'; else echo 'no'; fi")

  # Prepare the status message
  if [ "$REBOOT_NEEDED" == "yes" ]; then
    STATUS="**Reboot required** after updates. $UPDATE_STATUS"
  else
    STATUS="No reboot required. $UPDATE_STATUS"
  fi

  # Add status to the embed fields
  EMBED_CONTENT+="{\"name\":\"$SUBDOMAIN\",\"value\":\"$STATUS\",\"inline\":false},"
  
  echo "Update check for $NODE completed."
done

# Finish building the embed
EMBED_CONTENT="${EMBED_CONTENT%,}]}]}"

# Send the embed to Discord
send_discord_embed "$EMBED_CONTENT"
