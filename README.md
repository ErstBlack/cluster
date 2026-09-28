# cluster

A Rocky Linux 10 golden image (`image/`) whose nodes form an RKE2 cluster at first boot
through cloud-init and `cloud-init/rke2_elect.py`. Real deployments are independent physical and
virtual nodes, each started on its own with no orchestrator.

The OpenTofu project here is the test harness. It runs nine VMs, `Rocky-Cluster-1` to
`Rocky-Cluster-9`, on the KVM host `vcows`. Tofu runs in a podman container and reaches libvirt at `qemu+sshcmd://vcows/system`
through the `vcows` entry in `~/.ssh/config`.

| VM | MAC |
|---|---|
| Rocky-Cluster-N | `52:54:00:c1:00:0N` |

Each VM has 4 vCPU (host-passthrough), 8 GiB RAM, a 40 GiB thin qcow2 overlay on a shared base image,
UEFI with Secure Boot on (Microsoft keys enrolled, so Rocky's signed shim verifies), VNC and a serial
console, and `qemu-guest-agent`. The VMs sit on their own NAT network `rocky-cluster`
(192.168.150.0/24), which has no DHCP. Every volume tofu creates in the `images` pool is prefixed `rocky-cluster-`.

## Use

`just` lists the recipes.

```sh
just check
just image
just container
just tofu init
just tofu plan
just tofu apply
just tofu output
just tofu destroy
```

`tofu.sh` mounts this directory at `/work` and `~/.ssh` read-only. The cloud-init user `rocky` gets
every `~/.ssh/*.pub` plus every line of `~/.ssh/authorized_keys`, read at plan time. Keys reach a VM
only at its first boot. A later key change replaces the seed volumes but does not add or revoke keys
on existing VMs.

`node_count` is 1 to 9. Each slot has a fixed MAC, so scaling only adds or removes VMs.
Changing `disk_gib` rebuilds every VM with a fresh disk and loses guest data, the same as an image swap.
State and the generated cloud-init ISOs live in `/srv/rocky-cluster` on this host, outside the
checkout, so every checkout and session shares one state and its lock. Create it once with
`sudo install -d -o $USER -m 0700 /srv/rocky-cluster`. Deleting `/srv/rocky-cluster/tmp` makes the
next plan replace the seed volumes.

## Access

libvirt blocks forwarding between two NAT networks, so reach the VMs through vcows. The VIP lands on a
server, and `kubectl get nodes -o wide` there lists every node's address:

```sh
ssh -J vcows rocky@192.168.150.10
```

Consoles are in Cockpit on vcows under Virtual Machines, or `virsh -c qemu:///system console Rocky-Cluster-1` on vcows.

## Swapping the image

`base_image_url` takes any URL or local path to a qcow2. Changing it replaces the base image and
rebuilds every VM from scratch: overlays and domains are destroyed and re-created, and guest data is lost.

```sh
./tofu.sh apply -var base_image_url=https://example/rocky10-custom.qcow2
```

## RKE2 golden image

`image/build.sh` builds `image/output/rocky-rke2.qcow2` (gitignored) from `image/blueprint.toml` with
osbuild `image-builder` in a pinned, privileged root podman container. The image carries `rke2-server`,
`rke2-agent` and `keepalived` (all disabled), `rke2-selinux`, `kernel-modules-extra` and
`qemu-guest-agent`.

Every node gets the same user-data and meta-data and works out the rest at boot. cloud-init names
the node `node-` plus the first 10 hex characters of `/etc/machine-id`, then starts three units in
order, each reading the one before. `node-addr` (`cloud-init/node_addr.py`) writes the node's address
in the VIP's network and its interface to `/run/rke2/node.env`. The site config
`/etc/rancher/rke2/elect.env` carries the VIP with the site prefix (`VIP=192.168.150.10/24`) and
optional `GATEWAY` and `DNS`. An address already in that network is kept. Otherwise `node-addr` hashes
`/etc/machine-id` to a host address, skipping the VIP, gateway and DNS, and saves it as the
NetworkManager profile `cluster` on the first ethernet device with a carrier. NetworkManager's
duplicate address detection fails the profile when another host holds the address, and `node-addr`
tries the next hash. The profile's autoconnect priority (999) beats cloud-init's DHCP profile (120), so
NetworkManager brings the same address back on every boot, and `node-addr` brings the profile up itself
if it is not up yet. A `VIP` without a prefix, or with /31 or /32, stops `node-addr`. With no `GATEWAY`
the default route is on-link. `rke2-elect` (`cloud-init/rke2_elect.py`) elects the node's role, reports ready
to systemd and keeps beaconing the decision. `rke2-configure` (`cloud-init/rke2_configure.py`) on
first boot waits for the VIP unless the node bootstraps and writes `keepalived.conf` on servers and
`config.yaml`. On every boot it makes sure the role's units are enabled and started.

No node has a fixed role. Each node draws a random token and broadcasts it on UDP 9346, signed with
the RKE2 join token. Once 60 s pass with no node appearing or dropping out (silent for 10 s), the
`control_plane_count` (default 3) highest tokens become servers and the highest
bootstraps the cluster. If the elected bootstrap dies before it
starts RKE2, including within about 10 s before the decision, the others wait on the VIP forever.
Recover with `./tofu.sh destroy` and `./tofu.sh apply`. The rest are agents. A node that boots later sees the `decided` beacons or the
VIP and joins as an agent. The servers run keepalived, which holds the VIP `192.168.150.10` on a server
whose RKE2 supervisor answers. Nodes join through `https://192.168.150.10:9345`. After a reboot the node
keeps its role. The cloud-init needs this image. The GenericCloud default has no RKE2.

The container images ship pre-imported. `image/airgap-images.txt` lists the RKE2 airgap tarball.
`image/airgap.sh` fetches whatever is missing into a cache
at `/srv/rocky-cluster/images/agent-images`, imports everything with RKE2's own containerd into
`/var/lib/rancher/rke2/agent/containerd`, and packages that state as the RPM `rke2-airgap-images` in the
local repo `image/output/airgap-repo`. `image/build.sh` runs it, adds the repo with `--extra-repo` and
installs the package from `image/airgap.toml`. Nodes then start with every image already unpacked and the
rke2-runtime binaries already staged in `/var/lib/rancher/rke2/data`.
The seeded state is tied to the RKE2 release's containerd, so bumping RKE2 means updating the tarball URL
in the manifest. `SKIP_AIRGAP=1 image/build.sh` builds without the package and nodes pull at first boot.
CI does that. The host needs `curl`. `rpmbuild` and `createrepo_c` run in a Rocky 10 container.
With `CLUSTER_IMAGE_ARCHIVE` set, `image/build.sh` moves the finished image to
`$CLUSTER_IMAGE_ARCHIVE/<UTC timestamp>/`, copies `build.log` there, and leaves `image/output/rocky-rke2.qcow2`
as a symlink to it. `./tofu.sh` mounts that directory so the path below still resolves.

```sh
image/build.sh
./tofu.sh apply -var base_image_url=/work/image/output/rocky-rke2.qcow2
```
