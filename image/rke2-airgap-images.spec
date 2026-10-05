# Built by airgap.sh. Ships RKE2's containerd root with the RKE2 airgap images already imported and unpacked.
# %post extracts it once, at image build, and deletes the tarball. The state includes rke2-runtime's bin and charts
# under /var/lib/rancher/rke2/data. The tarball is already zstd, so payload compression stays at a fast level.
%global _binary_payload w3T.zstdio
%global state /usr/share/rke2-airgap-images/containerd-state.tar.zst

Name:           rke2-airgap-images
Version:        1
Release:        1
Summary:        Pre-imported RKE2 images for RKE2's containerd
License:        Various
BuildArch:      noarch
Source0:        containerd-state.tar.zst
Requires(post): tar zstd

%description
The containerd content store, meta.db and overlayfs snapshots under /var/lib/rancher/rke2/agent/containerd,
with overlay whiteouts and xattrs, for the RKE2 release the rke2-server pin in blueprint.toml names.

%install
install -D -m 0600 %{SOURCE0} %{buildroot}%{state}

# GNU tar only warns and exits 0 when it cannot set an xattr, which would silently drop trusted.overlay.opaque. Any
# output from tar fails the install.
%post
err=$(tar --zstd -xpf %{state} -C / --xattrs --xattrs-include='*' --numeric-owner 2>&1) && [ -z "$err" ] ||
  { echo "$err" >&2; exit 1; }
rm -f %{state}

%files
%{state}
