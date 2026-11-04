# Jellyfin + Jellarr

Jellyfin 12.1 restored from `.archive`, served at
**`https://jellyfin.${SECRET_DOMAIN}`** (public URL; on the LAN, Blocky
resolves it straight to Traefik — see
`kubernetes/apps/networking/blocky/app/config/config.yml`), with user sign-in
via Pocket ID OIDC through the
[Jellyfin Security](https://github.com/ZL154/JellyfinSecurity) plugin.

Server configuration is designed to be managed declaratively by
[jellarr](https://github.com/venkyr77/jellarr), **but jellarr is suspended for
now**: the current release (v0.1.0) authenticates with the legacy
`X-Emby-Token` header, which Jellyfin 12 disables by default
([jellyfin/jellyfin#15559](https://github.com/jellyfin/jellyfin/pull/15559)).
The upstream fix ([venkyr77/jellarr#79](https://github.com/venkyr77/jellarr/pull/79))
has not shipped yet, so the CronJob stays suspended and the server is
configured by hand once during bootstrap (below). When a fixed jellarr release
exists, unsuspend it and it will converge the server to
`jellarr/config/config.yml`.

> **Status: disabled.** `kubernetes/apps/media/kustomization.yaml` has
> `# - ./jellyfin/ks.yaml` commented out, so none of the `jellyfin/` manifests
> deploy yet. The `jellyfin-users` Pocket ID group does deploy already (it
> lives in the `pocket-id-groups` Kustomization) — that is harmless and just
> means the group is ready when Jellyfin is enabled.

## Layout

| Path | Purpose |
| --- | --- |
| `ks.yaml` | Flux Kustomizations: `jellyfin` and `jellarr` (CronJob deploys suspended) |
| `app/` | Jellyfin HelmRelease (12.1, CPU-only, NFS media mounts, public ingress, external gatus check) |
| `app/oidc/pocket-id-oidc-client.yaml` | `PocketIDOIDCClient` — creates the Pocket ID client and the `jellyfin-oidc-credentials` Secret |
| `jellarr/` | jellarr CronJob, ExternalSecret, and config (inert until unsuspended) |
| `jellarr/config/config.yml` | Everything jellarr will manage (system, libraries, plugins, Jellyfin Security) — also the source of truth for the manual bootstrap |
| `jellarr/config/render_config.py` | Init-container script that injects the Pocket ID client id/secret into the config at pod start |

The Homepage card is defined in
`kubernetes/apps/default/homepage/app/config/services.yaml` rather than in
ingress annotations, because the jellyfin widget needs `version: 2` for
Jellyfin 12 and annotation values are always strings.

## Bootstrap checklist

### 1. Enable the app

Uncomment the line in `kubernetes/apps/media/kustomization.yaml`:

```yaml
  - ./jellyfin/ks.yaml
```

Commit and push, then:

```bash
flux reconcile kustomization cluster-apps --with-source
kubectl -n media rollout status deploy/jellyfin --timeout=10m
```

This creates the Jellyfin HelmRelease (fresh 20Gi `jellyfin-config` PVC), the
Pocket ID OIDC client, and the jellarr app with its CronJob **suspended** on
purpose.

Networking, for reference: external-dns publishes `jellyfin.${SECRET_DOMAIN}`
as a **DNS-only (unproxied)** record (`external-dns.kubernetes.io/cloudflare-proxied: "false"`)
— media traffic through Cloudflare's proxy is against their ToS — so clients
connect straight to Traefik. The usual `external-with-errors` chain can't be
used for that: its `cloudflare-ips` allowlist only admits Cloudflare IPs, so
Jellyfin uses `external-direct-with-errors` (CrowdSec bouncer + error pages)
instead. On the LAN, Blocky maps the same hostname to the Traefik VIP, so any
RFC1918 client that can reach Traefik streams directly; the gatus check also
resolves via Blocky (`GATUS_DNS_RESOLVER` in `ks.yaml`) because NAT hairpin to
the WAN IP isn't available from inside the cluster. Clients that don't use
Blocky (hardcoded DNS) need NAT reflection/hairpin on the UniFi 443
port-forward to use the public hostname from inside.

### 2. First boot of Jellyfin

Open `https://jellyfin.${SECRET_DOMAIN}` and complete the setup wizard:

1. Create the admin account (by hand — nothing automates this).
2. **Dashboard → API Keys → create a key named `jellarr`** and copy it (stash
   it for step 6; jellarr itself stays suspended for now).
3. Optional: create a second key for the Homepage widget — or just reuse the
   `jellarr` key (API keys are not user-bound).

### 3. Install the plugins by hand

jellarr would do this, but it is suspended. **Dashboard → Plugins →
Repositories**, add:

| Name | URL |
| --- | --- |
| Jellyfin Security | `https://raw.githubusercontent.com/ZL154/JellyfinSecurity/main/manifest.json` |
| Intro Skipper | `https://intro-skipper.org/manifest.json` |

Save, then **Catalog → install both → restart Jellyfin**. On Jellyfin 12 the
Jellyfin Security catalog entry automatically serves the .NET 10 build, and
Intro Skipper's manifest serves the release matching the server version.

### 4. Configure Jellyfin Security (OIDC + hardening)

`jellarr/config/config.yml` is the source of truth for the settings below; set
them once in the plugin UI (Dashboard → Plugins → Jellyfin Security). The
client credentials come from the operator-generated Secret:

```bash
kubectl -n media get secret jellyfin-oidc-credentials \
  -o jsonpath='{.data.client_id}' | base64 -d; echo
kubectl -n media get secret jellyfin-oidc-credentials \
  -o jsonpath='{.data.client_secret}' | base64 -d; echo
```

Settings tab:

| Setting | Value |
| --- | --- |
| Public base URL | `https://jellyfin.${SECRET_DOMAIN}` |
| Trust X-Forwarded-For | on |
| Trusted proxy CIDRs | `${POD_CIDR}` / `${SERVICE_CIDR}` (10.42.0.0/16, 10.43.0.0/16) |
| Block empty-password login | on |
| Impossible-travel detection | off (no GeoIP databases mounted) |
| WebAuthn RP ID | `jellyfin.${SECRET_DOMAIN}` |
| WebAuthn origins | `https://jellyfin.${SECRET_DOMAIN}` |

Sign-in Methods tab → add a provider:

| Field | Value |
| --- | --- |
| Preset | PocketID |
| Display name | `Pocket ID` |
| Discovery URL | `https://id.${SECRET_DOMAIN}/.well-known/openid-configuration` |
| Client ID / Secret | from `jellyfin-oidc-credentials` above |
| Scopes | `openid profile email groups` |
| Username claim | `preferred_username` |
| Allowed groups | `jellyfin-users` |
| Auto-create users | on |
| Skip plugin 2FA | on |
| Force HTTPS | on |
| Show login button | on |

The Pocket ID side needs no changes: `app/oidc/pocket-id-oidc-client.yaml`
already registers the plugin's callback
(`https://jellyfin.${SECRET_DOMAIN}/TwoFactorAuth/Oidc/Callback/pocket-id`,
PKCE, restricted to `jellyfin-users`).

### 5. Verify OIDC

- The Jellyfin login page should show a **"Sign in with Pocket ID"** button.
- Sign in as a Pocket ID user in the `jellyfin-users` group (`dm`, `emm`,
  `mfm`) — the Jellyfin account is auto-created (non-admin).
- **Link the admin account by hand:** sign in with the local admin, go to
  `…/TwoFactorAuth/Setup` → linked sign-in methods → link Pocket ID. The
  plugin deliberately refuses to auto-link administrator accounts.

### 6. Pre-stage the GitLab secrets

ExternalSecrets read from GitLab through the `gitlab-secret-store`
ClusterSecretStore. Jellyfin's variables live in the existing **`jellyfin`**
CI/CD variable group. In GitLab → group → **Settings → CI/CD → Variables**,
add / refresh:

| Variable | Value | Notes |
| --- | --- | --- |
| `HOMEPAGE_VAR_JELLYFIN_TOKEN` | a valid Jellyfin API key | Needed now for the Homepage widget. The old value is dead because the old server's data (and its API keys) no longer exists |
| `JELLARR_API_KEY` | the `jellarr` API key from step 2 | Not consumed until jellarr is unsuspended, but stash it now while you're here |

Then force a sync:

```bash
kubectl -n default annotate externalsecret homepage-secret force-sync=$(date +%s) --overwrite
kubectl -n media annotate externalsecret jellarr force-sync=$(date +%s) --overwrite   # optional until jellarr is enabled
```

Homepage restarts itself via Reloader once the synced secret changes.

### 7. (Later) Enable jellarr

When a jellarr release that includes
[venkyr77/jellarr#79](https://github.com/venkyr77/jellarr/pull/79) exists:

1. Bump the image tag in `jellarr/helmrelease.yaml` (Renovate will open the
   PR; v0.1.0 is the newest release today).
2. Flip `suspend: true` → `false` (there's a TODO comment marking it), commit,
   and push.
3. The plugins are already installed; because Jellyfin needs a restart between
   plugin install and plugin configuration, run the job twice:

```bash
kubectl -n media create job --from=cronjob/jellarr jellarr-bootstrap-1
kubectl -n media logs -f job/jellarr-bootstrap-1
kubectl -n media rollout restart deploy/jellyfin
kubectl -n media create job --from=cronjob/jellarr jellarr-bootstrap-2
kubectl -n media logs -f job/jellarr-bootstrap-2
```

4. Steady state: the CronJob runs daily at **04:30 America/Chicago** and is
   idempotent — logs read `already up to date` when nothing changed. From then
   on jellarr is the source of truth for everything in `config.yml`; UI edits
   to managed fields get reverted on the next run.

## How it works

- **Public URL + LAN split-horizon:** `jellyfin.${SECRET_DOMAIN}` is published
  by external-dns as a DNS-only (unproxied) record (`ipv4.${SECRET_DOMAIN}`
  target, `cloudflare-proxied: "false"`) and routed by Traefik behind the
  `external-direct-with-errors` chain. On the LAN, Blocky maps the same
  hostname to the Traefik VIP (like `vault.`), so home clients stream directly
  — Jellyfin clients speak plain HTTPS to the hostname, so no dedicated
  `LoadBalancer` IP is needed (unlike Plex, whose native protocol can't ride
  an ingress).
- **jellarr** reads `/config/config.yml` (rendered at pod start from the
  `jellarr-configmap` ConfigMap). A `python:3.15-alpine` init container injects
  the Pocket ID `client_id`/`client_secret` from the operator-generated
  `jellyfin-oidc-credentials` Secret, so client-secret rotation is picked up
  automatically on the next run.
- **OIDC flow:** `PocketIDOIDCClient jellyfin` → pocket-id-operator creates the
  Pocket ID client (`https://jellyfin.${SECRET_DOMAIN}/TwoFactorAuth/Oidc/Callback/pocket-id`,
  PKCE, restricted to `jellyfin-users`) and the k8s Secret → jellarr pushes the
  provider config into the Jellyfin Security plugin via the Jellyfin API (or,
  while suspended, you set it in the UI as in step 4).
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

Recommended now that the server has a public URL:

- **OIDC-only sign-in for remote clients:** set `DisablePasswordLogin: true` in
  the Jellyfin Security config. Admin and LAN escape hatches stay on by
  default, so you can still sign in locally (or as admin) if Pocket ID is
  down.
- **Require 2FA for admins:** set `EnforcementScope: Admins` (or `All`) if you
  don't go fully OIDC-only.
- **Admin elevation via Pocket ID:** add `AdminGroups: admins` and
  `AllowAdminGroupElevation: true` to the OIDC provider.

Other options:

- **Impossible-travel alerts:** mount MaxMind GeoLite2 DBs (Pocket ID's secret
  already has a MaxMind license key) and set `ImpossibleTravelEnabled: true`.
- **Hardware transcoding:** mount the GPU and add an `encoding:` section, e.g.
  `hardwareAccelerationType: vaapi`, `vaapiDevice: /dev/dri/renderD128`.

## Reference commands

```bash
# trigger a run on demand (only useful once jellarr is unsuspended)
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
| jellarr job logs `already up to date` then crashes, or 401s | Expected: jellarr v0.1.0 can't authenticate to Jellyfin 12. Leave it suspended until venkyr77/jellarr#79 ships |
| `JELLARR_API_KEY required` in job logs | GitLab variable missing / ExternalSecret not synced — recheck step 6 |
| `jellyfin-oidc-credentials` missing | `kubectl -n media get pocketidoidcclient jellyfin` — operator still reconciling or Pocket ID unreachable |
| Login page has no Pocket ID button | Plugin config not applied yet — recheck step 4, restart Jellyfin |
| Homepage Jellyfin widget broken | `HOMEPAGE_VAR_JELLYFIN_TOKEN` missing or still the old key. The card needs `version: 2` (set in homepage `services.yaml`) — v1 mode calls the `/emby/` routes Jellyfin 12 removed |
| Job pod stuck `CreateContainerConfigError` | One of the secrets it references doesn't exist yet (step 6) |
| LAN device can't reach `jellyfin.${SECRET_DOMAIN}` | It's resolving the WAN IP — the device isn't using Blocky DNS. Enable NAT reflection/hairpin on the UniFi 443 port-forward, or point the device at Blocky |
