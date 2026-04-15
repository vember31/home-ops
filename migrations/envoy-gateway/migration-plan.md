# Traefik to Envoy Gateway Migration Plan

> Created: 2026-04-13
> Status: Planning

## Overview

Migrate from Traefik (IngressRoute CRDs + Ingress resources) to Envoy Gateway with Kubernetes Gateway API. This replaces the ingress controller and all routing configuration while keeping cert-manager, external-dns, and Cilium BGP unchanged.

**Strategy**: Parallel deployment — Envoy Gateway runs alongside Traefik on a separate LB IP. Routes are migrated in batches, validated, then the Traefik IP is retired and Envoy Gateway takes over. This allows rollback at any point by simply switching DNS back to Traefik.

**Git**: All changes on a `envoy-gateway` branch, merged to `main` after cutover.

---

## Current State Inventory

### Traefik Components to Replace

| Component | Count | Location |
|---|---|---|
| Traefik HelmRelease | 1 | `kubernetes/apps/networking/traefik/app/` |
| Traefik Middlewares | 5 | `kubernetes/apps/networking/traefik/middlewares/` |
| IngressRoute CRDs | 5 | error-pages, traefik-dashboard, flux-operator, flux-webhook, grafana |
| HelmRelease `ingress:` blocks | 33 | Across all namespaces |
| Traefik annotations | ~31 | `traefik.ingress.kubernetes.io/router.middlewares` |
| Traefik DNSEndpoint | 1 | `kubernetes/apps/networking/traefik/app/dnsendpoint.yaml` |
| Traefik ScrapeConfig | 1 | `kubernetes/apps/networking/traefik/metrics/scrapeconfig.yaml` |
| Traefik Certificates | 2 | `kubernetes/apps/networking/traefik/certificates/` |

### Middleware Usage Map

| Middleware | Function | Used By |
|---|---|---|
| `internal-with-errors` | IP allowlist (secure/pod/svc/vpn CIDRs) + error pages | 24 apps (most internal services) |
| `external-with-errors` | IP allowlist (Cloudflare IPs) + error pages | 5 apps (gatus, vaultwarden, etc.) |
| `secure-networks` | IP allowlist only (no error pages) | 1 app (vaultwarden secondary, traefik dashboard) |
| `cloudflare-ips` | Cloudflare IP allowlist only | 1 app (vaultwarden) |
| `error-pages` | Custom error page routing (400-599) | Base of both chain middlewares |

### What Stays the Same

- cert-manager ClusterIssuers (letsencrypt-production, letsencrypt-staging)
- external-dns (supports Gateway API natively via HTTPRoute hostnames)
- Cilium BGP / LoadBalancer services (Plex, qBittorrent, Blocky, kube-api)
- Error-pages app deployment (just needs new routing)
- All application deployments and services (only routing changes)
- Gatus health checks (URLs stay the same, only the gateway serving them changes)

---

## Envoy Gateway Equivalents

### Middleware → Policy Mapping

| Traefik Middleware | Envoy Gateway Equivalent | Resource Type |
|---|---|---|
| IP allowlist (secure-networks) | `SecurityPolicy` with `authorization.rules` (CIDR matching) | SecurityPolicy |
| IP allowlist (cloudflare-ips) | `SecurityPolicy` with `authorization.rules` (CIDR matching) | SecurityPolicy |
| Error pages (custom 4xx/5xx) | `BackendTrafficPolicy` with `responseOverride` | BackendTrafficPolicy |
| Middleware chain (internal-with-errors) | Attach both SecurityPolicy + BackendTrafficPolicy to HTTPRoute | Multiple policies on same target |
| Middleware chain (external-with-errors) | Same pattern, different SecurityPolicy CIDRs | Multiple policies on same target |

### TLS Configuration

| Traefik | Envoy Gateway |
|---|---|
| Default TLS options (min 1.2, max 1.3, sniStrict) | `ClientTrafficPolicy` on Gateway with TLS settings |
| HTTP → HTTPS redirect via entrypoint | Gateway listener config or `HTTPRouteFilter` redirect |
| cert-manager annotation on Ingress | cert-manager annotation on Gateway — auto-issues per-app certs from HTTPRoute hostnames |

### Key Architecture Difference

