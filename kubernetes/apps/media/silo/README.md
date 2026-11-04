# Silo

Silo media server plus a GPU transcode node pinned to `k3s-gpu-worker`.

## What this deploys

- `silo` Deployment in the `media` namespace
  - Web/API on `8080`
  - Jellyfin-compatible listener on `8096`
  - Metrics on `9091`
  - Local artwork, plugins, and compatibility assets on the `silo-config` Longhorn PVC
- `transcode` Deployment pinned to `k3s-gpu-worker`
  - `MODE=transcode`
  - `NODE_NAME=gpu-worker`
  - `NODE_URL=http://silo-transcode.media.svc.cluster.local:8080`
  - `/dev/dri` mounted from the host
  - Supplemental groups `44` (video) and `992` (render)

Both workloads use the existing CNPG `postgres-18` cluster and Dragonfly. The
database `silo` and the `vector`, `pg_trgm`, and `citext` extensions are created
by the `postgres-init` init container.

## Before Flux applies this

Create a GitLab CI/CD variable named **`silo`** whose value is a JSON object:

```json
{
  "SILO_POSTGRES_USER": "silo",
  "SILO_POSTGRES_PASS": "replace-with-openssl-rand-hex-24",
  "SILO_SECRET_KEY": "replace-with-openssl-rand-base64-48"
}
```

Generate a single-line JSON value for the GitLab variable with:

```bash
printf '{"SILO_POSTGRES_USER":"silo","SILO_POSTGRES_PASS":"%s","SILO_SECRET_KEY":"%s"}\n' \
  "$(openssl rand -hex 24)" "$(openssl rand -base64 48 | tr -d '\n')"
```

The existing `gitlab-secret-store` reads variables from the "All environments"
scope, so the variable does not need an environment scope. Use a single-line
JSON value if you want GitLab to allow masking the variable. Keep
`SILO_SECRET_KEY` backed up separately from database backups. Silo cannot start
on an existing database without it.

The existing `cloudnativepg` variable supplies `POSTGRES_SUPER_PASS` for the
init container.

## After the first reconcile

1. Open `https://silo.local.${SECRET_DOMAIN}` and create the admin account.
2. Add libraries using the mounted paths:
   - `/media/movies`
   - `/media/tv`
   - `/media/videos`
   - `/media/recordings`
   - `/media/books`
   - `/media2/movies`
   - `/media2/tv`
3. Open **Admin → Playback → Nodes** and add a **Transcode** node:
   - **Name:** `gpu-worker`
   - **URL:** `http://silo-transcode.media.svc.cluster.local:8080`
   - **Group:** leave blank unless more nodes are added
   - **Max Transcodes:** `2` (or whatever your iGPU handles reliably)
4. Set the node’s **Hardware Acceleration** to **Auto**. It should report
   **VA-API** on `/dev/dri/renderD128`.
5. Under **Routing**, choose **GPU offload** so direct play and remuxing stay on
   the main server and video transcodes go to `gpu-worker`.
6. Play something that needs conversion and check **Admin → Activity** for
   `HW VAAPI`. The node’s **Acceleration** block should show **VAAPI** in green.

## CPU fallback

The `silo` server runs in the default `integrated` mode and has no `/dev/dri`,
so its own transcodes use software (CPU) encoding. It is the fallback when the
GPU node is unavailable.

- With **Routing → GPU offload**, video transcodes prefer a healthy transcode
  node, but the main server remains a legal candidate. Routes ending in
  “only” never fall back, so don’t use those if you want CPU fallback.
- Set the node’s **Max Transcodes** to the number of simultaneous GPU jobs you
  want (for example `2`). Without a cap, Silo keeps sending new work to a
  busy-but-healthy node instead of falling back.
- If the node is unhealthy, draining, at its job cap, or rejected by the
  planner, new work goes to the main server. If it crashes mid-stream, Silo
  moves playback to the main server or another node, usually within about 10
  seconds.
- The main server’s hardware acceleration setting should stay on **Auto**; it
  will report **SW** because there is no GPU in that pod.
- CPU fallback is best-effort. A 4K transcode may not keep up on the server’s
  CPU, and the server has a 6 GiB memory limit.

## GPU access

The iGPU is passed through to VM 405 and appears on `k3s-gpu-worker` as:

```text
/dev/dri/card0        root:video   (gid 44)
/dev/dri/card1        root:video   (gid 44)
/dev/dri/renderD128   root:render  (gid 992)
```

The transcode pod runs as UID/GID `1000` with supplemental groups `44` and
`992`. No Intel device plugin or DRA driver is required for this single GPU.

## Scratch space

The GPU worker’s disk was expanded to 128 GiB on 2026-11-04 (about 109 GiB free
in the guest). Longhorn reports roughly 108 GiB available on the same disk. The
transcode scratch and prepared-download directory still share a 10 GiB
`emptyDir` at `/tmp` for the initial rollout. That is deliberately conservative;
once 4K transcoding is tested, `transcode-tmp` can be raised (for example to
`40Gi`). Note that the Node object may keep reporting the old 30 GiB
`ephemeral-storage` capacity until kubelet refreshes it, so don’t raise the
limit until `kubectl get node k3s-gpu-worker` reflects the new disk. A dedicated
disk remains the cleaner long-term option if Longhorn and transcode scratch
start competing for space.

Chapter thumbnails are intentionally left off because the transcode node does
not share the server’s artwork PVC. If they are needed later, move artwork to
S3 or a shared RWX volume first.

## Updates

Update the transcode node before the server when a Silo release says the node
protocol changed. Both workloads currently use the same `latest` image pinned by
digest (`sha256:c7b19fe…`).

Before updating, take a CNPG backup and remember that database migrations cannot
be rolled back by reverting the image.

## Verification

```bash
kubectl -n media get pods -l app.kubernetes.io/instance=silo -o wide
kubectl -n media logs deploy/silo -f
kubectl -n media logs deploy/silo-transcode -f
kubectl -n media get pvc silo-config
```

On `k3s-gpu-worker`, confirm the device is still present:

```bash
ssh duke@192.168.2.15 'ls -ln /dev/dri; LIBVA_DRIVER_NAME=iHD vainfo --display drm --device /dev/dri/renderD128 | head'
```

## Notes

- The server is pinned away from `k3s-gpu-worker` so it remains the CPU
  fallback; it can schedule on control-plane nodes.
- Media is mounted read-only at `/media` and `/media2`.
- The `silo-config` PVC holds local artwork, plugins, uploads, downloaded
  subtitles, and Jellyfin compatibility assets. Back it up with the database.
- `SILO_TRUSTED_PROXIES` is set to the pod CIDR so Traefik can supply the real
  client address.
- The Jellyfin-compatible listener is exposed at
  `https://silo-jf.local.${SECRET_DOMAIN}`.
- Both hostnames are internal-only; no external ingress is configured.
