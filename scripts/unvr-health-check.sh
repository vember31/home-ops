#!/usr/bin/env bash
# UNVR drive + Protect DB health check.
#
# Full context, incident history, and repair playbook:
#   docs/runbooks/unvr-storage-recovery.md
#
# Usage:
#   scripts/unvr-health-check.sh            # fast check (~10 s)
#   scripts/unvr-health-check.sh --deep     # + sweeps the known damage zone (~1-3 min)
#   scripts/unvr-health-check.sh --db       # + pg_amcheck cameras/users/events (~1-3 min)
#   scripts/unvr-health-check.sh --all      # fast + deep + db
#
# Requires SSH access to the UNVR. Uses the `unvr` alias from ~/.ssh/config
# (root@192.168.2.189, key ~/.ssh/unvr_ed25519, IdentitiesOnly yes), or override:
#   UNVR_HOST=root@192.168.2.189 scripts/unvr-health-check.sh
#
# What to watch (details in the runbook):
#   - Current_Pending_Sector / Reallocated_Sector_Ct per drive (trend, not single reading)
#   - NEW I/O errors outside the known zone (historical ones are documented in the runbook)
#   - Reallocated_Sector_Ct climbing => plan drive replacement
#   - md bad-block lists should stay EMPTY
#   - PostgreSQL btree index corruption in Protect's DB (--db)
#
# Known damage zone (disk LBA, 512-byte sectors), see runbook §4:
#   1,761,873,904 - 1,762,355,688
#
# Exit codes: 0 clean, 2 new out-of-zone I/O warning, 1 command/DB-check failure.

set -u

HOST="${UNVR_HOST:-unvr}"
MODE="${1:-}"
KZ_MIN=1761873904
KZ_MAX=1762355688
RC=0

DO_DEEP=0
DO_DB=0
case "$MODE" in
  "") ;;
  --deep) DO_DEEP=1 ;;
  --db) DO_DB=1 ;;
  --all) DO_DEEP=1; DO_DB=1 ;;
  *) echo "Usage: $0 [--deep|--db|--all]" >&2; exit 2 ;;
esac

if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" true 2>/dev/null; then
  echo "ERROR: cannot ssh to '$HOST'." >&2
  echo "Configure the 'unvr' alias in ~/.ssh/config (see runbook), or run:" >&2
  echo "  UNVR_HOST=root@192.168.2.189 $0 $MODE" >&2
  exit 1
fi

echo "===== UNVR health check - $(date) ====="

ssh -o BatchMode=yes "$HOST" "KZ_MIN=$KZ_MIN KZ_MAX=$KZ_MAX sh -s" <<'REMOTE_FAST'
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
total=$(dmesg -T | grep -c print_req_error)
total=${total:-0}
echo "total: $total"
outside=0
if [ "$total" -gt 0 ]; then
  outside=$(dmesg -T | grep print_req_error | sed -E 's/.*sector ([0-9]+).*/\1/' | awk -v lo="$KZ_MIN" -v hi="$KZ_MAX" '$1 < lo || $1 > hi' | wc -l | tr -d ' ')
  outside_sda=$(dmesg -T | grep print_req_error | grep "dev sda," | sed -E 's/.*sector ([0-9]+).*/\1/' | awk -v lo="$KZ_MIN" -v hi="$KZ_MAX" '$1 < lo || $1 > hi' | wc -l | tr -d ' ')
  outside_sdb=$(dmesg -T | grep print_req_error | grep "dev sdb," | sed -E 's/.*sector ([0-9]+).*/\1/' | awk -v lo="$KZ_MIN" -v hi="$KZ_MAX" '$1 < lo || $1 > hi' | wc -l | tr -d ' ')
  echo "outside known zone (all boot, LBA $KZ_MIN-$KZ_MAX): $outside (sda=$outside_sda, sdb=$outside_sdb)"
  echo "last 5 errors (all):"
  dmesg -T | grep print_req_error | tail -5
fi

