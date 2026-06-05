#!/usr/bin/env bash
# OS Disk Manager — DMG installer build (Phase 4.1).
#
# Produces a signed, notarisable DMG that users mount, drag the .app
# into Applications, and unmount. No external dependencies — uses
# `hdiutil` from base macOS, which is the same tool Apple uses for its
# own release DMGs.
#
# Prerequisites:
#   * bundle.sh has run and produced ./DiskWipe.app
#   * Scripts/notarize/sign.sh has run (Developer-ID OR ad-hoc)
#   * (optional) TEAM_ID + DEVELOPER_ID_APPLICATION set for codesigning
#     the DMG itself; without them the DMG is unsigned (still usable for
#     local distribution, GateKeeper will refuse downloads though).
#
# Outputs:
#   ./dist/DiskWipe-<version>-arm64.dmg

set -euo pipefail

cd "$(dirname "$0")/../.."

APP_PATH="${APP_PATH:-$(pwd)/DiskWipe.app}"
DIST_DIR="${DIST_DIR:-$(pwd)/dist}"

if [ ! -d "$APP_PATH" ]; then
    echo "==> ERROR: $APP_PATH does not exist. Run bundle.sh and sign.sh first."
    exit 1
fi

# Pull version from Info.plist so the DMG name always tracks the release.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
            "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "0.0")"
DMG_NAME="DiskWipe-${VERSION}-arm64.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"

mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH"

# Staging dir = what the user sees mounted. Includes the .app + a symlink
# to /Applications so the drag-target is one click away. Background image
# + .DS_Store layout omitted in v1 to keep things shippable; can be added
# in P4.1b once we have a design asset.
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

echo "==> Staging $APP_PATH → $STAGING"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# Compute UDZO (compressed) DMG.
echo "==> Building DMG: $DMG_NAME"
hdiutil create \
    -volname "OS Disk Manager $VERSION" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    "$DMG_PATH"

# Sign the DMG itself when Developer ID is available. notarytool wants
# the DMG signed by the same Team ID as the .app inside.
if [ -n "${TEAM_ID:-}" ] && [ -n "${DEVELOPER_ID_APPLICATION:-}" ]; then
    echo "==> Codesigning DMG with $DEVELOPER_ID_APPLICATION"
    codesign --force --timestamp \
        --sign "$DEVELOPER_ID_APPLICATION" "$DMG_PATH"
    codesign -dv --verbose=2 "$DMG_PATH" 2>&1 | head -10
else
    echo "==> NOTE: DMG not codesigned (no TEAM_ID). Local-distribution only."
fi

ls -lh "$DMG_PATH"
echo
echo "==> Done: $DMG_PATH"
echo "    Next: ./Scripts/notarize/notarize.sh with APP_PATH=$DMG_PATH"
echo "          (notarytool accepts both .app and .dmg; staple after success)"
