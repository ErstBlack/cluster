# Slot 1 of a nightly case that checks formation only (ci/cases.json). CI sets the variables multi.tftest.hcl lists,
# except TF_VAR_nodes, plus TF_VAR_expect_nodes and TF_VAR_expect_servers, the nodes and control-plane nodes the
# case must end with. tofu test ignores the backend, so /srv/rocky-cluster is not used.
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
    servers = var.expect_servers
    nodes   = var.expect_nodes
  }
}
