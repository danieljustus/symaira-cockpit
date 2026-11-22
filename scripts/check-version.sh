#!/usr/bin/env bash
set -euo pipefail

# Check that every declared version agrees with Cargo.toml's
# `[workspace.package] version` (the single source, see set-version.sh):
#
#   scripts/check-version.sh                 # the declarations agree with each other
#   scripts/check-version.sh 0.13.0          # ... and equal this version (a tag without its "v")
#   scripts/check-version.sh 0.13.0 <bin>    # ... and the built `symcockpit` binary reports it
#   scripts/check-version.sh --app <App.app> # ... and an assembled app bundle reports it
#
# Exit 0 only when all of them equal. Nothing is built or run except the
# binaries named on the command line.

cd "$(dirname "$0")/.."

EXPECT=""
BINARY=""
APP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="${2:?--app needs a path}"; shift 2 ;;
    *)
      if [[ -z "$EXPECT" ]]; then EXPECT="$1"; elif [[ -z "$BINARY" ]]; then BINARY="$1"; else
        printf 'unexpected argument: %s\n' "$1" >&2; exit 2
      fi
      shift ;;
  esac
done

python3 -I - "$EXPECT" <<'PY'
import pathlib
import re
import sys

expect = sys.argv[1]
root = pathlib.Path(".")
semver = r"[0-9]+\.[0-9]+\.[0-9]+"
found = {}  # place -> version


def one(pattern, text, place, flags=0):
    m = re.search(pattern, text, flags)
    if not m:
        sys.exit(f"check-version: {place}: no version found")
    found[place] = m.group(1)


cargo = (root / "Cargo.toml").read_text()
one(rf'(?ms)^\[workspace\.package\]\n(?:(?!^\[).*\n)*?^version = "({semver})"', cargo, "Cargo.toml [workspace.package]")
source = found["Cargo.toml [workspace.package]"]

for path in [root / "Cargo.toml", *sorted(root.glob("crates/*/Cargo.toml"))]:
    for i, pin in enumerate(re.findall(rf'(?m)^symcockpit[a-z-]* = \{{[^\n]*version = "=({semver})"', path.read_text())):
        found[f"{path} pin #{i}"] = pin
for path in sorted(root.glob("crates/*/Cargo.toml")):
    text = path.read_text()
    # A crate with its own literal version would leave the workspace unified version.
    if re.search(r'(?m)^version\s*=\s*"', text.split("[dependencies]")[0]):
        found[f"{path} own version"] = "literal"

lock = (root / "Cargo.lock").read_text()
for name, version in re.findall(rf'name = "(symcockpit[a-z-]*)"\nversion = "({semver})"\n(?!source)', lock):
    found[f"Cargo.lock {name}"] = version

swift = root / "Sources/SymCockpitVersion/CockpitVersion.swift"
if swift.exists():  # absent once the Swift version library is retired
    one(rf'public static let current = "({semver})"', swift.read_text(), str(swift))

bad = {k: v for k, v in found.items() if v != source}
if expect and source != expect:
    bad["expected (tag/argument)"] = expect
if bad:
    print(f"check-version: Cargo.toml says {source}, but:", file=sys.stderr)
    for place, version in bad.items():
        print(f"  {place}: {version}", file=sys.stderr)
    sys.exit(1)
print(f"check-version: {len(found)} declarations agree on {source}")
PY

SOURCE="$(sed -n '/^\[workspace\.package\]/,/^\[/{s/^version = "\(.*\)"/\1/p;}' Cargo.toml | head -1)"

if [[ -n "$BINARY" ]]; then
  OUT="$("$BINARY" version --json --no-update-check)"
  REPORTED="$(python3 -I -c 'import json,sys; print(json.load(sys.stdin)["version"])' <<<"$OUT")"
  [[ "$REPORTED" == "$SOURCE" ]] || {
    printf 'check-version: %s reports %s, Cargo.toml says %s\n' "$BINARY" "$REPORTED" "$SOURCE" >&2
    exit 1
  }
  printf 'check-version: %s reports %s\n' "$BINARY" "$REPORTED"
fi

if [[ -n "$APP" ]]; then
  PLIST="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
  [[ "$PLIST" == "$SOURCE" ]] || {
    printf 'check-version: %s Info.plist says %s, Cargo.toml says %s\n' "$APP" "$PLIST" "$SOURCE" >&2
    exit 1
  }
  for appex in "$APP"/Contents/PlugIns/*.appex; do
    [[ -d "$appex" ]] || continue
    EXT="$(plutil -extract CFBundleShortVersionString raw -o - "$appex/Contents/Info.plist")"
    [[ "$EXT" == "$SOURCE" ]] || {
      printf 'check-version: %s says %s, Cargo.toml says %s\n' "$appex" "$EXT" "$SOURCE" >&2
      exit 1
    }
  done
  APP_OUT="$("$APP/Contents/MacOS/SymCockpitApp" --version)"
  [[ "$APP_OUT" == "Symaira Cockpit $SOURCE" ]] || {
    printf 'check-version: SymCockpitApp --version says "%s", Cargo.toml says %s\n' "$APP_OUT" "$SOURCE" >&2
    exit 1
  }
  "$0" "$SOURCE" "$APP/Contents/MacOS/symcockpit" >/dev/null
  printf 'check-version: %s (Info.plist, extensions, app executable, bundled symcockpit) is %s\n' "$APP" "$SOURCE"
fi
