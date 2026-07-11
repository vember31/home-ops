# Cluster Bootstrap Procedures
The documentation here will guide from preparing a Debian or Ubuntu-based node, to having k3s setup.

## IP Address Assignment
Cluster nodes live on the secure VLAN (`192.168.2.0/24`) and are currently numbered sequentially starting at `192.168.2.11` (node 1 = `.11`, node 2 = `.12`, etc.) — the current cluster runs nodes `.11`–`.15`. Every node runs as a k3s **server** (this is an all-control-plane / stacked-etcd HA setup, not a separate control-plane/agent split), so a new node should be assigned the next unused IP in that sequence.

Once you've picked an IP for the new node, provision the VM/host with that address before continuing to Node Preparation below.

## Node Preparation
### Configure UDP buffers for QUIC
Blocky uses DNS-over-QUIC upstreams, so each node needs larger UDP socket buffers than the Linux defaults:
```
sudo tee /etc/sysctl.d/99-quic.conf >/dev/null <<EOF
net.core.rmem_max=7500000
net.core.wmem_max=7500000
EOF
sudo sysctl --system
```

Install packages:
```
sudo apt install nfs-common open-iscsi qemu-guest-agent unattended-upgrades
```
Configure Unattended Upgrades and enable OS package upgrades:
```
sudo dpkg-reconfigure -plow unattended-upgrades && sudo sed -i 's|//\s*"\${distro_id}:\${distro_codename}-updates";|"\${distro_id}:\${distro_codename}-updates";|' /etc/apt/apt.conf.d/50unattended-upgrades
```

### Configure Multipath (Longhorn)
Blacklist all devices from multipath so it doesn't interfere with Longhorn:
```
sudo bash -c 'cat > /etc/multipath.conf <<EOF
blacklist {
    devnode "^sd[a-z0-9]+"
}
EOF' && sudo systemctl restart multipathd && sudo multipath -F
```

### Set Environment Variables
Define these before running the remaining commands:
```
export SECRET_DOMAIN="example.com"
export K3S_TOKEN="[token from the node where you ran cluster-init]"
export GITLAB_PAT="[Gitlab PAT for external-secrets]"
```

### Install k3s on all nodes
*I'd like to shift this eventually to Ansible*

Write the k3s config and install k3s on the **first node** to initialize the cluster:
```
sudo mkdir -p /etc/rancher/k3s && sudo bash -c "cat > /etc/rancher/k3s/config.yaml <<EOF
cluster-init: true
token: ${K3S_TOKEN}
tls-san:
  - k3s.${SECRET_DOMAIN}
disable:
  - traefik
  - servicelb
  - coredns
flannel-backend: none
disable-network-policy: true
disable-kube-proxy: true
etcd-expose-metrics: true
kube-controller-manager-arg:
  - \"bind-address=0.0.0.0\"
kube-scheduler-arg:
  - \"bind-address=0.0.0.0\"
EOF" && curl -sfL https://get.k3s.io | sh -s server
```

Write the k3s config and install k3s on **additional server nodes** to join the cluster:
```
sudo mkdir -p /etc/rancher/k3s && sudo bash -c "cat > /etc/rancher/k3s/config.yaml <<EOF
server: https://k3s.${SECRET_DOMAIN}:6443
token: ${K3S_TOKEN}
tls-san:
  - k3s.${SECRET_DOMAIN}
disable:
  - traefik
  - servicelb
  - coredns
flannel-backend: none
disable-network-policy: true
disable-kube-proxy: true
etcd-expose-metrics: true
kube-controller-manager-arg:
  - \"bind-address=0.0.0.0\"
kube-scheduler-arg:
  - \"bind-address=0.0.0.0\"
EOF" && curl -sfL https://get.k3s.io | sh -s server
```

### Secret Preparation
Create and apply the gitlab secret for external-secrets:
```
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: gitlab-secret
  namespace: kube-system
data:
  token: $(echo -n "${GITLAB_PAT}" | base64)
type: Opaque
EOF
```

