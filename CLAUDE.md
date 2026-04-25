# CLAUDE.md — home-ops Repository Guide

## What This Is

GitOps-managed home Kubernetes infrastructure. A k3s cluster running on Ubuntu VMs in Proxmox, reconciled by **Flux CD** (via Flux Operator). All changes go through Git — no manual `kubectl apply`.

**Owner**: @vember31  
**Repo**: https://github.com/vember31/home-ops  
**Timezone**: America/Chicago

## Directory Structure

```
kubernetes/
├── apps/                  # All application manifests, organized by namespace
│   ├── <namespace>/       # e.g., monitoring, downloads, media, networking
│   │   ├── namespace.yaml
│   │   └── <app>/
│   │       ├── ks.yaml              # Flux Kustomization (entry point for Flux)
│   │       └── app/                 # Actual resources
│   │           ├── helmrelease.yaml
│   │           ├── kustomization.yaml
│   │           ├── externalsecret.yaml
│   │           └── config/          # ConfigMap files
├── bootstrap/             # Cluster init docs and k3s setup
├── flux/                  # Flux config: repositories, vars, FluxInstance
│   ├── apps.yaml          # Top-level: defines cluster-apps, flux-repositories, flux-vars
│   ├── repositories/      # HelmRepository and OCIRepository sources
│   └── vars/
│       ├── cluster-settings.yaml   # ConfigMap with IPs, CIDRs, names
│       └── cluster-secrets.yaml    # ExternalSecret pulling from GitLab
└── templates/
    ├── yaml-templates/    # Boilerplate for new apps (helmrelease, ks, externalsecret)
    └── gatus/             # Gatus health-check templates (internal, external, dns)

configs/                   # Network device configs (frr, haproxy, keepalived)
scripts/                   # Utility scripts (node setup, blocky, redis)
.github/
├── renovate.json5         # Renovate main config
├── renovate/              # Modular Renovate config files
└── workflows/             # GitHub Actions (cloudflare-ips, qbt-versions)
```

## App Conventions

### Adding/Modifying an App

Every app follows the same pattern: `kubernetes/apps/<namespace>/<app-name>/`

1. **`ks.yaml`** — Flux Kustomization. Tells Flux what to reconcile, with dependency ordering and variable substitution.
2. **`app/helmrelease.yaml`** — HelmRelease defining the chart, version, and values.
3. **`app/kustomization.yaml`** — Kustomize resource list. Often includes `externalsecret.yaml`, gatus templates, configMapGenerators.
4. **`app/externalsecret.yaml`** — Pulls secrets from GitLab via `gitlab-secret-store` ClusterSecretStore.
5. **Namespace-level `kustomization.yaml`** — The `kustomization.yaml` at `kubernetes/apps/<namespace>/kustomization.yaml` must include a reference to the new app's `ks.yaml` (e.g., `- ./my-app/ks.yaml`). **This is required for Flux to discover the app.**

Templates live in `kubernetes/templates/yaml-templates/` — use them as starting points.

### Key Patterns

- **Schema comments**: Every YAML file starts with `# yaml-language-server: $schema=...` for IDE validation.
- **Variable substitution**: Flux `postBuild.substitute` injects `${VARIABLE}` from `cluster-settings` ConfigMap and `cluster-secrets` Secret. Per-app vars like `${APP}` and `${GATUS_SUBDOMAIN}` are set in `ks.yaml`.
- **Secrets**: Never committed to git. Stored in GitLab CI/CD variables, fetched by External-Secrets operator via `gitlab-secret-store`.
- **Config reload**: Apps using ConfigMaps have `reloader.stakater.com/auto: "true"` annotation for automatic restarts on config changes.
- **Ingress**: Uses Traefik with annotations for cert-manager (`letsencrypt-production`), external-dns (`traefik.local.${SECRET_DOMAIN}`), and Traefik middlewares.
- **RBAC**: Most apps have a ServiceAccount with minimal Role for ConfigMap access.
- **HelmRelease boilerplate**: `interval: 30m`, rollback strategy, `maxHistory: 1`, remediation retries. See `kubernetes/templates/yaml-templates/helmrelease.tmpl`.
- **chartRef vs chart.spec**: Newer HelmReleases use `spec.chartRef` (OCIRepository); older ones use `spec.chart.spec` (HelmRepository). Both work.
- **ConfigMapGenerator**: Uses `disableNameSuffixHash: true` for stable names. Often paired with `generatorOptions.annotations` for Flux substitution.

## Core Infrastructure

