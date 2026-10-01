#!/usr/bin/env bash
# The storage spike (#91), never merged. Runs as root on one node, fed to ssh by spike/storage.sh: routes the node to the
# internet through its own runner, installs what the candidate needs on the host, and pulls the images.
#   storage-node.sh <candidate> <image>...
# Contracts: cluster.yml's spike step NATs runner N's 192.168.150.(240 + N), and tofu/main.tf gives node N the MAC
# 52:54:00:c1:00:0N and its data disk as vdb.
set -euo pipefail
shopt -s inherit_errexit

candidate=$1
shift
slot=$(sed -n 's/^52:54:00:c1:00:0\([1-9]\)$/\1/p' /sys/class/net/*/address | head -n 1)
: "${slot:?no MAC of the form 52:54:00:c1:00:0N}"
# The site profile routes everything on-link with no gateway or DNS. This route wins on its lower metric.
ip route replace default via "192.168.150.$((240 + slot))"
rm -f /etc/resolv.conf
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' >/etc/resolv.conf

# NFS serves Longhorn's and LINSTOR's RWX filesystems.
pkgs=(nfs-utils)
case $candidate in
  longhorn) pkgs+=(iscsi-initiator-utils cryptsetup) ;;
  linstor) pkgs+=("kernel-devel-$(uname -r)") ;;
esac
SECONDS=0
dnf --assumeyes --quiet install "${pkgs[@]}"
echo "slot $slot: installed ${pkgs[*]} in ${SECONDS}s"

case $candidate in
  longhorn)
    systemctl enable --now iscsid
    modprobe iscsi_tcp
    # Longhorn keeps its replicas under its default data path.
    mkfs.xfs -f -q /dev/vdb
    mkdir -p /var/lib/longhorn
    mount /dev/vdb /var/lib/longhorn
    ;;
  rook-ceph)
    modprobe rbd
    modprobe ceph
    ;;
esac

SECONDS=0
crictl=(/var/lib/rancher/rke2/bin/crictl --runtime-endpoint unix:///run/k3s/containerd/containerd.sock)
for image in "$@"; do
  for try in 1 2 3; do
    "${crictl[@]}" pull "$image" >/dev/null && break
    ((try < 3)) || echo "slot $slot: could not pull $image"
    sleep 5
  done
done
echo "slot $slot: pulled $# images in ${SECONDS}s"
