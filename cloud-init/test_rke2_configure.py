import json
import os
import tempfile
import unittest
from unittest import mock

import rke2_configure
import rke2_elect
from rke2_configure import CHECK, config_yaml, keepalived_conf

ENV = {"RKE2_TOKEN": "secret", "VIP": "192.168.150.10", "NODE_IP": "192.168.150.11"}


class ConfigYaml(unittest.TestCase):
    def test_bootstrap_server_has_no_server_line(self):
        self.assertNotIn("server:", config_yaml(ENV, "server", True))

    def test_joining_server_and_agent_join_through_the_vip(self):
        for role in ("server", "agent"):
            self.assertIn(
                "server: https://192.168.150.10:9345\n", config_yaml(ENV, role, False)
            )

    def test_only_servers_get_tls_san_and_etcd_args(self):
        server = config_yaml(ENV, "server", False)
        self.assertIn("tls-san:\n  - 192.168.150.11\n  - 192.168.150.10\n", server)
        self.assertIn(
            "etcd-arg:\n  - heartbeat-interval=500\n  - election-timeout=5000\n", server
        )
        agent = config_yaml(ENV, "agent", False)
        self.assertNotIn("tls-san", agent)
        self.assertNotIn("etcd-arg", agent)

    def test_token_with_quotes_colons_and_backslashes_keeps_its_value(self):
        # A JSON double-quoted string is a valid YAML scalar, and the stdlib has no YAML parser.
        token = """a"b'c: d\\e\\"f"""
        line = config_yaml({**ENV, "RKE2_TOKEN": token}, "agent", False).splitlines()[0]
        self.assertTrue(line.startswith("token: "))
        self.assertEqual(json.loads(line[len("token: ") :]), token)

    def test_each_epoch_has_its_own_join_token(self):
        token = lambda epoch: config_yaml(ENV, "agent", False, epoch).splitlines()[0]
        self.assertEqual(token(0), 'token: "secret"')
        self.assertEqual(token(1), token(1))
        self.assertEqual(len({token(0), token(1), token(2)}), 3)
        self.assertNotIn("secret", token(1))


class KeepalivedConf(unittest.TestCase):
    def test_holds_the_vip_on_the_interface_and_tracks_the_check(self):
        conf = keepalived_conf("192.168.150.10", "eth1")
        self.assertIn("    192.168.150.10/32\n", conf)
        self.assertIn("  interface eth1\n", conf)
        self.assertIn(f'  script "{CHECK}"\n', conf)
        self.assertIn("track_script {\n    chk_rke2\n  }", conf)


