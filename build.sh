#!/bin/bash
# Builds Harbor.app (universal, ad-hoc signed) into ./build
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Harbor.app"
VERSION="1.0.1"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

for ARCH in arm64 x86_64; do
  swiftc -O -parse-as-library -target "$ARCH-apple-macos14.0" \
    -module-name Harbor -o "build/obj/Harbor-$ARCH" Sources/*.swift
done
lipo -create build/obj/Harbor-arm64 build/obj/Harbor-x86_64 -output "$APP/Contents/MacOS/Harbor"

# App icon
swift Tools/MakeIcon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Harbor</string>
  <key>CFBundleIdentifier</key><string>app.harbor.Harbor</string>
  <key>CFBundleName</key><string>Harbor</string>
  <key>CFBundleDisplayName</key><string>Harbor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Not affiliated with Anthropic.</string>
  <key>NSAppleEventsUsageDescription</key><string>Harbor passes claude:// links (like sign-in links) to the Claude window of the right profile.</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>Harbor shortcuts</string>
      <key>CFBundleURLSchemes</key><array><string>harbor</string></array>
    </dict>
    <dict>
      <key>CFBundleURLName</key><string>Claude link router</string>
      <key>CFBundleURLSchemes</key><array><string>claude</string></array>
      <key>LSHandlerRank</key><string>Alternate</string>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"
