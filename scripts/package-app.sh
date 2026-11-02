#!/bin/bash
# Usage: scripts/package-app.sh path/to/SlopExport.app outdir
# Ad-hoc signs the app (no Apple Developer account needed, D-002) and writes
# SlopExport.zip and SlopExport.dmg into outdir.
set -euo pipefail
APP="$1"
OUT="$2"
mkdir -p "$OUT"
codesign --force --deep --options runtime --sign - \
  --entitlements App/SlopExport/SlopExport.entitlements "$APP"
codesign --verify --strict --verbose=2 "$APP"
ditto -c -k --keepParent "$APP" "$OUT/SlopExport.zip"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Slop Export" -srcfolder "$STAGE" -ov -format UDZO "$OUT/SlopExport.dmg"
rm -rf "$STAGE"
shasum -a 256 "$OUT"/* | tee "$OUT/SHA256SUMS.txt"
