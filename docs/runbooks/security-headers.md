# Web App Security Headers Runbook

How to add HTTP security headers to an externally exposed app using a per-app Traefik `Middleware`, and how to tune a Content-Security-Policy that won't break the app.

Reference implementation: `kubernetes/apps/networking/traefik/middlewares/seerr-headers.yaml` (seerr, Oct 2026). Mozilla Observatory went from ~C to **80/B+**; the only remaining deduction is CSP `'unsafe-inline'`, which Cloudflare features force (see §6).

---

## 1. Approach

- One `Middleware` per app (`traefik.io/v1alpha1`), namespace `networking`, file in `kubernetes/apps/networking/traefik/middlewares/`.
- Add the file to `middlewares/kustomization.yaml`.
- Attach it to the app's ingress annotation, **before** the shared chain:

  ```yaml
  traefik.ingress.kubernetes.io/router.middlewares: networking-<app>-headers@kubernetescrd,networking-external-with-errors@kubernetescrd
  ```

  Order matters: middlewares are applied first-to-last on the request path, so the headers middleware (first) is outermost and its response headers also cover error-pages/CrowdSec responses.

- **Why per-app instead of adding to the shared `external-with-errors` chain?** CSP is app-specific. A policy permissive enough for one app (blob workers, external frames, inline scripts) can be wrong for another. Per-app keeps the blast radius to one site.
- Naming: `<app>-headers`; the reference format is `<namespace>-<name>@kubernetescrd`.
- Traefik here is v3.7.13 (chart 41.6.1). The CRD supports `contentSecurityPolicy`, `permissionsPolicy`, `frameDeny`, `referrerPolicy`, and arbitrary `customResponseHeaders`.

## 2. Starter template

Copy `seerr-headers.yaml` and adjust per app:

```yaml
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: <app>-headers
  namespace: networking
spec:
  headers:
    contentTypeNosniff: true
    frameDeny: true
    referrerPolicy: strict-origin-when-cross-origin
    permissionsPolicy: "camera=(), geolocation=(), microphone=(), payment=(), usb=()"
    contentSecurityPolicy: >-
      default-src 'self'; base-uri 'self'; object-src 'none'; frame-ancestors 'none'; form-action 'self';
      script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline';
      img-src 'self' data: blob: https:; font-src 'self' data:; connect-src 'self';
      media-src 'self' blob:; frame-src 'self'; worker-src 'self' blob:; manifest-src 'self';
      upgrade-insecure-requests
    customResponseHeaders:
      Cross-Origin-Opener-Policy: same-origin-allow-popups
      Cross-Origin-Resource-Policy: same-origin
      X-Powered-By: ""
```

