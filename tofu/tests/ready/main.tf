# Test helper: waits until the server holding var.vip has its generated hostname, sees var.nodes nodes of which
# var.servers are control-plane nodes, all nodes are Ready with no InternalIP shared by two nodes, and keepalived
# serves the RKE2 supervisor on var.vip. The counts prove every node joined one cluster in the role it was elected to.
# A non-zero exit after 30 minutes fails the tofu test run.
variable "vip" {
  type = string
}

variable "servers" {
  type = number
}

variable "nodes" {
  type = number
}

resource "terraform_data" "ready" {
  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      source ${path.module}/../lib.sh ready ${var.vip}
      log "waiting for ${var.nodes} nodes, ${var.servers} of them control-plane, behind ${var.vip}"
      # Prints what the server holding var.vip sees, and succeeds once the cluster is ready. kubectl's errors are
      # dropped because the printed counts already say what is missing.
      ssh_ok() {
        ssh_timeout=60 vip_ssh \
          'k="sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml"
           hostname | grep -qx "node-[0-9a-f]\{10\}" && named=yes || named=no
           nodes=$($k get nodes -o name 2>/dev/null | wc -l)
           servers=$($k get nodes -l node-role.kubernetes.io/control-plane=true -o name 2>/dev/null | wc -l)
           $k wait --for=condition=Ready node --all --timeout=5s >/dev/null 2>&1 && ready=yes || ready=no
           ips=$($k get nodes -o jsonpath="{.items[*].status.addresses[?(@.type==\"InternalIP\")].address}" 2>/dev/null) &&
             [ -z "$(printf "%s\n" $ips | sort | uniq -d)" ] && unique=yes || unique=no
           curl -sfk --max-time 5 -o /dev/null https://${var.vip}:9345/ping && ping=yes || ping=no
           echo "$nodes/${var.nodes} nodes, $servers/${var.servers} control-plane, all Ready $ready, InternalIPs unique $unique, VIP ping $ping, hostname generated $named"
           [ "$named$ready$unique$ping" = yesyesyesyes ] && [ "$nodes" -eq ${var.nodes} ] && [ "$servers" -eq ${var.servers} ]'
      }
      until seen=$(ssh_ok); do
        log "$${seen:-no ssh answer from ${var.vip}}"
        [ "$SECONDS" -lt 1800 ] || { echo "cluster not ready after 30 min" >&2; exit 1; }
        sleep 15
      done
      log "passed after $${SECONDS}s: $seen"
    EOT
  }
}
