# Slot 1 of the reboot case: formation.tftest.hcl, then an agent and a server without the VIP reboot and return.
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

run "reboot" {
  module {
    source = "./tests/reboot"
  }

  variables {
    vip = run.apply.vip
  }
}
