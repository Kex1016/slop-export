#!/usr/bin/env bash
# Stamps a release version into the sources before a build (D-017).
#
#   scripts/set-version.sh 0.2.0 [build-number]
#
# Writes SlopVersion.current (the CLI, the Linux app and the .deb read it) and the macOS app's
# MARKETING_VERSION, plus CURRENT_PROJECT_VERSION when a build number is given. The Release
# workflow runs it on its own checkout; nothing is committed.
set -euo pipefail

VERSION="${1:?usage: scripts/set-version.sh X.Y.Z [build-number]}"
BUILD="${2:-}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version must look like 1.2.3, got '$VERSION'" >&2
  exit 1
fi
if [ -n "$BUILD" ] && ! [[ "$BUILD" =~ ^[0-9]+$ ]]; then
  echo "error: build number must be a whole number, got '$BUILD'" >&2
  exit 1
fi

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SWIFT="$ROOT/Sources/SlopCore/Support.swift"
YML="$ROOT/App/project.yml"

sed -i.bak -E "s/(static let current = \")[^\"]*(\")/\1$VERSION\2/" "$SWIFT"
sed -i.bak -E "s/^([[:space:]]*MARKETING_VERSION: \")[^\"]*(\")/\1$VERSION\2/" "$YML"
[ -n "$BUILD" ] && sed -i.bak -E "s/^([[:space:]]*CURRENT_PROJECT_VERSION: \")[^\"]*(\")/\1$BUILD\2/" "$YML"
rm -f "$SWIFT.bak" "$YML.bak"

# Fail loudly if a pattern stopped matching, rather than shipping the old number.
grep -q "static let current = \"$VERSION\"" "$SWIFT" || { echo "error: could not set the version in $SWIFT" >&2; exit 1; }
grep -q "MARKETING_VERSION: \"$VERSION\"" "$YML" || { echo "error: could not set MARKETING_VERSION in $YML" >&2; exit 1; }
[ -z "$BUILD" ] || grep -q "CURRENT_PROJECT_VERSION: \"$BUILD\"" "$YML" || { echo "error: could not set CURRENT_PROJECT_VERSION in $YML" >&2; exit 1; }
echo "Version set to $VERSION${BUILD:+ (build $BUILD)}"
