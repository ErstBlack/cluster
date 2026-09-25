#!/usr/bin/env bash
# Run tofu from the rocky-cluster-tofu image against this directory.
# ~/.ssh is mounted twice because ~/.ssh/config names the vcows key by absolute path.
# TMPDIR lives in the checkout so the provider's cloud-init ISOs survive between runs.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .tmp
exec podman run --rm -it --network host --security-opt label=disable \
  -v "$PWD":/work -w /work -e TMPDIR=/work/.tmp \
  -v "$HOME/.ssh":/root/.ssh:ro -v "$HOME/.ssh":"$HOME/.ssh":ro \
  rocky-cluster-tofu "$@"
