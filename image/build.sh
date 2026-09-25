#!/usr/bin/env bash
# Build image/output/rocky-rke2.qcow2 from blueprint.toml with the pinned image-builder container.
# Needs root podman: osbuild runs privileged. Also writes the SPDX SBOMs and the osbuild manifest.
# The host store keeps downloaded RPMs between builds. It has to be mounted at the image's VOLUME path.
#
# RPMs are verified before osbuild runs anything. rocky-10.2.json replaces the built-in repo list with v84's
# Rocky 10.2 x86_64 repos verbatim plus the Rancher repos, and holds both signing keys (Rancher 925EA29AE257814A).
# Every RPM the manifest names is checked for its sha256 and for a valid signature from one of those keys.
# Unsigned RPMs fail too. Verified files go into the store, and osbuild then runs that manifest with no network,
# so it installs only those files. osbuild's own checksig passes unsigned RPMs, so it is not relied on.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
img=ghcr.io/osbuild/image-builder-cli:v84.0.0@sha256:0c8cb4725ae52d663e2048a6e488ab0ce98d8733a4b2583c2c6a48c1d12ecbf2
store=/var/cache/image-builder/store
manifest=output/rocky-rke2.osbuild-manifest.json

# verify_rpms DIR: every file in DIR must be named by its sha256 and carry a valid signature from a key in
# rocky-10.2.json. Each file is judged by its own rpmkeys output line. rpmkeys' exit status is the failure count
# mod 256, so it is not used.
verify_rpms() {
  local db f n=0 bad=0
  db=$(mktemp -d)
  jq -r '[.x86_64[].gpgkey] | unique[]' rocky-10.2.json >"$db/keys.asc"
  rpmkeys --dbpath "$db" --import "$db/keys.asc"
  for f in "$1"/*; do
    n=$((n + 1))
    if [ "sha256:$(sha256sum <"$f" | cut -d' ' -f1)" != "${f##*/}" ] ||
      [ "$(rpmkeys --dbpath "$db" --define '_pkgverify_level signature' --checksig "$f" 2>&1)" != "$f: digests signatures OK" ]; then
      echo "verify_rpms: ${f##*/} failed" >&2
      bad=$((bad + 1))
    fi
  done
  rm -rf "$db"
  [ "$n" -gt 0 ] && [ "$bad" = 0 ] && echo "verify_rpms: $n RPMs verified against the Rocky and Rancher keys"
}

main() {
  local id url
  mkdir -p output
  sudo mkdir -p "$store/sources/org.osbuild.files"
  # shellcheck disable=SC2024 # the manifest is meant to be written as the invoking user
  sudo podman run --rm -v "$PWD/blueprint.toml":/blueprint.toml:ro -v "$PWD/rocky-10.2.json":/repos/rocky-10.2.json:ro \
    -v "$PWD/output":/output "$img" \
    --force-repo-dir /repos manifest qcow2 --distro rocky-10.2 --blueprint /blueprint.toml --output-dir /output --with-sbom \
    >"$manifest"
  work=$(mktemp -d -p /var/tmp rocky-rke2-rpms.XXXXXX)
  trap 'rm -rf "$work"' EXIT
  mkdir "$work/rpms"
  # One "id url" line per RPM. Any mirror that is not a plain baseurl stops the build.
  jq -r '.sources["org.osbuild.librepo"] as $s | $s.items | to_entries[] | $s.options.mirrors[.value.mirror] as $m
    | if $m.type == "baseurl" then "\(.key) \($m.url | rtrimstr("/"))/\(.value.path)" else error("mirror not baseurl: \(.value.mirror)") end' \
    "$manifest" >"$work/list"
  # Every package an rpm stage installs has to be one of the RPMs verified here.
  jq -e '([.pipelines[].stages[]? | select(.type == "org.osbuild.rpm") | .inputs.packages.references[].id] | unique)
    - (.sources["org.osbuild.librepo"].items | keys) == []' "$manifest" >/dev/null
  while read -r id url; do
    if [ -f "$store/sources/org.osbuild.files/$id" ]; then
      cp "$store/sources/org.osbuild.files/$id" "$work/rpms/$id"
    else
      curl -fsSL -o "$work/rpms/$id" "$url"
    fi
  done <"$work/list"
  verify_rpms "$work/rpms"
  sudo cp "$work/rpms"/sha256:* "$store/sources/org.osbuild.files/"
  while read -r id url; do [ -f "$store/sources/org.osbuild.files/$id" ]; done <"$work/list"
  # No network: osbuild can only use what is already in the store.
  sudo podman run --rm --privileged --network none -v "$PWD/output":/output -v "$store":"$store" --entrypoint osbuild "$img" \
    --store "$store" --output-directory /output --export qcow2 "/$manifest"
  sudo mv output/qcow2/disk.qcow2 output/rocky-rke2.qcow2
  sudo rmdir output/qcow2
  for f in output/rocky-10.2-qcow2-x86_64.*.spdx.json; do sudo mv "$f" "output/rocky-rke2.${f#output/rocky-10.2-qcow2-x86_64.}"; done
  sudo chown -R "$(id -u):$(id -g)" output
}

# Sourcing the script defines verify_rpms without building.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main; fi
