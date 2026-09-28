import ipaddress
import os
import subprocess
import tempfile
import unittest
from unittest import mock

import node_addr
from node_addr import addrs, assign, candidate, iface, pick

VIP = "192.168.150.10/24"
NET = ipaddress.ip_network("192.168.150.0/24")


class Pick(unittest.TestCase):
    def test_takes_the_address_on_the_vips_subnet(self):
        found = [
            ("lo", "127.0.0.1"),
            ("eth0", "10.0.0.5"),
            ("eth1", "192.168.150.11"),
        ]
        self.assertEqual(pick(VIP, found), ("eth1", "192.168.150.11"))

    def test_skips_the_vip_itself(self):
        found = [
            ("eth0", "192.168.150.10"),
            ("eth0", "192.168.150.11"),
        ]
        self.assertEqual(pick(VIP, found), ("eth0", "192.168.150.11"))

    def test_raises_when_no_address_matches(self):
        with self.assertRaises(LookupError):
            pick(
                VIP,
                [
                    ("lo", "127.0.0.1"),
                    ("eth0", "10.0.0.5"),
                ],
            )

    def test_matches_by_the_vips_prefix_not_the_addresss_own(self):
        # Only the VIP's /24 counts. 192.168.151.5 is outside it, even though a /16 around it holds the VIP.
        self.assertEqual(
            pick(
                VIP,
                [
                    ("eth0", "192.168.151.5"),
                    ("eth1", "192.168.150.20"),
                ],
            ),
            ("eth1", "192.168.150.20"),
        )


class Candidate(unittest.TestCase):
    def test_is_deterministic(self):
        self.assertEqual(
            candidate("abc", 0, NET, set()), candidate("abc", 0, NET, set())
        )
        self.assertNotEqual(
            candidate("abc", 0, NET, set()), candidate("abc", 1, NET, set())
        )

    def test_stays_inside_the_network_and_off_its_ends(self):
        for cidr in (NET, ipaddress.ip_network("10.20.0.0/16")):
            seen = {
                candidate(f"m{i}", a, cidr, set()) for i in range(200) for a in range(5)
            }
            self.assertTrue(all(ip in cidr for ip in seen))
            self.assertNotIn(cidr.network_address, seen)
            self.assertNotIn(cidr.broadcast_address, seen)

    def test_returns_none_for_an_excluded_address(self):
        ip = candidate("abc", 0, NET, set())
        self.assertIsNone(candidate("abc", 0, NET, {ip}))


def done(rc=0, stdout="", stderr=""):
    return subprocess.CompletedProcess([], rc, stdout, stderr)


NO_PROFILE = done(10)  # nmcli con up with no saved profile


class Iface(unittest.TestCase):
    def devices(self, out):
        with mock.patch.object(
            node_addr.subprocess, "run", return_value=done(stdout=out)
        ):
            return iface()

    def test_takes_the_first_ethernet_with_carrier_by_name(self):
        out = (
            "lo:loopback:connected (externally)\neth2:ethernet:disconnected\neth0:ethernet:unavailable\n"
            "eth1:ethernet:connecting (getting IP configuration)\n"
        )
        self.assertEqual(self.devices(out), "eth1")

    def test_raises_without_carrier(self):
        with self.assertRaises(LookupError):
            self.devices("eth0:ethernet:unavailable\neth1:ethernet:unmanaged\n")


class Assign(unittest.TestCase):
    def calls(self, results, gateway="", dns=""):
        with mock.patch.object(node_addr.subprocess, "run", side_effect=results) as run:
            ok = assign("eth0", "192.168.150.77", 24, gateway, dns)
        return ok, [c.args[0][1:] for c in run.call_args_list]

    def test_adds_an_on_link_default_route_without_a_gateway(self):
        ok, calls = self.calls([done(), done(), done()])
        self.assertTrue(ok)
        add = calls[1]
        self.assertIn("192.168.150.77/24", add)
        self.assertEqual(add[add.index("ipv4.routes") + 1], "0.0.0.0/0")
        self.assertNotIn("ipv4.gateway", add)
        self.assertNotIn("ipv4.dns", add)
        self.assertEqual(calls[2], ["con", "up", "cluster"])

    def test_sets_gateway_and_dns(self):
        _, calls = self.calls(
            [done(), done(), done()], gateway="192.168.150.1", dns="192.168.150.1"
        )
        add = calls[1]
        self.assertEqual(add[add.index("ipv4.gateway") + 1], "192.168.150.1")
        self.assertEqual(add[add.index("ipv4.dns") + 1], "192.168.150.1")
        self.assertNotIn("ipv4.routes", add)

    def test_deletes_the_profile_when_activation_fails(self):
        ok, calls = self.calls([done(), done(), done(4, stderr="conflict"), done()])
        self.assertFalse(ok)
        self.assertEqual(calls[-1], ["con", "delete", "cluster"])


