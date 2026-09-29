# Slot 1 of the rke2-stop case: formation.tftest.hcl, then rke2-server stops on the VIP holder and the VIP moves.
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

run "vip_failover" {
  module {
    source = "./tests/failover"
  }

  variables {
    vip    = run.apply.vip
    action = "sudo systemctl stop rke2-server"
  }
}