Traefik: One entrypoint handles all routes. Middlewares are referenced by annotation.

Envoy Gateway: A `Gateway` resource defines listeners (HTTP/HTTPS). `HTTPRoute` resources attach to the Gateway via `parentRefs`. Policies (`SecurityPolicy`, `BackendTrafficPolicy`, `ClientTrafficPolicy`) attach to either the Gateway (global) or individual HTTPRoutes (per-app).

---

## Phase 1: Deploy Envoy Gateway (Parallel with Traefik)

### 1.1 Add Envoy Gateway HelmRelease

Deploy Envoy Gateway into the `networking` namespace alongside Traefik.

New files:
- `kubernetes/flux/repositories/oci/envoy-gateway.yaml` — OCIRepository
- `kubernetes/apps/networking/envoy-gateway/ks.yaml` — Flux Kustomization
- `kubernetes/apps/networking/envoy-gateway/app/helmrelease.yaml` — HelmRelease
- `kubernetes/apps/networking/envoy-gateway/app/kustomization.yaml`

HelmRelease values (minimal):
```yaml
values:
  deployment:
    envoyGateway:
      resources:
        requests:
          cpu: 50m
          memory: 128Mi
        limits:
          memory: 256Mi
```

### 1.2 Create the Gateway Resource

Define a `Gateway` that listens on HTTP (80) and HTTPS (443) with a separate LoadBalancer IP from Traefik.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: internal
  namespace: networking
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-production
spec:
  gatewayClassName: eg
  listeners:
    - name: http
      protocol: HTTP
      port: 80
    - name: https
      protocol: HTTPS
      port: 443
      tls:
        mode: Terminate
        # certificateRefs are automatically managed by cert-manager's Gateway API integration.
        # cert-manager watches HTTPRoute hostnames attached to this Gateway and issues
        # per-app certs (matching the current Ingress-based approach).
  infrastructure:
    annotations:
      lbipam.cilium.io/ips: "192.168.10.24"  # temporary parallel IP
    labels:
      io.cilium/bgp-announce: worker
```

Also create a second Gateway for externally-facing routes (gatus, vaultwarden, flux-webhook) if needed, or use the same Gateway with different policy attachments.

### 1.3 Create Global Policies

**ClientTrafficPolicy** (TLS settings — replaces Traefik TLS options):
```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy
metadata:
  name: tls-policy
  namespace: networking
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: internal
  tls:
    minVersion: "1.2"
    maxVersion: "1.3"
```

**SecurityPolicy — internal networks** (replaces `secure-networks` middleware):
```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: internal-networks
  namespace: networking
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: <per-app>  # attached per-route
  authorization:
    defaultAction: Deny
    rules:
      - action: Allow
        principal:
          clientCIDRs:
            - ${SECURE_CIDR}
            - ${POD_CIDR}
            - ${SERVICE_CIDR}
            - ${VPN_CIDR}
```

**SecurityPolicy — Cloudflare IPs** (replaces `cloudflare-ips` middleware):
Same structure but with Cloudflare IP ranges.

**BackendTrafficPolicy — error pages** (replaces `error-pages` middleware):
```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: error-pages
  namespace: networking
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: internal
  responseOverride:
    - match:
        statusCodes:
          - type: Range
            range:
              start: 400
              end: 599
      response:
        contentType: text/html
        body:
          type: Inline
          inline: "custom error"  # or use a backend reference
```

> **Note**: Error pages integration may require an `EnvoyExtensionPolicy` or external processing filter to proxy to the error-pages service dynamically (matching Traefik's `service` error handler behavior). Research the best approach during Phase 2 testing.

### 1.4 Add DNSEndpoint for Envoy Gateway

```yaml
# Temporary parallel endpoint
apiVersion: externaldns.k8s.io/v1alpha1
kind: DNSEndpoint
metadata:
  name: envoy-gateway
  namespace: networking
spec:
  endpoints:
    - dnsName: envoy.local.${SECRET_DOMAIN}
      recordType: A
      targets:
        - "192.168.10.24"
