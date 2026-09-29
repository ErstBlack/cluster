variable "libvirt_uri" {
  type    = string
  default = "qemu+sshcmd://vcows/system"
}

variable "pool" {
  type    = string
  default = "images"
}

variable "node_count" {
  type    = number
  default = 9

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
  default = 8192
}

variable "disk_gib" {
  type    = number
  default = 40
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
