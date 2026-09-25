#!/usr/bin/env bash
# Build image/output/rocky-rke2.qcow2 from blueprint.toml with the pinned image-builder container.
# Needs root podman: osbuild runs privileged. Also writes the SPDX SBOMs and the osbuild manifest.
# The host store keeps downloaded RPMs between builds. It has to be mounted at the image's VOLUME path.
set -euo pipefail
cd "$(dirname "$0")"

# verify_rpms MANIFEST STORE: every RPM the manifest installs, read from the content-addressed store,
# must carry a valid signature from a key in rocky-10.2.json (Rocky or Rancher). Unsigned fails too.
verify_rpms() {
  local db ids rc
  db=$(mktemp -d)
  jq -r '[.x86_64[].gpgkey] | unique[]' rocky-10.2.json >"$db/keys.asc"
  rpmkeys --dbpath "$db" --import "$db/keys.asc"
  ids=$(jq -r '[.pipelines[].stages[]? | select(.type == "org.osbuild.rpm") | .inputs.packages.references[].id] | unique[]' "$1")
  [ -n "$ids" ] || { echo "verify_rpms: no packages in $1" >&2; rm -rf "$db"; return 1; }
  rc=0
  # shellcheck disable=SC2086 # ids are sha256:<hex>, one per word
  (cd "$2/sources/org.osbuild.files" && rpmkeys --dbpath "$db" --define '_pkgverify_level signature' --checksig $ids) >"$db/out" 2>&1 || rc=1
  grep -v ': digests signatures OK$' "$db/out" >&2 || true
  [ "$rc" = 0 ] && echo "verify_rpms: $(wc -w <<<"$ids") RPMs signed by the Rocky or Rancher key"
  rm -rf "$db"
  return "$rc"
}

mkdir -p output
sudo mkdir -p /var/cache/image-builder/store
# rocky-10.2.json replaces the built-in repo list: v84's Rocky 10.2 x86_64 repos verbatim plus the Rancher repos
# with the Rancher key (925EA29AE257814A) inline. --extra-repo cannot carry a key and is never GPG checked.
# osbuild then rejects a wrongly signed RPM, but its checksig runs at the default digest level and passes an
# unsigned one, so verify_rpms re-checks every installed RPM and deletes the qcow2 on any failure.
sudo podman run --rm --privileged \
  -v "$PWD/blueprint.toml":/blueprint.toml:ro -v "$PWD/rocky-10.2.json":/repos/rocky-10.2.json:ro \
  -v "$PWD/output":/output -v /var/cache/image-builder/store:/var/cache/image-builder/store \
  ghcr.io/osbuild/image-builder-cli:v84.0.0@sha256:0c8cb4725ae52d663e2048a6e488ab0ce98d8733a4b2583c2c6a48c1d12ecbf2 \
  --force-repo-dir /repos build qcow2 --distro rocky-10.2 --blueprint /blueprint.toml \
  --output-dir /output --output-name rocky-rke2 --with-sbom --with-manifest
sudo chown -R "$(id -u):$(id -g)" output
verify_rpms output/rocky-rke2.osbuild-manifest.json /var/cache/image-builder/store || { rm -f output/rocky-rke2.qcow2; exit 1; }
