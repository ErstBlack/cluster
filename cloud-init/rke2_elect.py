#!/usr/bin/python3
"""Elect this node's RKE2 role at first boot, then bootstrap or join the cluster through the VIP.

Every node broadcasts a signed beacon {ip, token, state} to UDP 9346 every 2s. Once 60s pass with
no change in the set of live peers, the top N tokens become servers and the largest bootstraps. A
node that sees a `decided` beacon adopts that decision instead of making its own, and one that finds
the VIP answering joins as an agent. A node is identified by (token, ip). The token is drawn once and
kept in STATE, so a restarted unit or a reboot keeps its role, while a rebuilt disk draws a new token,
is named in no decision, and joins as an agent.

ponytail: a dead server is not replaced by promoting an agent; the control plane stays below N
until the cluster is rebuilt.
ponytail: an elected bootstrap that dies for good before its apply, including one that goes silent
within about EXPIRE before the decision, leaves the others waiting on the VIP forever. Recovery is
`tofu destroy` then `tofu apply`. Upgrade path: a VIP-wait timeout that re-elects.
ponytail: no cluster merging. Two clusters formed apart stay apart.
ponytail: broadcast and VRRP are L2 only. Routed subnets need BGP (MetalLB) and a discovery seed.
ponytail: virtual_router_id is fixed at 51, so one cluster per L2 segment until merging lands.
"""
import hashlib
import hmac
import json
import os
import secrets
import socket
import ssl
import subprocess
import time
import urllib.request

PORT = 9346
INTERVAL = 2
SETTLE = 60
# Long enough for two nodes that decided in the same beacon interval to hear each other.
GRACE = 3 * INTERVAL
# A peer silent this long is dropped. That covers a node that died more than EXPIRE before the
# decision. One that died later is still elected (see the ponytail above). SETTLE > EXPIRE + INTERVAL
# makes sure a peer that dies right after its first beacon is dropped before anyone decides.
EXPIRE = 5 * INTERVAL
CONFIG = "/etc/rancher/rke2/config.yaml"
STATE = "/etc/rancher/rke2/elect.json"
KEEPALIVED = "/etc/keepalived/keepalived.conf"
CHECK = "/usr/libexec/keepalived/rke2-check.sh"


def top(members, n):
    """The n highest (token, ip) pairs, highest first. ip breaks token ties."""
    return sorted(members, reverse=True)[:n]


def role_of(me, servers):
    """(role, is_bootstrap) of me, a (token, ip), in a decision."""
    if me not in servers:
        return "agent", False
    return "server", servers[0] == me


def decide(me, peers, n):
    """me and peers are (token, ip). Same peer set on every node gives the same answer."""
    return role_of(me, top({me, *peers}, n))


def sign(key, body):
    msg = json.dumps(body, sort_keys=True, separators=(",", ":")).encode()
    return json.dumps({**body, "mac": hmac.new(key, msg, hashlib.sha256).hexdigest()}).encode()


def verify(key, data):
    """The beacon as a dict, or None if it is malformed or not signed with key."""
    try:
        body = json.loads(data)
        mac = body.pop("mac")
        msg = json.dumps(body, sort_keys=True, separators=(",", ":")).encode()
        if not hmac.compare_digest(mac, hmac.new(key, msg, hashlib.sha256).hexdigest()):
            return None
        if body["state"] not in ("electing", "decided"):
            return None
        body["token"] = int(body["token"])
        body["servers"] = [(int(t), str(i)) for t, i in body.get("servers", [])]
        return body
    except Exception:
        return None


def exchange(sock, key, ip, beacon):
    """Broadcast beacon() every INTERVAL and yield None after each send. In between, yield every
    valid beacon from another node. Bad beacons are dropped silently."""
    next_send = 0.0
    while True:
        if time.monotonic() >= next_send:
            sock.sendto(sign(key, beacon()), ("255.255.255.255", PORT))
            next_send = time.monotonic() + INTERVAL
            yield None
        sock.settimeout(max(0.01, next_send - time.monotonic()))
        try:
            data, _ = sock.recvfrom(65535)
        except socket.timeout:
            continue
        b = verify(key, data)
        if b and b["ip"] != ip:
            yield b


def vip_up(vip):
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        with urllib.request.urlopen(f"https://{vip}:9345/ping", timeout=1, context=ctx) as r:
            return r.status == 200
    except Exception:
        return False


