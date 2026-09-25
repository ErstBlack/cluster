# cluster

OpenTofu project that runs five Rocky Linux 10 VMs, `Rocky-Cluster-1` to `Rocky-Cluster-5`, on the
KVM host `vcows`. Tofu runs in a podman container and reaches libvirt at `qemu+sshcmd://vcows/system`
through the `vcows` entry in `~/.ssh/config`.

| VM | MAC | IP |
|---|---|---|
| Rocky-Cluster-N | `52:54:00:c1:00:0N` | `192.168.150.1N` |

Each VM has 4 vCPU (host-passthrough), 4 GiB RAM, a 20 GiB thin qcow2 overlay on a shared base image,
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
State and the generated cloud-init ISOs (`.tmp/`) stay local and are gitignored. Deleting `.tmp/`
makes the next plan replace the seed volumes.

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

Open-source build options: `virt-customize` / `virt-builder` (libguestfs) on top of GenericCloud, or
osbuild `image-builder` / `kiwi` from scratch.
