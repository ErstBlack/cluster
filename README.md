# cluster

OpenTofu project that runs nine Rocky Linux 10 VMs, `Rocky-Cluster-1` to `Rocky-Cluster-9`, on the
KVM host `vcows`. Tofu runs in a podman container and reaches libvirt at `qemu+sshcmd://vcows/system`
through the `vcows` entry in `~/.ssh/config`.

| VM | MAC | IP |
|---|---|---|
| Rocky-Cluster-N | `52:54:00:c1:00:0N` | `192.168.150.1N` |

Each VM has 4 vCPU (host-passthrough), 8 GiB RAM, a 20 GiB thin qcow2 overlay on a shared base image,
UEFI with Secure Boot on (Microsoft keys enrolled, so Rocky's signed shim verifies), VNC and a serial
console, and `qemu-guest-agent`. The VMs sit on their own NAT network `rocky-cluster`
(192.168.150.0/24). Every volume tofu creates in the `images` pool is prefixed `rocky-cluster-`.

## Use

```sh
podman build -t rocky-cluster-tofu .
./tofu.sh init
./tofu.sh plan
./tofu.sh apply
./tofu.sh output
./tofu.sh destroy
```

`tofu.sh` mounts this directory at `/work` and `~/.ssh` read-only. The cloud-init user `rocky` gets
every `~/.ssh/*.pub` plus every line of `~/.ssh/authorized_keys`, read at plan time. Keys reach a VM
only at its first boot. A later key change replaces the seed volumes but does not add or revoke keys
on existing VMs.

`node_count` is 1 to 9. The network reserves all nine MAC/IP slots, so scaling only adds or removes VMs.
Changing `disk_gib` rebuilds every VM with a fresh disk and loses guest data, the same as an image swap.
State and the generated cloud-init ISOs live in `/srv/rocky-cluster` on this host, outside the
checkout, so every checkout and session shares one state and its lock. Create it once with
`sudo install -d -o $USER -m 0700 /srv/rocky-cluster`. Deleting `/srv/rocky-cluster/tmp` makes the
next plan replace the seed volumes.

## Access

libvirt blocks forwarding between two NAT networks, so reach the VMs through vcows:

```sh
ssh -J vcows rocky@192.168.150.11
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
`rke2-agent` and `keepalived` (all disabled), `rke2-selinux`, `kernel-modules-extra`, `qemu-guest-agent`,
and HelmCharts for cert-manager and Rancher in `/var/lib/rancher/rke2/server/manifests/`.

No node has a fixed role. At first boot cloud-init starts `rke2-elect` (`cloud-init/rke2_elect.py`). Each
node draws a random token and broadcasts it on UDP 9346, signed with the RKE2 join token. Once 60 s pass
with no node appearing or dropping out (silent for 10 s), the `control_plane_count` (default 3) highest
tokens become servers and the highest bootstraps the cluster. If the elected bootstrap dies before it
starts RKE2, including within about 10 s before the decision, the others wait on the VIP forever.
Recover with `./tofu.sh destroy` and `./tofu.sh apply`. The rest are agents. A node that boots later sees the `decided` beacons or the
VIP and joins as an agent. The servers run keepalived, which holds the VIP `192.168.150.10` on a server
whose RKE2 supervisor answers. Nodes join through `https://192.168.150.10:9345`, and Rancher is served at
`https://rancher.192.168.150.10.sslip.io`. After a reboot the node keeps its role. Nodes pull charts and
container images at runtime. The cloud-init needs this image. The GenericCloud default has no RKE2.

```sh
image/build.sh
./tofu.sh apply -var base_image_url=/work/image/output/rocky-rke2.qcow2
```
