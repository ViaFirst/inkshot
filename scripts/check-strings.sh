#!/bin/bash
# Fails if a L("…") key used in Sources is missing from any Localizable.strings.
set -euo pipefail
cd "$(dirname "$0")/.."
status=0
keys=$(grep -rhoE 'L\("([^"\\]|\\.)+"\)' Sources | sed -E 's/^L\("(.*)"\)$/\1/' | sort -u)
for f in Resources/Localization/*.lproj/Localizable.strings; do
  while IFS= read -r key; do
    if ! grep -qF "\"$key\" =" "$f"; then
      echo "missing in $f: $key"
      status=1
    fi
  done <<< "$keys"
done
exit $status
