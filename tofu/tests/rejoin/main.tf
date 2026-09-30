# Test helper: after tests/failover moved var.vip off a server that restarts, waits until that server is back and
# every node is Ready, and checks that var.vip stays on the server holding it now, at every poll and 30 s after the
# return (keepalived's nopreempt). The old holder is the node its kubelet names in a Rebooted event, which the kubelet
# records when it finds a new boot ID.
# A non-zero exit after 15 minutes fails the tofu test run.
variable "vip" {
  type = string
}

resource "terraform_data" "rejoin" {
  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      source ${path.module}/../lib.sh rejoin ${var.vip}
      log "waiting for the old VIP holder to return, via ${var.vip}"
      k="sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml"
      # Fails if var.vip answers from a server other than $holder. An empty answer is a failed read, not a move.
      stays() {
        local now
        now=$(vip_ssh hostname)
        [ -z "$now" ] || [ "$now" = "$holder" ] ||
          { echo "the VIP moved from $holder to $now when the old holder returned" >&2; exit 1; }
      }
      holder=$(vip_ssh hostname)
      [ -n "$holder" ] || { echo "no hostname from ${var.vip}" >&2; exit 1; }
      SECONDS=0
      while :; do
        stays
        returned=$(vip_ssh "$k get events -A --field-selector reason=Rebooted -o jsonpath='{.items[*].involvedObject.name}'")
        ready="not checked"
        if [ -n "$returned" ] && [ "$returned" != "$holder" ]; then
          vip_ssh "$k wait --for=condition=Ready node --all --timeout=5s" >/dev/null && ready=yes || ready=no
        fi
        log "$${SECONDS}s: VIP not moved off $holder, Rebooted event for $${returned:-no node}, every node Ready $ready"
        [ "$ready" = yes ] && break
        [ "$SECONDS" -lt 900 ] || { echo "the old holder is not back and Ready within 15 min" >&2; exit 1; }
        sleep 10
      done
      log "checking the VIP is still on $holder in 30 s"
      sleep 30
      stays
      # tofu test hides provisioner output on success, so CI also gets the result in the job summary.
      echo "old VIP holder $returned Ready again in $${SECONDS}s; the VIP stayed on $holder" |
        tee -a "$${GITHUB_STEP_SUMMARY:-/dev/null}"
      log passed
    EOT
  }
}
