# Cluster Bootstrap Procedures
The documentation here will guide from preparing a Debian or Ubuntu-based node, to having k3s setup.
## Node Preparation
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