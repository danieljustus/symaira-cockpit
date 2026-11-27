#!/usr/bin/env bash
# Fails when the symaira-corekit pins disagree, which is what Dependabot leaves
# behind: it never edits tuning/project.yml, moves tuning/Package.swift without
# the root Package.swift that depends on it (#435), moves a Cargo
# `[workspace.dependencies]` tag only in Cargo.lock, and never moves a `rev` or
# `branch` pin.
#
# CoreKit owns the check: this runs its corekit_pins.py at the commit that
# .github/workflows/corekit-dependabot.yml pins, so the Dependabot bump of that
# action moves this check too. Pass --fix to repair drift locally.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

sha="$(sed -nE 's#.*symaira-corekit/\.github/actions/dependabot-corekit@([0-9a-f]{40}).*#\1#p' .github/workflows/corekit-dependabot.yml | head -1)"
if [ -z "$sha" ]; then
	echo "::error file=.github/workflows/corekit-dependabot.yml::no full-SHA pin of the dependabot-corekit action found" >&2
	exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL --retry 3 -o "$tmp/corekit_pins.py" \
	"https://raw.githubusercontent.com/danieljustus/symaira-corekit/$sha/.github/actions/dependabot-corekit/corekit_pins.py"
python3 -I "$tmp/corekit_pins.py" "$@"
