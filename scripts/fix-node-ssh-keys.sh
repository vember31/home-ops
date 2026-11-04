#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# fix-node-ssh-keys.sh
#
# Ensure the local SSH public key(s) are installed for the login user on every
# k3s node. The script is safe to re-run and only appends keys that are missing.
#
# How it installs a missing key:
#   1. If another local key already works, use SSH to append the missing key.
#   2. Otherwise, use the Proxmox guest agent on the node's PVE host (no
#      password needed, as long as root SSH to the PVE host works).
#   3. Otherwise, fall back to ssh-copy-id and prompt for the node password.
#
# Typical use after a VM rebuild:
#   ./scripts/fix-node-ssh-keys.sh --dry-run
#   ./scripts/fix-node-ssh-keys.sh --reset-known-hosts
#
# Node definitions are: name|ip|ssh_user|pve_host|vmid
###############################################################################

NODE_DEFS=(
  "k3s-control1|192.168.2.11|duke|192.168.2.3|401"
  "k3s-worker4|192.168.2.12|duke|192.168.2.3|402"
  "k3s-control3|192.168.2.13|duke|192.168.2.10|403"
  "k3s-control4|192.168.2.14|duke|192.168.2.2|404"
  "k3s-gpu-worker|192.168.2.15|duke|192.168.2.18|405"
  "k3s-worker1|192.168.2.51|duke|192.168.2.20|100"
  "k3s-worker2|192.168.2.52|duke|192.168.2.21|101"
  "k3s-worker3|192.168.2.53|duke|192.168.2.22|102"
)

SSH_TIMEOUT=5
SSH_PENALTY_WAIT=25
DRY_RUN=0
RESET_KNOWN_HOSTS=0
USE_PVE=1
VERBOSE=0

declare -a NODE_FILTER=()
declare -a KEY_INPUTS=()
declare -a KEY_PUB_FILES=()
declare -a KEY_PRIV_FILES=()
declare -a KEY_LINES=()

declare -a R_NAME=()
declare -a R_IP=()
declare -a R_USER=()
declare -a R_STATUS=()

usage() {
  cat <<'EOF'
Usage: fix-node-ssh-keys.sh [OPTIONS]

Ensure the local SSH public key(s) are installed on the k3s nodes.

Options:
  -n, --node NAME|IP       Only operate on this node (repeatable).
  -k, --key PATH           Private or public key to install (repeatable).
                           Default: ~/.ssh/id_ed25519 and ~/.ssh/id_rsa.
      --dry-run            Show what would change without modifying anything.
      --reset-known-hosts  Remove each target's entry from ~/.ssh/known_hosts
                           before connecting. Use this after rebuilding a VM
                           (the rebuilt guest has a new SSH host key).
      --ssh-only           Do not use the Proxmox guest-agent fallback.
      --timeout SECONDS    SSH connect timeout (default: 5).
  -v, --verbose            Show errors from failed fallback attempts.
      --list               Show the configured nodes and exit.
  -h, --help               Show this help.

Password fallback:
  If a node has no working local key and the Proxmox guest agent is unavailable,
  the script runs ssh-copy-id and prompts for that node's SSH password. Set the
  SSHPASS environment variable to use sshpass non-interactively (if installed).

Examples:
  ./scripts/fix-node-ssh-keys.sh --list
  ./scripts/fix-node-ssh-keys.sh --dry-run
  ./scripts/fix-node-ssh-keys.sh --reset-known-hosts
  ./scripts/fix-node-ssh-keys.sh --node k3s-gpu-worker --key ~/.ssh/id_ed25519
EOF
}

log() { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

is_number() { [[ "$1" =~ ^[0-9]+$ ]]; }

list_nodes() {
  printf '%-18s %-15s %-8s %-15s %s\n' "NODE" "IP" "USER" "PVE HOST" "VMID"
  printf '%-18s %-15s %-8s %-15s %s\n' "----" "--" "----" "--------" "----"
  local def name ip user pve_host vmid
  for def in "${NODE_DEFS[@]}"; do
    IFS='|' read -r name ip user pve_host vmid <<<"$def"
    printf '%-18s %-15s %-8s %-15s %s\n' "$name" "$ip" "$user" "$pve_host" "$vmid"
  done
}

parse_args() {
  while (($#)); do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --list)
        list_nodes
        exit 0
        ;;
      -n|--node)
        (($# >= 2)) || die "$1 requires an argument"
        NODE_FILTER+=("$2")
        shift
        ;;
      --node=*)
        NODE_FILTER+=("${1#*=}")
        ;;
      -k|--key)
        (($# >= 2)) || die "$1 requires an argument"
        KEY_INPUTS+=("$2")
        shift
        ;;
      --key=*)
        KEY_INPUTS+=("${1#*=}")
        ;;
      --dry-run)
        DRY_RUN=1
        ;;
      --reset-known-hosts)
        RESET_KNOWN_HOSTS=1
        ;;
      --ssh-only)
        USE_PVE=0
        ;;
      --timeout)
        (($# >= 2)) || die "$1 requires an argument"
        SSH_TIMEOUT="$2"
        shift
        ;;
      --timeout=*)
        SSH_TIMEOUT="${1#*=}"
        ;;
      -v|--verbose)
        VERBOSE=1
        ;;
      *)
        die "Unknown option: $1 (use --help)"
        ;;
    esac
    shift
  done

  is_number "$SSH_TIMEOUT" && ((SSH_TIMEOUT > 0)) || die "--timeout must be a positive integer"
}

