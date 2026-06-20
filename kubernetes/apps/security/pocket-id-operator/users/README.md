# Pocket ID Users

Each real user lives in their own initials-based folder:

```text
users/
  inits/
    externalsecret.yaml
    kustomization.yaml
    user.yaml
```

The parent `kustomization.yaml` applies only the real user folders. The `template/`
folder is intentionally not referenced by the cluster.

## Add a User

1. Copy `template/` to a new lowercase initials folder.
2. Replace `replace-me` with the user's initials in the copied YAML files.
3. Replace `pocket_id_users_replace_me` with an external secret variable key for the user.
4. Add the new folder to this directory's `kustomization.yaml`.
5. Add an external secret key with a JSON value matching the template below.

External secret keys must use letters, numbers, or underscores. Use this convention:

```text
pocket_id_users_<initials>
```

## JSON Template

Use type `Variable`, disable variable expansion, and use minified JSON if masking is
strict about spaces or special characters.

```json
{"USERNAME":"<initials>","FIRST_NAME":"<first-name>","LAST_NAME":"<last-name>","EMAIL":"<email-address>","DISPLAY_NAME":"<display-name>"}
```

## First Login Codes

When the operator creates a new `PocketIDUser`, Pocket ID generates a one-time
login token for the user's first login. The operator writes it to the resource
status:

```bash
kubectl -n security get pocketiduser <initials> \
  -o jsonpath='{.status.oneTimeLoginURL}{"\n"}'
```

The token TTL is currently hardcoded by the operator to 15 minutes and is not
configurable through the chart values or the `PocketIDUser` spec. After expiry,
the operator clears `status.oneTimeLoginToken` and `status.oneTimeLoginURL`, but
the user remains in Pocket ID.

The Pocket ID admin GUI is the better path when issuing a code intentionally.
Users created declaratively still appear as normal users in Pocket ID, and the
admin user list can generate a fresh login code with longer validity options
such as 1 hour, 12 hours, 1 day, 1 week, or 1 month. GUI-generated codes are
created directly by Pocket ID and will not appear in the `PocketIDUser` status.

To generate a new first-login code, clear the login status fields and let the
operator reconcile:

```bash
kubectl -n security patch pocketiduser <initials> \
  --subresource=status \
  --type=merge \
  -p '{"status":{"oneTimeLoginToken":"","oneTimeLoginURL":"","oneTimeLoginExpiresAt":""}}'
```

Then read the new URL:

```bash
kubectl -n security get pocketiduser <initials> \
  -o jsonpath='{.status.oneTimeLoginURL}{"\n"}'
```
