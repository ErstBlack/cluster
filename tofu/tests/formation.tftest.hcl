# Slot 1 of a nightly case that checks formation only (ci/cases.json). CI sets the variables multi.tftest.hcl lists.
# tofu test ignores the backend, so /srv/rocky-cluster is not used.
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
