#!/usr/bin/env bash
set -euo pipefail

# Render a Homebrew file from packaging/homebrew/ to stdout:
#
#   scripts/render-homebrew.sh formula <version> <sha256 of the CLI tarball>
#   scripts/render-homebrew.sh cask    <version> <sha256 of the DMG>
#
# The templates are plain Ruby with @VERSION@ and @SHA256@ in place of the two values, so nothing
# is expanded by a shell heredoc (that mangled `#{version}` interpolation before). The result is
# checked with `ruby -c` when ruby is installed.

cd "$(dirname "$0")/.."

KIND="${1:?usage: render-homebrew.sh formula|cask <version> <sha256>}"
VERSION="${2:?usage: render-homebrew.sh formula|cask <version> <sha256>}"
SHA256="${3:?usage: render-homebrew.sh formula|cask <version> <sha256>}"
case "$KIND" in
  formula) TEMPLATE="packaging/homebrew/symcockpit.rb.in" ;;
  cask) TEMPLATE="packaging/homebrew/symcockpit-cask.rb.in" ;;
  *) printf 'unknown kind: %s\n' "$KIND" >&2; exit 2 ;;
esac
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'not a version: %s\n' "$VERSION" >&2; exit 2; }
[[ "$SHA256" =~ ^[0-9a-f]{64}$ ]] || { printf 'not a SHA-256: %s\n' "$SHA256" >&2; exit 2; }

OUT="$(sed -e "s|@VERSION@|$VERSION|g" -e "s|@SHA256@|$SHA256|g" "$TEMPLATE")"
if grep -q '@[A-Z0-9_]*@' <<<"$OUT"; then
  printf 'unreplaced placeholder in %s\n' "$TEMPLATE" >&2
  exit 1
fi
if command -v ruby >/dev/null 2>&1; then
  ruby -c <<<"$OUT" >/dev/null
fi
printf '%s\n' "$OUT"
