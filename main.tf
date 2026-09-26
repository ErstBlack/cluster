terraform {
  # Shared by every checkout on this host. tofu.sh mounts the directory at the same path.
  backend "local" {
    path = "/srv/rocky-cluster/terraform.tfstate"
  }

  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.9.9"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}

provider "libvirt" {
  uri = var.libvirt_uri
}

locals {
  prefix  = "rocky-cluster"
  ssh_dir = pathexpand("~/.ssh")

  # Every ~/.ssh/*.pub plus every non-empty, non-comment line of ~/.ssh/authorized_keys.
  authorized_keys_file = "${local.ssh_dir}/authorized_keys"
  ssh_keys = distinct(concat(
    [for f in sort(fileset(local.ssh_dir, "*.pub")) : trimspace(file("${local.ssh_dir}/${f}"))],
    fileexists(local.authorized_keys_file) ? [
      for l in split("\n", file(local.authorized_keys_file)) : trimspace(l)
      if trimspace(l) != "" && !startswith(trimspace(l), "#")
    ] : [],
  ))

  # Fixed so that scaling never changes the network: the network resource is replaced on any change.
  network_cidr = "192.168.150.0/24"

  # Reservations cover every slot the MAC :0N / IP .1N scheme allows, so node_count only adds or removes VMs.
  slots = {
    for n in range(1, 10) : tostring(n) => {
      name     = "Rocky-Cluster-${n}"
      hostname = "${local.prefix}-${n}"
      mac      = format("52:54:00:c1:00:%02x", n)
      ip       = cidrhost(local.network_cidr, 10 + n)
    }
  }
  nodes = { for k, v in local.slots : k => v if tonumber(k) <= var.node_count }

  # Node 1 initializes the RKE2 cluster and every other node joins it. All nodes are servers.
  init_ip          = local.slots["1"].ip
  rancher_hostname = "rancher.${local.init_ip}.sslip.io"
}

resource "random_password" "rke2_token" {
  length  = 48
  special = false
}

resource "libvirt_network" "cluster" {
  name      = local.prefix
  autostart = true
  forward   = { mode = "nat" }
  bridge    = { name = "virbr-rcluster" }
  ips = [{
    address = cidrhost(local.network_cidr, 1)
    prefix  = tonumber(split("/", local.network_cidr)[1])
    dhcp = {
      ranges = [{
        start = cidrhost(local.network_cidr, 100)
        end   = cidrhost(local.network_cidr, 254)
      }]
      hosts = [for n, v in local.slots : { mac = v.mac, ip = v.ip, name = v.hostname }]
    }
  }]
}

resource "libvirt_volume" "base" {
  name   = "${local.prefix}-base-rocky10.qcow2"
  pool   = var.pool
  target = { format = { type = "qcow2" } }
  create = { content = { url = var.base_image_url } }
}

# Stands in for the RequiresReplace that provider v0.9.9 lacks on volume capacity (its Update always errors).
# Remove once the provider marks capacity as forcing replacement.
resource "terraform_data" "disk_size" {
  triggers_replace = var.disk_gib
}

resource "libvirt_volume" "disk" {
  for_each = local.nodes

  name     = "${each.value.hostname}.qcow2"
  pool     = var.pool
  capacity = var.disk_gib * 1024 * 1024 * 1024
  target   = { format = { type = "qcow2" } }
  backing_store = {
    path   = libvirt_volume.base.path
    format = { type = "qcow2" }
  }

  # The base keeps its path when replaced, so rebuild the overlays rather than re-back them onto a new image.
  # A disk_gib change rebuilds them too (see terraform_data.disk_size).
  lifecycle {
    replace_triggered_by = [libvirt_volume.base.id, terraform_data.disk_size.id]
  }
}

resource "libvirt_cloudinit_disk" "seed" {
  for_each = local.nodes

  name = "${each.value.hostname}-seed"
  user_data = templatefile("${path.module}/cloud-init/user-data.yaml.tftpl", {
    ssh_keys         = local.ssh_keys
    token            = random_password.rke2_token.result
    node_ip          = each.value.ip
    server           = each.key == "1" ? "" : "https://${local.init_ip}:9345"
    rancher_hostname = local.rancher_hostname
  })
  meta_data = yamlencode({
    instance-id    = each.value.hostname
    local-hostname = each.value.hostname
  })
}

resource "libvirt_volume" "seed" {
  for_each = local.nodes

  name   = "${each.value.hostname}-seed.iso"
  pool   = var.pool
  create = { content = { url = libvirt_cloudinit_disk.seed[each.key].path } }
}

resource "libvirt_domain" "node" {
  for_each = local.nodes

  name        = each.value.name
  type        = "kvm"
  vcpu        = var.vcpu
  memory      = var.memory_mib
  memory_unit = "MiB"
  running     = true

  cpu = { mode = "host-passthrough" }
  # The sb-enrolled OVMF build requires SMM.
  features = { acpi = true, apic = {}, smm = { state = "on" } }

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
    firmware     = "efi"
    # Secure Boot with Microsoft keys enrolled, so Rocky's signed shim verifies.
    # Order matches libvirt's read-back.
    firmware_info = {
      features = [
        { name = "enrolled-keys", enabled = "yes" },
        { name = "secure-boot", enabled = "yes" },
      ]
    }
  }

  devices = {
    disks = [
      {
        source = { volume = { pool = var.pool, volume = libvirt_volume.disk[each.key].name } }
        target = { bus = "virtio", dev = "vda" }
        driver = { type = "qcow2" }
      },
      {
        device = "cdrom"
        source = { volume = { pool = var.pool, volume = libvirt_volume.seed[each.key].name } }
        target = { bus = "sata", dev = "sda" }
      },
    ]

    interfaces = [{
      mac    = { address = each.value.mac }
      model  = { type = "virtio" }
      source = { network = { network = libvirt_network.cluster.name } }
    }]

    graphics = [{ vnc = { auto_port = true, listen = "127.0.0.1" } }]

    # No source means type pty. The pty source schema requires a path, which libvirt assigns at start.
    # libvirt adds the matching serial console itself.
    serials = [{ target = { port = 0 } }]

    channels = [{
      source = { unix = {} }
      target = { virt_io = { name = "org.qemu.guest_agent.0" } }
    }]
  }

  # A rebuilt overlay needs a fresh domain; a running VM must not keep a deleted disk open.
  lifecycle {
    replace_triggered_by = [libvirt_volume.disk[each.key].id]
  }
}