```

### 1.5 Validate

- [ ] Envoy Gateway controller pod running
- [ ] Envoy proxy pod(s) running
- [ ] Gateway resource accepted (`kubectl get gateway`)
- [ ] LoadBalancer IP assigned via Cilium BGP
- [ ] TLS listener working

---

## Phase 2: Migrate Routes (Batch by Batch)

### 2.1 Migration Pattern

For each app using bjw-s app-template (48 apps, 33 with ingress), change:

```yaml
# Before (Traefik Ingress)
ingress:
  app:
    enabled: true
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt-production
      external-dns.alpha.kubernetes.io/target: traefik.local.${SECRET_DOMAIN}
      traefik.ingress.kubernetes.io/router.middlewares: networking-internal-with-errors@kubernetescrd
      # ...homepage/hajimari annotations stay...
    hosts:
      - host: &host ${APP}.local.${SECRET_DOMAIN}
        paths:
          - path: /
            service:
              identifier: app
              port: http
    tls:
      - secretName: ${APP}-tls-production
        hosts:
          - *host
```

```yaml
# After (Gateway API HTTPRoute)
route:
  app:
    enabled: true
    kind: HTTPRoute
    annotations:
      external-dns.alpha.kubernetes.io/target: envoy.local.${SECRET_DOMAIN}
      # ...homepage/hajimari annotations stay...
    parentRefs:
      - group: gateway.networking.k8s.io
        kind: Gateway
        name: internal
        namespace: networking
        sectionName: https
    hostnames:
      - ${APP}.local.${SECRET_DOMAIN}
    rules:
      - matches:
          - path:
              type: PathPrefix
              value: /
        backendRefs: []  # defaults to primary service
