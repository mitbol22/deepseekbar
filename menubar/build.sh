#!/bin/zsh
# Builds DeepSeekBar.app and installs it to ~/Applications.
set -euo pipefail
HERE=${0:A:h}
PROJECT=${HERE:h}
APP="$HERE/build/DeepSeekBar.app"

rm -rf "$HERE/build"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$HERE/deepseek.svg" "$APP/Contents/Resources/"
swiftc -O -o "$APP/Contents/MacOS/DeepSeekBar" "$HERE/DeepSeekBar.swift" -framework AppKit -framework SwiftUI -framework Charts -framework ServiceManagement -swift-version 5

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.deepseekbar</string>
  <key>CFBundleName</key><string>DeepSeekBar</string>
  <key>CFBundleExecutable</key><string>DeepSeekBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>DSProjectDir</key><string>$PROJECT</string>
</dict></plist>
EOF

codesign --force --sign - "$APP"
mkdir -p ~/Applications
pkill -x DeepSeekBar 2>/dev/null || true
rm -rf ~/Applications/DeepSeekBar.app
cp -R "$APP" ~/Applications/
echo "Installed ~/Applications/DeepSeekBar.app"
