#!/bin/bash
# Line/region coverage for the library targets, via SwiftPM + llvm-cov.
#
# Scope note: SymTuneCLITests depends on the SymTuneCLI library, so the test
# bundles measure SymTuneCLI alongside SymTuneCore and SymTuneMCP. The thin
# Sources/symtune/* compatibility entry point and SymTuneApp/SymTuneUI are not
# linked into these package-local bundles. Absent files are not measured,
# uncovered lines. Root integration and release-baseline reports include a
# wider production-code scope; compare percentages only at equal scope.
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
echo "==> coverage (test-linked product code, including SymTuneCLI; no executable/UI entry points)"
if [ "$#" -gt 0 ]; then
  xcrun llvm-cov report "${objects[@]}" -instr-profile "$PROFILE" \
    -ignore-filename-regex="$IGNORE" "$@"
else
  xcrun llvm-cov report "${objects[@]}" -instr-profile "$PROFILE" \
    -ignore-filename-regex="$IGNORE"
fi