| Component | Purpose |
|---|---|
| **Flux CD** (Flux Operator) | GitOps reconciliation from this repo |
| **Traefik** | Ingress controller, reverse proxy |
| **Cilium** | CNI (eBPF), replaces kube-proxy + flannel |
| **MetalLB** | BGP-based LoadBalancer IP assignment |
| **cert-manager** | TLS certificates (Let's Encrypt) |
| **External-Secrets** | Secrets from GitLab CI/CD variables |
| **CloudNative-PG** | PostgreSQL operator + clusters |
| **Dragonfly** | Redis-compatible in-memory store |
| **Longhorn** | Distributed block storage |
| **VictoriaMetrics** | Metrics (Prometheus-compatible) |
| **VictoriaLogs** + Fluent Bit | Log aggregation |
| **Grafana** (operator) | Dashboards |
| **Blocky** | Primary DNS (daemonset) |
| **external-dns** | Syncs ingress to Cloudflare DNS |
| **system-upgrade-controller** | Automated k3s rolling updates |
| **Reloader** | Restarts pods on ConfigMap/Secret changes |

## Networking

- **Cluster**: k3s with Cilium CNI, MetalLB for LoadBalancer
- **Ingress**: Traefik at `192.168.10.20`
- **DNS**: Blocky (primary, `192.168.10.22`), AdGuard Home (secondary, LXC)
- **Domain**: `*.local.${SECRET_DOMAIN}` for internal services
- Key CIDRs: Secure `192.168.2.0/24`, LB `192.168.10.0/24`, Pods `10.42.0.0/16`, Services `10.43.0.0/16`

## Renovate

Automated dependency management with modular config in `.github/renovate/`:
- **Semantic commits**: `chore(container)`, `fix(helm)`, `feat(...)` format
- **Auto-merge**: Digest updates for specific containers, some chart updates
- **Custom managers**: Regex-based detection for Helm, Docker, GitHub releases, Grafana dashboards
- **Special versioning**: k3s (`+k3s1` suffix), CNPG images (`-trixie` suffix), date-based versions

## Cluster Access

SSH into nodes directly via the secure subnet. Nodes 11–15:

```
ssh <user>@192.168.2.11   # node 1
ssh <user>@192.168.2.12   # node 2
ssh <user>@192.168.2.13   # node 3
ssh <user>@192.168.2.14   # node 4
ssh <user>@192.168.2.15   # node 5
```

(`<user>` is the local admin account — not committed here for privacy.)

## Common Tasks

### Checking etcd fragmentation

Port-forward to VictoriaMetrics and query the two key metrics:

```bash
kubectl port-forward svc/vmsingle-victoria-metrics-k8s-stack 8428:8428 -n monitoring &
sleep 3

curl -s "http://localhost:8428/api/v1/query" \
  --data-urlencode "query=etcd_mvcc_db_total_size_in_bytes" > /tmp/etcd_total.json
curl -s "http://localhost:8428/api/v1/query" \
  --data-urlencode "query=etcd_mvcc_db_total_size_in_use_in_bytes" > /tmp/etcd_inuse.json

kill %1

python3 << 'EOF'
import json
total_data = json.load(open('/tmp/etcd_total.json'))
inuse_data = json.load(open('/tmp/etcd_inuse.json'))
inuse_map = {r['metric']['instance']: float(r['value'][1]) for r in inuse_data['data']['result']}
print(f"{'Instance':<22} {'Total':>10} {'In-Use':>10} {'Fragment':>10} {'Frag%':>7}")
print("-" * 65)
for r in sorted(total_data['data']['result'], key=lambda x: x['metric']['instance']):
    inst = r['metric']['instance']
    total = float(r['value'][1])
    inuse = inuse_map.get(inst, 0)
    frag = total - inuse
    pct = (frag / total * 100) if total > 0 else 0
    print(f"{inst:<22} {total/1024/1024:>9.1f}M {inuse/1024/1024:>9.1f}M {frag/1024/1024:>9.1f}M {pct:>6.1f}%")
EOF
```

**What to look for**: Fragmentation (absolute bytes) is the defrag trigger — threshold is **50 MB**. Fragmentation % of 40–50% is normal mid-cycle; it spikes before the nightly defrag (23:30 CT) and drops immediately after. The `etcd-defrag` CronJob in `kube-system` handles this automatically.

### Finding an app's config
```
kubernetes/apps/<namespace>/<app-name>/app/helmrelease.yaml
```

### Finding what secrets an app uses
Check `kubernetes/apps/<namespace>/<app-name>/app/externalsecret.yaml` — the `remoteRef.key` values are GitLab CI/CD variable names.

### Checking Flux variable substitution
Global vars: `kubernetes/flux/vars/cluster-settings.yaml`  
Per-app vars: the `postBuild.substitute` section in the app's `ks.yaml`

### Understanding dependencies
Check `spec.dependsOn` in `ks.yaml` files. Common chain: `external-secrets` -> `external-secrets-stores` -> apps that use secrets.

## Commit Conventions

- Semantic commits: `type(scope): message`
- Types: `feat`, `fix`, `chore`, `docs`
- Scope is usually the app name or category
- Recent examples from git log: `fix(grafana): ...`
