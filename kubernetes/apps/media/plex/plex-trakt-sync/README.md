# Plex-Trakt-Sync

### Kubernetes Setup Notes
This program requires that you do an interactive authentication within a shell. While the container should be staying active for a user to exec into it and do the authentication (which populates a few files in /config/app, including .env, .pytrakt.json and servers.yml), I was struggling to get this to work in Kubernetes and instead did it with docker compose on an Alpine LXC container.

At this time, I am coding in the tokens in .pytrakt.json, which will eventually lead to errors once the tokens expire.  When this happens, I'll need to:

1. Exec into the container with `kubectl exec -it $(kubectl get pods -n media -o name | grep plex-trakt-sync) -n media -- /bin/sh`.
2. Run `plextraktsync trakt-login`. Follow prompts.
3. Update Gitlab variables. It shouldn't be necessary to update the Plex login.


If I cannot do it in Kubernetes for any reason, I'll need to:

1. Go into the Alpine-LXC and do `cd /root/containers/plex-trakt-sync`.
2. Run `docker compose run --rm plextraktsync login`.
3. Answer all prompts
4. When complete, do `cat /root/containers/plex-trakt-sync/config/.pytrakt.json`.
5. Update the variables in Gitlab for the plex_trakt_sync variable with the new values.
6. Update the refresh time within the repository to the new value.
7. Annotate the secret to force a refresh with `kubectl annotate es -n media plex-trakt-sync-secret force-sync=$(date +%s) --overwrite`.
8. Restart the container if needed (it should restart upon step 6).

Long-term it will probably make sense to move the refresh time in .pytrakt.json into the Gitlab variable as well. No other files should need to be updated besides .pytrakt.json.