#!/usr/bin/env bash
set -euo pipefail

# Submit a file to Apple's notary service and fail unless it is Accepted:
#
#   NOTARY_API_KEY=<base64 .p8> NOTARY_API_KEY_ID=… NOTARY_API_ISSUER_ID=… \
#     scripts/notarize.sh <zip | dmg | pkg>
#
# Fail-closed: a missing credential, a non-zero notarytool exit, a status other than "Accepted" or
# an unreadable answer all exit 1; on a rejection the notary log is printed. Staple and validate in
# the caller. The key is written to a private temporary file and removed on exit. Nothing is
# printed from the secrets. Run only in the release workflow.

SUBMISSION="${1:?usage: notarize.sh <file>}"
[[ -f "$SUBMISSION" ]] || { printf 'not a file: %s\n' "$SUBMISSION" >&2; exit 1; }
for secret in NOTARY_API_KEY NOTARY_API_KEY_ID NOTARY_API_ISSUER_ID; do
  [[ -n "${!secret:-}" ]] || { printf '%s must be set (release environment).\n' "$secret" >&2; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
umask 077
printf '%s' "$NOTARY_API_KEY" | base64 --decode > "$WORK/AuthKey.p8"
grep -q -- '-----BEGIN' "$WORK/AuthKey.p8" || { printf 'NOTARY_API_KEY is not a base64 .p8 key.\n' >&2; exit 1; }

xcrun notarytool submit "$SUBMISSION" \
  -k "$WORK/AuthKey.p8" -d "$NOTARY_API_KEY_ID" -i "$NOTARY_API_ISSUER_ID" \
  --wait --output-format json > "$WORK/result.json" || {
  cat "$WORK/result.json" >&2 || true
  printf 'notarytool failed for %s\n' "$SUBMISSION" >&2
  exit 1
}
STATUS="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$WORK/result.json")"
if [[ "$STATUS" != "Accepted" ]]; then
  ID="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$WORK/result.json")"
  printf 'Notarization of %s: %s\n' "$SUBMISSION" "$STATUS" >&2
  [[ -z "$ID" ]] || xcrun notarytool log "$ID" -k "$WORK/AuthKey.p8" -d "$NOTARY_API_KEY_ID" -i "$NOTARY_API_ISSUER_ID" >&2 || true
  exit 1
fi
printf 'Notarization of %s: Accepted\n' "$SUBMISSION"
