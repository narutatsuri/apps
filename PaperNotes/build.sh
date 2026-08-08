#!/bin/bash
# Builds Paper Notes.app and installs it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

EXEC="PaperNotes"
APP="Paper Notes"
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
# KaTeX + marked, bundled so the preview renders with no network.
cp -R Resources/web "$BUNDLE/Contents/Resources/web"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP</string>
  <key>CFBundleDisplayName</key><string>$APP</string>
  <key>CFBundleIdentifier</key><string>local.papernotes</string>
  <key>CFBundleExecutable</key><string>$EXEC</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>

  <!-- Finder right-click → Services → "Add to Paper Notes" -->
  <key>NSServices</key>
  <array>
    <dict>
      <key>NSMenuItem</key>
      <dict><key>default</key><string>Add to Paper Notes</string></dict>
      <key>NSMessage</key><string>addToPaperNotes</string>
      <key>NSPortName</key><string>$EXEC</string>
      <key>NSSendFileTypes</key>
      <array><string>com.adobe.pdf</string></array>
    </dict>
  </array>

  <!-- Finder right-click → Open With → Paper Notes.
       Rank Alternate on purpose: Preview stays the default PDF handler, because
       reading happens there. -->
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>PDF</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array><string>com.adobe.pdf</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

echo "==> Signing"
# Reuse the stable identity if it exists, so any future TCC grants survive rebuilds.
IDENTITY="VoiceBridge Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" --identifier local.papernotes "$BUNDLE" 2>&1 | grep -v "replacing existing" || true
else
  codesign --force --sign - "$BUNDLE" >/dev/null 2>&1
fi

echo "==> Installing to /Applications"
pkill -x "$EXEC" 2>/dev/null || true
sleep 1
rm -rf "/Applications/$APP.app"
cp -R "$BUNDLE" "/Applications/$APP.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "/Applications/$APP.app" 2>/dev/null || true

if [ "${NO_LAUNCH:-0}" != "1" ]; then
  echo "==> Launching"
  open "/Applications/$APP.app"
fi
echo "Done. Notes live in ~/paper-notes (git)."
