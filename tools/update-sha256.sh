#!/bin/bash
# update-sha256.sh — release helper: writes the SHA256 of every downloaded file into the plg.
# The plugin manager checks it: a broken or wrong download is not installed, and a cached
# file on the flash drive with a wrong hash is downloaded again.
# Handles every line of the form  <FILE Name="..."[ SHA256="..."]><URL>&raw;/<path></URL></FILE>
# where <path> is relative to files/. Run from anywhere; exits non-zero if a file is missing.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
PLG=swap-manager.plg
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
re='^(<FILE Name="[^"]*")( SHA256="[0-9a-f]*")?(><URL>&raw;/([^<]+)</URL></FILE>)$'
n=0
while IFS= read -r line; do
  if [[ $line =~ $re ]]; then
    f=files/${BASH_REMATCH[4]}
    [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }
    sum=$(sha256sum "$f" | cut -d' ' -f1)
    line="${BASH_REMATCH[1]} SHA256=\"$sum\"${BASH_REMATCH[3]}"
    n=$((n + 1))
  fi
  printf '%s\n' "$line"
done <"$PLG" >"$tmp"
cat "$tmp" >"$PLG"
echo "$n hashes written to $PLG"
