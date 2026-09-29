# Three nodes on the local libvirt. CI sets TF_VAR_base_image_url to the golden image.
# tofu test ignores the backend, so /srv/rocky-cluster is not used.
variables {
  libvirt_uri = "qemu:///system"
  node_count  = 3
}

run "apply" {
  command = apply

  assert {
    condition     = keys(output.nodes) == ["Rocky-Cluster-1", "Rocky-Cluster-2", "Rocky-Cluster-3"]
    error_message = "expected exactly three nodes, Rocky-Cluster-1 to Rocky-Cluster-3"
  }
}

run "cluster_ready" {
  module {
    source = "./tests/ready"
  }

  variables {
    vip     = run.apply.vip
    servers = 3
    nodes   = 3
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