class Main(unittest.TestCase):
    def setUp(self):
        d = tempfile.TemporaryDirectory()
        self.addCleanup(d.cleanup)
        self.state = os.path.join(d.name, "elect.json")
        self.config = os.path.join(d.name, "rke2", "config.yaml")
        self.keepalived = os.path.join(d.name, "keepalived", "keepalived.conf")
        self.epoch = os.path.join(d.name, "rke2", "epoch")
        self.data = os.path.join(d.name, "data")
        self.password = os.path.join(d.name, "node", "password")
        self.vip_up = mock.Mock(return_value=True)
        self.write = mock.Mock(side_effect=rke2_elect.write)
        self.run_ = mock.Mock()
        for name, value in (
            ("STATE", self.state),
            ("CONFIG", self.config),
            ("KEEPALIVED", self.keepalived),
            ("EPOCH", self.epoch),
            ("DATA", self.data),
            ("NODE_PASSWORD", self.password),
            ("vip_up", self.vip_up),
            ("write", self.write),
        ):
            p = mock.patch.object(rke2_configure, name, value)
            p.start()
            self.addCleanup(p.stop)
        for p in (
            mock.patch.object(rke2_configure.subprocess, "run", self.run_),
            mock.patch.object(rke2_configure.time, "sleep"),
            mock.patch.dict(
                os.environ, {**ENV, "VIP": "192.168.150.10/24", "NODE_IFACE": "eth1"}
            ),
        ):
            p.start()
            self.addCleanup(p.stop)

    def main(self, state):
        if state is not None:
            with open(self.state, "w") as f:
                json.dump({"epoch": 0, **state}, f)
        rke2_configure.main()

    def assert_started(self, role):
        self.run_.assert_called_once_with(
            [
                "systemctl",
                "enable",
                "--now",
                "--no-block",
                *(
                    ["rke2-server", "keepalived"]
                    if role == "server"
                    else ["rke2-agent"]
                ),
            ],
            check=True,
        )

    def test_no_role_exits_nonzero_and_writes_nothing(self):
        for state in (None, {}):
            with self.subTest(state=state), self.assertRaises(SystemExit) as e:
                self.main(state)
            self.assertNotIn(e.exception.code, (0, None))
        self.write.assert_not_called()
        self.run_.assert_not_called()
        self.assertFalse(os.path.exists(self.config) or os.path.exists(self.keepalived))

    def test_joining_node_writes_nothing_until_the_vip_answers(self):
        answers = iter([False, False, True])

        def vip_up(vip):
            self.assertFalse(
                os.path.exists(self.config) or os.path.exists(self.keepalived)
            )
            return next(answers)

        self.vip_up.side_effect = vip_up
        self.main({"role": "server", "bootstrap": False})
        self.assertEqual(self.vip_up.call_args_list, [mock.call("192.168.150.10")] * 3)
        self.assertTrue(os.path.exists(self.config) and os.path.exists(self.keepalived))

    def test_bootstrap_does_not_wait_for_the_vip(self):
        self.main({"role": "server", "bootstrap": True})
        self.vip_up.assert_not_called()
        self.assert_started("server")

    def test_server_writes_keepalived_before_config(self):
        self.main({"role": "server", "bootstrap": False})
        self.assertEqual(
            [c.args[0] for c in self.write.call_args_list],
            [self.keepalived, self.epoch, self.config],
        )
        with open(self.keepalived) as f:
            self.assertEqual(f.read(), keepalived_conf("192.168.150.10", "eth1"))
        self.assert_started("server")

    def test_agent_writes_no_keepalived(self):
        self.main({"role": "agent", "bootstrap": False})
        self.assertEqual(
            [c.args[0] for c in self.write.call_args_list], [self.epoch, self.config]
        )
        self.assertFalse(os.path.exists(self.keepalived))
        self.assert_started("agent")

    def test_existing_config_is_kept_and_units_still_start(self):
        for role in ("server", "agent"):
            with self.subTest(role=role):
                rke2_elect.write(self.config, "old\n")
                self.run_.reset_mock()
                self.main({"role": role, "bootstrap": False})
                self.write.assert_not_called()
                self.vip_up.assert_not_called()
                with open(self.config) as f:
                    self.assertEqual(f.read(), "old\n")
                self.assert_started(role)

    def old_epoch(self):
        """A server's files from epoch 0: removed by a reset, and kept by it."""
        removed = [
            "server/db/etcd/member",
            "agent/pod-manifests/etcd.yaml",
            "agent/etc/rke2-agent-load-balancer.json",
            "agent/client-kubelet.crt",
            "agent/client-kubelet.key",
            "agent/kubelet.kubeconfig",
        ]
        kept = [
            "agent/containerd/io.containerd.metadata.v1.bolt/meta.db",
            "data/v1/bin/rke2",
        ]
        removed = [os.path.join(self.data, p) for p in removed]
        removed += [self.password, self.keepalived, self.config]
        kept = [os.path.join(self.data, p) for p in kept]
        for path in (*removed, *kept):
            rke2_elect.write(path, "old\n")
        rke2_elect.write(self.epoch, "0")
        return removed, kept

    def test_same_epoch_does_not_reset(self):
        removed, kept = self.old_epoch()
        self.main({"role": "server", "bootstrap": False})
        self.assertTrue(all(os.path.exists(p) for p in (*removed, *kept)))
        self.assert_started("server")

    def test_new_epoch_resets_then_takes_the_first_boot_path(self):
        removed, kept = self.old_epoch()
        self.main({"epoch": 1, "role": "agent", "bootstrap": False})
        self.assertEqual(
            [c.args[0] for c in self.run_.call_args_list],
            [
                [
                    "systemctl",
                    "disable",
                    "--now",
                    "keepalived",
                    "rke2-server",
                    "rke2-agent",
                ],
                ["/usr/bin/rke2-killall.sh"],
                ["systemctl", "enable", "--now", "--no-block", "rke2-agent"],
            ],
        )
        # CONFIG is written again, for the new role.
        self.assertEqual([p for p in removed if os.path.exists(p)], [self.config])
        self.assertTrue(all(os.path.exists(p) for p in kept))
        self.vip_up.assert_called_once_with("192.168.150.10")
        self.assertEqual(
            [c.args[:2] for c in self.write.call_args_list],
            [(self.epoch, "1"), (self.config, config_yaml(ENV, "agent", False, 1))],
        )


if __name__ == "__main__":
    unittest.main()
