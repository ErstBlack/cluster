#!/usr/bin/python3
"""The storage spike (#91), never merged. Prints one markdown table of the median, with its min-max range, of every
measurement over the storage-results.json files spike/storage.sh wrote, one column per candidate, then each run's
iperf3 baseline.

    aggregate.py <storage-results.json>...
"""

import json
import pathlib
import statistics
import sys

METRICS = [
    ("install_write_s", "Install start to the first fsync'd write, 3-replica PVC (s)"),
    ("install_healthy_s", "Install start to 3 healthy replicas (s)"),
    ("drbd_build_s", "DRBD module build and load, untimed prep (s)"),
    ("iperf_mibs", "iperf3 from slot 1's node, median over the other nodes (MiB/s)"),
    ("ingest_r1_mibs", "Ingest into a 1-replica volume (MiB/s)"),
    ("ingest_r3_mibs", "Ingest into a 3-replica volume (MiB/s)"),
    ("rwx_s", "RWX filesystem read on two nodes, after the PVC (s)"),
    ("rwx_shared_level_s", "RWX filesystem, pods at one shared SELinux level (s)"),
    ("migrate_s", "KubeVirt live migration on an RWX block volume (s)"),
    ("kill_notready_s", "Node kill: kill to NotReady (s)"),
    ("kill_back_s", "Node kill: kill to the killed node's pod writing elsewhere (s)"),
    ("notready_back_s", "Node kill: NotReady to the pod writing elsewhere (s)"),
    ("survivor_gap_s", "Node kill: longest gap in slot 1's writes, t-5 to t+180 (s)"),
    ("pod_idle_cpu_m", "Storage pods idle, CPU per node (m)"),
    ("pod_idle_mib", "Storage pods idle, RAM per node (MiB)"),
    ("pod_idle_mib_max", "Storage pods idle, RAM on the busiest node (MiB)"),
    ("pod_ingest_cpu_m", "Storage pods during 3-replica ingest, CPU per node (m)"),
    ("pod_ingest_mib", "Storage pods during 3-replica ingest, RAM per node (MiB)"),
    ("pod_end_mib", "Storage pods after the node kill, RAM per node (MiB)"),
    (
        "pod_end_mib_max",
        "Storage pods after the node kill, RAM on the busiest node (MiB)",
    ),
    ("node_idle_cpu_m", "Whole node idle, CPU per node (m)"),
    ("node_idle_mib", "Whole node idle, RAM per node (MiB)"),
    ("node_ingest_cpu_m", "Whole node during 3-replica ingest, CPU per node (m)"),
    ("node_ingest_mib", "Whole node during 3-replica ingest, RAM per node (MiB)"),
    ("node_end_mib", "Whole node after the node kill, RAM per node (MiB)"),
    ("avc_denials", "SELinux denials since prep, all nodes"),
]

# A metric counts only from runs that report this status, since earlier runs measured it wrongly: the SELinux count
# read nothing before ausearch got --input-logs (full run 36937924151).
NEEDS = {"avc_denials": "avc"}

STATUSES = [
    ("avc", "SELinux audit log read on every node"),
    ("rwx", "RWX filesystem on two nodes"),
    ("migrate", "KubeVirt live migration"),
    ("kill", "Node kill: the pod writes again elsewhere within 10 min"),
]


def number(v):
    return f"{v:.1f}" if v != int(v) and abs(v) < 100 else f"{v:.0f}"


def cell(values, runs):
    if not values:
        return "-"
    text = number(statistics.median(values))
    if len(values) > 1:
        text += f" ({number(min(values))}-{number(max(values))})"
    if len(values) < runs:
        text += f", {len(values)} of {runs} runs"
    return text


def main():
    results = [json.loads(pathlib.Path(path).read_text()) for path in sys.argv[1:]]
    candidates = sorted({r["candidate"] for r in results})
    by = {c: [r for r in results if r["candidate"] == c] for c in candidates}
    heads = [
        f"{c}, {len(by[c])} runs at {'/'.join(sorted({str(r['nodes']) for r in by[c]}))} nodes"
        for c in candidates
    ]
    print("## Storage spike, median (min-max) over runs")
    print()
    print("| Measurement | " + " | ".join(heads) + " |")
    print("|---|" + "---|" * len(candidates))
    for key, label in METRICS:
        cells = [
            cell(
                [
                    r["metrics"][key]
                    for r in by[c]
                    if key in r["metrics"] and NEEDS.get(key, "") in ("", *r["status"])
                ],
                len(by[c]),
            )
            for c in candidates
        ]
        if any(x != "-" for x in cells):
            print(f"| {label} | " + " | ".join(cells) + " |")
    for key, label in STATUSES:
        cells = []
        for c in candidates:
            seen = [r["status"].get(key, "not run") for r in by[c]]
            counts = {s: seen.count(s) for s in sorted(set(seen))}
            cells.append(", ".join(f"{s} {n}/{len(seen)}" for s, n in counts.items()))
        print(f"| {label} | " + " | ".join(cells) + " |")
    print()
    print(
        "| Run | Candidate | Nodes | iperf3 median (MiB/s) | 3 healthy replicas (s) | Ingest 3 replicas (MiB/s) |"
    )
    print("|---|---|---|---|---|---|")
    for r in sorted(results, key=lambda r: (r["run"], r["candidate"])):
        m = r["metrics"]
        values = [
            m.get(k) for k in ("iperf_mibs", "install_healthy_s", "ingest_r3_mibs")
        ]
        shown = " | ".join("-" if v is None else number(v) for v in values)
        print(f"| {r['run']} | {r['candidate']} | {r['nodes']} | {shown} |")


if __name__ == "__main__":
    main()