def elect(me, n, exchange, vip_up, clock=time.monotonic):
    """The decision as servers [(token, ip)], highest first. [] means join as an agent.
    exchange(beacon) and vip_up() are the network, injected so tests run without sockets."""
    peers = {}  # ip -> (token, last heard)
    last_new = clock()
    decision = None
    for b in exchange(lambda: {"ip": me[1], "token": me[0], "state": "electing"}):
        if b is None:
            if vip_up():
                print("VIP answers: a cluster exists", flush=True)
                return []
            now = clock()
            gone = [i for i, (_, seen) in peers.items() if now - seen > EXPIRE]
            for i in gone:
                del peers[i]
                print(f"dropped silent peer {i}", flush=True)
            if gone:
                last_new = now
            if now - last_new >= SETTLE:
                decision = top({me, *((t, i) for i, (t, _) in peers.items())}, n)
                print(f"decided with {len(peers) + 1} nodes", flush=True)
                break
        elif b["state"] == "decided":
            decision = b["servers"]
            print(f"adopted the decision of {b['ip']}", flush=True)
            break
        else:
            if peers.get(b["ip"], (None,))[0] != b["token"]:
                last_new = clock()
            peers[b["ip"]] = (b["token"], clock())

    # Nodes that decided apart converge on the decision with the highest bootstrap.
    end = clock() + GRACE
    beacon = lambda: {"ip": me[1], "token": me[0], "state": "decided", "servers": decision}
    for b in exchange(beacon):
        if b is None:
            if clock() >= end:
                return decision
        elif b["state"] == "decided" and b["servers"] > decision:
            print(f"switched to the decision of {b['ip']}", flush=True)
            decision = b["servers"]


def write(path, text, mode=0o644):
    """Atomic: a crash leaves the old file or the new one, never a partial one."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode), "w") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def keepalived_conf(vip):
    iface = json.loads(subprocess.check_output(["ip", "-j", "route", "show", "default"]))[0]["dev"]
    return f"""global_defs {{
  enable_script_security
  script_user root
}}
# The node holds the VIP only while its RKE2 supervisor answers.
vrrp_script chk_rke2 {{
  script "{CHECK}"
  interval 2
  fall 2
  rise 2
}}
vrrp_instance rke2 {{
  state BACKUP
  nopreempt
  interface {iface}
  virtual_router_id 51
  priority 100
  advert_int 1
  virtual_ipaddress {{
    {vip}/32
  }}
  track_script {{
    chk_rke2
  }}
}}
"""


def units(role):
    return ["rke2-server", "keepalived"] if role == "server" else ["rke2-agent"]


def load_state(path):
    """STATE, created with a fresh token on first use. The token outlives restarts, not the disk."""
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        state = {"token": secrets.randbits(64)}
        write(path, json.dumps(state), 0o600)
        return state


def settled(path, ip, elect, vip_up):
    """STATE with role, bootstrap and servers recorded. elect(me) runs only if no decision is recorded,
    so a restart while waiting on the VIP keeps the role."""
    state = load_state(path)
    if "servers" not in state:
        me = (state["token"], ip)
        servers = elect(me)
        role, bootstrap = role_of(me, servers)
        # A cluster already answering on the VIP means this node must not start a second one.
        if bootstrap and vip_up():
            print("VIP answers: joining as an agent instead of bootstrapping", flush=True)
            role, bootstrap = "agent", False
        state.update(role=role, bootstrap=bootstrap, servers=servers)
        write(path, json.dumps(state), 0o600)
    return state


def apply(env, role, bootstrap):
    lines = [f"token: {json.dumps(env['RKE2_TOKEN'])}"]
    if not bootstrap:
        lines.append(f"server: https://{env['VIP']}:9345")
    if role == "server":
        lines.append("tls-san:")
        lines += [f"  - {h}" for h in (env["NODE_IP"], env["VIP"], env["RANCHER_HOSTNAME"])]
        write(KEEPALIVED, keepalived_conf(env["VIP"]))
    # Written last: its presence means apply already ran.
    write(CONFIG, "\n".join(lines) + "\n", 0o600)
    # --no-block: rke2 blocks until ready, and beacons must keep going.
    subprocess.run(["systemctl", "enable", "--now", "--no-block", *units(role)], check=True)
    print(f"started {role}{' (bootstrap)' if bootstrap else ''}", flush=True)


def main():
    env = os.environ
    key, ip, vip = env["RKE2_TOKEN"].encode(), env["NODE_IP"], env["VIP"]
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.bind(("", PORT))

    n = int(env["CONTROL_PLANE_COUNT"])
    state = settled(STATE, ip, lambda me: elect(me, n, lambda beacon: exchange(sock, key, ip, beacon),
                                                lambda: vip_up(vip)), lambda: vip_up(vip))
    token, servers = state["token"], [tuple(s) for s in state["servers"]]
    applied = os.path.exists(CONFIG)
    if applied:
        subprocess.run(["systemctl", "enable", "--now", "--no-block", *units(state["role"])], check=True)

    # Keep beaconing `decided` so late nodes join rather than elect. Joiners wait for the VIP.
    beacon = lambda: {"ip": ip, "token": token, "state": "decided", "servers": servers}
    for b in exchange(sock, key, ip, beacon):
        if b is None and not applied and (state["bootstrap"] or vip_up(vip)):
            apply(env, state["role"], state["bootstrap"])
            applied = True


if __name__ == "__main__":
    main()
