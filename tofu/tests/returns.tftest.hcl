# Slot 1 of the holder-returns case: formation.tftest.hcl, then the VIP holder reboots, the VIP moves, the old
# holder returns, and the VIP stays where it moved.
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

run "vip_failover" {
  module {
    source = "./tests/failover"
  }

  variables {
    vip    = run.apply.vip
    action = "sudo systemctl reboot --force --force"
  }
}

run "rejoin" {
  module {
    source = "./tests/rejoin"
  }

  variables {
    vip = run.apply.vip
  }
}
