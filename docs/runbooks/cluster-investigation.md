# Cluster Investigation Runbook

Queries and patterns for debugging outages in this cluster. All times are UTC unless noted.

---

## Tooling quick-start

Port-forward to observability services before querying:

```bash
# VictoriaLogs (logs)
kubectl port-forward svc/victoria-logs-server 9428:9428 -n monitoring &

# VictoriaMetrics (metrics)
kubectl port-forward svc/vmsingle-victoria-metrics-k8s-stack 8428:8428 -n monitoring &
```

---

## 1. App went down — find why

### Get pod logs from VictoriaLogs around an incident

Replace `<namespace>` and `<app>` with the target. Times are UTC; convert from CT by adding 5h (CDT) or 6h (CST).

```bash
curl -s 'http://localhost:9428/select/logsql/query' \
  -d 'query=kubernetes.pod_namespace:<namespace> AND kubernetes.pod_name:~"<app>.*"&start=<ISO_UTC>&end=<ISO_UTC>&limit=500' | \
  while IFS= read -r line; do
    echo "$line" | python3 -c "
import sys, json
l = sys.stdin.read().strip()
if l:
    try:
        d = json.loads(l)
        print(d.get('_time','')[:23], d.get('kubernetes.pod_name',''), d.get('_msg','')[:150])
    except: pass
"
  done | sort
```

### Check pod restart history

```bash
kubectl get pods -n <namespace> -o wide
kubectl describe pod -n <namespace> <pod> | grep -A 20 "Events:"
```

### Check for errors in app logs specifically

```bash
curl -s 'http://localhost:9428/select/logsql/query' \
  -d 'query=kubernetes.pod_namespace:<namespace> AND level:error&start=<ISO_UTC>&end=<ISO_UTC>&limit=200'
```

---

## 2. Redis / Dragonfly issues

Outline and other apps use Dragonfly at `dragonfly.database.svc.cluster.local:6379`.

**Symptoms**: `connect ETIMEDOUT`, `Redis error`, `Retrying redis connection` in app logs.

### Check which node Dragonfly pods are on

```bash
kubectl get pods -n database -l app.kubernetes.io/name=dragonfly -o wide
```

### Check Dragonfly logs

```bash
curl -s 'http://localhost:9428/select/logsql/query' \
  -d 'query=kubernetes.pod_namespace:database AND kubernetes.pod_name:~"dragonfly-[012]"&start=<ISO_UTC>&end=<ISO_UTC>&limit=200'
```

**What to look for**: `OnIdle tasks are taking too long` warnings (sign of I/O pressure on the node). A Redis ETIMEDOUT on a healthy Dragonfly pod usually means a network disruption rather than Dragonfly itself crashing.

### Check Dragonfly restart counts

```bash
kubectl get pods -n database | grep dragonfly
# restarts > 0 means it crashed
```

---

## 3. etcd health (most impactful thing to check first)

etcd WAL fsync latency is the single best signal for "why is the cluster acting weird." Slow etcd → slow API server → cascading failures (leader election losses, Cilium disruptions, etc.).

**Normal**: p99 < 10ms. **Degraded**: 10–25ms. **Critical**: > 25ms.

### Query etcd WAL fsync latency

```bash
curl -s "http://localhost:8428/api/v1/query_range" \
  --data-urlencode 'query=histogram_quantile(0.99, rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m])) * 1000' \
  --data-urlencode 'start=<ISO_UTC>' \
  --data-urlencode 'end=<ISO_UTC>' \
  --data-urlencode 'step=60s' | python3 -c "
import sys, json, datetime
d = json.load(sys.stdin)
from collections import defaultdict
data = defaultdict(dict)
for r in d.get('data',{}).get('result',[]):
    inst = r['metric'].get('instance','?').replace(':2381','')
    for ts, val in r.get('values',[]):
        dt = datetime.datetime.utcfromtimestamp(float(ts)).strftime('%H:%M')
        v = float(val) if val != 'NaN' else 0
        data[dt][inst] = v
nodes = ['192.168.2.11','192.168.2.12','192.168.2.13','192.168.2.14','192.168.2.15']
labels = ['node1','node2','node3','node4','node5']
print('Time   ' + '  '.join(f'{l:>8}' for l in labels))
for dt in sorted(data.keys()):
    row = data[dt]
    vals = [row.get(n,0) for n in nodes]
    flag = ' ***' if max(vals) > 25 else ''
    print(f'{dt}  ' + '  '.join(f'{v:>8.1f}' for v in vals) + flag)
"
```

### Incident pattern (2026-05-01)

etcd WAL fsync spiked to **184–198ms** on node1 and node2 at ~06:44 UTC, and again to **109–116ms** at ~07:02 UTC. This caused:
- CNPG operator on node5 to fail leader election (`context deadline exceeded` on K8s API)
- Cilium network disruption → Outline's Redis connections timed out (ETIMEDOUT)
- Both incidents lasted ~5 minutes; Outline auto-recovered within ~1 minute

The spikes only hit node1 and node2, suggesting the cause was something at the **Proxmox/hypervisor layer** (e.g. VM storage snapshots). Check the Proxmox backup schedule if this recurs — two spikes ~19 minutes apart is a strong hint of a periodic background operation.

