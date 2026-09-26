# One node on the local libvirt. CI sets TF_VAR_base_image_url to the golden image.
# tofu test ignores the backend, so /srv/rocky-cluster is not used.
variables {
  libvirt_uri = "qemu:///system"
  node_count  = 1
}

run "apply" {
  command = apply

  assert {
    condition     = keys(output.nodes) == ["Rocky-Cluster-1"]
    error_message = "expected exactly one node, Rocky-Cluster-1"
  }

  assert {
    condition     = output.nodes["Rocky-Cluster-1"].ip == "192.168.150.11"
    error_message = "Rocky-Cluster-1 is not at 192.168.150.11"
  }

  assert {
    condition     = libvirt_domain.node["1"].running
    error_message = "Rocky-Cluster-1 is not running"
  }
}

run "cluster_ready" {
  module {
    source = "./tests/ready"
  }

  variables {
    ip = run.apply.nodes["Rocky-Cluster-1"].ip
  }
}
