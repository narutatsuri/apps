#!/bin/bash
# Builds "Coding Agent Usage.app" and installs it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

EXEC="CodingAgentUsage"           # SPM product / Mach-O name
APP="Coding Agent Usage"          # user-facing bundle name
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

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP</string>
  <key>CFBundleDisplayName</key><string>$APP</string>
  <key>CFBundleIdentifier</key><string>local.codingagentusage</string>
  <key>CFBundleExecutable</key><string>$EXEC</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- Menu bar only: no Dock icon, no app switcher entry. -->
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc)"
codesign --force --sign - "$BUNDLE" >/dev/null 2>&1

echo "==> Installing to /Applications"
pkill -x "$EXEC" 2>/dev/null || true
rm -rf "/Applications/UsageBar.app"          # predecessor, if present
rm -rf "/Applications/$APP.app"
cp -R "$BUNDLE" "/Applications/$APP.app"
# Let Launch Services notice the new bundle so the icon and login item resolve.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "/Applications/$APP.app" 2>/dev/null || true

echo "==> Launching"
open "/Applications/$APP.app"
echo "Done."
