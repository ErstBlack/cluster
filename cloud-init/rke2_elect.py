#!/usr/bin/python3
"""Elect this node's RKE2 role at first boot and record it in STATE for rke2-configure.

Every node broadcasts a signed beacon {ip, token, state, epoch, joined} to UDP 9346 every 2s. Once
60s pass with no change in the set of live peers, the top N tokens become servers and the largest
bootstraps. A node that sees a `decided` beacon adopts that decision instead of making its own, and
one that finds the VIP answering joins as an agent. A node is identified by (token, ip). The token
is drawn once and kept in STATE, so a restarted unit or a reboot keeps its role, while a rebuilt
disk draws a new token, is named in no decision, and joins as an agent. Once the role is recorded,
the unit reports ready to systemd, which then runs rke2-configure, and keeps beaconing `decided` so
late nodes join rather than elect.

A decision belongs to an epoch, 0 at first boot, and (epoch, servers) orders decisions. `joined`
says whether the node's role unit is active, which a server reaches only once it has joined the
cluster. It counts only at the beacon's own epoch. A node elects again at the next epoch, without
the bootstrap, when the bootstrap has been silent for DEADLINE, a majority of the decision's servers
is live, and no server of the decision reports `joined`. The majority keeps a node or group cut off
from the rest from electing apart. A node adopts a `decided` beacon from a later epoch unless a
majority of its own decision's servers is live and `joined` at its epoch, so an old bootstrap that
returns joins as an agent, the minority side of a healed partition joins the majority's epoch, and a
working cluster ignores nodes that elected apart. After a new decision, rke2-configure is restarted
to apply it, and each epoch's cluster has its own join token (see rke2_configure.config_yaml), so no
node joins another epoch's cluster.

ponytail: a dead server is not replaced by promoting an agent; the control plane stays below N
until the cluster is rebuilt.
ponytail: a bootstrap that dies after another server has joined is not replaced. That server reports
`joined`, which blocks re-election, and a two-member etcd without the bootstrap has no quorum.
Recovery is `tofu destroy` then `tofu apply`.
ponytail: no cluster merging. Two clusters formed apart stay apart.
ponytail: broadcast and VRRP are L2 only. Routed subnets need BGP (MetalLB) and a discovery seed.
ponytail: virtual_router_id is fixed at 51, so one cluster per L2 segment until merging lands.
"""

import hashlib
import hmac
import ipaddress
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
# decision. One that died later is still elected, and if it bootstraps, the others replace it after
# DEADLINE. SETTLE > EXPIRE + INTERVAL makes sure a peer that dies right after its first beacon is
# dropped before anyone decides.
EXPIRE = 5 * INTERVAL
# A bootstrap silent this long is replaced. It outlasts a bootstrap reboot (the first-boot network
# wait, then beacons), so a reboot does not cost a re-election.
DEADLINE = 300
STATE = "/etc/rancher/rke2/elect.json"


def top(members, n):
    """The n highest (token, ip) pairs, highest first. ip breaks token ties."""
    return sorted(members, reverse=True)[:n]


def role_of(me, servers):
    """(role, is_bootstrap) of me, a (token, ip), in a decision."""
    if me not in servers:
        return "agent", False
    return "server", servers[0] == me


def digest(key, body):
    """HMAC-SHA256 of body's canonical JSON."""
    return hmac.new(
        key,
        json.dumps(body, sort_keys=True, separators=(",", ":")).encode(),
        hashlib.sha256,
    ).hexdigest()


def sign(key, body):
    return json.dumps({**body, "mac": digest(key, body)}).encode()


def verify(key, data):
    """The beacon as a dict, or None if it is malformed or not signed with key."""
    try:
        body = json.loads(data)
        mac = body.pop("mac")
        if not hmac.compare_digest(mac, digest(key, body)):
            return None
        if body["state"] not in ("electing", "decided"):
            return None
        body["token"] = int(body["token"])
        body["epoch"] = int(body["epoch"])
        body["joined"] = bool(body["joined"])
        body["servers"] = [(int(t), str(i)) for t, i in body.get("servers", [])]
        return body
    except Exception:  # noqa: BLE001 - beacons are untrusted network input, and any malformed one is dropped
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
        except TimeoutError:
            continue
        b = verify(key, data)
        if b and b["ip"] != ip:
            yield b


