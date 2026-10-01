# Test helper for the storage spike (#91): runs spike/storage.sh, which writes its results to the job summary.
variable "vip" {
  type = string
}

variable "candidate" {
  type = string
}

variable "nodes" {
  type = number
}

resource "terraform_data" "storage" {
  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = "../spike/storage.sh ${var.vip} ${var.candidate} ${var.nodes}"
  }
}
