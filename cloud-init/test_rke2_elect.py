import os
import tempfile
import unittest
from typing import ClassVar

from rke2_elect import (
    DEADLINE,
    EXPIRE,
    INTERVAL,
    SETTLE,
    elect,
    load_state,
    role_of,
    settled,
    sign,
    top,
    verify,
    watch,
)

A, B, C, D = (9, "10.0.0.1"), (7, "10.0.0.2"), (7, "10.0.0.3"), (1, "10.0.0.4")


def decide(me, peers, n):
    """me and peers are (token, ip). Same peer set on every node gives the same answer."""
    return role_of(me, top({me, *peers}, n))


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


def beacon(node, servers=None, epoch=0, joined=False):
    b = {
        "ip": node[1],
        "token": node[0],
        "state": "electing" if servers is None else "decided",
        "epoch": epoch,
        "joined": joined,
    }
    return {**b, "servers": servers or []}


def network(heard):
    """A fake exchange and clock: every INTERVAL a tick, then the beacons heard(t) returns."""
    t = [0.0]

    def exchange(_):
        while t[0] < 1000:
            yield None
            t[0] += INTERVAL
            yield from heard(t[0])
        raise AssertionError("did not return")

    return exchange, lambda: t[0]


def run(me, heard, vip=lambda: False, epoch=0):
    """elect() on the fake network."""
    exchange, clock = network(heard)
    return elect(me, 3, exchange, vip, clock, epoch)


class Elect(unittest.TestCase):
    def test_peer_that_went_silent_is_not_elected(self):
        heard = lambda t: [beacon(B)] + ([beacon(A)] if t < 20 else [])
        self.assertEqual(run(D, heard), (0, [B, D]))

    def test_decided_beacon_is_adopted(self):
        heard = lambda t: [beacon(B, [B, D])] if t == 10 else []
        self.assertEqual(run(A, heard), (0, [B, D]))

    def test_grace_switches_only_to_a_higher_decision(self):
        # B is first heard at t=2, so D decides [B, D] at t=62 and is in grace at t=64.
        low = (2, "10.0.0.5")
        higher = lambda t: [beacon(B)] + ([beacon(A, [A])] if t == 64 else [])
        lower = lambda t: [beacon(B)] + ([beacon(low, [low])] if t == 64 else [])
        self.assertEqual(run(D, higher), (0, [A]))
        self.assertEqual(run(D, lower), (0, [B, D]))

    def test_vip_answering_means_agent(self):
        self.assertEqual(run(A, lambda t: [], vip=lambda: True), (0, []))

    def test_decision_heard_before_the_vip_is_adopted_with_its_epoch(self):
        # A late node at a site that re-elected: the VIP answers, and so do the epoch 1 beacons.
        heard = lambda t: [beacon(B, [B, D], epoch=1)]
        self.assertEqual(run(A, heard, vip=lambda: True), (1, [B, D]))

    def test_beacon_from_another_key_changes_nothing(self):
        # rogue_beacons in ci/case.sh: a node with the wrong key, a winning token and its own decision.
        rogue = (2**64, "10.0.0.9")
        wire = [
            sign(b"k", beacon(B)),
            sign(b"not-the-token", beacon(rogue)),
            sign(b"not-the-token", beacon(rogue, [rogue])),
        ]
        # The filter exchange() applies to what it receives.
        heard = lambda t: [b for b in (verify(b"k", w) for w in wire) if b]
        self.assertEqual(run(D, heard), (0, [B, D]))

    def test_staggered_peers_are_one_decision(self):
        # Each peer arrives just inside the quiet window the one before it opened.
        start = {B: INTERVAL, C: SETTLE, A: 2 * SETTLE - INTERVAL}
        heard = lambda t: [beacon(p) for p, s in start.items() if t >= s]
        self.assertEqual(run(D, heard), (0, [A, C, B]))

    def test_late_node_adopts_the_decision_as_agent(self):
        # A has the highest token but finds the decision made, during GRACE or after it.
        _, decided = run(A, lambda t: [beacon(p, [B, C, D]) for p in (B, C, D)])
        self.assertEqual(decided, [B, C, D])
        self.assertEqual(role_of(A, decided), ("agent", False))
        _, after = run(A, lambda t: [], vip=lambda: True)
        self.assertEqual(role_of(A, after), ("agent", False))

    def test_earlier_epoch_decision_is_ignored_and_a_later_one_adopted(self):
        stale = lambda t: [beacon(B, epoch=1)] + ([beacon(A, [A])] if t == 10 else [])
        self.assertEqual(run(D, stale, epoch=1), (1, [B, D]))
        later = lambda t: [beacon(B, [B, D], epoch=2)] if t == 10 else []
        self.assertEqual(run(D, later, epoch=1), (2, [B, D]))
        # A node at first boot adopts the epoch the site is at.
        self.assertEqual(run(A, later), (2, [B, D]))

    def test_grace_orders_by_epoch_then_servers(self):
        # As in test_grace_switches_only_to_a_higher_decision, D is in grace at t=64.
        later = lambda t: [beacon(B)] + ([beacon(D, [D], epoch=1)] if t == 64 else [])
        earlier = lambda t: [beacon(B, epoch=1)] + ([beacon(A, [A])] if t == 64 else [])
        self.assertEqual(run(D, later), (1, [D]))
        self.assertEqual(run(D, earlier, epoch=1), (1, [B, D]))