# New errors since the documented Oct 2026 repair cutoff. journalctl keeps
# messages that may already have rotated out of the dmesg ring buffer.
# Bump this after a documented repair/acknowledgement so historical errors
# are not re-flagged as new.
NEW_CUTOFF="2026-10-18 08:04:00"
new_total=$(journalctl -k --since "$NEW_CUTOFF" --no-pager 2>/dev/null | grep -c print_req_error)
new_total=${new_total:-0}
new_outside=$(journalctl -k --since "$NEW_CUTOFF" --no-pager 2>/dev/null | grep print_req_error | sed -E 's/.*sector ([0-9]+).*/\1/' | awk -v lo="$KZ_MIN" -v hi="$KZ_MAX" '$1 < lo || $1 > hi' | wc -l | tr -d ' ')
new_outside=${new_outside:-0}
echo "new since $NEW_CUTOFF: $new_total (outside known zone: $new_outside)"
if [ "$new_outside" -gt 0 ]; then
  echo "WARNING: NEW I/O errors outside the known zone (replacement trigger):"
  journalctl -k --since "$NEW_CUTOFF" --no-pager 2>/dev/null | grep print_req_error | while IFS= read -r line; do
    sec=$(echo "$line" | sed -E 's/.*sector ([0-9]+).*/\1/')
    case "$sec" in ''|*[!0-9]*) continue ;; esac
    if [ "$sec" -lt "$KZ_MIN" ] || [ "$sec" -gt "$KZ_MAX" ]; then
      echo "  $line"
    fi
  done | tail -10
fi
echo
echo "--- usd warnings (last 24h) ---"
journalctl -u usd --since "24 hours ago" --no-pager 2>/dev/null | grep -i warning | tail -5
echo "(empty above = clean)"
if [ "$new_outside" -gt 0 ]; then exit 2; fi
REMOTE_FAST
fast_rc=$?
if [ "$fast_rc" -eq 2 ]; then
  RC=2
elif [ "$fast_rc" -ne 0 ]; then
  echo "WARNING: health check command failed (rc=$fast_rc)" >&2
  RC=1
fi

if [ "$DO_DEEP" -eq 1 ]; then
  echo
  echo "===== DEEP: sweeping known damage zone (1MB blocks 860270-860545) ====="
  ssh -o BatchMode=yes "$HOST" 'sh -s' <<'REMOTE_DEEP'
for d in sda sdb; do
  f=0
  for b in $(seq 860270 860545); do
    dd if=/dev/$d bs=1M skip=$b count=1 of=/dev/null 2>/dev/null || { echo "  $d chunk $b (sector $((b*2048))) FAILED"; f=$((f+1)); }
  done
  echo "$d: hard-failing chunks: $f"
done
echo "(all zero = zone is clean; heal any FAILED chunks per the runbook)"
REMOTE_DEEP
  deep_rc=$?
  if [ "$deep_rc" -ne 0 ]; then
    echo "WARNING: deep sweep command failed (rc=$deep_rc)" >&2
    RC=1
  fi
fi

if [ "$DO_DB" -eq 1 ]; then
  echo
  echo "===== DB: Protect PostgreSQL btree index check (cameras, users, events) ====="
  echo "Note: pg_amcheck takes ShareLocks; run during a quiet window."
  ssh -o BatchMode=yes "$HOST" 'sh -s' <<'REMOTE_DB'
set -u
cd /tmp || cd /
PG_AMCHECK=/usr/lib/postgresql/14/bin/pg_amcheck
if [ ! -x "$PG_AMCHECK" ]; then
  PG_AMCHECK=$(command -v pg_amcheck 2>/dev/null || true)
fi
if [ -z "${PG_AMCHECK:-}" ] || [ ! -x "$PG_AMCHECK" ]; then
  echo "pg_amcheck not installed; skipping DB check"
  exit 0
fi
if ! sudo -u postgres psql -p 5433 -d unifi-protect -Atc "select 1 from pg_extension where extname='amcheck'" | grep -q 1; then
  echo "Installing amcheck extension..."
  sudo -u postgres psql -p 5433 -d unifi-protect -c "create extension if not exists amcheck;" >/dev/null
fi
start=$(date +%s)
if sudo -u postgres "$PG_AMCHECK" -p 5433 -d unifi-protect --heapallindexed \
     --table=cameras --table=users --table=events; then
  echo "pg_amcheck: PASS ($(( $(date +%s) - start ))s)"
else
  rc=$?
  echo "pg_amcheck: FAIL (rc=$rc, $(( $(date +%s) - start ))s)" >&2
  exit "$rc"
fi
REMOTE_DB
  db_rc=$?
  if [ "$db_rc" -ne 0 ]; then
    echo "WARNING: Protect DB index check failed (rc=$db_rc)" >&2
    RC=1
  fi
fi

exit "$RC"
