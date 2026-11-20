#!/bin/bash
# Record the Cockpit v0.12 oracle (see oracle/README.md). Builds nothing.
#
#   SWIFT_BIN=<path to a release-built symcockpit> scripts/oracle-capture.sh
#
# Env: SWIFT_BIN (required)   binary built from the Swift sources at the commit to record
#      ORACLE_RAW_DIR         raw output root, must be outside the repo
#                             (default /Volumes/1TB_NVMe_SN850X/Dev/evidence/symaira-cockpit/cockpit2-oracle/raw)
#      ORACLE_RUN             run label under ORACLE_RAW_DIR (default: UTC timestamp)
#      ORACLE_OUT             fixture directory (default: <repo>/oracle/v0.12)
# Raw stdout/stderr/exit codes never enter the repo. Exit 0 only if every case
# returned its expected exit code and the real user data was not touched.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
: "${SWIFT_BIN:?set SWIFT_BIN to the symcockpit binary}"
[ -x "$SWIFT_BIN" ] || { echo "oracle-capture: SWIFT_BIN not executable: $SWIFT_BIN" >&2; exit 2; }
[ -x /usr/bin/sandbox-exec ] || { echo "oracle-capture: /usr/bin/sandbox-exec missing (needed to fence real user data)" >&2; exit 2; }

RAW_ROOT=${ORACLE_RAW_DIR:-/Volumes/1TB_NVMe_SN850X/Dev/evidence/symaira-cockpit/cockpit2-oracle/raw}
RUN=${ORACLE_RUN:-$(date -u +%Y%m%dT%H%M%SZ)}
OUT=${ORACLE_OUT:-$REPO/oracle/v0.12}
mkdir -p "$RAW_ROOT"
RAW=$(cd "$RAW_ROOT" && pwd -P)/$RUN
case "$RAW/" in "$REPO"/*) echo "oracle-capture: raw dir must be outside the repo" >&2; exit 2;; esac
[ ! -e "$RAW" ] || { echo "oracle-capture: $RAW exists; raw runs are never overwritten" >&2; exit 2; }
mkdir -p "$RAW" "$OUT"

# Real user data the Swift binary would use without isolation. Stat only, never read.
REAL_HOME=$(cd ~ && pwd -P)
REAL_PATHS=("$REAL_HOME/.config/symtune" "$REAL_HOME/.local/share/symtune" "$REAL_HOME/.cache/symtune" "$REAL_HOME/.symtune")
snapshot() {
  for p in "${REAL_PATHS[@]}"; do
    if [ -e "$p" ]; then find "$p" -exec stat -f '%N %m %z' {} + | sort; else echo "$p absent"; fi
  done
}
snapshot > "$RAW/real-before.txt"

# Kernel-enforced fence: any access to those paths kills the process (SIGKILL),
# which fails the case. The isolated HOME/XDG variables make that unnecessary in
# practice; the fence turns "we did not touch it" into evidence.
PROFILE=$(mktemp "${TMPDIR:-/tmp}/oracle-sandbox.XXXXXX")
trap 'rm -f "$PROFILE"' EXIT
{
  echo '(version 1)'
  echo '(allow default)'
  printf '(deny file* (with send-signal SIGKILL)'
  for p in "${REAL_PATHS[@]}"; do printf ' (subpath "%s")' "$p"; done
  echo ')'
} > "$PROFILE"
cp "$PROFILE" "$RAW/sandbox.sb"

{
  echo "date_utc $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "binary $SWIFT_BIN"
  echo "binary_sha256 $(shasum -a 256 "$SWIFT_BIN" | cut -d' ' -f1)"
  echo "git_head $(git -C "$REPO" rev-parse HEAD)"
  echo "arch $(uname -m)"
  echo "macos $(sw_vers -productVersion)"
} > "$RAW/provenance.txt"

python3 -I "$REPO/oracle/tools/capture.py" "$SWIFT_BIN" "$RAW" "$OUT" "$REPO" "$PROFILE"

snapshot > "$RAW/real-after.txt"
if ! diff -q "$RAW/real-before.txt" "$RAW/real-after.txt" >/dev/null; then
  echo "oracle-capture: real user data changed during the run (see $RAW/real-*.txt)" >&2
  diff "$RAW/real-before.txt" "$RAW/real-after.txt" >&2 || true
  exit 1
fi
echo "oracle-capture: real user data unchanged; raw output in $RAW"