```

Key differences:
- `ingress:` → `route:`
- Traefik annotations removed
- `external-dns` target changes from `traefik.local.` to `envoy.local.` (temporary, then to final Envoy IP)
- `cert-manager` annotation lives on the Gateway resource — cert-manager auto-issues per-app certs based on HTTPRoute hostnames (same per-app cert approach as today, just driven by the Gateway instead of per-Ingress annotations)
- `tls:` section removed from HelmRelease values (Gateway handles TLS termination)
- `hosts:` → `hostnames:`
- `paths:` → `rules:` with `matches:`

### 2.2 Batch Order

Migrate in order of risk (least critical first):

**Batch 1 — Low-risk internal apps (test the pattern)**
- olivetin, homepage, pgadmin, goldilocks, dozzle
- Validate: access via `envoy.local.${SECRET_DOMAIN}`, cert issued, IP allowlist works

**Batch 2 — Media apps (read-heavy, internal only)**
- tautulli, seerr, maintainerr, requestrr, wizarr, agregarr, dispatcharr, autopulse, tracearr
- Validate: all accessible, homepage widgets work

**Batch 3 — Downloads apps (internal only)**
- sonarr, radarr, bazarr, prowlarr, autobrr, unpackerr, qbittorrent (web UI), epicgames-free
- Validate: all accessible, API calls between apps still work (these talk to each other via ClusterIP, not ingress)

**Batch 4 — Monitoring**
- victoria-metrics, victoria-logs, gatus, grafana (IngressRoute → HTTPRoute)
- Validate: dashboards load, metrics flowing

**Batch 5 — Infrastructure + external-facing**
- blocky (web UI), longhorn, plex (web UI ingress)
- flux-operator, flux-webhook (IngressRoute → HTTPRoute)
- Validate: Flux webhook receives GitHub events

**Batch 6 — External-facing with Cloudflare**
- vaultwarden (dual ingress: Cloudflare + internal)
- gatus (external endpoint)
- Validate: Cloudflare tunnel/proxy still works, external access functional

### 2.3 Convert IngressRoute CRDs

The 5 standalone IngressRoutes need manual conversion to HTTPRoute resources:

| IngressRoute | New HTTPRoute Location |
|---|---|
| error-pages catch-all | May become a default backend on the Gateway, or a low-priority HTTPRoute |
| traefik-dashboard | Replaced by Envoy Gateway's own admin interface, or removed |
| flux-operator | `kubernetes/apps/flux-system/flux-operator/app/httproute.yaml` |
| flux-webhook | `kubernetes/apps/flux-system/flux-instance/app/receiver/httproute.yaml` |
| grafana | `kubernetes/apps/monitoring/grafana-operator/app/resources/httproute.yaml` |

### 2.4 SecurityPolicy Attachment

Instead of per-app middleware annotations, attach SecurityPolicies to HTTPRoutes:

**Option A — Per-route attachment** (verbose but explicit):
Each HTTPRoute gets a SecurityPolicy targeting it by name.

**Option B — Gateway-level default + exceptions** (recommended):
- Attach `internal-networks` SecurityPolicy to the Gateway (applies to all routes by default)
- Override with `cloudflare-ips` SecurityPolicy on specific external HTTPRoutes
- This matches the current pattern where most apps use `internal-with-errors`

> Research whether Envoy Gateway supports policy inheritance/override between Gateway and HTTPRoute targets during Phase 1 testing.

---

## Phase 3: Cutover

### 3.1 Switch Envoy Gateway to Traefik's IP

Once all routes are migrated and validated:

1. Remove Traefik's LoadBalancer service (or scale to 0)
2. Update Envoy Gateway's Gateway resource to use `${TRAEFIK_IP}` (192.168.10.20)
3. Update DNSEndpoint to point `envoy.local.${SECRET_DOMAIN}` → `${TRAEFIK_IP}`
4. Or rename the variable entirely (e.g., `GATEWAY_LB_IP`)

### 3.2 Update external-dns Targets

All `external-dns.alpha.kubernetes.io/target` annotations need to point to the final Envoy Gateway DNS name. This could be done during Phase 2 if using the temporary parallel IP, or as a final sweep.

### 3.3 Update Homepage Widget

If Homepage has a Traefik widget, replace with Envoy Gateway metrics or remove.

### 3.4 Update Gatus Checks

Any Gatus endpoints monitoring `traefik.local.${SECRET_DOMAIN}` need updating.

---

## Phase 4: Cleanup

### 4.1 Remove Traefik

Delete entirely:
- `kubernetes/apps/networking/traefik/` (HelmRelease, middlewares, dashboard, certificates, metrics, DNSEndpoint)
- Update `kubernetes/apps/networking/kustomization.yaml` to remove traefik reference

### 4.2 Remove Traefik HelmRepository/OCIRepository

If Traefik had a dedicated chart source, remove it from `kubernetes/flux/repositories/`.

### 4.3 Rename Variables

Consider renaming `TRAEFIK_IP` to `INGRESS_IP` or `GATEWAY_IP` in `cluster-settings.yaml` (and all references) since it's no longer Traefik-specific.

### 4.4 Update Monitoring

- Remove Traefik ScrapeConfig (`kubernetes/apps/networking/traefik/metrics/scrapeconfig.yaml`)
- Add Envoy Gateway ScrapeConfig (Envoy exposes Prometheus metrics natively)
- Update Grafana dashboards (replace Traefik dashboard with Envoy Gateway dashboard)

### 4.5 Clean Up Error-Pages

The error-pages app deployment stays, but its IngressRoute and Traefik middleware integration are removed. Validate error page serving works through Envoy Gateway's `responseOverride` or extension mechanism.

---

## Resource Estimate

| Component | CPU Request | Memory Request | Memory Limit |
|---|---|---|---|
| Envoy Gateway controller | 50m | 128Mi | 256Mi |
| Envoy proxy (per Gateway) | 100m | 64Mi | 256Mi |
| **Total** | **150m** | **~192Mi** | **~512Mi** |

Compared to Traefik's current usage of ~2m CPU / 53Mi memory, Envoy Gateway is heavier but well within homelab capacity. The proxy scales based on traffic, not route count.

---

## Risk Assessment

| Risk | Severity | Mitigation |
|---|---|---|
| Route misconfiguration during migration | Medium | Parallel deployment — Traefik serves traffic until Envoy is validated |
| cert-manager + Gateway API integration | Low | Well-documented, cert-manager has native Gateway API support |
| external-dns + Gateway API | Low | Supported natively, HTTPRoute hostnames are auto-discovered |
| Error pages integration | Medium | Envoy's error handling differs from Traefik; may need EnvoyExtensionPolicy. Test early in Phase 1 |
| SecurityPolicy CIDR matching with Flux substitution | Medium | Test that `${SECURE_CIDR}` etc. substitute correctly in SecurityPolicy resources |
| Homepage/Gatus widget compatibility | Low | Worst case, remove Traefik widget. Envoy Gateway has its own metrics |
| Envoy Gateway maturity | Low-Medium | CNCF project, backed by Envoy (graduated). v1.x is production-ready |
| Resource overhead | Low | ~200Mi total vs ~53Mi for Traefik. Acceptable for the cluster |

---

## Files to Create

### Envoy Gateway deployment
- `kubernetes/flux/repositories/oci/envoy-gateway.yaml`
- `kubernetes/apps/networking/envoy-gateway/ks.yaml`
- `kubernetes/apps/networking/envoy-gateway/app/helmrelease.yaml`
- `kubernetes/apps/networking/envoy-gateway/app/kustomization.yaml`
- `kubernetes/apps/networking/envoy-gateway/app/gateway.yaml` — Gateway resource
- `kubernetes/apps/networking/envoy-gateway/app/dnsendpoint.yaml`
- `kubernetes/apps/networking/envoy-gateway/policies/client-traffic-policy.yaml` — TLS settings
- `kubernetes/apps/networking/envoy-gateway/policies/security-policy-internal.yaml` — internal IP allowlist
- `kubernetes/apps/networking/envoy-gateway/policies/security-policy-cloudflare.yaml` — Cloudflare IP allowlist
- `kubernetes/apps/networking/envoy-gateway/policies/backend-traffic-policy-errors.yaml` — error pages

### Converted IngressRoutes → HTTPRoutes
- `kubernetes/apps/flux-system/flux-operator/app/httproute.yaml` (replaces ingressroute.yaml)
- `kubernetes/apps/flux-system/flux-instance/app/receiver/httproute.yaml` (replaces ingressroute.yaml)
- `kubernetes/apps/monitoring/grafana-operator/app/resources/httproute.yaml` (replaces ingressroute.yaml)

## Files to Modify

### HelmRelease `ingress:` → `route:` conversions (33 files)
All files in `kubernetes/apps/` containing `ingress:` blocks — full list:
- `default/homepage/app/helmrelease.yaml`
- `default/olivetin/app/helmrelease.yaml`
- `database/pgadmin/app/helmrelease.yaml`
- `downloads/autobrr/app/helmrelease.yaml`
- `downloads/bazarr/app/helmrelease.yaml`
- `downloads/prowlarr/app/helmrelease.yaml`
- `downloads/qbittorrent/app/helmrelease.yaml`
- `downloads/qbittorrent/qui/helmrelease.yaml`
- `downloads/radarr/app/helmrelease.yaml`
- `downloads/sonarr/app/helmrelease.yaml`
- `games/epicgames-free/app/helmrelease.yaml`
- `home/outline/app/helmrelease.yaml`
- `kube-system/cilium/app/helmrelease.yaml` (Hubble UI ingress)
- `media/agregarr/app/helmrelease.yaml`
- `media/autopulse/app/helmrelease.yaml`
- `media/dispatcharr/app/helmrelease.yaml`
- `media/maintainerr/app/helmrelease.yaml`
- `media/plex/app/helmrelease.yaml`
- `media/requestrr/app/helmrelease.yaml`
- `media/seerr/app/helmrelease.yaml`
- `media/tautulli/app/helmrelease.yaml`
- `media/tracearr/app/helmrelease.yaml`
- `media/wizarr/app/helmrelease.yaml`
- `monitoring/dozzle/app/helmrelease.yaml`
- `monitoring/gatus/app/helmrelease.yaml`
- `monitoring/goldilocks/app/helmrelease.yaml`
- `monitoring/victoria-logs/app/helmrelease.yaml`
- `monitoring/victoria-metrics-k8s-stack/app/helmrelease.yaml`
- `networking/blocky/app/helmrelease.yaml`
- `security/vaultwarden/app/helmrelease.yaml`
- `storage/longhorn/app/helmrelease.yaml`

### Other modifications
- `kubernetes/apps/networking/kustomization.yaml` — add envoy-gateway, eventually remove traefik
- `kubernetes/flux/repositories/oci/kustomization.yaml` — add envoy-gateway OCI repo
- `kubernetes/flux/vars/cluster-settings.yaml` — optionally rename TRAEFIK_IP → GATEWAY_IP

## Files to Delete (Phase 4)

- `kubernetes/apps/networking/traefik/` — entire directory
- `kubernetes/apps/networking/error-pages/app/ingressroute.yaml` — replaced by Gateway error handling
