#!/usr/bin/env bash
set -euo pipefail

# Install the temporary cri-containerd AppArmor profile workaround for
# k3s/containerd profile stacking on Ubuntu 26.04 / kernel 6.17+.
#
# See docs/runbooks/apparmor-signal-stacking.md for context and removal steps.
# Remove this workaround once k3s/containerd includes the stacked-peer rules.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
PROFILE_SRC="${PROFILE_SRC:-$REPO_ROOT/configs/apparmor/cri-containerd.apparmor.d}"
PROFILE_DST="/etc/apparmor.d/cri-containerd.apparmor.d"
STACK_FEATURE="/sys/kernel/security/apparmor/features/domain/stack"
K3S_BIN="/var/lib/rancher/k3s/data/current/bin/k3s"

usage() {
  cat <<'EOF'
Usage: install-cri-containerd-apparmor-workaround.sh [--uninstall] [--force]

Installs a corrected cri-containerd.apparmor.d profile and reloads it.

Options:
  --uninstall  Remove the profile. Reboot afterwards so containerd can load
               its built-in profile (required after the upstream fix).
  --force      Install even if the k3s binary appears to already contain the
               stacked-peer rule.
  -h, --help   Show this help.

Environment:
  PROFILE_SRC  Override the profile source path.
EOF
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This script must be run as root." >&2
    exit 1
  fi
}

uninstall_profile() {
  require_root
  if [[ -f "${PROFILE_DST}" ]]; then
    rm -f "${PROFILE_DST}"
    echo "Removed ${PROFILE_DST}."
  else
    echo "${PROFILE_DST} is not present; nothing to remove."
  fi
  cat <<'EOF'

Reboot the node to unload the profile. Restarting k3s alone is not enough:
the old profile remains loaded in the kernel, so containerd will skip loading
its built-in profile.
EOF
}

MODE="install"
FORCE=0
for arg in "$@"; do
  case "${arg}" in
    --uninstall) MODE="uninstall" ;;
    --force) FORCE=1 ;;
    -h|--help) usage ; exit 0 ;;
    *)
      echo "Unknown argument: ${arg}" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "${MODE}" == "uninstall" ]]; then
  uninstall_profile
  exit 0
fi

require_root

if ! command -v apparmor_parser >/dev/null 2>&1; then
  echo "apparmor_parser is not installed; this node does not look like an AppArmor host." >&2
  exit 1
fi

if [[ ! -r "${STACK_FEATURE}" ]]; then
  echo "AppArmor profile stacking is not available on this node; workaround not needed."
  exit 0
fi

if [[ "$(cat "${STACK_FEATURE}")" != "yes" ]]; then
  echo "AppArmor profile stacking is not enabled on this node; workaround not needed."
  exit 0
fi

if [[ ! -f "${PROFILE_SRC}" ]]; then
  echo "Profile source not found: ${PROFILE_SRC}" >&2
  echo "Run this script from a checkout of the home-ops repo, or set PROFILE_SRC." >&2
  exit 1
fi

# Best-effort check: if the installed k3s binary already applies a stacked-peer
# rule, the workaround should not be needed. Use --force to override a false
# positive (for example if the check cannot read the binary).
if [[ "${FORCE}" -eq 0 && -e "${K3S_BIN}" ]] && command -v strings >/dev/null 2>&1; then
  if strings "${K3S_BIN}" 2>/dev/null | grep -qE 'peer=\{\{\.Name\}\}//|cri-containerd\.apparmor\.d//'; then
    echo "The installed k3s binary already references stacked AppArmor peer names."
    echo "Not installing the workaround. Use --force if this is a false positive."
    exit 0
  fi
fi

if ! apparmor_parser -N -K -T "${PROFILE_SRC}"; then
  echo "AppArmor profile validation failed: ${PROFILE_SRC}" >&2
  exit 1
fi

if [[ -f "${PROFILE_DST}" ]] && ! cmp -s "${PROFILE_SRC}" "${PROFILE_DST}"; then
  backup="${PROFILE_DST}.bak.$(date +%Y%m%d%H%M%S)"
  cp -a "${PROFILE_DST}" "${backup}"
  echo "Backed up existing profile to ${backup}."
fi

install -Dm644 "${PROFILE_SRC}" "${PROFILE_DST}"
apparmor_parser -r "${PROFILE_DST}"

cat <<EOF

Installed and reloaded ${PROFILE_DST}.

Restart affected workloads (for example Blocky and CrowdSec AppSec) if they
are currently stuck. Check dmesg for new apparmor signal denials afterwards.

This is a temporary workaround. Remove it once k3s/containerd includes the
stacked-peer fix; see docs/runbooks/apparmor-signal-stacking.md.
EOF
