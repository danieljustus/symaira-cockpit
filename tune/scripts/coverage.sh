#!/bin/bash
# Line/region coverage for the library targets, via SwiftPM + llvm-cov.
#
# Scope note (important when reading the numbers): the `symtune` executable is
# NOT part of this report. `SymTuneCLITests` depends only on SymTuneCore +
# SymTuneMCP, so `Sources/symtune/*` is never linked into a test bundle and
# contributes to neither the numerator nor the denominator — its lines are
# absent, not counted as uncovered. Logic that should be measured therefore
# belongs in SymTuneCore/SymTuneMCP (see
# `Sources/SymTuneCore/ProcessListingPresentation.swift` for the pattern);
# the CLI target keeps argument plumbing and I/O only.
#
# Test sources are excluded too, so the percentage describes product code rather
# than being inflated by test files that are covered by construction.
#
# Usage: scripts/coverage.sh [--json <path>] [file-substring ...]
set -euo pipefail

cd "$(dirname "$0")/.."

JSON_OUT=""
if [ "${1:-}" = "--json" ]; then
  JSON_OUT="${2:?--json needs a path}"
  shift 2
fi

# The Command Line Tools toolchain cannot build this package; prefer Xcode when
# DEVELOPER_DIR is not already pointing at one.
if [ -z "${DEVELOPER_DIR:-}" ]; then
  for candidate in /Applications/Xcode.app /Applications/Xcode-beta.app; do
    if [ -d "$candidate/Contents/Developer" ]; then
      export DEVELOPER_DIR="$candidate/Contents/Developer"
      break
    fi
  done
fi

# The Keychain round-trip test blocks on an interactive authorization prompt on
# a GUI host; CI skips it for the same reason.
SKIP_ARGS=(--skip KeychainCredentialsTests)

echo "==> swift test --enable-code-coverage ${SKIP_ARGS[*]}"
swift test --enable-code-coverage "${SKIP_ARGS[@]}"

objects=()
for bundle in .build/debug/*.xctest; do
  name="$(basename "$bundle" .xctest)"
  binary="$bundle/Contents/MacOS/$name"
  [ -f "$binary" ] && objects+=(-object "$binary")
done

if [ ${#objects[@]} -eq 0 ]; then
  echo "no test bundles found in .build/debug — did the build succeed?" >&2
  exit 1
fi

PROFILE=.build/debug/codecov/default.profdata
IGNORE='(Tests|\.build|checkouts)/'

if [ -n "$JSON_OUT" ]; then
  xcrun llvm-cov export "${objects[@]}" -instr-profile "$PROFILE" \
    -ignore-filename-regex="$IGNORE" > "$JSON_OUT"
  echo "==> wrote $JSON_OUT"
fi

echo
echo "==> coverage (product code only; the symtune CLI target is not instrumented)"
if [ "$#" -gt 0 ]; then
  xcrun llvm-cov report "${objects[@]}" -instr-profile "$PROFILE" \
    -ignore-filename-regex="$IGNORE" "$@"
else
  xcrun llvm-cov report "${objects[@]}" -instr-profile "$PROFILE" \
    -ignore-filename-regex="$IGNORE"
fi
