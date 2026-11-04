# GPU Worker and Control-Plane Layout Runbook

Context for the iGPU passthrough work, the rebuilt GPU worker, and the completed reduction to three control-plane nodes (with `control2` repurposed as `k3s-worker4`).

**Last updated:** 2026-11-04
**Author:** GPU/control-plane work was performed interactively (OpenCode session); this doc rebuilds that context.

---

## TL;DR

- The GPU worker is working. It is **VM 405 on `pve4`**, rebuilt clean as **`k3s-gpu-worker`** (q35 + OVMF, 8 vCPU, 16 GiB RAM, 128 GiB disk).
- The Intel iGPU (`0000:00:02.0`, `8086:46a3`) is passed through with:

  ```text
  hostpci0: 0000:00:02.0
  ```

  **No `pcie=1`.** QEMU attaches it at `bus=pci.0,addr=0x10`.
- Guest verification: `/dev/dri/renderD128` exists and `vainfo` loads the Intel iHD driver with H.264/HEVC/VP9 encode/decode profiles.
- The old `k3s-control5` node and its etcd member were removed. CNPG and Longhorn were cleaned up.
- Longhorn is enabled on all eight nodes, including `k3s-gpu-worker`; the stale `k3s-control2` Longhorn node was removed.
- **Current cluster shape:** **3 control planes + 5 workers.**
- Controls: `k3s-control1` (`pve`), `k3s-control3` (`pve2`), `k3s-control4` (`pve3`).
- `k3s-control2` was removed from etcd, renamed, and rebuilt in place as worker **`k3s-worker4`** (VM 402 on `pve`, same IP `192.168.2.12`). Both the Proxmox VM name and the guest hostname were changed.
- Reason: the old layout had `k3s-control1` and `k3s-control2` both on Proxmox host `pve`. With 3 controls that include both, losing `pve` would leave only 1/3 control planes and lose quorum. With 3 controls on three different Proxmox hosts (`pve`, `pve2`, `pve3`), losing one host still leaves 2/3 and quorum.

---

## Current node / VM / Proxmox mapping

| K3s node | IP | Proxmox host | VMID | Role | Notes |
|---|---|---:|---:|---|---|
| `k3s-control1` | 192.168.2.11 | `pve` (192.168.2.3) | 401 | control-plane, etcd | |
| `k3s-control3` | 192.168.2.13 | `pve2` (192.168.2.10) | 403 | control-plane, etcd | |
| `k3s-control4` | 192.168.2.14 | `pve3` (192.168.2.2) | 404 | control-plane, etcd | |
| `k3s-gpu-worker` | 192.168.2.15 | `pve4` (192.168.2.18) | 405 | worker | Intel iGPU passthrough |
| `k3s-worker1` | 192.168.2.51 | `pve5` (192.168.2.20) | 100 | worker | |
| `k3s-worker2` | 192.168.2.52 | `pve6` (192.168.2.21) | 101 | worker | |
| `k3s-worker3` | 192.168.2.53 | `pve7` (192.168.2.22) | 102 | worker | |
| `k3s-worker4` | 192.168.2.12 | `pve` (192.168.2.3) | 402 | worker | repurposed from `k3s-control2`; VM/guest renamed |

`pve4` currently runs only VM 405.

---

## Proxmox host `pve4` — GPU host configuration

Hardware/OS:

- Intel i7-12650H, 23 GiB RAM
- Proxmox `9.2.24`, kernel `7.0.14-26-pve`
- iGPU: `00:02.0`, Intel Alder Lake-P GT1 UHD Graphics, ID `8086:46a3`
- IOMMU group 0 contains only the iGPU
- The host loses `/dev/dri` once the iGPU is bound to `vfio-pci`

Host files:

```text
# /etc/default/grub
GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt initcall_blacklist=sysfb_init"
```

```text
# /etc/modules and /etc/modules-load.d/vfio.conf
vfio
vfio_iommu_type1
vfio_pci
```

