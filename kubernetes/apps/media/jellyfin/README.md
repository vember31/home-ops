# Jellyfin + Jellarr

Jellyfin 12.1 restored from `.archive`, with server configuration managed
declaratively by [jellarr](https://github.com/venkyr77/jellarr) and user
sign-in via Pocket ID OIDC through the
[Jellyfin Security](https://github.com/ZL154/JellyfinSecurity) plugin.

> **Status: disabled.** `kubernetes/apps/media/kustomization.yaml` has
> `# - ./jellyfin/ks.yaml` commented out, so none of this deploys yet. The
> `jellyfin-users` Pocket ID group does deploy already (it lives in the
> `pocket-id-groups` Kustomization) — that is harmless and just means the
> group is ready when Jellyfin is enabled.

## Layout

| Path | Purpose |
| --- | --- |
| `ks.yaml` | Flux Kustomizations: `jellyfin` and `jellarr` (plex-auto-languages style) |
| `app/` | Jellyfin HelmRelease (12.1, CPU-only, NFS media mounts, gatus/homepage) |
| `app/oidc/pocket-id-oidc-client.yaml` | `PocketIDOIDCClient` — creates the Pocket ID client and the `jellyfin-oidc-credentials` Secret |
| `jellarr/` | jellarr CronJob, ExternalSecret, and config |
| `jellarr/config/config.yml` | Everything jellarr manages (system, libraries, plugins) |
| `jellarr/config/render_config.py` | Init-container script that injects the Pocket ID client id/secret into the config at pod start |

## Bootstrap checklist

### 1. Enable the app

Uncomment the line in `kubernetes/apps/media/kustomization.yaml`:

```yaml
  - ./jellyfin/ks.yaml
```

Commit and push. Then watch it come up:

```bash
flux reconcile kustomization cluster-apps --with-source
kubectl -n media rollout status deploy/jellyfin --timeout=10m
```

This creates: the Jellyfin HelmRelease (fresh 10Gi `jellyfin-config` PVC — the
old data is gone), the Pocket ID OIDC client, and the jellarr app (CronJob
starts **suspended** on purpose).

### 2. First boot of Jellyfin

Open `https://jellyfin.local.${SECRET_DOMAIN}` and complete the setup wizard:

1. Create the admin account (this must be done by hand — jellarr intentionally
   does not skip the wizard or create users).
2. **Dashboard → API Keys → create a key named `jellarr`.** Copy it.
3. Optional: create a second key for the Homepage dashboard widget — or just
   reuse the `jellarr` key (API keys are not user-bound).

### 3. Prep the GitLab secrets

The cluster's ExternalSecrets read from GitLab through the
`gitlab-secret-store` ClusterSecretStore. Jellyfin's variables live in the
existing **`jellyfin`** CI/CD variable group (Homepage's ExternalSecret already
extracts from it). In GitLab → group → **Settings → CI/CD → Variables**, add /
refresh:

| Variable | Value | Notes |
| --- | --- | --- |
| `JELLARR_API_KEY` | the `jellarr` API key from step 2 | Mask it. Consumed as `{{ .JELLARR_API_KEY }}` by `jellarr/externalsecret.yaml` |
| `HOMEPAGE_VAR_JELLYFIN_TOKEN` | a valid Jellyfin API key | Mask it. Same key as above is fine. The old value is dead because the old server's data (and its API keys) no longer exists, which is why the Homepage Jellyfin widget is currently broken |

Notes:

- Only the *values* live in GitLab — nothing secret is committed to the repo.
- Homepage reads its token at container start, but the deployment has
  `reloader.stakater.com/auto: "true"`, so it restarts automatically once the
  synced `homepage-secret` changes. No manual restart needed.
- If you prefer separate keys for easier rotation, name the second one
  `homepage` in Jellyfin and put its value in `HOMEPAGE_VAR_JELLYFIN_TOKEN`.

Then force an External Secrets sync and confirm the secrets exist:

```bash
kubectl -n media annotate externalsecret jellarr force-sync=$(date +%s) --overwrite
kubectl -n media get externalsecret jellarr          # SecretSynced
kubectl -n media get secret jellarr-secret           # JELLARR_API_KEY
kubectl -n media get secret jellyfin-oidc-credentials # client_id, client_secret, issuer_url
```

If `jellyfin-oidc-credentials` is missing, the Pocket ID operator hasn't
reconciled the OIDC client yet — check `kubectl -n media get pocketidoidcclient jellyfin`.

### 4. Unsuspend jellarr

In `kubernetes/apps/media/jellyfin/jellarr/helmrelease.yaml`, change
`suspend: true` → `false` (there's a TODO comment marking it), commit, push.

```bash
kubectl -n media get cronjob jellarr -o jsonpath='{.spec.suspend}{"\n"}'  # false
```

### 5. First run — install plugins

```bash
kubectl -n media create job --from=cronjob/jellarr jellarr-bootstrap-1
kubectl -n media logs -f job/jellarr-bootstrap-1
```

Expected: system settings applied, four libraries created (Movies, TV Shows,
Videos, Recordings), Intro Skipper and Jellyfin Security installed. The plugin
**configs** may not apply yet if Jellyfin hasn't loaded the plugins.

### 6. Restart Jellyfin so the plugins load

```bash
kubectl -n media rollout restart deploy/jellyfin
kubectl -n media rollout status deploy/jellyfin
```

### 7. Second run — configure plugins + OIDC

```bash
kubectl -n media create job --from=cronjob/jellarr jellarr-bootstrap-2
kubectl -n media logs -f job/jellarr-bootstrap-2
```

Expected: `Updating plugin configuration: Jellyfin Security` (and Intro
Skipper if it has settings). After this, the OIDC provider is live.

### 8. Verify OIDC

- The Jellyfin login page should show a **"Sign in with Pocket ID"** button.
- Sign in as a Pocket ID user in the `jellyfin-users` group (`dm`, `emm`,
  `mfm`) — the Jellyfin account is auto-created (non-admin).
- **Link the admin account by hand:** sign in with the local admin, go to
  `…/TwoFactorAuth/Setup` → linked sign-in methods → link Pocket ID. The
  plugin deliberately refuses to auto-link administrator accounts.

Steady state: the CronJob runs daily at **04:30 America/Chicago** and is
idempotent — logs should read `already up to date` when nothing changed.

## How it works

- **jellarr** reads `/config/config.yml` (rendered at pod start from the
  `jellarr-configmap` ConfigMap). A `python:3.14-alpine` init container injects
  the Pocket ID `client_id`/`client_secret` from the operator-generated
  `jellyfin-oidc-credentials` Secret, so client-secret rotation is picked up
  automatically on the next run.
- **OIDC flow:** `PocketIDOIDCClient jellyfin` → pocket-id-operator creates the
  Pocket ID client (`https://jellyfin.local.${SECRET_DOMAIN}/TwoFactorAuth/Oidc/Callback/pocket-id`,
  PKCE, restricted to `jellyfin-users`) and the k8s Secret → jellarr pushes the
  provider config into the Jellyfin Security plugin via the Jellyfin API.
- **jellarr manages:** plugin repositories (official + Intro Skipper + Jellyfin
  Security), metrics, trickplay (software), libraries, and both plugins'
  configs. It does **not** manage branding, encoding, users, or the startup
  wizard.
- **Jellyfin Security settings applied:** Pocket ID OIDC as primary sign-in
  (auto-create users from `jellyfin-users`), Traefik forwarded headers trusted
  (`${POD_CIDR}`/`${SERVICE_CIDR}`), empty-password login blocked, IP banning
  on, impossible-travel off (no GeoIP databases mounted), plugin 2FA left
  optional and bypassed for OIDC users.
- **Transcoding is CPU-only.** The HelmRelease has no GPU device mounted and
  jellarr sets `trickplayOptions` to software. Add a `/dev/dri` (or NVIDIA)
  mount + an `encoding:` block in `config.yml` if that changes.
- **Recordings library** is created as `homevideos`; remove it from
  `config.yml` if you don't use DVR. The `jellyfin-users` group currently
  contains `dm`, `emm`, `mfm`.

## Post-bootstrap options

- **OIDC-only sign-in:** add `DisablePasswordLogin: true` to the Jellyfin
  Security config (admin/LAN escape hatches stay on by default).
- **Admin elevation via Pocket ID:** add `AdminGroups: admins` and
  `AllowAdminGroupElevation: true` to the OIDC provider.
- **Impossible-travel alerts:** mount MaxMind GeoLite2 DBs (Pocket ID's secret
  already has a MaxMind license key) and set `ImpossibleTravelEnabled: true`.
- **Hardware transcoding:** mount the GPU and add an `encoding:` section, e.g.
  `hardwareAccelerationType: vaapi`, `vaapiDevice: /dev/dri/renderD128`.

## Reference commands

```bash
# trigger a run on demand
kubectl -n media create job --from=cronjob/jellarr jellarr-manual-$(date +%s)

# follow the latest job
kubectl -n media logs -f job/$(kubectl -n media get jobs -o name | tail -1 | cut -d/ -f2)

# pause/resume jellarr
kubectl -n media patch cronjob jellarr -p '{"spec":{"suspend":true}}'   # git-tracked in helmrelease.yaml
kubectl -n media patch cronjob jellarr -p '{"spec":{"suspend":false}}'

# reconcile after a push
flux reconcile kustomization jellyfin --with-source
flux reconcile kustomization jellarr --with-source

# fully disable (config PVC is retained by the HelmRelease's retain: true)
# comment '# - ./jellyfin/ks.yaml' in media/kustomization.yaml again
```

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `JELLARR_API_KEY required` in job logs | GitLab variable missing / ExternalSecret not synced — recheck step 3 |
| ExternalSecret `SecretSyncedError` | `JELLARR_API_KEY` not present in the GitLab `jellyfin` group |
| `jellyfin-oidc-credentials` missing | `kubectl -n media get pocketidoidcclient jellyfin` — operator still reconciling or Pocket ID unreachable |
| Login page has no Pocket ID button | Plugin config not applied yet — restart Jellyfin, run jellarr again |
| Homepage Jellyfin widget broken | `HOMEPAGE_VAR_JELLYFIN_TOKEN` still holds the old server's key |
| Job pod stuck `CreateContainerConfigError` | One of the secrets it references doesn't exist yet (steps 3–4) |