discover_keys() {
  if ((${#KEY_INPUTS[@]})); then
    return
  fi

  local name
  for name in id_ed25519 id_rsa id_ecdsa; do
    if [[ -f "$HOME/.ssh/$name" && -f "$HOME/.ssh/$name.pub" ]]; then
      KEY_INPUTS+=("$HOME/.ssh/$name")
    fi
  done

  ((${#KEY_INPUTS[@]})) || die "No default SSH keys found in ~/.ssh. Use --key PATH."
}

resolve_keys() {
  local input pub priv line
  for input in "${KEY_INPUTS[@]}"; do
    case "$input" in
      "~/"*) input="$HOME/${input#~/}" ;;
    esac

    if [[ "$input" == *.pub ]]; then
      pub="$input"
      priv="${input%.pub}"
    else
      priv="$input"
      pub="${input}.pub"
    fi

    [[ -f "$priv" ]] || die "Private key not found: $priv"
    [[ -f "$pub" ]] || die "Public key not found: $pub"

    line="$(head -n 1 "$pub")"
    [[ -n "$line" ]] || die "Public key is empty: $pub"

    KEY_PRIV_FILES+=("$priv")
    KEY_PUB_FILES+=("$pub")
    KEY_LINES+=("$line")
  done
}

validate_selection() {
  ((${#NODE_FILTER[@]})) || return 0

  local sel def name ip user pve_host vmid found
  for sel in "${NODE_FILTER[@]}"; do
    found=0
    for def in "${NODE_DEFS[@]}"; do
      IFS='|' read -r name ip user pve_host vmid <<<"$def"
      if [[ "$sel" == "$name" || "$sel" == "$ip" ]]; then
        found=1
        break
      fi
    done
    ((found)) || die "Unknown node '$sel'. Use --list to see configured nodes."
  done
}

node_matches() {
  local name="$1" ip="$2" sel

  ((${#NODE_FILTER[@]})) || return 0
  for sel in "${NODE_FILTER[@]}"; do
    [[ "$sel" == "$name" || "$sel" == "$ip" ]] && return 0
  done
  return 1
}

reset_host_key() {
  local host="$1"
  ssh-keygen -R "$host" >/dev/null 2>&1 || true
}

key_auth_works() {
  local priv="$1" user="$2" host="$3"

  ssh \
    -o BatchMode=yes \
    -o ConnectTimeout="$SSH_TIMEOUT" \
    -o StrictHostKeyChecking=accept-new \
    -o PreferredAuthentications=publickey \
    -o PasswordAuthentication=no \
    -o KbdInteractiveAuthentication=no \
    -o IdentitiesOnly=yes \
    -i "$priv" \
    "$user@$host" true >/dev/null 2>&1
}

verify_keys() {
  local user="$1" host="$2" idx

  for idx in "${!KEY_PRIV_FILES[@]}"; do
    key_auth_works "${KEY_PRIV_FILES[$idx]}" "$user" "$host" || return 1
  done
  return 0
}

ssh_probe_penalized() {
  local user="$1" host="$2" out

  if out="$(ssh \
      -o BatchMode=yes \
      -o ConnectTimeout="$SSH_TIMEOUT" \
      -o StrictHostKeyChecking=accept-new \
      -o PreferredAuthentications=publickey \
      -o PasswordAuthentication=no \
      "$user@$host" true 2>&1)"; then
    return 1
  fi

  grep -qE 'Not allowed at this time|kex_exchange_identification' <<<"$out"
}

explain_probe_failure() {
  local user="$1" host="$2" out

  if ! out="$(ssh \
      -o BatchMode=yes \
      -o ConnectTimeout="$SSH_TIMEOUT" \
      -o StrictHostKeyChecking=accept-new \
      -o PreferredAuthentications=publickey \
      -o PasswordAuthentication=no \
      "$user@$host" true 2>&1)"; then
    if grep -qE 'Host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED' <<<"$out"; then
      warn "Host key mismatch for $host. If this VM was rebuilt, re-run with --reset-known-hosts."
    fi
  fi
}

# Build a small, self-contained script that installs the keys for a target user.
# It works both as root (Proxmox guest agent) and as the target user (SSH).
build_install_script() {
  local target_user="$1"
  shift
  local keys_b64
  keys_b64="$(printf '%s\n' "$@" | base64 -w0)"

  cat <<EOF
#!/bin/bash
set -euo pipefail
umask 077

TARGET_USER=$(printf '%q' "$target_user")
KEYS_B64='$keys_b64'

if ! getent passwd "\$TARGET_USER" >/dev/null; then
  echo "KEYFIX_FAILED: user \$TARGET_USER does not exist"
  exit 1
fi

HOME_DIR=\$(getent passwd "\$TARGET_USER" | cut -d: -f6)
TARGET_GROUP=\$(id -gn "\$TARGET_USER")

if [ "\$(id -u)" -eq 0 ]; then
  mkdir -p "\$HOME_DIR/.ssh"
  chmod 700 "\$HOME_DIR/.ssh"
  chown "\$TARGET_USER:\$TARGET_GROUP" "\$HOME_DIR/.ssh"
else
  if [ "\$(id -un)" != "\$TARGET_USER" ]; then
    echo "KEYFIX_FAILED: must run as \$TARGET_USER or root"
    exit 1
  fi
  mkdir -p "\$HOME_DIR/.ssh"
  chmod 700 "\$HOME_DIR/.ssh"
fi

AK="\$HOME_DIR/.ssh/authorized_keys"
touch "\$AK"
if [ "\$(id -u)" -eq 0 ]; then
  chown "\$TARGET_USER:\$TARGET_GROUP" "\$AK"
fi
chmod 600 "\$AK"

backup_done=0
changed=0

while IFS= read -r key; do
  [ -n "\$key" ] || continue

  body=\$(printf '%s\n' "\$key" | awk '{print \$1" "\$2}')
  if [ -s "\$AK" ] && awk '{print \$1" "\$2}' "\$AK" | grep -qxF "\$body"; then
    continue
  fi

  if [ "\$backup_done" -eq 0 ]; then
    cp -a "\$AK" "\$AK.bak.\$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    backup_done=1
  fi

  if [ -s "\$AK" ] && [ "\$(tail -c 1 "\$AK" | wc -l)" -eq 0 ]; then
    printf '\n' >> "\$AK"
  fi
  printf '%s\n' "\$key" >> "\$AK"
  changed=1
done < <(printf '%s' "\$KEYS_B64" | base64 -d)

if [ "\$(id -u)" -eq 0 ]; then
  chown "\$TARGET_USER:\$TARGET_GROUP" "\$AK"
fi
chmod 600 "\$AK"
echo "KEYFIX_OK user=\$TARGET_USER changed=\$changed"
EOF
}

install_via_ssh() {
  local priv="$1" target_user="$2" host="$3"
  shift 3
  local script output

  script="$(build_install_script "$target_user" "$@")"

  if ! output="$(printf '%s' "$script" | ssh \
      -o BatchMode=yes \
      -o ConnectTimeout="$SSH_TIMEOUT" \
      -o StrictHostKeyChecking=accept-new \
      -o PreferredAuthentications=publickey \
      -o PasswordAuthentication=no \
      -o KbdInteractiveAuthentication=no \
      -o IdentitiesOnly=yes \
      -i "$priv" \
      "$target_user@$host" 'bash -s' 2>&1)"; then
    if ((VERBOSE)); then
      printf '%s\n' "$output" >&2
    fi
    return 1
  fi

  if ! grep -q 'KEYFIX_OK' <<<"$output"; then
    if ((VERBOSE)); then
      printf '%s\n' "$output" >&2
    fi
    return 1
  fi

  return 0
}

guest_exec_script() {
  local pve_host="$1" vmid="$2" script="$3"
  local b64 remote_cmd

  b64="$(printf '%s' "$script" | base64 -w0)"
  remote_cmd="qm guest exec $vmid -- /bin/bash -c 'echo $b64 | base64 -d | /bin/bash'"

  ssh \
    -o BatchMode=yes \
    -o ConnectTimeout="$SSH_TIMEOUT" \
    -o StrictHostKeyChecking=accept-new \
    "root@$pve_host" "$remote_cmd" 2>&1
}

install_via_pve() {
  local pve_host="$1" vmid="$2" target_user="$3"
  shift 3
  local script output

  script="$(build_install_script "$target_user" "$@")"
  output="$(guest_exec_script "$pve_host" "$vmid" "$script")" || true

  if grep -q 'KEYFIX_OK' <<<"$output"; then
    return 0
  fi

  if ((VERBOSE)); then
    printf '%s\n' "$output" >&2
  fi
  return 1
}

try_ssh_copy_id() {
  local priv="$1" target_user="$2" host="$3"
  local -a cmd

  if [[ ! -t 0 ]]; then
    warn "Cannot prompt for a password (stdin is not a TTY)."
    return 1
  fi

  cmd=(ssh-copy-id
    -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout="$SSH_TIMEOUT"
    -i "$priv"
    "$target_user@$host")

  if [[ -n "${SSHPASS:-}" ]] && command -v sshpass >/dev/null 2>&1; then
    sshpass -e "${cmd[@]}"
  else
    "${cmd[@]}"
  fi
}

add_result() {
  R_NAME+=("$1")
  R_IP+=("$2")
  R_USER+=("$3")
  R_STATUS+=("$4")
}

main() {
  parse_args "$@"
  discover_keys
  resolve_keys
  validate_selection

  log "Ensuring keys: $(printf '%s ' "${KEY_PUB_FILES[@]}")"
  log "Mode: $([[ "$DRY_RUN" -eq 1 ]] && echo 'dry-run' || echo 'apply')"

  local def name ip user pve_host vmid idx
  local -a missing_indices=() missing_lines=() missing_privs=()
  local working_priv status installed verify_failed failures=0
  local -a key_names=()
  for idx in "${!KEY_PUB_FILES[@]}"; do
    key_names+=("$(basename "${KEY_PUB_FILES[$idx]}")")
  done

  for def in "${NODE_DEFS[@]}"; do
    IFS='|' read -r name ip user pve_host vmid <<<"$def"
    node_matches "$name" "$ip" || continue

    if ((RESET_KNOWN_HOSTS)); then
      reset_host_key "$ip"
    fi

    log "$name ($ip, user $user)"

    missing_indices=()
    working_priv=""

    for idx in "${!KEY_PRIV_FILES[@]}"; do
      if key_auth_works "${KEY_PRIV_FILES[$idx]}" "$user" "$ip"; then
        printf '    %-20s ok\n' "${key_names[$idx]}"
        if [[ -z "$working_priv" ]]; then
          working_priv="${KEY_PRIV_FILES[$idx]}"
        fi
      else
        printf '    %-20s missing\n' "${key_names[$idx]}"
        missing_indices+=("$idx")
      fi
    done

    if ((${#missing_indices[@]} == 0)); then
      add_result "$name" "$ip" "$user" "ok"
      continue
    fi

    if ((DRY_RUN)); then
      add_result "$name" "$ip" "$user" "would install ${#missing_indices[@]} key(s)"
      continue
    fi

    missing_lines=()
    missing_privs=()
    for idx in "${missing_indices[@]}"; do
      missing_lines+=("${KEY_LINES[$idx]}")
      missing_privs+=("${KEY_PRIV_FILES[$idx]}")
    done

    installed=0

    # Preferred: use a key that already works on the node.
    if [[ -n "$working_priv" ]]; then
      if install_via_ssh "$working_priv" "$user" "$ip" "${missing_lines[@]}"; then
        log "    installed missing key(s) via existing SSH key"
        installed=1
      fi
    fi

    # Useful after a rebuild where no local key works yet, but the guest agent
    # is available through the Proxmox host.
    if ((!installed)) && ((USE_PVE)) && [[ -n "$pve_host" && -n "$vmid" ]]; then
      if install_via_pve "$pve_host" "$vmid" "$user" "${missing_lines[@]}"; then
        log "    installed missing key(s) via Proxmox guest agent ($pve_host, VM $vmid)"
        installed=1
      fi
    fi

    # Last resort: password auth via ssh-copy-id.
    if ((!installed)); then
      if [[ -t 0 ]]; then
        warn "$name has no working key; trying ssh-copy-id (password prompt)"
        if try_ssh_copy_id "${missing_privs[0]}" "$user" "$ip"; then
          if install_via_ssh "${missing_privs[0]}" "$user" "$ip" "${missing_lines[@]}"; then
            log "    installed missing key(s) via ssh-copy-id"
            installed=1
          fi
        fi
      else
        warn "$name has no working key and no non-interactive install path."
      fi
    fi

    verify_failed=0
    verify_keys "$user" "$ip" || verify_failed=1

    # Repeated key probes can trip sshd's per-source rate limiting (Ubuntu
    # 26.04 enables PerSourcePenalties). Wait it out and verify once more.
    if ((verify_failed != 0)) && ssh_probe_penalized "$user" "$ip"; then
      warn "SSH is temporarily rate-limiting $ip; waiting ${SSH_PENALTY_WAIT}s before retrying verification."
      sleep "$SSH_PENALTY_WAIT"
      verify_failed=0
      verify_keys "$user" "$ip" || verify_failed=1
    fi

    if ((verify_failed != 0)); then
      explain_probe_failure "$user" "$ip"
      add_result "$name" "$ip" "$user" "FAILED"
      failures=$((failures + 1))
    else
      add_result "$name" "$ip" "$user" "ok"
    fi
  done

  printf '\nSummary:\n'
  printf '%-18s %-15s %-8s %s\n' "NODE" "IP" "USER" "RESULT"
  printf '%-18s %-15s %-8s %s\n' "----" "--" "----" "------"
  for idx in "${!R_NAME[@]}"; do
    printf '%-18s %-15s %-8s %s\n' "${R_NAME[$idx]}" "${R_IP[$idx]}" "${R_USER[$idx]}" "${R_STATUS[$idx]}"
  done

  if ((failures > 0)); then
    printf '\n%d node(s) failed verification.\n' "$failures" >&2
    exit 1
  fi

  if ((DRY_RUN)); then
    printf '\nDry run only. Re-run without --dry-run to install missing keys.\n'
  else
    printf '\nAll selected nodes accept all configured keys.\n'
  fi
}

main "$@"
