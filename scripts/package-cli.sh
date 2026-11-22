#!/usr/bin/env bash
set -euo pipefail

# Pack the Rust `symcockpit` release binary into the CLI tarball the Homebrew formula installs:
#
#   scripts/package-cli.sh <version> <path to symcockpit> <output dir>
#
# Writes <output dir>/symcockpit_<version>_darwin_arm64.tar.gz and <output dir>/checksums.txt.
# The binary comes from `cargo build --release --locked -p symcockpit --target aarch64-apple-darwin`
# (Intel is not supported, architecture D16). It is stripped, given the ad-hoc signature an arm64
# Mach-O needs to run at all (a tarball is not notarized; Homebrew does not quarantine it), and must
# report <version> before it is packed. Prints the archive path on the last line.

cd "$(dirname "$0")/.."

VERSION="${1:?usage: package-cli.sh <version> <binary> <output dir>}"
BINARY="${2:?usage: package-cli.sh <version> <binary> <output dir>}"
OUT="${3:?usage: package-cli.sh <version> <binary> <output dir>}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'not a version: %s\n' "$VERSION" >&2; exit 2; }
[[ -x "$BINARY" ]] || { printf 'not an executable: %s\n' "$BINARY" >&2; exit 1; }

ARCHIVE_NAME="symcockpit_${VERSION}_darwin_arm64.tar.gz"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

cp "$BINARY" "$STAGE/symcockpit"
strip "$STAGE/symcockpit"
codesign --force --sign - "$STAGE/symcockpit"
codesign --verify --strict "$STAGE/symcockpit"
[[ "$(lipo -archs "$STAGE/symcockpit")" == "arm64" ]] || {
  printf 'The CLI must be arm64 only: %s\n' "$(lipo -archs "$STAGE/symcockpit")" >&2
  exit 1
}
./scripts/check-version.sh "$VERSION" "$STAGE/symcockpit"
cp LICENSE README.md "$STAGE/"

rm -f "$OUT/$ARCHIVE_NAME" "$OUT/checksums.txt"
COPYFILE_DISABLE=1 tar -czf "$OUT/$ARCHIVE_NAME" -C "$STAGE" .
(cd "$OUT" && shasum -a 256 "$ARCHIVE_NAME" > checksums.txt)

# Look inside what will ship: exactly the binary, the licence and the README.
LISTING="$(tar -tzf "$OUT/$ARCHIVE_NAME" | sed 's|^\./||' | grep -v '^$' | sort | tr '\n' ' ')"
[[ "$LISTING" == "LICENSE README.md symcockpit " ]] || {
  printf 'Unexpected archive content: %s\n' "$LISTING" >&2
  exit 1
}
printf '%s\n' "$OUT/$ARCHIVE_NAME"
