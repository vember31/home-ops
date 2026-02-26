#!/usr/bin/env bash
set -euo pipefail

############################
# USER-EDITABLE VARIABLES #
############################

# Discord webhook for notifications.
# Leave empty ("") if you want to fill it in later.
DISCORD_WEBHOOK_URL=""

# Timer schedule (EDIT PER NODE if desired)
TIMER_ONCALENDAR="Sun *-*-* 03:45:00"

############################
# INTERNAL SETTINGS       #
############################

CONF="/etc/pve-auto-upgrade.conf"
SCRIPT="/usr/local/sbin/pve-auto-upgrade-reboot.sh"
POST_REBOOT_SCRIPT="/usr/local/sbin/pve-auto-upgrade-post-reboot.sh"
LOGFILE="/var/log/pve-auto-upgrade.log"
SERVICE="/etc/systemd/system/pve-auto-upgrade-reboot.service"
POST_REBOOT_SERVICE="/etc/systemd/system/pve-auto-upgrade-post-reboot.service"
TIMER="/etc/systemd/system/pve-auto-upgrade-reboot.timer"
REBOOT_FLAG="/var/lib/pve-auto-upgrade/reboot-pending"

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Please run as root."
    exit 1
  fi
}

install_conf() {
  cat > "$CONF" <<EOF
# Root-only config for Proxmox auto upgrades
# Managed by install-pve-auto-upgrade.sh

DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL}"

# Optional override (defaults to hostname -s)
NODE_NAME=""
EOF

  chmod 600 "$CONF"
  chown root:root "$CONF"
  echo "Installed $CONF"
}

