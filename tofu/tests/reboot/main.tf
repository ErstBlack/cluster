# Test helper: reboots one agent and one server that does not hold var.vip, then waits until each is back with a new
# boot ID, the same InternalIP, the same role (which of rke2-server and rke2-agent runs on it), and Ready.
# A non-zero exit after 15 minutes fails the tofu test run.
variable "vip" {
  type = string
}

resource "terraform_data" "reboot" {
  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      source ${path.module}/../lib.sh reboot ${var.vip}
      log "picking an agent and a server that does not hold ${var.vip}"
      k="sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml"
      # Prints "<kubelet boot ID> <Ready status> <InternalIP>" of node $1.
      info() {
        node_ssh ${var.vip} "$k get node $1 -o jsonpath=\"{.status.nodeInfo.bootID} {.status.conditions[?(@.type==\\\"Ready\\\")].status} {.status.addresses[?(@.type==\\\"InternalIP\\\")].address}\""
      }
      # Prints the state of rke2-server and rke2-agent on the node at $1, e.g. "active inactive" on a server. The node
      # label would survive a server that came back as an agent.
      units() {
        node_ssh "$1" systemctl is-active rke2-server rke2-agent | paste -sd ' '
      }
      # A node's name is its hostname.
      holder=$(node_ssh ${var.vip} hostname)
      agent=$(node_ssh ${var.vip} "$k get nodes -l node-role.kubernetes.io/control-plane!=true -o name" |
        sed 's|^node/||' | head -n 1)
      server=$(node_ssh ${var.vip} "$k get nodes -l node-role.kubernetes.io/control-plane=true -o name" |
        sed 's|^node/||' | grep -vx "$holder" | head -n 1)
      [ -n "$holder" ] && [ -n "$agent" ] && [ -n "$server" ] ||
        { echo "need a VIP holder, an agent and another server (got '$holder', '$agent', '$server')" >&2; exit 1; }
      declare -A ip role boot
      for node in "$agent" "$server"; do
        read -r _ _ "ip[$node]" <<<"$(info "$node")"
        boot[$node]=$(node_ssh "$${ip[$node]}" cat /proc/sys/kernel/random/boot_id)
        role[$node]=$(units "$${ip[$node]}")
        case $${role[$node]} in
          "active inactive" | "inactive active") ;;
          *) echo "$node at $${ip[$node]} runs neither rke2 unit alone: '$${role[$node]}'" >&2; exit 1 ;;
        esac
        [ -n "$${boot[$node]}" ] || { echo "no boot ID from $node at $${ip[$node]}" >&2; exit 1; }
        log "rebooting $node at $${ip[$node]}, running '$${role[$node]}' as rke2-server rke2-agent"
        node_ssh "$${ip[$node]}" 'sudo systemctl reboot' >/dev/null 2>&1 &
      done
      SECONDS=0
      for node in "$agent" "$server"; do
        # The kubelet reports the new boot ID once it is back, so a Ready from before the reboot never counts.
        until kube='' run=''; now=$(node_ssh "$${ip[$node]}" cat /proc/sys/kernel/random/boot_id) && [ -n "$now" ] &&
          [ "$now" != "$${boot[$node]}" ] && kube=$(info "$node") && [ "$kube" = "$now True $${ip[$node]}" ] &&
          run=$(units "$${ip[$node]}") && [ "$run" = "$${role[$node]}" ]; do
          if [ -z "$now" ] || [ "$now" = "$${boot[$node]}" ]; then
            log "$${SECONDS}s: $node not back at $${ip[$node]} with a new boot ID"
          else
            log "$${SECONDS}s: $node back with boot ID $now, kubelet reports '$kube', units '$run'"
          fi
          [ "$SECONDS" -lt 900 ] || {
            echo "$node not back at $${ip[$node]} as '$${role[$node]}' and Ready within 15 min: $(info "$node"), $(units "$${ip[$node]}")" >&2
            exit 1
          }
          sleep 10
        done
      done
      # tofu test hides provisioner output on success, so CI also gets the result in the job summary.
      echo "rebooted agent $agent and server $server, back with the same IP and role in $${SECONDS}s" |
        tee -a "$${GITHUB_STEP_SUMMARY:-/dev/null}"
      log passed
    EOT
  }
}
