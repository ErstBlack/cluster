tofu := env("TOFU", "./tofu.sh")

# List recipes
default:
    @just --list

# Unit tests, tofu fmt and tofu validate
check:
    python3 -m unittest discover -s cloud-init
    {{tofu}} fmt -check -recursive
    {{tofu}} init -backend=false
    {{tofu}} validate

# Build image/output/rocky-rke2.qcow2
image:
    image/build.sh

# Build the rocky-cluster-tofu container
container:
    podman build -t rocky-cluster-tofu .

# Run tofu, e.g. just tofu plan
tofu *args:
    {{tofu}} {{args}}
