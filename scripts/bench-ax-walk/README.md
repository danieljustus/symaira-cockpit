# AX walk benchmark

Measures how long `AccessibilityService` takes to read one application's
Accessibility tree — the walk behind `symcockpit operate serve`'s `query_ui`,
`find_ui` and `wait_for` tools.

It is a manual benchmark, not a CI gate: it needs a running GUI application and
an Accessibility grant for the process doing the measuring, and its wall-clock
numbers depend on the machine and on the target app. Nothing here is built by
`make build` or by the CI matrices.

## Why a fixture app

Real applications are moving targets. Their trees grow and shrink while the
benchmark runs, so two builds end up walking two different workloads and the
comparison means nothing. `Fixture.swift` puts up one window with a fixed,
statically-built hierarchy of a few hundred controls. Its window floats on
every space, because Stage Manager pulls a backgrounded app's windows out of
the space and an absent window has no tree to walk.

## Running it

```bash
# 1. The deterministic target.
xcrun swiftc -O scripts/bench-ax-walk/Fixture.swift -o /tmp/ax-bench-fixture
/tmp/ax-bench-fixture &          # prints its pid
PID=$!

# 2. One probe per build under test. Point the probe package at the checkout
#    you want to measure — e.g. build it once here, then again from a worktree
#    of the base commit, keeping each binary.
(cd scripts/bench-ax-walk/Probe && swift build -c release)
cp scripts/bench-ax-walk/Probe/.build/release/probe /tmp/probe-candidate

# 3. Confirm both builds still produce the same tree before comparing speed.
/tmp/probe-baseline  "$PID" 12 1000 1 dump > /tmp/tree-baseline.json
/tmp/probe-candidate "$PID" 12 1000 1 dump > /tmp/tree-candidate.json
diff /tmp/tree-baseline.json /tmp/tree-candidate.json

# 4. Alternating A/B run, then the summary.
scripts/bench-ax-walk/run.sh /tmp/probe-baseline /tmp/probe-candidate "$PID" 4 200 15 /tmp/d4.tsv
python3 scripts/bench-ax-walk/stats.py /tmp/d4.tsv
```

`4 200` is what `query_ui` defaults to. `12 1000` walks the whole window.

## Reading the output

Compare medians, and only when both variants report the same `nodes=` count.
A run whose node counts differ between variants walked different trees and has
to be discarded, not interpreted.
