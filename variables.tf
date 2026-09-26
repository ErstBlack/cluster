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
    error_message = "node_count must be a whole number from 1 to 9: MACs end :0N and IPs end .1N."
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
  default = 20
}

variable "base_image_url" {
  description = "URL or local path of the qcow2 base image. Swap for a custom build."
  type        = string
  default     = "https://dl.rockylinux.org/pub/rocky/10/images/x86_64/Rocky-10-GenericCloud-Base.latest.x86_64.qcow2"
}
