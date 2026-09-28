tofu := env("TOFU", "./tofu.sh")

# List recipes
default:
    @just --list

# Every check CI runs before tofu test
check: unit tofu-check shellcheck ruff actionlint hadolint

# Python unit tests
unit:
    python3 -m unittest discover -s cloud-init

# tofu fmt and tofu validate
tofu-check:
    {{tofu}} fmt -check -recursive
    {{tofu}} init -backend=false
    {{tofu}} validate

shellcheck:
    git ls-files -z '*.sh' | xargs -0 shellcheck

ruff:
    git ls-files -z '*.py' | xargs -0 uvx ruff check
    git ls-files -z '*.py' | xargs -0 uvx ruff format --check

actionlint:
    actionlint

hadolint:
    git ls-files -z '*Containerfile*' '*Dockerfile*' | xargs -0 hadolint

# Build image/output/rocky-rke2.qcow2
image:
    image/build.sh

# Build the rocky-cluster-tofu container
container:
    podman build -t rocky-cluster-tofu .

# Run tofu, e.g. just tofu plan
tofu *args:
    {{tofu}} {{args}}
