#!/usr/bin/python3
"""Give this node an address on the site network and write it to NODE_ENV for rke2-elect and rke2-configure.

VIP carries the site prefix, /30 or shorter (VIP=192.168.150.10/24). An address already inside that
network wins: DHCP, static config, or the profile a previous boot saved, which NetworkManager brings up
ahead of cloud-init's DHCP profile. If that profile exists but is not up, this brings it up. Otherwise
it derives a candidate from the machine-id and assigns it through NetworkManager, whose duplicate
address detection fails the activation when another host holds it, and then tries the next candidate. GATEWAY and DNS are optional.
With no GATEWAY the profile routes everything on-link. This waits until an interface has a carrier, so
the unit's start job only ever succeeds and the units that require it stay queued.

ponytail: a node with two NICs on the site network, or two cabled NICs, takes the first by name.
"""

import fcntl
import hashlib
import ipaddress
import os
import socket
import struct
import subprocess
import sys
import time

from rke2_elect import INTERVAL, write

NODE_ENV = "/run/rke2/node.env"
MACHINE_ID = "/etc/machine-id"
PROFILE = "cluster"
SIOCGIFADDR = 0x8915


def addrs():
    """(ifname, ip) for every interface with an IPv4 address."""
    found = []
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        for _, name in socket.if_nameindex():
            req = struct.pack("256s", name.encode())
            try:
                ip = fcntl.ioctl(s.fileno(), SIOCGIFADDR, req)[20:24]
            except OSError:  # no IPv4 address
                continue
            found.append((name, socket.inet_ntoa(ip)))
    return found


def pick(vip, addrs):
    """(ifname, ip) of the first address inside the network of vip (a.b.c.d/NN). The VIP itself is
    skipped, since keepalived may already hold it."""
    vip = ipaddress.ip_interface(vip)
    for name, ip in addrs:
        addr = ipaddress.ip_address(ip)
        if addr != vip.ip and addr in vip.network:
            return name, ip
    raise LookupError(f"no IPv4 address in {vip.network}")


def candidate(machine_id, attempt, cidr, exclude):
    """The host address for this attempt, spread over cidr by sha256 of the machine-id. None if it is
    in exclude, and the caller moves to the next attempt."""
    h = int.from_bytes(
        hashlib.sha256(f"{machine_id}:{attempt}".encode()).digest(), "big"
    )
    ip = cidr.network_address + 1 + h % (cidr.num_addresses - 2)
    return None if ip in exclude else ip


def nmcli(*a):
    return subprocess.run(["nmcli", *a], capture_output=True, text=True, check=False)


def iface():
    """The first ethernet device by name that NetworkManager manages and that has a carrier."""
    r = nmcli("--terse", "--fields", "DEVICE,TYPE,STATE", "device")
    r.check_returncode()
    for line in sorted(r.stdout.splitlines()):
        dev, kind, state = line.split(":", 2)
        if kind == "ethernet" and state not in (
            "unavailable",
            "unmanaged",
        ):  # unavailable: no carrier
            return dev
    raise LookupError("no ethernet device with a carrier")


def assign(iface, ip, prefix, gateway, dns):
    """Save and activate a static profile. False if activation fails, as it does on an address conflict.
    Its priority beats cloud-init's DHCP profile (120), so NetworkManager brings it up on every boot."""
    nmcli("con", "delete", PROFILE)  # left by an interrupted boot
    args = [
        "con",
        "add",
        "type",
        "ethernet",
        "con-name",
        PROFILE,
        "ifname",
        iface,
        "ipv4.method",
        "manual",
        "ipv4.addresses",
        f"{ip}/{prefix}",
        "ipv4.may-fail",
        "no",
        "ipv4.dad-timeout",
        "3000",
        "connection.autoconnect-priority",
        "999",
        "ipv6.method",
        "disabled",
    ]  # IPv4 only for now. #15 notes IPv6 discovery to revisit.
    args += ["ipv4.gateway", gateway] if gateway else ["ipv4.routes", "0.0.0.0/0"]
    if dns:
        args += ["ipv4.dns", dns]
    for a in (args, ["con", "up", PROFILE]):
        r = nmcli(*a)
        if r.returncode:
            print(f"nmcli {a[1]} {ip}: {r.stderr.strip()}", flush=True)
            nmcli("con", "delete", PROFILE)
            return False
    return True


def main():
    env = os.environ
    vip = ipaddress.ip_interface(env["VIP"])
    if vip.network.prefixlen > 30:
        sys.exit(
            f"VIP={env['VIP']} must carry the site prefix, /30 or shorter, e.g. VIP=192.168.150.10/24"
        )
    gateway, dns = env.get("GATEWAY", ""), env.get("DNS", "")
    exclude = {ipaddress.ip_address(a) for a in (str(vip.ip), gateway, dns) if a}
    with open(MACHINE_ID) as f:
        machine_id = f.read().strip()
    attempt, saved = 0, True
    while True:
        try:
            name, ip = pick(env["VIP"], addrs())
            break
        except LookupError as e:
            print(e, flush=True)
        try:
            name = iface()
        except LookupError as e:
            print(e, flush=True)
            time.sleep(INTERVAL)
            continue
        # A profile a previous boot saved keeps its address. Only a failed activation, or no saved profile, derives a
        # new one.
        if saved:
            saved = False
            if nmcli("con", "up", PROFILE).returncode == 0:
                continue
        ip = candidate(machine_id, attempt, vip.network, exclude)
        attempt += 1
        if ip is None:
            continue
        if assign(name, ip, vip.network.prefixlen, gateway, dns):
            break
        time.sleep(
            INTERVAL
        )  # spaces out a persistent nmcli error and two nodes probing one address
    write(NODE_ENV, f"NODE_IP={ip}\nNODE_IFACE={name}\n")
    print(f"{ip} on {name}", flush=True)


if __name__ == "__main__":
    main()
