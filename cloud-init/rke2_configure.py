#!/usr/bin/python3
"""Write this node's RKE2 config for the role rke2-elect recorded in STATE, then start the role's units.

On first boot a node that does not bootstrap waits for the VIP to answer, so it joins through it, and
CONFIG is written last. On every boot the role's units are enabled and started, so a failed start or a
power loss after CONFIG is written is repaired on the next run.

EPOCH records the election epoch this node's config was written for. When STATE records another,
rke2-elect has replaced the bootstrap: the node resets the old epoch's RKE2 state and takes the first
boot path again. EPOCH is written just before CONFIG, so a crash during the reset repeats it.

The role's units are enabled, so after a reboot an old epoch's rke2-server and keepalived run from boot
until the reset, and can hold the VIP meanwhile. That is harmless because each epoch has its own join
token (config_yaml): a node of another epoch is refused.
"""

import contextlib
import glob
import hashlib
import hmac
import ipaddress
import json
import os
import shutil
import subprocess
import sys
import time

from rke2_elect import INTERVAL, STATE, vip_up, write

CONFIG = "/etc/rancher/rke2/config.yaml"
EPOCH = "/etc/rancher/rke2/epoch"
DATA = "/var/lib/rancher/rke2"
NODE_PASSWORD = "/etc/rancher/node/password"
KEEPALIVED = "/etc/keepalived/keepalived.conf"
CHECK = "/usr/libexec/keepalived/rke2-check.sh"


def keepalived_conf(vip, iface):
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


def config_yaml(env, role, bootstrap, epoch=0):
    # Contract: at epoch > 0 the join token is not elect.env's RKE2_TOKEN but derived from it and the
    # epoch, so a node cannot join another epoch's cluster, such as an old bootstrap that returned.
    token = env["RKE2_TOKEN"]
    if epoch:
        token = hmac.new(
            token.encode(), f"epoch {epoch}".encode(), hashlib.sha256
        ).hexdigest()
    lines = [f"token: {json.dumps(token)}"]
    if not bootstrap:
        lines.append(f"server: https://{env['VIP']}:9345")
    if role == "server":
        lines.append("tls-san:")
        lines += [f"  - {h}" for h in (env["NODE_IP"], env["VIP"])]
        # 5x etcd's defaults (100 ms, 1000 ms): a disk stall of a few seconds does not cost the leader.
        # ponytail: tuned on shared consumer SSDs; revisit on dedicated disks, where it slows failover.
        lines += [
            "etcd-arg:",
            "  - heartbeat-interval=500",
            "  - election-timeout=5000",
        ]
    return "\n".join(lines) + "\n"


def units(role):
    return ["rke2-server", "keepalived"] if role == "server" else ["rke2-agent"]


def reset():
    """Stop RKE2 and remove the cluster state of an earlier epoch. agent/containerd and data hold the
    preloaded airgap images and stay. Every step is idempotent."""
    # disable: a node that is now an agent must not start rke2-server or keepalived at its next boot.
    subprocess.run(
        ["systemctl", "disable", "--now", "keepalived", "rke2-server", "rke2-agent"],
        check=True,
    )
    # Kills the pods, which outlive rke2 (KillMode=process), and their mounts and interfaces. Best
    # effort: on a node that never ran RKE2 there is nothing to kill, and its exit status is ignored.
    subprocess.run(["/usr/bin/rke2-killall.sh"], check=False)
    agent = f"{DATA}/agent"
    # agent/etc holds the old epoch's server addresses for the load balancers. rke2 rewrites the rest.
    # No suppress here: it would also swallow an entry vanishing inside the tree and leave the rest.
    for d in (f"{DATA}/server", f"{agent}/pod-manifests", f"{agent}/etc"):
        if os.path.lexists(d):
            shutil.rmtree(d)
    for f in (
        *glob.glob(f"{agent}/*.crt"),
        *glob.glob(f"{agent}/*.key"),
        *glob.glob(f"{agent}/*.kubeconfig"),
        NODE_PASSWORD,
        KEEPALIVED,
        CONFIG,
    ):
        with contextlib.suppress(FileNotFoundError):
            os.remove(f)
    print("reset the old epoch's RKE2 state", flush=True)


def main():
    # VIP carries the site prefix (a.b.c.d/NN). Only the address is used here.
    env = {**os.environ, "VIP": str(ipaddress.ip_interface(os.environ["VIP"]).ip)}
    try:
        with open(STATE) as f:
            state = json.load(f)
    except FileNotFoundError:
        state = {}
    if "role" not in state:
        # rke2-elect failed before recording its decision. systemd restarts this unit.
        sys.exit("no decision recorded yet")
    role, bootstrap, epoch = state["role"], state["bootstrap"], state["epoch"]
    try:
        with open(EPOCH) as f:
            applied = f.read()
    except FileNotFoundError:
        applied = "0"
    if applied != str(epoch):
        reset()
    if not os.path.exists(CONFIG):
        while not bootstrap and not vip_up(env["VIP"]):
            time.sleep(INTERVAL)
        if role == "server":
            write(KEEPALIVED, keepalived_conf(env["VIP"], env["NODE_IFACE"]))
        write(EPOCH, str(epoch))
        # Written last: its presence means the config is complete.
        write(CONFIG, config_yaml(env, role, bootstrap, epoch), 0o600)
    # --no-block: rke2 blocks until it is ready.
    subprocess.run(
        ["systemctl", "enable", "--now", "--no-block", *units(role)], check=True
    )
    print(f"started {role}{' (bootstrap)' if bootstrap else ''}", flush=True)


if __name__ == "__main__":
    main()
