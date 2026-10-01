variable "libvirt_uri" {
  type    = string
  default = "qemu+sshcmd://vcows/system"
}

# The directory of the pool tofu creates. The default keeps every volume in RAM.
variable "pool_dir" {
  type    = string
  default = "/dev/shm/rocky-cluster"
}

variable "node_count" {
  type    = number
  default = 7

  validation {
    condition     = var.node_count >= 1 && var.node_count <= 9 && floor(var.node_count) == var.node_count
    error_message = "node_count must be a whole number from 1 to 9: MACs end :0N."
  }
}

# The top control_plane_count nodes by election token become servers. Odd keeps etcd quorum clean.
variable "control_plane_count" {
  type    = number
  default = 3

  validation {
    condition     = var.control_plane_count >= 1 && floor(var.control_plane_count) == var.control_plane_count && var.control_plane_count % 2 == 1
    error_message = "control_plane_count must be an odd whole number of at least 1."
  }
}

variable "vcpu" {
  type    = number
  default = 4
}

variable "memory_mib" {
  type    = number
  default = 4096
}

variable "disk_gib" {
  type    = number
  default = 40
}

# A second, empty disk per node, vdb, for the storage spike (#91). 0 leaves it out.
variable "data_disk_gib" {
  type    = number
  default = 0
}

# Secure Boot with Microsoft keys enrolled. The storage spike (#91) turns it off for LINSTOR, whose DRBD module is built
# at boot and unsigned.
variable "secure_boot" {
  type    = bool
  default = true
}

variable "base_image_url" {
  description = "URL or local path of the qcow2 base image. Swap for a custom build."
  type        = string
  default     = "https://dl.rockylinux.org/pub/rocky/10/images/x86_64/Rocky-10-GenericCloud-Base.latest.x86_64.qcow2"
}

# The defaults keep one host running every node on its own libvirt network. CI runs one node per runner (#53).

# Only node <slot> runs here, so each host of a multi-host run starts its own node with its own MAC.
variable "slot" {
  type    = number
  default = null

  validation {
    condition     = var.slot == null ? true : var.slot >= 1 && var.slot <= 9 && floor(var.slot) == var.slot
    error_message = "slot must be a whole number from 1 to 9: MACs end :0N."
  }
}

# Every host of a run must pass the same token. Null mints one per apply.
variable "rke2_token" {
  type      = string
  default   = null
  sensitive = true
}

# An existing host bridge that replaces the libvirt network. The node gets no gateway or DNS on it.
variable "bridge" {
  type    = string
  default = null
}

# The node's NIC MTU, set through libvirt. Null leaves libvirt's default.
variable "mtu" {
  type    = number
  default = null
}
