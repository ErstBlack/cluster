#!/usr/bin/python3
"""Write this node's RKE2 config for the role rke2-elect recorded in STATE, then start the role's units.

On first boot a node that does not bootstrap waits for the VIP to answer, so it joins through it, and
CONFIG is written last. On every boot the role's units are enabled and started, so a failed start or a
power loss after CONFIG is written is repaired on the next run.
"""

import ipaddress
import json
import os
import subprocess
import sys
import time

from rke2_elect import INTERVAL, STATE, vip_up, write

CONFIG = "/etc/rancher/rke2/config.yaml"
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


def config_yaml(env, role, bootstrap):
    lines = [f"token: {json.dumps(env['RKE2_TOKEN'])}"]
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
    role, bootstrap = state["role"], state["bootstrap"]
    if not os.path.exists(CONFIG):
        while not bootstrap and not vip_up(env["VIP"]):
            time.sleep(INTERVAL)
        if role == "server":
            write(KEEPALIVED, keepalived_conf(env["VIP"], env["NODE_IFACE"]))
        # Written last: its presence means the config is complete.
        write(CONFIG, config_yaml(env, role, bootstrap), 0o600)
    # --no-block: rke2 blocks until it is ready.
    subprocess.run(
        ["systemctl", "enable", "--now", "--no-block", *units(role)], check=True
    )
    print(f"started {role}{' (bootstrap)' if bootstrap else ''}", flush=True)


if __name__ == "__main__":
    main()
