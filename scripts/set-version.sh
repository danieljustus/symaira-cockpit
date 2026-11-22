#!/usr/bin/env bash
set -euo pipefail

# Set the release version everywhere it is declared:
#
#   scripts/set-version.sh 0.13.0
#
# The single source is `[workspace.package] version` in Cargo.toml (it feeds
# `symcockpit version`, the agent hello, the helper and the FFI library). This
# script writes it and the places that must equal it:
#   - the `=X.Y.Z` pins between workspace crates (Cargo.toml, crates/*/Cargo.toml)
#   - the workspace crates' entries in Cargo.lock
#   - Sources/SymCockpitVersion/CockpitVersion.swift (the GUI's CockpitAppVersion)
# Info.plist files of the app and the extensions carry placeholders that
# build-app.sh and build-extensions.sh fill from CockpitVersion.swift.
# scripts/check-version.sh verifies that all of them agree (CI and release).

cd "$(dirname "$0")/.."

VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  printf 'usage: %s <x.y.z>\n' "$0" >&2
  exit 2
}

python3 -I - "$VERSION" <<'PY'
import pathlib
import re
import sys

version = sys.argv[1]
root = pathlib.Path(".")
semver = r"[0-9]+\.[0-9]+\.[0-9]+"


def rewrite(path, edit):
    text = path.read_text()
    new = edit(text)
    if new != text:
        path.write_text(new)
        print(f"updated {path}")


def workspace_version(text):
    # Only the line under [workspace.package]; `edition = ...` etc. stay untouched.
    new, n = re.subn(
        rf'(?ms)(^\[workspace\.package\]\n(?:(?!^\[).*\n)*?^version = ")({semver})(")',
        rf"\g<1>{version}\g<3>",
        text,
        count=1,
    )
    assert n == 1, "Cargo.toml: [workspace.package] version not found"
    return new


def pins(text):
    # Only pins between workspace crates; `=1.0.229`-style pins of other crates stay.
    return re.sub(
        rf'(?m)^(symcockpit[a-z-]* = \{{[^\n]*version = "=){semver}(")',
        rf"\g<1>{version}\g<2>",
        text,
    )


def lock(text):
    # Cargo.lock lists the workspace crates (no `source` line) as name + version.
    return re.sub(
        rf'(name = "symcockpit[a-z-]*"\nversion = "){semver}(")',
        rf"\g<1>{version}\g<2>",
        text,
    )


def swift(text):
    new, n = re.subn(
        rf'(public static let current = "){semver}(")', rf"\g<1>{version}\g<2>", text
    )
    assert n == 1, "CockpitVersion.swift: declaration not found"
    return new


rewrite(root / "Cargo.toml", lambda t: pins(workspace_version(t)))
for manifest in sorted(root.glob("crates/*/Cargo.toml")):
    rewrite(manifest, pins)
rewrite(root / "Cargo.lock", lock)
rewrite(root / "Sources/SymCockpitVersion/CockpitVersion.swift", swift)
PY

"$(dirname "$0")/check-version.sh" "$VERSION"
