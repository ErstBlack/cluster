# Test helper: records `ip -o link show` from the server holding var.vip, then checks that its site NIC (the device
# holding var.vip) reports var.mtu and that it can send a var.mtu-byte don't-fragment ping to every other node (#66).
# Only reads and pings from the guest, so nothing overlay-related enters the VM.
# A non-zero exit fails the tofu test run.
variable "vip" {
  type = string
}

variable "mtu" {
  type = number
}

resource "terraform_data" "mtu" {
  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      source ${path.module}/../lib.sh mtu ${var.vip}
      log "checking the site NIC's MTU and a ${var.mtu}-byte ping to every peer, from ${var.vip}"
      links=$(vip_ssh ip -o link show) || { echo "ip -o link show over ssh to ${var.vip} failed" >&2; exit 1; }
      # tofu test hides provisioner output on success, so CI also gets the links in the job summary.
      printf '```\n%s\n```\n' "$links" | tee -a "$${GITHUB_STEP_SUMMARY:-/dev/null}"
      dev=$(vip_ssh ip -o -4 addr show to ${var.vip} | awk '{ print $2; exit }')
      [ -n "$dev" ] || { echo "no device on the VIP holder holds ${var.vip}" >&2; exit 1; }
      mtu=$(vip_ssh cat "/sys/class/net/$dev/mtu")
      rc=0
      [ "$mtu" = "${var.mtu}" ] || { echo "site NIC $dev has MTU $mtu, expected ${var.mtu}" >&2; rc=1; }
      ips=$(vip_ssh 'sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes \
        -o jsonpath="{.items[*].status.addresses[?(@.type==\"InternalIP\")].address}"')
      peers=0
      for ip in $ips; do
        # Skip the guest's own address.
        [ -z "$(vip_ssh ip -o addr show to "$ip")" ] || continue
        peers=$((peers + 1))
        vip_ssh ping -M "do" -s $((${var.mtu} - 28)) -c 3 -W 2 "$ip" >/dev/null ||
          { echo "${var.mtu}-byte don't-fragment ping from $dev to $ip failed" >&2; rc=1; }
      done
      [ "$peers" -gt 0 ] || { echo "no peer InternalIP to ping (got: $ips)" >&2; rc=1; }
      [ "$rc" -eq 0 ] || exit 1
      echo "site NIC $dev has MTU $mtu; ${var.mtu}-byte don't-fragment ping reached $peers peers" |
        tee -a "$${GITHUB_STEP_SUMMARY:-/dev/null}"
      log passed
    EOT
  }
}