```text
# /etc/modprobe.d/vfio.conf
options vfio-pci ids=8086:46a3
softdep i915 pre: vfio-pci
softdep xe pre: vfio-pci
```

```text
# /etc/modprobe.d/blacklist-intel-gpu.conf
blacklist i915
blacklist xe
```

Then:

```bash
update-initramfs -u -k all
update-grub
reboot
```

Verify:

```bash
lspci -nnk -s 00:02.0
# Kernel driver in use: vfio-pci
```

`pve4` uses GRUB (UEFI boot), not systemd-boot. `proxmox-boot-tool` is not configured.

---

## GPU worker VM 405

Proxmox config:

```text
bios: ovmf
machine: q35
efidisk0: local-lvm:vm-405-disk-0,efitype=4m,pre-enrolled-keys=0,size=4M
scsi0: local-lvm:vm-405-disk-1,size=128G
ide2: local-lvm:vm-405-cloudinit,media=cdrom
boot: order=scsi0
cores: 8
memory: 16384
balloon: 8192
hostpci0: 0000:00:02.0
onboot: 1
net0: virtio,bridge=vmbr0,firewall=1
```

The disk was expanded online from 32 GiB to 128 GiB on 2026-11-04, since the
node also runs normal workloads and Longhorn replicas:

```bash
qm resize 405 scsi0 128G
# In the guest:
echo 1 > /sys/class/block/sda/device/rescan
growpart /dev/sda 1
resize2fs /dev/sda1
```

No reboot was required. The root filesystem grew to 123 GiB usable, and
Longhorn automatically picked up the new capacity (~108 GiB available).

`qm showcmd 405 --pretty` must show:

```text
-device 'vfio-pci,host=0000:00:02.0,id=hostpci0,bus=pci.0,addr=0x10'
```

That `bus=pci.0` attachment is the configuration that worked. Do **not** use `pcie=1` on this VM/host.

### Guest OS

- Ubuntu 24.04 cloud image, clean q35/OVMF install
- Static IP `192.168.2.15/24`, gateway `192.168.2.1`
- Interface **must be named `ens18`**, because Cilium is configured with `devices: [ens18]`

The cloud-init netplan was replaced with:

```yaml
network:
  version: 2
  ethernets:
    primary:
      match:
        macaddress: "bc:24:11:4b:84:16"
      set-name: ens18
      addresses:
        - "192.168.2.15/24"
      nameservers:
        addresses:
          - 192.168.10.22
          - 192.168.2.4
        search:
          - local.vember31.xyz
      routes:
        - to: "default"
          via: "192.168.2.1"
```

Also present:

```text
# /etc/systemd/network/10-ens18.link
[Match]
MACAddress=bc:24:11:4b:84:16

[Link]
Name=ens18
```

Cloud-init network rewriting is disabled:

```text
# /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
network: {config: disabled}
```

Adjust the MAC if VM 405 is ever recreated.

#### Login user (`duke`)

The original cloud-init user was `ubuntu`. On 2026-11-04 the VM was changed to use
`duke` instead:

- Proxmox `ciuser` is now `duke`, and the cloud-init `sshkeys` field contains only
  the workstation's `id_ed25519.pub` and `id_rsa.pub`.
- `duke` was created with UID/GID 1001, home `/home/duke`, shell `/bin/bash`, and
  the same password hash as `duke` on `k3s-control1`. It is in
  `sudo,adm,cdrom,dip,plugdev,lxd,video,render`.
- `ubuntu` remains as UID 1000 because container workloads run as that UID, but
  login is disabled: its shell is `/usr/sbin/nologin`, its password is locked, it
  was removed from `sudo`, and its `authorized_keys` and cloud-init sudoers rule
  were renamed with a `.disabled-*` suffix.

To verify SSH access to all nodes after a rebuild, run:

```bash
./scripts/fix-node-ssh-keys.sh --dry-run
./scripts/fix-node-ssh-keys.sh
```

See [node-ssh-access.md](node-ssh-access.md) for the node/user/VM mapping and
options.

### Guest packages / firmware