| Setting | Observatory test | Notes |
|---|---|---|
| `contentSecurityPolicy` | CSP | The only part that can break an app — tune per app (§3) |
| `frameDeny` + `frame-ancestors 'none'` | X-Frame-Options | Belt-and-braces; Observatory passes on `frame-ancestors` alone |
| `referrerPolicy` | Referrer Policy | `strict-origin-when-cross-origin` is accepted |
| `permissionsPolicy` | — | Not scored, cheap hardening |
| COOP `same-origin-allow-popups` | COOP | Accepted by Observatory and safe for OAuth popups (seerr's Plex login code explicitly handles this mode) |
| CORP `same-origin` | CORP | Does not affect CORS API clients or non-browser consumers |
| `X-Powered-By: ""` | — | Empty value removes a response header in Traefik |

**Do not enable COEP** (`require-corp`/`credentialless`) blindly — it is bonus-only and commonly breaks cross-origin images/iframes. SRI is also bonus-only and needs app-side support.

## 3. Building the CSP for a new app

The CSP is the only piece that can break an app. Process used for seerr:

1. **Inventory what the browser actually loads** (for a Next.js app):
   - Fetch a page and list script tags: `curl -sS https://<host>/login | grep -oE '<script[^>]*>'`
   - Download the JS chunks and grep for external hosts:
     ```bash
     buildid=$(curl -sS https://<host>/login | grep -oE '"buildId":"[^"]+"' | head -1 | cut -d'"' -f4)
     curl -sS "https://<host>/_next/static/$buildid/_buildManifest.js" -o bm.js
     grep -oE '"static/chunks/[^"]+\.js"' bm.js | tr -d '"' | sort -u > chunks.txt
     # download each as https://<host>/_next/<path>, then:
     grep -rhoE 'https://[a-zA-Z0-9._-]+' *.js | sort | uniq -c | sort -rn
     ```
   - Check CSS for external `url(...)` references.
2. **Map findings to directives:**
   - XHR/fetch/WebSocket destinations → `connect-src`. Seerr needed `https://plex.tv` for Plex OAuth PIN calls — easy to miss because they're built in a util, not visible in the page HTML.
   - iframes → `frame-src` (e.g. YouTube trailers).
   - Images → `img-src https:` is pragmatic; Observatory does not penalize broad `img-src`.
   - Self-hosted assets → `script-src 'self'`, `font-src 'self' data:`.
3. **Inline scripts:**
   - `<script type="application/json">` (e.g. Next.js `__NEXT_DATA__`) is a data block — CSP does **not** block it.
   - Real inline scripts need `'unsafe-inline'`, or a hash/nonce if content is static. Per-request content (e.g. Cloudflare's `__CF$cv$params` ray ID) cannot be hashed.
   - `style-src 'unsafe-inline'` is effectively required by Next.js and is not penalized by Observatory.
4. **Test in the browser**: DevTools console reports blocked resources as CSP violations. Add the missing directive, or roll back. For a cautious rollout, ship `contentSecurityPolicyReportOnly` first and watch the console before enforcing.

## 4. App-side changes that often pair with this

- **Express/Node apps behind Traefik**: enable `trust proxy` (seerr: `network.trustProxy: true` in `overrides.json`) so session cookies get the `Secure` flag and logs show real client IPs.
  Propagation path: ConfigMap → ExternalSecret → Reloader restart. Force the secret refresh with:
  ```bash
  kubectl annotate externalsecret -n <ns> <name> force-sync=$(date +%s) --overwrite
  ```
  Then confirm inside the pod, e.g. `kubectl exec -n <ns> deploy/<app> -- grep trustProxy /app/config/settings.json`.
- API-key consumers (requestrr, homepage, scraparr, etc.) are unaffected by CORP/COOP changes.

## 5. Deploy and verify

```bash
# Validate before pushing
kubectl apply --dry-run=server -f kubernetes/apps/networking/traefik/middlewares/<app>-headers.yaml
kubectl kustomize kubernetes/apps/networking/traefik/middlewares | grep -A2 'name: <app>-headers'

# After Flux reconciles
curl -sSI https://<host>/ | grep -iE 'content-security|frame|referrer|permissions|cross-origin|x-powered|strict-transport'
```

- Re-scan: `https://developer.mozilla.org/en-US/observatory/analyze?host=<host>`
- Functional check: log in and exercise the app's external integrations (for seerr: Plex login, trailer playback, submit a request).
- Note: `kubectl get middleware` resolves to a leftover v2 CRD (`middlewares.traefik.containo.us`, present since 2023). Query the v3 resource explicitly: `kubectl get middleware.traefik.io -n networking <app>-headers`.

## 6. Observatory scoring and Cloudflare caveats

Seerr before → after:

| Test | Before | After |
|---|---|---|
| CSP | −25 (report-only only) | −20 (`'unsafe-inline'`) |
| X-Frame-Options | −20 (missing) | 0 pass (via `frame-ancestors`) |
| Referrer Policy | missing | 0 pass |
| COOP / CORP | not implemented | 0 pass |
| HSTS / XCTO / Redirection | pass | pass |
| Score | ~55 / C | **80 / B+** |

- **HSTS** is served by Cloudflare at 180 days. For the preload bonus: set max-age ≥ 31536000 in the CF dashboard and submit the domain at https://hstspreload.org (long-term commitment).
- **The last 20 points** require removing `'unsafe-inline'` from `script-src`. Seerr itself has no executable inline scripts — the requirement comes entirely from Cloudflare:
  - **Rocket Loader** (Speed → Optimization): rewrites/deferred-executes scripts and re-executes inline ones.
  - **JavaScript Detections** (`__CF$cv$params`): inline script with a per-request ray ID; on free plans it's part of Bot Fight Mode and can only be disabled via the API:
    ```bash
    curl -X PUT "https://api.cloudflare.com/client/v4/zones/<ZONE_ID>/bot_management" \
      -H "Authorization: Bearer <API_TOKEN>" -H "Content-Type: application/json" \
      -d '{"enable_js": false, "fight_mode": false}'
    ```
  - Disable both, then drop `'unsafe-inline'` from `script-src` → A+. We chose to keep B+ rather than disable them (Oct 2026).
- A `Content-Security-Policy-Report-Only` seen in early scans was not present on live responses; the enforced policy supersedes it either way.

## 7. Troubleshooting and rollback

- **Something blocked?** Browser console: `Refused to load/execute ... because it violates CSP directive`. Add the origin to the right directive (`script-src` / `style-src` / `connect-src` / `frame-src` / `img-src`).
- **Rollback**: remove the middleware from the ingress annotation (or revert the commit). Headers disappear immediately; no app state is changed.
- **Middleware referenced before it exists**: Traefik errors the router and the site returns 404s until the `Middleware` resource appears. Keep both in the same commit; if paranoid, apply the middleware first.
- **Iframes**: `frame-ancestors 'none'` / `X-Frame-Options: DENY` prevent the app from being embedded (e.g. in a dashboard). Check before applying to apps you embed.
- **Removing a response header**: set it to `""` under `customResponseHeaders`.
