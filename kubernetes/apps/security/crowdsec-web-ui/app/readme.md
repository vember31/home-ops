# CrowdSec Web UI

## Post-install: register the LAPI watcher machine

The Web UI authenticates against the CrowdSec LAPI with a watcher machine
(`crowdsec-web-ui`). Its password lives in the `crowdsec-keys` secret
(`CROWDSEC_WEBUI_LAPI_PASSWORD`).

Register the machine once LAPI is up (the password must match the secret):

```bash
kubectl -n security exec deploy/crowdsec-lapi -- cscli machines add crowdsec-web-ui --password "$(kubectl -n security get secret crowdsec-keys -o jsonpath='{.data.CROWDSEC_WEBUI_LAPI_PASSWORD}' | base64 -d)" -f /dev/null
```

The `-f /dev/null` flag prevents the machine registration from clobbering the
LAPI's own credentials file.

Verify with `cscli machines list` (or the Web UI itself once OIDC is working).

## Notes

- The Web UI connects to the LAPI at `http://crowdsec-service.security.svc.cluster.local:8080`.
- Access is internal-only (`https://crowdsec.local.${SECRET_DOMAIN}`), SSO via PocketID, restricted to the `admins` group.
- SQLite state lives on a Longhorn PVC mounted at `/app/data`; the app writes its `config.yaml` there on first start.
- The app-image tag is date-based (`YYYY.M.D`); Renovate should pick it up as a container digest update.