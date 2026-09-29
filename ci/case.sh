#!/usr/bin/env bash
# Make a case's runner-side injection (ci/cases.json, #72) on this runner of a cluster.yml run. Runs as the runner
# user. Slot 1's tofu test makes the in-cluster ones.
#   pre <case> <slot> <n>     after ci/overlay.sh preflight and slot 1's .1, before this slot's apply or test
#   post <case> <slot> <n>    after this slot's apply, on slots other than 1
# A case with nothing to do at a point does nothing. Background work logs to RUNNER_TEMP/case.log, so it never holds
# the step open.
set -euo pipefail
shopt -s inherit_errexit

# Contracts with ci/overlay.sh (the bridge) and tofu/main.tf (network, VIP, domain names and MACs).
br="br-cluster"
net="192.168.150"
vip="$net.10"
virsh=(virsh --connect qemu:///system)

verb=${1:-}
name=${2:-}
slot=${3:-}
n=${4:-}

# Starts "$@" in the background, and fails if it exits within 2 s.
background() {
  "$@" </dev/null >"$RUNNER_TEMP/case.log" 2>&1 &
  sleep 2
  ps -p $! >/dev/null || { cat "$RUNNER_TEMP/case.log"; exit 1; }
}

# For 10 minutes, broadcasts an `electing` and a `decided` beacon a second, signed with a key other than the run's,
# that would win the election with token 2^64 if a node accepted them.
rogue_beacons() {
  python3 - "$PWD/cloud-init" "$br" <<'EOF'
import socket
import sys
import time

sys.path.insert(0, sys.argv[1])
from rke2_elect import PORT, sign

key, token, ip = b"not-the-token", 2**64, "192.168.150.250"
beacons = [
    sign(key, {"ip": ip, "token": token, "state": "electing"}),
    sign(key, {"ip": ip, "token": token, "state": "decided", "servers": [[token, ip]]}),
]
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    # Without it, 255.255.255.255 leaves through the default route, not the bridge.
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, sys.argv[2].encode())
    end = time.monotonic() + 600
    while time.monotonic() < end:
        for b in beacons:
            s.sendto(b, ("255.255.255.255", PORT))
        time.sleep(1)
print("sent rogue beacons for 10 minutes", flush=True)
EOF
}

# Powers off the VIP holder the moment the VIP first answers, so the bootstrap server dies as the others join it.
kill_bootstrap() {
  SECONDS=0
  until curl -sfk --max-time 1 -o /dev/null "https://$vip:9345/ping"; do
    ((SECONDS < 1800)) || { echo "the VIP never answered in 30 minutes"; return 1; }
    sleep 0.2
  done
  echo "$(date +%T) the VIP answered, powering off its holder"
  # A crashed peer never closes the connection, so this ssh hangs until its timeout.
  timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR "rocky@$vip" 'hostname; sudo systemctl poweroff --force --force' &
}

pre() {
  case $name in
    addr-conflict)
      # Every address above .20 answers duplicate address detection, so every node must land in .2 to .20.
      for ((i = 21; i <= 254; i++)); do
        echo "address add $net.$i/32 dev $br"
      done | sudo ip -batch -
      ;;
    staggered) sleep $(((slot - 1) * 50 / (n - 1))) ;;
    late-joiner) if ((slot == n)); then sleep 300; fi ;;
    rogue-beacons) if ((slot == 1)); then background rogue_beacons; fi ;;
    bootstrap-dies) if ((slot == 1)); then background kill_bootstrap; fi ;;
  esac
}

post() {
  local dom="Rocky-Cluster-$slot" mac addrs
  ((slot == n)) || return 0
  case $name in
    late-carrier)
      # The others decide about 150 s after apply: a 60 s first-boot network wait, DAD, then 60 s of election quiet.
      # Up at 300 s, the same margin late-joiner has, so this node finds the decision made.
      mac=$(printf '52:54:00:c1:00:%02x' "$slot")
      "${virsh[@]}" domif-setlink "$dom" "$mac" down
      sleep 300
      "${virsh[@]}" domif-setlink "$dom" "$mac" up
      ;;
    dies-before-decision)
      # Before the election's 60 s of quiet ends, so the others decide without this node.
      SECONDS=0
      until addrs=$("${virsh[@]}" domifaddr "$dom" --source agent 2>/dev/null) && [[ $addrs == *" $net."* ]]; do
        ((SECONDS < 600)) || { echo "$dom has no address in $net.0/24 after 10 minutes" >&2; exit 1; }
        sleep 1
      done
      # 30 s of beacons, so the others hear it even when their runners started late. Its arrival restarts their 60 s of
      # quiet, so they cannot decide before it dies.
      sleep 30
      "${virsh[@]}" destroy "$dom"
      ;;
  esac
}

case $verb in
  pre | post) ;;
  *) echo "usage: $0 pre|post <case> <slot> <n>" >&2; exit 2 ;;
esac
: "${slot:?}" "${n:?}"
# A misspelt case would otherwise run as happy.
case $name in
  happy | addr-conflict | late-carrier | reboot | staggered | late-joiner | dies-before-decision | rogue-beacons | \
    cp-1 | cp-5 | rke2-stop | holder-returns | agent-crash | bootstrap-dies) ;;
  *) echo "unknown case: $name" >&2; exit 2 ;;
esac
"$verb"
