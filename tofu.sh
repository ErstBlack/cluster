#!/usr/bin/env bash
# Run tofu from the rocky-cluster-tofu image against this directory.
# ~/.ssh is mounted twice because ~/.ssh/config names the vcows key by absolute path.
# State and TMPDIR (the provider's cloud-init ISOs) live in /srv/rocky-cluster, shared by every checkout.
set -euo pipefail
cd "$(dirname "$0")"
state=/srv/rocky-cluster
[ -d "$state" ] || { echo "missing $state, see README" >&2; exit 1; }
mkdir -p "$state/tmp"
# image/build.sh leaves image/output/rocky-rke2.qcow2 as a symlink into CLUSTER_IMAGE_ARCHIVE when it is set.
archive_mount=()
[[ -n ${CLUSTER_IMAGE_ARCHIVE:-} ]] && archive_mount=(-v "$CLUSTER_IMAGE_ARCHIVE":"$CLUSTER_IMAGE_ARCHIVE":ro)
exec podman run --rm -it --network host --security-opt label=disable \
  -v "$PWD":/work -w /work -v "$state":"$state" -e TMPDIR="$state/tmp" "${archive_mount[@]}" \
  -v "$HOME/.ssh":/root/.ssh:ro -v "$HOME/.ssh":"$HOME/.ssh":ro \
  rocky-cluster-tofu "$@"
