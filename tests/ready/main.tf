# Test helper: waits until the RKE2 node at var.ip is Ready and the cert-manager and Rancher HelmCharts are installed.
# A non-zero exit after 20 minutes fails the tofu test run.
variable "ip" {
  type = string
}

resource "terraform_data" "ready" {
  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      ssh_ok() {
        timeout 60 ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o LogLevel=ERROR "rocky@${var.ip}" \
          'k="sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml"
           $k wait --for=condition=Ready node --all --timeout=5s &&
           $k -n kube-system wait --for=condition=Complete job/helm-install-cert-manager job/helm-install-rancher --timeout=5s'
      }
      until ssh_ok; do
        [ "$SECONDS" -lt 1200 ] || { echo "cluster not ready after 20 min" >&2; exit 1; }
        sleep 15
      done
    EOT
  }
}
