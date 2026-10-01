# The storage spike (#91), never merged: slot 1 of a cluster.yml run with spike set. Like multi, plus TF_VAR_candidate
# naming the storage candidate spike/storage.sh installs and measures. tofu test ignores the backend.
variables {
  libvirt_uri = "qemu:///system"
  slot        = 1
}

run "apply" {
  command = apply
}

run "cluster_ready" {
  module {
    source = "./tests/ready"
  }

  variables {
    vip     = run.apply.vip
    servers = 3
    nodes   = var.nodes
  }
}

run "storage" {
  module {
    source = "./tests/storage"
  }

  variables {
    vip       = run.apply.vip
    candidate = var.candidate
    nodes     = var.nodes
  }
}
