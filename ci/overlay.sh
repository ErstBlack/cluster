#!/usr/bin/env bash
# Join this runner's node to one L2 segment shared by every runner of the CI run: unicast VXLAN over the run's
# Headscale tailnet, plugged into a plain Linux bridge that the node's NIC attaches to (#53). Runs as root.
#   up <run-id> <attempt>    create the bridge and the VXLAN port, print the MTU the node must use
#   reconcile                every 5 s, point one all-zeros FDB entry at each online peer of this run, and drop the
#                            entries of peers that left. Exits on a peer from another run, or after 3 failed reads
#                            of the tailnet in a row.
#   preflight <slot> <n>     prove every peer answers a don't-fragment ping at the MTU, with broadcast ARP, and
#                            record each peer's Tailscale path. Needs reconcile running.
# Every failure is the overlay's, not the cluster's, and prints INFRASTRUCTURE:.
set -euo pipefail
shopt -s inherit_errexit

# The bridge name is the contract with tofu/main.tf's var.bridge.
br="br-cluster"
vx="vx-cluster"

verb=${1:-}
reported=0

# Shows where a frame stops: the VXLAN and tailnet counters, the FDB and neighbours, plain tailnet reachability of
# each peer, and the host's packet filters.
diagnose() {
  local ip
  set +e
  ip -s link show "$vx"
  ip -s link show tailscale0
  bridge fdb show dev "$vx"
  ip neigh show dev "$br"
  for ip in $(fdb_peers); do
    ping -c 2 -W 2 "$ip"
    tailscale ping -c 2 "$ip"
  done
  tailscale debug netmap 2>&1 | jq -c '.PacketFilterRules // .PacketFilter' | head -c 4000
  echo
  nft list ruleset | head -120
}

fail() {
  [[ $verb != preflight ]] || diagnose >&2
  echo "INFRASTRUCTURE: $*" >&2
  reported=1
  exit 1
}

