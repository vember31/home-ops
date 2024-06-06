# Notes
*Various FAQs and helpful notes for solving or investigating issues I've encountered*

## Proxmox

####  Proxmox node shows questions marks for status
* https://forum.proxmox.com/threads/promox-question-marks-on-all-machines-and-storage.81087/

#### E1000 adapter drops connections to network
* https://forum.proxmox.com/threads/e1000-driver-hang.58284/page-9#post-511567

#### Proxmox node needs to be separated from rest of cluster
* https://pve.proxmox.com/wiki/Cluster_Manager#_remove_a_cluster_node
    * Look to the section of 'without reinstalling'

#### Checking for bad blocks
* `badblocks -sv [drive, such as /dev/sda]`