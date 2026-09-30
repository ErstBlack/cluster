# Test helper: forces a poweroff of one agent, then waits until that agent is NotReady while every other node stays
# Ready. var.vip must serve the RKE2 supervisor at every poll.
# A non-zero exit after 3 minutes, or a poll var.vip does not answer, fails the tofu test run.
variable "vip" {
  type = string
}

resource "terraform_data" "agent_crash" {
  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      source ${path.module}/../lib.sh agent_crash ${var.vip}
      log "picking an agent to crash, via ${var.vip}"
      k="sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml"
      read -r agent ip <<<"$(node_ssh "$vip" "$k get nodes -l node-role.kubernetes.io/control-plane!=true -o jsonpath=\"{.items[0].metadata.name} {.items[0].status.addresses[?(@.type==\\\"InternalIP\\\")].address}\"")"
      [ -n "$ip" ] || { echo "no agent from kubectl on $vip" >&2; exit 1; }
      log "forcing a poweroff of agent $agent at $ip"
      # A crashed peer never closes the connection, so this ssh hangs until its timeout.
      node_ssh "$ip" 'sudo systemctl poweroff --force --force' >/dev/null 2>&1 &
      SECONDS=0
      while :; do
        curl -sfk --max-time 5 -o /dev/null "https://$vip:9345/ping" ||
          { echo "the VIP did not answer $${SECONDS}s after $agent crashed" >&2; exit 1; }
        # "<name>=<Ready status>" of every node.
        status=$(node_ssh "$vip" "$k get nodes -o jsonpath=\"{range .items[*]}{.metadata.name}={.status.conditions[?(@.type==\\\"Ready\\\")].status} {end}\"")
        down=no
        others=yes
        for node in $status; do
          if [ "$${node%%=*}" = "$agent" ]; then
            [ "$${node#*=}" = True ] || down=yes
          else
            [ "$${node#*=}" = True ] || others=no
          fi
        done
        log "$${SECONDS}s: VIP ping yes, $agent NotReady $down, every other node Ready $others"
        [ "$down" = yes ] && [ "$others" = yes ] && break
        [ "$SECONDS" -lt 180 ] || { echo "not only $agent NotReady within 3 min: $status" >&2; exit 1; }
        sleep 2
      done
      # tofu test hides provisioner output on success, so CI also gets the result in the job summary.
      echo "agent $agent NotReady $${SECONDS}s after its crash, every other node Ready, the VIP answered throughout" |
        tee -a "$${GITHUB_STEP_SUMMARY:-/dev/null}"
      log passed
    EOT
  }
}