# Sets peers to the IPv4 address of every online peer of this run, one per line. A peer counts as this run's by its
# Headscale user, which the server assigns, not by its self-chosen hostname. Exits on any other peer. Returns 1, and
# leaves peers alone, on a tailscale or jq error or when tailscale is not running, since an empty list would then
# read as every peer gone. Callers test it in a condition, where set -e does not apply, so each step checks itself.
run_peers() {
  local status foreign
  status=$(tailscale status --json) || return 1
  foreign=$(jq --exit-status 'if .BackendState != "Running" then error("tailscale is \(.BackendState)")
    elif .Self.UserID == null then error("no Self.UserID") else . end
    | .Self.UserID as $me | [.Peer // {} | .[] | select(.UserID != $me)] | length' <<<"$status") || return 1
  if ((foreign)); then
    tailscale status >&2
    fail "a peer from outside this run is visible"
  fi
  peers=$(jq --raw-output '.Self.UserID as $me | .Peer // {} | .[] | select(.UserID == $me and .Online)
    | .TailscaleIPs[] | select(test("^[0-9.]+$"))' <<<"$status" | sort -u) || return 1
}

# Prints the destination of every all-zeros FDB entry, which is where broadcast and unknown unicast go.
fdb_peers() {
  bridge fdb show dev "$vx" | awk '$1 == "00:00:00:00:00:00" { print $3 }'
}

up() {
  local vni ts_ip mtu mac a b c d
  # 24 bits: the run id's low 20 bits and the attempt's low 4. Only this run's peers are in the FDB, so the VNI only
  # keeps a stray packet from another run or attempt off this segment.
  vni=$(((${1:?} % 1048576) << 4 | ${2:?} % 16))
  ts_ip=$(tailscale ip -4)
  # VXLAN over IPv4 adds 50 bytes to each frame.
  mtu=$(($(cat /sys/class/net/tailscale0/mtu) - 50))
  # Docker on the runner may load br_netfilter, which would pass bridged frames through iptables' FORWARD policy.
  # A plain switch filters nothing. Not measured on the runner.
  if [[ -d /proc/sys/net/bridge ]]; then
    sysctl --quiet --write net.bridge.bridge-nf-call-iptables=0 net.bridge.bridge-nf-call-ip6tables=0 \
      net.bridge.bridge-nf-call-arptables=0
  fi
  # The VXLAN socket binds 0.0.0.0:4789 whatever local is (measured), so a frame could arrive from any interface. Only
  # the tailnet, where Headscale shows each runner only its own user's peers, may reach it.
  nft -f - <<<'table inet overlay { chain input { type filter hook input priority 0; policy accept;
    iifname != "tailscale0" udp dport 4789 drop; }; }'
  # Runners share one machine-id, from which udev derives a new link's MAC, so every runner's bridge had the same MAC
  # and frames for a peer's bridge stayed local (run 36508310749). An explicit, locally administered MAC built from the
  # Tailscale address is unique within the run, and udev leaves a MAC that was set explicitly alone.
  IFS=. read -r a b c d <<<"$ts_ip"
  mac=$(printf '02:%02x:%02x:%02x:%02x' "$a" "$b" "$c" "$d")
  # No learning, so the FDB holds only the entries the reconciler puts there. Unicast then floods to every peer.
  ip link add "$vx" address "$mac:02" type vxlan id "$vni" local "$ts_ip" dstport 4789 nolearning
  # No snooping, so multicast floods as on a plain switch. No IPv6 link-local addresses, so the host sends nothing
  # onto the segment by itself.
  ip link add "$br" address "$mac:01" type bridge stp_state 0 mcast_snooping 0
  ip link set "$vx" addrgenmode none
  ip link set "$br" addrgenmode none
  ip link set "$vx" master "$br" mtu "$mtu" up
  ip link set "$br" mtu "$mtu" up
  echo "$mtu"
}

# Adds an entry on the first pass that sees its peer online. Removes one only after two passes in a row without it,
# so one pass that catches a peer's control session reconnecting does not cut its broadcast and split the VIP.
reconcile() {
  local peers have ip errors=0
  local -A missed=()
  while :; do
    if ! run_peers; then
      echo "$(date +%T) could not read this run's peers" >&2
      ((++errors < 3)) || fail "could not read this run's peers 3 times in a row"
      sleep 5
      continue
    fi
    errors=0
    have=$(fdb_peers | sort -u)
    for ip in $(comm -23 <(echo "$peers") <(echo "$have")); do
      bridge fdb append 00:00:00:00:00:00 dev "$vx" dst "$ip" self permanent
      echo "$(date +%T) added $ip"
    done
    for ip in $(comm -12 <(echo "$peers") <(echo "$have")); do
      unset "missed[$ip]"
    done
    for ip in $(comm -13 <(echo "$peers") <(echo "$have")); do
      if ((++missed[$ip] < 2)); then
        continue
      fi
      bridge fdb del 00:00:00:00:00:00 dev "$vx" dst "$ip" self
      unset "missed[$ip]"
      echo "$(date +%T) removed $ip"
    done
    sleep 5
  done
}

# Prints how many echo replies this host has sent the slot's temporary address.
echo_replies() {
  nft list counter inet preflight "s$1" | awk '$1 == "packets" { print $2 }'
}

# Each host takes 198.18.0.<slot> on the bridge for the check, and gives it up before the node starts. It keeps the
# address until it has answered a ping from every peer, which nftables counters show, so a host that finishes first
# never fails a slower one. The wait allows for slots that queue behind the account's job limit.
preflight() {
  local slot=${1:?} n=${2:?} mtu s have paths peers counters="" rules="" others=()
  mtu=$(cat "/sys/class/net/$br/mtu")
  for ((s = 1; s <= n; s++)); do
    ((s == slot)) || others+=("$s")
  done
  for s in "${others[@]}"; do
    counters+="counter s$s {}; "
    rules+="oifname $br ip daddr 198.18.0.$s icmp type echo-reply counter name s$s; "
  done
  nft -f - <<<"table inet preflight { $counters chain output { type filter hook output priority 0; policy accept; $rules }; }"
  ip address add "198.18.0.$slot/24" dev "$br"
  SECONDS=0
  while :; do
    pgrep --full "overlay.sh reconcile" >/dev/null || fail "the reconciler is not running, see its log"
    # Only for its exit on a foreign peer. The reconciler owns the FDB and retries a failed read.
    run_peers || :
    have=$(fdb_peers | wc -l)
    ((have == n - 1)) && break
    ((SECONDS < 600)) || fail "$have FDB entries after 10 minutes, expected $((n - 1))"
    sleep 5
  done
  # An empty neighbour table makes the first ping to each peer resolve it by broadcast ARP. The first packets over a
  # new Tailscale path can take seconds, hence the long reply timeout. A peer in the FDB has already joined and takes
  # its address seconds later, so 2 minutes is plenty.
  ip neigh flush dev "$br"
  SECONDS=0
  for s in "${others[@]}"; do
    until ping -q -M "do" -s $((mtu - 28)) -c 1 -W 5 "198.18.0.$s" >/dev/null; do
      ((SECONDS < 120)) || fail "slot $s does not answer a ${mtu}-byte don't-fragment ping"
      sleep 1
    done
    echo "slot $s answers at MTU $mtu"
  done
  paths=$(tailscale status --json | jq --raw-output '.Self.UserID as $me | .Peer // {} | .[] | select(.UserID == $me)
    | if (.CurAddr // "") != "" then "\(.HostName): direct \(.CurAddr)"
      else "::warning::\(.HostName): relayed via DERP \(.Relay)" end')
  echo "$paths"
  for s in "${others[@]}"; do
    while :; do
      have=$(echo_replies "$s")
      ((have > 0)) && break
      ((SECONDS < 600)) || fail "slot $s never pinged this host"
      sleep 1
    done
  done
  sleep 1
  ip address del "198.18.0.$slot/24" dev "$br"
  nft delete table inet preflight
  ip neigh flush dev "$br"
}

case $verb in
  up | reconcile | preflight) ;;
  *) echo "usage: $0 up <run-id> <attempt> | reconcile | preflight <slot> <n>" >&2; exit 2 ;;
esac
# Reports any failure that fail did not already explain, such as a failed ip command or a missing bridge.
on_exit() {
  local rc=$?
  ((rc == 0 || reported)) || echo "INFRASTRUCTURE: overlay.sh $verb failed with exit $rc" >&2
}
trap on_exit EXIT
"$verb" "${@:2}"
