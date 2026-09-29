# Test helper: crashes the server holding var.vip and waits until var.vip serves the RKE2 supervisor from a
# different server. The forced poweroff skips keepalived's clean stop, so the backups take over on the VRRP
# master-down timer, as they would after a real crash.
# A non-zero exit after 120 seconds fails the tofu test run.
variable "vip" {
  type = string
}

resource "terraform_data" "failover" {
  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      vip_ssh() {
        timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o LogLevel=ERROR "rocky@${var.vip}" "$@"
      }
      old=$(vip_ssh hostname)
      [ -n "$old" ] || { echo "no server answers ssh on ${var.vip}" >&2; exit 1; }
      # A crashed peer never closes the connection, so this ssh hangs until its timeout. Background it so the clock
      # starts at the crash.
      vip_ssh 'sudo systemctl poweroff --force --force' >/dev/null 2>&1 &
      SECONDS=0
      until curl -sfk --max-time 5 -o /dev/null https://${var.vip}:9345/ping &&
        new=$(vip_ssh hostname) && [ -n "$new" ] && [ "$new" != "$old" ]; do
        [ "$SECONDS" -lt 120 ] || { echo "VIP did not move off $old within 120 s" >&2; exit 1; }
        sleep 2
      done
      # tofu test hides provisioner output on success, so CI also gets the time in the job summary.
      echo "VIP moved from $old to $new in $${SECONDS}s" | tee -a "$${GITHUB_STEP_SUMMARY:-/dev/null}"
    EOT
  }
}
