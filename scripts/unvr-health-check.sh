#!/usr/bin/env bash
# UNVR drive health check.
#
# Full context, incident history, and repair playbook:
#   docs/runbooks/unvr-storage-recovery.md
#
# Usage:
#   scripts/unvr-health-check.sh            # fast check (~10 s)
#   scripts/unvr-health-check.sh --deep     # + sweeps the known damage zone (~1-3 min)
#
# Requires SSH access to the UNVR. Uses the `unvr` alias from ~/.ssh/config
# (root@192.168.2.189, key ~/.ssh/unvr_ed25519, IdentitiesOnly yes), or override:
#   UNVR_HOST=root@192.168.2.189 scripts/unvr-health-check.sh
#
# What to watch (details in the runbook):
#   - Current_Pending_Sector / Reallocated_Sector_Ct per drive (trend, not single reading)
#   - I/O errors OUTSIDE the known zone (disk LBA ~1,761.87M - 1,762.36M)
#   - Reallocated_Sector_Ct climbing => plan drive replacement
#   - md bad-block lists should stay EMPTY

set -u

HOST="${UNVR_HOST:-unvr}"
MODE="${1:-}"

if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" true 2>/dev/null; then
  echo "ERROR: cannot ssh to '$HOST'." >&2
  echo "Configure the 'unvr' alias in ~/.ssh/config (see runbook), or run:" >&2
  echo "  UNVR_HOST=root@192.168.2.189 $0 $MODE" >&2
  exit 1
fi

echo "===== UNVR health check - $(date) ====="

ssh -o BatchMode=yes "$HOST" '
echo
echo "--- RAID array (md3 = Protect data) ---"
grep -A2 "md3" /proc/mdstat
printf "sync_action:   "; cat /sys/block/md3/md/sync_action
printf "degraded:      "; cat /sys/block/md3/md/degraded
printf "mismatch_cnt:  "; cat /sys/block/md3/md/mismatch_cnt
echo
echo "--- SMART ---"
for d in sda sdb; do
  echo "[$d]"
  smartctl -a /dev/$d | grep -E "SMART overall-health|Current_Pending_Sector|Reallocated_Sector_Ct|Offline_Uncorrectable|UDMA_CRC|Power_On_Hours|Temperature_Cels"
  printf "  last self-test: "; smartctl -l selftest /dev/$d | grep -m1 "^# " || echo "(none)"
done
echo
echo "--- md bad-blocks (should be empty) ---"
mdadm --examine-badblocks /dev/sda5
mdadm --examine-badblocks /dev/sdb5
echo
echo "--- I/O errors (kernel log, this boot) ---"
echo "total: $(dmesg -T | grep -c print_req_error)"
dmesg -T | grep print_req_error | tail -5
echo
echo "--- usd warnings (last 24h) ---"
journalctl -u usd --since "24 hours ago" --no-pager 2>/dev/null | grep -i warning | tail -5
echo "(empty above = clean)"
'

if [ "$MODE" = "--deep" ]; then
  echo
  echo "===== DEEP: sweeping known damage zone (1MB blocks 860270-860545) ====="
  ssh -o BatchMode=yes "$HOST" '
for d in sda sdb; do
  f=0
  for b in $(seq 860270 860545); do
    dd if=/dev/$d bs=1M skip=$b count=1 of=/dev/null 2>/dev/null || { echo "  $d chunk $b (sector $((b*2048))) FAILED"; f=$((f+1)); }
  done
  echo "$d: hard-failing chunks: $f"
done
echo "(all zero = zone is clean; heal any FAILED chunks per the runbook)"
'
fi
