#!/usr/bin/env bash
# Build image/output/rocky-rke2.qcow2 from blueprint.toml with the pinned image-builder container.
# Needs root podman: osbuild runs privileged. Also writes the SPDX SBOMs and the osbuild manifest.
# The host store keeps downloaded RPMs between builds. It has to be mounted at the image's VOLUME path.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p output
sudo mkdir -p /var/cache/image-builder/store
# ponytail: --extra-repo is not GPG checked, only TLS to rpm.rancher.io. A --force-data-dir
# repositories file with gpgkeys adds the check if the build moves off a trusted network.
sudo podman run --rm --privileged \
  -v "$PWD/blueprint.toml":/blueprint.toml:ro -v "$PWD/output":/output -v /var/cache/image-builder/store:/var/cache/image-builder/store \
  ghcr.io/osbuild/image-builder-cli:v84.0.0@sha256:0c8cb4725ae52d663e2048a6e488ab0ce98d8733a4b2583c2c6a48c1d12ecbf2 \
  build qcow2 --distro rocky-10.2 --blueprint /blueprint.toml \
  --extra-repo https://rpm.rancher.io/rke2/stable/common/centos/10/noarch \
  --extra-repo https://rpm.rancher.io/rke2/stable/1.36/centos/10/x86_64 \
  --output-dir /output --output-name rocky-rke2 --with-sbom --with-manifest
sudo chown -R "$(id -u):$(id -g)" output