def vip_up(vip):
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        with urllib.request.urlopen(
            f"https://{vip}:9345/ping", timeout=1, context=ctx
        ) as r:
            return r.status == 200
    except Exception:  # noqa: BLE001 - any failure to reach the VIP means it is not up yet
        return False


def elect(me, n, exchange, vip_up, clock=time.monotonic, epoch=0):
    """The decision as (epoch, servers), servers [(token, ip)] highest first. [] means join as an
    agent. It is made at epoch unless a later epoch's decision is heard. exchange(beacon) and vip_up()
    are the network, injected so tests run without sockets. Nobody electing has joined this epoch's
    cluster, so its beacons say joined false."""
    peers = {}  # ip -> (token, last heard)
    start = last_new = clock()
    decision = None
    beacon = lambda: {
        "ip": me[1],
        "token": me[0],
        "state": "electing",
        "epoch": epoch,
        "joined": False,
    }
    for b in exchange(beacon):
        if b is None:
            # Listen first, so a decision heard is adopted with its epoch instead of the VIP's answer.
            if clock() - start >= GRACE and vip_up():
                print("VIP answers: a cluster exists", flush=True)
                return epoch, []
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
            # A decision from an earlier epoch is one the site has moved past.
            if b["epoch"] >= epoch:
                decision, epoch = b["servers"], b["epoch"]
                print(f"adopted the epoch {epoch} decision of {b['ip']}", flush=True)
                break
        else:
            if peers.get(b["ip"], (None,))[0] != b["token"]:
                last_new = clock()
            peers[b["ip"]] = (b["token"], clock())

    # Nodes that decided apart converge on the latest epoch, then on the highest bootstrap.
    end = clock() + GRACE
    beacon = lambda: {
        "ip": me[1],
        "token": me[0],
        "state": "decided",
        "epoch": epoch,
        "servers": decision,
        "joined": False,
    }
    for b in exchange(beacon):
        if b is None:
            if clock() >= end:
                return epoch, decision
        elif b["state"] == "decided" and (b["epoch"], b["servers"]) > (
            epoch,
            decision,
        ):
            print(f"switched to the decision of {b['ip']}", flush=True)
            decision, epoch = b["servers"], b["epoch"]


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
    """STATE with epoch, role, bootstrap and servers recorded. elect(me) runs only if no decision is
    recorded, so a restart while waiting on the VIP keeps the role."""
    state = load_state(path)
    if "servers" not in state:
        me = (state["token"], ip)
        epoch, servers = elect(me)
        role, bootstrap = role_of(me, servers)
        # A cluster already answering on the VIP means this node must not start a second one. Only at
        # epoch 0: while a bootstrap is being replaced, a server left from the old epoch can answer.
        if bootstrap and epoch == 0 and vip_up():
            print(
                "VIP answers: joining as an agent instead of bootstrapping", flush=True
            )
            role, bootstrap = "agent", False
        state.update(epoch=epoch, role=role, bootstrap=bootstrap, servers=servers)
        write(path, json.dumps(state), 0o600)
    return state


