### Vaultwarden Restore

To restore Vaultwarden data from a backup, follow the below steps:

1. Download the backup zip file to the local machine (e.g. WSL) running kubectl.
2. Ensure the Vaultwarden/Vaultwarden-backup containers are running together in a pod as usual. It is ok if this is a net-new PVC, or the existing vaultwarden-data PVC.
3. Move the backup.zip file to the PVC using:
```
kubectl cp /path/to/backup.zip security/<pod-name>:/data/restore.zip
```
4. Exec into the Vaultwarden-backup container. Confirm the presence of the restore.zip file
5. Run the restore command utilizing `entrypoint.sh`:
```
cd /
./app/entrypoint.sh restore --zip-file /data/restore.zip -password [[insert zip password here]]
```
6. Validate the restore.