#!/usr/bin/env bash
# Run tofu from the rocky-cluster-tofu image against this directory.
# ~/.ssh is mounted twice because ~/.ssh/config names the vcows key by absolute path.
# State and TMPDIR (the provider's cloud-init ISOs) live in /srv/rocky-cluster, shared by every checkout.
set -euo pipefail
cd "$(dirname "$0")"
state=/srv/rocky-cluster
[ -d "$state" ] || { echo "missing $state, see README" >&2; exit 1; }
mkdir -p "$state/tmp"
exec podman run --rm -it --network host --security-opt label=disable \
  -v "$PWD":/work -w /work -v "$state":"$state" -e TMPDIR="$state/tmp" \
  -v "$HOME/.ssh":/root/.ssh:ro -v "$HOME/.ssh":"$HOME/.ssh":ro \
  rocky-cluster-tofu "$@"
