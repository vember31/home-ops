# Multus
This one was painful and I messed up the cluster pretty badly by deploying this in a broken state somehow. Following the instructions and looking at others' examples on kubesearch didn't seem to get me a working product. 

## Fixing the cluster
I was getting a ton of sandbox errors of sorts, and PodKillErrors because the multus-shim couldn't be found.

To fix the cluster, I needed to do a few things:
1. Remove the multus ks.yaml so that multus is gone from the cluster
2. Delete the CRD that it creates

* By this point, multus should be removed from the cluster. Pods will have an issue starting & being killed.

3. Stop the k3s service on each node with `sudo service k3s stop`
4. Remove the multus config with `rm -rf  /var/lib/rancher/k3s/agent/etc/cni/net.d/*multus*`
* this should really only be one config file of 00-multus.conf or something
5. Remove all k3s data directories. These will be rebuilt automatically when k3s restarts.  `rm -rf /var/lib/rancher/k3s/data/`
6. Restart the k3s service with `sudo service k3s start`
* If this doesn't work, try doing steps 1-5 and then doing a reboot instead of step 6 via `sudo reboot`
