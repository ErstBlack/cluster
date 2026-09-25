#!/usr/bin/env bash
# Build image/output/rocky-rke2.qcow2 from blueprint.toml with the pinned image-builder container.
# Needs root podman: osbuild runs privileged. Also writes the SPDX SBOMs and the osbuild manifest.
# The host store keeps downloaded RPMs between builds. It has to be mounted at the image's VOLUME path.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p output
sudo mkdir -p /var/cache/image-builder/store
# rocky-10.2.json replaces the built-in repo list: v84's Rocky 10.2 x86_64 repos verbatim plus the
# Rancher repos with the Rancher key (925EA29AE257814A) inline, so an unsigned or wrongly signed RPM fails the build.
# --extra-repo cannot carry a key and is never GPG checked.
sudo podman run --rm --privileged \
  -v "$PWD/blueprint.toml":/blueprint.toml:ro -v "$PWD/rocky-10.2.json":/repos/rocky-10.2.json:ro \
  -v "$PWD/output":/output -v /var/cache/image-builder/store:/var/cache/image-builder/store \
  ghcr.io/osbuild/image-builder-cli:v84.0.0@sha256:0c8cb4725ae52d663e2048a6e488ab0ce98d8733a4b2583c2c6a48c1d12ecbf2 \
  --force-repo-dir /repos build qcow2 --distro rocky-10.2 --blueprint /blueprint.toml \
  --output-dir /output --output-name rocky-rke2 --with-sbom --with-manifest
sudo chown -R "$(id -u):$(id -g)" output
