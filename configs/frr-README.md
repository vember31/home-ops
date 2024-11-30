## Configuring BGP with the UDM Pro SE
### UDM Configuration
1. SSH into the UDM Pro SE
2. **Config Updates:** Update `/etc/frr/frr.conf` to append the content from my `config` folder in this repository for frr.
3. **Enable Service:** Enable and restart the frr service `systemctl enable frr.service && service frr start`
4. **Enable Multipath:** This means that there will be multiple, loadbalanced routes possible to each of the cluster nodes.  For DNS, this means true high-availability because DNS traffic will go to all live nodes, without relying on only one route.
```
vtysh
configure terminal
router bgp 64513
maximum-paths 5
```
* Note that '64513' should match to your router's BGP AS ID and '5' should be the number of nodes you have in your cluster, representing the maximum number of potential paths.

### MetalLB Configuration
MetalLB is configured in BGP mode in the repository. If it was switched back to L2 for any reason, make sure that the L2 advertisement is turned off and the BGPPeer & BGPAdvertisement custom resources are live and reconciled.

### Other notes
* It was key that the VIPs from MetalLB were *not* on the same VLAN as those with other devices. I created a new VLAN, 192.168.10.0/24, to house the VIPs (even though I only need a few).
* I don't believe the UDM Pro SE supports multipath, so truthfully BGP on the UDM isn't much better than L2 advertising because there's only one path being used to the 

### Validate
A valid configuration should display the following output of `vtysh -c "show ip bgp"` when run from the router's terminal

```
BGP table version is 25, local router ID is 192.168.2.1, vrf id 0
Default local pref 100, local AS 64513
Status codes:  s suppressed, d damped, h history, * valid, > best, = multipath,
               i internal, r RIB-failure, S Stale, R Removed
Nexthop codes: @NNN nexthop's vrf id, < announce-nh-self
Origin codes:  i - IGP, e - EGP, ? - incomplete
RPKI validation codes: V valid, I invalid, N Not found

   Network          Next Hop            Metric LocPrf Weight Path
*> 192.168.2.0/24   0.0.0.0                  0         32768 ?
*> 192.168.3.0/24   0.0.0.0                  0         32768 ?
*> 192.168.4.0/24   0.0.0.0                  0         32768 ?
*> 192.168.10.0/24  0.0.0.0                  0         32768 ?
*> 192.168.10.20/32 192.168.2.15             0             0 64514 i
*> 192.168.10.21/32 192.168.2.12             0             0 64514 i
*= 192.168.10.22/32 192.168.2.12             0             0 64514 i
*=                  192.168.2.11             0             0 64514 i
*=                  192.168.2.14             0             0 64514 i
*=                  192.168.2.13             0             0 64514 i
*>                  192.168.2.15             0             0 64514 i

Displayed  8 routes and 12 total paths
```
* Keys to look for in the above are:
  * The VIPs are visible (in the 192.168.10.0/24 network, in the above case)
  * Next hops are showing for the VIPs
  * The = signs represent multipath is enabled.