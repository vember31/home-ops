# UNVR Storage Recovery Runbook

Context for the UNVR (192.168.2.189) drive incident of October 2026: what happened, what was done, how to monitor it, and how to repair it again if it recurs.

**Last updated:** 2026-10-18
**Author:** recovery performed interactively (OpenCode session); this doc rebuilds that context.

---

## TL;DR — Current Status (2026-10-18)

- **UNVR is healthy and green in the UI.** Both drives pass SMART, RAID1 (`md3`) is clean, `Reallocated_Sector_Ct = 0` on both.
- Root cause of the incident: **localized event damage** (bad ECC on writes — signature of an unclean shutdown / power event) in a ~250 MB zone on **both** drives at disk LBA ≈ **1,761,873,904 – 1,762,355,688** (~902.1–902.3 GB into each disk). The same-region-on-both-drives pattern rules out two independently dying drives.
- All hard failures were **healed** (rewritten/remapped); a handful of **retry-marginal** sectors remain on sdb in that zone (`Current_Pending_Sector` wobbles ~12; reads succeed after drive-internal retries). This is cosmetic/functional-noise, not failure.
- **No replacement needed.** Watch monthly with `scripts/unvr-health-check.sh`. Replacement triggers are in [§6](#6-watch-plan--replacement-triggers).

---

## 1. Access

```bash
ssh unvr        # alias in ~/.ssh/config
```

Alias (created during the incident):

```
Host unvr 192.168.2.189
    HostName 192.168.2.189
    User root
    IdentityFile ~/.ssh/unvr_ed25519
    IdentitiesOnly yes
    ConnectTimeout 10
```

- Key `~/.ssh/unvr_ed25519` is installed at `/root/.ssh/authorized_keys` on the UNVR. **Firmware updates or toggling SSH off/on in the UniFi console can wipe it** — reinstall with the one-liner in [§7](#7-appendices).
- Password login (if ever needed): the SSH password set in **Settings → Console → SSH** (UniFi OS console UI).
- **sshd gotchas (bit us hard):**
  - Low `MaxAuthTries`: if your client offers several keys, the password method can be refused *without ever prompting* → looks like "Permission denied (publickey,keyboard-interactive)". Use `IdentitiesOnly yes` (the alias above does).
  - Failed-password lockout: repeated wrong passwords cause a temporary lockout (~10–15 min) where the server refuses to even prompt. Wait it out; don't hammer.
  - For scripts: `ssh -o BatchMode=yes`.

---

## 2. Hardware & Layout

- **UNVR** (aarch64, UniFi OS, kernel `4.19.152-alpine-unvr`). Boots from an internal 29 GB USB mass storage device (`boot1–boot5`); irrelevant to drive health.
- **Drives (RAID1 pair, same batch):**
  - `sda` = `WD-WCC7K1LKNKSP` — WDC WD40PURZ-85TTDY0 (WD Purple 4 TB, 5400 rpm), firmware 80.00A80
  - `sdb` = `WD-WCC7K4EK639Z` — same model/firmware
  - Array created 2024-09-15; ~18,260 power-on hours as of Oct 2026 (~2.1 years).
- **Partition layout (both disks):** `p1` 512 M · `p2` 2 G → `md0` (OS RAID1) · `p3` 1 G (unused) · `p5` remainder → **`md3`** (data RAID1, 3.63 TiB, ext4).
- `md3` volume UUID `bba14394-903a-4090-be8d-7d8688f0d006`, mounted at `/volume/bba14394-...` — this is **UniFi Protect storage** (~99% full is normal — Protect rotates).
- Daemons worth knowing: `usd` = "UI storage daemon" (drive/array health for the console UI; `journalctl -u usd`), `usdbd` = its status DB, `unifi-protect` = the NVR app.

### LBA math (critical for any repair work)

```
md3 array sector N  <->  disk LBA = N + 17,039,360     (on BOTH drives)
                          where 17,039,360 = 16,777,216 (partition start) + 262,144 (md data offset)
```

Verify anytime:

```bash
cat /sys/block/md3/md/dev-sda5/offset        # -> 262144
mdadm --examine /dev/sda5 | grep "Data Offset"   # -> 262144 sectors
```

`mdadm --examine-badblocks` reports **device-relative** sectors: `device = array_sector + 262,144`.

---

## 3. Incident Timeline (Oct 2026)

| When | What |
|---|---|
| ≥ Sep 12 | First ATA error-handler cycles on both drives (old `/var/log/messages.1`). |
| Oct 10 03:33 (boot) | Cluster of UNC read errors on **both** drives, LBA ~1,761,874,000–1,761,884,000. |
| Oct 10–15 | Scattered UNC errors; nightly bursts ~03:00; sector 1761878432 failed on **both** drives (double-failure). |
| Oct 15 | Diagnosis: `Current_Pending_Sector` sda=8 / sdb=2; kernel `print_req_error` UNC entries; RAID1 masking it all. Extended SMART self-tests started (starved by recording I/O — see §5). |
| Oct 17 | Full `md3` repair pass (`echo repair > /sys/block/md3/md/sync_action`), ~13 h under recording load. Fixed most sectors. |
| Oct 17 eve | 7 sda sectors still failing after the scrub. Root cause: **md auto-badblocked them** — once listed, md skips them on read *and* on repair-write (chicken-and-egg). Discoveries below. |
| Oct 17 eve | All bad sectors healed with **4K-aligned raw writes** from the sibling drive; stale badblock entries cleared via successful writes through `/dev/md3`; 2 double-dead 4K blocks zero-filled (total data loss: 8 KB). |
| Oct 17 23:23 | Restarted `usd` + `usdbd` → forced clean re-scan; the UI "overlapping bad blocks" warning source was `usd`'s log. |
| Oct 18 | UI "repair storage" action (Protect) ran `e2fsck` (fixed fs errors, exit 1), remounted volume, restarted all media services. Overnight scans flushed more weak sectors in the zone (sdb pending 2→13→16). |
| Oct 18 08:00 | Zone read-sweep + full write-scour (276 MB × both drives): **zero hard failures**; a few marginal sdb sectors remain (retry-readable). UI green. |

### Key technical discoveries (the hard-won bits)

1. **512-byte writes to a bad 4K physical sector FAIL** (read-modify-write can't read the sector). **Full 4K-aligned writes succeed** and let the drive rewrite/remap. Always heal with `bs=4096`.
2. **md auto-adds read-error sectors to its badblock list.** Consequences: reads skip that leg, and repair passes skip rewriting them → "the scrub didn't fix it". `mdadm --examine-badblocks /dev/sdX5` shows them. On kernel 4.19 the sysfs `bad_blocks` attribute does **not** accept writes (`clear` / `0 0` both rejected).
3. **A successful write through `/dev/md3` clears the badblock entry** for that range (md gives bad sectors a second chance on write). Order matters: heal the sector first, *then* write through md3.
4. **SMART counters on these drives are lazy** — `Current_Pending_Sector` can lag hours. A single reading is not truth; watch the trend.
5. **The `usd` daemon** tracks "overlapping bad blocks" (same range bad on both legs, tolerance 1) and logs warnings to `journalctl -u usd`. This is what the console UI warning was based on.

---

## 4. Current State Snapshot (2026-10-18, after repair)

| Check | sda | sdb |
|---|---|---|
| SMART overall | PASSED | PASSED |
| `Current_Pending_Sector` | **0** | ~12 (wobbling; retry-marginal zone sectors) |
| `Reallocated_Sector_Ct` | **0** | **0** |
| `UDMA_CRC_Error_Count` | 0 | 0 |
| Last self-test | Short, passed | Short, passed |
| Power-on hours | ~18,260 | ~18,260 |

- Array: `md3 [UU]`, `degraded: 0`, `sync_action: idle`, `mismatch_cnt ≈ 60648` (informational — live-array write races during scrubs; ignore).
- md badblock lists: **empty** on both legs.
- Known marginal zone: disk LBA ≈ **1,761,873,904 – 1,762,355,688** (~902.1–902.3 GB offset; 1 MB blocks **860,270–860,545**). Marginal sdb sectors observed: `1761874072`, `1761874376`, `1762331336` — reads need retries but succeed.
- UI: green (after the "repair storage" action).

---

## 5. Monitoring

Run the health check (see `scripts/unvr-health-check.sh`):

```bash
scripts/unvr-health-check.sh            # fast (~10 s)
scripts/unvr-health-check.sh --deep     # + sweeps the known damage zone (~1-3 min)
```

Cadence: **monthly**, or after any Protect storage alert.

What the fast check reports: array state, per-drive pending/reallocated/CRC/self-test, md badblock lists, recent kernel I/O errors, recent `usd` warnings.

Caveats:
- `dmesg` shows errors since last boot only; `journalctl -u usd` covers the longer window.
- Extended SMART self-tests **starve under recording load** (offline collection suspends on host I/O) — they can take days and get aborted. Short tests are fine. Prefer `--deep` sweeps over extended tests for surface checks.
- An `smartctl -t offline` scan also makes slow progress but never logs LBAs to the host.

---

## 6. Watch Plan & Replacement Triggers

**Fine to keep running** if: pending stays in the low double digits (or lower), reallocated stays 0, and errors stay inside the known zone.

**Plan replacement** when any of these appear:
1. `Reallocated_Sector_Ct` starts climbing (drive burning spare sectors = real media death).
2. `print_req_error` entries appear **outside** the known zone LBA range.
3. Pending grows well beyond the zone's population, or a drive drops from the array (`[UU]` → `[U_]`).

When replacing: RAID1 = pull the bad drive, insert new (same size or larger), let Protect/md rebuild. With this volume at 99% and both drives same-batch, expect to eventually replace **both** — but only on evidence, not preemptively.

---

## 7. Appendices

### Repair playbook — full scrub

```bash
# Full array repair pass (reads everything, rewrites single-leg failures).
# Runs hours; recording continues. Watch with: cat /proc/mdstat
ssh unvr 'echo repair > /sys/block/md3/md/sync_action'
```

Afterwards, check for unfixed sectors:

```bash
ssh unvr 'mdadm --examine-badblocks /dev/sda5; mdadm --examine-badblocks /dev/sdb5'
```

Non-empty lists = sectors md gave up on → heal them manually (below), then clear the entries.

### Repair playbook — heal a single sector

```bash
# Heal drive X at disk LBA L, using data from the healthy sibling Y.
# (Run on the UNVR; /tmp is fine for scratch files.)
L=1761878432; X=sda; Y=sdb; BLK=$((L/8))
dd if=/dev/$Y bs=4096 skip=$BLK count=1 of=/tmp/blk.bin
dd if=/tmp/blk.bin of=/dev/$X bs=4096 seek=$BLK count=1 conv=fsync
dd if=/dev/$X bs=512 skip=$L count=1 of=/dev/null && echo "healed OK"
```

- **Never use 512-byte writes** on a suspect sector (RMW fails).
- If both legs are unreadable at the same LBA (double-dead): write zeros to **both** legs the same way (the data is unrecoverable; zeros are strictly better than erroring sectors), then clear via md3.
- Raw writes bypass md deliberately (no risk of md faulting a drive on write error). Content written = what the sibling holds = what the array serves → consistent.

### Repair playbook — clear md badblocks

For each range from `mdadm --examine-badblocks` (device-relative `D`, count `C`):

```bash
# array sectors: N = D - 262144 ; disk LBA = N + 17039360
# For each 4K block in [N, N+C): write it through md3 using data from a healthy leg.
N=$((1745100992 - 262144))          # e.g. 1744838848
LBA=$((N + 17039360))
dd if=/dev/sdb bs=4096 skip=$((LBA/8)) count=1 of=/tmp/b.bin
dd if=/tmp/b.bin of=/dev/md3 bs=4096 seek=$((N/8)) count=1 conv=fsync
# verify: mdadm --examine-badblocks /dev/sda5  (entry should shrink/vanish)
```

### Repair playbook — zone sweep

```bash
# Read-sweep the known damage zone (1MB blocks 860,270–860,545) on both drives.
# Any hard-failing chunks get listed; heal those 4K blocks individually.
for d in sda sdb; do
  for b in $(seq 860270 860545); do
    dd if=/dev/$d bs=1M skip=$b count=1 of=/dev/null 2>/dev/null || echo "$d chunk $b FAILED"
  done
done
```

### UI warning reset ladder (if the console shows storage warnings again)

1. `ssh unvr 'systemctl restart usd usdbd'` → forces a clean re-scan of drives/arrays.
2. In the UniFi UI: storage page → **"repair storage"** action (runs `e2fsck`, remounts, restarts media services — this is the heavy, thorough one).
3. `ssh unvr 'systemctl restart unifi-protect'` → fresh Protect storage assessment (~75 s).
4. Reboot the UNVR (last resort; forces everything fresh).

### Reinstall the SSH key on the UNVR

```bash
mkdir -p /root/.ssh && chmod 700 /root/.ssh && echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDnHRUBz06Tr3310UEbipAG5FT0zIqH1QLYDkPWPtIbu opencode@home-ops -> unvr' >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
```

### Useful one-liners

```bash
ssh unvr 'cat /proc/mdstat'                                   # array + scrub progress
ssh unvr 'smartctl -a /dev/sdb | grep -E "Pending|Reallocated"'  # drive counters
ssh unvr 'dmesg -T | grep print_req_error | tail'             # recent I/O errors
ssh unvr 'journalctl -u usd --since "24 hours ago" | grep -i warning'  # usd health warnings
ssh unvr 'mdadm --examine-badblocks /dev/sda5; mdadm --examine-badblocks /dev/sdb5'
```
