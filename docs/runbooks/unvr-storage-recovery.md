# UNVR Storage Recovery Runbook

Context for the UNVR (192.168.2.189) drive incident of October 2026: what happened, what was done, how to monitor it, and how to repair it again if it recurs.

**Last updated:** 2026-11-08
**Author:** recovery performed interactively (OpenCode session); this doc rebuilds that context.

---

## TL;DR — Current Status (2026-11-08)

- **Array is healthy (`md3 [UU]`), both drives pass SMART, and `Reallocated_Sector_Ct = 0` on both — but sdb had a new out-of-zone error event on 2026-11-08 (see below).**
- Root cause of the incident: **event damage** (bad ECC on writes — signature of an unclean shutdown / power event), initially localized in a ~250 MB zone on **both** drives at disk LBA ≈ **1,761,873,904 – 1,762,355,688** (~902.1–902.3 GB into each disk). The same-region-on-both-drives pattern rules out two independently dying drives.
- All historical hard failures were **healed** (rewritten/remapped); a handful of **retry-marginal** sectors remain on sdb in that zone (`Current_Pending_Sector` wobbles ~12; reads succeed after drive-internal retries). The new Nov 8 out-of-zone event below changes the replacement assessment.
- **2026-11-08:** a deeper `dmesg`/journal audit found **40 historical I/O errors outside the original zone** (8 on sda, 32 on sdb), all from the Oct 17–18 repair pass. A full `pg_amcheck` later that day hit **6 new UNC read errors on sdb** at disk LBA `2,592,117,136/144` (inside the documented `2,592,11x` cluster). md3 corrected them from sda, the DB check passed with no logical corruption, and a direct 10 MB re-read of the cluster was clean. The new event is still a replacement trigger. See [§4.1](#41-additional-out-of-zone-error-clusters-oct-2026).
- **2026-11-08:** Baby Cam notifications stopped because Protect's PostgreSQL `cameras_pkey` index was corrupted. The index was rebuilt and the scheduler re-armed; notifications are flowing again. See [§4.2](#42-protect-database-index-corruption-nov-2026).
- **Replacement should now be planned on evidence.** The Nov 8 out-of-zone event meets the runbook's replacement trigger, but the array is still `[UU]`, there is no data loss, and no emergency action is required. Watch monthly with `scripts/unvr-health-check.sh`; replacement triggers are in [§6](#6-watch-plan--replacement-triggers).

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

## 4. Current State Snapshot (2026-11-08)

| Check | sda | sdb |
|---|---|---|
| SMART overall | PASSED | PASSED |
| `Current_Pending_Sector` | **0** | ~12 (wobbling; retry-marginal zone sectors) |
| `Reallocated_Sector_Ct` | **0** | **0** |
| `UDMA_CRC_Error_Count` | 0 | 0 |
| Last self-test | Short, passed (2026-11-08) | Short, passed (2026-11-08) |
| Power-on hours | ~18,783 | ~18,781 |

- Array: `md3 [UU]`, `degraded: 0`, `sync_action: idle`, `mismatch_cnt ≈ 60648` (informational — live-array write races during scrubs; ignore).
- md badblock lists: **empty** on both legs.
- Known marginal zone: disk LBA ≈ **1,761,873,904 – 1,762,355,688** (~902.1–902.3 GB offset; 1 MB blocks **860,270–860,545**). Marginal sdb sectors observed: `1761874072`, `1761874376`, `1762331336` — reads need retries but succeed.
- Additional out-of-zone error clusters: the 40 historical errors from Oct 17 were re-read OK on 2026-11-08, but the full DB scan that day triggered **6 new UNC errors on sdb** in the `2,592,11x` cluster. md3 corrected them from sda. See [§4.1](#41-additional-out-of-zone-error-clusters-oct-2026).
- Protect DB: `cameras_pkey` rebuilt on 2026-11-08; a full `pg_amcheck --heapallindexed` passed in **1m22s** (no logical DB corruption), despite the sdb media errors above. Critical notification-path indexes are clean. See [§4.2](#42-protect-database-index-corruption-nov-2026).
- UI: verify the console storage page after the Nov 8 new-error event; `usd` had no warnings in the 24h before the event.

### 4.1 Additional out-of-zone error clusters (Oct 2026)

The original incident was documented as damage confined to the ~250 MB zone above. A full audit of the boot's `dmesg` on 2026-11-08 found **40 historical `print_req_error` entries outside that zone** (8 on sda, 32 on sdb), all from the Oct 17–18 repair/scrub:

| Drive | Outside-zone errors | Approximate disk LBA clusters |
|---|---:|---|
| sda | 8 | 1,762,375,760; 1,762,401,472; 1,762,423,568; 1,774,456,760; 1,778,709,080; 2,592,128,528; 3,961,725,248; 4,752,411,008 |
| sdb | 32 | 1,762,359,792–1,762,420,080; 1,774,457,056–1,774,530,504; 2,592,113,192–2,592,128,944; 4,504,950,912–4,504,951,040; 7,642,284,544–7,646,478,208 |

- Last historical error: **2026-10-18 08:03:18**, sdb sector `1762331336` (inside the known zone).
- The 40 historical out-of-zone 4K blocks were re-read from both raw disks on 2026-11-08: **all READ OK**.
- No new `print_req_error` between 2026-10-18 and 2026-11-08 15:57; both drives still show `Reallocated_Sector_Ct = 0`, and the 2026-11-08 short SMART self-tests passed.

**2026-11-08 update — new out-of-zone errors.** A full `pg_amcheck --heapallindexed` run (82s) hit six new UNC read errors on sdb between **15:57:59 and 15:58:30** (three visible in `dmesg`, three more in `journalctl -k`), at disk LBA `2,592,117,136` and `2,592,117,144` — inside the previously documented sdb `2,592,113,192–2,592,128,944` cluster:

- md3 logged `read error corrected` / `redirecting sector ... to other mirror: sda5` for each; `pg_amcheck` still passed with no logical corruption.
- A direct 10 MB re-read of that cluster on sdb (`iflag=direct`) produced **0 new errors**; the sectors are currently readable.
- `mdadm --examine-badblocks` remained empty; array `[UU]`; SMART pending still 12, reallocated 0; short self-tests passed.
- This is a **new error after the Oct 18 cutoff** and therefore meets replacement trigger #2 ([§6](#6-watch-plan--replacement-triggers)). Plan replacement; do not treat the drive as fully healed.
- Optional temporary heal: rewrite the two 4K blocks from the sda mirror using the single-sector playbook in [§7](#7-appendices) (`L=2592117136` and `L=2592117144`, `X=sdb`, `Y=sda`). This may force the drive to remap them, but it does **not** change the replacement recommendation.

### 4.2 Protect database index corruption (Nov 2026)

**Symptom:** Baby Cam stopped sending notifications while other cameras (Driveway, Front Door) continued normally.

**Diagnosis:**
- Protect's PostgreSQL DB is `/srv/postgresql/14/protect` (port **5433**, database `unifi-protect`).
- `errors.log` showed repeated `insert or update on table "events" violates foreign key constraint "events_cameraId_fkey"` for the Baby Cam camera ID.
- `cameras.lastSeen` was stuck at 2026-11-05 10:22 UTC, and the recording scheduler never toggled the camera out of `"never"` after a Protect restart.
- The heap row existed, but a primary-key lookup returned 0 rows. `bt_index_check('cameras_pkey', true)` reported:
  `heap tuple ... from table "cameras" lacks matching index tuple within index "cameras_pkey"`.

**Cause:** corrupted btree primary-key index (`cameras_pkey`) in the Protect DB, consistent with the Oct storage incident. Event inserts failed the FK check, and updates by camera id silently affected 0 rows.

**Fix (2026-11-08):**

```bash
sudo -u postgres psql -p 5433 -d unifi-protect \
  -c "REINDEX INDEX CONCURRENTLY public.cameras_pkey;"
sudo systemctl restart unifi-protect   # re-arm the scheduler
```

**Verification:**

```bash
sudo -u postgres psql -p 5433 -d unifi-protect \
  -c "select bt_index_check('cameras_pkey'::regclass, true);"
sudo -u postgres psql -p 5433 -d unifi-protect \
  -c "set enable_seqscan=off; select id,\"name\" from cameras where id='66e77b7f02780d03e70003eb';"
```

- After the rebuild: `lastSeen` updates every ~10s, the scheduler set Baby Cam to `always` inside its recording window, a motion event saved, and the push notification was sent successfully.
- No new `events_cameraId_fkey` errors after the repair.
- Use `scripts/unvr-health-check.sh --db` (or the `pg_amcheck` one-liner in [§7](#7-appendices)) for periodic index checks. The nightly Protect DB backups are **partial** dumps stored on the same array, so they are not a substitute for integrity checks.

---

## 5. Monitoring

Run the health check (see `scripts/unvr-health-check.sh`):

```bash
scripts/unvr-health-check.sh            # fast (~10 s)
scripts/unvr-health-check.sh --deep     # + sweeps the known damage zone (~1-3 min)
scripts/unvr-health-check.sh --db       # + pg_amcheck cameras/users/events (~1-3 min)
scripts/unvr-health-check.sh --all      # fast + deep + db
```

Cadence: **monthly**, or after any Protect storage alert. Exit codes: `0` clean, `2` **new** out-of-zone I/O warning, `1` command/DB-check failure.

What the fast check reports: array state, per-drive pending/reallocated/CRC/self-test, md badblock lists, recent kernel I/O errors (historical out-of-zone counts plus a separate **new since 2026-10-18** count), recent `usd` warnings. It exits `2` only for **new** out-of-zone errors; the documented historical ones are informational.

Caveats:
- `dmesg` shows errors since last boot and its ring buffer can rotate out older entries. The fast check uses `journalctl -k` for the “new since 2026-10-18” comparison; the cutoff is hardcoded in `scripts/unvr-health-check.sh`. Bump it after a documented repair so historical errors stop paging as new. `journalctl -u usd` covers the longer window.
- The fast and `--deep` checks do **not** inspect PostgreSQL indexes. Use `--db` (cameras/users/events) or run `pg_amcheck` directly for the full DB. `--db` is read-only but takes `ShareLock`s on the checked tables, so run it during a quiet window. Measured on 2026-11-08: `--db` **36s**; full-DB `pg_amcheck --heapallindexed` **82s**.
- Extended SMART self-tests **starve under recording load** (offline collection suspends on host I/O) — they can take days and get aborted. Short tests are fine. Prefer `--deep` sweeps over extended tests for surface checks.
- An `smartctl -t offline` scan also makes slow progress but never logs LBAs to the host.

---

## 6. Watch Plan & Replacement Triggers

**Short-term operation is fine** while pending stays in the low double digits (or lower), reallocated stays 0, and no *additional* errors appear. However, the 2026-11-08 new out-of-zone event already meets trigger #2 below, so replacement should now be planned.

**Plan replacement** when any of these appear:
1. `Reallocated_Sector_Ct` starts climbing (drive burning spare sectors = real media death).
2. **New** `print_req_error` entries appear **outside** the known zone or the documented repaired clusters in [§4.1](#41-additional-out-of-zone-error-clusters-oct-2026).
3. Pending grows well beyond the zone's population, or a drive drops from the array (`[UU]` → `[U_]`).

The historical out-of-zone errors from Oct 17 are documented in §4.1 and were re-read clean on 2026-11-08. The **2026-11-08 pg_amcheck event is a new out-of-zone error** and meets trigger #2; do not wait for another failure.

When replacing: RAID1 = pull the bad drive, insert new (same size or larger), let Protect/md rebuild. With this volume at 99% and both drives same-batch, expect to eventually replace **both**. The Nov 8 event is sufficient evidence to start planning, even though there is no emergency today.

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
ssh unvr 'journalctl -k --since "2026-10-18 08:04:00" --no-pager | grep print_req_error'  # NEW I/O errors since repair
ssh unvr 'journalctl -u usd --since "24 hours ago" | grep -i warning'  # usd health warnings
ssh unvr 'mdadm --examine-badblocks /dev/sda5; mdadm --examine-badblocks /dev/sdb5'
ssh unvr "sudo -u postgres psql -p 5433 -d unifi-protect -c \"select bt_index_check('cameras_pkey'::regclass, true);\""  # DB index check
ssh unvr 'sudo -u postgres /usr/lib/postgresql/14/bin/pg_amcheck -p 5433 -d unifi-protect --heapallindexed --table=cameras --table=users --table=events'  # critical DB check
ssh unvr 'sudo -u postgres /usr/lib/postgresql/14/bin/pg_amcheck -p 5433 -d unifi-protect --heapallindexed'  # full DB (~82s)
ssh unvr 'grep -a events_cameraId_fkey /srv/unifi-protect/logs/errors.log | tail'  # event FK failures
```
