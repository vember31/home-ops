# GPU Worker and Control-Plane Layout Runbook

Context for the iGPU passthrough work, the rebuilt GPU worker, and the planned reduction to three control-plane nodes.

**Last updated:** 2026-11-04
**Author:** GPU/control-plane work was performed interactively (OpenCode session); this doc rebuilds that context.

---

## TL;DR

- The GPU worker is working. It is **VM 405 on `pve4`**, rebuilt clean as **`k3s-gpu-worker`** (q35 + OVMF, 8 vCPU, 16 GiB RAM, 32 GiB disk).
- The Intel iGPU (`0000:00:02.0`, `8086:46a3`) is passed through with:

  ```text
  hostpci0: 0000:00:02.0
  ```

  **No `pcie=1`.** QEMU attaches it at `bus=pci.0,addr=0x10`.
- Guest verification: `/dev/dri/renderD128` exists and `vainfo` loads the Intel iHD driver with H.264/HEVC/VP9 encode/decode profiles.
- The old `k3s-control5` node and its etcd member were removed. CNPG and Longhorn were cleaned up.
- **Current cluster shape:** 4 control planes + 4 workers.
- **Desired cluster shape:** **3 control planes** — `k3s-control1`, `k3s-control3`, `k3s-control4` — and **5 workers**. `k3s-control2` should be removed from etcd and repurposed as a worker.
- Reason: `k3s-control1` and `k3s-control2` are both on Proxmox host `pve`. With 3 controls that include both, losing `pve` would leave only 1/3 control planes and lose quorum. With 3 controls on three different Proxmox hosts (`pve`, `pve2`, `pve3`), losing one host still leaves 2/3 and quorum.

---

## Current node / VM / Proxmox mapping

| K3s node | IP | Proxmox host | VMID | Role | Notes |
|---|---|---:|---:|---|---|
| `k3s-control1` | 192.168.2.11 | `pve` (192.168.2.3) | 401 | control-plane, etcd | keep as control |
| `k3s-control2` | 192.168.2.12 | `pve` (192.168.2.3) | 402 | control-plane, etcd | **remove/repurpose** |
| `k3s-control3` | 192.168.2.13 | `pve2` (192.168.2.10) | 403 | control-plane, etcd | keep as control |
| `k3s-control4` | 192.168.2.14 | `pve3` (192.168.2.2) | 404 | control-plane, etcd | keep as control |
| `k3s-gpu-worker` | 192.168.2.15 | `pve4` (192.168.2.18) | 405 | worker | Intel iGPU passthrough |
| `k3s-worker1` | 192.168.2.51 | `pve5` (192.168.2.20) | 100 | worker | |
| `k3s-worker2` | 192.168.2.52 | `pve6` (192.168.2.21) | 101 | worker | |
| `k3s-worker3` | 192.168.2.53 | `pve7` (192.168.2.22) | 102 | worker | |

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
scsi0: local-lvm:vm-405-disk-1,size=32G
ide2: local-lvm:vm-405-cloudinit,media=cdrom
boot: order=scsi0
cores: 8
memory: 16384
balloon: 8192
hostpci0: 0000:00:02.0
onboot: 1
net0: virtio,bridge=vmbr0,firewall=1
```

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

## Planned control-plane reduction: 3 controls + 5 workers

**Decision:** keep `k3s-control1`, `k3s-control3`, and `k3s-control4` as the three control planes. Remove `k3s-control2` from etcd/control-plane duty and repurpose that VM as a worker.

Why:

| Layout | Lose `pve` host | Quorum |
|---|---|---|
| 3 controls: control1 + control2 on `pve`, control3 on `pve2` | 1/3 left | lost |
| 4 controls: control1 + control2 on `pve`, control3, control4 | 2/4 left | lost (needs 3) |
| 5 controls: 5th on another host | 3/5 left | OK |
| 3 controls: control1 on `pve`, control3 on `pve2`, control4 on `pve3` | 2/3 left | OK |

Target worker set:

- `k3s-worker1`
- `k3s-worker2`
- `k3s-worker3`
- `k3s-gpu-worker`
- the repurposed `control2` VM (or another worker)

### Recommended sequence

1. Take an etcd snapshot on a remaining control plane.
2. Remove `k3s-control2`’s etcd member and delete the node object.
3. Rebuild/repurpose VM 402 on `pve` as a clean worker (same VMID, no new VM), or leave it off until needed.
4. Join it as a worker; label it appropriately.
5. Verify three control planes are on three distinct Proxmox hosts:

   - `k3s-control1` → `pve`
   - `k3s-control3` → `pve2`
   - `k3s-control4` → `pve3`

6. Do not remove `control4` instead of `control2`; that would leave two controls on `pve` and recreate the same host-failure problem.

### Commands sketch

On a remaining control plane (e.g. `control1`):

```bash
k3s etcd-snapshot save --name pre-control2-removal-$(date +%Y%m%d-%H%M%S)

ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt \
  --cert=/var/lib/rancher/k3s/server/tls/etcd/client.crt \
  --key=/var/lib/rancher/k3s/server/tls/etcd/client.key \
  member list -w table
```

Remove the `k3s-control2` member by ID, then:

```bash
kubectl delete node k3s-control2
```

Then rebuild/repurpose VM 402. Do this one control-plane change at a time and verify quorum + CNPG + Longhorn after each step.

---

## Silo notes for the GPU worker

The GPU worker is ready to be the Silo transcode node:

- Pin the transcode workload to `k3s-gpu-worker` with `nodeSelector: media/gpu: intel`.
- Mount `/dev/dri` via `hostPath`.
- Add supplemental groups for `video` / `render` (commonly `44` and `109`; verify on the node).
- Use `MODE=transcode`.
- Share Postgres, Redis (`Dragonfly`), and `SECRET_KEY` with the main Silo server.
- Mount the same media path read-only.
- Set `SILO_STOP_GRACE_PERIOD=11m` for drain.
- Register the node in Silo at **Admin → Playback → Nodes** with matching `NODE_NAME` / `NODE_URL`.
- Keep the main Silo server integrated (or API) so CPU fallback still works if the GPU worker is down.

Do **not** use `pcie=1` for this iGPU on `pve4`, and do not add display-passthrough flags (`x-vga`, ROM files, `vga: none`) for a headless VA-API worker.

---

## Open items

- [ ] Reduce control planes to 3: `control1`, `control3`, `control4`.
- [ ] Remove/repurpose `control2` as a worker.
- [ ] Confirm Longhorn does not schedule replicas on `k3s-gpu-worker`.
- [ ] Deploy Silo server + transcode worker; register the node in Silo.
- [ ] Consider testing VM 405 reboot with the GPU attached, once there is a maintenance window.
- [ ] If the GPU worker VM is ever recreated, update the MAC in `10-ens18.link` / netplan.
