# shellcheck shell=bash
# Sourced by every helper under tests/ as `source ${path.module}/../lib.sh <helper> <vip>`. local-exec runs in tofu/,
# where path.module is tests/<helper>. Sets vip and k, the kubectl command on a server, and defines log, node_ssh,
# vip_ssh and node_ips.
# Every helper also writes its output, one progress line per poll included, to $TEST_LOG when it is set, because
# tofu test hides provisioner output. Locally, `TEST_LOG=/tmp/tofu-test.log just tofu test ...` with
# `tail -f /tmp/tofu-test.log` in another shell shows it live.
[ -z "${TEST_LOG:-}" ] || exec > >(tee -a "$TEST_LOG") 2>&1
helper=$1
vip=$2
log() { printf '%(%H:%M:%S)T %s: %s\n' -1 "$helper" "$*"; }
# node_ssh <host> <command>... runs the command as rocky on host. ssh_timeout overrides the 30 s limit.
node_ssh() {
  local host=$1
  shift
  timeout "${ssh_timeout:-30}" ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "rocky@$host" "$@"
}
vip_ssh() { node_ssh "$vip" "$@"; }
k="sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml"
# node_ips prints every node's InternalIP, as the server holding the VIP sees them.
node_ips() { vip_ssh "$k"' get nodes -o jsonpath="{.items[*].status.addresses[?(@.type==\"InternalIP\")].address}"'; }
