#!/usr/bin/env bash
# Build image/output/rocky-rke2.qcow2 and its SPDX SBOMs from blueprint.toml with the pinned image-builder container.
# Needs root podman: osbuild runs privileged. The host store keeps downloaded RPMs between builds. It has to be
# mounted at the image's VOLUME path.
#
# rocky-10.2.json replaces the built-in repo list with v84's Rocky 10.2 x86_64 repos verbatim plus the Rancher repos,
# and holds both signing keys. Every repo sets check_gpg, so osbuild checks each RPM's digest against the repo
# metadata and each signed RPM's signature. osbuild passes unsigned RPMs. The per-RPM signature verification that
# failed them was dropped. a9c4d25 has it.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
img=ghcr.io/osbuild/image-builder-cli:v84.0.0@sha256:0c8cb4725ae52d663e2048a6e488ab0ce98d8733a4b2583c2c6a48c1d12ecbf2
store=/var/cache/image-builder/store

mkdir -p output
sudo mkdir -p "$store"
# --output-name makes image-builder write rocky-rke2.qcow2. The SBOMs come out as rocky-rke2.2-qcow2-x86_64.<pipeline>.spdx.json
# and are renamed to rocky-rke2.<pipeline>.spdx.json below.
sudo podman run --rm --privileged -v "$PWD/blueprint.toml":/blueprint.toml:ro \
  -v "$PWD/rocky-10.2.json":/repos/rocky-10.2.json:ro -v "$PWD/output":/output -v "$store":"$store" "$img" \
  --force-repo-dir /repos build qcow2 --distro rocky-10.2 --blueprint /blueprint.toml --output-dir /output \
  --output-name rocky-rke2 --with-sbom
sudo chown -R "$(id -u):$(id -g)" output
for f in output/rocky-rke2.2-qcow2-x86_64.*.spdx.json; do mv "$f" "output/rocky-rke2.${f#output/rocky-rke2.2-qcow2-x86_64.}"; done