class Addrs(unittest.TestCase):
    def test_reads_loopback(self):
        self.assertIn(("lo", "127.0.0.1"), addrs())


class Main(unittest.TestCase):
    def run_main(
        self,
        addrs,
        iface=("eth0",),
        assign=(True,),
        nmcli=(NO_PROFILE,),
        vip=VIP,
    ):
        """nmcli answers the nmcli calls main makes itself. assign=None runs the real assign on it."""
        with tempfile.NamedTemporaryFile("w") as mid:
            mid.write("abc\n")
            mid.flush()
            with (
                mock.patch.dict(os.environ, {"VIP": vip, "GATEWAY": "", "DNS": ""}),
                mock.patch.object(node_addr, "MACHINE_ID", mid.name),
                mock.patch.object(node_addr, "addrs", side_effect=addrs),
                mock.patch.object(node_addr, "iface", side_effect=iface),
                mock.patch.object(
                    node_addr.subprocess, "run", side_effect=nmcli
                ) as run,
                (
                    mock.patch.object(node_addr, "assign", side_effect=assign)
                    if assign
                    else mock.MagicMock()
                ) as a,
                mock.patch.object(node_addr.time, "sleep") as sleep,
                mock.patch.object(node_addr, "write") as write,
            ):
                node_addr.main()
        return a, sleep, write, [c.args[0] for c in run.call_args_list]

    def test_keeps_an_existing_address(self):
        a, _, write, nmcli = self.run_main([[("eth0", "192.168.150.11")]])
        a.assert_not_called()
        self.assertEqual(nmcli, [])
        write.assert_called_once_with(
            node_addr.NODE_ENV, "NODE_IP=192.168.150.11\nNODE_IFACE=eth0\n"
        )

    def test_brings_up_the_saved_profile_instead_of_replacing_it(self):
        # assign=None: a delete from the real assign would show up in nmcli.
        _, _, write, nmcli = self.run_main(
            [[], [("eth0", "192.168.150.77")]],
            assign=None,
            nmcli=[done()],
        )
        self.assertEqual(nmcli, [["nmcli", "con", "up", "cluster"]])
        write.assert_called_once_with(
            node_addr.NODE_ENV, "NODE_IP=192.168.150.77\nNODE_IFACE=eth0\n"
        )

    def test_waits_for_a_carrier_instead_of_failing(self):
        lo = [("lo", "127.0.0.1")]
        a, sleep, _, _ = self.run_main(
            [lo, lo], iface=[LookupError("no carrier"), "eth0"]
        )
        sleep.assert_called_once()
        a.assert_called_once()

    def test_moves_to_the_next_attempt_after_a_conflict(self):
        lo = [("lo", "127.0.0.1")]
        exclude = {ipaddress.ip_address("192.168.150.10")}
        first, second = (candidate("abc", n, NET, exclude) for n in (0, 1))
        a, sleep, write, _ = self.run_main(
            [lo, lo], iface=["eth0", "eth0"], assign=[False, True]
        )
        self.assertEqual(
            [c.args for c in a.call_args_list],
            [("eth0", first, 24, "", ""), ("eth0", second, 24, "", "")],
        )
        sleep.assert_called_once_with(node_addr.INTERVAL)
        write.assert_called_once_with(
            node_addr.NODE_ENV, f"NODE_IP={second}\nNODE_IFACE=eth0\n"
        )

    def test_refuses_a_vip_without_a_usable_prefix(self):
        for vip in ("192.168.150.10", "192.168.150.10/32", "192.168.150.10/31"):
            with self.subTest(vip=vip), self.assertRaises(SystemExit) as e:
                self.run_main([], vip=vip)
            self.assertIn("/30 or shorter", str(e.exception))
