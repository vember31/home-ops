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

ES key variables keys must use letters, numbers, or underscores. Use this convention:

```text
pocket_id_users_<initials>
```

## JSON Template

Use type `Variable`, disable variable expansion, and use minified JSON if masking is
strict about spaces or special characters.

```json
{"USERNAME":"<initials>","FIRST_NAME":"<first-name>","LAST_NAME":"<last-name>","EMAIL":"<email-address>","DISPLAY_NAME":"<display-name>"}
```
