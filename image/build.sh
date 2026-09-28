#!/usr/bin/env bash
# Build image/output/rocky-rke2.qcow2 from blueprint.toml with the pinned image-builder container.
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
blueprint=blueprint.toml airgap_mount=() airgap_repo=()
# SKIP_AIRGAP builds without the pre-imported images, and nodes pull them at first boot. CI sets it.
if [[ -z ${SKIP_AIRGAP:-} ]]; then
  ./airgap.sh
  cat blueprint.toml airgap.toml > output/blueprint.toml
  blueprint=output/blueprint.toml airgap_mount=(-v "$PWD/output/airgap-repo":/airgap-repo:ro)
  airgap_repo=(--extra-repo file:///airgap-repo)
fi
sudo mkdir -p "$store"
# A previous archived build left a symlink here. Remove it so image-builder writes a fresh file, not through the link.
[[ -L output/rocky-rke2.qcow2 ]] && rm output/rocky-rke2.qcow2
sudo podman run --rm --privileged -v "$PWD/$blueprint":/blueprint.toml:ro "${airgap_mount[@]}" \
  -v "$PWD/rocky-10.2.json":/repos/rocky-10.2.json:ro -v "$PWD/output":/output -v "$store":"$store" "$img" \
  --force-repo-dir /repos "${airgap_repo[@]}" build qcow2 --distro rocky-10.2 --blueprint /blueprint.toml \
  --output-dir /output --output-name rocky-rke2 2>&1 | tee output/build.log
sudo chown -R "$(id -u):$(id -g)" output
# rpm only warns when a %post fails and osbuild checks rpm's exit code, so a failed extract still builds an image.
if grep -q 'scriptlet failed' output/build.log; then
  echo "a %post scriptlet failed, see output/build.log; output/rocky-rke2.qcow2 is incomplete" >&2
  exit 1
fi
# CLUSTER_IMAGE_ARCHIVE moves the finished image out of the checkout and leaves a symlink in its place.
if [[ -n ${CLUSTER_IMAGE_ARCHIVE:-} ]]; then
  dest=$CLUSTER_IMAGE_ARCHIVE/$(date -u +%Y%m%dT%H%M%SZ)
  mkdir -p "$dest"
  mv output/rocky-rke2.qcow2 "$dest"/
  cp output/build.log "$dest"/
  ln -s "$dest/rocky-rke2.qcow2" output/rocky-rke2.qcow2
  echo "archived to $dest"
fi
