# Slot 1 of a CI run with one node per runner on a shared bridge (#53). The other slots each apply their own node.
# CI sets TF_VAR_bridge, TF_VAR_mtu, TF_VAR_rke2_token and TF_VAR_base_image_url, plus TF_VAR_expect_nodes and
# TF_VAR_expect_servers, the nodes and control-plane nodes the run must end with. tofu test ignores the backend, so
# /srv/rocky-cluster is not used.
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

# Before vip_failover, which powers off the VIP holder this check runs on.
run "guest_mtu" {
  module {
    source = "./tests/mtu"
  }

  variables {
    vip = run.apply.vip
    mtu = var.mtu
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
