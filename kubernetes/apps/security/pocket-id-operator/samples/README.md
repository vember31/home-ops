# Pocket ID Operator Samples

These resources are examples only. They are intentionally not included from the
live app kustomization so they will not be applied until you explicitly wire them
in.

Required external secret for the default deployment:

```yaml
pocket-id:
  ENCRYPTION_KEY: "generate-a-random-value-at-least-16-characters"
```

The operator writes generated OIDC client credentials to Kubernetes Secrets, so
client secrets do not need to be committed to Git.

## User Workflow

Users are split into two parts:

- profile data lives in the external secret backend and is synced into a
  Kubernetes Secret by an `ExternalSecret`.
- the desired Pocket ID user/group state lives in Git as `PocketIDUser` and
  `PocketIDUserGroup` resources.

To add yourself as an administrator:

1. Add a secret-store entry at `pocket-id/users/admin`.
2. Fill it with these keys:

   ```yaml
   USERNAME: your-username
   FIRST_NAME: Your
   LAST_NAME: Name
   EMAIL: you@example.com
   DISPLAY_NAME: Your Name
   ```

3. Apply `admin-user.externalsecret.yaml` and `admin-user.yaml`, or copy their
   contents into the live instance kustomization.
4. Keep `spec.admin: true` on your `PocketIDUser`.
5. Keep your user listed in the `admins` group.

To add a normal user:

1. Add a secret-store entry at `pocket-id/users/normal`.
2. Fill it with the same keys shown above.
3. Apply `normal-user.externalsecret.yaml` and `normal-user.yaml`, or copy their
   contents into the live instance kustomization.
4. Keep `spec.admin: false` on their `PocketIDUser`.
5. Put them in application access groups, such as `bookorbit-users`, not in
   `admins`.

To grant BookOrbit access:

1. Apply `bookorbit-users.yaml` after the referenced users exist.
2. Keep yourself and any normal BookOrbit users listed under
   `spec.users.userRefs`.
3. Keep the BookOrbit OIDC client restricted to `bookorbit-users`.

The samples create:

- `admin`: a Pocket ID administrator in `admins`.
- `normal`: a standard Pocket ID user, only in `bookorbit-users`.
- `bookorbit-users`: the group allowed to use the BookOrbit OIDC client.

When a `PocketIDUser` is first created, the operator stores a one-time login
token and URL in the resource status for about 15 minutes. Use that for the
initial login, then enroll passkeys or configure the account normally.

BookOrbit's browser callback URL is:

```text
https://<bookorbit-url>/oauth2-callback
```

The BookOrbit sample includes both `books.local.${SECRET_DOMAIN}` and
`books.${SECRET_DOMAIN}` callback URLs so the same Pocket ID client can work
before and after BookOrbit becomes internet-facing.
