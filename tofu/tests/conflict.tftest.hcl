# Slot 1 of the addr-conflict case: formation.tftest.hcl, then every node in .2 to .20 and a conflict logged.
variables {
  libvirt_uri = "qemu:///system"
  slot        = 1
}

run "apply" {}

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

run "addr_conflict" {
  module {
    source = "./tests/addr_conflict"
  }

  variables {
    vip = run.apply.vip
  }
}