### Install Flux Operator
*This only has to be performed once for the full cluster. This bootstraps the Flux Operator, which then syncs the repo and manages itself going forward.*

Install the Flux Operator Helm chart:
```
helm install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
  --namespace flux-system \
  --create-namespace
```

Apply the FluxInstance CR to start syncing the repo:
```
kubectl apply -f - <<EOF
apiVersion: fluxcd.controlplane.io/v1
kind: FluxInstance
metadata:
  name: flux
  namespace: flux-system
spec:
  distribution:
    version: "2.x"
    registry: "ghcr.io/fluxcd"
  components:
    - source-controller
    - kustomize-controller
    - helm-controller
    - notification-controller
  cluster:
    networkPolicy: false
  sync:
    kind: GitRepository
    url: https://github.com/vember31/home-ops
    ref: refs/heads/main
    path: kubernetes/flux
    interval: 1h
EOF
```
Once the sync completes, Flux will pick up the `flux-operator` and `flux-instance` HelmReleases from the repo and manage itself from that point on.

## Adding a New Node to an Existing Cluster
Joining a new node to an already-bootstrapped cluster only requires the **Node Preparation** and **Install k3s on additional server nodes** steps above (skip Secret Preparation and Install Flux Operator — those are one-time, cluster-wide steps). `K3S_TOKEN` can be read from any existing node at `/var/lib/rancher/k3s/server/token`.

Beyond joining k3s itself, a few places track the list of node IPs by hand and must be updated whenever a node is added (or removed):

| File | What to update |
|---|---|
| `kubernetes/flux/vars/cluster-settings.yaml` | Add a `NODE<n>_IP: "<ip>"` entry — this is the source of truth for in-cluster manifests |
| `kubernetes/apps/monitoring/victoria-metrics-k8s-stack/app/vmstaticscrapes.yaml` | Add a `"${NODE<n>_IP}:<port>"` line to the `kube-controller-manager` (`:10257`), `kube-etcd` (`:2381`), and `kube-scheduler` (`:10259`) `targetEndpoints` lists |
| `configs/frr/frr-config-udm-pro-se.txt` | Add a `neighbor <ip> peer-group K8S` line, and bump `maximum-paths` in `router bgp 64513` to match the new node count |
| `docs/runbooks/cluster-investigation.md` | Add a row to the "Node → pod mapping" table, and add the IP/label to the node arrays in the embedded Python snippets |
| `CLAUDE.md` (repo root) | Add the new node to the "Cluster Access" SSH list |

`cluster-settings.yaml` is a Flux `ConfigMap` substituted into every manifest under `kubernetes/apps` via `postBuild.substituteFrom` (wired up cluster-wide in `kubernetes/flux/apps.yaml`), so `${NODE1_IP}` etc. resolve automatically in `vmstaticscrapes.yaml`. This only centralizes the *values* — Flux's substitution is a plain string replace with no array/loop support (it even strips newlines from substituted values), so growing the node count still means adding a new line per file above; it just means an existing node's IP only needs to change in one place.

**`configs/frr/frr-config-udm-pro-se.txt` is a reference copy, not GitOps-managed** — every node BGP-peers directly with the UDM Pro SE for MetalLB/Cilium route advertisement (see `configs/frr/frr-README.md`), and the UDM only picks up changes when they're applied live. After editing the repo file, SSH into the UDM Pro SE and apply the same change to the running config:
```
vtysh
configure terminal
router bgp 64513
 maximum-paths <new node count>
 neighbor <new-node-ip> peer-group K8S
 neighbor <new-node-ip> remote-as 64514
 neighbor <new-node-ip> soft-reconfiguration inbound
end
write memory
```
Validate with `vtysh -c "show ip bgp"` — the new node's IP should appear as a next hop with a `=` (multipath) once BGP converges.

After joining, confirm the node shows up healthy with `kubectl get nodes -o wide` and that etcd has the expected member count (`kubectl -n kube-system exec <any-etcd-pod> -- etcdctl member list`, or check the etcd fragmentation query in `docs/runbooks/cluster-investigation.md`).
