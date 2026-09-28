import os
import unittest
from unittest import mock

import node_addr
from node_addr import addrs, pick

VIP = "192.168.150.10"


class Pick(unittest.TestCase):
    def test_takes_the_address_on_the_vips_subnet(self):
        found = [
            ("lo", "127.0.0.1", "255.0.0.0"),
            ("eth0", "10.0.0.5", "255.255.255.0"),
            ("eth1", "192.168.150.11", "255.255.255.0"),
        ]
        self.assertEqual(pick(VIP, found), ("eth1", "192.168.150.11"))

    def test_skips_the_vip_itself(self):
        found = [
            ("eth0", VIP, "255.255.255.0"),
            ("eth0", "192.168.150.11", "255.255.255.0"),
        ]
        self.assertEqual(pick(VIP, found), ("eth0", "192.168.150.11"))

    def test_raises_when_no_address_matches(self):
        with self.assertRaises(LookupError):
            pick(
                VIP,
                [
                    ("lo", "127.0.0.1", "255.0.0.0"),
                    ("eth0", "10.0.0.5", "255.255.255.0"),
                ],
            )


class Addrs(unittest.TestCase):
    def test_reads_loopback(self):
        self.assertIn(("lo", "127.0.0.1", "255.0.0.0"), addrs())


class Main(unittest.TestCase):
    def test_waits_for_an_address_instead_of_failing(self):
        late = [
            [("lo", "127.0.0.1", "255.0.0.0")],
            [("eth0", "192.168.150.11", "255.255.255.0")],
        ]
        with (
            mock.patch.dict(os.environ, {"VIP": VIP}),
            mock.patch.object(node_addr, "addrs", side_effect=late),
            mock.patch.object(node_addr.time, "sleep") as sleep,
            mock.patch.object(node_addr, "write") as write,
        ):
            node_addr.main()
        sleep.assert_called_once()
        write.assert_called_once_with(
            node_addr.NODE_ENV, "NODE_IP=192.168.150.11\nNODE_IFACE=eth0\n"
        )
