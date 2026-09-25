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
  default = 5

  validation {
    condition     = var.node_count >= 1 && var.node_count <= 9 && floor(var.node_count) == var.node_count
    error_message = "node_count must be a whole number from 1 to 9: MACs end :0N and IPs end .1N."
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
  default = 20
}

variable "base_image_url" {
  description = "URL or local path of the qcow2 base image. Swap for a custom build."
  type        = string
  default     = "https://dl.rockylinux.org/pub/rocky/10/images/x86_64/Rocky-10-GenericCloud-Base.latest.x86_64.qcow2"
}
