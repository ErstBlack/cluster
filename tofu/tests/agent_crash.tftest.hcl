# Slot 1 of the agent-crash case: formation.tftest.hcl, then one agent crashes and only it goes NotReady.
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

run "agent_crash" {
  module {
    source = "./tests/agent_crash"
  }

  variables {
    vip = run.apply.vip
  }
}
