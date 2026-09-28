# List recipes
default:
    @just --list

# Every check CI runs before tofu test
check: unit tofu-check cloud-init-schema shellcheck ruff actionlint

# Python unit tests
unit:
    python3 -m unittest discover -s cloud-init

# tofu fmt and tofu validate
tofu-check:
    tofu fmt -check -recursive
    tofu init -backend=false
    tofu validate

# Render the user-data with sample values and validate it with Rocky 10's cloud-init
cloud-init-schema:
    #!/usr/bin/env bash
    set -euo pipefail
    dir={{justfile_directory()}}/cloud-init
    # Without python3-jsonschema, cloud-init skips validation and exits 0.
    containerfile='FROM docker.io/rockylinux/rockylinux:10
    RUN dnf install -y cloud-init python3-jsonschema && dnf clean all'
    # The tag is the Containerfile's hash, so a changed Containerfile builds a new image. The image is otherwise built
    # once. podman rmi the tag to pick up a newer Rocky 10 cloud-init.
    image=localhost/cluster-cloud-init:$(sha256sum <<< "$containerfile" | cut -c1-12)
    podman image exists "$image" || podman build -t "$image" - <<< "$containerfile"
    # tofu console runs in an empty directory so it does not load main.tf or the shared state.
    cd "$(mktemp -d)"
    echo "base64encode(templatefile(\"$dir/user-data.yaml.tftpl\", {ssh_keys = [\"ssh-ed25519 AAAA sample\"], token = \"sample\", vip = \"192.0.2.10/24\", gateway = \"192.0.2.1\", dns = \"192.0.2.1\", control_plane_count = 3, addr_py = file(\"$dir/node_addr.py\"), elect_py = file(\"$dir/rke2_elect.py\"), configure_py = file(\"$dir/rke2_configure.py\")}))" \
      | tofu console | tr -d '"' | base64 -d \
      | podman run --rm -i "$image" sh -c 'cat > /tmp/user-data && cloud-init schema --config-file /tmp/user-data'

shellcheck:
    git ls-files -z '*.sh' | xargs -0 shellcheck

ruff:
    git ls-files -z '*.py' | xargs -0 uvx ruff check
    git ls-files -z '*.py' | xargs -0 uvx ruff format --check

actionlint:
    actionlint

# Build image/output/rocky-rke2.qcow2
image:
    image/build.sh

# Run tofu, e.g. just tofu plan
tofu *args:
    #!/usr/bin/env bash
    set -euo pipefail
    # The provider writes the cloud-init ISOs, which hold the join token, under TMPDIR with 0644. umask keeps them
    # owner-only. On a workstation they also stay in the state directory, so their path in state does not change.
    umask 077
    if [[ -z ${CI:-} ]]; then
      [[ -d /srv/rocky-cluster ]] || { echo "missing /srv/rocky-cluster, see README" >&2; exit 1; }
      mkdir -p /srv/rocky-cluster/tmp
      export TMPDIR=/srv/rocky-cluster/tmp
    fi
    exec tofu {{args}}
