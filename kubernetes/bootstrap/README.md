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
export GITHUB_TOKEN="[GitHub PAT for Flux]"
```

### Install k3s on all nodes
*I'd like to shift this eventually to Ansible*

The below will init a new cluster:
```
curl -fL https://get.k3s.io | K3S_TOKEN=${K3S_TOKEN} \
    sh -s - \
    --cluster-init
    --disable servicelb \
    --disable traefik \
    --server https://k3s.${SECRET_DOMAIN}:6443 \
    --tls-san "[ip address of new k3s VM node]" \
    --tls-san "[dns address of new k3s VM node]"
```
The below will write the k3s config and install k3s on a new server node:
```
sudo mkdir -p /etc/rancher/k3s && sudo bash -c "cat > /etc/rancher/k3s/config.yaml <<EOF
server: https://k3s.${SECRET_DOMAIN}:6443
token: ${K3S_TOKEN}
tls-san:
  - 192.168.2.8
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
kube-proxy-arg:
  - \"metrics-bind-address=0.0.0.0\"
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

### Install Flux
*This only has to be performed once for the full cluster*
```
flux bootstrap github \
  --token-auth \
  --owner=vember31 \
  --repository=home-ops \
  --branch=main \
  --path=kubernetes/flux \
  --personal
```