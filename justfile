# List recipes
default:
    @just --list

# Every check CI runs before tofu test
check: unit tofu-check shellcheck ruff actionlint

# Python unit tests
unit:
    python3 -m unittest discover -s cloud-init

# tofu fmt and tofu validate
tofu-check:
    tofu fmt -check -recursive
    tofu init -backend=false
    tofu validate

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
    # The provider writes the cloud-init ISOs, which hold the join token, world-readable under TMPDIR. Keep them in
    # the 0700 state directory. CI's runner is single-use.
    if [[ -z ${CI:-} ]]; then
      [[ -d /srv/rocky-cluster ]] || { echo "missing /srv/rocky-cluster, see README" >&2; exit 1; }
      mkdir -p /srv/rocky-cluster/tmp
      export TMPDIR=/srv/rocky-cluster/tmp
    fi
    exec tofu {{args}}
