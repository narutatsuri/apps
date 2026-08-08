#!/bin/bash
# Builds Stickies.app and installs it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

EXEC="Jot"
APP="Jot"
BUNDLE="build/$APP.app"

echo "==> Compiling"
swift build -c release

echo "==> Rendering icon"
rm -rf build/AppIcon.iconset
swift Tools/MakeIcon.swift build/AppIcon.iconset >/dev/null

echo "==> Assembling bundle"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp ".build/release/$EXEC" "$BUNDLE/Contents/MacOS/$EXEC"
iconutil -c icns build/AppIcon.iconset -o "$BUNDLE/Contents/Resources/AppIcon.icns"
# KaTeX + marked, bundled so the render toggle works with no network.
cp -R Resources/web "$BUNDLE/Contents/Resources/web"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP</string>
  <key>CFBundleDisplayName</key><string>$APP</string>
  <key>CFBundleIdentifier</key><string>local.jot</string>
  <key>CFBundleExecutable</key><string>$EXEC</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <!-- Menu bar only: no Dock tile, no app-switcher entry. A scratchpad should
       already be on top rather than something you alt-tab to. -->
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Same identity the other local apps use. Ad-hoc signing produces a cdhash
# requirement that changes on every rebuild, which invalidates permissions.
IDENTITY="VoiceBridge Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" --identifier local.jot "$BUNDLE" 2>&1 | grep -v "replacing existing" || true
else
  codesign --force --sign - "$BUNDLE" >/dev/null 2>&1
fi

echo "==> Installing to /Applications"
pkill -f "/Applications/$APP.app/Contents/MacOS/$EXEC" 2>/dev/null || true
sleep 0.4
rm -rf "/Applications/$APP.app"
cp -R "$BUNDLE" "/Applications/$APP.app"

echo "==> Launching"
open -a "/Applications/$APP.app"
echo "Done. Notes live in ~/jot as plain markdown."