def watching(me, epoch, servers, heard, joined=lambda: False):
    """watch() on the fake network, and the time it returned."""
    exchange, clock = network(heard)
    return watch(me, epoch, servers, 3, exchange, joined, clock), clock()


class Watch(unittest.TestCase):
    # A bootstraps at epoch 0 with B and C as servers. A goes silent at t=20.
    servers: ClassVar[list] = [A, B, C]

    def heard(self, joined=frozenset()):
        """Beacons around B: A until t=20, and C and D, which elect at epoch 1 once A has been
        silent for DEADLINE unless a server they hear has joined."""

        def heard(t):
            out = [beacon(A, self.servers, joined=A in joined)] if t < 20 else []
            electing = t >= 20 + DEADLINE and not joined - {A}
            for p in (C, D):
                if electing:
                    out.append(beacon(p, epoch=1))
                else:
                    out.append(beacon(p, self.servers, joined=p in joined))
            return out

        return heard

    def test_silent_bootstrap_with_no_joined_server_is_replaced(self):
        (epoch, servers), t = watching(B, 0, self.servers, self.heard())
        self.assertEqual((epoch, servers), (1, [C, B, D]))
        self.assertGreaterEqual(t, 20 + DEADLINE + SETTLE)

    def test_joined_server_blocks_the_replacement(self):
        with self.assertRaises(AssertionError):
            watching(B, 0, self.servers, self.heard(joined={C}))
        # B's own role unit counts too.
        with self.assertRaises(AssertionError):
            watching(B, 0, self.servers, self.heard(joined={A}), joined=lambda: True)

    def test_bootstrap_never_replaces_itself(self):
        with self.assertRaises(AssertionError):
            watching(A, 0, self.servers, lambda t: [])

    def test_node_hearing_too_few_servers_does_not_re_elect(self):
        # Cut off from the rest, alone or with one server of three: it must not elect a cluster.
        for me, heard in ((D, []), (B, []), (D, [beacon(B, self.servers)])):
            with self.subTest(me=me, heard=heard), self.assertRaises(AssertionError):
                watching(me, 0, self.servers, lambda t, heard=heard: heard)

    def test_healthy_joined_cluster_ignores_a_later_epoch(self):
        # E elected (1, [E]) apart from a working cluster, then became reachable.
        E = (3, "10.0.0.5")
        heard = lambda t: [
            *(beacon(p, self.servers, joined=True) for p in (A, B, C)),
            beacon(E, [E], epoch=1, joined=True),
        ]
        for me in (A, B, D):
            with self.subTest(me=me), self.assertRaises(AssertionError):
                watching(me, 0, self.servers, heard, joined=lambda: True)

    def test_returning_old_bootstrap_adopts_the_later_epoch_as_an_agent(self):
        # A's own lone cluster is up, and the epoch 1 servers have joined theirs.
        heard = lambda t: [
            beacon(p, [C, B, D], epoch=1, joined=True) for p in (B, C, D)
        ]
        (epoch, servers), _ = watching(A, 0, self.servers, heard, joined=lambda: True)
        self.assertEqual((epoch, servers), (1, [C, B, D]))
        self.assertEqual(role_of(A, servers), ("agent", False))

    def test_minority_side_of_a_healed_partition_adopts_the_majority_epoch(self):
        # Five servers. {A, B} joined and {C, D, F} re-elected at epoch 1 while cut off from them.
        F = (5, "10.0.0.6")
        five = [A, B, C, D, F]
        later = [beacon(p, [C, D, F], epoch=1, joined=True) for p in (C, D, F)]
        for me, other in ((A, B), (B, A)):
            heard = lambda t, other=other: [beacon(other, five, joined=True), *later]
            with self.subTest(me=me):
                (epoch, servers), _ = watching(me, 0, five, heard, joined=lambda: True)
                self.assertEqual((epoch, servers), (1, [C, D, F]))

    def test_later_epoch_heard_before_any_peer_is_not_adopted(self):
        # Just after a restart B hears E's epoch first, then its own joined cluster.
        E = (3, "10.0.0.5")
        heard = lambda t: (
            [beacon(E, [E], epoch=1)]
            if t == INTERVAL
            else [beacon(p, self.servers, joined=True) for p in (A, C)]
        )
        with self.assertRaises(AssertionError):
            watching(B, 0, self.servers, heard)

    def test_slow_survivor_adopts_the_later_epoch(self):
        # B re-elected already. C is still at epoch 0 and has not joined.
        heard = lambda t: [beacon(B, [C, B, D], epoch=1), beacon(C, self.servers)]
        (epoch, servers), _ = watching(D, 0, self.servers, heard)
        self.assertEqual((epoch, servers), (1, [C, B, D]))

    def test_same_epoch_decision_changes_nothing(self):
        heard = lambda t: [beacon(A, self.servers), beacon(D, [D])]
        with self.assertRaises(AssertionError):
            watching(B, 0, self.servers, heard)


