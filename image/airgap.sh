#!/usr/bin/env bash
# Package the images in airgap-images.txt, pre-imported, as the RPM rke2-airgap-images in output/airgap-repo.
# Usage: airgap.sh [cache dir]
#
# Fetch: a https:// line is the RKE2 airgap tarball. Its release must match the rke2-server pin in blueprint.toml, and a
# download is checked against the release's sha256sum-amd64.txt. Any other line is an image ref, saved with skopeo as
# <ref minus registry, / and : as _>.tar. Only missing files are fetched.
# Seed: RKE2's own containerd, from the rke2-runtime image in that tarball, imports every file into namespace k8s.io
# of a root at /var/lib/rancher/rke2/agent/containerd with the overlayfs snapshotter. It sets the pinned labels RKE2's
# importer sets (k3s preloadFile/labelImages). The content store, meta.db and unpacked snapshots are tarred with their
# overlay whiteouts and xattrs. The state is tied to this RKE2 release's containerd, so an RKE2 bump means a reseed.
# The tar also carries rke2-runtime's bin and charts, staged where RKE2's bootstrap Stage looks, so RKE2 skips pulling
# that image from the registry at first start.
# Package: rpmbuild and createrepo_c run in a Rocky 10 container, so the host needs only podman, curl and skopeo.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
cache=${1:-/srv/rocky-cluster/images/agent-images}
img=docker.io/rockylinux/rockylinux:10@sha256:827d37bc128288ccf160ee318bb3cb92d591164cb217e92f8bc61e3982ae1834

mkdir -p "$cache" output
files=()
for e in $(sed 's/#.*//' airgap-images.txt); do
  if [[ $e == https://* ]]; then
    f=${e##*/} tag=${e%/*}
    tag=${tag##*/}
    pin=$(grep -A1 '^name = "rke2-server"' blueprint.toml | sed -n 's/^version = "\(.*\)"/\1/p')
    [[ $tag == "v${pin/\~/%2B}" ]] || { echo "RKE2 $tag in airgap-images.txt does not match rke2-server $pin" >&2; exit 1; }
    if [[ ! -e $cache/$f ]]; then
      curl -fL -o "$cache/$f.part" "$e"
      echo "$(curl -fsSL "${e%/*}/sha256sum-amd64.txt" | awk -v f="$f" '$2 == f {print $1}')  $cache/$f.part" | sha256sum -c
      mv "$cache/$f.part" "$cache/$f"
    fi
    rke2=$f runtime=rancher/rke2-runtime:${tag/\%2B/-}
  else
    r=${e#*/}
    f=${r//[\/:]/_}.tar
    if [[ ! -e $cache/$f ]]; then
      rm -f "$cache/$f.part"
      skopeo copy "docker://$e" "docker-archive:$cache/$f.part:$e"
      mv "$cache/$f.part" "$cache/$f"
    fi
  fi
  files+=("$f")
done

rpm=(output/airgap-repo/noarch/rke2-airgap-images-*.rpm)
fresh=1
[[ -e ${rpm[0]} && -e output/airgap-repo/repodata/repomd.xml ]] || fresh=
for f in airgap-images.txt airgap.sh rke2-airgap-images.spec "${files[@]/#/$cache/}"; do
  [[ ${rpm[0]} -nt $f ]] || fresh=
done
if [[ -n $fresh ]]; then
  echo "${rpm[0]} is up to date"
  exit 0
fi

sudo rm -rf output/airgap output/airgap-repo
mkdir -p output/airgap/root output/airgap-repo
sudo podman run --rm -i --privileged -v "$cache":/cache:ro -v "$PWD":/src:ro -v "$PWD/output":/out \
  -v "$PWD/output/airgap/root":/var/lib/rancher/rke2/agent/containerd \
  -e RKE2="$rke2" -e RUNTIME="$runtime" -e FILES="${files[*]}" -e OWNER="$(id -u):$(id -g)" "$img" bash -s <<'EOF'
set -euo pipefail
dnf -y -q --setopt=install_weak_deps=False install rpm-build createrepo_c zstd jq

mkdir /rt /tmp/rke2
cd /tmp/rke2
tar --zstd -xf "/cache/$RKE2" manifest.json
layers=$(jq -r --arg t "$RUNTIME" '.[] | select(.RepoTags | index($t)) | .Layers[]' manifest.json)
[[ -n $layers ]] || { echo "$RUNTIME is not in $RKE2" >&2; exit 1; }
tar --zstd -xf "/cache/$RKE2" $layers
for l in $layers; do tar -xf "$l" -C /rt; done
export PATH=/rt/bin:$PATH

# Stage in rke2 pkg/bootstrap/bootstrap.go skips the runtime pull when data/<refDigest>/bin, charts and .extracted exist.
# releaseRefDigest: the tag plus the first 12 hex of sha256(ref.String()), and String() is the unresolved default ref.
data=/var/lib/rancher/rke2/data/${RUNTIME#*:}-$(printf %s "$RUNTIME" | sha256sum | cut -c1-12)
mkdir -p "$data"
cp -a /rt/bin /rt/charts "$data"/
chmod 0755 "$data/bin"
printf %s "index.docker.io/$RUNTIME" > "$data/.extracted"

root=/var/lib/rancher/rke2/agent/containerd
containerd --root "$root" --state /run/containerd >/out/airgap/containerd.log 2>&1 &
pid=$!
for _ in {1..120}; do ctr version >/dev/null 2>&1 && break; sleep 1; done
ctr version >/dev/null
for f in $FILES; do
  echo "importing $f"
  # RKE2 imports all platforms but skips missing content, and the tarball's indexes carry only amd64 blobs. ctr has
  # no skip, so it imports the host platform: the same content ends up present.
  zstd -dcf "/cache/$f" | ctr -n k8s.io images import --local \
    --label io.cattle.rke2.pinned=pinned --label io.cri-containerd.pinned=pinned -
done
ctr -n k8s.io images ls -q > /out/airgap/images.txt
echo "$(wc -l < /out/airgap/images.txt) images in k8s.io"
kill "$pid"
wait "$pid" || true

# Only the state RKE2's containerd reads back, plus the staged runtime. Sockets and task state live under --state,
# outside the root.
# security.selinux is left out: osbuild labels the tree with rke2-selinux's contexts.
cd /
tar -c --xattrs --xattrs-include='*' --xattrs-exclude=security.selinux --numeric-owner \
  "${root#/}"/io.containerd.{content.v1.content,metadata.v1.bolt,snapshotter.v1.overlayfs} "${data#/}" |
  zstd -T0 -q -o /out/airgap/containerd-state.tar.zst
rm -rf "${root:?}"/*

rpmbuild -bb --define "_topdir /tmp/rpmbuild" --define "_sourcedir /out/airgap" --define "_rpmdir /out/airgap-repo" \
  /src/rke2-airgap-images.spec
rm /out/airgap/containerd-state.tar.zst
createrepo_c -q /out/airgap-repo
chown -R "$OWNER" /out/airgap /out/airgap-repo
EOF