def watch(me, epoch, servers, n, exchange, joined, clock=time.monotonic):
    """Beacon the decision (epoch, servers) until the site needs a new one, then return the new one
    as elect does. joined() says whether this node's role unit is active. A server is live when heard
    within EXPIRE, and joined when its beacon says so at this epoch. A `decided` beacon from a later
    epoch is adopted once this has listened for EXPIRE, unless a majority of the decision's servers
    is live and joined (this one counts). A node other than the bootstrap elects at the next epoch
    once the bootstrap has been silent for DEADLINE, a majority of the decision's servers is live
    (this one counts), and none is joined. The VIP is never asked: a server left from the old epoch
    can answer on it."""
    heard = {}  # (token, ip) -> (epoch, joined, last heard)
    start = clock()
    said = set()

    def say(msg):
        """Print msg once, not on every beacon interval."""
        if msg not in said:
            said.add(msg)
            print(msg, flush=True)

    def joined_servers(live):
        """How many servers of the decision are joined at this epoch, this one included."""
        return sum(live.get(s) == (epoch, True) for s in servers if s != me) + (
            me in servers and joined()
        )

    beacon = lambda: {
        "ip": me[1],
        "token": me[0],
        "state": "decided",
        "epoch": epoch,
        "servers": servers,
        "joined": joined(),
    }
    for b in exchange(beacon):
        now = clock()
        if b is not None:
            heard[(b["token"], b["ip"])] = (b["epoch"], b["joined"], now)
        live = {s: (e, j) for s, (e, j, seen) in heard.items() if now - seen <= EXPIRE}
        if b is not None:
            if b["state"] == "decided" and b["epoch"] > epoch:
                # Listen first: just after a restart nothing is heard yet, so nothing would block.
                if now - start < EXPIRE:
                    continue
                # A majority, so an old bootstrap running its own lone cluster still adopts.
                if 2 * joined_servers(live) > len(servers):
                    say(
                        f"ignoring epoch {b['epoch']} of {b['ip']}: this cluster has joined"
                    )
                    continue
                print(f"{b['ip']} is at epoch {b['epoch']}: adopting it", flush=True)
                return elect(me, n, exchange, lambda: False, clock, b["epoch"])
        elif (
            servers
            and servers[0] != me
            and now - heard.get(servers[0], (0, False, start))[2] >= DEADLINE
        ):
            # A majority of the decision's servers, this one included, must be live, so two groups
            # cut off from each other cannot both elect. A server electing at the next epoch is live.
            heard_servers = sum(
                s == me or live.get(s, (-1,))[0] >= epoch for s in servers[1:]
            )
            if 2 * heard_servers <= len(servers):
                say(
                    f"bootstrap {servers[0][1]} is silent, and too few servers are heard"
                )
                continue
            if joined_servers(live):
                say(f"bootstrap {servers[0][1]} is silent, but a server has joined")
                continue
            print(
                f"bootstrap {servers[0][1]} silent for {DEADLINE}s and no server joined:"
                f" electing epoch {epoch + 1}",
                flush=True,
            )
            return elect(me, n, exchange, lambda: False, clock, epoch + 1)


def notify(msg):
    """sd_notify(3) without libsystemd. A leading @ in NOTIFY_SOCKET names an abstract socket."""
    addr = os.environ.get("NOTIFY_SOCKET")
    if addr:
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as s:
            s.sendto(msg, "\0" + addr[1:] if addr.startswith("@") else addr)


def main():
    env = os.environ
    # VIP carries the site prefix (a.b.c.d/NN). Only the address is used here.
    key, ip, vip = (
        env["RKE2_TOKEN"].encode(),
        env["NODE_IP"],
        str(ipaddress.ip_interface(env["VIP"]).ip),
    )
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.bind(("", PORT))

    n = int(env["CONTROL_PLANE_COUNT"])
    state = settled(
        STATE,
        ip,
        lambda me: elect(
            me, n, lambda beacon: exchange(sock, key, ip, beacon), lambda: vip_up(vip)
        ),
        lambda: vip_up(vip),
    )
    # Starts rke2-configure, which is ordered after this unit.
    notify(b"READY=1")
    print(f"{state['role']}{' (bootstrap)' if state['bootstrap'] else ''}", flush=True)

    me = (state["token"], ip)
    unit = lambda: "rke2-server" if state["role"] == "server" else "rke2-agent"
    joined = lambda: (
        subprocess.run(
            ["systemctl", "is-active", "--quiet", unit()], check=False
        ).returncode
        == 0
    )
    # --no-block: rke2-configure can wait on the VIP for as long as it takes, and beacons must go on.
    reconfigure = lambda: subprocess.run(
        ["systemctl", "restart", "--no-block", "rke2-configure"], check=True
    )
    # A crash between recording a new epoch and restarting rke2-configure must not leave the old
    # epoch applied. rke2-configure does nothing new when it already applied this epoch.
    if state["epoch"]:
        reconfigure()
    # Keep beaconing `decided` so late nodes join rather than elect, and watch the bootstrap.
    while True:
        epoch, servers = watch(
            me,
            state["epoch"],
            # JSON keeps each (token, ip) as a list.
            [tuple(s) for s in state["servers"]],
            n,
            lambda beacon: exchange(sock, key, ip, beacon),
            joined,
        )
        role, bootstrap = role_of(me, servers)
        state.update(epoch=epoch, role=role, bootstrap=bootstrap, servers=servers)
        write(STATE, json.dumps(state), 0o600)
        print(f"epoch {epoch}: {role}{' (bootstrap)' if bootstrap else ''}", flush=True)
        reconfigure()


if __name__ == "__main__":
    main()
