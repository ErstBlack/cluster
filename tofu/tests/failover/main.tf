# Test helper: runs var.action on the server holding var.vip and waits until var.vip serves the RKE2 supervisor from
# a different server. The default forced poweroff skips keepalived's clean stop, so the backups take over on the VRRP
# master-down timer, as they would after a real crash.
# A non-zero exit after 120 seconds fails the tofu test run.
variable "vip" {
  type = string
}

# A command for the holder's shell, with no single quote.
variable "action" {
  type    = string
  default = "sudo systemctl poweroff --force --force"
}

resource "terraform_data" "failover" {
  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      [ -z "$${TEST_LOG:-}" ] || exec > >(tee -a "$TEST_LOG") 2>&1
      log() { printf '%(%H:%M:%S)T failover: %s\n' -1 "$*"; }
      log "finding the server holding ${var.vip}"
      vip_ssh() {
        timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o LogLevel=ERROR "rocky@${var.vip}" "$@"
      }
      old=$(vip_ssh hostname)
      [ -n "$old" ] || { echo "no server answers ssh on ${var.vip}" >&2; exit 1; }
      log "running '${var.action}' on $old"
      # A crashed peer never closes the connection, so this ssh hangs until its timeout. Background it so the clock
      # starts at the action.
      vip_ssh '${var.action}' >/dev/null 2>&1 &
      SECONDS=0
      until ping=no new=''; curl -sfk --max-time 5 -o /dev/null https://${var.vip}:9345/ping && ping=yes &&
        new=$(vip_ssh hostname) && [ -n "$new" ] && [ "$new" != "$old" ]; do
        log "$${SECONDS}s: VIP ping $ping, VIP held by $${new:-unknown}, waiting for a server other than $old"
        [ "$SECONDS" -lt 120 ] || { echo "VIP did not move off $old within 120 s" >&2; exit 1; }
        sleep 2
      done
      # tofu test hides provisioner output on success, so CI also gets the time in the job summary.
      echo "VIP moved from $old to $new in $${SECONDS}s" | tee -a "$${GITHUB_STEP_SUMMARY:-/dev/null}"
      log passed
    EOT
  }
}
