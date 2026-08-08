#!/bin/bash
# Builds VoiceBridge.app, installs the whisper model, and launches it.
set -euo pipefail
cd "$(dirname "$0")"

APP="VoiceBridge"
BUNDLE="build/$APP.app"
SUPPORT="$HOME/Library/Application Support/VoiceBridge"
MODEL="ggml-small.en.bin"

echo "==> Checking prerequisites"
command -v whisper-cli >/dev/null || { echo "missing whisper-cli — run: brew install whisper-cpp"; exit 1; }
mkdir -p "$SUPPORT"
if [ ! -f "$SUPPORT/$MODEL" ]; then
  if [ -f "models/$MODEL" ]; then
    echo "    installing model into Application Support"
    cp "models/$MODEL" "$SUPPORT/$MODEL"
  else
    echo "    downloading $MODEL"
    curl -Lf --progress-bar -o "$SUPPORT/$MODEL" \
      "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL"
  fi
fi

echo "==> Compiling"
swift build -c release

echo "==> Rendering icon"
rm -rf build/AppIcon.iconset
swift Tools/MakeIcon.swift build/AppIcon.iconset >/dev/null

echo "==> Assembling bundle"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp ".build/release/$APP" "$BUNDLE/Contents/MacOS/$APP"
iconutil -c icns build/AppIcon.iconset -o "$BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP</string>
  <key>CFBundleDisplayName</key><string>Voice Bridge</string>
  <key>CFBundleIdentifier</key><string>local.voicebridge</string>
  <key>CFBundleExecutable</key><string>$APP</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <!-- Both prompts are required: one to record, one to drive iTerm2. -->
  <key>NSMicrophoneUsageDescription</key>
  <string>VoiceBridge records your voice locally to transcribe it into your terminal.</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>VoiceBridge types the transcribed text into your iTerm2 session.</string>
</dict>
</plist>
PLIST

# A fixed certificate gives a designated requirement of
#   identifier "local.voicebridge" and certificate root = H"..."
# which survives rebuilds, so the Accessibility grant is not invalidated every
# time. Ad-hoc signing keys TCC to the binary hash instead, which is why this app
# kept losing its permission. Run Tools/make-signing-identity.sh to create it.
IDENTITY="VoiceBridge Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  echo "==> Signing with '$IDENTITY' (stable — TCC grant survives)"
  codesign --force --sign "$IDENTITY" --identifier local.voicebridge "$BUNDLE" 2>&1 | grep -v "replacing existing" || true
else
  echo "==> Signing (ad-hoc) — WARNING: this invalidates the Accessibility grant."
  echo "    Run Tools/make-signing-identity.sh to stop that happening."
  codesign --force --sign - "$BUNDLE" >/dev/null 2>&1
fi

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
cat <<'NOTE'
Done. Double-tap Control to dictate.

  Turn off the built-in Dictation shortcut first, or both will fire:
    System Settings › Keyboard › Dictation › Shortcut → Off

  No menu bar icon by design. Useful commands:
    /Applications/VoiceBridge.app/Contents/MacOS/VoiceBridge --status
    /Applications/VoiceBridge.app/Contents/MacOS/VoiceBridge --enable-login-item
    pkill -x VoiceBridge          # quit
NOTE
