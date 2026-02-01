# Cluster Bootstrap Procedures
The documentation here will guide from preparing a Debian or Ubuntu-based node, to having k3s setup.
## Node Preparation
Install packages:
```
sudo apt install nfs-common open-iscsi qemu-guest-agent unattended-upgrades
```
Configure Unattended Upgrades:
```
sudo dpkg-reconfigure -plow unattended-upgrades
```
Permit OS package upgrades by removing the `\\` from the 2nd line listed below:
```
sudo nano /etc/apt/apt.conf.d/50unattended-upgrades
"${distro_id}:${distro_codename}-updates";
```

### Install k3s on all nodes
*I'd like to shift this eventually to Ansible*

The below will init a new cluster:
```
curl -fL https://get.k3s.io | K3S_TOKEN=${SERVER_TOKEN} \
    sh -s - \
    --cluster-init
    --disable servicelb \
    --disable traefik \
    --server https://k3s.[secret domain]:6443 \
    --tls-san "[ip address of new k3s VM node]" \
    --tls-san "[dns address of new k3s VM node]"
```
The below will add new server nodes to the cluster.  It should be created in `/etc/rancher/k3s/config.yaml` on the new server and can be copied from an existing server node. The directory may need to be made first via `mkdir -p /etc/rancher/k3s`.
```
server: https://k3s.[secret domain]:6443
token: [token from server node of the node where you did cluster-init]
tls-san:
  - 192.168.2.8
  - k3s.[secret domain]
disable:
  - traefik
  - servicelb
flannel-backend: none
disable-network-policy: true
etcd-expose-metrics: true
kube-controller-manager-arg:
  - "bind-address=0.0.0.0"
kube-proxy-arg:
  - "metrics-bind-address=0.0.0.0"
kube-scheduler-arg:
  - "bind-address=0.0.0.0"
```
Once the config file is present, run the following command to install k3s:
```
curl -sfL https://get.k3s.io | sh -s server
```


### Secret Preparation
Create the following gitlab-secret.yaml, and save it to any location, to prepare for external-secrets:

```
apiVersion: v1
kind: Secret
metadata:
  name: gitlab-secret
  namespace: kube-system
data:
  token: [fill in Gitlab PAT]
type: Opaque
```

Then apply the file to the cluster:
```kubectl apply -f gitlab-secret.yaml```

### Install Flux
*This only has to be performed once for the full cluster*

First, export the Github PAT:
```
export GITHUB_TOKEN=[GITHUB PAT]
```
Next, boostrap the cluster:
```
flux bootstrap github \
  --token-auth \
  --owner=vember31 \
  --repository=home-ops \
  --branch=main \
  --path=kubernetes/flux \
  --personal
```