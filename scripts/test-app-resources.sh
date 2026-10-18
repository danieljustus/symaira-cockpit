#!/usr/bin/env bash
set -euo pipefail

# Negative packaging regression, using only a disposable copy of the given app.
APP_PATH="${1:?Usage: test-app-resources.sh /path/to/Symaira Cockpit.app}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/smoke-app.sh" "$APP_PATH"
TEST_DIR="$(mktemp -d "${TMPDIR:?TMPDIR must name a scratch directory}/cockpit-resources.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
COPY="$TEST_DIR/Cockpit.app"
cp -R "$APP_PATH" "$COPY"
FONT="$COPY/Contents/Resources/symaira-appkit_SymairaTheme.bundle/Contents/Resources/GoogleSansFlex.ttf"
mv "$FONT" "$TEST_DIR/font.ttf"
if "$SCRIPT_DIR/smoke-app.sh" "$COPY" > "$TEST_DIR/missing.log" 2>&1; then
  printf 'Smoke check incorrectly accepted an app without its font.\n' >&2
  exit 1
fi
grep -Fq 'Missing required AppKit resource: GoogleSansFlex.ttf' "$TEST_DIR/missing.log"
mv "$TEST_DIR/font.ttf" "$FONT"
"$SCRIPT_DIR/smoke-app.sh" "$COPY"
printf 'Resource packaging regression passed (missing font rejected, restored app accepted).\n'
