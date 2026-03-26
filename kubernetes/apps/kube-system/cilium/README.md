# Cilium

## Netkit Migration (2026-03-26)

Migrated Cilium's datapath from `veth` to `netkit` across all 5 cluster nodes. Netkit is a Linux 6.8+ network device that replaces the traditional veth pair for container networking, providing ~12% improvement in connections per second.

This completes all four performance shortcuts from Isovalent's [networking optimization guide](https://isovalent.com/blog/post/cilium-netkit-a-new-container-networking-paradigm-for-the-ai-era/):

1. **eBPF kube-proxy replacement** — `kubeProxyReplacement: true`
2. **eBPF host routing** — `routingMode: native` + `autoDirectNodeRoutes: true`
3. **BIG TCP** — `enableIPv4BIGTCP: true`
4. **Netkit** — `bpf.datapathMode: netkit`

### Migration procedure

Cilium cannot switch from veth to netkit in-place — existing pods retain their veth interfaces, and Cilium will fatal error if it detects veth endpoints while in netkit mode. A per-node rolling migration is required.

A `CiliumNodeConfig` resource was used to override `datapath-mode: netkit` on individual nodes via a label selector (`cilium.io/datapath-mode: netkit`), allowing the cluster-wide HelmRelease to remain on `veth` until all nodes were migrated.

> **Key gotcha:** The CiliumNodeConfig key is `datapath-mode`, not `bpf-datapath-mode`. The Helm value `bpf.datapathMode` maps to the CLI flag `--datapath-mode`.

#### Per-node steps

```bash
NODE="<node-name>"

# 1. Cordon and drain workloads
kubectl cordon $NODE
kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data

# 2. Label node to activate the CiliumNodeConfig
kubectl label node $NODE cilium.io/datapath-mode=netkit

# 3. Taint with NoExecute to evict daemonset pods
#    Cilium tolerates all taints so it stays; everything else gets evicted.
#    This is critical — without the taint, daemonset pods respawn with veth
#    interfaces before Cilium restarts (they don't need CNI to start), causing
#    Cilium to fatal error on detecting existing veth endpoints.
kubectl taint nodes $NODE netkit-migration=true:NoExecute

# 4. Wait for all non-Cilium pods to terminate (force-delete stragglers like longhorn)
kubectl get pods --all-namespaces --field-selector spec.nodeName=$NODE --no-headers

# 5. Delete the Cilium pod so it restarts fresh in netkit mode
kubectl -n kube-system delete pod -l k8s-app=cilium --field-selector spec.nodeName=$NODE --grace-period=0 --force

# 6. Wait for Cilium to be ready and verify netkit
sleep 8
kubectl -n kube-system wait pod -l k8s-app=cilium --field-selector spec.nodeName=$NODE --for=condition=Ready --timeout=120s
kubectl -n kube-system exec $(kubectl -n kube-system get pod -l k8s-app=cilium \
  --field-selector spec.nodeName=$NODE -o jsonpath='{.items[0].metadata.name}') \
  -- cilium-dbg status | grep "Device Mode"
# Expected output: Device Mode:             netkit

# 7. Remove taint and uncordon
kubectl taint nodes $NODE netkit-migration=true:NoExecute-
kubectl uncordon $NODE
```

#### Post-migration cleanup

Once all nodes were confirmed running netkit:

1. Updated `bpf.datapathMode: netkit` in the HelmRelease (cluster-wide default)
2. Removed the `CiliumNodeConfig` resource
3. Removed `cilium.io/datapath-mode` labels from all nodes

### Migration order

Nodes were migrated from least to most loaded to minimize risk:

| Order | Node | Notes |
|-------|------|-------|
| 1 | k3s-control4 | Lightest node, used as initial test |
| 2 | k3s-control5 | |
| 3 | k3s-control2 | |
| 4 | k3s-control3 | |
| 5 | k3s-control1 | Busiest node, migrated last |

### Requirements

- Linux kernel 6.8+ on all nodes (all running 6.8.0-106-generic)
- Cilium 1.16+ (netkit support)
