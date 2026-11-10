# ser2net radio gateway (`pve`)

The Zigbee (ZBT-2) and Z-Wave (ZWA-2) radios stay on the Proxmox host and are exposed to the cluster over TCP serial:

| Port | Radio | Consumer |
|---:|---|---|
| 4001 | Home Assistant Connect ZBT-2 | ZHA → `socket://192.168.2.3:4001` |
| 4002 | Home Assistant Connect ZWA-2 | Z-Wave JS UI → `tcp://192.168.2.3:4002` |

The config in this directory is versioned so the host-side change is reviewable, but `pve` is not reconciled by Flux. Apply it manually:

```bash
# Run from the repo root. Install the package before copying the config so the
# package's default /etc/ser2net.yaml does not overwrite it.
ssh root@192.168.2.3 'apt-get update && apt-get install -y ser2net'
scp configs/ser2net/ser2net.yaml root@192.168.2.3:/etc/ser2net.yaml
ssh root@192.168.2.3 '
  systemctl enable --now ser2net
  systemctl status ser2net --no-pager
  ss -tlnp | grep -E "4001|4002"
'
```

Restrict the ports to the secure LAN and do not expose them to the WAN or Wi-Fi/VPN:

```bash
nft add rule inet filter input tcp dport { 4001, 4002 } ip saddr 192.168.2.0/24 accept
nft add rule inet filter input tcp dport { 4001, 4002 } drop
```

Verify the by-id paths after detaching the USB devices from HAOS VM 300:

```bash
ls -l /dev/serial/by-id/
```

If the paths differ, update this file (and the runbook) before applying. Do not use `/dev/ttyACM0`; it can change.

The full migration context is in `docs/runbooks/home-assistant-kubernetes-migration.md` §6.8.
