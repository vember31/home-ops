# k3s AppArmor Signal Stacking Runbook

Context for the October 2026 worker-node incident where Blocky, CrowdSec AppSec, and the PostgreSQL replica stalled on Ubuntu 26.04 workers. This documents the diagnosis, the temporary node-level fix, verification, and removal once upstream contains the fix.

**Last updated:** 2026-10-29
**Incident:** `blocky` CrashLoopBackOff, `crowdsec-appsec` startup hang, `postgres-18-1` replica recovery stall.

---

## TL;DR

- Ubuntu 26.04 workers (kernel 6.17+) use AppArmor profile stacking. The kernel reports the peer name as `cri-containerd.apparmor.d//&unconfined`, but containerd's default `cri-containerd.apparmor.d` profile only allows signals to `peer=cri-containerd.apparmor.d`.
- As a result, ordinary signals are denied:
  - Go runtime `SIGURG` → Go processes spin in `sched_yield` instead of starting.
  - `rsync` `SIGUSR2` → CrowdSec's config copy hangs.
- Fixed on 2026-10-29 by installing a corrected `cri-containerd.apparmor.d` in `/etc/apparmor.d` on `k3s-worker1/2/3` and reloading it with `apparmor_parser`.
- **This is a temporary workaround.** It overrides containerd's built-in profile. Remove it after upgrading to a k3s/containerd version that includes the upstream fix, then reboot the node. See [Removal](#removal-when-upstream-is-fixed).
- Control-plane nodes are Ubuntu 24.04 and do not currently need it. New or upgraded Ubuntu 26.04 nodes do.

---

## 1. Symptoms

- Pods on worker nodes stuck in `CrashLoopBackOff`, or `Running` but never ready.
- Logs stop early:
  - Blocky prints its version banner, then never opens port 53. Liveness probe fails with `connection refused`.
  - CrowdSec AppSec prints the hub file listing, then hangs in `rsync`.
- `dmesg` on the node shows denied signals:

```text
apparmor="DENIED" operation="signal" class="signal" profile="cri-containerd.apparmor.d" \
  ... signal=urg peer="cri-containerd.apparmor.d//&unconfined"
```

  For CrowdSec's `rsync`, the signal is `usr2`. Other Go helpers may show `urg` as well.

- The process may look alive but is not doing useful work. Check syscall time and syscalls:

```bash
ps -o pid,stat,etime,time,wchan:32,comm -p <pid>
strace -f -c -p <pid>
```

  A profile-affected Go process typically shows almost all time in `sched_yield` (tens of thousands of calls per second) and no network/file progress.

- PostgreSQL replicas can also stall at `waiting for 0000004F...` because the CNPG instance manager cannot signal the postmaster to start streaming.

---

## 2. Root cause

containerd's default AppArmor template contains:

```text
signal (send,receive) peer={{.Name}},
```

which renders as `peer=cri-containerd.apparmor.d`. On kernels with AppArmor profile stacking, the actual peer name includes the stack suffix:

```text
cri-containerd.apparmor.d//&unconfined
```

The rule no longer matches, so AppArmor denies signals between processes in the same container. This affects all processes in the container, not only Go:

- Go runtime uses `SIGURG` for asynchronous goroutine preemption.
- `rsync` uses `SIGUSR2` between its worker processes.
- The CNPG instance manager uses signals to coordinate with PostgreSQL.

Upstream tracking:

- [k3s-io/k3s#13625](https://github.com/k3s-io/k3s/issues/13625)
- [containerd/containerd#12886](https://github.com/containerd/containerd/issues/12886)

The containerd issue was still open with no fix ETA as of 2026-10-29, which is why this workaround exists.

---

## 3. Detection

Run on the affected node:

```bash
cat /sys/kernel/security/apparmor/features/domain/stack
# "yes" means profile stacking is enabled and this workaround may be required.

dmesg -T | grep 'apparmor="DENIED".*operation="signal"'
```

Check whether the installed k3s/containerd already contains the stacked-peer rule:

```bash
strings /var/lib/rancher/k3s/data/current/bin/k3s \
  | grep -E 'peer=\{\{\.Name\}\}//|cri-containerd\.apparmor\.d//'
```

- No output: the installed binary still has the unstacked rule; apply the workaround.
- Output showing `//` in the peer: upstream may already include the fix; verify before applying/removing.

---

## 4. Fix

From a checkout of this repo on the node:

```bash
git clone https://github.com/vember31/home-ops /tmp/home-ops
sudo /tmp/home-ops/scripts/install-cri-containerd-apparmor-workaround.sh
```

The script:

- refuses to run unless it is root and AppArmor profile stacking is enabled;
- skips installation if the k3s binary already references stacked peer names;
- validates the profile with `apparmor_parser -N -K -T`;
- installs `configs/apparmor/cri-containerd.apparmor.d` to `/etc/apparmor.d/`;
- reloads it with `apparmor_parser -r`.

Manual equivalent:

```bash
sudo install -Dm644 \
  configs/apparmor/cri-containerd.apparmor.d \
  /etc/apparmor.d/cri-containerd.apparmor.d
sudo apparmor_parser -r /etc/apparmor.d/cri-containerd.apparmor.d
```

### Restart affected workloads

The profile reload applies to new signal attempts, but a process already spinning in `sched_yield` generally will not recover. Restart the affected workloads after applying the profile:

```bash
kubectl -n networking rollout restart ds/blocky
kubectl -n security rollout restart deploy/crowdsec-appsec
```

For CloudNativePG, restart **only the stuck replica**, never the primary:

```bash
kubectl -n database get pods -o wide | grep postgres
kubectl -n database delete pod postgres-18-1
```

Only do this once the WAL segments it needs are available in the archive. If the replica is stuck waiting for a segment that has not been archived yet, wait for the next archive cycle first (the primary archives every 5 minutes by default).

### Do not leave per-pod `unconfined` annotations

During the incident, Blocky and CrowdSec AppSec were temporarily run with:

```yaml
container.apparmor.security.beta.kubernetes.io/<container>: unconfined
```

Those annotations were removed after the node-level profile fix was verified. They weaken the sandbox and should not be kept as a permanent workaround.

---

## 5. Verification

```bash
# Profile is loaded
aa-status | grep cri-containerd

# No new signal denials after the reload
dmesg -T | grep 'apparmor="DENIED".*operation="signal"' | tail

# Workloads
kubectl -n networking get ds blocky
kubectl -n security get pods -l type=appsec
kubectl -n database get cluster postgres-18

# End-to-end DNS from a worker
kubectl run dnstest --rm -i --restart=Never --image=busybox:1.36 \
  --overrides='{"spec":{"nodeName":"k3s-worker1"}}' \
  -- nslookup github.com
```

Expected after the fix:

- Blocky `8/8` ready (on the current 8-node cluster).
- CrowdSec AppSec `1/1` ready.
- `postgres-18` cluster `Ready=True`, all instances `2/2` and streaming.
- No new `signal=urg` / `signal=usr2` denials.

---

## Removal when upstream is fixed

The workaround is a full replacement profile in `/etc/apparmor.d`. Ubuntu's `apparmor.service` loads it before k3s, and containerd only loads its built-in default profile if a profile with that name is not already loaded. **If the file is left in place, it will keep overriding containerd's profile and mask the upstream fix.**

When a k3s/containerd upgrade includes the stacked-peer rule:

1. Confirm the new binary contains the fix:

   ```bash
   strings /var/lib/rancher/k3s/data/current/bin/k3s \
     | grep -E 'peer=\{\{\.Name\}\}//|cri-containerd\.apparmor\.d//'
   ```

   Also check the containerd release notes and [containerd#12886](https://github.com/containerd/containerd/issues/12886).

2. Remove the profile and reboot the node:

   ```bash
   sudo /tmp/home-ops/scripts/install-cri-containerd-apparmor-workaround.sh --uninstall
   sudo reboot
   ```

   A reboot is required. Restarting k3s alone is not enough: the old profile is still loaded in the kernel, so containerd will see the name as loaded and skip its own profile.

3. After the reboot, verify:

   ```bash
   aa-status | grep cri-containerd
   dmesg -T | grep 'apparmor="DENIED".*operation="signal"'
   kubectl get pods -A | grep -E 'CrashLoop|Error|Pending'
   ```

4. Remove the workaround from `kubernetes/bootstrap/README.md`, `scripts/install-cri-containerd-apparmor-workaround.sh`, and `configs/apparmor/cri-containerd.apparmor.d` once every node is on the fixed version.

The k3s plans in `kubernetes/apps/infrastructure/system-upgrade-controller/plans/` are version-pinned and updated by Renovate. Add this check to the k3s upgrade PR/runbook so the workaround is not left behind indefinitely.

---

## 6. Incident notes (2026-10-29)

| Component | Symptom | Resolution |
|---|---|---|
| `blocky` (DaemonSet) | 3 worker pods CrashLoopBackOff; Go spun in `sched_yield`; port 53 never opened | Node profile fix + rollout |
| `crowdsec-appsec` | Startup hung in `rsync`; `signal=usr2` denied | Node profile fix + deployment rollout |
| `postgres-18-1` (replica) | Stuck at `waiting for 0000004F00000111000000E8`; WAL not yet archived | Waited for archive, then deleted only the replica pod; it restored and began streaming |

Affected nodes:

| Nodes | OS | Kernel | Status |
|---|---|---|---|
| `k3s-worker1/2/3` | Ubuntu 26.04.1 LTS | 7.0.0-42-generic | Profile installed 2026-10-29 |
| `k3s-control1/2/3/4/5` | Ubuntu 24.04.5 LTS | 6.8.0-147-generic | Not affected at time of writing |

If a control-plane node is upgraded to Ubuntu 26.04/kernel 6.17+, run the installer there too before restarting k3s workloads.

---

## References

- [k3s-io/k3s#13625 — AppArmor signal DENIED for SIGURG on kernel 6.17 with profile stacking](https://github.com/k3s-io/k3s/issues/13625)
- [containerd/containerd#12886 — AppArmor: signal rule does not match stacked profile peer on kernel 6.17](https://github.com/containerd/containerd/issues/12886)
- containerd default profile source: `contrib/apparmor/template.go` (v2.3.4)
