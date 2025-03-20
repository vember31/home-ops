# Upgrading PostgreSQL Major Versions
### This is a multiple-step process that, at the high-level, consists of:

1. Creating a net-new cluster on the new version of postgres, which utilizes the monolith import strategy to pull all databases and users from the previous postgres cluster. This will create new services/endpoints (e.g. `postgres-17-rw.databsae.svc.cluster.local`)
2. Updating all services to point to the new postgres cluster
3. Updating the postgres-init image to be for the new version
4. Updating Renovate to allow updates to the new version
5. Ensuring the scheduledbackup resource is updated to point to the new cluster
6. Removing the previous postgres cluster

#### Step 1 instructions
1. Create a new cluster##.yaml file within the 'cluster' folder. 
2. Copy the contents of the previous `cluster##.yaml` into the new `cluster##.yaml`
3. Update the `name`, `ImageName`, `serverName` fields to the new version. Use the old cluster##.yaml file to know how to do this.
4. Be sure to include the below YAML at the bottom of the new cluster##.yaml file. This will be responsible for creating the new database based on the content from the previous database. The `previousVersion` should be the serverName that represents the previous cluster.
```
   # The below is intended for upgrades. Read the readme for documentation about how to perform this upgrade going forward
   bootstrap:
     initdb:
       import:
         type: monolith
         databases: ["*"]
         roles: ["*"]
         source:
           externalCluster: &previousCluster postgres16-v1 #this might not matter. using servername.
   externalClusters:
     - name: *previousCluster
       connectionParameters:
         host: postgres-17-rw.database.svc.cluster.local #service of the previous cluster
         user: postgres
         dbname: postgres
       password:
         name: cloudnative-pg-secret
         key: password
  ```
  5. Update the kustomization.yaml to apply this new cluster##.yaml file
  6. Commit the changes and watch the new cluster get created. 

#### Step 2 Instructions
Use VSCode's 'replace' to replace all `postgres-##-rw` instances with the updated ##. This will make sure all services point to the new database.

#### Step 3 Instructions
Use VSCode's 'replace' to update all `tag: ##` to the new version of postgres-init.

#### Step 4 Instructions
Update `.github/renovate/allowedVersions.json5` to increment to the next version

#### Step 5 Instructions
Update `scheduledbackup.yaml` to reference the name of the new cluster.

### ---Right here is a good time to commit changes from steps 2-6---

#### Step 6 Instructions
Delete the old `cluster##.yaml` and update `kustomization.yaml` to not reference the old `cluster##.yaml`.  Commit.