```bash
sudo apt-get update
sudo apt-get install -y \
  linux-modules-extra-$(uname -r) \
  linux-firmware \
  intel-media-va-driver-non-free \
  vainfo \
  intel-gpu-tools \
  qemu-guest-agent
```

**Important:** Ubuntu ships the Alder Lake GuC firmware compressed as `adlp_guc_70.bin.zst`. The cloud kernel in this VM could not load it, so i915 declared the GPU wedged. The uncompressed file is required:

```bash
sudo curl -fsSL \
  -o /lib/firmware/i915/adlp_guc_70.bin \
  https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/i915/adlp_guc_70.bin
```

### Verification

```bash
lspci -nnk -s 06:10.0
# Kernel driver in use: i915

ls -l /dev/dri
# card0, card1, renderD128

sudo LIBVA_DRIVER_NAME=iHD vainfo \
  --display drm --device /dev/dri/renderD128
```

Expected: Intel iHD driver, and H.264/HEVC/VP9 encode/decode profiles.

The dmesg line `Cannot find any crtc or sizes` is normal for a headless secondary GPU.

### Updating the GPU worker

The worker runs **Ubuntu 24.04.5 LTS** with the normal `linux-virtual` meta packages. Guest updates are safe; the Proxmox-side `hostpci0`, q35/OVMF, and `onboot` settings are unaffected.

Kernel updates:

- `linux-virtual` → `linux-image-virtual` → `linux-image-<version>-generic` → `linux-modules-extra-<version>-generic`.
- i915 lives in `linux-modules-extra`, so a new kernel should pull the matching module package automatically.
- The current `linux-modules-extra-6.8.0-147-generic` is installed.

Before updating:

- If Silo transcodes are running, cordon/drain the worker or wait for a quiet window:

  ```bash
  kubectl cordon k3s-gpu-worker
  kubectl drain k3s-gpu-worker --ignore-daemonsets --delete-emptydir-data
  ```

- `unattended-upgrades` is enabled and **kured may reboot the node automatically** after a kernel update. Plan around active streams.
- Optionally take a Proxmox backup first. Do not rely on a long-lived LVM snapshot; `local-lvm` free space is limited.

Update:

```bash
sudo apt-get update
sudo apt-get full-upgrade -y
sudo reboot
```

After reboot:

```bash
lspci -nnk -s 06:10.0
ls -l /dev/dri/renderD128
ls -l /lib/firmware/i915/adlp_guc_70.bin
sudo dmesg | grep -iE 'GuC|HuC|i915'
sudo LIBVA_DRIVER_NAME=iHD vainfo \
  --display drm --device /dev/dri/renderD128
```

Then uncordon:

```bash
kubectl uncordon k3s-gpu-worker
```

If `/dev/dri` is missing after an update:

```bash
sudo apt-get install -y linux-modules-extra-$(uname -r)
sudo curl -fsSL \
  -o /lib/firmware/i915/adlp_guc_70.bin \
  https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/i915/adlp_guc_70.bin
sudo reboot
```

Do **not** run `cloud-init clean` or re-enable cloud-init networking; the custom `ens18` netplan/udev setup must persist.

### K3s worker join

The node is a **worker**, not a control plane:

```bash
curl -sfL https://get.k3s.io | \
  sudo env \
    INSTALL_K3S_VERSION=v1.37.1+k3s1 \
    K3S_URL=https://192.168.10.100:6443 \
    K3S_TOKEN='<token from a server>' \
    INSTALL_K3S_EXEC='agent --node-ip=192.168.2.15' \
    sh -
```

The token is in `/var/lib/rancher/k3s/server/token` on a server. Do not commit it.

Labels / Longhorn:

```bash
kubectl label node k3s-gpu-worker media/gpu=intel --overwrite
kubectl annotate node k3s-gpu-worker node.longhorn.io/create-default-disk=false --overwrite
# If/when the Longhorn node CR appears:
kubectl -n storage patch nodes.longhorn.io k3s-gpu-worker \
  --type merge -p '{"spec":{"allowScheduling":false}}'
```

---

