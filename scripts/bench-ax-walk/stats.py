#!/usr/bin/env python3
"""Summarise samples produced by scripts/bench-ax-walk/run.sh.

    python3 scripts/bench-ax-walk/stats.py ax-walk-samples.tsv

Reports sample count, median, mean, standard deviation and range per variant,
plus the median difference. The node count is printed with each workload: a
comparison is only meaningful when both variants walked the same tree.
"""
import statistics as st
import sys
from collections import defaultdict

samples = defaultdict(list)
nodes = defaultdict(set)

for path in sys.argv[1:]:
    with open(path) as handle:
        for line in handle:
            fields = line.rstrip("\n").split("\t")
            if len(fields) != 7:
                continue
            kind, variant, _pid, depth, cap, count, value = fields
            samples[(kind, depth, cap, variant)].append(float(value))
            nodes[(kind, depth, cap)].add(count)

for workload in sorted({key[:3] for key in samples}):
    base = samples[(*workload, "baseline")]
    cand = samples[(*workload, "candidate")]
    if not base or not cand:
        continue

    def describe(values):
        return (
            len(values),
            st.median(values),
            st.mean(values),
            st.stdev(values) if len(values) > 1 else 0.0,
            min(values),
            max(values),
        )

    nb, mb, ab, sb, lob, hib = describe(base)
    nc, mc, ac, sc, loc, hic = describe(cand)
    kind, depth, cap = workload
    print(f"{kind:7s} depth={depth:>3s} cap={cap:>4s} nodes={'/'.join(sorted(nodes[workload]))}")
    print(f"  baseline  n={nb:3d} median={mb:8.2f} ms  mean={ab:8.2f}  sd={sb:6.2f}  min={lob:8.2f}  max={hib:8.2f}")
    print(f"  candidate n={nc:3d} median={mc:8.2f} ms  mean={ac:8.2f}  sd={sc:6.2f}  min={loc:8.2f}  max={hic:8.2f}")
    print(f"  median: {mb - mc:.2f} ms faster ({(mb - mc) / mb * 100:.1f}% lower, x{mb / mc:.2f})")
    print()
