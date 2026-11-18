#!/usr/bin/env bash
# Stamps a release version into the sources before a build (D-017).
#
#   scripts/set-version.sh 0.2.0           # stamp it
#   scripts/set-version.sh --check 0.2.0   # only check the format
#
# Writes SlopVersion.current (the CLI, the Linux app and the .deb read it) and the macOS app's
# MARKETING_VERSION and CURRENT_PROJECT_VERSION (both the version itself, so later releases
# always have a higher build number). The Release workflow runs it on its own checkout; nothing
# is committed.
set -euo pipefail

CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then CHECK_ONLY=1; shift; fi
VERSION="${1:?usage: scripts/set-version.sh [--check] X.Y.Z}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version must look like 1.2.3, got '$VERSION'" >&2
  exit 1
fi
[ "$CHECK_ONLY" = 1 ] && exit 0

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SWIFT="$ROOT/Sources/SlopCore/Support.swift"
YML="$ROOT/App/project.yml"

sed -i.bak -E "s/(static let current = \")[^\"]*(\")/\1$VERSION\2/" "$SWIFT"
sed -i.bak -E "s/^([[:space:]]*(MARKETING_VERSION|CURRENT_PROJECT_VERSION): \")[^\"]*(\")/\1$VERSION\3/" "$YML"
rm -f "$SWIFT.bak" "$YML.bak"

# Fail loudly if a pattern stopped matching, rather than shipping the old number.
grep -q "static let current = \"$VERSION\"" "$SWIFT" || { echo "error: could not set the version in $SWIFT" >&2; exit 1; }
grep -q "MARKETING_VERSION: \"$VERSION\"" "$YML" || { echo "error: could not set MARKETING_VERSION in $YML" >&2; exit 1; }
grep -q "CURRENT_PROJECT_VERSION: \"$VERSION\"" "$YML" || { echo "error: could not set CURRENT_PROJECT_VERSION in $YML" >&2; exit 1; }
echo "Version set to $VERSION"
