# BookOrbit

## Promoting a Superuser

BookOrbit stores its own administrator state. A Pocket ID admin user is not automatically
a BookOrbit superuser.

If you are already logged into BookOrbit as an existing superuser, promote another user
through the BookOrbit API.

First, find the target user's BookOrbit ID:

```bash
POSTGRES_POD="$(kubectl -n database get pods -l cnpg.io/cluster=postgres-18 -o jsonpath='{.items[0].metadata.name}')"

kubectl -n database exec "$POSTGRES_POD" -c postgres -- \
  psql -U postgres -d bookorbit \
  -c "select id, username, email, is_superuser, provisioning_method from users order by id;"
```

Then open BookOrbit as the existing superuser, open the browser developer console, and
run:

```js
const r = await fetch('/api/v1/users/<USER_ID>/superuser', {
  method: 'PUT',
  headers: { 'Content-Type': 'application/json' },
  credentials: 'include',
  body: JSON.stringify({ isSuperuser: true }),
});

console.log(r.status, await r.text());
```

Replace `<USER_ID>` with the numeric ID from the query. A successful response is HTTP
`204` with an empty body.

After promotion, log out and back in as the promoted user. BookOrbit should show that
account as an admin/superuser.

The API requires the requesting user to already be a superuser. It also prevents a user
from changing their own superuser state and prevents removing the last superuser.