## What went wrong with the old `control5` — and what not to repeat

The original `k3s-control5` was an in-place conversion from BIOS/i440fx to q35/OVMF on an existing Ubuntu install.

Problems encountered:

1. **BIOS → UEFI in place is not a flag flip.** The VM had no ESP. An ESP was added as a second disk and GRUB EFI was installed manually.
2. **GRUB core prefix / config discovery failed.** `normal` re-entered the ESP config and produced `maximum recursion depth exceeded`. This was eventually worked around with a standalone EFI image that embedded a dynamic `configfile` pointer to `/boot/grub/grub.cfg`.
3. **The iGPU wedged the whole Proxmox host.** `pve4` became unreachable at the userspace level (ping and corosync up, SSH banner timeout, pveproxy hangs) when the GPU was attached to the old `control5` VM.
4. **The old VM attached the iGPU through `bus=ich9-pcie-port-1`**, not `bus=pci.0`. The disposable test VM and the clean rebuilt VM both used `bus=pci.0,addr=0x10` and worked.
5. **`pcie=1` was not the fix.** It was tried and is suspected to be part of the failure path.
6. **The old `control5` VM had a complex PCI topology** (second ESP disk, multiple virtio-scsi controllers, Longhorn disks). The clean single-disk VM does not have that problem.

Lessons:

- Do not do an in-place BIOS → UEFI conversion on a production control-plane VM if a clean rebuild is acceptable.
- Do not keep retrying GPU passthrough on an existing VM that wedges the host. Test on a disposable q35/OVMF VM first.
- For headless VA-API, do **not** copy display-passthrough guides directly. `vga: none`, `x-vga=1`, GOP ROM files, and `x-igd-opregion` are for HDMI/display output, not VA-API.
- The working configuration is the minimal one: q35/OVMF, single disk, `hostpci0: 0000:00:02.0` without `pcie=1`, `bus=pci.0`.

---

## Recovery if `pve4` wedges again

Symptoms:

```bash
ping 192.168.2.18            # works
nc -z 192.168.2.18 22        # opens, but SSH banner times out
pvesh get /nodes/pve4/status # hangs
corosync-cfgtool -n          # pve4 still reachable
```

The host userspace is wedged and needs a **physical hard reboot**. There is no IPMI/smart plug exposed in Home Assistant.

Before rebooting, make the VM safe from another Proxmox node:

```bash
# On pve3 (192.168.2.2), edit pve4's VM config:
cp -a /etc/pve/nodes/pve4/qemu-server/405.conf /root/405.conf.pre-recovery-$(date +%Y%m%d-%H%M%S)
sed -i '/^hostpci0:/d; /^args:/d' /etc/pve/nodes/pve4/qemu-server/405.conf
sed -i 's/^onboot: 1$/onboot: 0/' /etc/pve/nodes/pve4/qemu-server/405.conf
grep -E '^(hostpci0|args|onboot)' /etc/pve/nodes/pve4/qemu-server/405.conf || true
```

Then hard-reboot `pve4`. After it returns:

1. Verify `lspci -nnk -s 00:02.0` shows `vfio-pci`.
2. Start VM 405 without GPU first:

   ```bash
   qm start 405
   ```

3. Verify SSH, `ens18`, and `/dev/dri` only if the GPU config was restored.
4. Restore `onboot: 1` once stable.

If the host hangs with the GPU attached, remove `hostpci0`/`args` again and start without it. Do not keep rebooting blindly.

---

## Cleanup performed when replacing old `control5`

- etcd snapshot was taken on `control1`:

  ```bash
  k3s etcd-snapshot save --name pre-control5-rebuild-$(date +%Y%m%d-%H%M%S)
  ```

- `etcdctl` was installed on `control1` (`apt-get install etcd-client`) because K3s did not expose an etcdctl binary in its data dir.
- Stale etcd member `20ad5158a430442e` (`k3s-control5`) was removed.
- `kubectl delete node k3s-control5` was run.
- Old CNPG local-path instance `postgres-18-6` PVC/PV was deleted. CNPG created a replacement `postgres-18-2` on `k3s-worker3`.
- Stale Longhorn node `k3s-control5` was removed:
  - set `allowScheduling: false`
  - deleted the two stopped replica objects for already-detached `unknown` volumes
  - deleted the Longhorn node CR
