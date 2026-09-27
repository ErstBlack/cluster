#!/usr/bin/python3
"""Find this node's address on the VIP's subnet and write it to NODE_ENV for rke2-elect and rke2-configure.

The address is read, not assigned: DHCP or static config puts it there first. This waits until one
shows up, so the unit's start job only ever succeeds and the units that require it stay queued.

ponytail: a node with two NICs on the VIP's subnet takes the first.
"""
import fcntl
import ipaddress
import os
import socket
import struct
import time

from rke2_elect import INTERVAL, write

NODE_ENV = "/run/rke2/node.env"
SIOCGIFADDR = 0x8915
SIOCGIFNETMASK = 0x891B


def addrs():
    """(ifname, ip, netmask) for every interface with an IPv4 address."""
    found = []
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        for _, name in socket.if_nameindex():
            req = struct.pack("256s", name.encode())
            try:
                ip = fcntl.ioctl(s.fileno(), SIOCGIFADDR, req)[20:24]
                mask = fcntl.ioctl(s.fileno(), SIOCGIFNETMASK, req)[20:24]
            except OSError:  # no IPv4 address
                continue
            found.append((name, socket.inet_ntoa(ip), socket.inet_ntoa(mask)))
    return found


def pick(vip, addrs):
    """(ifname, ip) of the first address whose network holds vip. The VIP itself is skipped, since
    keepalived may already hold it."""
    vip = ipaddress.ip_address(vip)
    for name, ip, mask in addrs:
        if ipaddress.ip_address(ip) != vip and vip in ipaddress.ip_network(f"{ip}/{mask}", strict=False):
            return name, ip
    raise LookupError(f"no IPv4 address shares a subnet with the VIP {vip}")


def main():
    while True:
        try:
            name, ip = pick(os.environ["VIP"], addrs())
            break
        except LookupError as e:
            print(e, flush=True)
            time.sleep(INTERVAL)
    write(NODE_ENV, f"NODE_IP={ip}\nNODE_IFACE={name}\n")
    print(f"{ip} on {name}", flush=True)


if __name__ == "__main__":
    main()
