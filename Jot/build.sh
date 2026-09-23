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
# Every copy, not just the installed one. This used to be anchored to
# /Applications, which left a second Jot — the staging bundle below — running
# from ~/Developer. Two processes, one bundle id, one notes folder: they wrote
# over each other's files and raced for the ⌃⌥Space hotkey, and after a rebuild
# the survivor was the *older* build.
pkill -x "$EXEC" 2>/dev/null || true
sleep 0.4
rm -rf "/Applications/$APP.app"
cp -R "$BUNDLE" "/Applications/$APP.app"

# The staging bundle is unregistered and deleted once it is installed.
#
# Leaving a second launchable .app on disk is how the duplicate Jot started:
# it gets opened once — Spotlight, or a double-click while poking around in
# the build directory — and from then on macOS relaunches it at every login
# alongside the real one, sharing its bundle id and its data directory.
# Unregistering first because LaunchServices notices a new .app the moment it
# appears, so deleting the bundle alone leaves an entry pointing at a path
# that no longer exists — inert, but still a second entry for this id.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -u "$BUNDLE" 2>/dev/null || true
rm -rf "$BUNDLE"

echo "==> Launching"
open -a "/Applications/$APP.app"
echo "Done. Notes live in ~/Library/Application Support/Jot as plain markdown."