- Longhorn ended at 24 healthy volumes and 3 detached/unknown volumes (pre-existing).

Do not delete `unknown` Longhorn volumes just to clean up. They are detached, not necessarily broken.

---

## Control-plane reduction: 3 controls + 5 workers (completed 2026-11-04)

**Result:** `k3s-control1`, `k3s-control3`, and `k3s-control4` are the three remaining control planes, one per Proxmox host. `k3s-control2` was removed from etcd and rebuilt in place as worker **`k3s-worker4`** (VM 402 on `pve`, IP `192.168.2.12`).

Why:

| Layout | Lose `pve` host | Quorum |
|---|---|---|
| 3 controls: control1 + control2 on `pve`, control3 on `pve2` | 1/3 left | lost |
| 4 controls: control1 + control2 on `pve`, control3, control4 | 2/4 left | lost (needs 3) |
| 5 controls: 5th on another host | 3/5 left | OK |
| 3 controls: control1 on `pve`, control3 on `pve2`, control4 on `pve3` | 2/3 left | OK |

Final layout:

- Controls:
  - `k3s-control1` → `pve`
  - `k3s-control3` → `pve2`
  - `k3s-control4` → `pve3`
- Workers:
  - `k3s-gpu-worker` (VM 405, `pve4`)
  - `k3s-worker1` (VM 100, `pve5`)
  - `k3s-worker2` (VM 101, `pve6`)
  - `k3s-worker3` (VM 102, `pve7`)
  - `k3s-worker4` (VM 402, `pve`; repurposed from `k3s-control2`)

### What was done

1. Took an etcd snapshot on `control1`:

   ```bash
   k3s etcd-snapshot save --name pre-control2-removal-$(date +%Y%m%d-%H%M%S)
   ```

2. Confirmed all four etcd members were healthy, then cordoned and drained `k3s-control2`. `kubectl drain` needs `--disable-eviction` here because Longhorn's per-node instance-manager PDBs have `disruptionsAllowed: 0`:

   ```bash
   kubectl cordon k3s-control2
   kubectl drain k3s-control2 \
     --ignore-daemonsets --delete-emptydir-data --force --disable-eviction
   ```

3. Stopped and disabled the K3s server on `control2`, then removed its etcd member from `control1` and deleted the node object:

   ```bash
   systemctl disable --now k3s   # on control2
   etcdctl ... member remove <control2-member-id>
   kubectl delete node k3s-control2
   ```

4. Renamed the guest and the Proxmox VM:

   ```bash
   hostnamectl set-hostname k3s-worker4   # on VM 402
   sed -i 's/127.0.1.1 k3s-control2/127.0.1.1 k3s-worker4/' /etc/hosts
   qm set 402 --name k3s-worker4          # on pve
   ```

5. Uninstalled the server role:

   ```bash
   /usr/local/bin/k3s-uninstall.sh
   ```

   This removes `/etc/rancher/k3s` and `/var/lib/rancher/k3s`, but **not** `/var/lib/longhorn`.

6. Preserved the old Longhorn data, then gave the new worker a clean disk:

   ```bash
   mv /var/lib/longhorn /var/lib/longhorn-old-control2-20261104
   mkdir -p /var/lib/longhorn
   ```

7. Reinstalled as an agent with the server token:

   ```bash
   curl -sfL https://get.k3s.io | \
     env INSTALL_K3S_VERSION=v1.37.1+k3s1 \
       K3S_URL=https://192.168.10.100:6443 \
       K3S_TOKEN="$(cat /root/.k3s-join-token)" \
       INSTALL_K3S_EXEC='agent --node-ip=192.168.2.12' \
       sh -
   ```

   The token was copied out of `/etc/rancher/k3s/config.yaml` before the uninstall, then deleted after the join.

