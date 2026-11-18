#!/usr/bin/env bash
# Builds the Linux app (GTK 3) and packages it as a .deb for Ubuntu and Linux Mint (D-016).
#
#   scripts/package-deb.sh [out-dir]
#
# Run it on the oldest Ubuntu the package should install on (CI uses 22.04, so the .deb works on
# Ubuntu 22.04+ and Linux Mint 21+), with Swift 6.1, libgtk-3-dev, libsecret-1-dev and dpkg-dev.
# The Swift runtime is linked in statically, so users need no Swift installed.
# Set SCRATCH to reuse a build directory.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$(mkdir -p "${1:-dist}" && cd "${1:-dist}" && pwd)
VERSION=$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' "$ROOT/Sources/SlopCore/Support.swift")
ARCH=$(dpkg --print-architecture)
APP_ID=io.github.kex1016.SlopExport
BUILD=(swift build --package-path "$ROOT/Linux" -c release --static-swift-stdlib --product slop-export-gtk)
[ -n "${SCRATCH:-}" ] && BUILD+=(--scratch-path "$SCRATCH")

"${BUILD[@]}"
BIN="$("${BUILD[@]}" --show-bin-path)/slop-export-gtk"

STAGE=$(mktemp -d)
PKG="$STAGE/slop-export_${VERSION}_${ARCH}"
install -Dm755 "$BIN" "$PKG/usr/bin/slop-export-gtk"
strip --strip-unneeded "$PKG/usr/bin/slop-export-gtk"
install -Dm644 "$ROOT/Linux/packaging/$APP_ID.desktop" "$PKG/usr/share/applications/$APP_ID.desktop"
install -Dm644 "$ROOT/README.md" "$PKG/usr/share/doc/slop-export/README.md"

# Only system libraries remain dynamic; fail if anything else (a Swift runtime library) slipped in.
if ldd "$PKG/usr/bin/slop-export-gtk" | grep -E 'swift|Foundation|not found'; then
  echo "error: the binary still needs the Swift runtime" >&2
  exit 1
fi

mkdir -p "$PKG/DEBIAN"
cat > "$PKG/DEBIAN/control" <<CONTROL
Package: slop-export
Version: $VERSION
Section: mail
Priority: optional
Architecture: $ARCH
Depends: libc6 (>= 2.35), libgtk-3-0 (>= 3.24) | libgtk-3-0t64, libglib2.0-0 | libglib2.0-0t64, libsecret-1-0, libstdc++6, libgcc-s1
Recommends: gnome-keyring
Installed-Size: $(du -sk "$PKG/usr" | cut -f1)
Maintainer: Slop Export <https://github.com/Kex1016/slop-export>
Homepage: https://github.com/Kex1016/slop-export
Description: Copy Proton Mail into iCloud Mail
 Reads your mail through Proton Mail Bridge, keeps a full copy on disk, and
 uploads it to iCloud Mail with folders, dates, and read and flag state kept.
 Passwords are kept in your desktop keyring. Labels are not copied.
CONTROL

dpkg-deb --root-owner-group --build "$PKG" "$OUT/slop-export_${VERSION}_${ARCH}.deb"
(cd "$OUT" && sha256sum "slop-export_${VERSION}_${ARCH}.deb" > "slop-export_${VERSION}_${ARCH}.deb.sha256")
rm -rf "$STAGE"
echo "Wrote $OUT/slop-export_${VERSION}_${ARCH}.deb"
