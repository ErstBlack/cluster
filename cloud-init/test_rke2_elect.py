import os
import tempfile
import unittest

from rke2_elect import (EXPIRE, INTERVAL, SETTLE, decide, elect, load_state, role_of, settled, sign,
                        top, verify)

A, B, C, D = (9, "10.0.0.1"), (7, "10.0.0.2"), (7, "10.0.0.3"), (1, "10.0.0.4")


class Decide(unittest.TestCase):
    def test_single_node_bootstraps(self):
        self.assertEqual(decide(D, [], 3), ("server", True))

    def test_fewer_nodes_than_n_are_all_servers(self):
        self.assertEqual(decide(A, [D], 3), ("server", True))
        self.assertEqual(decide(D, [A], 3), ("server", False))

    def test_top_n_are_servers_and_the_rest_agents(self):
        self.assertEqual(decide(A, [B, C, D], 3), ("server", True))
        self.assertEqual(decide(B, [A, C, D], 3), ("server", False))
        self.assertEqual(decide(D, [A, B, C], 3), ("agent", False))

    def test_token_tie_breaks_on_ip_the_same_on_every_node(self):
        self.assertEqual(top([B, C], 1), [C])
        self.assertEqual(decide(B, [C], 1), ("agent", False))
        self.assertEqual(decide(C, [B], 1), ("server", True))

    def test_every_node_agrees_on_one_bootstrap(self):
        nodes = [A, B, C, D]
        boots = [n for n in nodes if decide(n, [p for p in nodes if p != n], 3)[1]]
        self.assertEqual(boots, [A])


    def test_identity_is_token_and_ip(self):
        # A rebuilt VM at the bootstrap's ip draws a new token and must not bootstrap again.
        self.assertEqual(role_of((5, A[1]), [A, B]), ("agent", False))
        self.assertEqual(role_of(A, [A, B]), ("server", True))


def beacon(node, servers=None):
    b = {"ip": node[1], "token": node[0], "state": "electing" if servers is None else "decided"}
    return {**b, "servers": servers or []}


def run(me, heard, vip=lambda: False):
    """elect() on a fake network: every INTERVAL a tick, then the beacons heard(t) returns."""
    t = [0.0]

    def exchange(_):
        while t[0] < 1000:
            yield None
            t[0] += INTERVAL
            yield from heard(t[0])
        raise AssertionError("elect did not return")

    return elect(me, 3, exchange, vip, lambda: t[0])


class Elect(unittest.TestCase):
    def test_peer_that_went_silent_is_not_elected(self):
        heard = lambda t: [beacon(B)] + ([beacon(A)] if t < 20 else [])
        self.assertEqual(run(D, heard), [B, D])

    def test_decided_beacon_is_adopted(self):
        heard = lambda t: [beacon(B, [B, D])] if t == 10 else []
        self.assertEqual(run(A, heard), [B, D])

    def test_grace_switches_only_to_a_higher_decision(self):
        # B is first heard at t=2, so D decides [B, D] at t=62 and is in grace at t=64.
        low = (2, "10.0.0.5")
        higher = lambda t: [beacon(B)] + ([beacon(A, [A])] if t == 64 else [])
        lower = lambda t: [beacon(B)] + ([beacon(low, [low])] if t == 64 else [])
        self.assertEqual(run(D, higher), [A])
        self.assertEqual(run(D, lower), [B, D])

    def test_vip_answering_means_agent(self):
        self.assertEqual(run(A, lambda t: [], vip=lambda: True), [])


class State(unittest.TestCase):
    def test_token_survives_a_restart(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "elect.json")
            self.assertEqual(load_state(path), load_state(path))

    def test_recorded_decision_skips_the_election(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "elect.json")
            first = settled(path, "10.0.0.1", lambda me: [me], lambda: False)
            self.assertEqual((first["role"], first["bootstrap"]), ("server", True))

            def elect_again(me):
                raise AssertionError("re-elected despite a recorded decision")
            again = settled(path, "10.0.0.1", elect_again, lambda: True)
            self.assertEqual((again["token"], again["role"], again["bootstrap"]),
                             (first["token"], "server", True))

    def test_bootstrap_joins_as_agent_when_the_vip_answers(self):
        with tempfile.TemporaryDirectory() as d:
            state = settled(os.path.join(d, "elect.json"), "10.0.0.1", lambda me: [me], lambda: True)
            self.assertEqual((state["role"], state["bootstrap"]), ("agent", False))

    def test_settle_outlasts_expiry(self):
        # A peer that dies right after its first beacon must be dropped before anyone decides.
        self.assertGreater(SETTLE, EXPIRE + INTERVAL)


class Beacon(unittest.TestCase):
    body = {"ip": "10.0.0.1", "token": 9, "state": "decided", "servers": [A]}

    def test_round_trip(self):
        self.assertEqual(verify(b"k", sign(b"k", self.body)), self.body)

    def test_wrong_key_or_tampered_is_dropped(self):
        self.assertIsNone(verify(b"other", sign(b"k", self.body)))
        self.assertIsNone(verify(b"k", sign(b"k", self.body).replace(b'"token": 9', b'"token": 99')))
        self.assertIsNone(verify(b"k", b"not json"))


if __name__ == "__main__":
    unittest.main()
