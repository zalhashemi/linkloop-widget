#!/bin/bash
# Builds LinkLoop.app (menu bar only, ad-hoc signed). Needs Xcode Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"
APP=LinkLoop.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
# One binary for Apple Silicon and Intel.
TMP=$(mktemp -d)
for ARCH in arm64 x86_64; do
  swiftc -O -target "$ARCH-apple-macos13" LinkLoop.swift -o "$TMP/LinkLoop-$ARCH"
done
lipo -create "$TMP"/LinkLoop-* -output "$APP/Contents/MacOS/LinkLoop"
rm -rf "$TMP"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>LinkLoop</string>
  <key>CFBundleIdentifier</key><string>com.local.linkloop</string>
  <key>CFBundleExecutable</key><string>LinkLoop</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict>
</plist>
PLIST
codesign --force -s - "$APP"
echo "Built $APP. Run: open $APP"