8. Restored the node's zone label:

   ```bash
   kubectl label node k3s-worker4 topology.kubernetes.io/zone=proxmox-shared --overwrite
   ```

9. Applied the Longhorn node prerequisites to all eight VMs per `kubernetes/bootstrap/README.md`: ensured the Longhorn packages (`nfs-common`, `open-iscsi`, `multipath-tools`, `cryptsetup`, `dmsetup`) were present, enabled `iscsid`, loaded `dm_crypt`, configured the multipath blacklist, and added the QUIC sysctls. The Longhorn managers were restarted to refresh the environment checks.

10. Deleted the stale `k3s-control2` Longhorn node. Its only remaining replica belonged to the expendable `games/epicgames-config-v2` volume, so that PVC/PV and Longhorn volume were deleted first. The `epicgames` HelmRelease was then deleted and recreated by Flux, which reprovisioned the config PVC and recreated the CronJob/Service/Ingress.

### Gotchas

- **Longhorn last replica:** the detached/unknown volume `pvc-44230187-52f7-4640-aab2-f44e3ce8f731` (`games/epicgames-config-v2`) had its only replica on `control2`. It was declared expendable: the old `/var/lib/longhorn-old-control2-20261104` backup was deleted, and the bound PVC/PV and Longhorn volume were removed so the stale node could be deleted. The `epicgames` HelmRelease was then deleted and recreated by Flux, which provisioned a fresh `epicgames-config-v2` volume. The other two pre-existing `unknown` volumes were left untouched. As a general rule, don't delete an `unknown` volume just to clean up unless its data has been confirmed expendable.
- **Drain vs. Longhorn PDB:** a normal `kubectl drain` stalls on the Longhorn instance-manager PDB. Use `--disable-eviction` (and `--force`) for this node.
- **Stop before removing the etcd member:** stop/disable K3s on the departing node first, then remove the member from a remaining control plane. Otherwise the node can rejoin etcd.
- **Agent join via the VIP:** immediately after the control-plane removal, the agent's bootstrap through `https://192.168.10.100:6443` failed with repeated EOF/resets while the Cilium BGP endpoint state was settling. Bootstrapping via `https://192.168.2.11:6443` worked. After Cilium was running on `k3s-worker4` and the `kube-api` EndpointSlice contained only `control1/3/4`, switching the agent back to `https://192.168.10.100:6443` worked and the node stayed `Ready`. If it recurs, join direct first, then switch back to the VIP.
- **Cilium API-LB selector:** the `kube-api` service selects Cilium pods labeled `cilium-api-lb=true`. The init container applies that label only on nodes with `node-role.kubernetes.io/control-plane=true`. `k3s-worker4` correctly has no such label, so it is not an API endpoint. The BGP advertisement's `kubernetes.io/os: linux` node selector intentionally makes every Linux node advertise the VIP; it does not make workers control planes.
- **Cilium control-plane labeling (fixed 2026-11-04):** the `label-control-plane` init container adds the `cilium-api-lb=true` label to Cilium pods on control-plane nodes. That label is what gives the `kube-api` service its endpoints and keeps the `192.168.10.100` VIP alive. The init container must not depend on the VIP or ClusterIP it is helping to create.
  - **Root cause:** `kubectl --server=...` does not load the in-cluster service-account token/CA. Without a kubeconfig, kubectl fell back to prompting for a username and exited with `error: EOF`. The `127.0.0.1` address itself was a red herring; control-plane nodes do listen on `127.0.0.1:6443`.
  - **Fix:** the init container now gets `status.hostIP` via the Downward API and talks directly to `https://${HOST_IP}:6443`, passing the service-account CA and token explicitly. Workers skip the check because they have no local API server on 6443.
  - If a control-plane Cilium pod restarts on an older revision and loses the label, re-apply it manually:
    ```bash
    kubectl -n kube-system label pod <cilium-pod> cilium-api-lb=true --overwrite
    ```
