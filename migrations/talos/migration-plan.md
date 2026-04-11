# k3s to Talos Linux Migration Plan

> Created: 2026-04-11
> Status: Planning

## Overview

Migrate from k3s (on Ubuntu VMs in Proxmox) to Talos Linux — an immutable, API-managed OS purpose-built for Kubernetes. No SSH, no shell, no package manager. Everything managed through `talosctl` and declarative machine configs.

**Strategy**: Parallel cluster (blue-green). Both clusters run simultaneously with their own permanent IPs. Cutover is just DNS/DHCP/BGP changes — no re-IP dance. The k3s cluster stays untouched on `main` branch until decommissioned.

**Git isolation**: A `talos` branch holds all Talos-specific changes during the parallel phase. Talos cluster's FluxInstance syncs from the `talos` branch. At cutover, merge `talos` → `main`.

---

## What Stays the Same (~90% of the repo)

- All Flux GitOps configuration (FluxInstance, repositories, vars, kustomizations)
- All application HelmReleases (60+ apps across 15 namespaces)
- All ExternalSecrets (GitLab backend is cluster-agnostic)
- Cilium BGP configuration (peering, LB pools, announcements)
- CoreDNS, Traefik, cert-manager, external-secrets, external-dns
- Longhorn (with extensions — see below)
- CloudNative-PG
- Pod CIDR (`10.42.0.0/16`) and Service CIDR (`10.43.0.0/16`)

## What Changes

| Component | Current (k3s) | Talos |
|---|---|---|
| OS | Ubuntu VMs + k3s binary | Talos Linux (immutable) |
| Node management | SSH + apt + systemd | `talosctl` + machine configs |
| OS upgrades | unattended-upgrades + kured | `talosctl upgrade` |
| k8s upgrades | system-upgrade-controller | `talosctl upgrade-k8s` |
| Control plane HA | Cilium BGP LB Service | Talos VIP (bootstrap) + Cilium BGP LB Service |
| etcd management | k3s-managed, custom defrag CronJob | Talos-managed, `talosctl etcd` commands |
| CNI bootstrap | k3s starts, then Cilium installed via Flux | Cilium must be inline manifest (before Flux) |
| API server proxy port | 6443 | 7445 (Talos local proxy) |
| etcd cert path | `/var/lib/rancher/k3s/server/tls/etcd` | `/system/secrets/etcd` |
| local-path-provisioner | Bundled with k3s | Must install separately |

---

## IP Scheme

### Secure VLAN (192.168.2.0/24)

| Resource | k3s (current) | Talos (permanent) |
|---|---|---|
| Node 1 | 192.168.2.11 | 192.168.2.41 |
| Node 2 | 192.168.2.12 | 192.168.2.42 |
| Node 3 | 192.168.2.13 | 192.168.2.43 |
| Node 4 | 192.168.2.14 | 192.168.2.44 |
| Node 5 | 192.168.2.15 | 192.168.2.45 |
| Talos VIP (internal/bootstrap only) | N/A | 192.168.2.40 |

### LB VLAN (192.168.10.0/24)

| Resource | k3s (current) | Talos (permanent) |
|---|---|---|
| Traefik | 192.168.10.20 | 192.168.10.40 |
| Plex | 192.168.10.21 | 192.168.10.41 |
| Blocky | 192.168.10.22 | 192.168.10.42 |
| qBittorrent | 192.168.10.23 | 192.168.10.43 |
| K8s API LB | 192.168.10.100 | 192.168.10.50 |

The Talos VIP (192.168.2.40) is only used for node-to-node bootstrap before Cilium is running. External `kubectl` access continues through the Cilium BGP-advertised K8s API LB, same as today.

---

## Phase 1: Preparation

### 1.1 Verify Talos Kernel Compatibility

Cilium netkit datapath requires Linux 6.8+. Talos 1.9+ ships kernel 6.12+, so this should be fine. Confirm:

