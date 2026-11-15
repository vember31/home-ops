# EpicGames Free

Runs [`claabs/epicgames-freegames-node`](https://github.com/claabs/epicgames-freegames-node) as a CronJob four times a day to claim free Epic Games titles.

## Storage

The HelmRelease creates the `epicgames-config-v2` Longhorn PVC (256 MiB) and mounts it at `/usr/app/config`.

| Path | Approx. size | Keep? |
|---|---|---|
| `config.json` | 0 B | No. The real config is the ExternalSecret mounted at the same path via `subPath`, which shadows this file. |
| `device-auths.json` | <1 KiB | Yes. Epic device-auth tokens. Deleting it forces a device-code login. |
| `users/<account>/` | ~142 MiB | Yes, but mostly disposable. This is the Chromium profile that holds the Epic session cookies. The cookies/login state are a few MB; the rest is Chrome cache and components. |

Do **not** replace the whole PVC with `emptyDir`. The browser profile is what keeps the account logged in, and wiping it causes device-code login prompts. Clearing only the cache subdirectories (`Default/Cache`, `Default/Code Cache`, `Default/Service Worker/CacheStorage`, `component_crx_cache`, etc.) is safe if the footprint needs shrinking.

## Longhorn actual-size warning

`LonghornVolumeActualSpaceUsedWarning` (defined in `kubernetes/apps/storage/longhorn/app/prometheusrule.yaml`) fires when `longhorn_volume_actual_size_bytes / longhorn_volume_capacity_bytes` stays above 90% for five minutes.

Longhorn reports allocated blocks, not filesystem usage. Chromium constantly writes and deletes cache files; the deleted blocks are not returned to Longhorn until the filesystem is trimmed. On 2026-11-14 the volume reached 230.5 MiB / 256 MiB (90%) while `du` showed only ~142 MiB of files, and it was growing by roughly 3 MiB/day.

The nightly `filesystem-trim` RecurringJob does **not** cover this volume: the CronJob pod only mounts the PVC for about a minute per run, and Longhorn's trim requires the volume to be attached and mounted. In Longhorn 1.13.0:

- `allow-recurring-job-while-volume-detached` only auto-attaches volumes for snapshot/backup jobs. For trim it would select the detached volume and then fail with `volume is not attached` (`VolumeManager.TrimFilesystem` requires `Status.State == Attached`).
- The `filesystem-trim` job at 07:00 UTC therefore skips this volume every day.

## Manual trim

Run this between app runs. The PVC is `ReadWriteOnce`, so don't run it while the CronJob is active. The pod attaches the volume temporarily; deleting the pod detaches it again.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pvc-trim
  namespace: games
spec:
  restartPolicy: Never
  containers:
    - name: trim
      image: ghcr.io/claabs/epicgames-freegames-node:latest
      command: ["sh", "-c", "fstrim -v /usr/app/config"]
      securityContext:
        capabilities:
          add: ["SYS_ADMIN"]
      volumeMounts:
        - name: config
          mountPath: /usr/app/config
  volumes:
    - name: config
      persistentVolumeClaim:
        claimName: epicgames-config-v2
```

```bash
kubectl apply -f pvc-trim.yaml
kubectl -n games wait --for=jsonpath='{.status.phase}'=Succeeded pod/pvc-trim --timeout=180s
kubectl -n games logs pvc-trim      # e.g. "/usr/app/config: 81.5 MiB (85487616 bytes) trimmed"
kubectl -n games delete pod pvc-trim
```

`FITRIM` requires `CAP_SYS_ADMIN`, which Kubernetes containers do not get by default. Without it the command fails with:

```text
fstrim: /usr/app/config: FITRIM ioctl failed: Operation not permitted
```

Check the result (Longhorn updates the metric asynchronously, so allow a scrape interval for the alert to clear):

```bash
VOL=pvc-a11e7765-7f01-4e80-b2af-872f791679e0
kubectl -n storage get volumes.longhorn.io "$VOL" -o jsonpath='{.status.actualSize}{"\n"}' |
  awk '{ printf "%.1f MiB\n", $1 / 1048576 }'
```

## Optional: automated trim

To make this automatic without resizing the PVC, add a small CronJob that mounts the PVC, runs `fstrim`, and exits. Schedule it in the gap between app runs (for example `05:00` UTC), and keep `SYS_ADMIN` on this short-lived pod rather than on the internet-facing app container.

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: epicgames-trim
  namespace: games
spec:
  schedule: "0 5 * * *"
  timeZone: Etc/UTC
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      backoffLimit: 0
      activeDeadlineSeconds: 1800
      template:
        spec:
          restartPolicy: Never
          automountServiceAccountToken: false
          containers:
            - name: trim
              image: ghcr.io/claabs/epicgames-freegames-node:latest
              command: ["sh", "-c", "fstrim -v /usr/app/config"]
              securityContext:
                capabilities:
                  add: ["SYS_ADMIN"]
              volumeMounts:
                - name: config
                  mountPath: /usr/app/config
          volumes:
            - name: config
              persistentVolumeClaim:
                claimName: epicgames-config-v2
```

Alternatively, `persistence.config.size` in the HelmRelease can be increased (Longhorn supports online expansion) if maintaining the trim job is not desirable.
