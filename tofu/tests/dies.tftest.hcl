# Slot 1 of the dies-before-decision case: formation.tftest.hcl, then some surviving node's election dropped the
# node that died, so the drop path ran rather than the node going unheard.
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

run "dropped_peer" {
  module {
    source = "./tests/dropped_peer"
  }

  variables {
    vip = run.apply.vip
  }
}