```bash
# After booting a test Talos node
talosctl dmesg --nodes <ip> | grep "Linux version"
```

Also required: `enableIPv4BIGTCP` (kernel 5.19+), BBR bandwidth manager — both well within Talos kernel versions.

### 1.2 Build Custom Talos Image with Extensions

Talos is immutable — no `apt install`. Longhorn requires iSCSI and util-linux tools as system extensions.

Required extensions:

| Extension | Reason |
|---|---|
| `siderolabs/iscsi-tools` | Longhorn requires iSCSI initiator |
| `siderolabs/util-linux-tools` | Longhorn needs `nsenter`, `blkid`, etc. |
| `siderolabs/qemu-guest-agent` | Proxmox VM integration |
| `siderolabs/intel-ucode` | Microcode updates (if Intel CPUs) |

Build via [Talos Image Factory](https://factory.talos.dev) or `imager`:

```bash
docker run --rm -t -v /tmp/_out:/out \
  ghcr.io/siderolabs/imager:v1.9.x \
  installer \
  --system-extension-image ghcr.io/siderolabs/iscsi-tools:v0.1.x \
  --system-extension-image ghcr.io/siderolabs/util-linux-tools:v2.x \
  --system-extension-image ghcr.io/siderolabs/qemu-guest-agent:vX.x \
  --system-extension-image ghcr.io/siderolabs/intel-ucode:vX.x
```

### 1.3 Back Up Everything

- **Longhorn**: Verify daily backups to MinIO are current and restorable. Take an on-demand backup before migration.
- **CloudNative-PG**: WAL archiving to MinIO (`s3://cloudnative-pg/`) is already running. Take an on-demand backup.
- **Document current state**:
  ```bash
  kubectl get nodes -o wide
  kubectl get pvc -A
  kubectl get svc -A --field-selector spec.type=LoadBalancer
  ```

---

## Phase 2: Repo Changes (on `talos` branch)

### 2.1 Create the `talos` Branch

```bash
git checkout -b talos main
```

All changes below happen on this branch. k3s keeps running on `main` untouched.

### 2.2 Update cluster-settings.yaml

```yaml
# kubernetes/flux/vars/cluster-settings.yaml
# Rename comment from "k3s-based IPs" to "k8s service IPs"
TRAEFIK_IP: "192.168.10.40"
BLOCKY_IP: "192.168.10.42"
K8S_LB_IP: "192.168.10.50"    # renamed from K3S_LB_IP
PLEX_IP: "192.168.10.41"
QBT_IP: "192.168.10.43"
```

All HelmReleases reference these via Flux substitution (`${TRAEFIK_IP}`, etc.), so the IP change propagates automatically to all apps.

### 2.3 Update K3S_LB_IP References

Renaming `K3S_LB_IP` → `K8S_LB_IP` requires updating:
- `kubernetes/flux/vars/cluster-settings.yaml` (definition)
- `kubernetes/apps/kube-system/cilium/app/kube-api.yaml` (annotation)
- `kubernetes/apps/networking/blocky/app/config/config.yml` (DNS mapping — also rename `k3s.domain` to `talos.domain` or `k8s.domain`)

### 2.4 Update Cilium Config

In `kubernetes/apps/kube-system/cilium/app/helmrelease.yaml`:

```yaml
# Change from:
k8sServiceHost: 127.0.0.1
k8sServicePort: 6443

# To:
k8sServiceHost: 127.0.0.1
k8sServicePort: 7445  # Talos API proxy port
```

### 2.5 Update etcd-defrag

In `kubernetes/apps/kube-system/etcd-defrag/app/helmrelease.yaml`:

```yaml
# Change hostPath from:
hostPath: /var/lib/rancher/k3s/server/tls/etcd

# To:
hostPath: /system/secrets/etcd
```

Verify the cert file names match Talos's layout (`ca.crt`, `peer.crt`, `peer.key` or similar). May need to adjust the `--cacert`, `--cert`, `--key` args as well.

### 2.6 Delete k3s-Specific Apps

Remove entirely:
- `kubernetes/apps/infrastructure/system-upgrade-controller/` (k3s upgrade mechanism)
- `kubernetes/apps/kube-system/kured/` (reboot sentinel — Talos is immutable)

Update the parent namespace `kustomization.yaml` files to remove references to these apps' `ks.yaml`.

### 2.7 Add local-path-provisioner

k3s bundles Rancher's local-path-provisioner. VictoriaMetrics and VictoriaLogs use the `local-path` StorageClass. On Talos, install it as a Flux-managed app:

- Add a HelmRelease for `rancher/local-path-provisioner` or deploy the raw manifests
- Ensure the StorageClass name remains `local-path`

### 2.8 Clean Up Dead Code (Optional)

- `configs/haproxy/` — no longer in use
- `configs/keepalived/` — no longer in use
- `kubernetes/bootstrap/README.md` — rewrite for Talos workflow
- `scripts/` — replace k3s setup scripts with Talos machine config generation

### 2.9 Update FluxInstance Branch

In the FluxInstance HelmRelease, point to the `talos` branch during parallel running:

```yaml
# kubernetes/apps/flux-system/flux-instance/app/helmrelease.yaml
# Change ref.branch from "main" to "talos"
```

This gets applied manually during Talos bootstrap (step 3.4), not committed to the branch itself — otherwise the k3s cluster would also try to switch branches if the change leaked to main.

---

## Phase 3: Build the Talos Cluster

### 3.1 Talos Machine Config

Generate configs with `talosctl gen config`:

```bash
talosctl gen config home-ops https://192.168.2.40:6443 \
  --config-patch-control-plane @controlplane-patch.yaml \
  --output-dir _out
```

Key settings in the controlplane patch:

```yaml
machine:
  type: controlplane
  network:
    interfaces:
      - interface: ens18
        addresses:
          - 192.168.2.4X/24  # per-node
        routes:
          - network: 0.0.0.0/0
            gateway: 192.168.2.1
        vip:
          ip: 192.168.2.40  # shared VIP
    nameservers:
      - 1.1.1.1
      - 1.0.0.1
  install:
    extensions:
      - image: ghcr.io/siderolabs/iscsi-tools:v0.1.x
      - image: ghcr.io/siderolabs/util-linux-tools:v2.x
      - image: ghcr.io/siderolabs/qemu-guest-agent:vX.x
  kernel:
    modules:
      - name: iscsi_tcp

cluster:
  controlPlane:
    endpoint: https://192.168.2.40:6443
  network:
    cni:
      name: none           # Cilium is the CNI
    podSubnets:
      - 10.42.0.0/16
    serviceSubnets:
      - 10.43.0.0/16
  proxy:
    disabled: true         # Cilium replaces kube-proxy
  etcd:
    advertisedSubnets:
      - 192.168.2.0/24
  apiServer:
    certSANs:
      - 192.168.2.40
  controllerManager:
    extraArgs:
      bind-address: 0.0.0.0
  scheduler:
    extraArgs:
      bind-address: 0.0.0.0
  inlineManifests:
    - name: cilium
      contents: |
        # Helm-templated Cilium manifests (see 3.2)
```

### 3.2 Solve the Cilium Bootstrap Problem

Talos with `cni: none` means no pods schedule until Cilium is running. Cilium must be installed before Flux.

Generate Cilium manifests for the inline manifest:

```bash
helm template cilium oci://quay.io/cilium/charts/cilium \
  --version 1.19.2 \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=127.0.0.1 \
  --set k8sServicePort=7445 \
  --set cni.exclusive=true \
  --set bpf.datapathMode=netkit \
  --set routingMode=native \
  --set ipv4NativeRoutingCIDR=10.42.0.0/16 \
  --set autoDirectNodeRoutes=true \
  --set ipam.mode=cluster-pool \
  --set ipam.operator.clusterPoolIPv4PodCIDRList='{10.42.0.0/16}' \
  > cilium-inline.yaml
```

Embed this in the machine config's `inlineManifests`. Once Flux is bootstrapped, it takes over Cilium management via HelmRelease (reconciles on top of the inline install).

### 3.3 Provision VMs and Bootstrap

```bash
# Create 5 VMs in Proxmox, boot from Talos ISO

# Apply config to each node (with per-node IP patch)
talosctl apply-config --insecure --nodes 192.168.2.41 --file controlplane-1.yaml
talosctl apply-config --insecure --nodes 192.168.2.42 --file controlplane-2.yaml
# ... etc

# Bootstrap the first node
talosctl bootstrap --nodes 192.168.2.41

# Wait for all nodes to join
talosctl health --nodes 192.168.2.41

# Get kubeconfig
talosctl kubeconfig --nodes 192.168.2.41
```

### 3.4 Add BGP Peers on UDM Router

Add Talos nodes to the FRR config alongside existing k3s peers:

```conf
# New Talos peers (add to existing peer-group K8S)
neighbor 192.168.2.41 peer-group K8S
neighbor 192.168.2.42 peer-group K8S
neighbor 192.168.2.43 peer-group K8S
neighbor 192.168.2.44 peer-group K8S
neighbor 192.168.2.45 peer-group K8S
```

No conflict — each cluster advertises its own LB IPs via BGP.

### 3.5 Bootstrap Flux

```bash
# Create the GitLab secret for External-Secrets
kubectl create secret generic gitlab-secret \
  --namespace kube-system \
  --from-literal=token="${GITLAB_PAT}"

# Install Flux Operator
helm install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
  --namespace flux-system --create-namespace

# Apply FluxInstance — pointed at the 'talos' branch
# (modify the FluxInstance manifest to use ref.branch: talos before applying)
kubectl apply -f flux-instance.yaml
```

Flux syncs the `talos` branch → reconciles all apps with the new Talos-specific config and IPs.

### 3.6 Restore Data

**CloudNative-PG (PostgreSQL)**:
- Modify the cluster spec on the `talos` branch to use `bootstrap.recovery` (restore from MinIO WAL archive) instead of `bootstrap.initdb`
- After restore completes and the cluster is healthy, switch back to `bootstrap.initdb` for future reconciliation

**Longhorn volumes**:
- Restore from MinIO backups via the Longhorn UI or API
- Or use Velero to migrate PVCs between clusters

**NFS media**:
- No migration needed — same OMV NFS shares, same mount config

### 3.7 Validate

- [ ] All nodes Ready (`talosctl health`)
- [ ] Cilium healthy, BGP peers established (`cilium bgp peers`)
- [ ] All 60+ apps reconciled by Flux (`flux get kustomizations`)
- [ ] LB IPs reachable from workstation (Traefik at .40, Blocky at .42, etc.)
- [ ] DNS resolution working (test Blocky at new IP)
- [ ] TLS certificates issued (cert-manager)
- [ ] Secrets synced from GitLab (external-secrets)
- [ ] Persistent data intact (databases, app configs)
- [ ] Grafana dashboards showing metrics
- [ ] Plex streaming works, downloads functional

---

## Phase 4: Cutover

This is the brief window where traffic moves from k3s to Talos.

### 4.1 Final Data Sync

- Take a fresh CloudNative-PG backup and restore to Talos cluster
- Take fresh Longhorn backups and restore
- This minimizes data gap between clusters

### 4.2 Switch DNS/DHCP

- **DHCP on UDM**: Point clients' DNS server from `192.168.10.22` (old Blocky) to `192.168.10.42` (new Blocky)
- **AdGuard Home**: If it forwards to Blocky, update to the new IP

### 4.3 Update Router BGP

Remove k3s peers from FRR config on UDM:

```conf
# Remove these
no neighbor 192.168.2.11 peer-group K8S
no neighbor 192.168.2.12 peer-group K8S
no neighbor 192.168.2.13 peer-group K8S
no neighbor 192.168.2.14 peer-group K8S
no neighbor 192.168.2.15 peer-group K8S
```

### 4.4 Merge and Finalize

```bash
# Merge talos branch to main
git checkout main
git merge talos

# Update FluxInstance to sync 'main' instead of 'talos'
# (edit and apply, or commit the change)
```

### 4.5 Decommission k3s

- Shut down k3s VMs in Proxmox
- Optionally delete them after a soak period (keep for a week as safety net)

---

## Phase 5: Ongoing Operations

### OS Upgrades (Replaces system-upgrade-controller + kured)

```bash
# Upgrade Talos OS on a node
talosctl upgrade --nodes 192.168.2.41 \
  --image ghcr.io/siderolabs/installer:v1.9.x

# Upgrade Kubernetes version
talosctl upgrade-k8s --to 1.32.x
```

Consider automating with Omni (Talos's management platform) or a Kubernetes-native upgrade controller for Talos.

### etcd Management

```bash
talosctl etcd defrag --nodes 192.168.2.41
talosctl etcd snapshot --nodes 192.168.2.41 etcd-backup.db
talosctl etcd members
```

The etcd-defrag CronJob can still work if cert paths are updated (done in Phase 2).

### Debugging (No SSH)

```bash
talosctl dmesg --nodes 192.168.2.41          # kernel logs
talosctl logs kubelet --nodes 192.168.2.41    # kubelet logs
talosctl services --nodes 192.168.2.41        # service status
talosctl dashboard --nodes 192.168.2.41       # TUI dashboard
talosctl read /var/log/... --nodes 192.168.2.41  # read files
```

---

## Risk Assessment

| Risk | Severity | Mitigation |
|---|---|---|
| Longhorn on Talos | Medium | Requires iscsi-tools + util-linux-tools extensions baked into image. Well-documented. |
| Cilium bootstrap ordering | Medium | Inline manifests in machine config. Flux reconciles on top once running. |
| Data loss during migration | High | Parallel cluster + verified backups. Never destroy k3s until Talos validated. Final data sync before cutover. |
| BGP peering disruption | Low | Different IPs, both peer groups coexist on router. No conflict. |
| Talos kernel compatibility | Low | 6.12+ kernel ships with Talos 1.9+, well above 6.8 netkit requirement. |
| local-path-provisioner | Low | Install as standalone Helm chart. Drop-in replacement for k3s-bundled version. |
| etcd cert paths | Low | Simple path change in etcd-defrag HelmRelease. |
| Proxmox integration | Low | qemu-guest-agent extension available for Talos. |

---

## Files to Modify (on talos branch)

### Update
- `kubernetes/flux/vars/cluster-settings.yaml` — new IPs, rename K3S_LB_IP → K8S_LB_IP
- `kubernetes/apps/kube-system/cilium/app/helmrelease.yaml` — k8sServicePort 6443 → 7445
- `kubernetes/apps/kube-system/cilium/app/kube-api.yaml` — K3S_LB_IP → K8S_LB_IP
- `kubernetes/apps/kube-system/etcd-defrag/app/helmrelease.yaml` — etcd cert hostPath
- `kubernetes/apps/networking/blocky/app/config/config.yml` — K3S_LB_IP → K8S_LB_IP, rename DNS entry

### Delete
- `kubernetes/apps/infrastructure/system-upgrade-controller/` — entire directory
- `kubernetes/apps/kube-system/kured/` — entire directory
- Update parent namespace `kustomization.yaml` files to remove references

### Add
- `kubernetes/apps/<namespace>/local-path-provisioner/` — new Flux-managed app
- `migrations/talos/` — this document and machine config templates

### Clean Up (Optional)
- `configs/haproxy/` — dead code, no longer in use
- `configs/keepalived/` — dead code, no longer in use
- `kubernetes/bootstrap/README.md` — rewrite for Talos