---

## 4. Node I/O health

### CPU iowait — all nodes over a time range

```bash
curl -s "http://localhost:8428/api/v1/query_range" \
  --data-urlencode 'query=avg by (instance) (rate(node_cpu_seconds_total{mode="iowait"}[5m])) * 100' \
  --data-urlencode 'start=<ISO_UTC>' \
  --data-urlencode 'end=<ISO_UTC>' \
  --data-urlencode 'step=60s' | python3 -c "
import sys, json, datetime
d = json.load(sys.stdin)
from collections import defaultdict
data = defaultdict(dict)
for r in d.get('data',{}).get('result',[]):
    inst = r['metric'].get('instance','?').replace(':9100','')
    for ts, val in r.get('values',[]):
        dt = datetime.datetime.utcfromtimestamp(float(ts)).strftime('%H:%M')
        data[dt][inst] = float(val)
nodes = ['192.168.2.11','192.168.2.12','192.168.2.13','192.168.2.14','192.168.2.15']
labels = ['node1','node2','node3','node4','node5']
print('Time   ' + '  '.join(f'{l:>8}' for l in labels))
for dt in sorted(data.keys()):
    row = data[dt]
    vals = [row.get(n,0) for n in nodes]
    if any(v > 5 for v in vals):
        flag = ' ***' if max(vals) > 40 else ''
        print(f'{dt}  ' + '  '.join(f'{v:>8.1f}' for v in vals) + flag)
"
```

**Baseline as of 2026-05-01**: node3 (~29%) and node4 (~43%) are chronically elevated — likely Longhorn replication. This is a known issue, not a new incident signal. Spikes *above* that baseline are the signal to watch.

### Node memory

```bash
curl -s "http://localhost:8428/api/v1/query_range" \
  --data-urlencode 'query=node_memory_MemAvailable_bytes{instance="192.168.2.1X:9100"} / node_memory_MemTotal_bytes{instance="192.168.2.1X:9100"} * 100' \
  --data-urlencode 'start=<ISO_UTC>' --data-urlencode 'end=<ISO_UTC>' --data-urlencode 'step=60s'
```

### Check when a node last rebooted

```bash
curl -s "http://localhost:8428/api/v1/query" \
  --data-urlencode 'query=node_boot_time_seconds' | python3 -c "
import sys, json, datetime
d = json.load(sys.stdin)
for r in d.get('data',{}).get('result',[]):
    inst = r['metric'].get('instance','?')
    ts = float(r['value'][1])
    dt = datetime.datetime.utcfromtimestamp(ts)
    print(f'{inst}: last booted {dt} UTC')
"
```

---

## 5. Kubernetes API server health

### 5xx error rate

```bash
curl -s "http://localhost:8428/api/v1/query_range" \
  --data-urlencode 'query=rate(apiserver_request_total{code=~"5.."}[5m])' \
  --data-urlencode 'start=<ISO_UTC>' --data-urlencode 'end=<ISO_UTC>' --data-urlencode 'step=60s'
```

### CNPG leader election loss

If CNPG is restarting, look for this in its logs — it means the K8s API was unreachable:

```bash
curl -s 'http://localhost:9428/select/logsql/query' \
  -d 'query=kubernetes.pod_namespace:database AND kubernetes.pod_name:~"cloudnative-pg.*"&start=<ISO_UTC>&end=<ISO_UTC>&limit=100' | \
  grep -E 'leader election|lease|deadline'
```

---

## 6. Flux reconciliation activity

Check whether a Helm upgrade was happening around the incident time:

```bash
curl -s 'http://localhost:9428/select/logsql/query' \
  -d 'query=kubernetes.pod_namespace:flux-system AND kubernetes.pod_name:~"helm-controller.*"&start=<ISO_UTC>&end=<ISO_UTC>&limit=300' | \
  grep -iE '"upgrade|install|uninstall|failed|error"'
```

---

## 7. Node → pod mapping

| Node | IP | Typical workloads |
|---|---|---|
| k3s-control1 | 192.168.2.11 | etcd, control plane |
| k3s-control2 | 192.168.2.12 | etcd, control plane |
| k3s-control3 | 192.168.2.13 | etcd, control plane, Longhorn |
| k3s-control4 | 192.168.2.14 | etcd, Dragonfly-1 |
| k3s-control5 | 192.168.2.15 | etcd, CNPG operator |

etcd ports: `:2381` (metrics), `:2379` (client), `:2380` (peer)  
node-exporter: `:9100`

---

## 8. VictoriaLogs field reference

Key fields in log entries from Fluent Bit:

| Field | Example |
|---|---|
| `kubernetes.pod_name` | `outline-7b9f5cb549-ccmw8` |
| `kubernetes.pod_namespace` | `home` |
| `kubernetes.host` | `k3s-control4` |
| `kubernetes.container_name` | `app` |
| `_time` | `2026-05-01T07:00:25.379Z` |
| `_msg` | the log line |

LogsQL syntax: `field:value`, `field:~"regex"`, `AND`, `OR`, `level:error`