class State(unittest.TestCase):
    def test_token_survives_a_restart(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "elect.json")
            self.assertEqual(load_state(path), load_state(path))

    def test_recorded_decision_skips_the_election(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "elect.json")
            first = settled(path, "10.0.0.1", lambda me: (0, [me]), lambda: False)
            self.assertEqual(
                (first["epoch"], first["role"], first["bootstrap"]), (0, "server", True)
            )

            def elect_again(me):
                raise AssertionError("re-elected despite a recorded decision")

            again = settled(path, "10.0.0.1", elect_again, lambda: True)
            self.assertEqual(
                (again["token"], again["role"], again["bootstrap"]),
                (first["token"], "server", True),
            )

    def test_bootstrap_joins_as_agent_when_the_vip_answers(self):
        with tempfile.TemporaryDirectory() as d:
            state = settled(
                os.path.join(d, "elect.json"),
                "10.0.0.1",
                lambda me: (0, [me]),
                lambda: True,
            )
            self.assertEqual((state["role"], state["bootstrap"]), ("agent", False))

    def test_later_epoch_bootstrap_ignores_the_vip(self):
        # A server left from the old epoch can answer on the VIP while the bootstrap is replaced.
        with tempfile.TemporaryDirectory() as d:
            state = settled(
                os.path.join(d, "elect.json"),
                "10.0.0.1",
                lambda me: (1, [me]),
                lambda: True,
            )
            self.assertEqual((state["role"], state["bootstrap"]), ("server", True))

    def test_settle_outlasts_expiry(self):
        # A peer that dies right after its first beacon must be dropped before anyone decides.
        self.assertGreater(SETTLE, EXPIRE + INTERVAL)


class Beacon(unittest.TestCase):
    body: ClassVar[dict] = {
        "ip": "10.0.0.1",
        "token": 9,
        "state": "decided",
        "epoch": 1,
        "servers": [A],
        "joined": True,
    }

    def test_round_trip(self):
        self.assertEqual(verify(b"k", sign(b"k", self.body)), self.body)

    def test_wrong_key_or_tampered_is_dropped(self):
        self.assertIsNone(verify(b"other", sign(b"k", self.body)))
        self.assertIsNone(
            verify(b"k", sign(b"k", self.body).replace(b'"token": 9', b'"token": 99'))
        )
        self.assertIsNone(verify(b"k", b"not json"))


if __name__ == "__main__":
    unittest.main()
