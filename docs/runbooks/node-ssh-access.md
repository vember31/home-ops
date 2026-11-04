# Node SSH Access

How to restore SSH key auth on the k3s nodes after a VM rebuild.

**Last updated:** 2026-11-04

## Node / user / Proxmox mapping

| Node | IP | SSH user | Proxmox host | VMID |
|---|---|---:|---|---:|
| `k3s-control1` | `192.168.2.11` | `duke` | `192.168.2.3` (`pve`) | 401 |
| `k3s-worker4` | `192.168.2.12` | `duke` | `192.168.2.3` (`pve`) | 402 |
| `k3s-control3` | `192.168.2.13` | `duke` | `192.168.2.10` (`pve2`) | 403 |
| `k3s-control4` | `192.168.2.14` | `duke` | `192.168.2.2` (`pve3`) | 404 |
| `k3s-gpu-worker` | `192.168.2.15` | `duke` | `192.168.2.18` (`pve4`) | 405 |
| `k3s-worker1` | `192.168.2.51` | `duke` | `192.168.2.20` (`pve5`) | 100 |
| `k3s-worker2` | `192.168.2.52` | `duke` | `192.168.2.21` (`pve6`) | 101 |
| `k3s-worker3` | `192.168.2.53` | `duke` | `192.168.2.22` (`pve7`) | 102 |

The GPU worker was originally built with the cloud-init `ubuntu` user. It now has
`duke` (UID/GID 1001) and uses the same password as the other nodes. `ubuntu`
remains only as the UID 1000 service account used by container workloads; its
login, sudo access, and `authorized_keys` are disabled.

## Script

`scripts/fix-node-ssh-keys.sh` makes every selected node accept the local default
SSH keys (`~/.ssh/id_ed25519` and `~/.ssh/id_rsa`, if present). It is idempotent
and only appends missing keys.

```bash
# Show what would change
./scripts/fix-node-ssh-keys.sh --dry-run

# Apply to all nodes
./scripts/fix-node-ssh-keys.sh

# Just one node
./scripts/fix-node-ssh-keys.sh --node k3s-gpu-worker

# Use a specific key, or add another key to every node
./scripts/fix-node-ssh-keys.sh --key ~/.ssh/id_ed25519

# After a VM rebuild (new SSH host key)
./scripts/fix-node-ssh-keys.sh --reset-known-hosts

# List the configured mapping
./scripts/fix-node-ssh-keys.sh --list
```

Install order for a missing key:

1. Use a key that already works on that node.
2. If no local key works, ask the Proxmox guest agent (root SSH to the PVE host)
   to append the key. This is the normal recovery path after a cloud-image
   rebuild, where the old login user or keys are gone.
3. Fall back to `ssh-copy-id` and prompt for the node password.

`--ssh-only` disables the Proxmox guest-agent fallback. Set `SSHPASS` to let
`ssh-copy-id` use `sshpass` non-interactively.

## After rebuilding a VM

1. Confirm the VM's Proxmox host, VMID, and IP still match the table above.
2. If the rebuild used the Ubuntu cloud image, either set the Proxmox cloud-init
   user to `duke` and add the workstation keys, or create `duke` first:

   ```bash
   # Via the Proxmox guest agent, as root on the PVE host:
   qm guest exec <vmid> -- /bin/bash -c \
     'useradd -m -U -s /bin/bash -c "Duke Miller" -G sudo,adm,cdrom,dip,plugdev,lxd,video,render duke'
   ```

   On a fresh Ubuntu cloud image, also move the cloud-init sudoers rule aside
   after verifying `duke`, so sudo uses the normal password-protected `sudo`
   group instead of cloud-init's `NOPASSWD` rule:

   ```bash
   mv /etc/sudoers.d/90-cloud-init-users \
      /etc/sudoers.d/90-cloud-init-users.disabled-$(date +%Y%m%d)
   ```

3. Set the password. The usual approach is to copy the password hash from
   `k3s-control1` so the new node matches the rest of the cluster. This runs
   through the Proxmox guest agent and does not require the plaintext password:

   ```bash
   # Run from the workstation; do not echo the hash.
   src_json=$(ssh root@192.168.2.3 \
     "qm guest exec 401 -- /bin/bash -c 'getent shadow duke | cut -d: -f2'")
   hash=$(printf '%s' "$src_json" | jq -r '."out-data"' | tr -d '\n')
   printf '%s\n%s\n' "$hash" "$hash" | \
     ssh root@<pve-host> 'qm guest passwd <vmid> duke --crypted 1'
   ```

4. Run `./scripts/fix-node-ssh-keys.sh --node <name>` and verify:

   ```bash
   ssh -o BatchMode=yes duke@192.168.2.15 'hostname; id -un'
   ```

## Troubleshooting

- **`Host key verification failed` / `REMOTE HOST IDENTIFICATION HAS CHANGED`**
  The rebuilt guest has a new host key. After confirming the IP belongs to the
  expected VM, run the script with `--reset-known-hosts`.
- **`Not allowed at this time` / `kex_exchange_identification`**
  Ubuntu 26.04 enables sshd per-source penalties. Repeated failed key probes can
  temporarily rate-limit the workstation. The script detects this and waits
  before retrying verification. If running manually, wait ~30 seconds.
- **`Permission denied (publickey,password)`**
  The node may still be using a different login user (for example `ubuntu` on a
  fresh cloud image) or the key was not appended. Check the mapping with
  `--list` and inspect the node through the Proxmox guest agent.