install_script() {
  cat > "$SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
# Suppress needrestart from automatically restarting services mid-apt;
# we handle service health explicitly after the upgrade.
export NEEDRESTART_SUSPEND=1

LOGFILE="/var/log/pve-auto-upgrade.log"
CONF="/etc/pve-auto-upgrade.conf"

# Critical Proxmox services to verify are active after upgrade
PVE_SERVICES=(pve-cluster corosync pve-manager qemu-server)

# Load config
if [[ -f "$CONF" ]]; then
  # shellcheck disable=SC1090
  source "$CONF"
fi

NODE_NAME="${NODE_NAME:-}"
if [[ -z "$NODE_NAME" ]]; then
  NODE_NAME="$(hostname -s)"
fi

DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"

log() {
  local msg="[$(date --iso-8601=seconds)] $*"
  echo "$msg" | tee -a "$LOGFILE"
  logger -t pve-auto-upgrade "$*"
}

discord_embed() {
  local title="$1"
  local description="$2"
  local color="$3"
  [[ -z "${DISCORD_WEBHOOK_URL}" ]] && return 0

  if (( ${#description} > 4000 )); then
    description="${description:0:4000}…"
  fi

  title="${title//\\/\\\\}"
  title="${title//\"/\\\"}"
  description="${description//\\/\\\\}"
  description="${description//\"/\\\"}"
  description="${description//$'\n'/\\n}"

  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"

  curl -fsSL -X POST \
    -H "Content-Type: application/json" \
    -d "{\"embeds\":[{\"title\":\"${title}\",\"description\":\"${description}\",\"color\":${color},\"footer\":{\"text\":\"${NODE_NAME}\"},\"timestamp\":\"${timestamp}\"}]}" \
    "$DISCORD_WEBHOOK_URL" >/dev/null || true
}

on_error() {
  local exit_code=$?
  local line=$1
  log "ERROR: script failed at line ${line} (exit ${exit_code})"
  discord_embed "❌ Upgrade Failed" "**${NODE_NAME}** — script failed at line ${line} (exit ${exit_code}). Manual inspection required." 15158332
}

reboot_required() {
  if [[ -f /var/run/reboot-required ]]; then
    return 0
  fi

  local running newest_boot newest_ver
  running="$(uname -r)"

  newest_boot="$(ls -1 /boot/vmlinuz-* 2>/dev/null | sort -V | tail -n 1 || true)"
  if [[ -n "$newest_boot" ]]; then
    newest_ver="${newest_boot#/boot/vmlinuz-}"
    if [[ "$newest_ver" != "$running" ]]; then
      return 0
    fi
  fi

  return 1
}

check_services() {
  local failed=()
  for svc in "${PVE_SERVICES[@]}"; do
    # Skip services that aren't installed on this node
    if ! systemctl list-unit-files "${svc}.service" &>/dev/null; then
      continue
    fi
    if ! systemctl is-active --quiet "${svc}.service"; then
      log "WARNING: ${svc} is not active after upgrade — attempting restart"
      systemctl restart "${svc}.service" 2>&1 | tee -a "$LOGFILE" || true
      sleep 3
      if ! systemctl is-active --quiet "${svc}.service"; then
        failed+=("${svc}")
        log "ERROR: ${svc} failed to restart"
      else
        log "${svc} recovered after restart"
      fi
    fi
  done

  if (( ${#failed[@]} > 0 )); then
    discord_embed "⚠️ Service Failure After Upgrade" "**${NODE_NAME}** — failed to restart: ${failed[*]}. Check logs." 15105570
    return 1
  fi
  return 0
}

notify_pending_upgrades() {
  local upgradable count pkg_names
  upgradable="$(apt list --upgradable 2>/dev/null | grep -v '^Listing' || true)"
  count="$(echo "$upgradable" | grep -c '/' || true)"

  if [[ "$count" -eq 0 ]]; then
    log "No packages to upgrade. Exiting."
    discord_embed "✅ Up to Date" "**${NODE_NAME}** — no packages to upgrade." 3066993
    exit 0
  fi

  pkg_names="$(echo "$upgradable" | cut -d'/' -f1 | tr '\n' ' ' | xargs)"
  log "Pending upgrades (${count}): ${pkg_names}"
  discord_embed "📦 Updates Available" "**${NODE_NAME}** — ${count} package(s) to upgrade:"$'\n'"${pkg_names}" 15844367
}

main() {
  trap 'on_error $LINENO' ERR

  log "=== START upgrade on ${NODE_NAME} ==="
  discord_embed "🔧 Checking for Upgrades" "Running apt update on **${NODE_NAME}**…" 3447003

  apt-get update 2>&1 | tee -a "$LOGFILE"

  notify_pending_upgrades

  apt-get -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    upgrade 2>&1 | tee -a "$LOGFILE"

  apt-get -y autoremove --purge 2>&1 | tee -a "$LOGFILE"

  sync

  check_services

  if reboot_required; then
    log "Reboot required -> rebooting now."
    discord_embed "🔁 Upgrade Complete — Rebooting" "**${NODE_NAME}** — upgrades applied. Rebooting now…" 15105570
    mkdir -p /var/lib/pve-auto-upgrade
    touch /var/lib/pve-auto-upgrade/reboot-pending
    sync
    systemctl reboot
  else
    log "No reboot required."
    discord_embed "✅ Upgrade Complete" "**${NODE_NAME}** — upgrades applied. No reboot required." 3066993
  fi

  log "=== END upgrade on ${NODE_NAME} ==="
}

main "$@"
EOF

  chmod 755 "$SCRIPT"
  chown root:root "$SCRIPT"
  echo "Installed $SCRIPT"
}

install_post_reboot_script() {
  cat > "$POST_REBOOT_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

REBOOT_FLAG="/var/lib/pve-auto-upgrade/reboot-pending"
CONF="/etc/pve-auto-upgrade.conf"
LOGFILE="/var/log/pve-auto-upgrade.log"

PVE_SERVICES=(pve-cluster corosync pve-manager qemu-server)

# Nothing to do if this boot wasn't triggered by the upgrade script
[[ -f "$REBOOT_FLAG" ]] || exit 0

# Load config
if [[ -f "$CONF" ]]; then
  # shellcheck disable=SC1090
  source "$CONF"
fi

NODE_NAME="${NODE_NAME:-}"
if [[ -z "$NODE_NAME" ]]; then
  NODE_NAME="$(hostname -s)"
fi

DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"

log() {
  local msg="[$(date --iso-8601=seconds)] $*"
  echo "$msg" | tee -a "$LOGFILE"
  logger -t pve-auto-upgrade "$*"
}

discord_embed() {
  local title="$1"
  local description="$2"
  local color="$3"
  [[ -z "${DISCORD_WEBHOOK_URL}" ]] && return 0

  if (( ${#description} > 4000 )); then
    description="${description:0:4000}…"
  fi

  title="${title//\\/\\\\}"
  title="${title//\"/\\\"}"
  description="${description//\\/\\\\}"
  description="${description//\"/\\\"}"
  description="${description//$'\n'/\\n}"

  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"

  curl -fsSL -X POST \
    -H "Content-Type: application/json" \
    -d "{\"embeds\":[{\"title\":\"${title}\",\"description\":\"${description}\",\"color\":${color},\"footer\":{\"text\":\"${NODE_NAME}\"},\"timestamp\":\"${timestamp}\"}]}" \
    "$DISCORD_WEBHOOK_URL" >/dev/null || true
}

main() {
  log "=== POST-REBOOT check on ${NODE_NAME} ==="

  # Remove flag immediately so a crash below doesn't loop on next boot
  rm -f "$REBOOT_FLAG"

  # Give services a moment to finish starting up
  sleep 20

  local failed=()
  for svc in "${PVE_SERVICES[@]}"; do
    if ! systemctl list-unit-files "${svc}.service" &>/dev/null; then
      continue
    fi
    if ! systemctl is-active --quiet "${svc}.service"; then
      failed+=("${svc}")
      log "WARNING: ${svc} is not active after reboot"
    fi
  done

  if (( ${#failed[@]} > 0 )); then
    log "Post-reboot: degraded services: ${failed[*]}"
    discord_embed "⚠️ Reboot Complete — Service Issues" "**${NODE_NAME}** — services not running: ${failed[*]}. Manual inspection required." 15158332
  else
    log "Post-reboot: all services healthy."
    discord_embed "✅ Reboot Complete" "**${NODE_NAME}** — all Proxmox services healthy." 3066993
  fi

  log "=== END POST-REBOOT check on ${NODE_NAME} ==="
}

main "$@"
EOF

  chmod 755 "$POST_REBOOT_SCRIPT"
  chown root:root "$POST_REBOOT_SCRIPT"
  echo "Installed $POST_REBOOT_SCRIPT"
}

install_logfile() {
  touch "$LOGFILE"
  chmod 640 "$LOGFILE"
  if getent group adm >/dev/null 2>&1; then
    chown root:adm "$LOGFILE"
  else
    chown root:root "$LOGFILE"
  fi
  echo "Prepared $LOGFILE"

  # Install logrotate config to keep log from growing unbounded
  cat > /etc/logrotate.d/pve-auto-upgrade <<LREOF
$LOGFILE {
  weekly
  rotate 8
  compress
  delaycompress
  missingok
  notifempty
}
LREOF
  echo "Installed logrotate config for $LOGFILE"
}

install_service() {
  cat > "$SERVICE" <<EOF
[Unit]
Description=Proxmox automatic upgrade + Discord logging + reboot-if-needed
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-$CONF
ExecStart=$SCRIPT
EOF

  chmod 644 "$SERVICE"
  chown root:root "$SERVICE"
  echo "Installed $SERVICE"
}

install_post_reboot_service() {
  cat > "$POST_REBOOT_SERVICE" <<EOF
[Unit]
Description=Proxmox post-upgrade reboot completion check + Discord notification
After=network-online.target multi-user.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-$CONF
ExecStart=$POST_REBOOT_SCRIPT

[Install]
WantedBy=multi-user.target
EOF

  chmod 644 "$POST_REBOOT_SERVICE"
  chown root:root "$POST_REBOOT_SERVICE"
  echo "Installed $POST_REBOOT_SERVICE"
}

install_timer() {
  cat > "$TIMER" <<EOF
[Unit]
Description=Nightly Proxmox upgrade + reboot-if-needed

[Timer]
OnCalendar=$TIMER_ONCALENDAR
Persistent=true

[Install]
WantedBy=timers.target
EOF

  chmod 644 "$TIMER"
  chown root:root "$TIMER"
  echo "Installed $TIMER"
}

enable_units() {
  systemctl daemon-reload
  systemctl enable --now pve-auto-upgrade-reboot.timer
  systemctl enable pve-auto-upgrade-post-reboot.service

  echo
  systemctl list-timers --all | grep pve-auto-upgrade-reboot || true
  echo
  echo "Next steps:"
  echo "  - Verify DISCORD_WEBHOOK_URL in $CONF"
  echo "  - Adjust OnCalendar in $TIMER per node (15 min stagger)"
  echo "  - systemctl restart pve-auto-upgrade-reboot.timer"
  echo "  - Optional test: systemctl start pve-auto-upgrade-reboot.service"
}

main() {
  need_root
  install_conf
  install_script
  install_post_reboot_script
  install_logfile
  install_service
  install_post_reboot_service
  install_timer
  enable_units
}

main "$@"
