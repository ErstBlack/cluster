# Test helper: waits until the server holding var.vip has its generated hostname, sees var.servers control-plane
# nodes, all nodes are Ready with no InternalIP shared by two nodes, and keepalived serves the RKE2 supervisor on
# var.vip. The control-plane count proves all nodes became servers in one cluster.
# A non-zero exit after 30 minutes fails the tofu test run.
variable "vip" {
  type = string
}

variable "servers" {
  type = number
}

resource "terraform_data" "ready" {
  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      ssh_ok() {
        timeout 60 ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o LogLevel=ERROR "rocky@${var.vip}" \
          'k="sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml"
           hostname | grep -qx "node-[0-9a-f]\{10\}" &&
           [ "$($k get nodes -l node-role.kubernetes.io/control-plane=true -o name | wc -l)" -eq ${var.servers} ] &&
           $k wait --for=condition=Ready node --all --timeout=5s &&
           ips=$($k get nodes -o jsonpath="{.items[*].status.addresses[?(@.type==\"InternalIP\")].address}") &&
           [ -z "$(printf "%s\n" $ips | sort | uniq -d)" ] &&
           curl -sfk --max-time 5 -o /dev/null https://${var.vip}:9345/ping'
      }
      until ssh_ok; do
        [ "$SECONDS" -lt 1800 ] || { echo "cluster not ready after 30 min" >&2; exit 1; }
        sleep 15
      done
    EOT
  }
}
