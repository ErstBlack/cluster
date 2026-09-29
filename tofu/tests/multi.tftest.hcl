# Slot 1 of a CI run with one node per runner on a shared bridge (#53). The other slots each apply their own node.
# CI sets TF_VAR_bridge, TF_VAR_mtu, TF_VAR_rke2_token, TF_VAR_base_image_url, and TF_VAR_nodes to the run's node
# count. tofu test ignores the backend, so /srv/rocky-cluster is not used.
variables {
  libvirt_uri = "qemu:///system"
  slot        = 1
}

run "apply" {
  command = apply

  assert {
    condition     = keys(output.nodes) == ["Rocky-Cluster-1"]
    error_message = "expected only this slot's node, Rocky-Cluster-1"
  }
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

run "vip_failover" {
  module {
    source = "./tests/failover"
  }

  variables {
    vip = run.apply.vip
  }
}
