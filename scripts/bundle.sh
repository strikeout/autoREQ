#!/bin/sh
# Builds AutoREQ.app in build/. macOS asks for microphone access only for a bundled app
# with NSMicrophoneUsageDescription, so do not use a bare `swift run` binary to measure.
set -eu
cd "$(dirname "$0")/.."
VERSION=$(sed 's/^v//' version.txt)
swift build -c release --product AutoREQ
APP=build/AutoREQ.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/AutoREQ" "$APP/Contents/MacOS/AutoREQ"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>AutoREQ</string>
  <key>CFBundleIdentifier</key><string>uk.local.autoreq</string>
  <key>CFBundleName</key><string>AutoREQ</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>AutoREQ uses the microphone to measure your speakers and your room.</string>
</dict>
</plist>
EOF
codesign --force --sign - "$APP"
echo "Built $APP"
