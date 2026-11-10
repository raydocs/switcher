#!/bin/bash
# Build Switcher.app into dist/ (ad-hoc signed unless SIGN_ID is set).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.1.0}"
swift build -c release --product SwitcherApp
swift build -c release --product switcher
BIN="$(swift build -c release --show-bin-path)"
APP="dist/Switcher.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/SwitcherApp" "$APP/Contents/MacOS/Switcher"
cp "$BIN/switcher" "$APP/Contents/Resources/switcher"
[ -f assets/AppIcon.icns ] && cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.switcher.app</string>
  <key>CFBundleName</key><string>Switcher</string>
  <key>CFBundleDisplayName</key><string>Switcher</string>
  <key>CFBundleExecutable</key><string>Switcher</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
  <key>NSHumanReadableCopyright</key><string>Includes code ported from cc-same (MIT).</string>
</dict>
</plist>
PLIST
codesign --force --sign "${SIGN_ID:--}" --options runtime "$APP"
echo "$APP"
