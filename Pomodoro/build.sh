#!/bin/bash
# Builds Pomodoro.app and installs it to /Applications.
# Bundle identifier is deliberately unchanged (com.pomodoro.app) so the existing
# preferences at ~/Library/Preferences/com.pomodoro.app.plist carry over.
set -euo pipefail
cd "$(dirname "$0")"

APP="Pomodoro"
BUNDLE="build/$APP.app"
ORIG="reference/Pomodoro-original.app"

echo "==> Compiling"
swift build -c release

echo "==> Assembling bundle"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp ".build/release/$APP" "$BUNDLE/Contents/MacOS/$APP"

# Reuse the original artwork so the app looks unchanged in the menu bar and Finder.
for res in AppIcon.icns MenuBarIcon.png MenuBarIcon@2x.png; do
  [ -f "$ORIG/Contents/Resources/$res" ] && cp "$ORIG/Contents/Resources/$res" "$BUNDLE/Contents/Resources/$res"
done

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP</string>
  <key>CFBundleDisplayName</key><string>$APP</string>
  <key>CFBundleIdentifier</key><string>com.pomodoro.app</string>
  <key>CFBundleExecutable</key><string>$APP</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc)"
codesign --force --sign - "$BUNDLE" >/dev/null 2>&1

echo "==> Installing to /Applications"
pkill -x "$APP" 2>/dev/null || true
sleep 1
rm -rf "/Applications/$APP.app"
cp -R "$BUNDLE" "/Applications/$APP.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "/Applications/$APP.app" 2>/dev/null || true

if [ "${NO_LAUNCH:-0}" != "1" ]; then
  echo "==> Launching"
  open "/Applications/$APP.app"
fi
echo "Done."
