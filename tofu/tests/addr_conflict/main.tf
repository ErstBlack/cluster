# Test helper: after ready, checks that every node's InternalIP is in .2 to .20 of var.vip's /24 and that some node's
# node-addr journal logs a failed `nmcli up`, which is how an address conflict shows. CI holds .21 to .254 on every
# runner's bridge for this case (ci/case.sh), and the runner running this test holds .1, so it reaches every node.
# A non-zero exit fails the tofu test run.
variable "vip" {
  type = string
}

resource "terraform_data" "addr_conflict" {
  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      source ${path.module}/../lib.sh addr_conflict ${var.vip}
      log "checking every node's InternalIP and node-addr journal, via ${var.vip}"
      net=$${vip%.*}
      ips=$(node_ssh "$vip" 'sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes \
        -o jsonpath="{.items[*].status.addresses[?(@.type==\"InternalIP\")].address}"')
      [ -n "$ips" ] || { echo "no InternalIP from kubectl on $vip" >&2; exit 1; }
      rc=0
      logged=""
      for ip in $ips; do
        host=$${ip##*.}
        if [ "$${ip%.*}" != "$net" ] || [ "$host" -lt 2 ] || [ "$host" -gt 20 ]; then
          echo "$ip is outside $net.2 to $net.20" >&2
          rc=1
        fi
        journal=$(node_ssh "$ip" sudo journalctl --unit node-addr --no-pager) ||
          { echo "could not read node-addr's journal on $ip" >&2; rc=1; }
        case $journal in *"nmcli up "*) logged="$logged $ip" ;; esac
      done
      [ -n "$logged" ] || { echo "no node's node-addr journal logs a failed nmcli up" >&2; rc=1; }
      [ "$rc" -eq 0 ] || exit 1
      # tofu test hides provisioner output on success, so CI also gets the result in the job summary.
      echo "InternalIPs $ips all in $net.2 to $net.20; a failed nmcli up logged on$logged" |
        tee -a "$${GITHUB_STEP_SUMMARY:-/dev/null}"
      log passed
    EOT
  }
}
