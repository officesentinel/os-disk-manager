#!/bin/bash
# Build release binaries and assemble DiskWipe.app (no Xcode required).
#
# Scope: Apple Silicon (M1 / M2 / M3 / M4 / M5) only. Intel Mac is not a target.
# The build refuses to proceed on x86_64 to make this contract explicit.
set -euo pipefail
cd "$(dirname "$0")"

if [ "$(uname -m)" != "arm64" ]; then
  echo "==> ERROR: OS Disk Manager targets Apple Silicon only (M1-M5)."
  echo "    This host reports uname -m = $(uname -m). Aborting."
  exit 1
fi

APP="DiskWipe.app"
ID="org.officesentinel.diskwipe"

echo "==> swift build -c release"
swift build -c release

BIN=".build/release/DiskWipeApp"
ENGINE=".build/release/diskwipe-engine"

echo "==> icon"
if [ ! -f AppIcon.icns ] || [ make-icon.swift -nt AppIcon.icns ]; then
    swift make-icon.swift AppIcon.iconset
    iconutil -c icns AppIcon.iconset -o AppIcon.icns
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DiskWipe"
# Bundle the engine inside too (for reference / portability).
cp "$ENGINE" "$APP/Contents/MacOS/diskwipe-engine"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>OS Disk Manager</string>
  <key>CFBundleDisplayName</key><string>OS Disk Manager</string>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleExecutable</key><string>DiskWipe</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> ad-hoc codesign"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "   (codesign skipped)"

echo "==> install engine to /usr/local/bin + app to /Applications (needs admin)"
osascript -e "do shell script \"mkdir -p /usr/local/bin && cp '$PWD/$ENGINE' /usr/local/bin/diskwipe-engine && chmod 755 /usr/local/bin/diskwipe-engine && codesign --force --sign - /usr/local/bin/diskwipe-engine && rm -rf '/Applications/$APP' && cp -R '$PWD/$APP' /Applications/ && codesign --force --deep --sign - '/Applications/$APP' && touch '/Applications/$APP'\" with administrator privileges"

# Refresh icon caches so Finder/Dock show the new icon immediately.
/usr/bin/touch "/Applications/$APP" 2>/dev/null || true
killall Finder Dock 2>/dev/null || true

echo "==> done: /Applications/$APP"
