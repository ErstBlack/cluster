# Test helper: after ready, checks that some node's rke2-elect journal logs "dropped silent peer", so a node that died
# before the decision was heard and then dropped, not merely never heard. The runner running this test holds .1, so it
# reaches every node.
# A non-zero exit fails the tofu test run.
variable "vip" {
  type = string
}

resource "terraform_data" "dropped_peer" {
  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      [ -z "$${TEST_LOG:-}" ] || exec > >(tee -a "$TEST_LOG") 2>&1
      log() { printf '%(%H:%M:%S)T dropped_peer: %s\n' -1 "$*"; }
      log "searching every node's rke2-elect journal for a dropped silent peer, via ${var.vip}"
      node_ssh() {
        local host=$1
        shift
        timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o LogLevel=ERROR "rocky@$host" "$@"
      }
      ips=$(node_ssh ${var.vip} 'sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes \
        -o jsonpath="{.items[*].status.addresses[?(@.type==\"InternalIP\")].address}"')
      [ -n "$ips" ] || { echo "no InternalIP from kubectl on ${var.vip}" >&2; exit 1; }
      for ip in $ips; do
        line=$(node_ssh "$ip" sudo journalctl --unit rke2-elect --no-pager | grep --max-count 1 'dropped silent peer')
        if [ -n "$line" ]; then
          # tofu test hides provisioner output on success, so CI also gets the result in the job summary.
          echo "$ip: $line" | tee -a "$${GITHUB_STEP_SUMMARY:-/dev/null}"
          log passed
          exit 0
        fi
      done
      echo "no node's rke2-elect journal logs a dropped silent peer (nodes $ips)" >&2
      exit 1
    EOT
  }
}