- **Worker Cilium stuck after a reboot:** if a worker Cilium pod is stuck in its `config` init container with `no route to host` to the VIP, stale eBPF state can prevent it from reaching the API. A reboot clears the stale state. The `clean-cilium-state` init container cannot run until `config` succeeds, so the node cannot self-recover from that state.
- **VM naming:** `qm set 402 --name k3s-worker4` only changes the Proxmox VM name. The guest hostname is separate.

### Verification

```bash
kubectl get nodes -o wide
kubectl -n storage get nodes.longhorn.io
kubectl -n database get clusters.postgresql.cnpg.io postgres-18
```

Expected: three controls (`control1`, `control3`, `control4`), five workers (`gpu-worker`, `worker1`–`worker4`), all Ready; CNPG healthy; all Longhorn nodes Ready/Schedulable; Longhorn healthy except the two remaining pre-existing `unknown` volumes. The freshly recreated `epicgames-config-v2` volume is detached/`unknown` until its CronJob first attaches it. The `Multipathd` condition remains a warning by design while `multipathd` is running with the blacklist config.

The system-upgrade-controller `agent` plan targets nodes without the control-plane label, so it picked up `k3s-worker4` automatically. It was a no-op because the version already matched.

---

## Silo notes for the GPU worker

The GPU worker is ready to be the Silo transcode node:

- Pin the transcode workload to `k3s-gpu-worker` with `nodeSelector: media/gpu: intel`.
- Mount `/dev/dri` via `hostPath`.
- Add supplemental groups for `video` / `render`. Verified on 2026-11-04: **`44` (video) and `992` (render)**. The earlier `109` guess was wrong for this node.
- Use `MODE=transcode`.
- Share Postgres, Redis (`Dragonfly`), and `SECRET_KEY` with the main Silo server.
- Mount the same media path read-only.
- Set `SILO_STOP_GRACE_PERIOD=11m` for drain.
- Register the node in Silo at **Admin → Playback → Nodes** with matching `NODE_NAME` / `NODE_URL`. The prepared manifests use `gpu-worker` and `http://silo-transcode.media.svc.cluster.local:8080`.
- Keep the main Silo server integrated (or API) so CPU fallback still works if the GPU worker is down.

The manifests are in `kubernetes/apps/media/silo/` (prepared 2026-11-04; not
committed or deployed yet). The transcode scratch is a 10 GiB `emptyDir` for the
initial rollout; see the app README for the 4K/disk caveat.

Do **not** use `pcie=1` for this iGPU on `pve4`, and do not add display-passthrough flags (`x-vga`, ROM files, `vga: none`) for a headless VA-API worker.

---

## Open items

- [x] Reduce control planes to 3: `control1`, `control3`, `control4`.
- [x] Remove `control2` from etcd and repurpose VM 402 as `k3s-worker4`.
- [x] Apply Longhorn node prerequisites fleet-wide (`nfs-common`, `open-iscsi`, `iscsid` enabled, `dm_crypt`, multipath blacklist); Longhorn is enabled on all nodes, including `k3s-gpu-worker`.
- [x] Remove the stale Longhorn node `k3s-control2` after deleting the expendable `games/epicgames-config-v2` volume.
- [x] Test VM 405 reboot with the GPU attached (2026-11-04): `pve4` stayed responsive, the iGPU came back as `i915` with `/dev/dri/renderD128` and iHD `vainfo`, and the node returned `Ready`.
- [x] Make the Cilium `label-control-plane` init container robust using the node IP (`status.hostIP`) and verify a Cilium rollout in a maintenance window.
- [ ] Deploy Silo server + transcode worker; register the node in Silo.

The two remaining detached/`unknown` Longhorn volumes (`pvc-ab16c80b-cd4d-40a8-b165-1fb948b89243` / `media/kometa-config` and `pvc-bbbe2576-114f-4f5e-b31b-e32fc7a24e34` / `home/babybuddy-config`) are pre-existing and still bound to their PVCs; leave them alone unless their data is declared expendable.

**FYI:** if VM 405 is ever recreated, update the MAC in `10-ens18.link` / netplan. There is no action unless a rebuild happens.
