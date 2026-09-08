#!/bin/bash
# Alternating A/B benchmark for the Accessibility tree walk.
#
#   scripts/bench-ax-walk/run.sh <baseline-probe> <candidate-probe> <pid> [depth] [nodes] [rounds] [out.tsv]
#
# Both probes run against the same target window on the same machine, and the
# order flips every round so slow drift (thermals, background load) cannot land
# on one build only. Each probe invocation warms up before it measures.
set -euo pipefail

if [ $# -lt 3 ]; then
    echo "usage: $0 <baseline-probe> <candidate-probe> <pid> [depth] [nodes] [rounds] [out.tsv]" >&2
    exit 2
fi

BASELINE="$1"
CANDIDATE="$2"
PID="$3"
DEPTH="${4:-4}"
NODES="${5:-200}"
ROUNDS="${6:-15}"
OUT="${7:-ax-walk-samples.tsv}"

: > "$OUT"
for round in $(seq 1 "$ROUNDS"); do
    if [ $((round % 2)) -eq 1 ]; then
        order=("$BASELINE:baseline" "$CANDIDATE:candidate")
    else
        order=("$CANDIDATE:candidate" "$BASELINE:baseline")
    fi
    for entry in "${order[@]}"; do
        "${entry%%:*}" "$PID" "$DEPTH" "$NODES" 3 "${entry##*:}" >> "$OUT"
    done
done
echo "wrote $(wc -l < "$OUT") samples to $OUT"
